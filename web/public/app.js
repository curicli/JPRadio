// JPRadio web 前端。所有网络请求都打本机的 `web/server.mjs`（同源），
// radiko 鉴权 / 加头 / 改写 m3u8 全在服务端做 —— 浏览器里做不到，见 server.mjs 顶部说明。
//
// 与 iOS 端的对应关系：拨盘条＝`TunerView` 的地区选择，卡片轮播＝`StationPagerView`，
// 刻度尺＝`FrequencyDialView`（dial.js），番組表抽屉＝`ProgramSheet`，
// 识曲＝`SongRecognizer`（recognize.js，走服务端抓音 + 浏览器算指纹），
// 录制 / 预约 / 录音库 / 节目收藏＝`RecordingsSheet` 那一套（library.js，录制跑在服务端）。
//
// **没有搬过来的**：节目提醒（本地通知）—— LAN 上的 http:// 不是安全上下文，
// 而且提醒要页面开着才响，摆个点不动的开关没意义。README 里写清楚了。

const $ = (id) => document.getElementById(id)
const el = (tag, cls, text) => {
  const n = document.createElement(tag)
  if (cls) n.className = cls
  if (text != null) n.textContent = text
  return n
}

const KEY = { fav: 'favorites', dial: 'lastDial', station: 'lastStation', vol: 'volume' }

const store = {
  favorites() {
    try {
      const v = JSON.parse(localStorage.getItem(KEY.fav) ?? '[]')
      return new Set(Array.isArray(v) ? v : [])
    } catch {
      return new Set()
    }
  },
  saveFavorites(set) {
    localStorage.setItem(KEY.fav, JSON.stringify([...set]))
  },
}

const state = {
  doc: null,
  stations: new Map(),   // id → station
  dials: [],             // { id, name, subtitle, kind, stations[] }
  dialIndex: 0,
  stationID: null,
  favorites: store.favorites(),
  playing: false,
  /// 正在放的是存档（タイムフリー）时记下这档节目，播放条上要显示、也用来禁掉看门狗重连。
  archive: null,
  /// 正在放的是录音库里的一条文件（`/rec/<id>`）时记下它。文件播放不走 HLS、
  /// 也不能重连（放完就是放完了），所以看门狗与 hls.js 两条路都要绕开。
  file: null,
  day: 0,
  hls: null,
  dial: null,
}

const audio = $('audio')

// MARK: - 台表与拨盘

/// 真实拨盘（来自 stations.json，与 app 同一份）+ 两条合成拨盘：★收藏、全部。
/// 合成拨盘在这里拼而不进 stations.json，是因为收藏是每台浏览器自己的事。
function buildDials() {
  const real = state.doc.regions.map((r) => ({ ...r, synthetic: false }))
  const all = real.flatMap((r) => r.stations)
  const favorites = {
    id: '★',
    name: '★',
    subtitle: T('favorites'),
    kind: 'mixed',
    synthetic: true,
    stations: all.filter((s) => state.favorites.has(s.id)),
  }
  const everything = {
    id: 'ALL',
    name: T('allRegion'),
    subtitle: T('stationCount', all.length),
    kind: 'mixed',
    synthetic: true,
    stations: all,
  }
  state.dials = [favorites, everything, ...real]
}

const currentDial = () => state.dials[state.dialIndex] ?? state.dials[0]
const currentStation = () => state.stations.get(state.stationID)

function renderDials() {
  const box = $('dials')
  box.textContent = ''
  state.dials.forEach((d, i) => {
    // 两行（大名字 + 小副标题），跟 iOS 端 regionBar 的胶囊一样。
    const b = el('button', d.id === '★' ? 'favdial' : null)
    b.append(el('span', 'dn', d.name))
    b.append(el('span', 'ds', d.subtitle))
    if (i === state.dialIndex) b.setAttribute('aria-current', 'true')
    b.title = d.synthetic ? d.subtitle : T('stationCount', d.stations.length)
    b.onclick = () => selectDial(i)
    box.append(b)
  })
}

function selectDial(i) {
  state.dialIndex = i
  localStorage.setItem(KEY.dial, currentDial().id)
  const list = currentDial().stations
  // 换拨盘时尽量留在当前台上（★ 与「全部」之间来回切最常见）；不在这条拨盘上就取第一台。
  const keep = list.some((s) => s.id === state.stationID)
  renderDials()
  renderCards()
  state.dial.setStations(list, keep ? state.stationID : list[0]?.id ?? null)
  if (!keep) selectStation(list[0]?.id ?? null, { scroll: true })
  else scrollToCard(state.stationID)
}

