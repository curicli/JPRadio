// 录音库 / 预约录制 / 节目收藏。
//
// **录制跑在服务端**（`web/server.mjs` 那个 Node 进程），浏览器只负责按按钮和放文件 ——
// 所以按下录制之后关页面、锁屏、换台都不影响，音频照常写到磁盘上。这跟 iOS 版
// 「App 随时会被杀」的前提正好相反，也正是 web 版敢做预约录制的原因（见 README）。
//
// 节目收藏反过来**只存在这台浏览器**的 localStorage 里（与电台收藏同一处）：服务端不需要
// 知道你喜欢哪档节目。iOS 端的「节目提醒」没有搬 —— LAN 上的 http:// 不是安全上下文，
// 通知 API 用不了，而且提醒还得页面开着才响。
//
// 加载顺序排在 app.js 之后，所以能直接用它的 `state` / `audio` / `play` / `T`；
// 反过来它调这边要经过 `window.libraryHooks`（与 recognize.js 同一套办法）。

const LKEY = { favProgram: 'favoritePrograms' }

/// 有活儿在干（正在录 / 正在下存档）或抽屉开着时，多久拉一次服务端状态。
/// 打的是本机、回来是一小段 JSON，一秒一次的代价可以忽略，换来的是按钮上的秒表在走。
const LIB_POLL_MS = 1000

/// 番組表行右侧的操作按钮统一用图标（不用文字）：文字标签（如「Schedule recording」）
/// 会把节目标题挤成窄窄一列、层层折行还跟「ON AIR」角标叠在一起。图标 + aria-label
/// 既紧凑又不丢可读性。原版 / art 版共用这套 JS，改这里两版一起生效。
const PICON = {
  reserve: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><circle cx="12" cy="13" r="7"/><path d="M12 10.5V13l1.9 1.1"/><path d="M5 4.6 7.4 6.9M19 4.6 16.6 6.9"/></svg>',
  download: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 4v9m0 0-3.5-3.5M12 13l3.5-3.5M5 18.5h14"/></svg>',
}

/// 已经不会再变的预约状态（角标计数不算它们）。与 lib/reservations.mjs 的 DONE 一致。
const RES_DONE = new Set(['completed', 'failed', 'missed'])

/// 节目收藏的 id：跟 iOS 端 `FavoriteProgram` 一样只用「台 + 标题」，不带时间 ——
/// 收藏的是「这档节目」而不是「这一期」，下周同一档也得算收藏。
const favKey = (stationID, title) => `${stationID}#${title}`

/// 预约的 id：番組表要靠它判「这档已经约过了」。必须带上台 id —— 节目 id 只在台内唯一。
const resKey = (station, p) => `${station.id}#${p.id ?? p.start}`

const lib = {
  recordings: [],
  live: [],        // 正在实时录的 job
  archive: [],     // 正在下存档的 job
  reservations: [],
  favPrograms: loadFavPrograms(),
  dir: null,
  tab: 'rec',
  timer: null,
  flashTimer: null,
}

function loadFavPrograms() {
  try {
    const v = JSON.parse(localStorage.getItem(LKEY.favProgram) ?? '[]')
    return Array.isArray(v) ? v.filter((p) => p?.stationID && p?.title) : []
  } catch {
    return []
  }
}

const saveFavPrograms = () => localStorage.setItem(LKEY.favProgram, JSON.stringify(lib.favPrograms))

/// POST 一个 JSON、拿回一个 JSON。失败时 body 里带 `error`，一律原样显示给人看 ——
/// 「录制失败」不带原因等于什么都没说（服务端为此专门把 HTTP 状态写进 error 里）。
async function postJSON(path, body) {
  try {
    const res = await fetch(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    })
    const doc = await res.json().catch(() => null)
    if (!res.ok) return { error: doc?.error ?? `HTTP ${res.status}` }
    return doc ?? {}
  } catch (e) {
    return { error: String(e?.message ?? e) }
  }
}

// MARK: - 格式化

/// mm:ss（过一小时给 h:mm:ss）。
function clock(seconds) {
  const s = Math.max(0, Math.round(seconds ?? 0))
  const pad = (n) => String(n).padStart(2, '0')
  const h = Math.floor(s / 3600)
  return h ? `${h}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}` : `${pad(Math.floor(s / 60))}:${pad(s % 60)}`
}

