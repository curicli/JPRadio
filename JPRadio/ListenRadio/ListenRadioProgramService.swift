import Foundation

/// ListenRadio（リッスンラジオ，全国コミュニティFM）的番組表。
///
/// 端点（App 客户端用的那个）：
/// `https://listenradio.jp/service/schedulelist.aspx?devtype=ios&offset=0&count=999&channelId=30008`
///
/// 沙箱里联不上这个站，真实字段名与返回格式都无从核实，所以这一层做三件事：
/// 1. **多个端点变体依次试**（devtype 不同、或干脆不带），第一个能解析出节目的就用它。
/// 2. **格式宽容**：去 BOM、拆 JSONP 包装、JSON 解不出来时再试 XML。
/// 3. **失败要说清原因**（HTTP 状态 / 响应片段 / 行里的键名），别只给一句「加载失败」——
///    否则永远查不出到底是网络问题、格式变了，还是字段名没对上。
enum ListenRadioProgramService {

    /// 一次拉全（count=999 覆盖到未来一周以上），再按放送日切片给界面。
    private static let cache = ScheduleCache()

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg)
    }()

    /// 直连台 id 形如 `LR30008`，去掉前缀即 ListenRadio 的 ChannelId。
    static func channelID(for station: Station) -> String {
        station.id.hasPrefix("LR") ? String(station.id.dropFirst(2)) : station.id
    }

    /// 拉取某台某个放送日（JST 05:00 起算，与 radiko 一致）的节目。
    static func fetch(station: Station, dayOffset: Int) async throws -> [RadikoProgram] {
        let channel = channelID(for: station)
        let all = try await cache.programs(channel: channel) { try await load(channel: channel) }
        let dayStart = broadcastDayStart(dayOffset: dayOffset)
        let dayEnd = dayStart.addingTimeInterval(24 * 3600)
        let slice = all.filter { p in
            guard let s = p.start else { return false }
            return s >= dayStart && s < dayEnd
        }
        // 明明解析出了节目，却没有一档落在这一天 —— 十有八九是时刻字段被解析成了别的日期。
        // 这时静默显示「暂无节目表」的话就永远查不出来，所以把实际覆盖范围报出去。
        if slice.isEmpty, !all.isEmpty {
            throw ListenRadioError.dayEmpty(total: all.count,
                                            covered: coverage(of: all),
                                            requested: jst(dayStart))
        }
        return slice
    }

    /// 解析出来的节目实际覆盖的时间范围（JST），用于诊断。
    private static func coverage(of programs: [RadikoProgram]) -> String {
        let starts = programs.compactMap(\.start).sorted()
        guard let first = starts.first, let last = starts.last else { return "-" }
        return "\(jst(first)) → \(jst(last))"
    }

    private static func jst(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// 放送日的起点（JST 当日 05:00）。
    static func broadcastDayStart(dayOffset: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let shifted = Date().addingTimeInterval(TimeInterval(dayOffset) * 24 * 3600)
        // 凌晨 0:00–4:59 仍属于前一放送日。
        let base = cal.date(byAdding: .hour, value: -5, to: shifted) ?? shifted
        let day = cal.startOfDay(for: base)
        return cal.date(byAdding: .hour, value: 5, to: day) ?? day
    }

    // MARK: - 网络

    /// 端点变体：devtype 不同的客户端有时拿到不同的表；带不带 devtype 也试一次。
    private static func endpoints(channel: String) -> [URL] {
        let variants: [[URLQueryItem]] = [
            [.init(name: "devtype", value: "ios")],
            [.init(name: "devtype", value: "android")],
            [],
        ]
        return variants.compactMap { extra in
            var comps = URLComponents(string: "https://listenradio.jp/service/schedulelist.aspx")!
            comps.queryItems = extra + [
                .init(name: "offset", value: "0"),
                .init(name: "count", value: "999"),
                .init(name: "channelId", value: channel),
            ]
            return comps.url
        }
    }

    private static func load(channel: String) async throws -> [RadikoProgram] {
        var errors: [Error] = []
        for url in endpoints(channel: channel) {
            do { return try await loadOne(url, channel: channel) }
            catch { errors.append(error) }
        }
        // 全灭了再试一次：先访问一下站点首页拿 cookie。aspx 端点在没有会话时可能给错误页，
        // 而浏览器里能直接打开是因为它早就带着 cookie 了。
        if let first = endpoints(channel: channel).first {
            await warmUp()
            do { return try await loadOne(first, channel: channel) }
            catch { errors.append(error) }
        }
        // 解析类错误比网络错误更有信息量，优先报出去。
        throw errors.max(by: { rank($0) < rank($1) }) ?? ListenRadioError.network("no endpoint")
    }

    /// 拿 cookie 用的空跑请求（结果不关心；session 是 ephemeral，cookie 只活在本次进程里）。
    private static func warmUp() async {
        guard let url = URL(string: "https://listenradio.jp/") else { return }
        var req = URLRequest(url: url)
        req.setValue(RadioPlayer.browserUserAgent, forHTTPHeaderField: "User-Agent")
        _ = try? await session.data(for: req)
    }

    private static func rank(_ error: Error) -> Int {
        switch error {
        case ListenRadioError.noPrograms:  return 4
        case ListenRadioError.noRows:      return 3
        case ListenRadioError.undecodable: return 2
        case ListenRadioError.http:        return 1
        default:                           return 0
        }
    }

    private static func request(for url: URL) -> URLRequest {
        var req = URLRequest(url: url)
        req.setValue(RadioPlayer.browserUserAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://listenradio.jp/", forHTTPHeaderField: "Referer")
        req.setValue("application/json, text/plain, text/xml, */*", forHTTPHeaderField: "Accept")
        return req
    }

    private static func loadOne(_ url: URL, channel: String) async throws -> [RadikoProgram] {
        let req = request(for: url)
        let data: Data
        let resp: URLResponse
        do { (data, resp) = try await session.data(for: req) }
        catch { throw ListenRadioError.network(error.localizedDescription) }

        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ListenRadioError.http(status: http.statusCode)
        }
        guard let root = decode(data) else { throw ListenRadioError.undecodable(sample: sample(data)) }

        let rows = ScheduleJSON.rows(in: root)
        guard !rows.isEmpty else { throw ListenRadioError.noRows(sample: sample(data)) }
        let programs = ScheduleJSON.programs(from: rows, channel: channel)
        guard !programs.isEmpty else {
            throw ListenRadioError.noPrograms(keys: ScheduleJSON.keySample(rows))
        }
        return programs
    }

    // MARK: - 解码（JSON → JSONP → XML）

    private static func decode(_ data: Data) -> Any? {
        let body = stripped(data)
        if let json = try? JSONSerialization.jsonObject(with: body) { return json }
        // JSONP（`callback({...})`）或前后带杂字符：截出第一个 { / [ 到最后一个 } / ]。
        if let text = string(from: body),
           let open = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
           let close = text.lastIndex(where: { $0 == "}" || $0 == "]" }), open < close,
           let json = try? JSONSerialization.jsonObject(with: Data(String(text[open...close]).utf8)) {
            return json
        }
        return XMLDictParser().parse(body)
    }

    /// 去掉 BOM 与前导空白（两者都会让 JSONSerialization 直接失败）。
    private static func stripped(_ data: Data) -> Data {
        var d = data
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { d = d.dropFirst(3) }
        while let f = d.first, f == 0x20 || f == 0x09 || f == 0x0A || f == 0x0D { d = d.dropFirst() }
        return d
    }

    private static func string(from data: Data) -> String? {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .shiftJIS)
    }

    /// 报错时附带的响应片段（够看出格式，又不至于糊满屏幕）。
    private static func sample(_ data: Data) -> String {
        guard let text = string(from: stripped(data)) else { return "\(data.count) bytes (not text)" }
        let flat = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return flat.count > 220 ? String(flat.prefix(220)) + "…" : flat
    }

    // MARK: - 诊断

    /// 自查报告：把每个端点变体的真实响应原样带出来（状态码 / Content-Type / 字节数 / 开头一段），
    /// 再附上解析过程的中间结果（行数 / 首行键名 / 节目数 / 第一档）。
    ///
    /// 番組表一旦对不上，这份报告是唯一能定位问题的输入 —— 是根本没连上、
    /// 返回了错误页、还是结构对了但键名没猜中，看一眼就知道。界面上可一键复制。
    static func diagnose(station: Station) async -> String {
        let channel = channelID(for: station)
        var out = ["station: \(station.name)  id: \(station.id)  channel: \(channel)",
                   "now (JST): \(jst(Date()))",
                   "day 0 window: \(jst(broadcastDayStart(dayOffset: 0))) +24h"]
        for url in endpoints(channel: channel) {
            out.append(await probe(url, channel: channel))
        }
        return out.joined(separator: "\n\n")
    }

    private static func probe(_ url: URL, channel: String) async -> String {
        var lines = ["GET \(url.absoluteString)"]
        do {
            let (data, resp) = try await session.data(for: request(for: url))
            let http = resp as? HTTPURLResponse
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "-"
            lines.append("status: \(http?.statusCode ?? -1)  type: \(type)  bytes: \(data.count)")
            if let root = decode(data) {
                let rows = ScheduleJSON.rows(in: root)
                lines.append("rows: \(rows.count)  keys: \(ScheduleJSON.keySample(rows))")
                let programs = ScheduleJSON.programs(from: rows, channel: channel)
                var summary = "programs: \(programs.count)"
                if let first = programs.first { summary += "  first: \(jst(first.start ?? Date())) \(first.title)" }
                if let last = programs.last, programs.count > 1 { summary += "  last: \(jst(last.start ?? Date()))" }
                lines.append(summary)
            } else {
                lines.append("decode: failed (neither JSON nor XML)")
            }
            lines.append("body head (\(data.count) bytes received, showing first \(headLimit)):\n\(head(data))")
        } catch {
            lines.append("error: \(error.localizedDescription)")
        }
        return lines.joined(separator: "\n")
    }

    /// 报告里只截响应开头（够看清字段名，又不至于长到没法复制）。
    /// 上面那行会同时写出 `bytes received`，免得把「报告被截断」误读成「响应本身不全」。
    private static let headLimit = 1400

    private static func head(_ data: Data, limit: Int = headLimit) -> String {
        guard let text = string(from: stripped(data)) else { return "\(data.count) bytes (not text)" }
        return text.count > limit ? String(text.prefix(limit)) + "…(truncated)" : text
    }

    /// 每台的番組表缓存（10 分钟），避免切日期时反复拉 999 条。失败不入缓存。
    private actor ScheduleCache {
        private var store: [String: (fetchedAt: Date, programs: [RadikoProgram])] = [:]
        private static let ttl: TimeInterval = 600

        func programs(channel: String,
                      loader: () async throws -> [RadikoProgram]) async throws -> [RadikoProgram] {
            if let hit = store[channel], Date().timeIntervalSince(hit.fetchedAt) < Self.ttl {
                return hit.programs
            }
            let fresh = try await loader()
            store[channel] = (Date(), fresh)
            return fresh
        }
    }
}