// MARK: - 卡片轮播

/// 台标一律走 `/api/image` 反代：直接取 radiko/listenradio 会被 CORS 挡住（拿不到像素就
/// 没法取主色），smartstream 那边还看 Referer。
const proxiedLogo = (url) => (url ? `/api/image?u=${encodeURIComponent(url)}` : '')

function renderCards() {
  const box = $('cards')
  box.textContent = ''
  const list = currentDial().stations
  if (!list.length) {
    box.append(el('p', 'err', T('noFavorites')))
    renderStationList()
    return
  }
  for (const s of list) box.append(stationCard(s))
  scrollToCard(state.stationID)
  renderStationList()
}

/// 一张卡片 = 白色台标徽章（LIVE 灯 + ★）+ 下面一组文字（频率 / 台名 / 标语 / 正在播出）。
/// 与 iOS 端 `StationCardView` 一一对应。
function stationCard(s) {
  const card = el('div', 'card')
  card.dataset.id = s.id
  if (s.id === state.stationID) card.classList.add('on')

  const badge = el('div', 'badge')
  if (s.logo) {
    const img = el('img')
    img.src = proxiedLogo(s.logo)
    img.alt = s.name
    img.loading = 'lazy'
    img.crossOrigin = 'anonymous'
    // radiko 有几个台标是 404：换成台名占位，别留一张空白牌子。
    img.onerror = () => { img.remove(); badge.prepend(el('div', 'nologo', s.name)) }
    badge.append(img)
  } else {
    badge.append(el('div', 'nologo', s.name))
  }
  badge.append(el('span', 'live', 'LIVE'))
  // ★ 收藏挪到卡片上（iOS 端也在这个位置）。只有当前那张卡显示，所以直接对当前台操作。
  const star = el('button', 'cfav')
  star.onclick = (e) => { e.stopPropagation(); toggleFavorite() }
  badge.append(star)
  card.append(badge)

  const info = el('div', 'info')
  // 直连台的频率是为了排刻度合成出来的，不能当真读数展示（与 iOS 端同一条规矩）。
  if (!s.direct) {
    const line = el('div', 'freqline')
    line.append(el('span', 'unit', 'FM'))
    line.append(el('span', 'freq rounded', s.frequency.toFixed(1)))
    line.append(el('span', 'unit', 'MHz'))
    info.append(line)
  }
  info.append(el('div', 'name', s.name))
  info.append(el('div', 'tag', s.tagline))
  const now = el('div', 'now', '')
  now.dataset.now = s.id
  info.append(now)
  card.append(info)

  card.onclick = () => {
    if (s.id === state.stationID) togglePlay()
    else selectStation(s.id, { scroll: true })
  }
  return card
}

/// 卡片相对滚动容器的位置。不能直接用 `offsetLeft` —— 它算的是相对 body 的位置，
/// 宽屏下 `#app` 居中会带进上百像素的偏移，卡片会停在偏一边的地方。
const cardOffset = (card, box) => card.offsetLeft - box.offsetLeft

function scrollToCard(id) {
  const box = $('cards')
  const card = box.querySelector(`.card[data-id="${CSS.escape(id ?? '')}"]`)
  if (!card) return
  box.scrollTo({
    left: cardOffset(card, box) - (box.clientWidth - card.clientWidth) / 2,
    behavior: 'smooth',
  })
}

// 滑动停下来后把中间那张卡设为选中台（scrollend 只有新浏览器有，退回去抖动去重）。
let scrollTimer
$('cards').addEventListener('scroll', () => {
  clearTimeout(scrollTimer)
  scrollTimer = setTimeout(() => {
    const box = $('cards')
    const mid = box.scrollLeft + box.clientWidth / 2
    let best = null
    for (const c of box.querySelectorAll('.card')) {
      const d = Math.abs(cardOffset(c, box) + c.clientWidth / 2 - mid)
      if (!best || d < best.d) best = { d, id: c.dataset.id }
    }
    if (best && best.id !== state.stationID) selectStation(best.id, { scroll: false })
  }, 140)
})

// MARK: - 侧栏台列表（只在宽屏出现）
//
// 鼠标用户不该被逼着横向滑一列卡片，所以宽屏另给一条竖列表：当前拨盘的全部电台，
// 点一行就换台（卡片轮播会跟着滚过去）。

