import Foundation

/// 鉴权成功后拿到的 token 及其对应区域。
struct RadikoToken {
    let value: String       // X-Radiko-AuthToken
    let area: String        // 例如 "JP13"
    let acquiredAt: Date
    let userID: String      // 本次会话使用的随机 user id（拉流 lsid 复用）

    /// radiko token 有效期较长，这里保守地在 5 分钟后视为需要刷新。
    var isFresh: Bool { Date().timeIntervalSince(acquiredAt) < 300 }
}

enum RadikoError: LocalizedError {
    case badResponse
    case auth1Failed(Int)
    case auth2Failed(Int)
    case missingAuthHeaders
    case areaRestricted(String)

    var errorDescription: String? {
        switch self {
        case .badResponse:          return T.errServer
        case .auth1Failed(let c):   return T.errAuth1(c)
        case .auth2Failed(let c):   return T.errAuth2(c)
        case .missingAuthHeaders:   return T.errMissingHeaders
        case .areaRestricted(let a):return T.errArea(a)
        }
    }
}

/// radiko 鉴权器：auth1 → 计算 partial key → auth2，缓存 token 并按需刷新。
/// 复刻 rajiko 的 GPS 定位伪造，实现境外绕过。
actor RadikoAuthenticator {
    static let shared = RadikoAuthenticator()

    private let auth1URL = URL(string: "https://api.radiko.jp/v2/api/auth1")!
    private let auth2URL = URL(string: "https://api.radiko.jp/v2/api/auth2")!

    /// 当前生效的 profile：优先 android 绕过（若已配置 key），否则 pc_html5。
    private var profile: RadikoAuthProfile {
        RadikoAuthProfile.android ?? .pcHTML5
    }

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    /// 按地区分别缓存 token —— 跨地区（东京/大阪/…）切台时不能复用同一个 token，
    /// 否则会拿着「东京区域」的凭证去拉「大阪」的流而被判定越区。
    private var cachedByArea: [String: RadikoToken] = [:]

    /// 返回目标地区一个可用 token（命中该地区缓存则直接返回）。
    func token(preferredArea: String = "JP13") async throws -> RadikoToken {
        if let cached = cachedByArea[preferredArea], cached.isFresh { return cached }
        return try await authenticate(area: preferredArea)
    }

    /// 强制重新鉴权某地区（例如拉流返回 401 时）。
    @discardableResult
    func refresh(area: String = "JP13") async throws -> RadikoToken {
        cachedByArea[area] = nil
        return try await authenticate(area: area)
    }

    private func authenticate(area: String) async throws -> RadikoToken {
        let profile = self.profile
        let userID = Self.randomUserID()

        // --- auth1 ---
        var req1 = URLRequest(url: auth1URL)
        req1.httpMethod = "GET"
        applyCommonHeaders(&req1, profile: profile, userID: userID)
        let (_, resp1) = try await session.data(for: req1)
        guard let http1 = resp1 as? HTTPURLResponse else { throw RadikoError.badResponse }
        guard http1.statusCode == 200 else { throw RadikoError.auth1Failed(http1.statusCode) }

        guard let authToken = http1.value(forHTTPHeaderField: "X-Radiko-AuthToken"),
              let offsetStr = http1.value(forHTTPHeaderField: "X-Radiko-KeyOffset"),
              let lengthStr = http1.value(forHTTPHeaderField: "X-Radiko-KeyLength"),
              let offset = Int(offsetStr), let length = Int(lengthStr) else {
            throw RadikoError.missingAuthHeaders
        }

        let partialKey = Self.partialKey(from: profile.fullKeyBytes, offset: offset, length: length)

        // --- auth2 ---
        var req2 = URLRequest(url: auth2URL)
        req2.httpMethod = "GET"
        applyCommonHeaders(&req2, profile: profile, userID: userID)
        req2.setValue(authToken, forHTTPHeaderField: "X-Radiko-AuthToken")
        req2.setValue(partialKey, forHTTPHeaderField: "X-Radiko-Partialkey")
        if profile.sendsLocation {
            req2.setValue(RadikoGPS.location(for: area), forHTTPHeaderField: "X-Radiko-Location")
            req2.setValue("wifi", forHTTPHeaderField: "X-Radiko-Connection")
        }

        let (data2, resp2) = try await session.data(for: req2)
        guard let http2 = resp2 as? HTTPURLResponse else { throw RadikoError.badResponse }
        guard http2.statusCode == 200 else { throw RadikoError.auth2Failed(http2.statusCode) }

        // 响应体形如 "JP13,東京都,tokyo Japan"
        let body = String(decoding: data2, as: UTF8.self)
        let resolvedArea = body.split(separator: ",").first.map(String.init) ?? area
        if resolvedArea.uppercased() == "OUT" {
            throw RadikoError.areaRestricted(resolvedArea)
        }

        let token = RadikoToken(value: authToken, area: resolvedArea, acquiredAt: Date(), userID: userID)
        cachedByArea[area] = token
        return token
    }

    private func applyCommonHeaders(_ req: inout URLRequest, profile: RadikoAuthProfile, userID: String) {
        req.setValue(profile.appName,    forHTTPHeaderField: "X-Radiko-App")
        req.setValue(profile.appVersion, forHTTPHeaderField: "X-Radiko-App-Version")
        req.setValue(profile.device,     forHTTPHeaderField: "X-Radiko-Device")
        req.setValue(userID,             forHTTPHeaderField: "X-Radiko-User")
        req.setValue(profile.userAgent,  forHTTPHeaderField: "User-Agent")
    }

    /// partialkey = base64( fullKey[offset ..< offset+length] )
    static func partialKey(from fullKey: [UInt8], offset: Int, length: Int) -> String {
        guard offset >= 0, length > 0, offset + length <= fullKey.count else {
            return Data(fullKey).base64EncodedString()
        }
        return Data(fullKey[offset ..< offset + length]).base64EncodedString()
    }

    /// 32 位随机十六进制 user id（复刻 rajiko genRandomInfo）。
    static func randomUserID() -> String {
        (0..<32).map { _ in String(Int.random(in: 0...15), radix: 16) }.joined()
    }
}
