import SwiftUI
import AVKit

/// 主界面：动态渐变背景 + 地区切换 + 可左右滑动的电台分页 + FM 调频刻度尺 + 播放控制。
/// 附睡眠定时器、ShazamKit 实时识曲、番組表与多语言切换。
struct TunerView: View {
    @StateObject private var player = RadioPlayer()
    @StateObject private var palette = PaletteStore()
    @StateObject private var sleepTimer = SleepTimer()
    @StateObject private var recognizer = SongRecognizer()

    @EnvironmentObject private var favorites: FavoritesStore
    @EnvironmentObject private var recordings: RecordingStore
    @EnvironmentObject private var reservations: ReservationStore
    @EnvironmentObject private var reminders: ReminderStore
    /// 收藏的节目（番組表里点 ★ 加进来，录音库里列出）。
    @EnvironmentObject private var favoritePrograms: FavoriteProgramStore
    /// 点了「节目即将开始」的通知：带回来一个台号，这里负责选台开播。
    @EnvironmentObject private var router: NotificationRouter

    @AppStorage(L.key) private var appLanguageRaw = AppLanguage.en.rawValue
    /// 实时识曲：播放中自动识别正在放的曲子。默认开，工具条上的识曲键可随时关掉
    /// （每轮要另下 ~12 秒音频，介意流量的关掉即可）。
    @AppStorage("autoRecognize") private var autoRecognize = true

    @State private var regionIndex = 0
    @State private var selectedID: String? = "FMT"
    @State private var showSchedule = false
    @State private var showRecordings = false
    /// 点了顶部 ★ 收藏菜单里的某档节目：带着它去开番組表并翻到那一档（`.sheet(item:)`）。
    @State private var scheduleFavorite: FavoriteProgram?
    /// 启动时把拨盘对到默认台所属的真实地区，只做一次（见 `setup`）。
    @State private var didPickInitialRegion = false

    /// 合成拨盘的 id：它们不是真实地区，`Station.regions` 里没有对应项。
    private static let favRegionID = "FAV"
    private static let allRegionID = "ALL"
    private static let syntheticRegionIDs: Set<String> = [favRegionID, allRegionID]

    /// 拨盘列表 =「★ 收藏」（有收藏时）+「全部」+ 各真实地区。
    ///
    /// 「全部」把所有电台放到同一条刻度上（按频率升序）：想在全国范围里找台时不必先猜它在哪个区。
    /// 代价是同频台在刻度上重叠得更多（拖到该刻度会依次轮换，见 `FrequencyDialView`），
    /// 精确挑台还是滑上方卡片更快。
    private var regions: [Region] {
        var synthetic: [Region] = []
        let favStations = favorites.ids
            .compactMap { Station.station(id: $0) }
            .sorted { $0.frequency < $1.frequency }
        if !favStations.isEmpty {
            synthetic.append(Region(id: Self.favRegionID, name: "★",
                                    subtitle: T.favorites, stations: favStations))
        }
        let all = Station.allStationsByFrequency
        synthetic.append(Region(id: Self.allRegionID, name: T.allRegion,
                                subtitle: T.stationCount(all.count), stations: all))
        return synthetic + Station.regions
    }

    /// 当前地区的电台列表（regions 是动态的，索引需夹紧防越界）。
    private var stations: [Station] { regions[safeRegionIndex].stations }

    private var safeRegionIndex: Int {
        min(max(regionIndex, 0), regions.count - 1)
    }

    private var selectedStation: Station? {
        stations.first { $0.id == selectedID }
    }