function renderStationList() {
  const box = $('list')
  if (!box) return
  box.textContent = ''
  const d = currentDial()
  $('list-head').textContent = `${d.name} · ${T('stationCount', d.stations.length)}`
  for (const s of d.stations) {
    const row = el('button', 'srow')
    row.dataset.id = s.id
    row.setAttribute('role', 'option')
    if (s.id === state.stationID) row.classList.add('on')
    row.setAttribute('aria-selected', String(s.id === state.stationID))
    // 缺图（radiko 有几个 logo 是 404）时换成同尺寸的空牌子，不是直接删掉 ——
    // 删掉的话那一行的文字会比别的行往左窜一截。
    if (s.logo) {
      const img = el('img')
      img.src = proxiedLogo(s.logo)
      img.alt = ''
      img.loading = 'lazy'
      img.onerror = () => img.replaceWith(el('div', 'slogo-blank'))
      row.append(img)
    } else {
      row.append(el('div', 'slogo-blank'))
    }
    const body = el('div', 'sbody')
    body.append(el('div', 'sname', s.name))
    body.append(el('div', 'stag', s.tagline))
    row.append(body)
    if (!s.direct) row.append(el('div', 'sfreq', s.frequency.toFixed(1)))
    row.onclick = () => selectStation(s.id, { scroll: true })
    box.append(row)
  }
}

/// 只挪高亮，不重建（换台很频繁，滑一次卡片就要动好几回）。
function paintStationList() {
  for (const r of $('list').querySelectorAll('.srow')) {
    const on = r.dataset.id === state.stationID
    r.classList.toggle('on', on)
    r.setAttribute('aria-selected', String(on))
  }
}

// MARK: - 选台

function selectStation(id, { scroll } = {}) {
  if (!id) return
  const wasPlaying = state.playing
  state.stationID = id
  localStorage.setItem(KEY.station, id)
  for (const c of $('cards').querySelectorAll('.card')) {
    c.classList.toggle('on', c.dataset.id === id)
  }
  state.dial?.setSelected(id)
  if (scroll) scrollToCard(id)
  paintStationList()
  updateFavButton()
  paintGlow()
  // 换台时清掉存档 / 录音回放：进度条、状态文案都要回到直播那一套。
  state.archive = null
  state.file = null
  audio.controls = false
  $('live-back').hidden = true
  if (wasPlaying) play()
  else setStatus(T('statusIdle'))
  loadNowPlaying(id)
  // 识曲：上一首的结果作废，自动识曲对着新台重新开始（recognize.js）。
  window.recognizeHooks?.stationChanged?.()
  // 录制按钮是「当前台在不在录」，换台就得重画（library.js）。
  window.libraryHooks?.stationChanged?.()
}

/// ★ 在卡片右上角（不再是独立按钮），所以「重画收藏」= 重画当前那张卡上的星。
function updateFavButton() {
  const on = state.favorites.has(state.stationID)
  for (const b of $('cards').querySelectorAll('.card.on .cfav')) {
    b.textContent = on ? '★' : '☆'
    b.setAttribute('aria-pressed', String(on))
    b.title = T('favorite')
    b.setAttribute('aria-label', T('favorite'))
  }
}

function toggleFavorite() {
  if (!state.stationID) return
  if (state.favorites.has(state.stationID)) state.favorites.delete(state.stationID)
  else state.favorites.add(state.stationID)
  store.saveFavorites(state.favorites)
  updateFavButton()
  // ★ 拨盘的成员变了：重建拨盘表，并保持当前拨盘不动（按 id 找回来，索引会漂）。
  const keepID = currentDial().id
  buildDials()
  const i = state.dials.findIndex((d) => d.id === keepID)
  state.dialIndex = i >= 0 ? i : 0
  renderDials()
  if (currentDial().id === '★') {
    renderCards()
    state.dial.setStations(currentDial().stations, state.stationID)
  }
}

// MARK: - 台标主色（背景光）

const glowCache = new Map()

/// 取台标的主色铺背景（对应 iOS 端 ColorExtractor）。缩到 16×16 再取平均并拔高饱和度：
/// 台标多是白底 + 一小块彩色 logo，直接平均会得到一片脏白，所以先滤掉接近白/黑的像素。
async function dominantColor(url) {
  if (glowCache.has(url)) return glowCache.get(url)
  const color = await new Promise((resolve) => {
    const img = new Image()
    img.crossOrigin = 'anonymous'
    img.onload = () => {
      try {
        const c = document.createElement('canvas')
        c.width = c.height = 16
        const g = c.getContext('2d', { willReadFrequently: true })
        g.drawImage(img, 0, 0, 16, 16)
        const { data } = g.getImageData(0, 0, 16, 16)
        let r = 0, gg = 0, b = 0, n = 0
        for (let i = 0; i < data.length; i += 4) {
          const [pr, pg, pb, pa] = [data[i], data[i + 1], data[i + 2], data[i + 3]]
          if (pa < 128) continue
          const max = Math.max(pr, pg, pb), min = Math.min(pr, pg, pb)
          if (max > 240 && max - min < 24) continue // 近白
          if (max < 28) continue                    // 近黑
          r += pr; gg += pg; b += pb; n++
        }
        if (!n) return resolve(null)
        resolve([Math.round(r / n), Math.round(gg / n), Math.round(b / n)])
      } catch {
        resolve(null) // 画布被污染（反代没给同源像素）就算了，背景保持默认
      }
    }
    img.onerror = () => resolve(null)
    img.src = proxiedLogo(url)
  })
  glowCache.set(url, color)
  return color
}

