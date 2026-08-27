// JPRadio web 版的本机服务器：静态前端 + radiko/ListenRadio 反向代理。
//
//   node web/server.mjs            # 然后开 http://127.0.0.1:8787
//   node web/server.mjs --port 9000 --host 0.0.0.0
//
// **为什么必须有服务端**（不能纯静态页）：
//   - `api.radiko.jp` / `radiko.jp` / `listenradio.jp` 都不给 CORS 头，浏览器里 fetch 直接被拦；
//   - radiko 拉流要在 playlist 请求上带 `X-Radiko-AuthToken`，分片请求**不能**带；
//     ListenRadio 的 CDN 又按 Referer/Origin 防盗链。浏览器无法为 HLS 内部请求分别设头；
//   - 境外绕过靠 auth2 时上报伪造 GPS，这同样只能由服务端发。
// 所以浏览器只跟本机同源地址打交道，加头/鉴权/改写 m3u8 全在这里做。
//
// **安全**：默认只监听 127.0.0.1，没有任何鉴权 —— 它是给自己用的本机播放器。
// 加 `--host 0.0.0.0` 会把它暴露到局域网（同网段任何人都能用你的 IP 听 radiko、
// 并让你的 IP 去打 radiko），只在自己信任的网络里这么做，也别端口转发到公网。
// `/img` 只代理台标那两个域名，`/p` `/s` 只认本进程自己发出的 token，不是通用开放代理。
import { createServer } from 'node:http'
import { readFile, stat } from 'node:fs/promises'
import { createReadStream } from 'node:fs'
import { networkInterfaces } from 'node:os'
import { extname, join, normalize, dirname, sep, resolve as resolvePath } from 'node:path'
import { fileURLToPath } from 'node:url'
import { Readable } from 'node:stream'
import * as radiko from './lib/radiko.mjs'
import { rewritePlaylist, collectSegments, firstURI, mapURI, isMediaPlaylist, URLVault } from './lib/hls.mjs'
import { mapPool } from './lib/pool.mjs'
import * as pg from './lib/programs.mjs'
import { looksLikeTS, tsToADTS } from './lib/adts.mjs'
import * as shazam from './lib/shazamapi.mjs'
import { SegmentWriter, captureLive, writeAll } from './lib/recorder.mjs'
import { Library } from './lib/library.mjs'
import { Reservations } from './lib/reservations.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const PUBLIC = join(here, 'public')

const args = process.argv.slice(2)
const flag = (name, fallback) => {
  const i = args.indexOf(name)
  return i >= 0 && args[i + 1] ? args[i + 1] : fallback
}
const PORT = Number(process.env.PORT ?? flag('--port', '8787'))
const HOST = process.env.HOST ?? flag('--host', '127.0.0.1')
/// 录音落盘的地方。录音很占空间（一小时约 20 MB），所以留一个换盘的口子。
const REC_DIR = resolvePath(process.env.JPRADIO_REC_DIR ?? flag('--rec-dir', join(here, 'recordings')))


/// 上游地址 → 短 token。分片地址每几秒换一批，映射只活在内存里。
const vault = new URLVault()

/// 直连台（ListenRadio）与台标要用的「像浏览器」的头 —— smartstream 的 CDN
/// 按防盗链校验，缺 Referer/UA 会 403（表现为「浏览器能放、播放器里失败」）。
const DIRECT_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15',
  Referer: 'https://listenradio.jp/',
  Origin: 'https://listenradio.jp',
}

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.webmanifest': 'application/manifest+json',
}

const M3U8 = 'application/vnd.apple.mpegurl'

// MARK: - 台表

/// 台表由 `zsh web/sync-stations.sh` 从 ios/JPRadio/Models/Station.swift 导出，
/// 与 app 用的是同一份数据（手抄 116 条迟早会漂）。
const stations = new Map()

async function loadStations() {
  const raw = await readFile(join(PUBLIC, 'stations.json'), 'utf8')
  const doc = JSON.parse(raw)
  for (const region of doc.regions) {
    for (const s of region.stations) stations.set(s.id, s)
  }
  return doc
}

// MARK: - 小工具

const send = (res, status, headers, body) => {
  res.writeHead(status, headers)
  res.end(body)
}
const sendJSON = (res, status, value) =>
  send(res, status, { 'Content-Type': MIME['.json'], 'Cache-Control': 'no-store' },
       JSON.stringify(value))
const sendText = (res, status, text) =>
  send(res, status, { 'Content-Type': 'text/plain; charset=utf-8' }, text)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/// 读完请求 body（目前只有 `/api/recognize` 需要）。带上限，免得一个坏请求吃光内存。
async function readBody(req, limit = 512 * 1024) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > limit) throw new Error(`body 超过 ${limit} 字节`)
    chunks.push(Buffer.from(chunk))
  }
  return Buffer.concat(chunks).toString('utf8')
}

/// playlist 一律不许缓存：直播的 chunklist 每几秒就变一次，缓存住就等于卡死。
const playlistHeaders = {
  'Content-Type': M3U8,
  'Cache-Control': 'no-store',
  'Access-Control-Allow-Origin': '*',
}

// MARK: - 上游请求

/// 取一层 playlist。radiko 的 playlist 请求必须带 token（分片请求反而不能带），
/// 401/403 时**换一个新 token 再试一次** —— token 过期是最常见的失败，
/// 而 web 版每次请求都重新加头，所以不像 iOS 那样存在「token 冻在 asset 里」的问题。
async function fetchPlaylist(url, meta) {
  const attempt = async (force) => {
    const headers = { ...DIRECT_HEADERS }
    if (meta.kind === 'radiko') {
      const t = await radiko.token(meta.area, { force })
      delete headers.Referer
      delete headers.Origin
      headers['X-Radiko-AuthToken'] = t.value
      headers['X-Radiko-AreaId'] = t.area
    }
    return fetch(url, { headers, redirect: 'follow' })
  }
  let res = await attempt(false)
  if ((res.status === 401 || res.status === 403) && meta.kind === 'radiko') {
    res = await attempt(true)
  }
  return res
}

/// 把上游 playlist 改写成本机地址；嵌套 playlist 与分片各走一个入口。
function rewrite(text, absURL, meta) {
  return rewritePlaylist(text, absURL, (target, kind) => {
    const token = vault.put(target, meta)
    return kind === 'playlist' ? `/p/${token}.m3u8` : `/s/${token}`
  })
}

