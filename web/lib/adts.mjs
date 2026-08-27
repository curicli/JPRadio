// MPEG-TS → 裸 ADTS AAC。识曲抓音那一步用。
//
// **为什么需要**：识曲的音频最终要交给浏览器的 `decodeAudioData` 解码
// （见 `public/recognize.js`）—— 它认裸 ADTS，但**不认 MPEG-TS 容器**。
// radiko 的分片本来就是 `.aac`（ADTS），直接喂就行；ListenRadio 的分片是 TS，
// 不拆开的话那 30 个台一个都识不了。所以这里把 TS 拆成 ADTS 再送给浏览器。
//
// 只做识曲这一条路需要的最小拆解：找到 PAT → PMT → 第一条 AAC 流的 PID，
// 把那个 PID 的 PES 载荷接起来（stream_type 0x0F 的 PES 载荷本身就是 ADTS 帧）。
// 时间戳、连续计数、加扰、多程序全部不管 —— 拿不到就返回空，让调用方照常报错。
//
// 播放路径**不经过这里**：`/s/` 是原样透传（浏览器自己能放 TS）。
// 这里只服务识曲。

const PACKET = 188
const SYNC = 0x47

/// 这堆字节是不是 MPEG-TS。判据是 188 字节一格的 0x47 同步字节 ——
/// 只看第一个字节会把恰好以 0x47 开头的 ADTS 误判（ADTS 的同步字是 0xFFF，
/// 不会是 0x47，但分片开头未必对齐帧边界，所以还是按周期性来判）。
export function looksLikeTS(bytes) {
  if (bytes.length < PACKET * 2 || bytes[0] !== SYNC) return false
  for (let at = PACKET; at < bytes.length && at < PACKET * 6; at += PACKET) {
    if (bytes[at] !== SYNC) return false
  }
  return true
}

/// 拆出裸 ADTS。拆不出来（没有 PMT、没有 AAC 流、全是加扰包）时返回长度 0 的数组。
export function tsToADTS(bytes) {
  let pmtPID = -1
  let audioPID = -1
  const parts = []
  let total = 0

  for (let at = 0; at + PACKET <= bytes.length; at += PACKET) {
    if (bytes[at] !== SYNC) continue                      // 丢一个包总比整段作废好
    if (bytes[at + 1] & 0x80) continue                    // transport_error_indicator
    if (bytes[at + 3] & 0xc0) continue                    // 加扰过的，解不了
    const pid = ((bytes[at + 1] & 0x1f) << 8) | bytes[at + 2]
    const start = (bytes[at + 1] & 0x40) !== 0            // payload_unit_start_indicator
    const control = (bytes[at + 3] >> 4) & 0x3
    if (!(control & 0x1)) continue                        // 只有 adaptation field，没有载荷
    let from = at + 4
    if (control & 0x2) from += 1 + bytes[at + 4]          // 跳过 adaptation field
    if (from >= at + PACKET) continue

    const payload = bytes.subarray(from, at + PACKET)
    if (pid === 0) {
      pmtPID = programMapPID(section(payload, start)) ?? pmtPID
    } else if (pid === pmtPID && audioPID < 0) {
      audioPID = aacPID(section(payload, start)) ?? -1
    } else if (pid === audioPID && audioPID >= 0) {
      const es = start ? afterPESHeader(payload) : payload
      if (es && es.length) {
        parts.push(es)
        total += es.length
      }
    }
  }

  const out = new Uint8Array(total)
  let at = 0
  for (const p of parts) {
    out.set(p, at)
    at += p.length
  }
  return out
}

/// PSI 包的载荷 → 段内容。首包前面有一个 `pointer_field`（几乎总是 0，但不能假定）。
/// 后续包（`start` 为假）这里一律不接 —— PAT/PMT 短到不会跨包，接了反而要维护状态。
function section(payload, start) {
  if (!start) return null
  const pointer = payload[0]
  const at = 1 + pointer
  return at < payload.length ? payload.subarray(at) : null
}

/// PAT 里第一个 `program_number != 0` 的 PMT PID。
function programMapPID(s) {
  if (!s || s.length < 12 || s[0] !== 0x00) return null
  const length = ((s[1] & 0x0f) << 8) | s[2]
  const end = Math.min(s.length, 3 + length - 4)      // 末尾 4 字节是 CRC32
  for (let at = 8; at + 4 <= end; at += 4) {
    const program = (s[at] << 8) | s[at + 1]
    if (program === 0) continue                       // 0 是 NIT，不是节目
    return ((s[at + 2] & 0x1f) << 8) | s[at + 3]
  }
  return null
}

/// PMT 里第一条 AAC 流的 PID。0x0F 是 ADTS AAC，0x11 是 LATM
/// （LATM 的载荷不是 ADTS，浏览器多半解不开，但拿到总比什么都没有好）。
function aacPID(s) {
  if (!s || s.length < 12 || s[0] !== 0x02) return null
  const length = ((s[1] & 0x0f) << 8) | s[2]
  const end = Math.min(s.length, 3 + length - 4)
  let at = 12 + (((s[10] & 0x0f) << 8) | s[11])       // 跳过 program_info
  while (at + 5 <= end) {
    const type = s[at]
    const pid = ((s[at + 1] & 0x1f) << 8) | s[at + 2]
    const info = ((s[at + 3] & 0x0f) << 8) | s[at + 4]
    if (type === 0x0f || type === 0x11) return pid
    at += 5 + info
  }
  return null
}

/// 跳过 PES 头，返回后面的基本流字节。
/// 头长度写在第 9 个字节（`PES_header_data_length`），不能按 PTS/DTS 有无去算。
function afterPESHeader(payload) {
  if (payload.length < 9) return null
  if (payload[0] !== 0x00 || payload[1] !== 0x00 || payload[2] !== 0x01) return null
  const at = 9 + payload[8]
  return at < payload.length ? payload.subarray(at) : null
}