async function paintGlow() {
  const s = currentStation()
  const rgb = s?.logo ? await dominantColor(s.logo) : null
  document.documentElement.style.setProperty(
    '--glow',
    rgb ? `rgba(${rgb[0]}, ${rgb[1]}, ${rgb[2]}, .38)` : 'rgba(255, 102, 46, .18)',
  )
}

// MARK: - 播放

const nativeHLS = () => !!audio.canPlayType('application/vnd.apple.mpegurl')

function setStatus(text, live = false) {
  const p = $('status')
  p.textContent = text
  p.classList.toggle('live', live)
}

/// 播放键的图标是两个内嵌 SVG，用 `.playing` 决定露哪一个（别再写 textContent —— 那会把
/// 两个 <svg> 一起抹掉）。顺手点亮当前卡片上的 LIVE 灯：只有真的在放直播才亮，
/// 放存档 / 放录音都不是直播。
function paintPlay() {
  const b = $('play')
  b.classList.toggle('playing', state.playing)
  const label = T(state.playing ? 'pause' : 'play')
  b.setAttribute('aria-label', label)
  b.title = label
  const liveNow = state.playing && !state.file && !state.archive
  for (const c of $('cards').querySelectorAll('.card')) {
    c.classList.toggle('playing', liveNow && c.dataset.id === state.stationID)
  }
}

function destroyHls() {
  if (state.hls) {
    state.hls.destroy()
    state.hls = null
  }
}

/// 把一条流接到 `<audio>` 上。Safari 原生放 HLS；其它浏览器交给 hls.js。
/// `plain` 是「这不是 HLS，是一个普通音频文件」（录音库里的 `/rec/<id>`）——
/// 交给 hls.js 只会解析失败，必须直接给 `<audio>`。
function attach(url, { plain = false } = {}) {
  destroyHls()
  if (plain || nativeHLS()) {
    audio.src = url
    audio.load()
    return true
  }
  if (window.Hls?.isSupported()) {
    // 上一次可能是在放录音文件（src 还指着 /rec/…）：留着会和 hls.js 抢同一个元素。
    audio.removeAttribute('src')
    const hls = new window.Hls({ lowLatencyMode: false, enableWorker: true })
    hls.loadSource(url)
    hls.attachMedia(audio)
    hls.on(window.Hls.Events.ERROR, (_e, data) => {
      if (!data.fatal) return
      // 网络类错误先让 hls.js 自己重开一次加载；媒体错误试着恢复；都不行才走我们的重连。
      if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) hls.startLoad()
      else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR) hls.recoverMediaError()
      else reconnect()
    })
    state.hls = hls
    return true
  }
  setStatus(T('playFailed'))
  return false
}

function liveURLFor(station) {
  return `/stream/${encodeURIComponent(station.id)}.m3u8`
}

/// 现在该显示的播放状态。录制那边闪完一句提示后要把这一行交还给它（library.js）。
function playbackStatus() {
  if (!state.playing) return { text: T('statusIdle'), live: false }
  if (state.file) return { text: T('playingFile', state.file.title), live: true }
  if (state.archive) return { text: T('playingArchive', state.archive.title), live: true }
  return { text: T('live'), live: true }
}

