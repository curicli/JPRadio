import Foundation
import ShazamKit

/// 拿本机生成的 Shazam 指纹去查曲库 —— 但**不经过 Apple 的 ShazamKit 目录服务**，
/// 而是直接请求 Shazam 客户端自己在用的那个接口（`shazamio` 用的也是它）。
///
/// 为什么要这么绕：Apple 在 `SHSession.h` 里写得很明确 ——
/// 「Matching audio against the Shazam catalog requires enabling your app to access the
/// catalog. If you are using a custom catalog, you don't need to enable ShazamKit.」
/// 也就是说：
/// - **生成指纹**（`SHSignatureGenerator`）不需要任何能力，自定义曲库那条路就是这么用的；
/// - **拿指纹查 Shazam 官方曲库**（`SHSession` / `SHManagedSession`）才需要给 App ID
///   开 ShazamKit App Services，而那个开关只有付费开发者账号能勾
///   （免费账号硬把 `com.apple.developer.shazamkit` 写进 entitlements 只会让签名失败）。
///
/// 所以这里只把「查曲库」这一步换掉，指纹仍由 ShazamKit 在本机算 —— 免费账号也能识曲。
///
/// 代价说清楚：这是 Shazam 未公开的接口，不受任何契约保护，随时可能改字段、限流或直接拒绝，
/// 也不能拿去上架（个人自用编译安装是另一回事）。出错时 `ShazamWebError` 会把 HTTP 状态、
/// 响应开头和指纹自身的形状一起带出来，否则坏在哪一步根本无从判断。
enum ShazamWebMatcher {

    /// 匹配结果。字段与原先从 `SHMediaItem` 取的那几项一一对应，界面不用改。
    struct Match: Equatable {
        let title: String
        let artist: String
        let artworkURL: URL?
        let appleMusicURL: URL?
    }

    /// 请求里那几个「可能挑食」的维度。正常识曲用 `Shape()`，
    /// 自检（`diagnose`）时逐项换掉，看服务端到底认哪一种。
    ///
    /// `locale` 用的是**带地区的标签**（`en-US`），不是裸语言码：shazamio 这个已知能跑通的
    /// 客户端默认就是 `en-US`，而裸 `en`/`zh` 是我先前自己简化出来的，最初那次 400 的头号嫌疑。
    /// 返回的曲名/歌手来自曲库原文，与这个标签无关，所以固定用 `en-US` 不影响显示。
    struct Shape: Equatable {
        var locale = "en-US"
        var country = "JP"
        var device = "iphone"
        /// 那一串 `sync/webv3/sampling/...` 开关。
        var flags = true
    }

    /// 正文的几种送法。正常识曲用 `.standard`；自检时逐一试，看服务端认哪一种。
    ///
    /// `.standard` 为什么要剥壳，见 `unwrap` —— 那是真机自检定下来的结论：
    /// 原样送（`.wrapped`）一律 `400`，剥掉壳才被接受。
    enum Body: String {
        /// 剥掉 Apple 的外壳只送里面那份签名，`samplems` 填毫秒。识曲走的就是这条。
        case standard
        /// `SHSignature.dataRepresentation` 原样送（改之前的做法）。留着当对照组：
        /// 它要是哪天不再回 400，就说明服务端放宽了，可以不用剥壳。
        case wrapped
        /// 剥壳，但 `samplems` 填 16 kHz 下的**采样数**而不是毫秒 ——
        /// shazamio 新版核心传的是 `signature.samples`，与毫秒差 16 倍。
        /// 真机结论：两种都被接受（同一段音频两行同样 `200 no match`），
        /// 这个字段并不参与匹配，所以正常识曲就用毫秒。
        case sampleCount
    }

    /// 查曲库。返回 `nil` = 接口正常应答但没匹配上（对应 `SHSession.Result.noMatch`）。
    static func match(signature: SHSignature) async throws -> Match? {
        let raw = signature.dataRepresentation
        let request = try self.request(signature: raw, durationMS: Int(signature.duration * 1000))

        let (payload, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ShazamWebError.noResponse }
        guard http.statusCode == 200 else {
            throw ShazamWebError.http(status: http.statusCode,
                                      head: head(payload),
                                      fingerprint: shape(fingerprint(raw, .standard)))
        }
        guard let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else {
            throw ShazamWebError.malformed(head: head(payload))
        }
        // 没匹配上时只有 `matches: []`，没有 `track`。
        guard let track = root["track"] as? [String: Any] else { return nil }
        return parse(track)
    }

