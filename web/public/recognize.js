// 识曲（web 版）。对应 iOS 端 `RadioPlayer.swift` 里的 `SongRecognizer`。
//
// 一轮识曲跨三个地方，缺一不可：
//   1. `/api/snippet/<台>`（服务端）抓 16 秒刚播出的音频，回裸 ADTS AAC；
//   2. 这里解码 → 混单声道 → 重采样到 16 kHz → **裁到 12 秒**；
//   3. `sig-worker.js` 算指纹（用的就是服务端那份 `lib/shazam.mjs`），
//      再 POST 给 `/api/recognize`，由服务端去打 `amp.shazam.com`。
//
// **为什么不在浏览器里 tap `<audio>`**：Safari 播原生 HLS 时
// `createMediaElementSource` 拿到的是静音（音频被媒体管线独占，页面反而没声了），
// iPhone 上又没有普通 MSE 可以退回 hls.js 走 Web Audio。分片本来就是我们代理的，
// 让服务端多下一份最省事 —— iOS 端 `LiveRecorder.snippet` 也是这么干的。
//
// **12 秒是硬上限**，不是随手取的：整段 ~20 秒的指纹上游只回一个没有 `track` 的
// `200`，跟「这首歌不在库里」长得一模一样（iOS 上试出来的：20s → no match，
// 12s / 5s → 正确曲名）。所以宁可多抓少交。
//
// **代价**：每一轮都要真下 16 秒音频，等于给流量翻一倍。自动识曲因此按
// 「匹配上就歇 30 秒、没匹配上歇 8 秒」的节奏走，跟 iOS 端一致。

const RKEY = { auto: 'autoRecognize' }

const SIG_RATE = 16_000
const SNIPPET_SECONDS = 16          // 服务端抓多少（宁可多抓，裁短在浏览器做）
const SIG_SECONDS = 12              // 交给上游的长度：见上面「硬上限」
const AFTER_MATCH_MS = 30_000
const AFTER_MISS_MS = 8_000
const AUTO_FAILURE_LIMIT = 3        // 自动识曲连错几次就收手

const rec = {
  auto: localStorage.getItem(RKEY.auto) !== '0',   // 默认开，跟 iOS 端一样
  loop: false,        // 自动识曲的循环是否在跑
  running: false,     // 有一轮正在进行
  timer: null,
  failures: 0,
  worker: null,
  seq: 0,
  pending: new Map(),
}

// MARK: - 一轮识曲

async function oneRound() {
  const s = currentStation()
  if (!s) throw new Error(T('identifyNoStation'))
  const res = await fetch(snippetURL(s))
  if (!res.ok) throw new Error((await res.text()).slice(0, 200))
  const bytes = await res.arrayBuffer()
  if (bytes.byteLength < 4096) throw new Error(T('identifyTooShort', bytes.byteLength))
  const samples = await to16kMono(bytes, SIG_SECONDS)
  const sig = await fingerprint(samples)
  const answer = await fetch('/api/recognize', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ uri: sig.uri, samplems: sig.samplems }),
  })
  const doc = await answer.json().catch(() => null)
  if (!answer.ok) throw new Error(doc?.error ?? `HTTP ${answer.status}`)
  return doc?.match ?? null
}

function snippetURL(s) {
  const base = `/api/snippet/${encodeURIComponent(s.id)}?seconds=${SNIPPET_SECONDS}`
  if (!state.archive) return base
  // 存档：要的是播放头**刚放过**的那一段，所以窗口往前挪一整段
  // （服务端从 `start` 往后给，我们又只取末尾 12 秒 → 正好是刚听到的 12 秒）。
  const at = state.archive.start + Math.max(0, audio.currentTime) * 1000 - SNIPPET_SECONDS * 1000
  return `${base}&start=${Math.round(Math.max(state.archive.start, at))}`
}

// MARK: - 解码与重采样
//
// 靠的是规范里那条「`decodeAudioData` 把结果重采样到 context 的采样率」：
// 拿一个 16 kHz 的 OfflineAudioContext 去解，重采样就由浏览器自己那套
// （给音频文件用的、质量好的）重采样器完成了 —— 跟 iOS 端交给 `AVAudioConverter`
// 是同一个道理，我们不用手写一个。

/// 分片字节 → 末尾 `seconds` 秒的 16 kHz 单声道 Float32。
async function to16kMono(bytes, seconds) {
  const Offline = self.OfflineAudioContext ?? self.webkitOfflineAudioContext
  if (!Offline) throw new Error('这个浏览器没有 OfflineAudioContext')
  let buf = await decodeAudio(new Offline(1, 128, SIG_RATE), bytes)
  // 万一某个浏览器不按 context 采样率解（回来还是 44.1/48 kHz），走退路。
  if (buf.sampleRate !== SIG_RATE) buf = await resample(Offline, buf, SIG_RATE)
  return trimMono(buf, seconds)
}