/// 分片透传。**radiko 的 .aac 分片不能带任何 radiko 头**（带了会 403）；
/// 直连台反过来必须带浏览器头。所以这里按来源分别处理，别图省事统一加。
///
/// `Range` 必须**原样转给上游、并把 206 原样转回来**：Safari 取 MPEG-TS 分片时会先发一个
/// 小的 range 探针，拿到 200 全量就会 abort 再试，然后卡在 readyState 0 不动
/// （表现是「一直连接中…」，控制台里连错误都没有）。ListenRadio 的 TS 分片就是这么栽的。
async function pipeSegment(res, url, meta, range) {
  const headers = meta.kind === 'radiko' ? {} : { ...DIRECT_HEADERS }
  if (range) headers.Range = range
  const upstream = await fetch(url, { headers, redirect: 'follow' })
  if (!upstream.ok || !upstream.body) {
    return sendText(res, upstream.status === 200 ? 502 : upstream.status, `分片失败：${upstream.status}`)
  }
  const out = {
    'Content-Type': upstream.headers.get('content-type') ?? 'audio/aac',
    'Cache-Control': 'no-store',
    'Access-Control-Allow-Origin': '*',
    'Accept-Ranges': upstream.headers.get('accept-ranges') ?? 'bytes',
  }
  for (const h of ['content-range', 'content-length']) {
    const v = upstream.headers.get(h)
    if (v) out[h === 'content-range' ? 'Content-Range' : 'Content-Length'] = v
  }
  res.writeHead(upstream.status, out)
  await Readable.fromWeb(upstream.body).pipe(res)
}

// MARK: - 路由

/// 入口 playlist：`/stream/<station id>.m3u8`。前端把这个地址交给 hls.js / Safari。
async function handleStream(res, stationID) {
  const station = stations.get(stationID)
  if (!station) return sendText(res, 404, `未知电台：${stationID}`)

  const { url, meta } = await liveEntry(station)
  const upstream = await fetchPlaylist(url, meta)
  if (!upstream.ok) return sendText(res, 502, `上游 playlist 失败：HTTP ${upstream.status}`)
  send(res, 200, playlistHeaders, rewrite(await upstream.text(), upstream.url || url, meta))
}

/// 现起一条直播入口地址。radiko 的这一步包含鉴权（auth1/auth2 + 伪造 GPS），
/// 而且**每次都要重新起**：地址里带着这次会话的 lsid。
async function liveEntry(station) {
  if (station.direct) return { url: station.streamURL, meta: { kind: 'direct' } }
  const t = await radiko.token(station.areaID)
  const base = await radiko.playlistBase(station.id)
  return {
    url: radiko.liveURL(base, station.id, t.userID),
    // 记下台 id：chunklist 会话过期时要靠它重新起一条（见 handleNestedPlaylist）。
    meta: { kind: 'radiko', area: station.areaID, station: station.id },
  }
}

/// 嵌套 playlist（master → chunklist）。直播的 chunklist 会被播放器反复重取，
/// 每次都在这里重新加一次新鲜的 token 头。
async function handleNestedPlaylist(res, token) {
  const hit = vault.get(token)
  if (!hit) return sendText(res, 410, 'playlist token 已过期，请重新起播')
  let upstream = await fetchPlaylist(hit.url, hit.meta)
  let url = hit.url
  let meta = hit.meta
  if (!upstream.ok) {
    // radiko 直播的 chunklist 地址背后是一个会话：**停止轮询一分钟左右它就 404**
    // （实测 8 秒还活着、102 秒已经死了）—— 暂停一会儿再继续、或者切到后台标签页
    // 都会踩到。播放器不会自己回到入口地址重来，所以这里悄悄重建一条会话，
    // 并把同一个 token 指到新地址；用户侧连那 12 秒看门狗都不用等。
    const rebuilt = await rebuildLive(hit, token)
    if (!rebuilt) return sendText(res, 502, `上游 playlist 失败：HTTP ${upstream.status}`)
    upstream = rebuilt.upstream
    url = rebuilt.url
    meta = rebuilt.meta
    if (!upstream.ok) return sendText(res, 502, `上游 playlist 失败：HTTP ${upstream.status}`)
  }
  send(res, 200, playlistHeaders, rewrite(await upstream.text(), upstream.url || url, meta))
}

/// 重建一条 radiko 直播会话，并让原来的 token 指向新的 chunklist。
/// 只对「直播的 radiko chunklist」做（タイムフリー 的窗口地址过期就是真过期，
/// 直连台也没有这层会话），失败就返回 null，让调用方照常报 502。
async function rebuildLive(hit, token) {
  const station = hit.meta.kind === 'radiko' && hit.meta.station
    ? stations.get(hit.meta.station)
    : null
  if (!station) return null
  const entry = await liveEntry(station)
  const master = await fetchPlaylist(entry.url, entry.meta)
  if (!master.ok) return null
  const variant = firstURI(await master.text(), master.url || entry.url)
  if (!variant) return null
  vault.retarget(token, variant, entry.meta)
  console.log(`[${station.id}] chunklist 会话过期，已重建`)
  return { upstream: await fetchPlaylist(variant, entry.meta), url: variant, meta: entry.meta }
}

async function handleSegment(res, token, range) {
  const hit = vault.get(token)
  if (!hit) return sendText(res, 410, '分片 token 已过期')
  await pipeSegment(res, hit.url, hit.meta, range)
}

/// 番組表：`/api/programs?station=<id>&day=<-7..7>`。
async function handlePrograms(res, params) {
  const stationID = params.get('station') ?? ''
  const station = stations.get(stationID)
  if (!station) return sendJSON(res, 404, { error: `未知电台：${stationID}` })
  const day = Math.max(pg.DAY_RANGE.min, Math.min(pg.DAY_RANGE.max, Number(params.get('day') ?? 0) || 0))
  try {
    const list = station.direct
      ? await pg.listenRadioPrograms(stationID, day)
      : await pg.radikoPrograms(stationID, day)
    sendJSON(res, 200, {
      station: stationID,
      day,
      dayStart: pg.broadcastDayStart(day),
      date: pg.broadcastDateString(day),
      programs: list,
    })
  } catch (e) {
    // 番組表失败要说清原因（HTTP 状态 / 解析到哪一步），否则永远查不出是网络、
    // 是格式变了还是键名没对上 —— iOS 端为此专门做过诊断报告。
    sendJSON(res, 502, { error: String(e.message ?? e) })
  }
}

