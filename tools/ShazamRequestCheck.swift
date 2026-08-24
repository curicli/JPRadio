// Shazam 查曲库接口的请求/响应形状自测（在 Mac 上跑；在 JPRadio/ 之外，不进 iOS target）。
//
//   SWIFTC=/Applications/xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc
//   SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
//   "$SWIFTC" -sdk "$SDK" -o /tmp/shzcheck \
//       JPRadio/Models/Station.swift JPRadio/Player/ShazamWebMatcher.swift \
//       Tools/ShazamRequestCheck.swift
//   /tmp/shzcheck
//
// 为什么需要它：`amp.shazam.com` 是未公开接口，请求少一个开关、指纹 URI 的前缀写错，
// 结果都只是一句 400，而这台机器连不上它 —— 所以把「请求长什么样」和「响应怎么取字段」
// 这两件能离线判定的事钉死在这里，真机上只剩「网络与服务端是否接受」一个变量。
import Foundation

var failures = 0

func expect(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("✓ \(name)")
    } else {
        print("✗ \(name)\(detail().isEmpty ? "" : " — \(detail())")")
        failures += 1
    }
}

@main
struct ShazamRequestCheck {
static func main() {

// MARK: - 请求形状

let fingerprint = Data([0x80, 0x25, 0xfe, 0xca] + Array(repeating: UInt8(0x11), count: 60))
guard let request = try? ShazamWebMatcher.request(signature: fingerprint, durationMS: 12_000),
      let url = request.url,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
    print("✗ 请求组不出来"); exit(1)
}

expect("POST", request.httpMethod == "POST", request.httpMethod ?? "nil")
expect("主机 amp.shazam.com", components.host == "amp.shazam.com", components.host ?? "nil")

let segments = components.path.split(separator: "/").map(String.init)
// /discovery/v5/{语言}/{地区}/iphone/-/tag/{uuid}/{uuid}
expect("路径前缀 discovery/v5", segments.prefix(2) == ["discovery", "v5"], components.path)
// 语言段必须是**带地区的标签**（`en-US`），不是裸 `en`/`zh`：shazamio 这个已知能跑通的
// 客户端默认就是 `en-US`。裸语言码是真机上那次 400 的头号嫌疑，所以把它钉在这里，
// 免得哪天又被「跟着界面语言走」顺手改回去。
expect("语言段 en-US", segments[2] == "en-US", segments[2])
expect("地区段 JP", segments[3] == "JP", segments[3])
expect("设备段 iphone", segments[4] == "iphone", segments[4])
expect("tag 段", segments[5] == "-" && segments[6] == "tag", segments[5...6].joined(separator: "/"))
expect("两个 uuid", segments.count == 9
        && UUID(uuidString: segments[7]) != nil && UUID(uuidString: segments[8]) != nil,
       segments.dropFirst(7).joined(separator: "/"))
expect("uuid 大写", segments[7] == segments[7].uppercased(), segments[7])

let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
for (key, value) in ["sync": "true", "webv3": "true", "sampling": "true", "connected": "",
                     "shazamapiversion": "v3", "sharehub": "true",
                     "hubv5minorversion": "v5.1", "hidelb": "true", "video": "v3"] {
    expect("查询串 \(key)=\(value)", query[key] == value, query[key] ?? "缺失")
}

// MARK: - 请求头

let headers = request.allHTTPHeaderFields ?? [:]
expect("X-Shazam-Platform: IPHONE", headers["X-Shazam-Platform"] == "IPHONE",
       headers["X-Shazam-Platform"] ?? "缺失")
expect("带 X-Shazam-AppVersion", headers["X-Shazam-AppVersion"]?.isEmpty == false)
expect("Content-Type: application/json", headers["Content-Type"] == "application/json",
       headers["Content-Type"] ?? "缺失")
expect("带 User-Agent", headers["User-Agent"]?.isEmpty == false)
// Accept-Language 与路径里的语言段必须是同一个值 —— 两处不一致本身就够让对方拒收。
expect("Accept-Language 同语言段", headers["Accept-Language"] == segments[2],
       headers["Accept-Language"] ?? "缺失")

// MARK: - 可换形状（真机自检 diagnose 用的那几种）

// 自检要逐项替换 locale/地区/设备段/开关串，看服务端认哪一种。
// 这里只验「换了确实换到了 URL 上」——能不能过是真机上的事。
func shapedPath(_ shape: ShazamWebMatcher.Shape) -> (path: [String], query: [URLQueryItem]?) {
    guard let url = (try? ShazamWebMatcher.request(signature: fingerprint, durationMS: 12_000,
                                                   shape: shape))?.url,
          let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return ([], nil) }
    return (parts.path.split(separator: "/").map(String.init), parts.queryItems)
}