async function play() {
  const s = currentStation()
  if (!s && !state.file) return
  setStatus(T('connecting'))
  const url = state.file
    ? `/rec/${encodeURIComponent(state.file.id)}`
    : state.archive
      ? `/timefree/${encodeURIComponent(s.id)}.m3u8?start=${state.archive.start}&end=${state.archive.end}`
      : liveURLFor(s)
  if (!attach(url, { plain: !!state.file })) return
  try {
    await audio.play()
    state.playing = true
    paintPlay()
    const st = playbackStatus()
    setStatus(st.text, st.live)
    // 看门狗只对直播有意义：存档与录音是有尽头的，播放头停下来就是放完了。
    if (!state.file && !state.archive) startWatchdog()
    updateMediaSession()
    // 放录音时不要开自动识曲：`/api/snippet` 抓的是那个台**现在**的直播边缘，
    // 跟正在放的这段录音根本不是同一段声音。
    window.recognizeHooks?.playbackChanged?.(!state.file)
  } catch (e) {
    // 正在自动重连的循环里失败（多半是网刚切、还没通）：别直接判死，交回 reconnect()
    // 按退避再试，次数上限也归它管 —— 与 iOS 端 startPlayback 的 catch 同一处理。
    if (attempts > 0 && !state.file) {
      reconnect()
      return
    }
    state.playing = false
    paintPlay()
    setStatus(`${T('playFailed')}（${e?.message ?? e}）`)
  }
}

function pause() {
  audio.pause()
  state.playing = false
  stopWatchdog()
  paintPlay()
  setStatus(T('paused'))
  // 暂停时停掉自动识曲：抓的是直播边缘，跟用户听到的已经不是一回事了。
  window.recognizeHooks?.playbackChanged?.(false)
}

function togglePlay() {
  if (state.playing) pause()
  else play()
}

// MARK: - 看门狗（直播静默中断的唯一可靠信号是「播放头不走了」）
//
// iOS 端为同一个毛病加过播放头看门狗（见 RadioPlayer.swift）：直播流被 CDN 掐掉时
// 播放器不报错、状态还停在「正在播放」，只有播放头不动。浏览器里同样如此，所以照搬：
// 2 秒一采样，卡满 12 秒（radiko 分片 5 秒，更短会把正常缓冲误判成断流）就重建这条流。
//
// 但「播放头不动」还不够：ListenRadio 的分片是 10 秒一片，缓冲一旦见底，播放头能停十几秒
// 等下一片 —— 那不是断流，重连反而会把已经缓好的东西丢掉。所以**缓冲区还在长**就算活着，
// 只有播放头与缓冲同时不动才判死。

const STALL_GRACE_MS = 12_000
const MAX_RECONNECTS = 6
let watchdog = null
let lastTime = -1
let lastBuffered = -1
let lastProgressAt = 0
let attempts = 0
let lastReconnectAt = 0

function startWatchdog() {
  stopWatchdog()
  lastTime = -1
  lastBuffered = -1
  lastProgressAt = Date.now()
  watchdog = setInterval(checkProgress, 2000)
}

function stopWatchdog() {
  if (watchdog) clearInterval(watchdog)
  watchdog = null
}

/// 缓冲区末端（还在下载的话它会一直往前走）。
function bufferedEnd() {
  const b = audio.buffered
  return b.length ? b.end(b.length - 1) : 0
}

function checkProgress() {
  if (!state.playing) return
  const t = audio.currentTime
  if (!Number.isFinite(t)) return
  const end = bufferedEnd()
  const moved = lastTime < 0 || t - lastTime > 0.25
  const filling = lastBuffered < 0 || end - lastBuffered > 0.25
  if (moved || filling) {
    lastTime = t
    lastBuffered = end
    lastProgressAt = Date.now()
    // 重连之后稳定播够 30 秒，就把重连预算还回去。
    if (attempts > 0 && Date.now() - lastReconnectAt > 30_000) attempts = 0
    return
  }
  // 先试最便宜的一招：被系统按停了，推一把就回来。
  if (audio.paused) audio.play().catch(() => {})
  if (Date.now() - lastProgressAt >= STALL_GRACE_MS) reconnect()
}

/// 重建这条流。服务端每次请求都会重新加新鲜的 radiko token，所以「token 冻在流里」
/// 这个 iOS 上的死因在 web 版根本不存在，重连只是为了换掉抽风的连接。
function reconnect() {
  if (!state.playing) return
  stopWatchdog()
  if (attempts >= MAX_RECONNECTS) {
    state.playing = false
    paintPlay()
    setStatus(T('playFailed'))
    return
  }
  attempts++
  lastReconnectAt = Date.now()
  setStatus(T('connecting'))
  const backoff = Math.max(Math.min(2 ** (attempts - 1), 8) - 1, 0) * 1000
  setTimeout(() => { if (state.playing) play() }, backoff)
}

// 直播流「播完了」或报错，只可能是这条流没了 —— 立刻重连。
// 存档与录音是有尽头的：放完就是放完，报错也不该重连（重连会从头再放一遍）。
audio.addEventListener('ended', () => {
  if (state.file || state.archive) pause()
  else if (state.playing) reconnect()
})
audio.addEventListener('error', () => {
  if (!state.playing) return
  if (state.file || state.archive) {
    state.playing = false
    paintPlay()
    setStatus(T('playFailed'))
    return
  }
  reconnect()
})