/// 台标反代：浏览器直接取 radiko/listenradio 的图会被 CORS 挡住（拿不到像素就没法
/// 从台标里取主色做背景），而且 smartstream 那边看 Referer。只放这几个域名。
const IMAGE_HOSTS = new Set(['radiko.jp', 'listenradio.jp', 'program-static.cf.radiko.jp'])

async function handleImage(res, target) {
  let url
  try {
    url = new URL(target)
  } catch {
    return sendText(res, 400, '图片地址不合法')
  }
  if (url.protocol !== 'https:' || !IMAGE_HOSTS.has(url.hostname)) {
    return sendText(res, 403, `不代理这个域名：${url.hostname}`)
  }
  const upstream = await fetch(url, { headers: DIRECT_HEADERS })
  if (!upstream.ok || !upstream.body) return sendText(res, upstream.status, '图片失败')
  res.writeHead(200, {
    'Content-Type': upstream.headers.get('content-type') ?? 'image/png',
    // 台标不会变，缓存一天，省得每次换台都重取。
    'Cache-Control': 'public, max-age=86400',
  })
  await Readable.fromWeb(upstream.body).pipe(res)
}

/// タイムフリー（radiko 一周内存档）：`/timefree/<id>.m3u8?start=<epochms>&end=<epochms>`。
/// 浏览器没法自己拼 radiko 那一串 5 分钟窗口，所以这里把分片**接成一条 VOD playlist**
/// 交给播放器 —— 于是整档节目可以拖进度条听。
async function handleTimefree(res, stationID, params) {
  const station = stations.get(stationID)
  if (!station) return sendText(res, 404, `未知电台：${stationID}`)
  if (station.direct) return sendText(res, 400, 'ListenRadio 没有タイムフリー，只能听直播')

  const start = Number(params.get('start')), end = Number(params.get('end'))
  const bad = archiveRangeError(start, end)
  if (bad) return sendText(res, 400, bad)

  const { segments, meta } = await timefreeSegments(station, start, end)
  if (!segments.length) return sendText(res, 502, 'タイムフリー 没有取到任何分片')
  send(res, 200, playlistHeaders, vodPlaylist(segments, meta))
}

/// start/end 这一对参数的校验（回放与「下载存档」用的是同一条规矩）。
function archiveRangeError(start, end) {
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
    return 'start/end 参数不合法（epoch 毫秒）'
  }
  if (end > Date.now()) return '这档节目还没播完，タイムフリー 里还没有'
  return null
}

/// 把整档节目的分片按顺序收齐。
///
/// radiko 的 tf 端点一次最多给 `l=300`（5 分钟）的窗口，靠 `seek` 按 +300s 递推覆盖整档
/// （与 iOS 端 RadioRecorder 的下载逻辑同源）。8 条并发、结果按窗口顺序回填：一档两小时的
/// 节目是 24 个窗口 / 48 个请求，串行要半分钟以上。**顺序绝不能乱** —— 回放时它是一条
/// VOD playlist，录制时它是一个文件里的字节顺序。
async function timefreeSegments(station, start, end) {
  const meta = { kind: 'radiko', area: station.areaID }
  const t = await radiko.token(station.areaID)
  const base = await radiko.playlistBase(station.id, { timefree: true })
  const ft = pg.epochToJSTStamp(start), to = pg.epochToJSTStamp(end)

  const windows = []
  for (let offset = 0; offset < Math.ceil((end - start) / 1000); offset += 300) {
    windows.push(timefreeWindow({
      base, stationID: station.id, lsid: t.userID, ft, to, seek: pg.epochToJSTStamp(start + offset * 1000),
    }))
  }

  const segments = []
  const seen = new Set()
  for (const part of await mapPool(windows, 8, (w) => windowSegments(w, meta))) {
    for (const seg of part) {
      if (seen.has(seg.url)) continue
      seen.add(seg.url)
      segments.push(seg)
    }
  }
  return { segments, meta }
}


/// 组一个 タイムフリー 窗口地址。`l=300` 是 radiko 单次最多给的长度，
/// `seek` 决定窗口从哪儿开始（`ft`/`to` 始终是整档节目的范围）。
/// 拼整档（handleTimefree）和识曲只要一个窗口（archiveSnippetSegments）都用它。
function timefreeWindow({ base, stationID, lsid, ft, to, seek }) {
  const u = new URL(base)
  for (const [k, v] of Object.entries({
    station_id: stationID, l: '300', lsid, start_at: ft, end_at: to, ft, to, seek, type: 'b',
  })) u.searchParams.set(k, v)
  return u.toString()
}

/// 取一个 タイムフリー 窗口里的分片序列。
/// radiko 这个端点回的是 **master**（一层 `#EXT-X-STREAM-INF` 指向真正的 chunklist），
/// 所以必须再往下一层；直接收 master 会把那条变体地址当成一个 5 秒分片收走 ——
/// 表现是「15 分钟的节目只拼出 15 秒」。
async function windowSegments(windowURL, meta) {
  const first = await fetchPlaylist(windowURL, meta)
  if (!first.ok) return []
  const text = await first.text()
  const base = first.url || windowURL
  if (isMediaPlaylist(text)) return collectSegments(text, base)
  const child = firstURI(text, base)
  if (!child) return []
  const second = await fetchPlaylist(child, meta)
  if (!second.ok) return []
  const inner = await second.text()
  return isMediaPlaylist(inner) ? collectSegments(inner, second.url || child) : []
}

/// 从一段 chunklist 里取出 (时长, 分片绝对地址) 序列 —— 实现在 lib/hls.mjs（可单独自检）。

/// 把分片序列拼成一条可拖动进度条的 VOD playlist。
function vodPlaylist(segments, meta) {
  const target = Math.max(1, Math.ceil(Math.max(...segments.map((s) => s.duration))))
  const lines = [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-PLAYLIST-TYPE:VOD',
    `#EXT-X-TARGETDURATION:${target}`,
    '#EXT-X-MEDIA-SEQUENCE:0',
  ]
  for (const seg of segments) {
    lines.push(`#EXTINF:${seg.duration.toFixed(3)},`)
    lines.push(`/s/${vault.put(seg.url, meta)}`)
  }
  lines.push('#EXT-X-ENDLIST', '')
  return lines.join('\n')
}

