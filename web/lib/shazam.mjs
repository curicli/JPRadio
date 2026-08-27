// Shazam 客户端指纹的纯 JS 实现 —— 也就是 `amp.shazam.com` 收的那份
// `0xcafe2580` 开头的原生签名。iOS 端这一步是 ShazamKit 代劳的
// （`SHSignatureGenerator`），浏览器里没有等价物，所以只能自己算。
//
// **为什么值得把算法写下来**：查曲库那半边（`ShazamWebMatcher`）本来就是自己实现的，
// 不需要 ShazamKit；缺的只有「音频 → 指纹」这一步。而这一步一旦有偏差，
// 服务端**不会报错**，只会回一句 `200 no match` —— 从响应里看不出错在第几个常数上。
// 所以 `Tools/ShazamSigRef.swift` 让 ShazamKit 对同一段音频算一份，
// 拿来跟这里的输出做字节级对照：对上了才谈联网。
//
// 算法与格式的出处是公开的逆向实现（marin-m/SongRec 的 fingerprinting 模块）。
//
// **对照结果**（`node web/test/sigdiff.mjs`，标尺是 `tools/ShazamSigRef.swift`）：
//   - 字节格式**已经证明是对的**：把 ShazamKit 自己那份签名解出来、再用这里的
//     `encodeSignature` 重新打一遍，2388 字节里只有偏移 4（crc32）和偏移 12 不同 ——
//     TLV、delta 编码、补齐、长度字段、CRC32 全部逐字节吻合。
//   - 峰值：ShazamKit 那 459 个峰里我们命中 432 个，`(帧号, 频点)` **完全相等**；
//     幅度 89% 完全相等、其余只差 1 个最低位。所以窗函数、FFT 归一、扩散、
//     判定门、抛物线插值、频段划分都是对的。
//   - 唯一的实质差别：**我们的峰是超集**（1304 对 459）。ShazamKit 还会再筛一轮
//     （大致每个频段留最强的一百多个），我们不筛。SongRec 也不筛而它能查到曲子，
//     所以多出来的峰应当只是多几个候选散列，不会把真的那些挤掉。
//
// 下面每个常数都必须**一个字不差**，因为它们最终决定了送给服务端的那串字节：
//   - 16 kHz 单声道；2048 点 FFT，每 128 个样本推进一帧（帧号 = fft_pass）；
//   - 窗函数是「2050 点对称 Hanning 去掉两端的零」，也就是分母 2049 而不是
//     2047（np.hanning(2048)）或 2048（周期形式）—— 这一条最容易错，
//     而错了之后指纹仍然「看起来正常」；
//   - 峰值判定要跨 46/49 帧回看，所以两个环形缓冲都得留 256 帧；
//   - 频点按 64 倍精度做抛物线插值，再按四个频段分桶。
export const SIG_SAMPLE_RATE = 16000

const N = 2048          // FFT 长度
const HOP = 128         // 每帧推进的样本数
const BINS = 1025       // 实数 FFT 的输出点数（N / 2 + 1）
const RINGS = 256       // 环形缓冲的帧数（要 > 49 + 前后邻居用到的 91 帧）

/// 峰值幅度的下限，同时也是取对数之后的钳位值（原实现两处用的是同一个字面量）。
const FLOOR = 1 / 64

/// 频率方向的邻居偏移：候选点必须比 -49 帧里这些位置都强。
const FREQ_NEIGHBORS = [-10, -7, -4, -3, 1, 2, 5, 8]

/// 时间方向的邻居帧偏移（相对当前 spread 下标，mod 256）。
/// 165…249 换算过来是 −91…−7 每 7 帧一个，**跳过 −49**（那一帧就是 B 自己，
/// 已经单独比过了）—— 所以这里是 14 个而不是 15 个，别顺手补齐。
const TIME_NEIGHBORS = [-53, -45, 165, 172, 179, 186, 193, 200, 214, 221, 228, 235, 242, 249]