    var body: some View {
        // 显式依赖当前语言：切换语言时整个界面的 T.* 文案重新求值。
        let _ = appLanguageRaw

        ZStack {
            background
            VStack(spacing: 0) {
                header
                regionBar
                StationPagerView(stations: stations, selectedID: $selectedID,
                                 player: player, favorites: favorites)
                    .frame(maxHeight: .infinity)
                recognitionBanner
                    .animation(.easeInOut(duration: 0.25), value: recognizer.song)
                    .animation(.easeInOut(duration: 0.25), value: recognizer.isActive)
                FrequencyDialView(stations: stations, selectedID: $selectedID)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                controls
                    .padding(.horizontal, 28)
                    .padding(.bottom, 14)
                utilityBar
                    .padding(.horizontal, 20)
                    .padding(.bottom, 22)
            }
        }
        .preferredColorScheme(.dark)
        .sensoryFeedback(.selection, trigger: selectedID)
        .onAppear(perform: setup)
        .onDisappear { recognizer.stop() }
        .onChange(of: selectedID) { _, newID in
            guard let station = stations.first(where: { $0.id == newID }) else { return }
            palette.load(for: station)
            player.select(station)
        }
        // 实时识曲跟着播放状态走：开始播/换台就接着识，暂停或关机就停。
        .onChange(of: player.state) { _, _ in syncAutoRecognition() }
        .onChange(of: player.currentStation?.id) { _, _ in syncAutoRecognition() }
        .onChange(of: autoRecognize) { _, on in
            // 关掉时连手动那次也一起停 —— 这个键就是「识曲总开关」。
            if !on { recognizer.stop() }
            syncAutoRecognition()
        }
        // 识出歌就把曲名/歌手/封面送进锁屏与控制中心（台名照旧保留，见 updateNowPlaying）；
        // 结果被清掉或换台后自动退回台名与台标。
        .onChange(of: recognizer.song) { _, song in
            player.showSong(title: song?.title, artist: song?.artist, artworkURL: song?.artworkURL)
        }
        // 「★ 收藏」区的出现/消失会让真实地区整体前后移一位，这里同步修正当前地区索引，
        // 避免用户刚点星标就被弹到别的拨盘上。
        .onChange(of: favorites.ids) { old, new in
            if old.isEmpty && !new.isEmpty {
                regionIndex += 1
            } else if !old.isEmpty && new.isEmpty {
                regionIndex = max(regionIndex - 1, 0)
            }
            regionIndex = min(max(regionIndex, 0), regions.count - 1)
            // 在收藏区取消收藏后当前台可能已不在拨盘上 —— 退回该拨盘第一台。
            if let id = selectedID, !stations.contains(where: { $0.id == id }) {
                selectedID = stations.first?.id
            }
        }
        // 点了提醒通知：跳到那台去听。冷启动时通知可能比界面先到，
        // 所以除了 onChange 还要在 onAppear 里消费一次（见 setup）。
        .onChange(of: router.openStationID) { _, id in
            guard let id else { return }
            open(stationID: id)
        }
        .sheet(isPresented: $showSchedule) {
            if let station = selectedStation {
                ProgramSheet(station: station, reservations: reservations, reminders: reminders,
                             favoritePrograms: favoritePrograms)
                    .preferredColorScheme(.dark)
            }
        }
        // 从顶部 ★ 收藏菜单进来：开那一档所在台的番組表，允许换台，并让它开表就翻到这档节目。
        .sheet(item: $scheduleFavorite) { fav in
            if let station = Station.station(id: fav.stationID) {
                ProgramSheet(station: station, reservations: reservations, reminders: reminders,
                             favoritePrograms: favoritePrograms, allowsStationSwitch: true,
                             initialFavoriteTitle: fav.title)
                    .preferredColorScheme(.dark)
            }
        }
        .sheet(isPresented: $showRecordings) {
            // pauseLive：点开某条录音时把直播停掉并让出媒体卡片；reclaimLive：停播后收回卡片。
            RecordingsSheet(store: recordings, reservations: reservations, reminders: reminders,
                            favoritePrograms: favoritePrograms, currentStation: selectedStation,
                            pauseLive: { player.pause(); player.yieldNowPlaying() },
                            reclaimLive: { player.reclaimNowPlaying() })
                .preferredColorScheme(.dark)
        }
    }

    /// 通知点进来：切到该台所在的拨盘、选中它并开播。
    ///
    /// `player.play` 放到下一轮：`selectedID` 的 onChange 会先跑一次 `player.select`，
    /// 两者同一帧里叠着调会把刚起的取流任务取消掉又重来一遍。
    private func open(stationID id: String) {
        guard let station = Station.station(id: id) else { return }
        // 已经在当前拨盘上就别换拨盘（在「全部」或「★」上点通知时不该被弹到别处）。
        if !stations.contains(where: { $0.id == id }), let index = dialIndex(containing: id) {
            regionIndex = index
        }
        selectedID = id
        router.openStationID = nil
        Task { @MainActor in
            palette.load(for: station)
            player.play(station)
        }
    }

