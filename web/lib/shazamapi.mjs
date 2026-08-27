// 查曲库 —— `ios/JPRadio/Player/ShazamWebMatcher.swift` 的 Node 版，一个字段一个字段照抄。
//
// 打的是 Shazam iPhone 客户端自己在用的那个接口（`amp.shazam.com/discovery/v5/…`）。
// ShazamKit 的 `SHSession.match` 在浏览器里没有等价物，而这个接口只要
// 「指纹字节 + 一个 UUID」就肯回结果，所以 web 版走它。
//
// **它对请求形状很挑，而且挑错了不会告诉你**：locale 写成裸 `en` 会 400，
// 指纹带着 Apple 那 12 字节外壳（`SHSignature.dataRepresentation`）会 400，
// 而指纹算错、或者音频超过 ~12 秒，它一律回 `200` 加一个没有 `track` 的空壳
// —— 跟「真的没这首歌」长得一模一样。所以这里把形状抽成纯函数，
// 让 `test/check.mjs` 不联网也能把 URL、头、body 逐个钉住。
//
// 只给自己听用，别拿去做公开服务（跟 iOS 端同一句话）。

/// 请求形状。`locale` 必须是带地区的标签，`country` 决定曲库地区。
export const SHAPE = { locale: 'en-US', country: 'JP', device: 'iphone' }

/// 固定的查询串。`connected` 就是空值（客户端也这么发）。
const QUERY = {
  sync: 'true',
  webv3: 'true',
  sampling: 'true',
  connected: '',
  shazamapiversion: 'v3',
  sharehub: 'true',
  hubv5minorversion: 'v5.1',
  hidelb: 'true',
  video: 'v3',
}

/// 冒充 Shazam 14.1.0 / iOS 17.4。
/// **故意不发 `Accept-Encoding`** —— 让 undici 自己谈压缩并自己解，
/// 手写一个反而可能拿到没解压的 gzip。
const HEADERS = {
  'Content-Type': 'application/json',
  Accept: '*/*',
  'X-Shazam-Platform': 'IPHONE',
  'X-Shazam-AppVersion': '14.1.0',
  'User-Agent': 'Shazam/14.1.0 CFNetwork/1494.0.7 Darwin/23.4.0',
}

/// 组一次 tag 请求。所有会变的东西（两个 UUID、时间戳、时区）都能注入，
/// 这样测试里能算出确定的结果。
export function tagRequest({
  uri,
  samplems,
  shape = SHAPE,
  uuid = () => crypto.randomUUID(),
  now = () => Date.now(),
  timezone = () => Intl.DateTimeFormat().resolvedOptions().timeZone,
} = {}) {
  if (typeof uri !== 'string' || !uri.startsWith('data:audio/vnd.shazam.sig;base64,')) {
    throw new Error('指纹要是 data:audio/vnd.shazam.sig;base64,… 这种形状')
  }
  if (!Number.isFinite(samplems) || samplems <= 0) throw new Error(`samplems 不合法：${samplems}`)

  const path = `/discovery/v5/${shape.locale}/${shape.country}/${shape.device}/-/tag/${uuid()}/${uuid()}`
  const url = new URL(path, 'https://amp.shazam.com')
  for (const [k, v] of Object.entries(QUERY)) url.searchParams.set(k, v)

  return {
    url: url.toString(),
    method: 'POST',
    headers: { ...HEADERS, 'Accept-Language': shape.locale },
    body: JSON.stringify({
      timezone: timezone(),
      signature: { uri, samplems: Math.round(samplems) },
      timestamp: Math.round(now()),
      context: {},
      geolocation: {},
    }),
  }
}

/// 响应里的 `track` → 我们要的四个字段。没有 `title` 就当没匹配上。
export function parseTrack(track) {
  if (!track || typeof track !== 'object' || typeof track.title !== 'string') return null
  const images = track.images ?? {}
  return {
    title: track.title,
    artist: typeof track.subtitle === 'string' ? track.subtitle : '',
    artwork: images.coverarthq ?? images.coverart ?? null,
    appleMusic: appleMusicLink(track),
  }
}

/// Apple Music 深链：`hub.options[].actions[]` 里第一个带 `music.apple.com` 的 `uri`，
/// 找不到就退回 `track.url`（那是 shazam.com 的页面，总比没有好）。
function appleMusicLink(track) {
  const options = track.hub?.options
  if (Array.isArray(options)) {
    for (const option of options) {
      for (const action of option?.actions ?? []) {
        const uri = action?.uri
        if (typeof uri === 'string' && uri.includes('music.apple.com')) return uri
      }
    }
  }
  return typeof track.url === 'string' ? track.url : null
}

/// 真的去查一次。回 `{ match }`，`match` 为 `null` 就是没匹配上（那是正常结果，不是错误）。
///
/// 上游出错时抛的 `Error` 带着 HTTP 状态、响应开头 200 字节和指纹长度 ——
/// 这三样是当初在 iOS 上把 400 一个个试出来的唯一线索，别精简掉。
export async function recognize({ uri, samplems, shape = SHAPE, timeoutMS = 20_000 } = {}) {
  const req = tagRequest({ uri, samplems, shape })
  const signal = AbortSignal.timeout(timeoutMS)
  let res
  try {
    res = await fetch(req.url, { method: req.method, headers: req.headers, body: req.body, signal })
  } catch (e) {
    throw new Error(`连不上 amp.shazam.com：${e?.message ?? e}（sig ${uri.length - 33} 字符 base64）`)
  }
  const text = await res.text()
  if (!res.ok) {
    throw new Error(`amp.shazam.com HTTP ${res.status}：${text.slice(0, 200)}（sig ${uri.length - 33} 字符 base64）`)
  }
  let doc
  try {
    doc = JSON.parse(text)
  } catch {
    throw new Error(`响应不是 JSON：${text.slice(0, 200)}`)
  }
  return { match: parseTrack(doc?.track), retry: doc?.retryms ?? null }
}