/// `decodeAudioData` / `startRendering` 在老 Safari 上只有回调式，新的两种都有 ——
/// 两种都接一下，比嗅探版本可靠。
const decodeAudio = (ctx, bytes) => new Promise((resolve, reject) => {
  const p = ctx.decodeAudioData(bytes, resolve, (e) => reject(new Error(
    `解不开这段音频（${e?.message ?? 'decodeAudioData 失败'}）`)))
  if (p && typeof p.then === 'function') p.then(resolve, reject)
})

const render = (ctx) => new Promise((resolve, reject) => {
  ctx.oncomplete = (e) => resolve(e.renderedBuffer)
  const p = ctx.startRendering()
  if (p && typeof p.then === 'function') p.then(resolve, reject)
})

/// 退路：渲染一遍来换采样率。
///
/// 必须**先在原采样率上低通**再降采样：Chrome 的 `AudioBufferSourceNode` 换率时
/// 是线性插值，不去掉 8 kHz 以上的东西，10.5~15.75 kHz 会折回 250~5500 Hz ——
/// 那正是四个频段所在的范围，峰值会跟着乱。三级 7 kHz 双二阶 ≈ 36 dB/oct。
async function resample(Offline, buf, rate) {
  const guard = new Offline(1, buf.length, buf.sampleRate)
  let node = sourceNode(guard, buf)
  for (let i = 0; i < 3; i++) {
    const lp = guard.createBiquadFilter()
    lp.type = 'lowpass'
    lp.frequency.value = 7000
    lp.Q.value = Math.SQRT1_2
    node.connect(lp)
    node = lp
  }
  node.connect(guard.destination)
  const filtered = await render(guard)
  const down = new Offline(1, Math.max(1, Math.round(filtered.duration * rate)), rate)
  sourceNode(down, filtered).connect(down.destination)
  return await render(down)
}

/// 起一个放完就算的 buffer source。名字别叫 `play` —— app.js 里那个 `play()` 是播放，
/// 两个 script 共用一个全局作用域，同名会把它盖掉。
function sourceNode(ctx, buf) {
  const src = ctx.createBufferSource()
  src.buffer = buf
  src.start(0)
  return src
}

/// 取**末尾** `seconds` 秒并混成单声道。
/// 取末尾而不是开头：那一段最贴近用户此刻听到的地方，而且拼出来的开头
/// 可能是半个 AAC 帧。返回的必须是一个新数组 —— 它要被转移给 worker。
function trimMono(buf, seconds) {
  const want = Math.min(buf.length, Math.round(seconds * buf.sampleRate))
  const from = buf.length - want
  const out = new Float32Array(want)
  for (let ch = 0; ch < buf.numberOfChannels; ch++) {
    const data = buf.getChannelData(ch)
    for (let i = 0; i < want; i++) out[i] += data[from + i]
  }
  if (buf.numberOfChannels > 1) {
    for (let i = 0; i < want; i++) out[i] /= buf.numberOfChannels
  }
  return out
}

// MARK: - worker

/// 把样本交给 worker 算指纹。一个 worker 一直留着复用（每轮新建要重新拉一次
/// `lib/shazam.mjs` 并重新编译）。样本数组直接转移过去，不复制。
function fingerprint(samples) {
  if (!rec.worker) {
    rec.worker = new Worker('sig-worker.js', { type: 'module' })
    rec.worker.onmessage = (e) => {
      const waiting = rec.pending.get(e.data?.id)
      if (!waiting) return
      rec.pending.delete(e.data.id)
      if (e.data.error) waiting.reject(new Error(e.data.error))
      else waiting.resolve(e.data)
    }
    rec.worker.onerror = (e) => {
      // module worker 起不来（浏览器太老）就在这里冒出来，而且是一次性的：
      // 把等着的都判死，扔掉这个 worker，下一轮重新建。
      const err = new Error(e?.message || 'worker 起不来（浏览器可能不支持 module worker）')
      for (const waiting of rec.pending.values()) waiting.reject(err)
      rec.pending.clear()
      rec.worker?.terminate()
      rec.worker = null
    }
  }
  const id = ++rec.seq
  return new Promise((resolve, reject) => {
    rec.pending.set(id, { resolve, reject })
    rec.worker.postMessage({ id, samples }, [samples.buffer])
  })
}

// MARK: - 节奏

/// 手动识曲：立刻来一轮，而且**要有界面反馈**（这是与自动识曲的区别之一）。
function identifyNow() {
  if (rec.running) return
  stopTimer()
  rec.failures = 0
  runRound({ quiet: false })
}

