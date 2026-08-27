import SwiftUI
import AVKit
import MediaPlayer
import UIKit

/// 录音库：收藏节目 + 预定（提醒 / 预约录制）+ 已录音列表（行内迷你播放器、导出、删除）。
/// 点一行的标题区会打开 [RecordingPlayerView]（与直播界面同一套外观的播放界面，可识曲）。
struct RecordingsSheet: View {
    @ObservedObject var store: RecordingStore
    @ObservedObject var reservations: ReservationStore
    @ObservedObject var reminders: ReminderStore
    @ObservedObject var favoritePrograms: FavoriteProgramStore
    /// 「自定义时间段」预约与番組表的预填电台（当前选中台）。
    var currentStation: Station?
    /// 开始播录音前把直播停掉（由 `TunerView` 传进来）。两路音频同时出声没人想听。
    /// 这个闭包同时把直播的**媒体卡片与远程控制**一起让出来（`RadioPlayer.yieldNowPlaying`），
    /// 好让录音接管锁屏/控制中心。
    var pauseLive: () -> Void = {}
    /// 录音停了把媒体卡片还给直播（`RadioPlayer.reclaimNowPlaying`）。
    var reclaimLive: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @StateObject private var playback = LocalPlayback()
    @State private var showingCustom = false
    /// 要打开番組表的台：从「从节目表选择」进来是当前台，从收藏节目那一行进来是该行的台。
    /// 用 `sheet(item:)` 而不是布尔量，才能带着「打开哪台」这个信息一起present。
    @State private var scheduleStation: Station?
    /// 打开了播放界面的那条录音（全屏盖在录音库上）。
    @State private var playingRecording: Recording?
    /// 用于让「待录制 → 播出中 → 等待存档」这些**随时间变化**的标签自己刷新。
    @State private var now = Date()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 主入口：选节目比手调起止时间省事得多，所以排在最前。
                    Button {
                        scheduleStation = currentStation ?? Station.kantoFM[0]
                    } label: {
                        Label(T.pickFromSchedule, systemImage: "calendar.badge.clock")
                    }
                    Button {
                        showingCustom = true
                    } label: {
                        Label(T.customReserve, systemImage: "calendar.badge.plus")
                    }
                } footer: {
                    Text(T.pickFromScheduleHint)
                }

                if !upcomingReminders.isEmpty {
                    Section(T.reminders) {
                        ForEach(upcomingReminders) { r in
                            reminderRow(r)
                        }
                    }
                }

                if !pendingReservations.isEmpty {
                    Section(T.reservations) {
                        ForEach(pendingReservations) { r in
                            reservationRow(r)
                        }
                    }
                }

                Section(T.recordings) {
                    if store.items.isEmpty {
                        Text(T.noRecordings)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(store.items) { item in
                            recordingRow(item)
                        }
                    }
                }
            }
            .navigationTitle(T.recordings)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(T.close) { dismiss() }
                }
            }
            .sheet(isPresented: $showingCustom) {
                CustomReservationSheet(reservations: reservations, recordings: store,
                                       initialStation: currentStation)
            }
            // 从这里进节目表时没有「当前台」的语境，所以允许在表内换台。
            .sheet(item: $scheduleStation) { station in
                ProgramSheet(station: station, reservations: reservations, reminders: reminders,
                             favoritePrograms: favoritePrograms, allowsStationSwitch: true)
            }
            // 播放界面全屏盖上来（与直播界面一样的沉浸式版式，而不是又一层小卡片）。
            .fullScreenCover(item: $playingRecording) { item in
                RecordingPlayerView(recording: item, store: store, playback: playback)
            }
        }
        .presentationDetents([.large, .medium])
        // 把「让出/收回直播媒体卡片」的两个闭包交给播放器：开播时暂停直播并让卡片，
        // 停播时把卡片还回去（见 LocalPlayback.begin / stop）。
        .onAppear {
            playback.onEngage = pauseLive
            playback.onDisengage = reclaimLive
        }
        .task {
            reminders.prune()
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
        // 关掉录音库就停播（迷你播放器是这个界面的一部分）。
        // 但 `fullScreenCover` 盖上来时这个 onDisappear 也会跑 —— 那时正要开始播，不能停。
        .onDisappear { if playingRecording == nil { playback.stop() } }
    }

    /// 未完成的预约（待录 / 失败 / 错过都展示，便于用户知道结果并清理）。
    private var pendingReservations: [Reservation] {
        reservations.items.filter { $0.status != .completed }
    }

    /// 还没播完的收听提醒。
    private var upcomingReminders: [ProgramReminder] { reminders.upcoming }

    // MARK: - 提醒行

    private func reminderRow(_ r: ProgramReminder) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label(T.leadLabel(r.leadMinutes), systemImage: "bell.fill")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.yellow.opacity(0.18), in: Capsule())
                    .foregroundStyle(.yellow)
                Text(r.programTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
            }
            Text("\(r.stationName) · \(r.timeText)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button(role: .destructive) {
                // 提醒已并入收藏：单撤这一条会在下次载入番組表时又被补回来，
                // 所以这里直接取消收藏（连带撤掉这档节目排下的全部通知）。
                favoritePrograms.remove(id: FavoriteProgramStore.key(stationID: r.stationID, title: r.programTitle))
                reminders.removeAll(stationID: r.stationID, title: r.programTitle)
            } label: {
                Label(T.unfavoriteProgram, systemImage: "bookmark.slash")
            }
        }
    }

    // MARK: - 预约行

    private func reservationRow(_ r: Reservation) -> some View {
        let phase = phase(of: r)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    if phase == .fetching {
                        ProgressView().controlSize(.mini)
                    } else if phase == .airing {
                        Image(systemName: "record.circle").symbolEffect(.pulse)
                    }
                    Text(statusText(of: r, phase: phase))
                }
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint(of: r, phase: phase).opacity(0.18), in: Capsule())
                .foregroundStyle(tint(of: r, phase: phase))

                Text(r.programTitle)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
            }
            Text("\(r.stationName) · \(r.timeText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            // 失败/降级原因（HTTP 状态等）：不显示出来就永远查不出为什么没录到。
            if let note = r.note, !note.isEmpty {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if r.isDirect {
                Text(T.liveOnlyNote)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // 已结束的 radiko 预约可以手动催一次存档下载（也用于看失败原因）。
            if !r.isDirect, r.end <= now, r.status != .completed, phase != .fetching {
                Button(T.retryFetch) {
                    Task { await reservations.fetchNow(r, into: store) }
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button(role: .destructive) {
                reservations.remove(r)
            } label: {
                Label(T.cancelReserve, systemImage: "trash")
            }
        }
    }

    /// 预约的当前阶段。`status` 只记最终结果，「播出中 / 等存档 / 获取中」都是算出来的。
    private enum Phase { case scheduled, airing, awaiting, fetching, finished }

    private func phase(of r: Reservation) -> Phase {
        if reservations.isFetching(r) { return .fetching }
        guard r.status == .pending else { return .finished }
        if reservations.isCapturing(r) || r.isAiring(now) { return .airing }
        return r.end <= now ? .awaiting : .scheduled
    }

    private func statusText(of r: Reservation, phase: Phase) -> String {
        switch phase {
        case .fetching:  return T.statusFetching
        case .airing:    return T.statusAiring
        case .awaiting:  return r.isDirect ? T.statusMissed : T.statusAwaiting
        case .scheduled: return T.statusPending
        case .finished:  return r.status.label
        }
    }

    private func tint(of r: Reservation, phase: Phase) -> Color {
        switch phase {
        case .airing:              return .red
        case .fetching, .awaiting: return .orange
        case .scheduled:           return .brand
        case .finished:            return statusColor(r.status)
        }
    }

    private func statusColor(_ s: Reservation.Status) -> Color {
        switch s {
        case .pending:   return .brand
        case .completed: return .green
        case .failed:    return .red
        case .missed:    return .orange
        }
    }

    // MARK: - 录音行

    private func recordingRow(_ item: Recording) -> some View {
        let url = store.fileURL(for: item)
        let isCurrent = playback.currentID == item.id

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button {
                    playback.toggle(.init(recording: item, url: url))
                } label: {
                    Image(systemName: isCurrent && playback.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(Color.brand)
                }
                .buttonStyle(.plain)

                // 标题区整块可点 → 打开播放界面（台标 + 进度 + 识曲）。
                // 行内那个圆钮仍然只管播/停：想「边翻列表边听」时不该被全屏界面打断。
                Button {
                    open(item)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.displayTitle)
                            .font(.callout.weight(.semibold))
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(item.source.label)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.15), in: Capsule())
                            Text(item.stationName)
                            if let d = item.durationText {
                                Text("· \(d)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Text(item.dateText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(T.openPlayer)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary.opacity(0.6))

                ShareLink(item: url) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
            }

            // 播放中的那条展开成可拖动的进度条。
            // 用 Slider 而不是 ProgressView：拖动时只改本地位置，松手才真正 seek，
            // 免得时间观察者把手指下的滑块一路拽回去。
            if isCurrent {
                VStack(spacing: 2) {
                    Slider(value: $playback.position,
                           in: 0...max(playback.seekableDuration, 1),
                           onEditingChanged: { editing in
                        if editing { playback.beginScrub() } else { playback.endScrub() }
                    })
                    .tint(Color.brand)
                    HStack {
                        Text(LocalPlayback.clock(playback.position))
                        Spacer()
                        Text(LocalPlayback.clock(playback.seekableDuration))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
        .swipeActions {
            Button(role: .destructive) {
                if isCurrent { playback.stop() }
                store.delete(item)
            } label: {
                Label(T.delete, systemImage: "trash")
            }
        }
    }

    /// 打开某条录音的播放界面：让它开始播（界面里的控件都作用在同一个
    /// `playback` 上，所以关掉播放界面回到列表时，这条仍在播、进度也接着走）。
    /// 停直播、让出媒体卡片都由 `playback.begin` 里的 `onEngage` 统一处理。
    private func open(_ item: Recording) {
        playback.start(.init(recording: item, url: store.fileURL(for: item)))
        playingRecording = item
    }
}

// MARK: - 本地录音迷你播放器

/// 播放录音库里的本地文件（与直播播放器分开，避免互相打断状态）。
/// 支持拖动定位：`position` 双向绑定给 Slider，拖动期间不被时间观察者覆盖。
///
/// 录音库列表与 [RecordingPlayerView] 共用**同一个实例**（由列表持有、传进播放界面）——
/// 所以从播放界面退回列表时，那条录音仍在播、进度也接着走。
@MainActor
final class LocalPlayback: ObservableObject {
    /// 一条待播录音连同锁屏/控制中心要显示的信息。台标地址在这里就地查出来
    /// （录音只存台号），免得播放器再去认识 `RecordingStore`。
    struct Track {
        let id: String
        let url: URL
        let title: String
        let stationName: String
        let artworkURL: URL?
        let duration: TimeInterval?

        init(recording: Recording, url: URL) {
            id = recording.id
            self.url = url
            title = recording.displayTitle
            stationName = recording.stationName
            artworkURL = Station.station(id: recording.stationID)?.largeLogoURL
            duration = recording.duration
        }
    }

    @Published private(set) var currentID: String?
    @Published private(set) var isPlaying = false
    /// 当前位置（秒）。Slider 直接绑定它，所以是可写的。
    @Published var position: TimeInterval = 0
    /// 容器给出的时长；拿不到（拼接出来的裸 AAC 会是 indefinite）时为 0。
    @Published private(set) var duration: TimeInterval = 0

    /// 开始播放时调用：暂停直播并把媒体卡片让出来（由 `RecordingsSheet` 接上 `RadioPlayer`）。
    var onEngage: () -> Void = {}
    /// 停止播放时调用：把媒体卡片还给直播。
    var onDisengage: () -> Void = {}

    /// 进度条量程：容器时长 → 录音登记的时长 → 已播到的位置，取第一个可用的。
    var seekableDuration: TimeInterval {
        let known = duration > 0 ? duration : (fallbackDuration ?? 0)
        return max(known, position)
    }

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var fallbackDuration: TimeInterval?
    /// 手指按在滑块上：这期间不让播放进度改写 `position`。
    private var isScrubbing = false
    /// 当前这条录音的元数据（写锁屏卡片用）。
    private var track: Track?
    /// 已挂上的远程控制命令 target，停播时整批摘掉。
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    /// 台标缩略图；异步下载的按序号丢弃过期结果。
    private var artwork: MPMediaItemArtwork?
    private var artworkToken = 0
    /// 实时识曲识出的歌：有值时盖掉标题/歌手/封面（见 `updateNowPlaying`），空则退回录音本身。
    private var song: (title: String, artist: String)?
    /// 识曲封面；同样异步下载、按序号丢弃过期结果，与台标各记各的。
    private var songArtwork: MPMediaItemArtwork?
    private var songArtworkToken = 0

    func toggle(_ track: Track) {
        if currentID == track.id {
            isPlaying ? pause() : resume()
        } else {
            begin(track)
        }
    }

    func start(_ track: Track) {
        guard currentID != track.id else {
            if !isPlaying { resume() }
            return
        }
        begin(track)
    }

    /// 前后跳 `delta` 秒（负数为后退）。夹在 0…量程之间。
    func skip(_ delta: TimeInterval) {
        guard currentID != nil else { return }
        let target = min(max(0, position + delta), max(seekableDuration, 0))
        position = target
        seek(to: target)
        updateNowPlaying()
    }

    /// "1:02:33" / "4:10"。列表与播放界面共用。
    nonisolated static func clock(_ t: TimeInterval) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        let total = Int(t)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }

    // MARK: - 拖动

    func beginScrub() { isScrubbing = true }

    func endScrub() {
        isScrubbing = false
        seek(to: position)
        updateNowPlaying()
    }

    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // 容差给 0 会在裸 AAC 上很慢甚至定不住；留一点余量换取「拖到哪就从哪响」。
        player.seek(to: target,
                    toleranceBefore: CMTime(seconds: 0.5, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.5, preferredTimescale: 600))
    }

    // MARK: - 播放

    /// 开始播放某条录音。**已经是当前这条就不重来** —— 打开播放界面时会调 `start`，
    /// 若无条件重开，正听到一半点开界面会被拽回开头。
    private func begin(_ track: Track) {
        teardown()
        // 暂停直播并接管媒体卡片（两路音频同时出声没人想听）。
        onEngage()
        self.track = track
        let item = AVPlayerItem(url: track.url)
        let p = AVPlayer(playerItem: item)
        player = p
        currentID = track.id
        position = 0
        duration = 0
        // 老录音是分片拼出来的裸 AAC，容器里没有时长；先用录音登记的时长撑起量程，
        // 拿到真时长再覆盖。（新录音已在落盘后重封成 m4a，这里通常一次就拿到。）
        self.fallbackDuration = track.duration

        timeObserver = p.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                if !self.isScrubbing { self.position = time.seconds }
                let d = p.currentItem?.duration.seconds ?? 0
                if d.isFinite, d > 0 { self.duration = d }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isPlaying = false
                self.position = self.seekableDuration
                self.updateNowPlaying()
            }
        }

        // 容器时长（m4a 能直接拿到；裸 AAC 拿不到就维持 fallback）。
        Task { [weak self] in
            guard let loaded = try? await AVURLAsset(url: track.url).load(.duration) else { return }
            let seconds = loaded.seconds
            guard seconds.isFinite, seconds > 0 else { return }
            await MainActor.run { [weak self] in
                guard let self, self.currentID == track.id else { return }
                self.duration = seconds
                self.updateNowPlaying()
            }
        }

        p.play()
        isPlaying = true
        installRemoteCommands()
        loadArtwork(track.artworkURL)   // 内部会调 updateNowPlaying()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlaying()
    }

    private func resume() {
        // 播完后再点播放：从头开始，而不是卡在结尾。
        if seekableDuration > 0, position >= seekableDuration - 0.5 { seek(to: 0); position = 0 }
        player?.play()
        isPlaying = true
        updateNowPlaying()
    }

    /// 停止播放：拆掉播放器并把媒体卡片还给直播。
    func stop() {
        teardown()
        removeRemoteCommands()
        track = nil
        artwork = nil
        // 把卡片还给直播（`onDisengage` 里 `RadioPlayer.reclaimNowPlaying` 会重写整张卡片）。
        onDisengage()
    }

    /// 只拆播放器本身，不动媒体卡片/远程控制 —— `begin` 换曲时用，马上又要接管。
    private func teardown() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        player?.pause()
        player = nil
        currentID = nil
        isPlaying = false
        isScrubbing = false
        position = 0
        duration = 0
        fallbackDuration = nil
        // 换曲/停播都清掉上一条的识曲叠加，并作废在下的封面下载。
        song = nil
        songArtwork = nil
        songArtworkToken += 1
    }

    // MARK: - 锁屏 / 控制中心（播录音期间由本播放器接管，见 RadioPlayer.yieldNowPlaying）

    /// 把当前录音的信息写进锁屏/控制中心。`IsLiveStream = false` 让系统显示可拖动的进度条；
    /// 只在状态变化（播/停/跳/拿到时长）时写一次，其余时间系统按 `PlaybackRate` 自行推进。
    private func updateNowPlaying() {
        guard let track else { return }
        var info: [String: Any] = [:]
        if let song {
            // 识出歌了：曲名放第一行（最大那行），台名跟着歌手进第二行、也别丢。
            info[MPMediaItemPropertyTitle] = song.title
            info[MPMediaItemPropertyArtist] = song.artist.isEmpty
                ? track.stationName
                : "\(song.artist) — \(track.stationName)"
        } else {
            info[MPMediaItemPropertyTitle] = track.title
            info[MPMediaItemPropertyArtist] = track.stationName
        }
        info[MPNowPlayingInfoPropertyIsLiveStream] = false
        info[MPMediaItemPropertyPlaybackDuration] = seekableDuration
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        // 有歌就优先用识曲封面（封面还没下完时暂用台标顶着），没歌用台标。
        if let art = song != nil ? (songArtwork ?? artwork) : artwork {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 实时识曲结果 → 锁屏/控制中心：曲名/歌手替掉录音标题、专辑封面替掉台标。
    /// 传空（结果被清掉或识别停了）就整体退回录音本身。进度条量程/位置保持不变。
    func showSong(title: String?, artist: String?, artworkURL: URL?) {
        if let title, !title.isEmpty {
            song = (title, artist ?? "")
        } else {
            song = nil
        }
        loadSongArtwork(artworkURL)   // 内部会调 updateNowPlaying()
    }

    private func loadSongArtwork(_ url: URL?) {
        songArtwork = nil
        songArtworkToken += 1
        let token = songArtworkToken
        // 没歌或没封面地址：不下载，直接刷新（updateNowPlaying 会退回台标）。
        guard song != nil, let url else { updateNowPlaying(); return }
        updateNowPlaying()            // 先把曲名文字贴上，封面下完再补
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.songArtworkToken == token else { return }
                self.songArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlaying()
            }
        }
    }

    private func loadArtwork(_ url: URL?) {
        artwork = nil
        artworkToken += 1
        let token = artworkToken
        guard let url else { updateNowPlaying(); return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.artworkToken == token else { return }
                self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                self.updateNowPlaying()
            }
        }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand,
                 _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            commandTargets.append((command, command.addTarget(handler: handler)))
        }
        add(center.playCommand) { [weak self] _ in self?.resume(); return .success }
        add(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        add(center.togglePlayPauseCommand) { [weak self] _ in
            guard let self else { return .commandFailed }
            self.isPlaying ? self.pause() : self.resume()
            return .success
        }
        add(center.skipForwardCommand) { [weak self] _ in self?.skip(15); return .success }
        add(center.skipBackwardCommand) { [weak self] _ in self?.skip(-15); return .success }
        add(center.changePlaybackPositionCommand) { [weak self] event in
            guard let self, let e = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            self.position = min(max(0, e.positionTime), max(self.seekableDuration, 0))
            self.seek(to: self.position)
            self.updateNowPlaying()
            return .success
        }
        center.skipForwardCommand.preferredIntervals = [15]
        center.skipBackwardCommand.preferredIntervals = [15]
    }

    private func removeRemoteCommands() {
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
    }
}
