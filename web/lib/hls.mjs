// m3u8 改写：把上游 playlist 里的地址换成本机反代地址。
//
// 为什么非改不可：radiko 的 playlist 请求要带 `X-Radiko-AuthToken`，分片请求**不能**带
// （带了反而 403）；ListenRadio 的 CDN 又按 Referer/Origin 防盗链。浏览器无法为 HLS 内部
// 请求分别设头，所以每一层地址都得先回到本机，由服务端按目标类型加对头再转发。
//
// 只改地址、不动其它任何一行：`#EXTINF`、`#EXT-X-*` 的时间与序号原样留着，
// hls.js / Safari 才能正确算缓冲与断点。

/// 一行是不是 URI 行（既不是空行也不是标签）。
const isURILine = (line) => line.length > 0 && !line.startsWith('#')

/// URI 指向的是嵌套 playlist 还是媒体分片。**只在没有更可靠线索时**才用：
/// 按扩展名判断（去掉 query 再看）。
export function uriKind(uri) {
  const path = uri.split('?')[0].split('#')[0]
  return /\.m3u8?$/i.test(path) ? 'playlist' : 'segment'
}

/// 标签里带 `URI="…"` 的那几个，指向什么必须**写死**、不许靠扩展名猜：
/// 加密 key / 初始化段 / 分部分片是「按分片取」，备用轨与 I-frame 轨是嵌套 playlist。
const URI_ATTR_KIND = [
  [/^#EXT-X-(MEDIA|I-FRAME-STREAM-INF)\b/i, 'playlist'],
  [/^#EXT-X-(KEY|SESSION-KEY|MAP|PART|PRELOAD-HINT)\b/i, 'segment'],
]
const URI_ATTR_TAGS = /^#EXT-X-(KEY|MAP|MEDIA|SESSION-KEY|I-FRAME-STREAM-INF|PART|PRELOAD-HINT)\b/i

/**
 * @param {string} text     上游 m3u8 正文
 * @param {string} baseURL  该 m3u8 自己的绝对地址（相对路径按它解析）
 * @param {(absURL: string, kind: 'playlist'|'segment') => string} proxy
 *        把绝对上游地址换成本机地址
 */
export function rewritePlaylist(text, baseURL, proxy) {
  const out = []
  // `#EXT-X-STREAM-INF` 的下一个 URI 行**一定**是嵌套 playlist，跟扩展名没关系。
  // 这不是理论问题：radiko 直播的 master 里那条变体地址就不带 `.m3u8`，
  // 按扩展名猜会把 chunklist 当成 aac 分片直接透传 —— 里面的分片地址于是没被改写，
  // 浏览器会绕过反代直连 CDN（hls.js 那边就是一个取不到分片的 CORS 错误）。
  let variantNext = false
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '')
    if (isURILine(line)) {
      const abs = resolve(line, baseURL)
      const kind = variantNext ? 'playlist' : uriKind(line)
      variantNext = false
      out.push(abs ? proxy(abs, kind) : line)
      continue
    }
    if (/^#EXT-X-STREAM-INF\b/i.test(line)) variantNext = true
    if (URI_ATTR_TAGS.test(line)) {
      const kind = URI_ATTR_KIND.find(([re]) => re.test(line))?.[1] ?? 'segment'
      out.push(line.replace(/URI="([^"]*)"/gi, (whole, uri) => {
        const abs = resolve(uri, baseURL)
        return abs ? `URI="${proxy(abs, kind)}"` : whole
      }))
      continue
    }
    out.push(line)
  }
  return out.join('\n')
}

function resolve(uri, baseURL) {
  try {
    return new URL(uri, baseURL).toString()
  } catch {
    return null
  }
}