let shazamio = shapedPath(ShazamWebMatcher.Shape(locale: "en-US", country: "GB"))
expect("换地区 → GB", shazamio.path.count == 9 && shazamio.path[3] == "GB",
       shazamio.path.joined(separator: "/"))

let web = shapedPath(ShazamWebMatcher.Shape(locale: "ja-JP", device: "web"))
expect("换语言 → ja-JP", web.path.count == 9 && web.path[2] == "ja-JP", web.path.joined(separator: "/"))
expect("换设备段 → web", web.path.count == 9 && web.path[4] == "web", web.path.joined(separator: "/"))

let noFlags = shapedPath(ShazamWebMatcher.Shape(flags: false))
expect("关开关串 → 没有查询参数", noFlags.query == nil, "\(noFlags.query?.count ?? -1) 个")

// MARK: - 可换正文（自检的 Body 变体）

// 两轮真机自检定下来的事实：
//   ① URL 形状那七种全是 400，而对照组 GET 是 200 → 不通的不是 URL 而是正文；
//   ② `SHSignature.dataRepresentation` 外面套了一层 12 字节的 Apple 壳，
//      真签名（`0xcafe2580`）在偏移 12 处；剥掉壳就不再是 400。
// 所以「剥壳剥对了」是识曲能不能用的命门，钉在这里 —— 这一步错了，真机上只会回一句 400。
//
// 造一份和真机同构的壳：魔数 0x25802580、版本 2、载荷偏移 12，其后是真签名的头。
let payload = Data([0x80, 0x25, 0xfe, 0xca] + Array(repeating: UInt8(0x11), count: 60))
let appleSig = Data([0x80, 0x25, 0x80, 0x25, 0x02, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00]) + payload

func sentBody(_ variant: ShazamWebMatcher.Body, _ signature: Data = appleSig) -> (sig: Data, samplems: Int) {
    let prefix = "data:audio/vnd.shazam.sig;base64,"
    guard let data = (try? ShazamWebMatcher.request(signature: signature, durationMS: 12_000,
                                                    body: variant))?.httpBody,
          let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let part = json["signature"] as? [String: Any],
          let uri = part["uri"] as? String, uri.hasPrefix(prefix),
          let bytes = Data(base64Encoded: String(uri.dropFirst(prefix.count)))
    else { return (Data(), -1) }
    return (bytes, part["samplems"] as? Int ?? -1)
}

let standard = sentBody(.standard)
expect("standard：剥掉 12 字节的壳", standard.sig == payload,
       standard.sig.prefix(4).map { String(format: "%02x", $0) }.joined() + "/\(standard.sig.count)B")
expect("standard：samplems 是毫秒", standard.samplems == 12_000, "\(standard.samplems)")

let wrapped = sentBody(.wrapped)
expect("wrapped：原样送（对照组）", wrapped.sig == appleSig, "\(wrapped.sig.count) 字节")

let counted = sentBody(.sampleCount)
// shazamio 新版核心送的是采样数，16 kHz 下与毫秒差 16 倍。
expect("sampleCount：samplems = 毫秒 × 16", counted.samplems == 192_000, "\(counted.samplems)")
expect("sampleCount：同样剥壳", counted.sig == payload, "\(counted.sig.count) 字节")

// 偏移是从字节 8 读出来的、不是写死 12：壳变长也要跟得上。
let longShell = Data([0x80, 0x25, 0x80, 0x25, 0x02, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
                      0xde, 0xad, 0xbe, 0xef]) + payload