// MARK: - 识曲
//
// 分两半：**抓音**在这里（`/api/snippet`），**算指纹**在浏览器（`public/recognize.js`
// → `sig-worker.js` → `lib/shazam.mjs`），**查曲库**又回到这里（`/api/recognize`）。
//
// 为什么抓音不在浏览器里做：Safari 播原生 HLS 时 `createMediaElementSource` 拿到的是
// 静音（音频被媒体管线独占），iPhone 上又没有普通 MSE 可以退回 hls.js 走 Web Audio。
// 分片本来就是我们代理的，服务端多下一份的代价是一次额外下载 —— 跟 iOS 端
// `LiveRecorder.snippet` 的做法一致，比在浏览器里跟 Safari 打架靠谱得多。
//
// 为什么指纹不在服务端算：12 秒音频要做 ~1450 次 2048 点 FFT（实测 177 ms），
// 这个进程同时在给播放器转发 HLS，堵住事件循环会让正在听的流卡一下。

const snippetSpan = (segments) => segments.reduce((sum, s) => sum + s.duration, 0)

/// 识曲抓音：`/api/snippet/<台 id>?seconds=16`，存档再加 `&start=<epoch 毫秒>`。
///
/// 回的是**裸 ADTS AAC**：浏览器 `decodeAudioData` 认 ADTS 但不认 MPEG-TS 容器，
/// 所以 ListenRadio 的 TS 分片在这里就拆开（`lib/adts.mjs`）。
/// 长度只保证「不少于要的秒数」—— 裁到正好 12 秒由浏览器做（它解完才知道真实时长）。
async function handleSnippet(res, stationID, params) {
  const station = stations.get(stationID)
  if (!station) return sendText(res, 404, `未知电台：${stationID}`)
  const seconds = Math.min(30, Math.max(6, Number(params.get('seconds') ?? 16) || 16))
  const start = Number(params.get('start'))
  const archive = Number.isFinite(start) && start > 0

  let picked
  try {
    picked = archive
      ? await archiveSnippetSegments(station, start, seconds)
      : await liveSnippetSegments(station, seconds)
  } catch (e) {
    return sendText(res, 502, `抓音失败：${String(e?.message ?? e)}`)
  }
  if (!picked.segments.length) return sendText(res, 502, '没有取到任何分片')

  const parts = await mapPool(picked.segments, 4, async (seg) => {
    const upstream = await fetch(seg.url, {
      // 跟 pipeSegment 同一条规矩：radiko 的分片**不能**带 radiko 头，直连台必须带浏览器头。
      headers: picked.meta.kind === 'radiko' ? {} : { ...DIRECT_HEADERS },
      redirect: 'follow',
    })
    return upstream.ok ? Buffer.from(await upstream.arrayBuffer()) : Buffer.alloc(0)
  })
  let audio = Buffer.concat(parts)
  if (looksLikeTS(audio)) audio = Buffer.from(tsToADTS(audio))
  if (!audio.length) return sendText(res, 502, '分片是空的，或者 TS 里没找到 AAC 流')

  send(res, 200, {
    'Content-Type': 'audio/aac',
    'Cache-Control': 'no-store',
    'X-Snippet-Seconds': snippetSpan(picked.segments).toFixed(1),
  }, audio)
}

/// 直播：取 chunklist **末尾**够 `seconds` 的那几个分片（贴着直播边缘，也就是用户在听的地方）。
/// chunklist 通常本来就有 25~30 秒，一次够；不够才多轮询几次 —— 上游每
/// targetduration 秒才换一批，所以最多等 3 轮 × 2 秒，硬等下去没有意义。
async function liveSnippetSegments(station, seconds) {
  const entry = await liveEntry(station)
  const master = await fetchPlaylist(entry.url, entry.meta)
  if (!master.ok) throw new Error(`上游 playlist 失败：HTTP ${master.status}`)
  const text = await master.text()
  const base = master.url || entry.url

  // master 里的变体地址不带 `.m3u8`，所以判类型只能看内容（跟 lib/hls.mjs 同一个坑）。
  const media = isMediaPlaylist(text)
  const chunklist = media ? base : firstURI(text, base)
  if (!chunklist) throw new Error('master 里没有变体地址')

  const seen = new Set()
  const all = []
  const take = (list) => {
    for (const seg of list) {
      if (seen.has(seg.url)) continue
      seen.add(seg.url)
      all.push(seg)
    }
  }
  if (media) take(collectSegments(text, base))

  for (let round = 0; round < 4 && snippetSpan(all) < seconds; round++) {
    if (all.length) await sleep(2000)
    const upstream = await fetchPlaylist(chunklist, entry.meta)
    if (!upstream.ok) break
    const body = await upstream.text()
    if (!isMediaPlaylist(body)) break
    take(collectSegments(body, upstream.url || chunklist))
  }

  const tail = []
  for (let i = all.length - 1; i >= 0 && snippetSpan(tail) < seconds; i--) tail.unshift(all[i])
  return { segments: tail, meta: entry.meta }
}

/// 存档（タイムフリー）：只要 `start` 落在的那一个 5 分钟窗口，从头取够 `seconds`。
async function archiveSnippetSegments(station, startMS, seconds) {
  if (station.direct) throw new Error('ListenRadio 没有存档')
  const endMS = Math.min(startMS + 300_000, Date.now() - 5_000)
  if (endMS <= startMS) throw new Error('这个位置还没播出')
  const meta = { kind: 'radiko', area: station.areaID }
  const t = await radiko.token(station.areaID)
  const base = await radiko.playlistBase(station.id, { timefree: true })
  const ft = pg.epochToJSTStamp(startMS)
  const url = timefreeWindow({
    base, stationID: station.id, lsid: t.userID, ft, to: pg.epochToJSTStamp(endMS), seek: ft,
  })
  const head = []
  for (const seg of await windowSegments(url, meta)) {
    if (snippetSpan(head) >= seconds) break
    head.push(seg)
  }
  return { segments: head, meta }
}

