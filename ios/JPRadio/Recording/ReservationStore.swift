import Foundation
import Combine
import UserNotifications

/// 一条录音预约。radiko 台播完后走 タイムフリー 下载补录（可靠）；
/// 直连台（ListenRadio）无存档，只能在 App 活跃时尽力实时录。
struct Reservation: Codable, Identifiable, Hashable {
    enum Status: String, Codable {
        case pending, completed, failed, missed

        var label: String {
            switch self {
            case .pending:   return T.statusPending
            case .completed: return T.statusCompleted
            case .failed:    return T.statusFailed
            case .missed:    return T.statusMissed
            }
        }
    }

    let id: String            // 用 program.id，便于在节目表里判定「已预约」
    let stationID: String
    let stationName: String
    let areaID: String
    let isDirect: Bool        // 直连台（无 timefree）
    let programTitle: String
    let start: Date
    let end: Date
    var status: Status
    /// 失败/降级的具体原因（HTTP 状态等），直接显示在预约行上——
    /// 否则「没录到」永远查不出是卡在鉴权、播放列表还是分片。
    /// 用 `Optional` 是为了兼容旧存档：合成的 Decodable 对可选属性用 decodeIfPresent，
    /// 缺这个键也能解出来（换成非可选就会整个预约列表解码失败、全部丢掉）。
    var note: String?

    /// 正在播出？
    func isAiring(_ now: Date = Date()) -> Bool { start <= now && now < end }

    var timeText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.language.localeID)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: start)
    }
}

/// 预约录制的存储与执行：持久化预约、排本地通知、App 活跃时按心跳准点动作。
///
/// iOS 无法保证在设定时刻唤醒被杀掉的 App 去录直播，故分三层：
/// 1. **心跳**（`startTicking`，App 活跃时每 15s）：到点开实时录、播完立刻取存档。
/// 2. **radiko 存档**：播完后用 token 下载 タイムフリー（最可靠、最完整）；
///    实时录到的那份只作备份，存档成功即删除，存档失败才入库并注明原因。
/// 3. **兜底**：后台刷新 `BGAppRefresh` + 本地通知（提醒用户打开 App）。
///
/// 直连台（ListenRadio）没有存档，只有第 1 层——App 没开就是真的录不到。
@MainActor
final class ReservationStore: ObservableObject {

    @Published private(set) var items: [Reservation] = []
    /// 正在取回存档的预约 id（UI 显示「获取中…」）。
    @Published private(set) var fetchingIDs: Set<String> = []
    /// 正在实时抓流的预约 id（UI 显示「录制中」）。
    @Published private(set) var capturingIDs: Set<String> = []

    private static let key = "reservations"
    private var didRequestAuth = false
    /// 防止对账重入：启动时 `.task` 与 scenePhase `.active` 会同时触发，
    /// 若不加锁同一条预约可能被下载两次（录音库出现重复条目）。
    private var isReconciling = false
    /// 预约在 App 活跃时的实时抓流任务（按预约 id）。
    private var liveTasks: [String: Task<Void, Never>] = [:]
    /// radiko 预约实时录到的「备份」文件：存档取回成功就删掉，失败才入库。
    private var heldCaptures: [String: URL] = [:]
    /// 取存档失败后的退避时间点 + 已试次数（只在内存里，重启即清零）。
    private var retryAfter: [String: Date] = [:]
    private var attempts: [String: Int] = [:]
    /// App 活跃期间的心跳。
    private var ticker: Task<Void, Never>?

    /// 心跳间隔：预约「准点」的实际精度。
    private static let tickInterval: UInt64 = 15_000_000_000
    /// 取存档失败后的重试间隔与放弃阈值。
    private static let retryDelay: TimeInterval = 300
    private static let maxAttempts = 6

    init() { load() }

    func isReserved(programID: String) -> Bool {
        items.contains { $0.id == programID && $0.status == .pending }
    }

    func isFetching(_ r: Reservation) -> Bool { fetchingIDs.contains(r.id) }
    func isCapturing(_ r: Reservation) -> Bool { capturingIDs.contains(r.id) }

    // MARK: - 增删

    /// 预约一档 radiko 节目（节目表行触发）。返回是否为直连台（供 UI 提示「仅实时」）。
    @discardableResult
    func add(program: RadikoProgram, station: Station) -> Bool {
        guard let start = program.start, let end = program.end,
              !items.contains(where: { $0.id == program.id }) else { return station.isDirect }
        let r = Reservation(
            id: program.id, stationID: station.id, stationName: station.name,
            areaID: station.areaID, isDirect: station.isDirect,
            programTitle: program.title, start: start, end: end, status: .pending)
        items.append(r)
        items.sort { $0.start < $1.start }
        persist()
        requestAuthIfNeeded()
        scheduleNotifications(for: r)
        return station.isDirect
    }