    /// 找一台该落在哪条拨盘上：优先真实地区 —— 合成的「全部」什么台都装得下，
    /// 落在那儿等于没定位（用户看到的是一条挤满全国电台的刻度）。
    private func dialIndex(containing id: String) -> Int? {
        let real = regions.firstIndex {
            !Self.syntheticRegionIDs.contains($0.id) && $0.stations.contains { $0.id == id }
        }
        return real ?? regions.firstIndex { $0.stations.contains { $0.id == id } }
    }

    // MARK: - 背景

    private var background: some View {
        ZStack {
            Color.black
            Rectangle()
                .fill((selectedStation.map { palette.color(for: $0) } ?? PaletteStore.fallback).gradient)
                .animation(.easeInOut(duration: 0.55), value: selectedID)
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.55), .black],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部（语言 · 标题/状态 · 番組表）

    private var header: some View {
        ZStack {
            VStack(spacing: 3) {
                Text(T.title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                    .contentTransition(.opacity)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            // 右侧可能并排 ★ 收藏 + 番組表两颗钮，多留些余量免得长状态文案压上去。
            .padding(.leading, 44)
            .padding(.trailing, favoritePrograms.items.isEmpty ? 44 : 84)

            HStack {
                languageMenu
                Spacer()
                if !favoritePrograms.items.isEmpty { favoritesButton }
                scheduleButton
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }

    private var languageMenu: some View {
        Menu {
            Picker(T.language, selection: $appLanguageRaw) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.label).tag(lang.rawValue)
                }
            }
        } label: {
            Image(systemName: "globe")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: Circle())
        }
    }