/// 查曲库：`POST /api/recognize`，body `{ uri, samplems }`（指纹是浏览器算好的）。
/// 这里只替它去打 `amp.shazam.com` —— 那个接口不给 CORS，还要伪装成 iPhone 客户端。
async function handleRecognize(req, res) {
  if ((req.method ?? 'GET').toUpperCase() !== 'POST') {
    return sendJSON(res, 405, { error: '识曲要用 POST' })
  }
  let body
  try {
    body = JSON.parse(await readBody(req))
  } catch (e) {
    return sendJSON(res, 400, { error: `body 不是 JSON：${String(e?.message ?? e)}` })
  }
  // 12 秒那条硬规矩：整段 ~20 秒的指纹上游只回一个**没有 track 的 200**，
  // 跟「这首歌不在库里」长得一模一样。所以宁可在这里拦住，也别让它伪装成没匹配上。
  if (Number(body?.samplems) > 13_000) {
    return sendJSON(res, 400, {
      error: `指纹 ${body.samplems} 毫秒：超过 ~12 秒时 amp.shazam.com 只回 200 空壳，得先裁短`,
    })
  }
  try {
    const out = await shazam.recognize({ uri: body?.uri, samplems: body?.samplems })
    sendJSON(res, 200, { match: out.match })
  } catch (e) {
    sendJSON(res, 502, { error: String(e?.message ?? e) })
  }
}

/// 指纹算法要在浏览器里跑，但服务端也在用同一份文件（`lib/shazam.mjs`）——
/// 往 public/ 复制一份迟早会漂，所以开一个只读白名单把那一个文件送出去。
/// 必须以 `text/javascript` 发，module worker 才肯 import。
const SHARED_LIB = new Set(['shazam.mjs'])

async function handleLib(res, name) {
  if (!SHARED_LIB.has(name)) return sendText(res, 403, `不提供这个文件：${name}`)
  try {
    const body = await readFile(join(here, 'lib', name))
    send(res, 200, { 'Content-Type': MIME['.js'], 'Cache-Control': 'no-cache' }, body)
  } catch {
    sendText(res, 404, '没有这个文件')
  }
}

// MARK: - 录制
//
// iOS 版的录制受制于「App 随时会被杀掉」，web 版反过来：这是一个一直开着的 Node 进程，
// 所以**录制在服务端做**（README 里原来那句「浏览器不能后台长时间录流落盘」说的是浏览器，
// 不是这个进程）。落盘、拆容器、拼存档全在这边，浏览器只负责按按钮和放文件。
//
// 三条路：
//   - **实时录制**：按一下开始，贴着直播边缘录（`lib/recorder.mjs` 的 `captureLive`）。
//   - **下载存档**：番組表里对着一档已经播完的 radiko 节目直接把整档存成文件。
//   - **预约录制**：到点自动执行，策略见 `lib/reservations.mjs` 顶部
//     （radiko 等播完下存档，直连台只能实时录）。
//
// 容器判定与「先拿到分片再建文件」那两条规矩在 `lib/recorder.mjs`，别在这里重复。

const library = await new Library(REC_DIR).open()
const reservations = await new Reservations(REC_DIR).open()

/// 正在进行的实时录制：录音 id → job。停止靠 `job.cancelled`，收尾靠 `await job.task`。
const liveJobs = new Map()
/// 正在下载的存档：录音 id → job（带进度，前端轮询显示）。
const archiveJobs = new Map()

const newID = () => `${Date.now().toString(36)}${Math.random().toString(36).slice(2, 6)}`

/// 取一个分片的字节。跟 `pipeSegment` 同一条规矩：**radiko 的分片不能带 radiko 头**
/// （带了 403），直连台反过来必须带浏览器头。
async function fetchSegmentBytes(seg, meta) {
  const res = await fetch(seg.url, {
    headers: meta?.kind === 'radiko' ? {} : { ...DIRECT_HEADERS },
    redirect: 'follow',
  })
  if (!res.ok) throw new Error(`分片 HTTP ${res.status}`)
  return Buffer.from(await res.arrayBuffer())
}

/// 录制用的直播会话：每次 `pull()` 回当前 chunklist 的分片列表。
///
/// radiko 直播的 chunklist 背后是一个**约一分钟不轮询就 404** 的会话（见 README 第 2 条）。
/// 录制会连着轮几小时，中途上游抖一下就可能把会话丢掉，所以取不到时自己从入口地址
/// 重来一遍 —— 录着的这条文件不该因为换了会话而中断。
function liveSession(station) {
  let chunklist = null
  let meta = null

  const reset = async () => {
    const entry = await liveEntry(station)
    meta = entry.meta
    const master = await fetchPlaylist(entry.url, meta)
    if (!master.ok) throw new Error(`上游 playlist 失败：HTTP ${master.status}`)
    const text = await master.text()
    const base = master.url || entry.url
    // master 里的变体地址不带 `.m3u8`，所以只能看内容判（跟 lib/hls.mjs 同一个坑）。
    if (isMediaPlaylist(text)) {
      chunklist = base
      return { text, base }
    }
    const variant = firstURI(text, base)
    if (!variant) throw new Error('master 里没有变体地址')
    chunklist = variant
    const child = await fetchPlaylist(variant, meta)
    if (!child.ok) throw new Error(`上游 chunklist 失败：HTTP ${child.status}`)
    return { text: await child.text(), base: child.url || variant }
  }

  return {
    get meta() { return meta },
    async pull() {
      let got = null
      if (chunklist) {
        const res = await fetchPlaylist(chunklist, meta)
        if (res.ok) got = { text: await res.text(), base: res.url || chunklist }
      }
      if (!got || !isMediaPlaylist(got.text)) got = await reset()
      return {
        segments: isMediaPlaylist(got.text) ? collectSegments(got.text, got.base) : [],
        init: mapURI(got.text, got.base),
      }
    },
  }
}

/// 开一条实时录制。立刻返回 job（不等录完）；`job.task` 是收尾用的 promise。
///
/// `until` 是自动停的时刻（预约录制传节目结束时间）；手动录制不传，靠 `stop` 停。
function startLiveRecording(station, { title = null, reservationID = null, until = null } = {}) {
  const id = newID()
  const writer = new SegmentWriter(library.dir, id)
  const session = liveSession(station)
  const job = {
    id, kind: 'live', stationID: station.id, stationName: station.name,
    title, reservationID, startedAt: Date.now(),
    seconds: 0, bytes: 0, cancelled: false, error: null,
  }
  liveJobs.set(id, job)

  job.task = (async () => {
    let note = null
    try {
      const out = await captureLive({
        pull: () => session.pull(),
        fetchBytes: (seg) => fetchSegmentBytes(seg, session.meta),
        writer,
        isCancelled: () => job.cancelled || (until != null && Date.now() >= until),
        onProgress: ({ seconds, bytes }) => { job.seconds = seconds; job.bytes = bytes },
      })
      note = out.note
    } catch (e) {
      note = String(e?.message ?? e)
    }
    liveJobs.delete(id)
    // 一个字节都没录到就别在库里留一条空记录，也别留下半截文件。
    if (!writer.bytes) {
      await writer.discard()
      return { ok: false, error: note ?? '没有录到任何音频' }
    }
    const done = await writer.finish()
    const rec = await library.add({
      id, title, stationID: station.id, stationName: station.name,
      source: 'live', date: job.startedAt,
      seconds: done.seconds, bytes: done.bytes, file: done.file, container: done.container,
      note,
    })
    console.log(`[录制] ${station.id} 实时录制结束：${done.seconds} 秒 / ${mb(done.bytes)}`)
    return { ok: true, recording: rec }
  })()

  console.log(`[录制] ${station.id} 开始实时录制（${id}）`)
  return job
}

