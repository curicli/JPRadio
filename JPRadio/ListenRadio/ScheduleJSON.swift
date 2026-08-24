import Foundation

/// ListenRadio 番組表的宽容解析。
///
/// **真实形状**（2026-08 用机上的诊断报告确认，`schedulelist.aspx?devtype=ios`）：
/// ```
/// {"Result":0,"ServerTime":…,"ViewChannelId":30035,
///  "ProgramList":[{"ChannelId":30035,"ChannelName":…,
///    "Schedule":[{"ProgramId":18585753,"ProgramName":"シティウォーキン",
///                 "ProgramSummary":"…","StartDate":"202608240700",
///                 "EndDate":"202608240900","MainteFlg":false,"Timetable":[]}, …]}]}
/// ```
/// 注意 `StartDate` 是 **`yyyyMMddHHmm`（12 位、没有秒）**。曾经格式表里只有 14 位的
/// `yyyyMMddHHmmss`，DateFormatter 又要求整串匹配，于是每一行都「找不到时刻」→ 行数 0 →
/// 界面报 `noRows`（而浏览器里打开同一个链接却是满的，因为响应本身没问题）。
///
/// 沙箱里联不上 listenradio.jp（`service/*.aspx` 的抓取一律被掐断），别的电台/别的日期是否
/// 还有其它形状无从核实，所以这里**既不依赖键名、也不依赖外层结构**：
/// - 行数组：递归收集所有「元素是字典且带**含时刻的值**」的数组，再把形状相同的分组**合并**。
///   （番組表常按放送日拆成多个数组；只取最大的那一个，会让别的日期整天空掉。）
/// - 标题/起止时间：先按候选键名 → 再按键名关键词（start/開始 之类）→ 最后按「值像时间/像标题」兜底。
/// - 只给 `HH:mm` 的行，用同一行里的日期字段锚定；没有日期字段才退回今天的放送日。
///
/// 解析不出来时不静默返回空数组，而是让上层抛出带**样本/键名**的错误（见 `ListenRadioError`），
/// 这样界面上能直接看到「到底是哪一步没对上」。
enum ScheduleJSON {

    // MARK: - 键名候选（先猜名字）

    private static let titleKeys = [
        "ProgramTitle", "ScheduleTitle", "ProgramName", "ScheduleName",
        "Title", "Name", "ProgramText",
    ]
    private static let detailKeys = [
        "ProgramDetail", "ScheduleDetail", "ProgramSummary", "Personality", "Performer",
        "Cast", "Detail", "Description", "ProgramComment",
    ]
    private static let startKeys = [
        "StartTime", "StartDateTime", "StartDate", "ScheduleStart", "ProgramStart",
        "OnAirStart", "BeginTime", "Start", "StartAt", "OnairStartTime",
    ]
    private static let endKeys = [
        "EndTime", "EndDateTime", "EndDate", "ScheduleEnd", "ProgramEnd",
        "OnAirEnd", "FinishTime", "End", "EndAt", "OnairEndTime",
    ]
    private static let imageKeys = [
        "ProgramLogo", "ScheduleLogo", "ImageUrl", "ImageURL", "Logo", "ProgramImage",
    ]

    // MARK: - 键名关键词（名字没猜中时按关键词）

    private static let titleHints = ["title", "name", "program", "subject", "番組", "タイトル"]
    private static let detailHints = ["detail", "personality", "performer", "cast",
                                     "description", "summary", "comment", "出演", "内容"]
    private static let startHints = ["start", "begin", "from", "onair", "on_air", "開始"]
    private static let endHints = ["end", "finish", "close", "until", "終了"]
    private static let imageHints = ["image", "logo", "photo", "thumb", "banner"]
    private static let dateHints = ["date", "day", "ymd", "日付"]

    // MARK: - 找到「节目行」

