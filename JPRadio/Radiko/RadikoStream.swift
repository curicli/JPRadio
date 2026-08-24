import Foundation

/// 解析 radiko 的直播流地址。
///
/// 步骤：拉取 `https://radiko.jp/v3/station/stream/pc_html5/{id}.xml`，
/// 从中挑选 `areafree=0, timefree=0`（区域内 · 直播）的 `playlist_create_url`，
/// 追加 `station_id / l / lsid / type` 参数，得到最终 m3u8。拉流时请求头需带
/// `X-Radiko-AuthToken`（由 `RadioPlayer` 通过 AVURLAsset 注入）。
enum RadikoStream {

    /// 兜底直播地址（当 stream XML 拉取/解析失败时使用）。
    private static let fallbackPlaylistURLs = [
        "https://si-f-radiko.smartstream.ne.jp/so/playlist.m3u8",
        "https://dr-wowza.radiko-cf.com/so/playlist.m3u8",
    ]

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    static func playlistURL(for station: Station, token: RadikoToken) async throws -> URL {
        let base = (try? await fetchPlaylistBase(stationID: station.id)) ?? fallbackPlaylistURLs[0]
        return buildURL(base: base, stationID: station.id, lsid: token.userID)
    }

    // MARK: - 拉取并解析 stream 配置 XML

    private static func fetchPlaylistBase(stationID: String) async throws -> String {
        let url = URL(string: "https://radiko.jp/v3/station/stream/pc_html5/\(stationID).xml")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw RadikoError.badResponse
        }
        let parser = StreamXMLParser()
        let entries = parser.parse(data)

        // 优先：区域内直播（areafree=0, timefree=0）；退而求其次任意直播（timefree=0）。
        let live = entries.filter { $0.timefree == false }
        let inArea = live.first { $0.areafree == false }
        guard let chosen = inArea ?? live.first ?? entries.first else {
            throw RadikoError.badResponse
        }
        return chosen.url
    }

    private static func buildURL(base: String, stationID: String, lsid: String) -> URL {
        var comps = URLComponents(string: base)!
        comps.queryItems = [
            URLQueryItem(name: "station_id", value: stationID),
            URLQueryItem(name: "l", value: "15"),
            URLQueryItem(name: "lsid", value: lsid),
            URLQueryItem(name: "type", value: "b"),
        ]
        return comps.url!
    }

    // MARK: - タイムフリー（近一周存档，用于预约/补录）

    /// timefree 播放列表兜底地址（stream XML 拉取/解析失败时使用）。
    /// 注意：旧的 `radiko.jp/v2/api/ts/playlist.m3u8` 现已 404，改用 tf30 端点。
    private static let fallbackTimefreeURL = "https://tf-f-rpaa-radiko.smartstream.ne.jp/tf/playlist.m3u8"

    /// 取指定台的 timefree（`timefree=1`）playlist_create_url 基地址。
    ///
    /// **必须挑 `areafree=0` 的那条**：`areafree=1` 的入口是给「エリアフリー（付费会员）」
    /// 用的，我们拿的是 GPS 伪造出来的区域内 token，用它去请求会直接 403 —— 而下载链路里
    /// 一个 403 就意味着整段录音一个字节都拿不到。
    static func fetchTimefreeBase(stationID: String) async throws -> String {
        let url = URL(string: "https://radiko.jp/v3/station/stream/pc_html5/\(stationID).xml")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw RadikoError.badResponse
        }
        let entries = StreamXMLParser().parse(data)
        let timefree = entries.filter { $0.timefree == true }
        return (timefree.first { $0.areafree == false } ?? timefree.first)?.url ?? fallbackTimefreeURL
    }

    /// 构造一段 timefree 播放列表 URL。
    /// 复刻 rajiko `modules/timeshift.js`：`l=300`(单次最大窗口/最大 seek)，
    /// 通过外部按 +300s 递增 `seek` 覆盖整档节目；时间均为 JST `yyyyMMddHHmmss`。
    static func timefreePlaylistURL(base: String, stationID: String, lsid: String,
                                    startAt: String, endAt: String, seek: String) -> URL {
        var comps = URLComponents(string: base)!
        var items = comps.queryItems ?? []
        items.append(contentsOf: [
            URLQueryItem(name: "station_id", value: stationID),
            URLQueryItem(name: "l", value: "300"),
            URLQueryItem(name: "lsid", value: lsid),
            URLQueryItem(name: "start_at", value: startAt),
            URLQueryItem(name: "end_at", value: endAt),
            URLQueryItem(name: "ft", value: startAt),
            URLQueryItem(name: "to", value: endAt),
            URLQueryItem(name: "seek", value: seek),
            URLQueryItem(name: "type", value: "b"),
        ])
        comps.queryItems = items
        return comps.url!
    }

    /// timefree 单窗口步长（秒）。与 `l=300` 对应。
    static let timefreeSeekStep = 300
}

// MARK: - XML 解析

private struct StreamEntry {
    var areafree: Bool
    var timefree: Bool
    var url: String
}

/// 解析 `<urls><url areafree=".." timefree=".."><playlist_create_url>..</playlist_create_url></url>...`
private final class StreamXMLParser: NSObject, XMLParserDelegate {
    private var entries: [StreamEntry] = []
    private var currentAreafree = false
    private var currentTimefree = false
    private var currentText = ""
    private var capturing = false

