import Foundation
import Combine

/// 一条录音的元数据。音频文件放在 Documents/Recordings/<fileName>，
/// 这里只存文件名（不存绝对路径，避免沙盒容器路径在重装后漂移）。
struct Recording: Codable, Identifiable, Hashable {
    enum Source: String, Codable {
        case live       // 实时抓流录制
        case timefree   // radiko タイムフリー 存档下载

        var label: String {
            switch self {
            case .live: return T.sourceLive
            case .timefree: return T.sourceTimefree
            }
        }
    }

    let id: String
    let title: String        // 节目名（timefree）或时间戳标签（手动实时录制）
    let stationName: String
    let stationID: String
    let date: Date           // 节目/录制开始时间
    let duration: TimeInterval?
    let fileName: String
    let source: Source

    /// 列表主标题：无节目名时回退到台名。
    var displayTitle: String { title.isEmpty ? stationName : title }

    /// 时长显示，例如 "1:02:33" / "04:10"。
    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    /// 日期显示（本地时区、随当前语言）。
    var dateText: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.language.localeID)
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }
}

/// 录音库：管理 Documents/Recordings 下的音频文件与其元数据（Documents/recordings.json）。
/// 同时持有「实时录制」状态，供界面显示录制指示与计时。
@MainActor
final class RecordingStore: ObservableObject {

    @Published private(set) var items: [Recording] = []

    /// 正在实时录制的台 id（nil = 未在录）。
    @Published private(set) var liveStationID: String?
    /// 实时录制开始时间（用于计时显示）。
    @Published private(set) var liveStartedAt: Date?

    private var liveTask: Task<Void, Never>?

    var isRecording: Bool { liveStationID != nil }
    func isRecording(_ stationID: String) -> Bool { liveStationID == stationID }

    // MARK: - 目录 / 文件

    /// 音频目录：Documents/Recordings（首次访问时创建）。
    static let recordingsDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static var metadataURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings.json")
    }

    /// 某条录音的音频文件地址。
    func fileURL(for recording: Recording) -> URL {
        Self.recordingsDir.appendingPathComponent(recording.fileName)
    }

    init() { load() }

    // MARK: - 增删

    func add(_ recording: Recording) {
        items.insert(recording, at: 0)
        persist()
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: fileURL(for: recording))
        items.removeAll { $0.id == recording.id }
        persist()
    }

    // MARK: - 实时录制（手动录制当前台）

    /// 开始实时抓流录制。仅当 App 存活（前台或后台音频）时持续（iOS 限制）。
    func startLive(station: Station) {
        guard liveTask == nil else { return }
        liveStationID = station.id
        liveStartedAt = Date()
        let dir = Self.recordingsDir
        let base = UUID().uuidString
        liveTask = Task { [weak self] in
            let url = await LiveRecorder.capture(station: station, into: dir, filename: base)
            self?.finishLive(station: station, fileURL: url)
        }
    }

    /// 停止实时录制（触发 `capture` 收尾并入库）。
    func stopLive() {
        liveTask?.cancel()
    }

    private func finishLive(station: Station, fileURL: URL?) {
        let started = liveStartedAt
        liveTask = nil
        liveStationID = nil
        liveStartedAt = nil
        guard let fileURL else { return }
        let duration = started.map { Date().timeIntervalSince($0) }
        add(Recording(
            id: UUID().uuidString,
            title: Self.liveTitle(started ?? Date()),
            stationName: station.name,
            stationID: station.id,
            date: started ?? Date(),
            duration: duration,
            fileName: fileURL.lastPathComponent,
            source: .live))
    }

    // MARK: - 外部入库（下载 / 预约录制完成后登记元数据）

    /// 登记一条已写入 `recordingsDir` 的录音（timefree 下载或预约实时录制）。
    func importRecording(fileURL: URL, title: String, stationName: String,
                         stationID: String, date: Date, duration: TimeInterval?,
                         source: Recording.Source) {
        add(Recording(
            id: UUID().uuidString,
            title: title,
            stationName: stationName,
            stationID: stationID,
            date: date,
            duration: duration,
            fileName: fileURL.lastPathComponent,
            source: source))
    }

    // MARK: - 持久化

    private func load() {
        guard let data = try? Data(contentsOf: Self.metadataURL),
              let decoded = try? JSONDecoder().decode([Recording].self, from: data) else { return }
        // 只保留音频文件仍在的条目。
        items = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
        purgeOrphanFiles()
    }

    /// 清掉 Recordings 目录里没有元数据指向的文件。
    /// radiko 预约会先把实时抓到的那份留作备份、等存档对账后才决定入库还是删除；
    /// 若中途 App 被系统杀掉，这份文件就成了看不见也删不掉的孤儿，白占沙盒空间。
    /// 只在元数据成功读出后才清理（读不出时宁可留着，绝不误删用户录音）。
    private func purgeOrphanFiles() {
        let known = Set(items.map(\.fileName))
        let files = (try? FileManager.default.contentsOfDirectory(
            at: Self.recordingsDir, includingPropertiesForKeys: nil)) ?? []
        for f in files where !known.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: Self.metadataURL, options: .atomic)
    }

    private static func liveTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: L.language.localeID)
        f.dateStyle = .short
        f.timeStyle = .short
        return "\(T.sourceLive) · \(f.string(from: date))"
    }
}