    /// 递归收集所有像节目行的数组并合并。
    /// 判据只有一条：元素是字典，且行里至少有一个**带时刻**的值（纯日期不算，
    /// 否则「按日期分组」的外层数组会被当成节目行，混进一堆假条目）。
    ///
    /// 行里只有 `HH:mm`、放送日写在**外层分组**上（`{"date":…,"list":[…]}`）是常见形状，
    /// 所以往下递归时带着最近的日期，注入到没有自带日期的行里 —— 否则明天的节目
    /// 会被锚到今天，日期一切换就整天错乱。
    static func rows(in json: Any) -> [[String: Any]] {
        var groups: [[[String: Any]]] = []

        func visit(_ node: Any, inherited: String?) {
            if let array = node as? [Any] {
                let dicts = array.compactMap { $0 as? [String: Any] }
                if dicts.count == array.count, !dicts.isEmpty {
                    let rows = dicts.filter(hasClockValue).map { inheriting(inherited, $0) }
                    // 过半数的元素都带时刻才认，避免把零散字典误当节目表。
                    if rows.count * 2 >= dicts.count, !rows.isEmpty { groups.append(rows) }
                }
                for element in array { visit(element, inherited: inherited) }
            } else if let dict = node as? [String: Any] {
                let here = ownDateText(dict) ?? inherited
                for value in dict.values { visit(value, inherited: here) }
            }
        }
        visit(json, inherited: nil)

        guard let largest = groups.max(by: { $0.count < $1.count }) else { return [] }
        // 与最大分组「键名有交集」的分组视为同一张表的其它片段（多为按日分片）。
        let shape = lowerKeys(largest.first)
        var merged: [[String: Any]] = []
        var seen = Set<String>()
        for group in groups {
            let keys = lowerKeys(group.first)
            guard !shape.isDisjoint(with: keys) else { continue }
            for row in group where seen.insert(signature(row)).inserted {
                merged.append(row)
            }
        }
        return merged
    }

    /// 这一层字典自带的「放送日」（分组头上的 `date` 之类），纯日期才算。
    private static func ownDateText(_ dict: [String: Any]) -> String? {
        for key in dict.keys.sorted() {
            let lower = key.lowercased()
            guard dateHints.contains(where: { lower.contains($0) }),
                  let s = dict[key] as? String, parseDateOnly(s) != nil else { continue }
            return s
        }
        return nil
    }

    /// 把外层的放送日补进行里（行自带日期时不动它）。键名带 `date` 才能被 `dateAnchor` 认出。
    private static func inheriting(_ date: String?, _ row: [String: Any]) -> [String: Any] {
        guard let date, dateAnchor(in: row) == nil else { return row }
        var copy = row
        copy["__date"] = date
        return copy
    }

    /// 数值要大到这个量级才可能是时间戳（秒 ≥ 2001-09 / 毫秒）。
    /// 门槛不能再低：ListenRadio 的 `ProgramId` 已经是 1.8×10⁷ 这个量级，
    /// 把它当成 epoch 会解析出 1970 年代的假节目。
    private static let epochFloor: Double = 1_000_000_000

    /// 行里是否有「带时刻」的值（`HH:mm` / 完整日期时间 / epoch）。
    private static func hasClockValue(_ row: [String: Any]) -> Bool {
        for value in row.values {
            if let s = value as? String, parseClock(s) != nil { return true }
            if let n = value as? NSNumber, n.doubleValue >= epochFloor { return true }
        }
        return false
    }

    /// 行去重用的指纹（同一档节目可能同时出现在两个分组里）。
    private static func signature(_ row: [String: Any]) -> String {
        row.keys.sorted().map { "\($0)=\(String(describing: row[$0]!))" }
            .joined(separator: "\u{1}")
    }

    /// 出错时给界面看的键名清单——一眼就能看出候选键名该往哪补。
    static func keySample(_ rows: [[String: Any]]) -> String {
        (rows.first?.keys.sorted() ?? []).joined(separator: ", ")
    }