async function runRound({ quiet }) {
  rec.running = true
  if (!quiet) showStatus(T('identifying'))
  try {
    const match = await oneRound()
    rec.failures = 0
    if (match) showMatch(match)
    else if (!quiet) showStatus(T('noMatch'))
    // 匹配上了就歇久一点：同一首歌没必要每 8 秒问一次（每次都是 16 秒音频的流量）。
    scheduleNext(match ? AFTER_MATCH_MS : AFTER_MISS_MS)
  } catch (e) {
    const detail = String(e?.message ?? e)
    rec.failures++
    console.warn('[识曲]', detail)
    if (!quiet) showStatus(`${T('identifyFailed')}：${detail}`)
    // 自动识曲连错 3 次就收手（iOS 端 autoFailureLimit 也是 3）：多半是这个台的音频
    // 浏览器解不开、或者上游把我们挡了，继续每 8 秒重试只是白烧流量。
    if (rec.failures >= AUTO_FAILURE_LIMIT) {
      const wasLooping = rec.loop
      stopLoop()
      if (wasLooping) showStatus(`${T('identifyGaveUp')}：${detail}`)
    } else {
      scheduleNext(AFTER_MISS_MS)
    }
  } finally {
    rec.running = false
  }
}

function scheduleNext(ms) {
  stopTimer()
  if (!rec.loop) return
  rec.timer = setTimeout(() => { if (rec.loop && !rec.running) runRound({ quiet: true }) }, ms)
}

function stopTimer() {
  if (rec.timer) clearTimeout(rec.timer)
  rec.timer = null
}

/// 自动识曲。跟 iOS 端一样有三点刻意的不同：不退回麦克风（浏览器里更没道理）、
/// 不显示「识别中…」（每 8 秒闪一下太吵）、连错 3 次就收手。
function startLoop() {
  if (!rec.auto || rec.loop || !state.playing || !currentStation()) return
  rec.loop = true
  rec.failures = 0
  if (!rec.running) runRound({ quiet: true })
}

function stopLoop() {
  rec.loop = false
  stopTimer()
  updateAutoButton()
}

function setAuto(on) {
  rec.auto = on
  localStorage.setItem(RKEY.auto, on ? '1' : '0')
  updateAutoButton()
  if (on) startLoop()
  else stopLoop()
}

// MARK: - 界面

function showStatus(text) {
  const card = $('song')
  card.hidden = false
  card.classList.add('plain')
  $('song-art').hidden = true
  $('song-title').textContent = text
  $('song-artist').textContent = ''
  $('song-link').hidden = true
}

function showMatch(m) {
  const card = $('song')
  card.hidden = false
  card.classList.remove('plain')
  const art = $('song-art')
  if (m.artwork) {
    art.src = m.artwork          // 封面是 mzstatic 的图，只是显示，不用像台标那样读像素
    art.hidden = false
  } else {
    art.hidden = true
    art.removeAttribute('src')
  }
  $('song-title').textContent = m.title
  $('song-artist').textContent = m.artist
  const link = $('song-link')
  link.hidden = !m.appleMusic
  if (m.appleMusic) {
    link.href = m.appleMusic
    link.textContent = T('appleMusic')
  }
}

function clearCard() {
  $('song').hidden = true
  $('song-art').removeAttribute('src')
}

function updateAutoButton() {
  const b = $('auto-identify')
  if (!b) return
  b.classList.toggle('on', rec.auto)
  b.setAttribute('aria-pressed', String(rec.auto))
  b.title = T(rec.auto ? 'autoIdentifyOn' : 'autoIdentifyOff')
}

function applyRecognizeLanguage() {
  for (const [id, key] of [['identify', 'identify'], ['song-close', 'close']]) {
    const b = $(id)
    b.title = T(key)
    b.setAttribute('aria-label', T(key))
  }
  updateAutoButton()
  const link = $('song-link')
  if (!link.hidden) link.textContent = T('appleMusic')
}

// MARK: - 接到 app.js 上
//
// app.js 是同一个全局作用域里的另一个 script（`defer`，先跑），所以这里能直接用
// 它的 `state` / `audio` / `currentStation` / `T`。反过来它调这边要经过
// `window.recognizeHooks` —— 加载顺序上 app.js 的 `main()` 是异步的，
// 等它跑到调用点时这个对象已经挂好了。

window.recognizeHooks = {
  /// 换台：上一首的结果作废，失败计数归零（上个台失败不该算到这个台头上）。
  stationChanged() {
    clearCard()
    stopLoop()
    rec.failures = 0
    if (state.playing) startLoop()
  },
  /// 开始 / 暂停。暂停时停掉循环：那时抓的是直播边缘，跟用户听的已经不是一回事，
  /// 而且为一个暂停着的页面每 8 秒下 16 秒音频纯属浪费。
  playbackChanged(playing) {
    if (playing) startLoop()
    else stopLoop()
  },
  applyLanguage: applyRecognizeLanguage,
}

$('identify').onclick = identifyNow
$('auto-identify').onclick = () => setAuto(!rec.auto)
$('song-close').onclick = clearCard
updateAutoButton()
