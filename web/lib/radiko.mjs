// radiko 鉴权（auth1 → partialkey → auth2）与直播流地址解析。
//
// 这是 iOS 端 ios/JPRadio/Radiko/{RadikoProfile,RadikoAuth,RadikoStream}.swift 的等价实现。
// **浏览器里做不到这一步**，所以必须放在服务端：
//   1. `api.radiko.jp` 不给跨域响应头（无 CORS），网页端 fetch 直接被浏览器拦掉；
//   2. 拉流的每个 playlist 请求要带自定义头 `X-Radiko-AuthToken`，那会触发 preflight，
//      radiko 同样不回应；
//   3. 境外绕过靠 auth2 时上报伪造 GPS，浏览器不允许伪造这个头部之外的身份信息。
// 于是 web 版的形状是「本机 Node 反代 + 静态前端」：鉴权、加头、改写 playlist 都在这里做，
// 浏览器只看到同源的 m3u8 与分片。
//
// full key 不在这里复制一份，而是**启动时从 RadikoProfile.swift 里抠出来**（见 `fullKey()`）：
// 那 167KB base64 在仓库里只该存在一处，两处早晚会漂。
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const profileSwift = join(here, '..', '..', 'ios', 'JPRadio', 'Radiko', 'RadikoProfile.swift')

const AUTH1 = 'https://api.radiko.jp/v2/api/auth1'
const AUTH2 = 'https://api.radiko.jp/v2/api/auth2'

/// radiko 网页端公开 key（日本境内/日本 IP 可直接用），抠不到安卓 key 时的兜底。
const PC_HTML5 = {
  appName: 'pc_html5',
  appVersion: '0.0.1',
  device: 'pc',
  userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15',
  fullKey: Buffer.from('bcd151073c03b352e1ef2fd66c32209da9ca0afa', 'utf8'),
  sendsLocation: false,
}

/// 伪造 GPS 的基准坐标，与 RadikoProfile.swift 的 `RadikoGPS.coordinates` 同值。
export const GPS = {
  JP13: [35.6895, 139.6917],   // 東京
  JP27: [34.6863, 135.52],     // 大阪
  JP23: [35.1802, 136.9066],   // 愛知（名古屋）
  JP01: [43.0643, 141.3469],   // 北海道（札幌）
  JP40: [33.6066, 130.4181],   // 福岡
  JP47: [26.2124, 127.6809],   // 沖縄（那覇）
  JP14: [35.4475, 139.6425],   // 神奈川（横浜）
}

/// 复刻 rajiko `genGPS`：基准坐标 ±0~0.025 度（约 0~2.7km）的随机微偏移，再拼 ",gps"。
/// 每次鉴权都抖一下，免得同一坐标反复出现。
export function location(areaID) {
  const [lat, lon] = GPS[areaID] ?? GPS.JP13
  const jitter = () => Math.random() * 0.025 * (Math.random() < 0.5 ? 1 : -1)
  return `${(lat + jitter()).toFixed(6)},${(lon + jitter()).toFixed(6)},gps`
}

/// 32 位随机十六进制 user id（复刻 rajiko genRandomInfo）。拉流的 lsid 复用它。
export function randomUserID() {
  let s = ''
  for (let i = 0; i < 32; i++) s += Math.floor(Math.random() * 16).toString(16)
  return s
}

/// partialkey = base64( fullKey[offset .. offset+length] )。
/// 越界就退回整把 key —— 与 iOS 端 `RadikoAuthenticator.partialKey` 行为一致，
/// 反正 auth2 会拒，不如让错误停在服务器这一侧而不是抛异常中断。
export function partialKey(fullKey, offset, length) {
  if (offset < 0 || length <= 0 || offset + length > fullKey.length) {
    return fullKey.toString('base64')
  }
  return fullKey.subarray(offset, offset + length).toString('base64')
}

let cachedProfile
/// 当前生效的 profile：能从 RadikoProfile.swift 抠到安卓 key 就用安卓绕过，否则 pc_html5。
export function profile() {
  if (cachedProfile) return cachedProfile
  cachedProfile = androidProfile() ?? PC_HTML5
  return cachedProfile
}

function androidProfile() {
  let text
  try {
    text = readFileSync(profileSwift, 'utf8')
  } catch {
    return null
  }
  const pick = (name) => text.match(new RegExp(`static let ${name} = "([^"]*)"`))?.[1] ?? ''
  const appName = pick('androidAppName')
  const appVersion = pick('androidAppVersion')
  const keyB64 = pick('androidFullKeyBase64')
  if (!appName || !appVersion || !keyB64) return null
  const fullKey = Buffer.from(keyB64, 'base64')
  // radiko 新版把 full key 藏在一整张 JPEG 里（partialkey 只是从中按 offset/length 切片），
  // 所以这里顺手验一下确实解出了 JPEG：base64 被编辑器截断过的话（末尾 `==` 常被吞）
  // 长度会不对，而那种错误在 auth2 才报出来就很难查了。
  if (fullKey.length < 1024) return null
  return {
    appName,
    appVersion,
    device: '34.Google Pixel 6',
    userAgent: `radiko/${appVersion} (Android;Android14, Google Pixel 6)`,
    fullKey,
    sendsLocation: true,
  }
}