expect("按偏移字段剥（16 字节的壳）", ShazamWebMatcher.unwrap(longShell) == payload,
       "\(ShazamWebMatcher.unwrap(longShell).count) 字节")

// 偏移处不是 0xcafe2580 / 数据太短 / 根本没有壳：一律原样返回，不能崩也不能截错。
let bogus = Data([0x80, 0x25, 0x80, 0x25, 0x02, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00])
    + Data(repeating: 0x11, count: 40)
expect("偏移处没有 magic → 原样", ShazamWebMatcher.unwrap(bogus) == bogus)
expect("偏移越界 → 原样", ShazamWebMatcher.unwrap(
    Data([0x80, 0x25, 0x80, 0x25, 0x02, 0x00, 0x00, 0x00, 0xff, 0x00, 0x00, 0x00])
        + Data(repeating: 0x11, count: 40)).count == 52)
expect("已经是裸签名 → 原样", ShazamWebMatcher.unwrap(payload) == payload)
let stub = Data([0x80, 0x25])
expect("过短 → 原样", ShazamWebMatcher.unwrap(stub) == stub)
expect("过短也组得出请求",
       (try? ShazamWebMatcher.request(signature: stub, durationMS: 1_000)) != nil)

// 头 64 字节的十六进制转写 + 特征串定位（真机报告里的 hex/find 两行）。
let look = ShazamWebMatcher.inspect(appleSig)
expect("inspect 打出十六进制", look.contains("80258025 02000000 0c000000 8025feca"), look)
expect("inspect 报出真签名的偏移", look.contains("cafe2580@12"), look)
expect("inspect 报出实际送出的形状", look.contains("sent sig 8025feca/64B"), look)
expect("inspect 找不到就报 -", ShazamWebMatcher.inspect(Data(repeating: 0x11, count: 40))
        .contains("cafe2580@-"))

// MARK: - 请求正文

guard let body = request.httpBody,
      let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
    print("✗ 正文不是 JSON"); exit(1)
}

expect("正文五个键", Set(json.keys) == ["timezone", "signature", "timestamp", "context", "geolocation"],
       json.keys.sorted().joined(separator: ","))
let signature = json["signature"] as? [String: Any] ?? [:]
expect("samplems = 12000", signature["samplems"] as? Int == 12_000, "\(signature["samplems"] ?? "缺失")")

let uri = signature["uri"] as? String ?? ""
let prefix = "data:audio/vnd.shazam.sig;base64,"
expect("指纹 URI 前缀", uri.hasPrefix(prefix), String(uri.prefix(40)))
// base64 必须能原样解回指纹字节：编错了服务端只会回一句 400，在这里挡住。
let decoded = Data(base64Encoded: String(uri.dropFirst(prefix.count)))
expect("指纹 base64 可还原", decoded == fingerprint, "\(decoded?.count ?? -1) 字节")

let timestamp = json["timestamp"] as? Int ?? 0
expect("timestamp 是毫秒", timestamp > 1_600_000_000_000 && timestamp < 4_000_000_000_000, "\(timestamp)")
expect("timezone 非空", (json["timezone"] as? String)?.isEmpty == false)

// 每次请求要换一对 uuid（照抄 Shazam 客户端的行为；固定值容易被认成重放）。
let again = try? ShazamWebMatcher.request(signature: fingerprint, durationMS: 12_000)
expect("uuid 每次不同", again?.url?.path != components.path,
       again?.url?.path ?? "nil")

// MARK: - 响应解析

