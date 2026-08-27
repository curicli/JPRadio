import Foundation
import Combine
import UserNotifications

/// 一条「收听提醒」：到点（或提前几分钟）发一条本地通知，点通知直接跳到该台并开播。
///
/// **提醒不再是用户单独开的开关，而是收藏的产物**：收藏一档节目（★）就等于
/// 「每次播出前通知我」，每条提醒都对应「某档收藏节目的某一次播出」，
/// 由 `ReminderStore.syncFavorites` 在番組表加载时排出来。
///
/// 与 `Reservation`（预约**录制**）仍然刻意分开：提醒不下载、不抓流、不重试，
/// 只是一条定时通知 —— 混进 `ReservationStore` 的对账链路只会让「录没录到」的状态更难看懂。
/// 两者可以对同一档节目同时存在（提醒我听 + 顺手录一份）。
struct ProgramReminder: Codable, Identifiable, Hashable {
    /// 用 `program.id`，节目表据此判「已设提醒」。自定义的用 `remind-<uuid>`。
    let id: String
    let stationID: String
    let stationName: String
    let programTitle: String
    let start: Date
    let end: Date
    /// 提前多少分钟提醒（0 = 开始时）。
    var leadMinutes: Int

    /// 通知的实际触发时刻。
    var fireAt: Date { start.addingTimeInterval(-Double(leadMinutes) * 60) }

    var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.language.localeID)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: start)
    }
}

/// 收听提醒的存储与本地通知排程。
///
/// 本地通知**不需要** App 存活（与实时录制不同，那个 App 一被挂起就断），
/// 所以「提醒我听」这条链路在 iOS 上是可靠的：系统会在设定时刻弹出，
/// 点一下由 `NotificationRouter` 把台号带回界面，直接选台开播。
///
/// 入口只有一个：`syncFavorites` —— 提醒跟着 ★ 收藏走，界面上没有单独的「设提醒」开关了。
@MainActor
final class ReminderStore: ObservableObject {

    @Published private(set) var items: [ProgramReminder] = []
    /// 上一次选的提前时间，作为下次的默认值（每次都要重选很烦）。
    @Published var defaultLead: Int {
        didSet { UserDefaults.standard.set(defaultLead, forKey: Self.leadKey) }
    }

    /// 可选的提前分钟数（0 = 开始时提醒）。
    static let leadChoices = [0, 5, 10, 15, 30]

    private static let key = "programReminders"
    private static let leadKey = "reminderLeadMinutes"
    private var didRequestAuth = false

    init() {
        let saved = UserDefaults.standard.object(forKey: Self.leadKey) as? Int
        defaultLead = saved ?? 5
        load()
        prune()
    }

    // MARK: - 查询

    func isReminded(programID: String) -> Bool { items.contains { $0.id == programID } }

    func reminder(programID: String) -> ProgramReminder? { items.first { $0.id == programID } }

    /// 还没开播的提醒（界面上列的就是这些）。
    var upcoming: [ProgramReminder] {
        let now = Date()
        return items.filter { $0.end > now }
    }

    // MARK: - 增删

    /// 给一档节目设提醒。已过开播时间就不设（通知排不进过去）。
    ///
    /// `remembersLead`：把这次的提前值记成下次的默认。跟着收藏自动排的那些**不记**（传 false）——
    /// 那不是用户此刻做的选择，某档节目设了「提前 30 分钟」不该把全局默认也改成 30。
    @discardableResult
    func add(program: RadikoProgram, station: Station, lead: Int? = nil,
             remembersLead: Bool = true) -> Bool {
        guard let start = program.start, start > Date() else { return false }
        let minutes = lead ?? defaultLead
        if remembersLead { defaultLead = minutes }
        let r = ProgramReminder(
            id: program.id, stationID: station.id, stationName: station.name,
            programTitle: program.title, start: start,
            end: program.end ?? start.addingTimeInterval(3600), leadMinutes: minutes)
        // 同一档改提前时间：换掉旧的那条（连通知一起）。
        if let existing = items.first(where: { $0.id == r.id }) { cancelNotification(for: existing) }
        items.removeAll { $0.id == r.id }
        items.append(r)
        items.sort { $0.start < $1.start }
        persist()
        requestAuthIfNeeded()
        scheduleNotification(for: r)
        return true
    }

    func remove(_ reminder: ProgramReminder) {
        cancelNotification(for: reminder)
        items.removeAll { $0.id == reminder.id }
        persist()
    }

    func remove(programID: String) {
        guard let r = reminder(programID: programID) else { return }
        remove(r)
    }

    /// 清掉已经播完的提醒（通知早就发过了，留着只是让列表越来越长）。
    func prune() {
        let cutoff = Date()
        let stale = items.filter { $0.end <= cutoff }
        guard !stale.isEmpty else { return }
        for r in stale { cancelNotification(for: r) }
        items.removeAll { $0.end <= cutoff }
        persist()
    }

    // MARK: - 跟着收藏走（收藏 = 每次播出前自动提醒）