const sizeText = (n) => (n >= 1048576 ? `${(n / 1048576).toFixed(1)} MB` : `${Math.round((n ?? 0) / 1024)} KB`)

/// 录音的时间戳一律按 JST 显示，跟番組表对得上（本地时区会整体错几小时）。
const stampText = (epoch) => `${jstDate(epoch)} ${jstTime(epoch)}`

/// 借播放状态那一行说一句话，几秒后交还 —— 不然会一直挂着「已保存」，看起来像播放停了。
function flash(text) {
  setStatus(text)
  clearTimeout(lib.flashTimer)
  lib.flashTimer = setTimeout(() => {
    const st = playbackStatus()
    setStatus(st.text, st.live)
  }, 5000)
}

// MARK: - 服务端状态

/// 拉一次 `/api/rec`（录音库 + 正在干的活儿 + 预约）。
/// 拉失败**不清空**已有列表：服务端抖一下不该让界面变成「一条录音都没有」。
async function libRefresh() {
  try {
    const res = await fetch('/api/rec')
    const doc = await res.json()
    lib.recordings = doc.recordings ?? []
    lib.live = doc.live ?? []
    lib.archive = doc.archive ?? []
    lib.reservations = doc.reservations ?? []
    lib.dir = doc.dir ?? null
  } catch { /* 保持上一次的样子 */ }
  updateRecButton()
  if (!$('lib').hidden) renderLib()
  syncPolling()
}

/// 只在「有活儿在干」或「抽屉开着」时轮询。空着的时候一秒一个请求纯属浪费。
function syncPolling() {
  const want = lib.live.length > 0 || lib.archive.length > 0 || !$('lib').hidden
  if (want && !lib.timer) lib.timer = setInterval(() => { libRefresh() }, LIB_POLL_MS)
  if (!want && lib.timer) {
    clearInterval(lib.timer)
    lib.timer = null
  }
}

// MARK: - 录制按钮

/// 当前台那条手动录制。预约录的不算 —— 那条不该被这个按钮停掉。
const liveJobForCurrent = () =>
  lib.live.find((j) => j.stationID === state.stationID && !j.reservationID) ?? null

/// 按钮上的秒表按**墙上时间**走，不用 job.seconds：后者是真写进文件的秒数，
/// 每轮拉分片（约 4 秒）才回来一次，按它显示的话刚按下去会停在 00:00 像是没反应。
/// 库里那一行显示的是 job/录音的真实秒数。
const elapsedOf = (job) => (Date.now() - job.startedAt) / 1000

function updateRecButton() {
  const b = $('rec')
  if (!b) return
  const job = liveJobForCurrent()
  // 图标是两个内嵌 SVG（圆点 / 方块），靠 `.on` 决定露哪一个 —— 只往小字那行写秒表，
  // 写 textContent 会把两个 <svg> 一起抹掉。
  $('rec-cap').textContent = job ? clock(elapsedOf(job)) : ''
  b.classList.toggle('on', !!job)
  b.setAttribute('aria-pressed', String(!!job))
  b.title = T(job ? 'recordStop' : 'recordStart')
  b.setAttribute('aria-label', T(job ? 'recordStop' : 'recordStart'))
  updateLibBadge()
}

/// 录音库槽位上的角标：还没了结的预约数（等待中 / 正在录 / 正在下）。
/// 预约是「关了页面也会到点开录」的东西，界面上得有个一眼能看到的计数。
function updateLibBadge() {
  const dot = $('lib-badge')
  if (!dot) return
  const n = lib.reservations.filter((r) => !RES_DONE.has(r.status)).length
  dot.textContent = n > 99 ? '99+' : String(n)
  dot.hidden = n === 0
}

/// 录音的标题：优先用「正在播出」那档节目名 —— 借 app.js 为卡片那一行拉过的番組表缓存，
/// 不再多打一次请求；拿不到就用「台名 + 时间」，总比一堆同名文件好找。
function nowTitleFor(station) {
  const now = Date.now()
  const list = nowCache.get(station.id)?.list ?? []
  const hit = list.find((p) => p.start <= now && (p.end ?? p.start + 3600_000) > now)
  return hit?.title || `${station.name} ${jstTime(now)}`
}

async function toggleRec() {
  const job = liveJobForCurrent()
  if (job) return await stopRec(job)
  const s = currentStation()
  if (!s) return
  const out = await postJSON('/api/rec/live', { station: s.id, title: nowTitleFor(s) })
  if (out.error) return flash(`${T('recordFailed')}（${out.error}）`)
  flash(T('recordStarted'))
  await libRefresh()
}