/// profile 的可读描述（启动横幅与 /api/health 用；不含 key 本身）。
export function profileSummary() {
  const p = profile()
  return {
    app: p.appName,
    version: p.appVersion,
    keyBytes: p.fullKey.length,
    spoofsLocation: p.sendsLocation,
    mode: p.sendsLocation ? 'android + GPS（境外可听）' : 'pc_html5（仅日本境内/日本 IP）',
  }
}

function commonHeaders(p, userID) {
  return {
    'X-Radiko-App': p.appName,
    'X-Radiko-App-Version': p.appVersion,
    'X-Radiko-Device': p.device,
    'X-Radiko-User': userID,
    'User-Agent': p.userAgent,
  }
}

/// 按地区缓存 token。**不能跨地区复用**：拿东京的凭证去拉大阪的流会被判越区
/// （iOS 端曾经踩过这个坑，见 RadikoAuth.swift 的 cachedByArea）。
const tokens = new Map()
const TOKEN_TTL_MS = 300_000

/// 取某地区一个可用 token；`force` 为真时无条件重新鉴权（拉流 401 / 自动重连时用）。
export async function token(areaID = 'JP13', { force = false } = {}) {
  const hit = tokens.get(areaID)
  if (!force && hit && Date.now() - hit.acquiredAt < TOKEN_TTL_MS) return hit
  const fresh = await authenticate(areaID)
  tokens.set(areaID, fresh)
  return fresh
}

async function authenticate(areaID) {
  const p = profile()
  const userID = randomUserID()

  const r1 = await fetch(AUTH1, { headers: commonHeaders(p, userID) })
  if (!r1.ok) throw new Error(`auth1 失败：HTTP ${r1.status}`)
  const authToken = r1.headers.get('x-radiko-authtoken')
  const offset = Number(r1.headers.get('x-radiko-keyoffset'))
  const length = Number(r1.headers.get('x-radiko-keylength'))
  if (!authToken || !Number.isFinite(offset) || !Number.isFinite(length)) {
    throw new Error('auth1 响应缺少鉴权头（X-Radiko-AuthToken / KeyOffset / KeyLength）')
  }

  const headers = {
    ...commonHeaders(p, userID),
    'X-Radiko-AuthToken': authToken,
    'X-Radiko-Partialkey': partialKey(p.fullKey, offset, length),
  }
  if (p.sendsLocation) {
    headers['X-Radiko-Location'] = location(areaID)
    headers['X-Radiko-Connection'] = 'wifi'
  }
  const r2 = await fetch(AUTH2, { headers })
  if (!r2.ok) throw new Error(`auth2 失败：HTTP ${r2.status}`)

  // 响应体形如 "JP13,東京都,tokyo Japan"
  const resolvedArea = (await r2.text()).split(',')[0]?.trim() || areaID
  if (resolvedArea.toUpperCase() === 'OUT') {
    throw new Error('该地区受限（auth2 返回 OUT）——境外绕过未生效')
  }
  return { value: authToken, area: resolvedArea, userID, acquiredAt: Date.now() }
}

// MARK: - 直播流地址

const streamBaseCache = new Map()

/// 取某台的 `playlist_create_url`。挑 `areafree=0, timefree=0`（区域内 · 直播）那条：
/// areafree=1 的入口是给付费会员的，用 GPS 伪造出来的区域内 token 去请求会 403。
export async function playlistBase(stationID, { timefree = false } = {}) {
  const cacheKey = `${stationID}:${timefree ? 'tf' : 'live'}`
  const hit = streamBaseCache.get(cacheKey)
  if (hit) return hit
  const url = `https://radiko.jp/v3/station/stream/pc_html5/${encodeURIComponent(stationID)}.xml`
  const res = await fetch(url)
  if (!res.ok) throw new Error(`stream XML 失败：HTTP ${res.status}`)
  const entries = parseStreamXML(await res.text())
  const wanted = entries.filter((e) => e.timefree === timefree)
  const chosen = wanted.find((e) => !e.areafree) ?? wanted[0] ?? entries[0]
  const base = chosen?.url ?? (timefree ? FALLBACK_TIMEFREE : FALLBACK_LIVE)
  streamBaseCache.set(cacheKey, base)
  return base
}

const FALLBACK_LIVE = 'https://si-f-radiko.smartstream.ne.jp/so/playlist.m3u8'
const FALLBACK_TIMEFREE = 'https://tf-f-rpaa-radiko.smartstream.ne.jp/tf/playlist.m3u8'

/// 解析 `<url areafree=".." timefree=".."><playlist_create_url>…</playlist_create_url></url>`。
export function parseStreamXML(xml) {
  const entries = []
  const re = /<url\b([^>]*)>([\s\S]*?)<\/url>/g
  let m
  while ((m = re.exec(xml))) {
    const attrs = m[1]
    const inner = m[2]
    const url = inner.match(/<playlist_create_url>([\s\S]*?)<\/playlist_create_url>/)?.[1]?.trim()
    if (!url) continue
    entries.push({
      areafree: /areafree="1"/.test(attrs),
      timefree: /timefree="1"/.test(attrs),
      url,
    })
  }
  return entries
}

/// 拼出可直接请求的直播 m3u8 地址（`l=15` 与 iOS 端一致）。
export function liveURL(base, stationID, lsid) {
  const u = new URL(base)
  u.searchParams.set('station_id', stationID)
  u.searchParams.set('l', '15')
  u.searchParams.set('lsid', lsid)
  u.searchParams.set('type', 'b')
  return u.toString()
}