const mb = (n) => `${(n / 1024 / 1024).toFixed(1)} MB`

/// 停一条实时录制并等它收尾（几秒内 —— 只等当前那一片写完）。
async function stopLiveRecording(id) {
  const job = liveJobs.get(id)
  if (!job) return { ok: false, error: `没有这条正在录的：${id}` }
  job.cancelled = true
  return await job.task
}

/// 下载一整档 タイムフリー 存档到文件。立刻返回 job，进度在 job 上（前端轮询）。
function startArchiveDownload(station, { start, end, title = null, reservationID = null } = {}) {
  const id = newID()
  const writer = new SegmentWriter(library.dir, id)
  const job = {
    id, kind: 'timefree', stationID: station.id, stationName: station.name,
    title, reservationID, startedAt: Date.now(),
    seconds: 0, bytes: 0, done: 0, total: 0, cancelled: false, error: null,
  }
  archiveJobs.set(id, job)

  job.task = (async () => {
    try {
      const { segments, meta } = await timefreeSegments(station, start, end)
      job.total = segments.length
      if (!segments.length) throw new Error('タイムフリー 没有取到任何分片')
      await writeAll({
        segments,
        fetchBytes: (seg) => fetchSegmentBytes(seg, meta),
        writer,
        isCancelled: () => job.cancelled,
        onProgress: (p) => { job.done = p.done; job.seconds = p.seconds; job.bytes = writer.bytes },
      })
    } catch (e) {
      job.error = String(e?.message ?? e)
    }
    archiveJobs.delete(id)
    if (!writer.bytes) {
      await writer.discard()
      return { ok: false, error: job.error ?? '存档里没有音频' }
    }
    const out = await writer.finish()
    const rec = await library.add({
      id, title, stationID: station.id, stationName: station.name,
      source: 'timefree', date: start,
      seconds: out.seconds, bytes: out.bytes, file: out.file, container: out.container,
      // 中途取不到几片也算成功（少几秒），但要把原因留在库里。
      note: job.error,
    })
    console.log(`[录制] ${station.id} 存档下载完成：${out.seconds} 秒 / ${mb(out.bytes)}`)
    return { ok: true, recording: rec }
  })()

  return job
}

// MARK: - 预约对账
//
// 15 秒一拍。**必须防重入**：启动时的第一拍和定时器可能叠在一起，同一条预约被下两遍
// 就会在录音库里出现重复条目（iOS 端踩过，为此加了 `isReconciling`）。

const TICK_MS = 15_000
let reconciling = false
let ticker = null

async function reconcile(now = Date.now()) {
  if (reconciling) return
  reconciling = true
  try {
    const { live, archive, missed } = reservations.plan(now)

    for (const r of live) {
      const station = stations.get(r.stationID)
      if (!station) {
        await reservations.setStatus(r.id, 'failed', `台表里没有 ${r.stationID}`)
        continue
      }
      await reservations.setStatus(r.id, 'recording')
      const job = startLiveRecording(station, { title: r.title, reservationID: r.id, until: r.end })
      // 收尾在录完之后（`until` 到点自己停），不占着这一拍。
      job.task.then(async (out) => {
        if (out.ok) await reservations.setStatus(r.id, 'completed')
        else await reservations.setStatus(r.id, 'missed', out.error)
      }).catch(async (e) => {
        await reservations.setStatus(r.id, 'failed', String(e?.message ?? e))
      })
    }

    for (const r of missed) {
      // 直连台没有存档，节目播完了还是 pending，说明整段都没在录 —— 真的错过了。
      if (r.status === 'pending') {
        await reservations.setStatus(r.id, 'missed', '直连台没有存档，节目播出时没在录')
      }
    }

    for (const r of archive) {
      const station = stations.get(r.stationID)
      if (!station) {
        await reservations.setStatus(r.id, 'failed', `台表里没有 ${r.stationID}`)
        continue
      }
      await reservations.setStatus(r.id, 'fetching')
      const job = startArchiveDownload(station, {
        start: r.start, end: r.end, title: r.title, reservationID: r.id,
      })
      job.task.then(async (out) => {
        if (out.ok) await reservations.setStatus(r.id, 'completed')
        // radiko 对一部分节目关掉了 タイムフリー —— 这时怎么重试都取不到，
        // 但也只能靠错误原因让人看出来（上游不会说「这档不给存档」）。
        else await reservations.backoff(r.id, out.error)
      }).catch(async (e) => {
        await reservations.backoff(r.id, String(e?.message ?? e))
      })
    }
  } catch (e) {
    console.error('[预约] 对账出错', e?.message ?? e)
  } finally {
    reconciling = false
  }
}

// MARK: - 录制 / 预约的接口
//
// 都很薄：解析参数 → 调上面那几个函数 → 回 JSON。真正的规矩在 lib/ 里。

async function jsonBody(req, res) {
  if ((req.method ?? 'GET').toUpperCase() !== 'POST') {
    sendJSON(res, 405, { error: '这个接口要用 POST' })
    return null
  }
  try {
    return JSON.parse(await readBody(req))
  } catch (e) {
    sendJSON(res, 400, { error: `body 不是 JSON：${String(e?.message ?? e)}` })
    return null
  }
}

/// job 里有 promise 与 writer，不能直接 JSON 化 —— 只把前端要显示的字段挑出来。
const jobView = (j) => ({
  id: j.id, kind: j.kind, stationID: j.stationID, stationName: j.stationName,
  title: j.title, startedAt: j.startedAt, seconds: j.seconds, bytes: j.bytes,
  done: j.done ?? null, total: j.total ?? null, reservationID: j.reservationID ?? null,
})