    private static func lowerKeys(_ row: [String: Any]?) -> Set<String> {
        guard let row else { return [] }
        return Set(row.keys.map { $0.lowercased() })
    }

    // MARK: - 行 → RadikoProgram

    static func programs(from rows: [[String: Any]], channel: String) -> [RadikoProgram] {
        var result: [RadikoProgram] = []
        var seenIDs = Set<String>()

        for row in rows {
            // 同一行里的日期字段（"2026/08/24"）用来给只有 "21:30" 的时刻锚定放送日。
            let anchor = dateAnchor(in: row)
            let clocks = clockValues(in: row, anchor: anchor)
            guard var start = pick(row, keys: startKeys, hints: startHints, anchor: anchor)
                    ?? clocks.first?.date else { continue }
            var end = pick(row, keys: endKeys, hints: endHints, anchor: anchor)
            // 键名全没猜中时：起点取最早、终点取最晚（同一行里通常就这两个时刻）。
            if end == nil, clocks.count >= 2 {
                start = clocks.first!.date
                end = clocks.last!.date
            }
            // 跨零点（23:30 → 00:30）：终点会算成比起点早，补一天。
            if let e = end, e <= start { end = e.addingTimeInterval(24 * 3600) }
            // 明显不合理的时长（键名猜错、把别的时间当终点）宁可丢掉，让下一档来补。
            if let e = end, e.timeIntervalSince(start) > 12 * 3600 { end = nil }

            let title = text(row, keys: titleKeys, hints: titleHints)
                ?? fallbackTitle(row) ?? T.noProgramTitle
            let detail = text(row, keys: detailKeys, hints: detailHints) ?? ""
            let image = text(row, keys: imageKeys, hints: imageHints)
                .flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil }

            let id = "LRP-\(channel)-\(Int(start.timeIntervalSince1970))"
            guard seenIDs.insert(id).inserted else { continue }
            result.append(RadikoProgram(id: id, title: title, performer: detail,
                                        start: start, end: end, imageURL: image))
        }

        result.sort { ($0.start ?? .distantPast) < ($1.start ?? .distantPast) }