// MARK: - 系统媒体控件（锁屏 / 耳机按键 / 菜单栏）

function updateMediaSession() {
  if (!('mediaSession' in navigator)) return
  const s = currentStation()
  if (!s) return
  navigator.mediaSession.metadata = new MediaMetadata({
    title: state.file?.title ?? state.archive?.title ?? s.name,
    artist: state.file || state.archive ? s.name : s.tagline,
    album: T('title'),
    artwork: s.logo ? [{ src: proxiedLogo(s.logo), sizes: '224x100', type: 'image/png' }] : [],
  })
  navigator.mediaSession.playbackState = state.playing ? 'playing' : 'paused'
  const set = (action, fn) => {
    try { navigator.mediaSession.setActionHandler(action, fn) } catch { /* 不支持就跳过 */ }
  }
  set('play', () => play())
  set('pause', () => pause())
  set('previoustrack', () => step(-1))
  set('nexttrack', () => step(1))
}

/// 上一台 / 下一台（在当前拨盘内绕圈）。
function step(delta) {
  const list = currentDial().stations
  if (!list.length) return
  const i = list.findIndex((s) => s.id === state.stationID)
  const next = list[((i < 0 ? 0 : i) + delta + list.length) % list.length]
  selectStation(next.id, { scroll: true })
}

// MARK: - 睡眠定时器
//
// 工具条上那个槽位没有自己的按钮：一个原生 <select> 透明地铺在上面（见 style.css），
// 所以外观是我们的、下拉是系统的。倒计时写在槽位下面那行小字上（iOS 端也是这么显示的）。

const SLEEP_OPTIONS = [0, 15, 30, 45, 60, 90, 120]

let sleepTimer = null
let sleepTick = null
let sleepEndsAt = 0

const mmss = (seconds) => {
  const s = Math.max(0, Math.round(seconds))
  return `${String(Math.floor(s / 60)).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`
}

function setupSleepSelect() {
  const sel = $('sleep')
  // 语言一变这个函数会重跑：选项要重建，但**已经定好的时长不能被抹掉**
  // （抹掉了下拉显示「关」而定时器还在跑，等于骗人）。
  const keep = sel.value || '0'
  sel.textContent = ''
  for (const m of SLEEP_OPTIONS) {
    const o = el('option', null, m === 0 ? T('sleepOff') : T('minutesStop', m))
    o.value = String(m)
    sel.append(o)
  }
  sel.value = SLEEP_OPTIONS.map(String).includes(keep) ? keep : '0'
  sel.onchange = () => armSleep(Number(sel.value))
  paintSleep()
}

function armSleep(minutes) {
  clearTimeout(sleepTimer)
  clearInterval(sleepTick)
  sleepTimer = sleepTick = null
  sleepEndsAt = minutes > 0 ? Date.now() + minutes * 60_000 : 0
  if (minutes > 0) {
    sleepTimer = setTimeout(() => { pause(); $('sleep').value = '0'; armSleep(0) }, minutes * 60_000)
    sleepTick = setInterval(paintSleep, 1000)
  }
  paintSleep()
}

function paintSleep() {
  const slot = $('sleep-slot')
  const left = sleepEndsAt - Date.now()
  const on = left > 0
  slot.classList.toggle('on', on)
  $('sleep-cap').textContent = on ? mmss(left / 1000) : ''
  const label = on ? T('minutesStop', Math.ceil(left / 60_000)) : T('sleepOff')
  slot.title = label
  slot.setAttribute('aria-label', label)
}

// MARK: - 时间显示（一律 JST）

/// 日本时间的 HH:mm。番組表的时刻本来就是 JST，用浏览器本地时区显示会整体错几小时。
const jstTime = (epoch) =>
  new Intl.DateTimeFormat(L.locale, {
    timeZone: 'Asia/Tokyo', hour: '2-digit', minute: '2-digit', hour12: false,
  }).format(new Date(epoch))

const jstDate = (epoch) =>
  new Intl.DateTimeFormat(L.locale, {
    timeZone: 'Asia/Tokyo', month: 'short', day: 'numeric', weekday: 'short',
  }).format(new Date(epoch))

function dayLabel(day, dayStart) {
  const relative = day === 0 ? T('today') : day === -1 ? T('yesterday') : day === 1 ? T('tomorrow') : null
  const date = jstDate(dayStart)
  return relative ? `${relative} · ${date}` : date
}