/// 从一段 chunklist 里取出 (时长, 分片绝对地址) 序列。
/// タイムフリー 要把好几个 5 分钟窗口的分片接成一条 VOD playlist（见 server.mjs），
/// 所以这一步得能单独拿出来用，也能单独自检。
export function collectSegments(text, baseURL) {
  const out = []
  let duration = 5
  for (const raw of text.split('\n')) {
    const line = raw.trim()
    if (line.startsWith('#EXTINF:')) {
      const value = Number.parseFloat(line.slice(8))
      if (Number.isFinite(value)) duration = value
      continue
    }
    if (!line || line.startsWith('#')) continue
    try {
      out.push({ duration, url: new URL(line, baseURL).toString() })
    } catch { /* 地址不合法就跳过这一片 */ }
  }
  return out
}

/// 这段 m3u8 是不是**媒体** playlist（里面直接是分片）。
/// master 里只有变体地址，拿 `collectSegments` 去收会把那条变体当成一个 5 秒分片 ——
/// タイムフリー 那边踩过：两小时的节目只拼出十几秒。
export const isMediaPlaylist = (text) => /^#EXTINF:/m.test(text)

/// 取 playlist 里第一条 URI（master 里就是那条变体地址）。
/// radiko 直播的 master 只有一条变体，重建会话时要靠它拿到新的 chunklist 地址。
export function firstURI(text, baseURL) {
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '').trim()
    if (!isURILine(line)) continue
    return resolve(line, baseURL)
  }
  return null
}

/// fMP4 流的初始化段（`#EXT-X-MAP:URI="…"`），没有就返回 null。
/// **录制**要用：把分片直接首尾相接只对裸 ADTS 成立，fMP4 缺了这一段整个文件解不开。
/// 播放路径不需要（`rewritePlaylist` 会把这个标签里的地址一并改写、原样交给播放器）。
export function mapURI(text, baseURL) {
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\r$/, '')
    if (!/^#EXT-X-MAP\b/i.test(line)) continue
    const uri = line.match(/URI="([^"]*)"/i)?.[1]
    const abs = uri ? resolve(uri, baseURL) : null
    if (abs) return { url: abs, duration: 0 }
  }
  return null
}

/// 上游地址 ⇄ 短 token 的映射。
///
// 不把上游地址明文塞进 query（`?u=https://…`）有两个实际原因：地址里带着 lsid 之类的
// 会话参数，出现在浏览器 network 面板与访问日志里没必要；而且分片地址长，逐条 encode
// 会让 playlist 体积翻倍。所以服务端发一个短 token，映射只活在内存里。
export class URLVault {
  #byToken = new Map()
  #byURL = new Map()
  #seq = 0

  /// 存一个上游地址，拿回短 token（同一地址重复存拿到同一个 token）。
  put(url, meta) {
    const existing = this.#byURL.get(url)
    if (existing) return existing
    const token = (++this.#seq).toString(36)
    this.#byToken.set(token, { url, meta })
    this.#byURL.set(url, token)
    // 直播流的分片地址一直在变，无上限会一路涨。留足几千条（够几小时连续收听
    // 与来回换台），超了就把最老的丢掉 —— 那些分片早就播过了，不会再被请求。
    if (this.#byToken.size > 8000) {
      const oldest = this.#byToken.keys().next().value
      const gone = this.#byToken.get(oldest)
      this.#byToken.delete(oldest)
      if (gone) this.#byURL.delete(gone.url)
    }
    return token
  }

  get(token) {
    return this.#byToken.get(token)
  }

  /// 把已发出的 token 改指到另一个上游地址（原地址的反查一并清掉）。
  /// radiko 直播的 chunklist 背后是个会存活期限的会话，重建之后播放器手里那条
  /// `/p/<token>.m3u8` 不该作废 —— 让同一个 token 指向新会话即可。
  retarget(token, url, meta) {
    const old = this.#byToken.get(token)
    if (!old) return false
    if (this.#byURL.get(old.url) === token) this.#byURL.delete(old.url)
    this.#byToken.set(token, { url, meta: meta ?? old.meta })
    this.#byURL.set(url, token)
    return true
  }

  get size() {
    return this.#byToken.size
  }
}