/// 停止并**等它收尾**（只等当前那一片写完，几秒），这样能立刻把结果报出来。
async function stopRec(job) {
  const b = $('rec')
  b.disabled = true
  const out = await postJSON('/api/rec/stop', { id: job.id })
  b.disabled = false
  await libRefresh()
  if (!out.ok) return flash(`${T('recordFailed')}（${out.error ?? T('recordNothing')}）`)
  const rec = out.recording
  flash(T('recordSaved', `${rec?.title || job.stationName} · ${clock(rec?.seconds)}`))
}

// MARK: - 存档下载（把一整档 タイムフリー 存成文件）

async function downloadArchive(station, p) {
  const out = await postJSON('/api/rec/archive', {
    station: station.id,
    start: p.start,
    end: p.end,
    title: p.title || T('noProgramTitle'),
  })
  if (out.error) return flash(`${T('recordFailed')}（${out.error}）`)
  flash(T('downloadingArchive', 0, out.job?.total || '…'))
  await libRefresh()
}

// MARK: - 预约录制

/// 约一档。服务端两种策略：radiko 等播完下存档，直连台只能在服务开着时实时录 ——
/// 差别很要紧（直连台错过就是真错过），所以约完当场把这句话说清楚。
async function addReserve(station, p, id) {
  const out = await postJSON('/api/reservations', {
    id,
    station: station.id,
    start: p.start,
    end: p.end,
    title: p.title || T('noProgramTitle'),
  })
  if (out.error) return flash(out.error)
  await libRefresh()
  flash(`${T('reserved')} · ${T(out.direct ? 'reserveDirectNote' : 'reserveArchiveNote')}`)
}

async function cancelReserve(id) {
  const out = await postJSON('/api/reservations/delete', { id })
  await libRefresh()
  if (out.error) flash(out.error)
}

const hasReserve = (id) => lib.reservations.some((r) => r.id === id)

// MARK: - 节目收藏（只在这台浏览器里）

const favIndexOf = (stationID, title) =>
  lib.favPrograms.findIndex((p) => favKey(p.stationID, p.title) === favKey(stationID, title))

/// 收 / 取消收藏，返回收藏之后的状态。
function toggleFavProgram(station, p) {
  const title = p.title || T('noProgramTitle')
  const at = favIndexOf(station.id, title)
  if (at >= 0) lib.favPrograms.splice(at, 1)
  else {
    lib.favPrograms.unshift({
      stationID: station.id,
      stationName: station.name,
      title,
      performer: p.performer ?? '',
      // 留一份「收藏时看到的那一期」的时刻，列表里显示大概什么时候播（下一期未必同一时间）。
      start: p.start ?? null,
      end: p.end ?? null,
      addedAt: Date.now(),
    })
  }
  saveFavPrograms()
  if (!$('lib').hidden && lib.tab === 'fav') renderLib()
  return at < 0
}

// MARK: - 录音库抽屉

function openLib() {
  $('lib').hidden = false
  renderLib()
  libRefresh()
}

function closeLib() {
  $('lib').hidden = true
  syncPolling()      // 抽屉一关，没活儿就该停掉轮询
}

function renderLib() {
  const busy = lib.live.length + lib.archive.length
  const tabs = [
    ['rec', T('library'), lib.recordings.length + busy],
    ['res', T('reservations'), lib.reservations.filter((r) => !RES_DONE.has(r.status)).length],
    ['fav', T('favPrograms'), lib.favPrograms.length],
  ]
  const bar = $('lib-tabs')
  bar.textContent = ''
  for (const [id, label, n] of tabs) {
    const b = el('button', null, n ? `${label} ${n}` : label)
    if (id === lib.tab) b.setAttribute('aria-current', 'true')
    b.onclick = () => { lib.tab = id; renderLib() }
    bar.append(b)
  }
  $('lib-title').textContent = tabs.find(([id]) => id === lib.tab)?.[1] ?? T('library')
  const body = $('lib-body')
  body.textContent = ''
  if (lib.tab === 'rec') renderRecordings(body)
  else if (lib.tab === 'res') renderReservations(body)
  else renderFavPrograms(body)
  // 录音落在哪个目录要写出来：`--rec-dir` 能换，而且用户迟早要自己去拷文件。
  $('lib-note').textContent = lib.tab === 'res'
    ? T('reserveArchiveNote')
    : lib.dir ?? ''
}