// MARK: - 卡片上的「正在播出」

const nowCache = new Map()
const NOW_TTL_MS = 600_000

async function loadNowPlaying(stationID) {
  try {
    const hitCache = nowCache.get(stationID)
    // 一天的表拿一次就够（每分钟只是重新判断哪一档在播）；10 分钟后过期，跨放送日也能换表。
    const fresh = hitCache && Date.now() - hitCache.at < NOW_TTL_MS
    const list = fresh ? hitCache.list : (await fetchProgramDoc(stationID, 0)).programs ?? []
    if (!fresh) nowCache.set(stationID, { at: Date.now(), list })
    const now = Date.now()
    const hit = list.find((p) => p.start <= now && (p.end ?? p.start + 3600_000) > now)
    const slot = $('cards').querySelector(`[data-now="${CSS.escape(stationID)}"]`)
    if (slot) slot.textContent = hit ? `${jstTime(hit.start)} ${hit.title}` : ''
  } catch {
    // 番組表拿不到不该影响听 —— 卡片上那一行留空即可（抽屉里才报详细原因）。
  }
}

/// `{station, day, dayStart, date, programs}`；失败时抛出服务端给的真实原因。
async function fetchProgramDoc(stationID, day) {
  const res = await fetch(`/api/programs?station=${encodeURIComponent(stationID)}&day=${day}`)
  const doc = await res.json().catch(() => null)
  if (!res.ok) throw new Error(doc?.error ?? `HTTP ${res.status}`)
  return doc
}

// MARK: - 番組表抽屉

function openSheet() {
  if (!state.stationID) return
  state.day = 0
  $('sheet').hidden = false
  $('sheet-note').textContent = `${T('jstNote')} · ${T('timefree')}`
  loadSheet()
}

function closeSheet() {
  $('sheet').hidden = true
}

async function loadSheet() {
  const s = currentStation()
  if (!s) return
  $('sheet-title').textContent = `${s.name} · ${T('program')}`
  $('day-label').textContent = '—'
  const body = $('sheet-body')
  body.textContent = ''
  body.append(el('p', null, T('loading')))
  try {
    const doc = await fetchProgramDoc(s.id, state.day)
    $('day-label').textContent = dayLabel(state.day, doc.dayStart)
    renderPrograms(body, doc.programs ?? [], s)
  } catch (e) {
    body.textContent = ''
    // 失败原因原样显示（HTTP 状态 / 解析到哪一步）：否则永远查不出是网络、格式变了还是键名没对上。
    body.append(el('p', 'err', `${T('loadFailed')}\n${e.message}`))
    const retry = el('button', 'pill', T('retry'))
    retry.onclick = loadSheet
    body.append(retry)
  }
}

function renderPrograms(body, list, station) {
  if (!list.length) {
    body.append(el('p', null, T('noProgram')))
    return
  }
  const now = Date.now()
  for (const p of list) {
    const row = el('div', 'prog')
    const onair = p.start <= now && (p.end ?? p.start + 3600_000) > now
    if (onair) row.classList.add('onair')
    row.append(el('div', 'time', `${jstTime(p.start)}${p.end ? `–${jstTime(p.end)}` : ''}`))
    const box = el('div', 'body')
    const title = el('div', 'ptitle', p.title || T('noProgramTitle'))
    if (onair) title.append(el('span', 'badge', T('onAir')))
    box.append(title)
    if (p.performer) box.append(el('div', 'pfm', p.performer))
    row.append(box)
    const acts = el('div', 'pacts')
    // タイムフリー 只有 radiko 有，而且只覆盖已经播完的节目（一周内）。
    if (!station.direct && p.end && p.end <= now && now - p.end < 7 * 86400_000) {
      const b = el('button', null, T('timefree'))
      b.onclick = () => playArchive(station, p)
      acts.append(b)
    }
    // ★收藏 / 预约 / 下载存档（library.js 往这个盒子里加）。
    window.libraryHooks?.programRow?.(acts, station, p, now)
    row.append(acts)
    body.append(row)
  }
  const current = body.querySelector('.prog.onair')
  current?.scrollIntoView({ block: 'center' })
}

// MARK: - タイムフリー（存档回放）

/// 服务端把 radiko 的一串 5 分钟窗口接成一条 VOD playlist，所以整档节目能拖进度条听。
function playArchive(station, program) {
  if (station.direct) return setStatus(T('timefreeOnlyRadiko'))
  if (!program.end || program.end > Date.now()) return setStatus(T('timefreeFuture'))
  if (station.id !== state.stationID) selectStation(station.id, { scroll: true })
  state.file = null
  state.archive = { start: program.start, end: program.end, title: program.title || T('noProgramTitle') }
  attempts = 0
  audio.controls = true
  $('live-back').hidden = false
  closeSheet()
  play()
}

