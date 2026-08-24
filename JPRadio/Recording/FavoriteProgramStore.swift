import Foundation
import Combine

/// 一档被收藏的节目。
///
/// **键是「台号 + 节目名」，不是 `program.id`** —— 番組表里每次播出都是一条新记录
/// （id 含放送日与起止时刻），拿它当键的话今天收藏的《ゴールデンラジオ》明天就认不出来了。
/// 收藏的语义是「这档节目我常听」，跨天必须还是同一条。
///
/// **收藏即提醒**：收藏一档节目就等于「每次播出前通知我」（见 `ReminderStore.syncFavorites`）。
/// 原先 ★ 收藏与 🔔 提醒是两个独立开关，一行挤三个圆钮，而且「收藏了却没提醒」
/// 本来就不是谁想要的状态 —— 现在合成一个。
///
/// 与 `Reservation`（一次性的录制任务）仍然分开：收藏没有时刻、不下载，
/// 混进那个 store 会毁掉它「到点做一次然后清掉」的语义。
struct FavoriteProgram: Codable, Identifiable, Hashable {
    /// `fav-<台号>#<节目名>`，由 `FavoriteProgramStore.key(stationID:title:)` 生成。
    let id: String
    let stationID: String
    /// 收藏时的台名：直接存下来，免得将来电台表里删了这台就只剩一个台号。
    let stationName: String
    let title: String
    let performer: String
    /// 收藏时那一档的播出时段 —— 用来显示「週三 13:00 – 15:00」这样的索引信息。
    /// 可空：自定义/没有时刻的条目也允许收藏。
    let start: Date?
    let end: Date?
    /// 提醒的提前分钟数；`nil` = 跟随全局默认值（`ReminderStore.defaultLead`）。
    ///
    /// 「提前多久」是收藏自己的属性（长按 ★ 可改），因为提醒已经并入收藏。
    /// 用 `Optional` 也是为了兼容旧存档：合成的 Decodable 对可选属性用 decodeIfPresent，
    /// 缺这个键照样解得出来（换成非可选会让整张收藏表解码失败、用户的收藏全部丢掉）。
    var leadMinutes: Int? = nil
    let addedAt: Date

    /// 「週三 13:00 – 15:00」（日本时间）。同一档节目每周同一时段，
    /// 收藏时记下的那一档就够当索引用了 —— 真正的播出时刻还是看番組表。
    var slotText: String {
        guard let start else { return "" }
        var text = Self.weekdayTime.string(from: start)
        if let end { text += " – \(Self.hhmm.string(from: end))" }
        return text
    }

    private static var weekdayTime: DateFormatter { formatter("EEE HH:mm") }
    private static var hhmm: DateFormatter { formatter("HH:mm") }

    /// 每次新建：`L.language` 随时可能被用户切换，缓存住的 formatter 会一直用旧语言。
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.language.localeID)
        f.timeZone = TimeZone(identifier: "Asia/Tokyo")
        f.dateFormat = format
        return f
    }
}

/// 收藏节目的存储。只有增删查与持久化 —— 没有 `prune()`：收藏就是要一直留着
/// （播完自动消失的是提醒，见 `ReminderStore`）。
///
/// 通知的排程仍然全部在 `ReminderStore` 里，这边只存「提前多久」这个设定值：
/// 排通知要 UNUserNotificationCenter、要对账已排的那些请求，跟「记住我常听哪档节目」
/// 是两件事，写在一起以后谁也说不清一条收藏被删时通知到底撤了没有。
@MainActor
final class FavoriteProgramStore: ObservableObject {

    @Published private(set) var items: [FavoriteProgram] = []

    private static let storageKey = "favoritePrograms"

    init() { load() }

    // MARK: - 键

    /// 台号 + 节目名 → 稳定的收藏键（见 `FavoriteProgram` 的说明）。
    /// `nonisolated`：纯字符串拼接，离线自测要在主 actor 之外调它。
    nonisolated static func key(stationID: String, title: String) -> String {
        "fav-\(stationID)#\(title)"
    }

    // MARK: - 查询

    func isFavorite(stationID: String, title: String) -> Bool {
        contains(Self.key(stationID: stationID, title: title))
    }

    func isFavorite(program: RadikoProgram, station: Station) -> Bool {
        isFavorite(stationID: station.id, title: program.title)
    }

    /// 这档节目的收藏记录（提醒排程需要读它的 `leadMinutes`）。
    func favorite(stationID: String, title: String) -> FavoriteProgram? {
        let id = Self.key(stationID: stationID, title: title)
        return items.first { $0.id == id }
    }

    /// 「提前多久提醒」；`nil` = 跟随全局默认值。
    func lead(stationID: String, title: String) -> Int? {
        favorite(stationID: stationID, title: title)?.leadMinutes
    }

    private func contains(_ id: String) -> Bool { items.contains { $0.id == id } }

    /// 列表顺序：最近收藏的排在最前（刚点的那一条要一眼看得到）。
    var sorted: [FavoriteProgram] { items.sorted { $0.addedAt > $1.addedAt } }

    // MARK: - 增删

    /// 收藏/取消收藏一档节目。返回收藏后的状态（true = 现在是收藏的）。
    @discardableResult
    func toggle(program: RadikoProgram, station: Station) -> Bool {
        let id = Self.key(stationID: station.id, title: program.title)
        if contains(id) {
            remove(id: id)
            return false
        }
        items.append(FavoriteProgram(
            id: id, stationID: station.id, stationName: station.name,
            title: program.title, performer: program.performer,
            start: program.start, end: program.end, addedAt: Date()))
        persist()
        return true
    }

    func remove(_ item: FavoriteProgram) { remove(id: item.id) }

    func remove(id: String) {
        guard contains(id) else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    /// 改这档节目的提醒提前时间。已排出去的通知由 `ReminderStore.updateLead` 重排 ——
    /// 这里只负责把设定值记下来，好让以后翻到的每一次播出都按新值排。
    func setLead(_ minutes: Int?, stationID: String, title: String) {
        let id = Self.key(stationID: stationID, title: title)
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].leadMinutes != minutes else { return }
        items[i].leadMinutes = minutes
        persist()
    }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([FavoriteProgram].self, from: data) else { return }
        items = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