/// 四个频段（Hz，**闭区间**，按截断后的整数比较）。落在外面的峰直接丢掉。
/// 注意最后一段的上界 5500 是含在内的，写成半开区间会少掉边界上的峰。
const BANDS = [[250, 519], [520, 1449], [1450, 3499], [3500, 5500]]

/// 采样率在头里的编号。
const RATE_IDS = new Map([[8000, 1], [11025, 2], [16000, 3], [32000, 4], [44100, 5], [48000, 6]])

/// 头部偏移 12 那个 u32。
///
/// ShazamKit 写的是 `0x43504010`（两份长度不同的签名里都一样，所以它是常数
/// 而不是随内容变的字段）；公开逆向实现写的是 `0x94119C00`。
/// 我们跟 ShazamKit 一致 —— iOS 端送出去能查到曲子的就是这个值，
/// 而 `amp.shazam.com` 对错误的指纹只回 `no match`，没必要在这里赌另一个。
const MAGIC2 = 0x43504010
export const MAGIC2_SONGREC = 0x94119c00

// MARK: - 窗函数与 FFT

/// 「2050 点对称 Hanning 去掉两端的零」= 分母 2049。
/// 换成 2047（`np.hanning(2048)`）或 2048（周期形式）都只差 1e-9 量级，
/// 却足以让个别临界峰值翻面 —— 而指纹里少一个峰，服务端就只回 no match。
const WINDOW = (() => {
  const w = new Float64Array(N)
  for (let i = 0; i < N; i++) w[i] = 0.5 * (1 - Math.cos((2 * Math.PI * (i + 1)) / (N + 1)))
  return w
})()

/// 位反转表与旋转因子（2048 点定长，建一次用到底）。
const REV = new Uint16Array(N)
const TWIDDLE_COS = new Float64Array(N / 2)
const TWIDDLE_SIN = new Float64Array(N / 2)
{
  const bits = Math.log2(N)
  for (let i = 0; i < N; i++) {
    let r = 0
    for (let b = 0; b < bits; b++) if (i & (1 << b)) r |= 1 << (bits - 1 - b)
    REV[i] = r
  }
  for (let i = 0; i < N / 2; i++) {
    TWIDDLE_COS[i] = Math.cos((-2 * Math.PI * i) / N)
    TWIDDLE_SIN[i] = Math.sin((-2 * Math.PI * i) / N)
  }
}

/// 原地基 2 FFT（迭代版）。输入是实信号，所以调用方把 `im` 清零即可；
/// 只用到前 1025 个输出点。自己写是为了守住「零第三方依赖」。
function fft(re, im) {
  for (let i = 0; i < N; i++) {
    const j = REV[i]
    if (j > i) {
      let t = re[i]; re[i] = re[j]; re[j] = t
      t = im[i]; im[i] = im[j]; im[j] = t
    }
  }
  for (let size = 2; size <= N; size <<= 1) {
    const half = size >> 1
    const step = N / size
    for (let i = 0; i < N; i += size) {
      for (let k = 0; k < half; k++) {
        const c = TWIDDLE_COS[k * step], s = TWIDDLE_SIN[k * step]
        const a = i + k, b = a + half
        const tr = re[b] * c - im[b] * s
        const ti = re[b] * s + im[b] * c
        re[b] = re[a] - tr; im[b] = im[a] - ti
        re[a] += tr; im[a] += ti
      }
    }
  }
}

// MARK: - 峰值提取