    /// 预约任意时间段（自定义界面触发）。
    ///
    /// 与节目预约的唯一区别是 id 自造（节目预约用 program.id 以便节目表判「已预约」），
    /// 其余走完全相同的通知 / 对账链路——因此对 radiko 台选一个**已过去**的时间段，
    /// 下一次对账（打开 App 即触发）就会直接从 タイムフリー 下载，等于「补录」。
    @discardableResult
    func addCustom(station: Station, title: String, start: Date, end: Date) -> Reservation? {
        guard end > start else { return nil }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let r = Reservation(
            id: "custom-\(UUID().uuidString)", stationID: station.id, stationName: station.name,
            areaID: station.areaID, isDirect: station.isDirect,
            programTitle: name.isEmpty ? station.name : name,
            start: start, end: end, status: .pending)
        items.append(r)
        items.sort { $0.start < $1.start }
        persist()
        requestAuthIfNeeded()
        scheduleNotifications(for: r)
        return r
    }

    func remove(_ reservation: Reservation) {
        cancelNotifications(for: reservation)
        liveTasks[reservation.id]?.cancel()
        liveTasks[reservation.id] = nil
        capturingIDs.remove(reservation.id)
        retryAfter[reservation.id] = nil
        attempts[reservation.id] = nil
        // 实时录的备份还没入库就删掉，别在沙盒里留孤儿文件。
        if let held = heldCaptures.removeValue(forKey: reservation.id) {
            try? FileManager.default.removeItem(at: held)
        }
        items.removeAll { $0.id == reservation.id }
        persist()
    }

    // MARK: - 心跳（App 活跃时准点动作）