    /// 这档收藏节目实际用的提前值：收藏里设过就用它，没设就用全局默认。
    func lead(for f: FavoriteProgram) -> Int { f.leadMinutes ?? defaultLead }

    /// 把一张刚加载好的节目表与收藏对齐：其中「已收藏且还没开播」的每一档都排上提醒。
    ///
    /// 为什么要在番組表加载时做，而不是收藏的时候一次排完：本地通知必须给出**具体时刻**，
    /// 而一档节目下一次什么时候播只有番組表知道（改档、停播、特番都会变），
    /// 所以只能「用户翻到哪一天，就把那一天的收藏节目排上」。radiko 的表能往后看一周，
    /// 平时开一次番組表就足够把最近几次播出都排上。
    func syncFavorites(_ favorites: FavoriteProgramStore,
                       programs: [RadikoProgram], station: Station) {
        for program in programs {
            guard let f = favorites.favorite(stationID: station.id, title: program.title) else { continue }
            let want = lead(for: f)
            guard Self.needsReminder(existingLead: reminder(programID: program.id)?.leadMinutes,
                                     favoriteLead: want, start: program.start) else { continue }
            add(program: program, station: station, lead: want, remembersLead: false)
        }
    }

    /// 该不该为这一次播出（重新）排提醒。
    ///
    /// 单独拎成纯函数是为了能离线自测：番組表每次加载都会跑一遍 `syncFavorites`，
    /// 若不比对「已排的提前值」，同一条提醒会被反复撤了又排（白写 UserDefaults、
    /// 通知也会在系统里抖一下）。`nonisolated`：自测在主 actor 之外调它。
    nonisolated static func needsReminder(existingLead: Int?, favoriteLead: Int,
                                         start: Date?, now: Date = Date()) -> Bool {
        guard let start, start > now else { return false }   // 排不进过去
        return existingLead != favoriteLead                  // 没排过，或提前值改了
    }

    /// 取消收藏 → 这档节目已排的提醒（可能横跨好几次播出）一起撤掉。
    /// 提醒不再是独立开关，留着任何一条都会让用户收到「一档已经取消收藏的节目」的通知。
    func removeAll(stationID: String, title: String) {
        let doomed = items.filter { $0.stationID == stationID && $0.programTitle == title }
        guard !doomed.isEmpty else { return }
        for r in doomed { cancelNotification(for: r) }
        items.removeAll { $0.stationID == stationID && $0.programTitle == title }
        persist()
    }

    /// 改「提前多久」→ 这档节目已排的、还没开播的提醒全部按新值重排。
    func updateLead(_ minutes: Int, stationID: String, title: String) {
        let now = Date()
        var changed = false
        for i in items.indices where items[i].stationID == stationID
                                  && items[i].programTitle == title {
            guard items[i].start > now, items[i].leadMinutes != minutes else { continue }
            cancelNotification(for: items[i])
            items[i].leadMinutes = minutes
            scheduleNotification(for: items[i])
            changed = true
        }
        if changed { persist() }
    }

    // MARK: - 通知

    private func requestAuthIfNeeded() {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleNotification(for r: ProgramReminder) {
        // 提前时间已经过去（比如 5 分钟后开播却选了「提前 10 分钟」）就立刻改成开播时提醒，
        // 否则这条通知会被系统直接丢掉，用户完全收不到。
        let fire = r.fireAt > Date() ? r.fireAt : r.start
        guard fire > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = T.notifSoonTitle
        content.body = T.notifSoonBody(r.programTitle, r.stationName, r.leadMinutes)
        content.sound = .default
        // 点通知要能跳到这台去听 —— 台号必须带在通知里（见 NotificationRouter）。
        content.userInfo = [NotificationRouter.stationKey: r.stationID]
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current()
            .add(UNNotificationRequest(identifier: Self.notifID(r.id), content: content, trigger: trigger))
    }

    private func cancelNotification(for r: ProgramReminder) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: [Self.notifID(r.id)])
    }

    private static func notifID(_ id: String) -> String { "remind-\(id)" }

    // MARK: - 持久化

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([ProgramReminder].self, from: data) else { return }
        items = decoded.sorted { $0.start < $1.start }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}

// MARK: - 通知点击 → 跳到该台

/// 本地通知的收件人。做两件事：
/// 1. App 在前台时也把通知**显示出来**（默认是静默丢弃 —— 提醒就白设了）。
/// 2. 用户点通知时把 `stationID` 交给界面，由 `TunerView` 选台开播。
///
/// 必须在 App 启动早期就设为 `UNUserNotificationCenter.delegate`，
/// 否则冷启动那次点击（App 没在运行时收到的通知）的回调会丢。
@MainActor
final class NotificationRouter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// `nonisolated`：`didReceive` 回调是 nonisolated 的，要在那里读这个键。
    nonisolated static let stationKey = "stationID"

    /// 待处理的「跳到这台去听」请求；界面消费后置回 nil。
    @Published var openStationID: String?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let id = response.notification.request.content.userInfo[Self.stationKey] as? String
        guard let id else { return }
        await MainActor.run { self.openStationID = id }
    }
}