/// 从 16 kHz 单声道样本里提取四个频段的峰值序列。
///
/// `samples` 收 `Int16Array`（或取值已在 ±32768 的 `Float64Array`）——
/// 原实现在这一步就把 f32 转成了 i16，量化误差是算法的一部分，不能跳过。
///
/// 返回 `[band0, band1, band2, band3]`，每个峰是
/// `{ pass, magnitude, bin }`（帧号 / u16 幅度 / 64 倍精度的频点）。
export function collectPeaks(samples) {
  const ring = new Float64Array(N)
  let ringIndex = 0
  const ffts = Array.from({ length: RINGS }, () => new Float64Array(BINS))
  let fftIndex = 0
  const spreads = Array.from({ length: RINGS }, () => new Float64Array(BINS))
  let spreadIndex = 0
  let done = 0
  const bands = [[], [], [], []]
  const re = new Float64Array(N), im = new Float64Array(N)
  const snapshot = new Float64Array(BINS)

  for (let offset = 0; offset + HOP <= samples.length; offset += HOP) {
    // ---- do_fft：写进环形缓冲，**先推进下标**，再从新下标处开始读（最老的排在最前）。
    for (let i = 0; i < HOP; i++) ring[(ringIndex + i) & (N - 1)] = samples[offset + i]
    ringIndex = (ringIndex + HOP) & (N - 1)
    for (let i = 0; i < N; i++) {
      re[i] = ring[(i + ringIndex) & (N - 1)] * WINDOW[i]
      im[i] = 0
    }
    fft(re, im)
    const out = ffts[fftIndex]
    for (let i = 0; i < BINS; i++) {
      out[i] = Math.max((re[i] * re[i] + im[i] * im[i]) / 131072, 1e-10)
    }
    fftIndex = (fftIndex + 1) & (RINGS - 1)

    // ---- do_peak_spreading：先在频率方向取 3 点最大，再把结果**写进**更早的三帧。
    const cur = spreads[spreadIndex]
    cur.set(out)
    for (let p = 0; p <= 1022; p++) cur[p] = Math.max(cur[p], cur[p + 1], cur[p + 2])
    snapshot.set(cur)
    for (const back of [1, 3, 6]) {
      const earlier = spreads[(spreadIndex - back + RINGS) & (RINGS - 1)]
      for (let p = 0; p < BINS; p++) if (snapshot[p] > earlier[p]) earlier[p] = snapshot[p]
    }
    spreadIndex = (spreadIndex + 1) & (RINGS - 1)

    done++
    if (done >= 46) recognize(ffts, fftIndex, spreads, spreadIndex, done, bands)
  }
  return bands
}

/// 每帧幅度→频点的换算：16000 / 2 / 1024 / 64。
const HZ_PER_UNIT = 16000 / 2 / 1024 / 64

/// do_peak_recognition：判定 **46 帧之前**那一帧里的峰。
///
/// 三重比较缺一不可，而且下标错一位不会报错、只会少几个峰：
///   1. 原始谱 A（`fftIndex - 46`）自己要够响（≥ 1/64）且不低于 B 的 **前一个** 频点；
///   2. 比 B（`spreadIndex - 49`）在 8 个频率邻居处都强；
///   3. 比另外 14 帧在 **bin − 1** 处都强（那 14 帧的最大值以第 2 步的结果为起点继续取）。
function recognize(ffts, fftIndex, spreads, spreadIndex, done, bands) {
  const a = ffts[(fftIndex - 46 + RINGS) & (RINGS - 1)]
  const b = spreads[(spreadIndex - 49 + RINGS) & (RINGS - 1)]
  for (let bin = 10; bin <= 1014; bin++) {
    const mag = a[bin]
    if (mag < FLOOR || mag < b[bin - 1]) continue

    let peak = 0
    for (const off of FREQ_NEIGHBORS) peak = Math.max(peak, b[bin + off])
    if (mag <= peak) continue

    for (const off of TIME_NEIGHBORS) {
      const other = spreads[(spreadIndex + off) & (RINGS - 1)]
      peak = Math.max(peak, other[bin - 1])
    }
    if (mag <= peak) continue

    // 钳位在 ln **之后**（先 max 再 ln 会得到完全不同的值）。
    const here = Math.max(Math.log(mag), FLOOR) * 1477.3 + 6144
    const before = Math.max(Math.log(a[bin - 1]), FLOOR) * 1477.3 + 6144
    const after = Math.max(Math.log(a[bin + 1]), FLOOR) * 1477.3 + 6144
    const v1 = here * 2 - before - after
    const v2 = ((after - before) * 32) / v1
    const corrected = (bin * 64 + Math.trunc(v2)) & 0xffff

    const hz = Math.trunc(corrected * HZ_PER_UNIT)
    for (let i = 0; i < 4; i++) {
      if (hz >= BANDS[i][0] && hz <= BANDS[i][1]) {
        bands[i].push({ pass: done - 46, magnitude: Math.round(here) & 0xffff, bin: corrected })
        break
      }
    }
  }
}