    // MARK: - 请求

    /// 组一次查询请求。
    ///
    /// 形状照 Shazam iPhone 客户端来：`POST /discovery/v5/{语言}/{地区}/iphone/-/tag/{uuid}/{uuid}`
    /// 挂一串开关，正文里带 `data:audio/vnd.shazam.sig;base64,…` 形式的指纹。
    /// 两个 uuid 是本次请求的标识，每次新生成。
    ///
    /// `internal` 而不是 `private`：请求形状错一个字段就是 400，而这里连不上真机之外的网络，
    /// 所以留给 `Tools/ShazamRequestCheck.swift` 离线核对（`signature` 收裸字节正是为此）。
    static func request(signature: Data, durationMS: Int,
                        shape: Shape = Shape(), body variant: Body = .standard) throws -> URLRequest {
        var request = URLRequest(url: endpoint(shape))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        for (key, value) in headers(shape) { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try body(signature: signature, durationMS: durationMS, variant: variant)
        return request
    }

    private static func endpoint(_ shape: Shape) -> URL {
        let path = "https://amp.shazam.com/discovery/v5/\(shape.locale)/\(shape.country)"
            + "/\(shape.device)/-/tag/\(UUID().uuidString)/\(UUID().uuidString)"
        var components = URLComponents(string: path)!
        if shape.flags {
            components.queryItems = [
                URLQueryItem(name: "sync", value: "true"),
                URLQueryItem(name: "webv3", value: "true"),
                URLQueryItem(name: "sampling", value: "true"),
                URLQueryItem(name: "connected", value: ""),
                URLQueryItem(name: "shazamapiversion", value: "v3"),
                URLQueryItem(name: "sharehub", value: "true"),
                URLQueryItem(name: "hubv5minorversion", value: "v5.1"),
                URLQueryItem(name: "hidelb", value: "true"),
                URLQueryItem(name: "video", value: "v3"),
            ]
        }
        return components.url!
    }

    private static func headers(_ shape: Shape) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Accept": "*/*",
            "Accept-Language": shape.locale,
            // 故意**不**设 Accept-Encoding：URLSession 自己会带上并透明解压，
            // 手动设反而可能拿到没解开的 gzip 原始字节（那就只能解析失败）。
            "X-Shazam-Platform": "IPHONE",
            "X-Shazam-AppVersion": "14.1.0",
            "User-Agent": "Shazam/14.1.0 CFNetwork/1494.0.7 Darwin/23.4.0",
        ]
    }

    /// `SHSignature.dataRepresentation` 里装的就是这个接口收的那份 Shazam 原生签名，
    /// 但外面套了一层 12 字节的 Apple 壳 —— **必须先剥掉**（`unwrap`），
    /// 原样送一律 `400`（两轮真机自检的结论，见 `diagnose`）。
    private static func body(signature: Data, durationMS: Int,
                            variant: Body = .standard) throws -> Data {
        let bytes = fingerprint(signature, variant)
        let json: [String: Any] = [
            "timezone": TimeZone.current.identifier,
            "signature": ["uri": "data:audio/vnd.shazam.sig;base64,\(bytes.base64EncodedString())",
                          "samplems": variant == .sampleCount ? durationMS * 16 : durationMS],
            "timestamp": Int(Date().timeIntervalSince1970 * 1000),
            "context": [String: String](),
            "geolocation": [String: String](),
        ]
        return try JSONSerialization.data(withJSONObject: json)
    }

    /// 按 `Body` 变体决定送哪一份指纹字节。
    private static func fingerprint(_ data: Data, _ variant: Body) -> Data {
        variant == .wrapped ? data : unwrap(data)
    }

    /// 剥掉 `SHSignature.dataRepresentation` 外面那层 Apple 自己的壳，取出里面那份
    /// **Shazam 原生签名**（`0xcafe2580` 开头的那种，也就是这个接口收的东西）。
    ///
    /// 壳长什么样 —— 真机自检打出来的头 24 字节（小端）：
    /// ```
    ///  0: 80 25 80 25   壳的魔数 0x25802580
    ///  4: 02 00 00 00   版本 = 2
    ///  8: 0c 00 00 00   载荷偏移 = 12 —— 从这里起才是真签名
    /// 12: 80 25 fe ca   magic1 = 0xcafe2580   ← 接口认的就是这个
    /// 16: c4 40 5f 62   crc32
    /// 20: 38 0c 00 00   size_minus_header = 3128（= 3188 − 12 壳 − 48 头，正好对上）
    /// ```
    /// 剥出来的这份连 crc32 都是 Apple 算好的，不用重算 —— 原样转发即可。
    ///
    /// 偏移是从第 8 个字节**读**出来的，不写死 12：那本来就是个偏移字段，
    /// 哪天 Apple 改了壳的长度，读字段还能跟上，写死就又是一次 400。
    /// 读出来的位置对不上 `0xcafe2580` 就当没有壳、原样返回（真机上不该发生，
    /// 但宁可送一份服务端不认的，也不要在这里崩）。
    static func unwrap(_ data: Data) -> Data {
        guard data.count > 16 else { return data }
        let base = data.startIndex
        // 小端读出偏移字段（手动拼字节：不必为了四个字节去碰 loadUnaligned 的可用性版本）。
        let offset = data[(base + 8) ..< (base + 12)].enumerated()
            .reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        guard offset >= 12, offset + 4 <= data.count,
              Array(data[(base + offset) ..< (base + offset + 4)]) == [0x80, 0x25, 0xfe, 0xca]
        else { return data }
        return Data(data.dropFirst(offset))
    }

    // MARK: - 解析

    /// 响应里有用的就那几项：`title` / `subtitle`(演唱者) / `images` / Apple Music 深链。
    /// 整份 JSON 又深又杂（`hub`、`sections`、`share`…），用字典逐层取比写一大套
    /// `Codable` 结构稳 —— 对方改了别处也不至于整条解析失败。
    ///
    /// `internal`：同样留给离线自测（用真实形状的响应片段对字段名）。
    static func parse(_ track: [String: Any]) -> Match? {
        guard let title = track["title"] as? String else { return nil }
        let images = track["images"] as? [String: Any]
        let art = (images?["coverarthq"] as? String) ?? (images?["coverart"] as? String)
        return Match(title: title,
                     artist: track["subtitle"] as? String ?? "",
                     artworkURL: art.flatMap { URL(string: $0) },
                     appleMusicURL: appleMusicLink(in: track))
    }

    /// Apple Music 深链埋在 `hub.options[].actions[]` 里，找不到就退回 Shazam 的曲目页。
    private static func appleMusicLink(in track: [String: Any]) -> URL? {
        let hub = track["hub"] as? [String: Any]
        for option in hub?["options"] as? [[String: Any]] ?? [] {
            for action in option["actions"] as? [[String: Any]] ?? [] {
                guard let uri = action["uri"] as? String,
                      uri.contains("music.apple.com"),
                      let url = URL(string: uri) else { continue }
                return url
            }
        }
        return (track["url"] as? String).flatMap { URL(string: $0) }
    }

    // MARK: - 诊断

    /// 响应开头（截断、去掉换行）—— 被拒时对方通常会在正文里说原因。
    /// 认出 gzip 就直接说是 gzip：那种情况下正文是二进制，印出来只会是一串乱码。
    private static func head(_ data: Data) -> String {
        if data.starts(with: [0x1f, 0x8b]) { return "gzip, \(data.count) bytes（未解压）" }
        let text = String(data: data.prefix(200), encoding: .utf8) ?? "\(data.count) bytes"
        return text.replacingOccurrences(of: "\n", with: " ")
    }

    /// 指纹自身的形状：魔数 + 字节数。接口拒收时第一个要排除的就是「签名格式不对」。
    private static func shape(_ data: Data) -> String {
        let magic = data.prefix(4).map { String(format: "%02x", $0) }.joined()
        return "sig \(magic)/\(data.count)B"
    }

    // MARK: - 自检

    /// 一次把「正文可能不被接受」的几种送法各试一遍，报告哪一种能过。
    ///
    /// 这东西已经立过功：这个接口被拒时只回 `400` 加**空正文**，从状态码看不出错在哪，
    /// 而开发机连不上 `amp.shazam.com`，一次装包只验一种太慢。三轮真机自检的结论 ——
    /// 1. URL 形状（locale / 地区 / 设备段 / 开关串共 7 种）全是 400，而对照组 GET 是 200
    ///    → 域名可达、请求头没被拦，问题在 POST 正文；
    /// 2. `hex` 那行露出了原因：`dataRepresentation` 外面套了一层 12 字节的 Apple 壳，
    ///    真签名（`0xcafe2580`）在偏移 12 处。剥掉壳就不再是 400（见 `unwrap`）。
    /// 3. 剥壳后整段（~20 秒）是 `200 no match`，裁到 12 秒/5 秒立刻出正确曲名
    ///    → 剩下那个变量是**指纹长度**（见 `RadioPlayer.SongRecognizer.signature(of:)`）；
    ///    `samplems` 填毫秒还是采样数则无关，两种都被接受。
    ///
    /// 留着它是为了下一次：这接口没有任何契约，改了字段照样只回 400 或 no match，
    /// 那时还是这一句能把「坏在哪一维」一次问清楚。
    static func diagnose(signature: SHSignature) async -> String {
        let raw = signature.dataRepresentation
        let ms = Int(signature.duration * 1000)
        var lines = ["\(shape(raw)) dur \(ms)ms", inspect(raw), "ctl \(await control())"]
        for variant in [Body.standard, .wrapped, .sampleCount] {
            let line = await probe(signature: raw, durationMS: ms, body: variant)
            lines.append("\(variant.rawValue.padding(toLength: 12, withPad: " ", startingAt: 0)) \(line)")
        }
        return lines.joined(separator: "\n")
    }

    /// 指纹字节的头 64 字节，加上两个已知特征串的位置：
    /// `cafe2580@12` 就是「Apple 壳里的真签名从 12 起」这件事的证据。
    static func inspect(_ raw: Data) -> String {
        let hex = raw.prefix(64).enumerated()
            .map { String(format: $0.offset % 4 == 3 ? "%02x " : "%02x", $0.element) }
            .joined()
        return "hex \(hex)\n"
            + "find cafe2580@\(find([0x80, 0x25, 0xfe, 0xca], in: raw)) "
            + "sent \(shape(unwrap(raw)))"
    }

    /// 特征串首次出现的偏移，找不到给 `-`。
    private static func find(_ pattern: [UInt8], in data: Data) -> String {
        let bytes = [UInt8](data)
        guard bytes.count >= pattern.count else { return "-" }
        for start in 0 ... (bytes.count - pattern.count)
        where Array(bytes[start ..< start + pattern.count]) == pattern {
            return "\(start)"
        }
        return "-"
    }

    /// 发一次 tag 请求，把「状态码 + 结论」压成一行。
    static func probe(signature: Data, durationMS: Int,
                      shape variant: Shape = Shape(), body: Body = .standard) async -> String {
        do {
            let request = try self.request(signature: signature, durationMS: durationMS,
                                           shape: variant, body: body)
            let (payload, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else { return "\(status) \(head(payload).prefix(60))" }
            let root = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
            guard let track = root?["track"] as? [String: Any],
                  let title = track["title"] as? String else { return "200 no match" }
            return "200 \(title)"
        } catch {
            return "err \(error.localizedDescription)"
        }
    }

    /// 对照组：普通 GET 查一首固定曲目，不带指纹。只看通不通。
    private static func control() async -> String {
        let url = URL(string: "https://amp.shazam.com/discovery/v5/en-US/GB/web/-/track/40329962")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // 除 Content-Type（GET 没有正文）之外照常带头，顺带验证这套头没被拒。
        for (key, value) in headers(Shape()) where key != "Content-Type" {
            request.setValue(value, forHTTPHeaderField: key)
        }
        do {
            let (payload, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return "\(status) \(payload.count)B"
        } catch {
            return "err \(error.localizedDescription)"
        }
    }
}

/// 查曲库这一步的失败原因。描述会直接显示在识曲失败的那条提示上（可复制）。
enum ShazamWebError: LocalizedError {
    case noResponse
    case http(status: Int, head: String, fingerprint: String)
    case malformed(head: String)

    var errorDescription: String? {
        switch self {
        case .noResponse:
            return "no HTTP response"
        case .http(let status, let head, let fingerprint):
            return "HTTP \(status) [\(fingerprint)] \(head)"
        case .malformed(let head):
            return "unparsable JSON: \(head)"
        }
    }
}