/// 录音库 + 正在进行的活儿。前端录制时每秒轮一次这个。
function handleRecList(res) {
  sendJSON(res, 200, {
    recordings: library.list(),
    live: [...liveJobs.values()].map(jobView),
    archive: [...archiveJobs.values()].map(jobView),
    reservations: reservations.list(),
    dir: library.dir,
  })
}

async function handleRecLive(req, res) {
  const body = await jsonBody(req, res)
  if (!body) return
  const station = stations.get(String(body.station ?? ''))
  if (!station) return sendJSON(res, 404, { error: `未知电台：${body.station}` })
  const already = [...liveJobs.values()].find((j) => j.stationID === station.id && !j.reservationID)
  if (already) return sendJSON(res, 200, { job: jobView(already), already: true })
  sendJSON(res, 200, { job: jobView(startLiveRecording(station, { title: body.title ?? null })) })
}

async function handleRecStop(req, res) {
  const body = await jsonBody(req, res)
  if (!body) return
  const out = await stopLiveRecording(String(body.id ?? ''))
  sendJSON(res, out.ok ? 200 : 502, out)
}

async function handleRecArchive(req, res) {
  const body = await jsonBody(req, res)
  if (!body) return
  const station = stations.get(String(body.station ?? ''))
  if (!station) return sendJSON(res, 404, { error: `未知电台：${body.station}` })
  if (station.direct) return sendJSON(res, 400, { error: 'ListenRadio 没有存档，只能实时录' })
  const start = Number(body.start), end = Number(body.end)
  const bad = archiveRangeError(start, end)
  if (bad) return sendJSON(res, 400, { error: bad })
  const job = startArchiveDownload(station, { start, end, title: body.title ?? null })
  sendJSON(res, 200, { job: jobView(job) })
}

async function handleRecDelete(req, res) {
  const body = await jsonBody(req, res)
  if (!body) return
  const id = String(body.id ?? '')
  if (liveJobs.has(id) || archiveJobs.has(id)) {
    return sendJSON(res, 409, { error: '这条还在录/还在下，先停下来再删' })
  }
  const gone = await library.remove(id)
  sendJSON(res, gone ? 200 : 404, gone ? { ok: true } : { error: `没有这条录音：${id}` })
}

async function handleReserveAdd(req, res) {
  const body = await jsonBody(req, res)
  if (!body) return
  const station = stations.get(String(body.station ?? ''))
  if (!station) return sendJSON(res, 404, { error: `未知电台：${body.station}` })
  const start = Number(body.start), end = Number(body.end)
  if (!Number.isFinite(start) || !Number.isFinite(end) || end <= start) {
    return sendJSON(res, 400, { error: 'start/end 参数不合法（epoch 毫秒）' })
  }
  const r = await reservations.add({
    // id 用节目 id（番組表要靠它判「已预约」）；自定义时段自己造一个。
    id: String(body.id || `custom-${station.id}-${start}`),
    stationID: station.id, stationName: station.name, areaID: station.areaID,
    direct: !!station.direct, title: String(body.title ?? ''), start, end,
  })
  // 已经播完的时段直接预约就是「补录」：这一拍就会去下存档。
  reconcile().catch(() => {})
  sendJSON(res, 200, { reservation: r, direct: !!station.direct })
}

async function handleReserveDelete(req, res) {
  const body = await jsonBody(req, res)
  if (!body) return
  const id = String(body.id ?? '')
  // 正在为它录着的，一并停掉（录到的那半截照常入库）。
  for (const j of liveJobs.values()) if (j.reservationID === id) j.cancelled = true
  const gone = await reservations.remove(id)
  sendJSON(res, gone ? 200 : 404, gone ? { ok: true } : { error: `没有这条预约：${id}` })
}

/// 放录音：`/rec/<录音 id>`（加 `?dl=1` 变成下载）。
///
/// **必须支持 Range**：不然浏览器拖不动进度条，Safari 还会先发探针、拿到 200 全量就
/// abort 再试，然后卡在 readyState 0 不动（跟 `/s/` 那个坑同一个，见 README 第 4 条）。
const REC_MIME = { '.aac': 'audio/aac', '.m4a': 'audio/mp4', '.ts': 'video/mp2t' }

async function handleRecordingFile(req, res, id, params) {
  const rec = library.get(id)
  if (!rec) return sendText(res, 404, `没有这条录音：${id}`)
  const path = library.pathFor(rec)
  let size
  try {
    size = (await stat(path)).size
  } catch {
    return sendText(res, 404, '录音文件已经不在磁盘上了')
  }

  const name = `${(rec.title || rec.stationName || 'recording').replace(/[/\\?%*:|"<>]/g, '_')}${extname(rec.file)}`
  const headers = {
    'Content-Type': REC_MIME[extname(rec.file).toLowerCase()] ?? 'application/octet-stream',
    'Accept-Ranges': 'bytes',
    'Cache-Control': 'no-store',
    // 文件名可能是日文/中文，只能走 RFC 5987 那种写法。
    'Content-Disposition':
      `${params?.get('dl') ? 'attachment' : 'inline'}; filename*=UTF-8''${encodeURIComponent(name)}`,
  }

  const hit = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? '')
  if (!hit) {
    res.writeHead(200, { ...headers, 'Content-Length': String(size) })
    return void createReadStream(path).pipe(res)
  }
  let from = hit[1] ? Number(hit[1]) : 0
  let to = hit[2] ? Number(hit[2]) : size - 1
  if (hit[1] === '' && hit[2]) {                      // `bytes=-500`：末尾 500 字节
    from = Math.max(0, size - Number(hit[2]))
    to = size - 1
  }
  if (!Number.isFinite(from) || from >= size || to < from) {
    return send(res, 416, { 'Content-Range': `bytes */${size}` }, '')
  }
  to = Math.min(to, size - 1)
  res.writeHead(206, {
    ...headers,
    'Content-Range': `bytes ${from}-${to}/${size}`,
    'Content-Length': String(to - from + 1),
  })
  createReadStream(path, { start: from, end: to }).pipe(res)
}

// MARK: - 静态文件