// MARK: - 字节格式

/// CRC-32/ISO-HDLC（反射多项式 0xEDB88320，初值与末值都取反）。
const CRC_TABLE = (() => {
  const t = new Uint32Array(256)
  for (let i = 0; i < 256; i++) {
    let c = i
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[i] = c >>> 0
  }
  return t
})()

function crc32(bytes) {
  let c = 0xffffffff
  for (let i = 0; i < bytes.length; i++) c = CRC_TABLE[(c ^ bytes[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

/// 把峰值序列打成 Shazam 原生签名（`0xcafe2580` 开头，与 iOS 剥壳后的那份同一种）。
///
/// `sampleCount` 是参与计算的样本数（16 kHz 下 12 秒 = 192000）。
/// 头里第 40 字节那一项是 `样本数 + (u32)(f32)(采样率 * 0.24)` ——
/// 必须照抄「先转 f32 再截断」这一步，否则 16 kHz 下会差 1。
/// （已经拿 12 秒与 5 秒两份 ShazamKit 签名核对过：195840 / 83840，都对得上。）
export function encodeSignature(bands, sampleCount, sampleRate = SIG_SAMPLE_RATE, magic2 = MAGIC2) {
  const rateId = RATE_IDS.get(sampleRate)
  if (rateId === undefined) throw new Error(`不支持的采样率：${sampleRate}`)

  // 先把每个频段的载荷打出来（空频段整块跳过，不能留一个长度为 0 的壳）。
  const chunks = []
  for (let i = 0; i < 4; i++) {
    const peaks = bands[i]
    if (!peaks || peaks.length === 0) continue
    const body = []
    let counter = 0
    for (const peak of peaks) {
      if (peak.pass - counter >= 255) {
        body.push(0xff)
        pushU32(body, peak.pass)
        counter = peak.pass
      }
      body.push((peak.pass - counter) & 0xff)
      pushU16(body, peak.magnitude)
      pushU16(body, peak.bin)
      counter = peak.pass
    }
    chunks.push({ tag: (0x60030040 + i) >>> 0, body })
  }

  let payloadLength = 0
  for (const c of chunks) payloadLength += 8 + c.body.length + ((4 - (c.body.length % 4)) % 4)

  const total = 48 + 8 + payloadLength
  const out = new Uint8Array(total)
  const view = new DataView(out.buffer)
  const sizeMinusHeader = total - 48

  view.setUint32(0, 0xcafe2580, true)          // magic1
  view.setUint32(4, 0, true)                   // crc32，最后补
  view.setUint32(8, sizeMinusHeader, true)
  view.setUint32(12, magic2, true)             // magic2
  view.setUint32(16, 0, true)
  view.setUint32(20, 0, true)
  view.setUint32(24, 0, true)
  view.setUint32(28, (rateId << 27) >>> 0, true)
  view.setUint32(32, 0, true)
  view.setUint32(36, 0, true)
  view.setUint32(40, (sampleCount + Math.trunc(Math.fround(sampleRate * 0.24))) >>> 0, true)
  view.setUint32(44, 0x007c0000, true)
  view.setUint32(48, 0x40000000, true)         // TLV 前导
  view.setUint32(52, sizeMinusHeader, true)

  let at = 56
  for (const c of chunks) {
    view.setUint32(at, c.tag, true); at += 4
    view.setUint32(at, c.body.length, true); at += 4
    out.set(c.body, at); at += c.body.length
    at += (4 - (c.body.length % 4)) % 4    // 补零，Uint8Array 本来就是 0
  }

  view.setUint32(4, crc32(out.subarray(8)), true)
  return out
}

function pushU16(arr, v) {
  arr.push(v & 0xff, (v >>> 8) & 0xff)
}

function pushU32(arr, v) {
  arr.push(v & 0xff, (v >>> 8) & 0xff, (v >>> 16) & 0xff, (v >>> 24) & 0xff)
}

/// 反过来解一份原生签名 —— 只在对照 ShazamKit 的输出时用。
///
/// 刻意写得宽容：ShazamKit 那份的头未必与公开逆向实现逐字节一致
/// （实测偏移 12 处不是 `magic2`），而且可能多带几个我们不认识的 TLV。
/// 所以 TLV 一律按 `tag/length` 跳过，只认 `0x60030040+i` 四个频段块。
/// 这样两边就能在**峰值层面**对照，而不必先赌头部一致。
export function decodeSignature(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const u32 = (o) => view.getUint32(o, true)
  const info = {
    magic1: u32(0),
    crc32: u32(4),
    sizeMinusHeader: u32(8),
    magic2: u32(12),
    rateId: u32(28) >>> 27,
    sampleCountPlusPad: u32(40),
    bands: [[], [], [], []],
    unknownTags: [],
  }

  let at = 48
  const end = Math.min(bytes.length, 48 + info.sizeMinusHeader)
  while (at + 8 <= end) {
    const tag = u32(at)
    const len = u32(at + 4)
    at += 8
    if (tag === 0x40000000) continue        // 外层容器，直接进到里面
    if (at + len > end) break
    const index = tag - 0x60030040
    if (index >= 0 && index <= 3) {
      let p = at
      let pass = 0
      while (p + 5 <= at + len) {
        let delta = bytes[p]; p += 1
        if (delta === 0xff) {
          pass = u32(p); p += 4
          continue
        }
        pass += delta
        const magnitude = view.getUint16(p, true); p += 2
        const bin = view.getUint16(p, true); p += 2
        info.bands[index].push({ pass, magnitude, bin })
      }
    } else {
      info.unknownTags.push({ tag, len, at })
    }
    at += len + ((4 - (len % 4)) % 4)
  }
  return info
}

// MARK: - 对外的一步到位接口

/// `Float32Array`（±1.0）→ `Int16Array`。
///
/// 量化必须在进 FFT **之前**做 —— 原实现就是在这一步落到 i16 的，
/// 由此产生的误差是算法的一部分。取整方式（round / trunc）是与
/// ShazamKit 对照时要试的一个旋钮，先按四舍五入。
export function floatsToInt16(floats) {
  const out = new Int16Array(floats.length)
  for (let i = 0; i < floats.length; i++) {
    const v = Math.round(floats[i] * 32767)
    out[i] = v > 32767 ? 32767 : v < -32768 ? -32768 : v
  }
  return out
}

/// 16 kHz 单声道样本 → 原生签名字节。
export function signature(samples, sampleRate = SIG_SAMPLE_RATE) {
  const pcm = samples instanceof Int16Array ? samples : floatsToInt16(samples)
  return encodeSignature(collectPeaks(pcm), pcm.length, sampleRate)
}

/// 签名字节 → `ShazamWebMatcher` 里那种 `signature.uri`。
/// 浏览器与 Node 都要能用，所以两种 base64 都留着（这个文件将来要直接进浏览器）。
export function signatureURI(bytes) {
  let b64
  if (typeof Buffer !== 'undefined') {
    b64 = Buffer.from(bytes).toString('base64')
  } else {
    let s = ''
    for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i])
    b64 = btoa(s)
  }
  return `data:audio/vnd.shazam.sig;base64,${b64}`
}