// MARK: - 错误（界面直接把 errorDescription 显示出来，便于定位）

enum ListenRadioError: LocalizedError {
    /// HTTP 非 2xx（端点搬了 / 参数不认）。
    case http(status: Int)
    /// 连不上、超时。
    case network(String)
    /// 拿到了响应但既不是 JSON 也不是 XML。
    case undecodable(sample: String)
    /// 结构里找不到任何「带时刻」的行数组。
    case noRows(sample: String)
    /// 找到了行，但标题/时间字段一个都没对上（附行里的键名，照着补候选键即可）。
    case noPrograms(keys: String)
    /// 解析出了节目，但没有一档落在所选放送日（附实际覆盖范围，一看就知道时刻解析歪到哪去了）。
    case dayEmpty(total: Int, covered: String, requested: String)

    var errorDescription: String? {
        switch self {
        case .http(let status):        return "HTTP \(status)"
        case .network(let detail):     return detail
        case .undecodable(let sample): return "unrecognized response: \(sample)"
        case .noRows(let sample):      return "no schedule rows: \(sample)"
        case .noPrograms(let keys):    return "rows found but no time/title fields — keys: \(keys)"
        case .dayEmpty(let total, let covered, let requested):
            return "parsed \(total) programs covering \(covered) — none in the day starting \(requested)"
        }
    }
}