    /// 启动心跳：每 15s 检查一次「该开录了 / 该取存档了」。
    ///
    /// 早先只在启动与 scenePhase 变 `.active` 时对一次账 —— App 一直开着等到点，
    /// 什么也不会发生，非要切后台再切回来才动，这就是「预约没按时启动」。
    /// iOS 依然不保证唤醒被系统杀掉的 App（那部分只能靠 BGAppRefresh + 通知兜底）。
    func startTicking(into store: RecordingStore) {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.tickWhileActive(into: store)
                // 对账可能是一次很慢的下载：单独起任务，别拖住心跳（内部有重入保护）。
                Task { await self.reconcile(into: store) }
                try? await Task.sleep(nanoseconds: Self.tickInterval)
            }
        }
    }

    func stopTicking() {
        ticker?.cancel()
        ticker = nil
    }

    /// 到点就开录：正在播出的预约一律尽力实时抓流。
    /// radiko 的实时录只当**备份**（存档更完整），见 `settle`。
    func tickWhileActive(into store: RecordingStore) {
        let now = Date()
        for r in items where r.status == .pending {
            if r.isAiring(now) {
                if liveTasks[r.id] == nil { startCapture(r, into: store) }
            } else if now >= r.end, let task = liveTasks[r.id] {
                task.cancel()   // 到点收尾入库
            }
        }
    }

    // MARK: - 对账（心跳 / 开 App / 后台刷新）

    /// 收尾所有已结束的待录预约。瞬时失败保持 pending，按退避重试。
    func reconcile(into store: RecordingStore) async {
        guard !isReconciling else { return }
        isReconciling = true
        defer { isReconciling = false }

        let now = Date()
        // 还在实时抓的先不动，等它收尾（否则备份文件会和存档抢同一条预约）。
        let due = items.filter {
            $0.status == .pending && $0.end <= now && liveTasks[$0.id] == nil
                && (retryAfter[$0.id] ?? .distantPast) <= now
        }
        for r in due { await settle(r, into: store) }
    }

    /// 立刻取回（无视退避），供录音库里的「重试」按钮调用。
    func fetchNow(_ r: Reservation, into store: RecordingStore) async {
        guard r.end <= Date(), !fetchingIDs.contains(r.id) else { return }
        retryAfter[r.id] = nil
        attempts[r.id] = 0
        await settle(r, into: store)
    }

    /// 一条已结束预约的最终归宿。
    private func settle(_ r: Reservation, into store: RecordingStore) async {
        // 直连台没有存档：播出时录到的已在 finishCapture 入库，走到这儿就是真错过了。
        if r.isDirect { update(r.id, .missed, note: nil); return }

        if Date().timeIntervalSince(r.end) > 7 * 24 * 3600 {   // 超出 timefree 一周窗口
            if let held = heldCaptures.removeValue(forKey: r.id) {
                importLive(held, for: r, into: store)
            } else {
                update(r.id, .failed, note: T.tooOldForArchive)
            }
            return
        }

        fetchingIDs.insert(r.id)
        defer { fetchingIDs.remove(r.id) }
        do {
            let url = try await TimefreeRecorder.download(
                stationID: r.stationID, areaID: r.areaID,
                start: r.start, end: r.end, into: RecordingStore.recordingsDir)
            store.importRecording(
                fileURL: url, title: r.programTitle, stationName: r.stationName,
                stationID: r.stationID, date: r.start,
                duration: r.end.timeIntervalSince(r.start), source: .timefree)
            // 存档更完整，实时录的备份可以扔了。
            if let held = heldCaptures.removeValue(forKey: r.id) {
                try? FileManager.default.removeItem(at: held)
            }
            attempts[r.id] = nil
            update(r.id, .completed, note: nil)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            // 存档拿不到，但播出时实时录到了 —— 用这份，并说明为什么是实时版。
            if let held = heldCaptures.removeValue(forKey: r.id) {
                importLive(held, for: r, into: store, note: T.fellBackToLive(reason))
                return
            }
            let n = (attempts[r.id] ?? 0) + 1
            attempts[r.id] = n
            retryAfter[r.id] = Date().addingTimeInterval(Self.retryDelay)
            update(r.id, n >= Self.maxAttempts ? .failed : .pending, note: reason)
        }
    }

    // MARK: - 实时抓流（到点开录）

    private func startCapture(_ r: Reservation, into store: RecordingStore) {
        guard let station = Station.station(id: r.stationID) else { return }
        let dir = RecordingStore.recordingsDir
        let base = UUID().uuidString
        capturingIDs.insert(r.id)
        liveTasks[r.id] = Task { [weak self] in
            let url = await LiveRecorder.capture(station: station, into: dir, filename: base)
            guard let self else { return }
            self.liveTasks[r.id] = nil
            self.capturingIDs.remove(r.id)
            self.finishCapture(r, fileURL: url, into: store)
        }
    }

    private func finishCapture(_ r: Reservation, fileURL: URL?, into store: RecordingStore) {
        // 期间被用户删掉了：清理文件，不入库。
        guard items.contains(where: { $0.id == r.id }) else {
            if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
            return
        }
        guard let fileURL else {
            if r.isDirect { update(r.id, .missed, note: T.captureFailed) }
            return
        }
        if r.isDirect {
            importLive(fileURL, for: r, into: store)
        } else {
            heldCaptures[r.id] = fileURL    // radiko：备份，等 settle 决定用不用
        }
    }

    private func importLive(_ url: URL, for r: Reservation, into store: RecordingStore,
                            note: String? = nil) {
        store.importRecording(
            fileURL: url, title: r.programTitle, stationName: r.stationName,
            stationID: r.stationID, date: r.start,
            duration: min(Date(), r.end).timeIntervalSince(r.start), source: .live)
        attempts[r.id] = nil
        update(r.id, .completed, note: note)
    }

    // MARK: - 通知

    private func requestAuthIfNeeded() {
        guard !didRequestAuth else { return }
        didRequestAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func scheduleNotifications(for r: Reservation) {
        let center = UNUserNotificationCenter.current()
        if r.isDirect {
            schedule(center, id: "\(r.id)-start", at: r.start,
                     title: T.notifLiveTitle, body: T.notifLiveBody(r.programTitle))
        } else {
            // 结束后稍延迟，确保 timefree 已就绪。
            schedule(center, id: "\(r.id)-end", at: r.end.addingTimeInterval(60),
                     title: T.notifReadyTitle, body: T.notifReadyBody(r.programTitle))
        }
    }

    private func schedule(_ center: UNUserNotificationCenter, id: String, at date: Date,
                          title: String, body: String) {
        guard date > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func cancelNotifications(for r: Reservation) {
        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ["\(r.id)-start", "\(r.id)-end"])
    }

    // MARK: - 状态 / 持久化

    private func update(_ id: String, _ status: Reservation.Status, note: String?) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
        items[i].note = note
        persist()
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([Reservation].self, from: data) else { return }
        items = decoded.sorted { $0.start < $1.start }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