    func parse(_ data: Data) -> [StreamEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        if elementName == "url" {
            currentAreafree = (attributeDict["areafree"] == "1")
            currentTimefree = (attributeDict["timefree"] == "1")
        } else if elementName == "playlist_create_url" {
            capturing = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { currentText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "playlist_create_url" {
            let url = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !url.isEmpty {
                entries.append(StreamEntry(areafree: currentAreafree, timefree: currentTimefree, url: url))
            }
            capturing = false
        }
    }
}

// MARK: - 节目表（radiko 番組表 API，无需鉴权）

/// 一档节目。
struct RadikoProgram: Identifiable, Hashable {
    let id: String
    let title: String
    let performer: String
    let start: Date?
    let end: Date?
    let imageURL: URL?

    /// 是否正在直播（用绝对时间比较，跨时区安全）。
    var isOnAir: Bool {
        guard let start, let end else { return false }
        let now = Date()
        return start <= now && now < end
    }

    /// 时间段显示，例如 "13:00 – 15:00"（日本时间）。
    var timeText: String {
        guard let start else { return "" }
        let s = Self.hhmm.string(from: start)
        let e = end.map { Self.hhmm.string(from: $0) } ?? ""
        return e.isEmpty ? s : "\(s) – \(e)"
    }

    private static let hhmm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "HH:mm"
        return f
    }()
}

/// 拉取并解析 radiko 节目表。番組表 API 公开、无需鉴权。
/// 放送日以日本时间 05:00 为一日之始；可通过 dayOffset 查看其它日期。
enum RadikoProgramService {
    /// 可回溯 / 前瞻的放送日范围（radiko timefree 约保留一周）。
    static let dayRange = -7...7

    private static let jst = TimeZone(identifier: "Asia/Tokyo")!

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()

    /// 拉取指定台某个放送日的节目列表。dayOffset=0 为今天，-1 昨天，+1 明天。
    static func fetch(stationID: String, dayOffset: Int = 0) async throws -> [RadikoProgram] {
        let date = dateString(broadcastDate(dayOffset: dayOffset))
        let url = URL(string: "https://radiko.jp/v3/program/station/date/\(date)/\(stationID).xml")!
        let (data, resp) = try await session.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            throw RadikoError.badResponse
        }
        return RadikoProgramXMLParser().parse(data)
    }

    /// 日期主标签：-1/0/+1 用「昨天 / 今天 / 明天」，其余用星期几（随当前语言）。
    static func dayPrimaryLabel(dayOffset: Int) -> String {
        switch dayOffset {
        case 0:  return T.today
        case -1: return T.yesterday
        case 1:  return T.tomorrow
        default:
            let f = DateFormatter()
            f.locale = Locale(identifier: L.language.localeID)
            f.timeZone = jst
            f.dateFormat = "EEEE"
            return f.string(from: broadcastDate(dayOffset: dayOffset))
        }
    }

    /// 日期副标签：本地化的「月/日」，例如 Aug 23 / 8月23日。
    static func daySecondaryLabel(dayOffset: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.language.localeID)
        f.timeZone = jst
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: broadcastDate(dayOffset: dayOffset))
    }

    // MARK: - 放送日计算（JST）

    /// 今天的放送日（< 05:00 归前一日）偏移 dayOffset 天；取当天正午避免边界问题。
    private static func broadcastDate(dayOffset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        let now = Date()
        let hour = cal.component(.hour, from: now)
        let today = hour < 5 ? (cal.date(byAdding: .day, value: -1, to: now) ?? now) : now
        let shifted = cal.date(byAdding: .day, value: dayOffset, to: today) ?? today
        return cal.date(bySettingHour: 12, minute: 0, second: 0, of: shifted) ?? shifted
    }

    private static func dateString(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = jst
        f.dateFormat = "yyyyMMdd"
        return f.string(from: date)
    }
}

/// 解析 `<prog ft=".." to=".." id=".."><title/><pfm/><img/></prog>`。
private final class RadikoProgramXMLParser: NSObject, XMLParserDelegate {
    private var programs: [RadikoProgram] = []
    private var ft = "", to = "", progID = ""
    private var title = "", pfm = "", img = ""
    private var current = ""
    private var capturing = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyyMMddHHmmss"
        return f
    }()

    func parse(_ data: Data) -> [RadikoProgram] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return programs
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String]) {
        switch elementName {
        case "prog":
            ft = attributeDict["ft"] ?? ""
            to = attributeDict["to"] ?? ""
            progID = attributeDict["id"] ?? ft
            title = ""; pfm = ""; img = ""
        case "title", "pfm", "img":
            capturing = true
            current = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing { current += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if capturing, let s = String(data: CDATABlock, encoding: .utf8) { current += s }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "title": title = trimmed(current); capturing = false
        case "pfm":   pfm = trimmed(current);   capturing = false
        case "img":   img = trimmed(current);   capturing = false
        case "prog":
            programs.append(RadikoProgram(
                id: progID.isEmpty ? ft : progID,
                title: title.isEmpty ? "—" : title,
                performer: pfm,
                start: Self.stamp.date(from: ft),
                end: Self.stamp.date(from: to),
                imageURL: URL(string: img)
            ))
        default:
            break
        }
    }

    private func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