function renderRecordings(body) {
  for (const j of [...lib.live, ...lib.archive]) {
    const row = el('div', 'lrow busy')
    const box = el('div', 'lbody')
    box.append(el('div', 'ltitle', j.title || j.stationName))
    const sub = j.kind === 'timefree'
      ? T('downloadingArchive', j.done ?? 0, j.total || '…')
      : T('recording', clock(elapsedOf(j)))
    box.append(el('div', 'lsub', `${j.stationName} · ${sub}`))
    row.append(box)
    // 预约录的那条不给停：它有自己的结束时间，手停等于把预约作废一半。
    if (j.kind === 'live' && !j.reservationID) {
      const stop = el('button', null, T('recordStop'))
      stop.onclick = () => stopRec(j)
      row.append(stop)
    }
    body.append(row)
  }
  if (!lib.recordings.length) {
    if (!lib.live.length && !lib.archive.length) body.append(el('p', null, T('noRecordings')))
    return
  }
  for (const r of lib.recordings) body.append(recordingRow(r))
}

function recordingRow(r) {
  const row = el('div', 'lrow')
  const box = el('div', 'lbody')
  box.append(el('div', 'ltitle', r.title || r.stationName))
  // 时长用元数据里的秒数，不问播放器要 —— 裸 ADTS 没有时长索引，浏览器只会按码率瞎估。
  const bits = [
    r.stationName,
    T(r.source === 'timefree' ? 'sourceTimefree' : 'sourceLive'),
    stampText(r.date),
    clock(r.seconds),
    sizeText(r.bytes),
  ]
  box.append(el('div', 'lsub', bits.filter(Boolean).join(' · ')))
  // 降级原因（存档缺了几片之类）一定要露出来，否则「录得不对」永远查不出所以然。
  if (r.note) box.append(el('div', 'err', r.note))
  row.append(box)

  const listen = el('button', null, '▶')
  listen.title = T('play')
  listen.onclick = () => playRecording(r)
  row.append(listen)

  const down = el('a', 'lbtn', '⤓')
  down.href = `/rec/${encodeURIComponent(r.id)}?dl=1`
  down.title = T('download')
  down.setAttribute('download', '')
  row.append(down)

  const del = el('button', null, '🗑')
  del.title = T('delete')
  del.onclick = () => deleteRecording(r)
  row.append(del)
  return row
}

/// 放库里的一条。走 `/rec/<id>`（普通音频文件，不是 HLS）—— app.js 的 `attach`
/// 会为它绕开 hls.js，看门狗也不启动（放完就是放完，不该重连）。
function playRecording(r) {
  state.file = { id: r.id, title: r.title || r.stationName }
  state.archive = null
  audio.controls = true          // 要能拖进度条（服务端支持 Range）
  $('live-back').hidden = false
  closeLib()
  play()
}

async function deleteRecording(r) {
  if (!confirm(T('confirmDelete', r.title || r.stationName))) return
  // 正在放这条就先撤下来：文件删了播放器只会卡在那儿报错。
  if (state.file?.id === r.id) {
    pause()
    state.file = null
    audio.removeAttribute('src')
    audio.controls = false
    $('live-back').hidden = true
  }
  const out = await postJSON('/api/rec/delete', { id: r.id })
  if (out.error) flash(out.error)
  await libRefresh()
}

function renderReservations(body) {
  if (!lib.reservations.length) return void body.append(el('p', null, T('noReservations')))
  for (const r of lib.reservations) {
    const row = el('div', 'lrow')
    const box = el('div', 'lbody')
    box.append(el('div', 'ltitle', r.title || r.stationName))
    const status = r.status ? T(`status${r.status[0].toUpperCase()}${r.status.slice(1)}`) : ''
    box.append(el('div', 'lsub',
      `${r.stationName} · ${stampText(r.start)}–${jstTime(r.end)} · ${status}`))
    // `note` 是「为什么没录到」（HTTP 状态 / 卡在哪一步 / 第几次重试）。iOS 端也是显示在
    // 预约行上的 —— 不显示的话事后永远查不出原因。
    if (r.note) box.append(el('div', 'err', r.note))
    row.append(box)
    const del = el('button', null, RES_DONE.has(r.status) ? '🗑' : T('cancelReserve'))
    del.onclick = async () => { del.disabled = true; await cancelReserve(r.id) }
    row.append(del)
    body.append(row)
  }
}

