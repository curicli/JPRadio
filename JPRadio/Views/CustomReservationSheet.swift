import SwiftUI

/// 「自定义时间段」预约：不依赖节目表，直接指定电台 + 起止时刻。
///
/// 时间一律按**日本时间**显示与选择（`\.timeZone` 环境值），因为 radiko / ListenRadio
/// 的编排都是 JST；`Date` 本身是绝对时刻，改环境只影响显示，不会偏移数据。
///
/// 对 radiko 台选**过去**的时间段等于「补录」：加入后立刻对账，
/// 走 タイムフリー 下载（存档只有一周，超窗会给出提示）。
struct CustomReservationSheet: View {
    @ObservedObject var reservations: ReservationStore
    @ObservedObject var recordings: RecordingStore

    @Environment(\.dismiss) private var dismiss

    @State private var regionID: String
    @State private var stationID: String
    @State private var title = ""
    @State private var start: Date
    @State private var end: Date
    /// 记住上一次的起点，改起点时把终点整体平移，保持时长不变。
    @State private var lastStart: Date

    private static let jst = TimeZone(identifier: "Asia/Tokyo")!
    /// 任何情况下都有台可选的兜底（静态字面量数组，必非空）。
    private static let fallbackStation = Station.kantoFM[0]

    /// `initialStation` 为打开时预填的电台（通常是当前选中台）。
    init(reservations: ReservationStore, recordings: RecordingStore, initialStation: Station?) {
        self.reservations = reservations
        self.recordings = recordings
        let base = initialStation ?? Self.fallbackStation
        // 默认「下一个整点起 1 小时」，比「此刻」更符合预约的语义。
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.jst
        let now = Date()
        let hourStart = cal.date(bySetting: .minute, value: 0, of: now) ?? now
        let s = hourStart > now ? hourStart : hourStart.addingTimeInterval(3600)
        _stationID = State(initialValue: base.id)
        _regionID = State(initialValue: Station.regions
            .first { $0.stations.contains(where: { $0.id == base.id }) }?.id
            ?? base.areaID)
        _start = State(initialValue: s)
        _lastStart = State(initialValue: s)
        _end = State(initialValue: s.addingTimeInterval(3600))
    }

    private var station: Station { Station.station(id: stationID) ?? Self.fallbackStation }
    private var currentRegion: Region? { Station.regions.first { $0.id == regionID } }
    private var isValid: Bool { end > start }
    /// radiko 存档只有一周：起点早于一周前就拿不到了。
    private var beyondArchive: Bool {
        !station.isDirect && start < Date().addingTimeInterval(-7 * 24 * 3600)
    }
    private var isBackfill: Bool { !station.isDirect && end <= Date() }

    var body: some View {
        NavigationStack {
            Form {
                stationSection
                timeSection
                noteSection
            }
            .environment(\.timeZone, Self.jst)
            .navigationTitle(T.customReserve)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(T.cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isBackfill ? T.downloadNow : T.add, action: submit)
                        .fontWeight(.semibold)
                        .disabled(!isValid || beyondArchive)
                }
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - 各节

    private var stationSection: some View {
        Section {
            // 两级选择（地区 → 电台）：ListenRadio 有数百个频道，摊平成一个列表不可用。
            Picker(T.area, selection: $regionID) {
                ForEach(Station.regions) { region in
                    Text("\(region.name) · \(region.subtitle)").tag(region.id)
                }
            }
            Picker(T.station, selection: $stationID) {
                ForEach(currentRegion?.stations ?? []) { s in
                    Text("\(s.name) · \(s.frequencyText)").tag(s.id)
                }
            }
            TextField(T.titleField, text: $title, prompt: Text(T.titleFieldPlaceholder))
        }
        // 换地区后原选中台不在列表里，Picker 会显示空白——立刻落到该区第一台。
        .onChange(of: regionID) { _, id in
            let list = Station.regions.first { $0.id == id }?.stations ?? []
            if !list.contains(where: { $0.id == stationID }), let first = list.first {
                stationID = first.id
            }
        }
    }

    private var timeSection: some View {
        Section {
            DatePicker(T.startTime, selection: $start, displayedComponents: [.date, .hourAndMinute])
            DatePicker(T.endTime, selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
            LabeledContent(T.durationLabel, value: durationText)
        } header: {
            Text(T.jstNote)
        } footer: {
            if !isValid {
                Text(T.invalidRange).foregroundStyle(.red)
            } else if beyondArchive {
                Text(T.tooOldForArchive).foregroundStyle(.red)
            }
        }
        // 改起点时把终点跟着平移，避免每次都要重设两个选择器。
        .onChange(of: start) { _, new in
            let span = max(end.timeIntervalSince(lastStart), 60)
            lastStart = new
            end = new.addingTimeInterval(span)
        }
    }

    private var noteSection: some View {
        Section {
            Label(station.isDirect ? T.liveOnlyNote : T.customReserveHint,
                  systemImage: station.isDirect ? "exclamationmark.triangle" : "info.circle")
                .font(.footnote)
                .foregroundStyle(station.isDirect ? .orange : .secondary)
        }
    }

    private var durationText: String {
        let total = max(Int(end.timeIntervalSince(start)), 0) / 60
        let h = total / 60, m = total % 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    // MARK: - 提交

    private func submit() {
        guard reservations.addCustom(station: station, title: title, start: start, end: end) != nil
        else { return }
        // 已播完的 radiko 时间段：立刻开始下载，不必等下一次 scenePhase 对账。
        if isBackfill {
            Task { await reservations.reconcile(into: recordings) }
        }
        dismiss()
    }
}