    /// 顶部收藏节目按钮：番組表里收藏的节目都汇在这里，点一条就直接开番組表并翻到那一档。
    /// 用**书签**而不是星标 —— 星标是「收藏电台」的标志（拨盘上的「★ 收藏」区），
    /// 收藏节目改用书签才不至于两个 ★ 混在一起；配色也跟 🌐/📅 一样用白色，保持顶栏一致。
    private var favoritesButton: some View {
        Menu {
            ForEach(favoritePrograms.sorted) { f in
                Button {
                    scheduleFavorite = f
                } label: {
                    Text(f.title)
                    Text(f.slotText.isEmpty ? f.stationName : "\(f.stationName) · \(f.slotText)")
                }
            }
        } label: {
            Image(systemName: "bookmark")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: Circle())
        }
        .accessibilityLabel(T.favoritePrograms)
    }

    /// 番組表按钮。radiko 走官方节目表，直连的社区FM 走 ListenRadio 的 schedulelist 接口，
    /// 两路都由 `ProgramCatalog` 统一（所以只要选中了台就可用）。
    private var scheduleButton: some View {
        let unavailable = selectedStation == nil
        return Button {
            showSchedule = true
        } label: {
            Image(systemName: "calendar")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.white.opacity(0.08), in: Circle())
        }
        .opacity(unavailable ? 0 : 1)       // 保留占位，标题保持居中
        .disabled(unavailable)
    }

    /// 地区切换条（横向滑动的胶囊）。首位可能是合成的「★ 收藏」区。
    private var regionBar: some View {
        let current = safeRegionIndex
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(regions.enumerated()), id: \.element.id) { index, region in
                    Button {
                        selectRegion(index)
                    } label: {
                        VStack(spacing: 1) {
                            Text(region.name)
                                .font(.footnote.weight(.semibold))
                            Text(region.subtitle)
                                .font(.system(size: 9, weight: .medium))
                                .opacity(0.7)
                        }
                        .foregroundStyle(region.id == Self.favRegionID ? Color.yellow : .white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(
                            index == current ? Color.white.opacity(0.22) : Color.white.opacity(0.06),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().stroke(.white.opacity(index == current ? 0.5 : 0), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 10)
        // 与电台卡片之间要留出真正的空隙：原先只有 2pt，白卡几乎贴着地区胶囊。
        .padding(.bottom, 16)
    }

    // MARK: - 识曲结果 / 状态条

    /// 曲目卡片与「識別中/失败」那行的外观在 [SongBanner] 里（录音播放界面共用同一套）；
    /// 只有自检报告条留在这里 —— 那是直播界面独有的排错入口。
    @ViewBuilder
    private var recognitionBanner: some View {
        if let report = recognizer.probeReport {
            probeBanner(report)
        } else {
            SongBanner(recognizer: recognizer)
        }
    }

    /// 自检报告条。原样呈现（等宽、可选中复制）—— 这东西是拿来贴出来看的，不该被排版加工。
    /// 优先级放在曲目卡片之前：跑自检就是为了看报告，这时挡住卡片是对的。
    private func probeBanner(_ report: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ScrollView {
                Text(report)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 160)
            Button {
                recognizer.clearProbe()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    // MARK: - 实时识曲的开关逻辑

    /// 当下该自动识哪台：只在**正在播（或正在起流）**时识 —— 暂停/关机时下音频是白费流量。
    private var autoRecognitionStation: Station? {
        guard autoRecognize else { return nil }
        switch player.state {
        case .playing, .loading: return player.currentStation
        default:                 return nil
        }
    }

    /// 让识曲循环跟上「该识哪台」。换台、开始/停止播放、开关自动识别都汇到这里。
    private func syncAutoRecognition() {
        guard let station = autoRecognitionStation else {
            // 手动点起来的那次不该被自动逻辑掐掉（比如想识一下暂停前那首）。
            if recognizer.isActive && recognizer.isAuto { recognizer.stop() }
            return
        }
        if recognizer.isActive {
            // 已经在识同一台就别重启 —— 重启会把已经识出的曲目卡片清掉。
            guard recognizer.isAuto, recognizer.stationID != station.id else { return }
            recognizer.stop()
        }
        recognizer.start(station: station, auto: true)
    }

    // MARK: - 底部工具条（睡眠 · 录制 · AirPlay · 录音库 · 识曲）

    /// 收成一条「玻璃条」：5 个等宽槽位，图标同尺寸、命中区域同高。
    ///
    /// 之前是两端各挂一个带文字的胶囊、中间三个圆钮，形状/重量/间距都不齐，显得挤。
    /// 现在文字只在槽位**激活**时出现（睡眠倒计时 / 录制走秒 / 识曲中），
    /// 静止状态下就是一排干净的图标。
    private var utilityBar: some View {
        HStack(spacing: 0) {
            sleepMenu
            recordButton
            airplaySlot
            libraryButton
            shazamButton
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(.white.opacity(0.10), lineWidth: 1)
                )
        )
    }

    /// 工具条槽位的统一外观。`caption` 只在激活时给值。
    private func slotLabel(icon: String, caption: String? = nil, active: Bool,
                           tint: Color = .brand, pulse: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .symbolEffect(.pulse, isActive: pulse)
            if let caption {
                Text(caption)
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .foregroundStyle(active ? tint : .white.opacity(0.82))
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }

    /// 手动录制当前台（实时抓流）。仅在 App 存活时持续 —— iOS 会挂起被切走的进程。
    private var recordButton: some View {
        let active = recordings.isRecording
        return Button {
            if active {
                recordings.stopLive()
            } else if let station = selectedStation {
                recordings.startLive(station: station)
            }
        } label: {
            if active, let started = recordings.liveStartedAt {
                // 每秒刷新的走秒，不需要额外的 Timer 状态。
                TimelineView(.periodic(from: started, by: 1)) { ctx in
                    slotLabel(icon: "stop.fill",
                              caption: Self.elapsedText(from: started, to: ctx.date),
                              active: true, tint: .red, pulse: true)
                }
            } else {
                slotLabel(icon: "record.circle", active: false)
            }
        }
        .buttonStyle(.plain)
        .disabled(selectedStation == nil)
        .accessibilityLabel(active ? T.recordStop : T.record)
    }

    /// AirPlay 槽位（系统控件自带图标，尺寸对齐其它槽位）。
    private var airplaySlot: some View {
        RoutePickerButton()
            .frame(width: 34, height: 34)
            .frame(maxWidth: .infinity, minHeight: 48)
    }

    /// 录音库 / 预约列表入口。角标为待录预约数。
    private var libraryButton: some View {
        Button {
            showRecordings = true
        } label: {
            slotLabel(icon: "waveform", active: false)
                .overlay(alignment: .topTrailing) {
                    if pendingReservationCount > 0 {
                        Text("\(pendingReservationCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.brand, in: Circle())
                            .offset(x: -6, y: 4)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(T.recordings)
    }

    /// 角标数：待录预约 + 未播的收听提醒（两者都是「已经预定、还没发生」的事）。
    private var pendingReservationCount: Int {
        reservations.items.filter { $0.status == .pending }.count + reminders.upcoming.count
    }

    /// 录制走秒显示，例如 "03:12" / "1:02:33"。
    private static func elapsedText(from start: Date, to now: Date) -> String {
        let total = max(Int(now.timeIntervalSince(start)), 0)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    private var sleepMenu: some View {
        Menu {
            if sleepTimer.isActive {
                Button(role: .destructive) { sleepTimer.cancel() } label: {
                    Label(T.sleepOff, systemImage: "xmark")
                }
            }
            ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                Button(T.minutesStop(minutes)) { sleepTimer.start(minutes: minutes) }
            }
        } label: {
            slotLabel(icon: sleepTimer.isActive ? "moon.zzz.fill" : "moon.zzz",
                      caption: sleepTimer.isActive ? sleepTimer.remainingText : nil,
                      active: sleepTimer.isActive)
        }
        .accessibilityLabel(T.sleep)
    }

    /// 识曲槽位。**点一下**开/关「播放时自动识曲」（这是识曲总开关）；
    /// **长按**出菜单，可以只识一次 —— 手动那条路允许退回麦克风，自动模式刻意不碰麦克风。
    private var shazamButton: some View {
        let listening = recognizer.isActive
        return Menu {
            Toggle(isOn: $autoRecognize) {
                Label(T.autoIdentify, systemImage: "shazam.logo")
            }
            Button {
                // 传当前电台 → 走内源识别（直接读流）；没有台时才用麦克风。
                recognizer.stop()
                recognizer.start(station: player.currentStation ?? selectedStation)
            } label: {
                Label(T.identifyOnce, systemImage: "waveform.badge.magnifyingglass")
            }
            Button {
                // 识曲一直失败时用这个：抓一段音频，把查曲库那一步的每种请求形状各试一遍，
                // 报告直接显示在界面上（可复制）。见 `ShazamWebMatcher.diagnose`。
                recognizer.stop()
                recognizer.runProbe(station: player.currentStation ?? selectedStation)
            } label: {
                Label(T.identifyProbe, systemImage: "stethoscope")
            }
        } label: {
            slotLabel(icon: autoRecognize ? "shazam.logo.fill" : "shazam.logo",
                      caption: recognizer.isProbing ? T.probing
                             : (listening ? (recognizer.isAuto ? T.autoShort : T.identifying) : nil),
                      active: autoRecognize || listening || recognizer.isProbing,
                      pulse: listening || recognizer.isProbing)
        } primaryAction: {
            autoRecognize.toggle()
        }
        .accessibilityLabel(T.identify)
    }

    // MARK: - 播放控制条（三键居中）

    private var controls: some View {
        HStack(spacing: 40) {
            Button(action: previous) {
                Image(systemName: "backward.fill").font(.title2)
            }
            .disabled(isFirst)

            Button(action: togglePlay) {
                ZStack {
                    Circle().fill(.white).frame(width: 74, height: 74)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    playButtonIcon
                }
            }

            Button(action: next) {
                Image(systemName: "forward.fill").font(.title2)
            }
            .disabled(isLast)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var playButtonIcon: some View {
        switch player.state {
        case .loading:
            ProgressView().controlSize(.large).tint(.black)
        case .playing:
            Image(systemName: "pause.fill").font(.system(size: 30)).foregroundStyle(.black)
        default:
            Image(systemName: "play.fill").font(.system(size: 30))
                .foregroundStyle(.black).offset(x: 2)
        }
    }

    // MARK: - 状态

    private var statusText: String {
        switch player.state {
        case .idle:            return T.statusIdle
        case .loading:         return T.connecting
        case .playing:         return T.live
        case .paused:          return T.paused
        case .failed(let msg): return msg
        }
    }

    private var statusColor: Color {
        switch player.state {
        case .playing: return .green
        case .failed:  return .orange
        default:       return .white.opacity(0.6)
        }
    }

    // MARK: - 动作

    /// 播放/暂停。播放器还没拿到台时（拨盘刚变、选中项已失效等）先把当前拨盘上的台交给它，
    /// 否则 `togglePlayPause()` 在 `currentStation == nil` 时会静默地什么都不做。
    private func togglePlay() {
        if player.currentStation == nil, let station = selectedStation ?? stations.first {
            player.play(station)
            return
        }
        player.togglePlayPause()
    }

    private func setup() {
        // 合成拨盘（★ 收藏 /「全部」）排在真实地区之前，`regionIndex` 初值 0 就会落到
        // 挤满全国电台的「全部」上 —— 启动时对到默认选中台所属的真实地区更合用。
        // 只做一次：之后用户自己切到哪条拨盘就留在哪条。
        var index = safeRegionIndex
        if !didPickInitialRegion {
            didPickInitialRegion = true
            if let id = selectedID, let real = dialIndex(containing: id) { index = real }
            if index != regionIndex { regionIndex = index }
        }
        // 用局部的 list 而不是 stations：@State 刚写完就读回来并不保证拿到新值。
        let list = regions[min(max(index, 0), regions.count - 1)].stations
        for station in list { palette.load(for: station) }
        // 启动时默认选中的 "FMT" 不一定在当前拨盘上：有收藏时「★ 收藏」区排在最前，
        // 而收藏里可能没有它 —— 那样 player.currentStation 一直是 nil，点播放键会走
        // togglePlayPause 的 default 分支而什么都不做（表现为「要先拖一下封面才能播」）。
        // 这里兜底落到当前拨盘的第一台。
        if let station = list.first(where: { $0.id == selectedID }) ?? list.first {
            if selectedID != station.id { selectedID = station.id }
            palette.load(for: station)
            player.select(station)
        }
        player.onNext = next
        player.onPrevious = previous
        sleepTimer.onFire = { [weak player] in player?.pause() }
        // 冷启动：点通知启动 App 时，`router` 的值可能在这个界面出现之前就到了，
        // onChange 看不到那次赋值 —— 这里补消费一次。
        if let id = router.openStationID { open(stationID: id) }
    }

    /// 切换地区：更新拨盘、预取台标配色，并选中该地区第一个台。
    private func selectRegion(_ index: Int) {
        guard index != safeRegionIndex, regions.indices.contains(index) else { return }
        withAnimation(.easeInOut(duration: 0.3)) {
            regionIndex = index
        }
        let list = regions[index].stations
        for station in list { palette.load(for: station) }
        if let first = list.first {
            selectedID = first.id   // 触发 onChange(selectedID) → 更新配色 + 播放器
        }
    }

    private var currentIndex: Int {
        stations.firstIndex { $0.id == selectedID } ?? 0
    }
    private var isFirst: Bool { currentIndex == 0 }
    private var isLast: Bool { currentIndex == stations.count - 1 }

    private func next() {
        guard currentIndex < stations.count - 1 else { return }
        withAnimation { selectedID = stations[currentIndex + 1].id }
    }
    private func previous() {
        guard currentIndex > 0 else { return }
        withAnimation { selectedID = stations[currentIndex - 1].id }
    }
}

/// AirPlay 输出选择按钮（系统原生控件）。录音播放界面也用它，所以不是 private。
struct RoutePickerButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = UIColor(Color.brand)
        view.prioritizesVideoDevices = false
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

#Preview {
    TunerView()
        .environmentObject(FavoritesStore())
        .environmentObject(RecordingStore())
        .environmentObject(ReservationStore())
        .environmentObject(ReminderStore())
        .environmentObject(NotificationRouter())
}
