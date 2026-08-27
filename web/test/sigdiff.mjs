// 指纹对照台 —— 把 `web/lib/shazam.mjs` 的输出和 ShazamKit 的输出摆在一起看。
//
//   1) 生成一段确定性的 16 kHz 单声道 16-bit WAV：
//        node web/test/sigdiff.mjs wav "$TMPDIR/probe.wav"
//   2) 让 ShazamKit 对同一段音频算一份（见 tools/ShazamSigRef.swift 的编译命令）：
//        "$TMPDIR/shazamsig" "$TMPDIR/probe.wav" "$TMPDIR/probe.sig"
//   3) 两种对照：
//        node web/test/sigdiff.mjs bytes "$TMPDIR/probe.sig"              ← 只验字节格式
//        node web/test/sigdiff.mjs diff  "$TMPDIR/probe.wav" "$TMPDIR/probe.sig"  ← 连算法一起验
//   另外 `self` 不需要 ShazamKit，只跑一遍看编解码是否自洽。
//
// 为什么要这么绕：`amp.shazam.com` 对错误的指纹只回 `200 no match`，
// 从响应里看不出错在第几个常数上。所以先在本机把两边对齐，对上了再谈联网。
//
// `bytes` 是最硬的那个证据：把 ShazamKit 自己的峰解出来、用我们的写入器重新打一遍，
// 除了偏移 4（crc32）与偏移 12（magic2，可选值）以外应当逐字节相同。
// `diff` 则是算法层面的对照，判定标准是**峰值**而不是整体 md5：ShazamKit 会再筛一轮，
// 我们的峰是它的超集，所以看的是「它的峰我们是不是都有」。
import { readFileSync, writeFileSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
import {
  collectPeaks, decodeSignature, encodeSignature, signature, SIG_SAMPLE_RATE,
} from '../lib/shazam.mjs'

// MARK: - 探针音频

/// 一段确定性的「像音乐」的信号：几个谐波 + 慢速颤音 + 每 1.5 秒换一次和弦，
/// 再叠一点固定种子的噪声。要的是能稳定产出各频段峰值、且两次生成完全一样。
///
/// `check.mjs` 里钉的那几个金标准值就是这段信号算出来的，所以**别改它** ——
/// 改了以后钉住的数就全对不上，也就跟 ShazamKit 那次对照脱钩了。
export function makeProbe(seconds = 12) {
  const n = Math.round(SIG_SAMPLE_RATE * seconds)
  const out = new Int16Array(n)
  const chords = [
    [261.63, 329.63, 392.0],
    [293.66, 369.99, 440.0],
    [349.23, 440.0, 523.25],
    [392.0, 493.88, 587.33],
  ]
  let seed = 0x1234abcd
  for (let i = 0; i < n; i++) {
    const t = i / SIG_SAMPLE_RATE
    const chord = chords[Math.floor(t / 1.5) % chords.length]
    let v = 0
    for (const f of chord) {
      v += Math.sin(2 * Math.PI * f * t) * 0.22
      v += Math.sin(2 * Math.PI * f * 2 * t) * 0.09     // 二次谐波，进第二个频段
      v += Math.sin(2 * Math.PI * f * 5 * t) * 0.04     // 五次谐波，进第三/四个频段
    }
    v *= 0.9 + 0.1 * Math.sin(2 * Math.PI * 5.5 * t)    // 颤音
    seed = (seed * 1103515245 + 12345) & 0x7fffffff     // 固定种子的伪随机
    v += (seed / 0x7fffffff - 0.5) * 0.02
    const s = Math.round(Math.max(-1, Math.min(1, v / 1.6)) * 32767)
    out[i] = s
  }
  return out
}

/// 最朴素的 WAV 封装（44 字节头 + PCM），给 AVURLAsset 读。
export function wav(pcm, rate = SIG_SAMPLE_RATE) {
  const bytes = new Uint8Array(44 + pcm.length * 2)
  const view = new DataView(bytes.buffer)
  const ascii = (o, s) => { for (let i = 0; i < s.length; i++) bytes[o + i] = s.charCodeAt(i) }
  ascii(0, 'RIFF')
  view.setUint32(4, 36 + pcm.length * 2, true)
  ascii(8, 'WAVEfmt ')
  view.setUint32(16, 16, true)
  view.setUint16(20, 1, true)          // PCM
  view.setUint16(22, 1, true)          // 单声道
  view.setUint32(24, rate, true)
  view.setUint32(28, rate * 2, true)   // 字节率
  view.setUint16(32, 2, true)          // 帧大小
  view.setUint16(34, 16, true)         // 位深
  ascii(36, 'data')
  view.setUint32(40, pcm.length * 2, true)
  for (let i = 0; i < pcm.length; i++) view.setInt16(44 + i * 2, pcm[i], true)
  return bytes
}

/// 从我们自己写的那种 WAV 里读回样本（只认 16-bit 单声道 PCM）。
function readWav(path) {
  const buf = readFileSync(path)
  const view = new DataView(buf.buffer, buf.byteOffset, buf.byteLength)
  let at = 12
  let rate = SIG_SAMPLE_RATE
  let pcm = null
  while (at + 8 <= buf.length) {
    const id = String.fromCharCode(buf[at], buf[at + 1], buf[at + 2], buf[at + 3])
    const len = view.getUint32(at + 4, true)
    if (id === 'fmt ') rate = view.getUint32(at + 12, true)
    if (id === 'data') {
      pcm = new Int16Array(len / 2)
      for (let i = 0; i < pcm.length; i++) pcm[i] = view.getInt16(at + 8 + i * 2, true)
    }
    at += 8 + len + (len % 2)
  }
  if (!pcm) throw new Error(`${path} 里没找到 data 块`)
  return { pcm, rate }
}

// MARK: - 对照

function hex(bytes) {
  return [...bytes].map((b) => b.toString(16).padStart(2, '0')).join(' ')
}

/// 逐 u32 印出头部 48 字节，顺带标出公开实现里那几个已知常数。
function dumpHeader(label, bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  const known = {
    0: 'magic1 (应为 cafe2580)',
    4: 'crc32',
    8: 'size-48',
    12: 'magic2（ShazamKit 43504010 / 公开实现 94119c00）',
    28: 'rate_id << 27',
    40: 'samples + (u32)(f32)(rate*0.24)',
    44: '007c0000',
    48: 'TLV tag 40000000',
    52: 'size-48（复述）',
  }
  console.log(`\n== ${label}  ${bytes.length}B`)
  for (let o = 0; o + 4 <= Math.min(56, bytes.length); o += 4) {
    const v = view.getUint32(o, true)
    const note = known[o] ? `  ← ${known[o]}` : ''
    console.log(`  ${String(o).padStart(2)}  ${v.toString(16).padStart(8, '0')}  ${v}${note}`)
  }
}

/// 峰值层面的对照。判定标准是**覆盖率**：ShazamKit 的峰我们要都有。
///
/// 反过来不成立 —— ShazamKit 还会再筛一轮，所以我们多出来的峰（`多余`）是预期的。
/// `(帧号, 频点)` 必须完全相等；幅度只允许差 1 个最低位（两边浮点路径不完全一样）。
function diffBands(mine, theirs) {
  let covered = 0
  let missing = 0
  let extra = 0
  let magOff = 0
  // 尾巴要排掉：ShazamKit 会把音频末尾补零再多算几十帧，我们到最后一个整帧就停。
  const maxPass = Math.max(0, ...mine.flat().map((p) => p.pass))
  for (let i = 0; i < 4; i++) {
    const a = mine[i] ?? []
    const b = theirs[i] ?? []
    const key = (p) => `${p.pass}/${p.bin}`
    const mapA = new Map(a.map((p) => [key(p), p]))
    const want = b.filter((p) => p.pass <= maxPass)
    const lost = want.filter((p) => !mapA.has(key(p)))
    const off = want.filter((p) => {
      const m = mapA.get(key(p))
      return m && Math.abs(m.magnitude - p.magnitude) > 1
    })
    covered += want.length - lost.length
    missing += lost.length
    extra += a.length - (want.length - lost.length)
    magOff += off.length
    console.log(`  band ${i}: ShazamKit ${String(b.length).padStart(4)} 个（帧号 ≤ ${maxPass} 的 ${String(want.length).padStart(4)} 个）` +
      ` → 覆盖 ${want.length - lost.length}，漏 ${lost.length}，幅度差 >1 的 ${off.length}；我们另有 ${a.length - (want.length - lost.length)} 个多余的峰`)
    for (const p of lost.slice(0, 6)) console.log(`      漏：pass ${p.pass} bin ${p.bin} mag ${p.magnitude}`)
  }
  return { covered, missing, extra, magOff }
}

// MARK: - 入口
//
// 只有直接跑这个文件才走下面的命令行；`check.mjs` 会 import 上面的 `makeProbe`。

const isMain = process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href
const [mode, arg1, arg2] = isMain ? process.argv.slice(2) : ['—']

if (!isMain) {
  // 被 import，什么都不做。
} else if (mode === 'wav') {
  const path = arg1 ?? `${process.env.TMPDIR ?? '.'}/probe.wav`
  const pcm = makeProbe(12)
  writeFileSync(path, wav(pcm))
  console.log(`已写 ${path}：${pcm.length} 样本 / ${(pcm.length / SIG_SAMPLE_RATE).toFixed(2)} 秒 / 16 kHz 单声道`)
} else if (mode === 'self') {
  // 不需要 ShazamKit 的自查：算一遍，印峰数与头部，再解回来看能不能自洽。
  const pcm = arg1 ? readWav(arg1).pcm : makeProbe(12)
  const t0 = Date.now()
  const bands = collectPeaks(pcm)
  const bytes = signature(pcm)
  console.log(`${pcm.length} 样本，用了 ${Date.now() - t0} ms`)
  console.log(`峰数：${bands.map((b) => b.length).join(' / ')}`)
  dumpHeader('JS', bytes)
  const back = decodeSignature(bytes)
  console.log(`\n解回来的峰数：${back.bands.map((b) => b.length).join(' / ')}`)
  console.log(`未识别的 TLV：${back.unknownTags.length}`)
  const ok = back.bands.every((b, i) => b.length === bands[i].length)
  console.log(ok ? '编码/解码自洽 ✅' : '编码/解码不自洽 ❌')
  process.exit(ok ? 0 : 1)
} else if (mode === 'bytes') {
  // 只验字节格式，不碰算法：把 ShazamKit 那份解开、再用我们的写入器重新打一遍。
  if (!arg1) {
    console.error('用法：node web/test/sigdiff.mjs bytes <probe.sig>')
    process.exit(2)
  }
  const theirs = new Uint8Array(readFileSync(arg1))
  const info = decodeSignature(theirs)
  const samples = info.sampleCountPlusPad - Math.trunc(Math.fround(SIG_SAMPLE_RATE * 0.24))
  const mine = encodeSignature(info.bands, samples, SIG_SAMPLE_RATE)
  console.log(`ShazamKit ${theirs.length}B  重新打 ${mine.length}B  ` +
    (theirs.length === mine.length ? '长度一致 ✅' : '长度不一致 ❌'))
  const bad = []
  for (let i = 0; i < Math.min(theirs.length, mine.length); i++) if (theirs[i] !== mine[i]) bad.push(i)
  const u32s = [...new Set(bad.map((i) => i - (i % 4)))]
  for (const o of u32s) {
    console.log(`  偏移 ${o}：ShazamKit ${hex(theirs.subarray(o, o + 4))} / 我们 ${hex(mine.subarray(o, o + 4))}`)
  }
  // 偏移 4 是 crc32，只要头里有一个字段不同它就必然不同；偏移 12 是 magic2 的可选值。
  const ok = theirs.length === mine.length && u32s.every((o) => o === 4 || o === 12)
  console.log(ok
    ? (u32s.length === 0
      ? '\n每一个字节都相同 ✅（TLV / delta / 补齐 / 长度 / magic2 / CRC32 全对）'
      : `\n除了偏移 ${u32s.join('、')}，逐字节一致 ✅（TLV / delta / 补齐 / 长度 / CRC32 都对）`)
    : '\n载荷里也有差异 ❌')
  process.exit(ok ? 0 : 1)
} else if (mode === 'diff') {
  if (!arg1 || !arg2) {
    console.error('用法：node web/test/sigdiff.mjs diff <probe.wav> <probe.sig>')
    process.exit(2)
  }
  const { pcm, rate } = readWav(arg1)
  if (rate !== SIG_SAMPLE_RATE) console.warn(`⚠️ WAV 是 ${rate} Hz，不是 16 kHz`)
  const mine = signature(pcm)
  const theirs = new Uint8Array(readFileSync(arg2))
  dumpHeader('JS', mine)
  dumpHeader('ShazamKit', theirs)
  const a = decodeSignature(mine)
  const b = decodeSignature(theirs)
  console.log('\n== 峰值')
  const { covered, missing, extra, magOff } = diffBands(a.bands, b.bands)
  console.log(`\n覆盖 ${covered}，漏 ${missing}，幅度差 >1 的 ${magOff}，我们多出来的 ${extra}`)
  if (b.unknownTags.length) {
    console.log(`ShazamKit 那份里有 ${b.unknownTags.length} 个我们不认识的 TLV：` +
      b.unknownTags.map((t) => `${t.tag.toString(16)}(${t.len}B)`).join(' '))
  }
  const ok = missing === 0 && magOff === 0
  console.log(ok
    ? '\nShazamKit 的峰我们全都有，幅度也只差最低位以内 ✅（多出来的峰是预期的）'
    : '\n有漏掉的峰或幅度差得太多 ❌')
  process.exit(ok ? 0 : 1)
} else {
  console.error('用法：node web/test/sigdiff.mjs wav|self|bytes|diff [参数…]')
  process.exit(2)
}