// MARK: - XML 兜底

/// 把 XML 转成字典/数组（`service/*.aspx` 万一返回 XML 而不是 JSON 时用）。
/// 同名兄弟元素合并成数组，属性与子元素同放一层——`ScheduleJSON.rows` 只找
/// 「元素是字典的数组」，这样两种格式就能走同一条解析路径。
private final class XMLDictParser: NSObject, XMLParserDelegate {
    private var stack: [(name: String, dict: [String: Any], text: String)] = []
    private var root: Any?

    func parse(_ data: Data) -> Any? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        guard parser.parse() else { return nil }
        return root
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes attributeDict: [String: String] = [:]) {
        var dict: [String: Any] = [:]
        for (key, value) in attributeDict { dict[key] = value }
        stack.append((elementName, dict, ""))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        guard let node = stack.popLast() else { return }
        let text = node.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: Any = node.dict.isEmpty ? text : node.dict
        guard !stack.isEmpty else { root = value; return }
        var parent = stack[stack.count - 1]
        if let existing = parent.dict[node.name] {
            if var array = existing as? [Any] {
                array.append(value)
                parent.dict[node.name] = array
            } else {
                parent.dict[node.name] = [existing, value]
            }
        } else {
            parent.dict[node.name] = value
        }
        stack[stack.count - 1] = parent
    }
}