        // 缺结束时间的，用下一档的开始时间补；最后一档默认 1 小时。
        for i in result.indices where result[i].end == nil {
            let fallback = (i + 1 < result.count ? result[i + 1].start : nil)
                ?? result[i].start?.addingTimeInterval(3600)
            result[i] = RadikoProgram(
                id: result[i].id, title: result[i].title, performer: result[i].performer,
                start: result[i].start, end: fallback, imageURL: result[i].imageURL)
        }
        return result
    }

    // MARK: - 取值（键名 → 键名关键词 → 值的样子）

    /// 按候选键名、再按键名关键词找一个时间值。
    ///
    /// 分两轮：**先只认带时刻的值**，一轮都没有才允许纯日期。
    /// 否则 `OnAirDate:"2026-08-24"` + `OnAirStartTime:"07:00"` 这种行里，
    /// 键名含 `onair` 的日期字段会先被当成开始时间，整档节目被钉在 00:00
    /// （于是全部落到放送日之外，界面上就是「今天没有节目」）。
    private static func pick(_ row: [String: Any], keys: [String],
                             hints: [String], anchor: Date?) -> Date? {
        if let d = scan(row, keys: keys, hints: hints, anchor: anchor, resolve: clock) { return d }
        return scan(row, keys: keys, hints: hints, anchor: anchor, resolve: date)
    }

    /// `hints`/`avoid` 用「关键词出现的位置」裁决：`OnAirEndTime` 里 `end` 比 `onair` 靠后，
    /// 所以它算终点而不是起点——否则起点会被终点值污染。
    private static func scan(_ row: [String: Any], keys: [String], hints: [String],
                             anchor: Date?,
                             resolve: (Any?, Date?) -> Date?) -> Date? {
        for key in keys {
            if let d = resolve(row[key], anchor) { return d }
        }
        let avoid = (hints == startHints) ? endHints : startHints
        for key in row.keys.sorted() {
            let lower = key.lowercased()
            guard let own = lastHintIndex(lower, hints) else { continue }
            if let other = lastHintIndex(lower, avoid), other > own { continue }
            if let d = resolve(row[key], anchor) { return d }
        }
        return nil
    }

    private static func lastHintIndex(_ lower: String, _ hints: [String]) -> Int? {
        var best: Int?
        for hint in hints {
            guard let r = lower.range(of: hint) else { continue }
            let idx = lower.distance(from: lower.startIndex, to: r.lowerBound)
            if best == nil || idx > best! { best = idx }
        }
        return best
    }

    /// 行里所有「带时刻」的值，按时间排序（键名全猜不中时的兜底来源）。
    private static func clockValues(in row: [String: Any],
                                    anchor: Date?) -> [(key: String, date: Date)] {
        var found: [(key: String, date: Date)] = []
        for key in row.keys.sorted() {
            if let d = clock(row[key], anchor: anchor) { found.append((key, d)) }
        }
        return found.sorted { $0.date < $1.date }
    }

    /// 同一行里的「放送日」字段（给只有 `HH:mm` 的时刻锚定日期）。
    private static func dateAnchor(in row: [String: Any]) -> Date? {
        for key in row.keys.sorted() {
            let lower = key.lowercased()
            guard dateHints.contains(where: { lower.contains($0) }),
                  let s = row[key] as? String else { continue }
            if let d = parseDateOnly(s) { return d }
            if let d = parseClock(s) { return d }
        }
        return nil
    }

    private static func text(_ row: [String: Any], keys: [String], hints: [String]) -> String? {
        for key in keys {
            if let s = clean(row[key]) { return s }
        }
        for key in row.keys.sorted() {
            let lower = key.lowercased()
            guard hints.contains(where: { lower.contains($0) }), let s = clean(row[key]) else { continue }
            return s
        }
        return nil
    }

    /// 取字符串值；空串与占位横线（ListenRadio 的 `ProgramSummary` 常填 `"-"`）都当没有。
    private static func clean(_ value: Any?) -> String? {
        guard let s = value as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return (t.isEmpty || t == "-" || t == "－" || t == "ー") ? nil : t
    }

    /// 连标题的键名都没猜中时：取行里最长的一段「像人话」的字符串。
    private static func fallbackTitle(_ row: [String: Any]) -> String? {
        var best: String?
        for value in row.values {
            guard let s = clean(value), s.count <= 120,
                  !s.hasPrefix("http"), Double(s) == nil,
                  parseClock(s) == nil, parseDateOnly(s) == nil else { continue }
            if best == nil || s.count > best!.count { best = s }
        }
        return best
    }

    // MARK: - 时间解析

    private static let jst = TimeZone(identifier: "Asia/Tokyo")!

    private static func formatter(_ pattern: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = jst
        f.dateFormat = pattern
        return f
    }

    /// 带时刻的完整时间戳。
    ///
    /// `DateFormatter` 要求**整串匹配**（`yyyyMMddHHmmss` 喂 12 位数字得到 nil），
    /// 所以位数不同的紧凑格式必须各列一条：ListenRadio 用 12 位，radiko 用 14 位。
    /// 长的排在短的前面，免得 14 位被 12 位那条截着解析。
    private static let dateTimeFormatters: [DateFormatter] = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy/MM/dd HH:mm:ss",
        "yyyy/MM/dd HH:mm",
        "yyyyMMddHHmmss",   // radiko: 20260824130000
        "yyyyMMddHHmm",     // ListenRadio: 202608241300
        "yyyy年MM月dd日 HH:mm",
    ].map(formatter)

    /// 纯时刻。
    private static let timeOnlyFormatters: [DateFormatter] =
        ["HH:mm:ss", "HH:mm", "H:mm"].map(formatter)

    /// 纯日期（无时刻）。最后一个没有年份，按当年补。
    private static let dateOnlyFormatters: [DateFormatter] =
        ["yyyy-MM-dd", "yyyy/MM/dd", "yyyyMMdd", "yyyy年MM月dd日", "MM/dd"].map(formatter)

    private static func epoch(_ value: Double) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }

    private static func date(_ value: Any?, anchor: Date?) -> Date? {
        if let s = value as? String { return parseClock(s, anchor: anchor) ?? parseDateOnly(s) }
        if let n = value as? NSNumber { return epoch(n.doubleValue) }
        return nil
    }

    private static func clock(_ value: Any?, anchor: Date?) -> Date? {
        if let s = value as? String { return parseClock(s, anchor: anchor) }
        if let n = value as? NSNumber, n.doubleValue >= epochFloor { return epoch(n.doubleValue) }
        return nil
    }

    /// 带时刻的值 → Date。纯 `HH:mm` 用 `anchor` 的年月日锚定（没有 anchor 就用今天的放送日）。
    static func parseClock(_ raw: String, anchor: Date? = nil) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // .NET 的 "/Date(1756000000000+0900)/"。
        if s.hasPrefix("/Date("),
           let digits = s.split(separator: "(").last?.prefix(while: { $0.isNumber }),
           let ms = Double(digits) {
            return epoch(ms)
        }
        // 先走格式表：yyyyMMddHHmmss 全是数字，若先当 epoch 会跑到 26 世纪去。
        for f in dateTimeFormatters where f.date(from: s) != nil {
            return f.date(from: s)
        }
        if (s.count == 10 || s.count == 13), let n = Double(s) { return epoch(n) }

        for f in timeOnlyFormatters {
            guard let t = f.date(from: s) else { continue }
            return anchored(time: t, to: anchor)
        }
        return nil
    }

    /// 纯日期 → 当天 00:00（JST）。
    static func parseDateOnly(_ raw: String) -> Date? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 12 || s.contains("年") else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        for f in dateOnlyFormatters {
            guard let d = f.date(from: s) else { continue }
            // "08/24" 这种没年份的会落到 2000 年，补成当年。
            let year = cal.component(.year, from: d)
            guard year < 1980 else { return d }
            var comps = cal.dateComponents([.month, .day], from: d)
            comps.year = cal.component(.year, from: Date())
            return cal.date(from: comps) ?? d
        }
        return nil
    }

    /// 把「只有时刻」的值放到某一天上。放送日惯例：05:00 之前算次日。
    private static func anchored(time: Date, to anchor: Date?) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = jst
        let hm = cal.dateComponents([.hour, .minute, .second], from: time)
        let day = anchor ?? ListenRadioProgramService.broadcastDayStart(dayOffset: 0)
        var comps = cal.dateComponents([.year, .month, .day], from: day)
        comps.hour = hm.hour; comps.minute = hm.minute; comps.second = hm.second ?? 0
        guard let fixed = cal.date(from: comps) else { return nil }
        return (hm.hour ?? 0) < 5 ? fixed.addingTimeInterval(24 * 3600) : fixed
    }
}

// MARK: - 番組表统一入口（radiko / ListenRadio 两路）

/// 界面只跟这个门面打交道：按电台类型路由到对应的番組表服务。
enum ProgramCatalog {

    /// 可查看的放送日范围。radiko 有一周 timefree 存档故可回溯；直连台只有未来表。
    static func dayRange(for station: Station) -> ClosedRange<Int> {
        station.isDirect ? 0...7 : RadikoProgramService.dayRange
    }

    static func fetch(station: Station, dayOffset: Int) async throws -> [RadikoProgram] {
        if station.isDirect {
            return try await ListenRadioProgramService.fetch(station: station, dayOffset: dayOffset)
        }
        return try await RadikoProgramService.fetch(stationID: station.id, dayOffset: dayOffset)
    }
}