function backToLive() {
  state.archive = null
  state.file = null
  audio.controls = false
  $('live-back').hidden = true
  attempts = 0
  play()
}

// MARK: - 语言

function applyLanguage() {
  document.documentElement.lang = L.lang === 'zh' ? 'zh-CN' : L.lang === 'ja' ? 'ja' : 'en'
  $('app-title').textContent = T('title')
  $('lang').value = L.lang
  // 顶栏与播放键都是图标钮了：文案只剩 title / aria-label（读屏与鼠标悬停靠它）。
  for (const [id, key] of [
    ['schedule', 'program'], ['prev', 'prev'], ['next', 'next'], ['lang-btn', 'language'],
  ]) {
    const n = $(id)
    n.title = T(key)
    n.setAttribute('aria-label', T(key))
  }
  $('sheet-title').textContent = T('program')
  $('live-back').textContent = T('backToLive')
  $('hint').textContent = T('webHint')
  setupSleepSelect()
  paintPlay()
  updateFavButton()
  window.recognizeHooks?.applyLanguage?.()
  window.libraryHooks?.applyLanguage?.()
  // 合成拨盘的名字（★ / 全部 / n 个台）跟着语言变，所以整条拨盘条重建。
  const keepID = currentDial()?.id
  buildDials()
  const i = state.dials.findIndex((d) => d.id === keepID)
  state.dialIndex = i >= 0 ? i : 0
  renderDials()
  renderStationList()
  if (!state.playing) setStatus(T('statusIdle'))
  if (!$('sheet').hidden) loadSheet()
}

// MARK: - 启动

function wire() {
  $('play').onclick = togglePlay
  $('prev').onclick = () => step(-1)
  $('next').onclick = () => step(1)
  $('schedule').onclick = openSheet
  $('sheet-close').onclick = closeSheet
  $('live-back').onclick = backToLive
  $('day-prev').onclick = () => { if (state.day > -7) { state.day--; loadSheet() } }
  $('day-next').onclick = () => { if (state.day < 7) { state.day++; loadSheet() } }
  $('sheet').onclick = (e) => { if (e.target === $('sheet')) closeSheet() }
  $('lang').onchange = (e) => { L.lang = e.target.value; applyLanguage() }

  const vol = $('vol')
  vol.value = localStorage.getItem(KEY.vol) ?? '1'
  audio.volume = Number(vol.value)
  vol.oninput = () => {
    audio.volume = Number(vol.value)
    localStorage.setItem(KEY.vol, vol.value)
  }

  document.addEventListener('keydown', (e) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement) return
    // 抽屉里按空格是「按下当前这个按钮」（删除、预约……），别顺手把播放也切了。
    if (e.code === 'Space' && e.target instanceof HTMLButtonElement) return
    if (e.code === 'Space') { e.preventDefault(); togglePlay() }
    else if (e.code === 'ArrowRight') step(1)
    else if (e.code === 'ArrowLeft') step(-1)
    else if (e.code === 'Escape') { closeSheet(); window.libraryHooks?.closeSheet?.() }
  })
}

async function main() {
  const res = await fetch('stations.json')
  state.doc = await res.json()
  for (const region of state.doc.regions) {
    for (const s of region.stations) state.stations.set(s.id, s)
  }
  buildDials()
  wire()

  // 上次听的拨盘与电台（记不住就从「全部」的第一台开始）。
  const lastDial = localStorage.getItem(KEY.dial)
  const di = state.dials.findIndex((d) => d.id === lastDial)
  state.dialIndex = di >= 0 ? di : 1
  const lastStation = localStorage.getItem(KEY.station)
  const list = currentDial().stations
  state.stationID = list.some((s) => s.id === lastStation) ? lastStation : list[0]?.id ?? null

  state.dial = new Dial($('dial'), (id) => selectStation(id, { scroll: true }))
  state.dial.setStations(list, state.stationID)
  renderDials()
  renderCards()
  applyLanguage()
  updateFavButton()
  paintGlow()
  setStatus(T('statusIdle'))
  if (state.stationID) loadNowPlaying(state.stationID)
  // 番組表每分钟只影响卡片那一行「正在播出」，一分钟刷一次够了。
  setInterval(() => { if (state.stationID) loadNowPlaying(state.stationID) }, 60_000)
}

main().catch((e) => setStatus(`启动失败：${e?.message ?? e}`))