/// 真实形状的一份应答（字段名与嵌套照 Shazam 的 `discovery/v5` 回应来）。
let sample = #"""
{
  "matches": [{"id": "1234567", "offset": 12.3, "timeskew": 0.0001, "frequencyskew": 0.0}],
  "timestamp": 1700000000000,
  "timezone": "Asia/Tokyo",
  "track": {
    "layout": "5", "type": "MUSIC", "key": "1234567",
    "title": "Lemon", "subtitle": "米津玄師",
    "images": {
      "background": "https://example.com/bg.jpg",
      "coverart": "https://example.com/400x400.jpg",
      "coverarthq": "https://example.com/800x800.jpg",
      "joecolor": "b:000000"
    },
    "hub": {
      "type": "APPLEMUSIC",
      "actions": [
        {"name": "apple", "type": "applemusicplay", "id": "1445017264"},
        {"name": "apple", "type": "uri", "uri": "https://audio-ssl.itunes.apple.com/preview.m4a"}
      ],
      "options": [{
        "caption": "OPEN",
        "actions": [
          {"name": "hub:applemusic:deeplink", "type": "applemusicopen",
           "uri": "https://music.apple.com/jp/album/lemon/1445017264?i=1445017265"}
        ]
      }]
    },
    "sections": [{"type": "SONG", "metadata": [{"title": "アルバム", "text": "Lemon"}]}],
    "url": "https://www.shazam.com/track/1234567/lemon",
    "genres": {"primary": "J-Pop"}
  }
}
"""#

func track(_ text: String) -> [String: Any] {
    let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    return root?["track"] as? [String: Any] ?? [:]
}

let matched = ShazamWebMatcher.parse(track(sample))
expect("曲名", matched?.title == "Lemon", matched?.title ?? "nil")
expect("演唱者取 subtitle", matched?.artist == "米津玄師", matched?.artist ?? "nil")
// 有高清封面就用高清的：卡片上那张图放得不小，400px 明显发虚。
expect("封面优先 coverarthq",
       matched?.artworkURL?.absoluteString == "https://example.com/800x800.jpg",
       matched?.artworkURL?.absoluteString ?? "nil")
expect("Apple Music 深链取 hub.options",
       matched?.appleMusicURL?.host == "music.apple.com",
       matched?.appleMusicURL?.absoluteString ?? "nil")

// 只有 400px 封面（老曲目常见）：退回 coverart，不能变成没有封面。
let lowRes = #"""
{"track": {"title": "A", "subtitle": "B",
           "images": {"coverart": "https://example.com/400x400.jpg"},
           "url": "https://www.shazam.com/track/1/a"}}
"""#
expect("无 coverarthq 时退回 coverart",
       ShazamWebMatcher.parse(track(lowRes))?.artworkURL?.absoluteString
        == "https://example.com/400x400.jpg",
       ShazamWebMatcher.parse(track(lowRes))?.artworkURL?.absoluteString ?? "nil")

// hub 里只有试听音频、没有 Apple Music 深链：退回 Shazam 曲目页，
// 否则卡片上那个「去听」按钮会指向一个 .m4a 直链。
let noDeeplink = #"""
{"track": {"title": "A", "subtitle": "B",
           "hub": {"options": [{"actions": [
             {"type": "uri", "uri": "https://audio-ssl.itunes.apple.com/preview.m4a"}]}]},
           "url": "https://www.shazam.com/track/1/a"}}
"""#
expect("无深链时退回 Shazam 曲目页",
       ShazamWebMatcher.parse(track(noDeeplink))?.appleMusicURL?.absoluteString
        == "https://www.shazam.com/track/1/a",
       ShazamWebMatcher.parse(track(noDeeplink))?.appleMusicURL?.absoluteString ?? "nil")

// 连 url 都没有：允许没有链接，但不能因此整条解析失败。
let bare = #"{"track": {"title": "A"}}"#
let bareMatch = ShazamWebMatcher.parse(track(bare))
expect("只有曲名也算匹配上", bareMatch?.title == "A" && bareMatch?.artist == "",
       bareMatch.map { "\($0.title)/\($0.artist)" } ?? "nil")
expect("无链接时为 nil", bareMatch?.appleMusicURL == nil && bareMatch?.artworkURL == nil)

// 没有 title 的 track（对方改了字段名 / 回了个非音乐条目）：当成没匹配上，
// 而不是给界面一张空卡片。
expect("无 title → nil", ShazamWebMatcher.parse(["subtitle": "B"]) == nil)

// MARK: - 收尾

print("")
print(failures == 0 ? "全部通过" : "\(failures) 项失败")
if failures > 0 { exit(1) }
}
}