async function handleStatic(res, pathname) {
  let decoded
  try {
    decoded = decodeURIComponent(pathname === '/' ? '/index.html' : pathname)
  } catch {
    // `%ZZ` 之类的坏转义会让 decodeURIComponent 抛异常 —— 那是个 400，不该冒成 500。
    return sendText(res, 400, '路径不合法')
  }
  const rel = normalize(decoded).replace(/^[/\\]+/, '')
  const file = resolvePath(PUBLIC, rel)
  // 目录穿越防护：不做字符串比对（`%2e%2e`、`..\` 之类的花样太多），直接看解析后的
  // 绝对路径还在不在 public/ 里面。
  if (file !== PUBLIC && !file.startsWith(PUBLIC + sep)) return sendText(res, 403, '越界')
  try {
    const body = await readFile(file)
    send(res, 200, {
      'Content-Type': MIME[extname(rel).toLowerCase()] ?? 'application/octet-stream',
      'Cache-Control': 'no-cache',
    }, body)
  } catch {
    sendText(res, 404, '没有这个文件')
  }
}

// MARK: - 主循环

const doc = await loadStations()

/// 请求分发。**导出**给自检用：`web/test/check.mjs` 拿假的 req/res 走一遍所有不联网的
/// 分支（未知台、过期 token、越界路径、不给代理的域名…），不需要真占一个端口。
export async function handle(req, res) {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`)
  const path = url.pathname
  try {
    if (path === '/api/health') {
      return sendJSON(res, 200, {
        ok: true,
        radiko: radiko.profileSummary(),
        stations: stations.size,
        dials: doc.regions.length,
        cachedURLs: vault.size,
        recordings: library.list().length,
        recordingNow: liveJobs.size + archiveJobs.size,
        reservations: reservations.list().filter((r) => r.status === 'pending').length,
        recDir: library.dir,
        node: process.version,
      })
    }
    if (path === '/api/programs') return await handlePrograms(res, url.searchParams)
    if (path === '/api/image') return await handleImage(res, url.searchParams.get('u') ?? '')
    if (path === '/api/recognize') return await handleRecognize(req, res)

    if (path === '/api/rec') return handleRecList(res)
    if (path === '/api/rec/live') return await handleRecLive(req, res)
    if (path === '/api/rec/stop') return await handleRecStop(req, res)
    if (path === '/api/rec/archive') return await handleRecArchive(req, res)
    if (path === '/api/rec/delete') return await handleRecDelete(req, res)
    if (path === '/api/reservations') return await handleReserveAdd(req, res)
    if (path === '/api/reservations/delete') return await handleReserveDelete(req, res)

    const recFile = path.match(/^\/rec\/([^/]+)$/)
    if (recFile) return await handleRecordingFile(req, res, decodeURIComponent(recFile[1]), url.searchParams)

    const snippet = path.match(/^\/api\/snippet\/(.+)$/)
    if (snippet) return await handleSnippet(res, decodeURIComponent(snippet[1]), url.searchParams)

    const lib = path.match(/^\/lib\/([^/]+)$/)
    if (lib) return await handleLib(res, lib[1])

    const stream = path.match(/^\/stream\/(.+)\.m3u8$/)
    if (stream) return await handleStream(res, decodeURIComponent(stream[1]))

    const timefree = path.match(/^\/timefree\/(.+)\.m3u8$/)
    if (timefree) return await handleTimefree(res, decodeURIComponent(timefree[1]), url.searchParams)

    const nested = path.match(/^\/p\/([^/]+)\.m3u8$/)
    if (nested) return await handleNestedPlaylist(res, nested[1])

    const segment = path.match(/^\/s\/([^/]+)$/)
    if (segment) return await handleSegment(res, segment[1], req.headers.range)

    await handleStatic(res, path)
  } catch (e) {
    // 一个请求出错不该把服务器带走（尤其是播放中途 radiko 抖一下）。
    if (!res.headersSent) sendText(res, 500, `服务器错误：${String(e?.message ?? e)}`)
    else res.end()
    console.error(`[${path}]`, e?.message ?? e)
  }
}

// 被 import（自检）时不要占端口：只有直接 `node web/server.mjs` 才真的起服务。
const isMain = process.argv[1] && resolvePath(process.argv[1]) === fileURLToPath(import.meta.url)

/// 手机上真正能输入的地址。监听在通配地址时 `http://0.0.0.0:8787` 是打不开的，
/// 所以把每块网卡的 IPv4 都列出来 —— 顺带列上网卡名，因为 VPN / 代理软件
/// （utun*）也会挂一个地址上来，那个是连不通的，得让人看得出来选哪个。
export function reachableURLs(host, port) {
  if (host !== '0.0.0.0' && host !== '::' && host !== '') {
    return [{ url: `http://${host}:${port}`, via: null }]
  }
  const out = [{ url: `http://127.0.0.1:${port}`, via: '本机' }]
  for (const [name, list] of Object.entries(networkInterfaces())) {
    for (const i of list ?? []) {
      if (i.internal || i.family !== 'IPv4') continue
      if (i.address.startsWith('169.254.')) continue      // link-local，没设备连得上
      out.push({ url: `http://${i.address}:${port}`, via: name })
    }
  }
  return out
}

if (isMain) {
  createServer(handle).listen(PORT, HOST, () => {
    const p = radiko.profileSummary()
    const urls = reachableURLs(HOST, PORT)
    console.log(`JPRadio web  →  ${urls[0].url}${urls[0].via ? `  (${urls[0].via})` : ''}`)
    for (const u of urls.slice(1)) console.log(`                ${u.url}  (${u.via})`)
    console.log(`  台表：${stations.size} 台 / ${doc.regions.length} 条真实拨盘`)
    console.log(`  radiko 鉴权：${p.mode}（${p.app} ${p.version}，key ${p.keyBytes} 字节）`)
    const pending = reservations.list().filter((r) => r.status === 'pending').length
    console.log(`  录音库：${library.list().length} 条 · 预约 ${pending} 条 · ${library.dir}`)
    if (HOST !== '127.0.0.1' && HOST !== 'localhost') {
      console.log('  ⚠️  监听在非本机地址且没有任何鉴权：同网段的人都能用它收听、并借你的 IP 打 radiko。')
      console.log('     录制接口也一样是敞开的（能开录、能删你的录音）。')
    }
  })
  // 预约对账：启动先跑一次（把进程没开着的那段时间补上），之后 15 秒一拍。
  reconcile().catch(() => {})
  ticker = setInterval(() => { reconcile().catch(() => {}) }, TICK_MS)
  ticker.unref?.()
}
