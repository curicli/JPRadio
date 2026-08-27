// 指纹计算的 worker。
//
// **为什么不在主线程**：12 秒 16 kHz 音频要做 ~1450 次 2048 点 FFT（Node 上实测 177 ms，
// 浏览器里两三百毫秒）。放主线程会让刻度尺动画、卡片滑动、音量条一起顿一下，
// 自动识曲每 8 秒一次的话就是每 8 秒顿一次。
//
// **import 的是服务端在用的同一份文件**：`web/lib/shazam.mjs`（服务端为它开了
// `/lib/shazam.mjs` 这个只读入口）。复制一份到 public/ 迟早两边会漂，
// 而这份代码的正确性是拿 ShazamKit 逐字节对照出来的 —— 只能有一份。
// 所以这个 worker 必须用 `new Worker(url, { type: 'module' })` 起。
import { signature, signatureURI, SIG_SAMPLE_RATE } from '/lib/shazam.mjs'

self.onmessage = (e) => {
  const { id, samples } = e.data ?? {}
  try {
    const bytes = signature(samples)
    self.postMessage({
      id,
      uri: signatureURI(bytes),
      samplems: Math.round((samples.length / SIG_SAMPLE_RATE) * 1000),
      sigBytes: bytes.length,
    })
  } catch (err) {
    self.postMessage({ id, error: String(err?.message ?? err) })
  }
}