function renderFavPrograms(body) {
  if (!lib.favPrograms.length) return void body.append(el('p', null, T('noFavPrograms')))
  for (const f of lib.favPrograms) {
    const row = el('div', 'lrow')
    const box = el('div', 'lbody')
    box.append(el('div', 'ltitle', f.title))
    const bits = [f.stationName, f.performer, f.start ? stampText(f.start) : null]
    box.append(el('div', 'lsub', bits.filter(Boolean).join(' · ')))
    row.append(box)
    // 点标题跳到那个台的番組表：收藏的是「这档节目」，下一期什么时候播得看表。
    const open = el('button', null, T('program'))
    open.disabled = !state.stations.has(f.stationID)
    open.onclick = () => {
      closeLib()
      selectStation(f.stationID, { scroll: true })
      openSheet()
    }
    row.append(open)
    const del = el('button', null, '★')
    del.title = T('unfavProgram')
    del.classList.add('on')
    del.onclick = () => {
      lib.favPrograms = lib.favPrograms.filter((p) => favKey(p.stationID, p.title) !== favKey(f.stationID, f.title))
      saveFavPrograms()
      renderLib()
    }
    row.append(del)
    body.append(row)
  }
}

// MARK: - 番組表每一行上的按钮
//
// app.js 的 `renderPrograms` 把一个空盒子递过来（タイムフリー 回放按钮已经在里面了）。
// 三类按钮按节目所处的时间给：★收藏谁都有，没播完的能预约，播完的 radiko 节目能下存档。

function programRow(acts, station, p, now) {
  const title = p.title || T('noProgramTitle')

  const fav = el('button', 'pfav')
  const paintFav = () => {
    const on = favIndexOf(station.id, title) >= 0
    fav.textContent = on ? '★' : '☆'
    fav.classList.toggle('on', on)
    fav.title = T(on ? 'unfavProgram' : 'favProgram')
  }
  fav.onclick = () => { toggleFavProgram(station, p); paintFav() }
  paintFav()
  acts.append(fav)

  const ended = p.end && p.end <= now
  if (!ended) {
    const id = resKey(station, p)
    const b = el('button', 'picon')
    b.innerHTML = PICON.reserve
    const paint = () => {
      const on = hasReserve(id)
      b.classList.toggle('on', on)
      const label = T(on ? 'cancelReserve' : 'reserve')
      b.title = label
      b.setAttribute('aria-label', label)
    }
    b.onclick = async () => {
      b.disabled = true
      if (hasReserve(id)) await cancelReserve(id)
      else await addReserve(station, p, id)
      b.disabled = false
      paint()
    }
    paint()
    acts.append(b)
    return
  }
  // 播完的：只有 radiko 有存档，而且只留一周（更早的就真没有了）。
  if (!station.direct && now - p.end < 7 * 86400_000) {
    const b = el('button', 'picon')
    b.innerHTML = PICON.download
    b.title = T('downloadArchive')
    b.setAttribute('aria-label', T('downloadArchive'))
    b.onclick = async () => { b.disabled = true; await downloadArchive(station, p); b.disabled = false }
    acts.append(b)
  }
}

// MARK: - 接到 app.js 上

window.libraryHooks = {
  programRow,
  /// 换台：录制按钮显示的是「当前台在不在录」，得重画。
  stationChanged: updateRecButton,
  /// 语言变了：按钮标题、抽屉里的每一行文案都跟着变。
  applyLanguage() {
    for (const [id, key] of [['lib-open', 'library'], ['lib-close', 'close']]) {
      const n = $(id)
      n.title = T(key)
      n.setAttribute('aria-label', T(key))
    }
    updateRecButton()
    if (!$('lib').hidden) renderLib()
  },
  /// Esc：app.js 关番組表的同时也把这个抽屉关掉。
  closeSheet: closeLib,
}

$('rec').onclick = toggleRec
$('lib-open').onclick = openLib
$('lib-close').onclick = closeLib
$('lib').onclick = (e) => { if (e.target === $('lib')) closeLib() }

// 进页面先看一眼服务端：上次按下录制之后可能一直录着（录制不依赖这个页面开着），
// 那种情况按钮必须一进来就是「正在录」的样子。
libRefresh()
