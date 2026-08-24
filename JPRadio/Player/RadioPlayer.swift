import AVFoundation
import MediaPlayer
import UIKit
import Combine
import ShazamKit

/// 电台播放器：串联「鉴权 → 解析流地址 → AVPlayer 播放」，
/// 并负责锁屏/控制中心信息与远程控制。
@MainActor
final class RadioPlayer: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentStation: Station? {
        didSet {
            // 换台就把上一首识出的歌丢掉 —— 否则锁屏上会挂着另一个台的曲名。
            if oldValue?.id != currentStation?.id { song = nil }
        }
    }

    /// 实时识曲识出的曲名/歌手，仅用于媒体界面（锁屏、控制中心、CarPlay）。
    /// `nil` = 没识出/已清空，此时那两行退回「台名 + 频率·简介」。
    private var song: (title: String, artist: String)?

    /// 供界面注入的「上一台/下一台」动作（拨盘顺序只有界面知道）。
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?

    private let player = AVPlayer()
    private var statusObserver: NSKeyValueObservation?
    private var playTask: Task<Void, Never>?
    private var retriedOnce = false
    /// 锁屏/控制中心缩略图的请求序号与当前来源地址。
    /// 序号用来丢弃「换台或换曲之后才回来」的下载结果；地址用来避免重复下载同一张图
    /// —— 实时识曲每轮都会给出同一首歌，同一个封面不该每次都重下一遍。
    private var artworkToken = 0
    private var artworkURL: URL?
    /// 锁屏/控制中心命令的 target 句柄，供 `yieldNowPlaying` 整批摘除。
    private var commandTargets: [(MPRemoteCommand, Any)] = []
    /// 正在播录音：暂时把媒体卡片与远程控制让给录音播放器（见 `yieldNowPlaying`）。
    private var yieldedNowPlaying = false
    /// 路由/中断通知的观察者（`RadioPlayer` 与 App 同生命周期，不需要主动移除）。
    private var sessionObservers: [NSObjectProtocol] = []
    /// 中断（来电等）开始前是否正在播，用于中断结束后决定要不要接着播。
    private var resumeAfterInterruption = false

    /// 伪装成移动 Safari 的 UA，用于直连社区FM（ListenRadio）流的防盗链校验。
    /// （录制引擎 `LiveRecorder` 也复用它——故标 `nonisolated`，可脱离主 actor 访问。）
    nonisolated static let browserUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    var isPlaying: Bool { state == .playing }

    init() {
        configureAudioSession()
        setupRemoteCommands()
        observeAudioSession()
        player.automaticallyWaitsToMinimizeStalling = true
        // 关掉「外部播放」——否则投到 Mac / Apple TV 这类**支持视频的 AirPlay 接收端**时，
        // AVPlayer 会把 HLS 地址整个交给对端去自己下载，而
        // `AVURLAssetHTTPHeaderFieldsKey` 里的 radiko token / 社区FM 的 Referer
        // 不会跟着过去：对端拿到 401/403，于是「连上了却放不出声」。
        // 置为 false 后音频在本机解码，AirPlay 只当音频输出路由，两类流都能正常播。
        player.allowsExternalPlayback = false
    }

    // MARK: - 对外控制

    /// 选中并（强制）播放某台。
    func play(_ station: Station) {
        currentStation = station
        state = .loading
        retriedOnce = false
        updateNowPlaying()
        loadArtwork(for: station)
        startPlayback(station, forceRefresh: false)
    }

    /// 切换选中的台：若正在播放/加载则无缝切流继续播放；
    /// 若处于关机/暂停状态则仅更新当前台，不自动出声（贴近真实调频器手感）。
    func select(_ station: Station) {
        let wasActive = (state == .playing || state == .loading)
        if wasActive {
            play(station)
        } else {
            currentStation = station
            loadArtwork(for: station)
            updateNowPlaying()
        }
    }

    func togglePlayPause() {
        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        default:
            if let station = currentStation { play(station) }
        }
    }

    func pause() {
        player.pause()
        state = .paused
        updateNowPlaying()
    }

    func resume() {
        guard currentStation != nil else { return }
        player.play()
        state = .playing
        updateNowPlaying()
    }

    // MARK: - 播放流程

    private func startPlayback(_ station: Station, forceRefresh: Bool) {
        playTask?.cancel()
        playTask = Task { [weak self] in
            guard let self else { return }

            // 直连流（ListenRadio 等非 radiko 台）：无需鉴权与区域伪造，直接播。
            // 但要带上「像浏览器」的 UA 与 Referer/Origin —— 部分社区FM CDN
            // （smartstream.ne.jp）按防盗链校验，缺失时返回 403，
            // 表现为「浏览器能放、app 里失败」。
            if let direct = station.directStreamURL, let url = URL(string: direct) {
                if Task.isCancelled { return }
                let headers = [
                    "User-Agent": Self.browserUserAgent,
                    "Referer": "https://listenradio.jp/",
                    "Origin": "https://listenradio.jp",
                ]
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                let item = AVPlayerItem(asset: asset)
                self.attach(item: item, station: station)
                return
            }

            do {
                let auth = RadikoAuthenticator.shared
                let token = forceRefresh
                    ? try await auth.refresh(area: station.areaID)
                    : try await auth.token(preferredArea: station.areaID)
                let url = try await RadikoStream.playlistURL(for: station, token: token)
                if Task.isCancelled { return }

                // 关键：让 AVPlayer 在所有 HLS 请求上带 radiko token。
                let headers = ["X-Radiko-AuthToken": token.value]
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                let item = AVPlayerItem(asset: asset)
                self.attach(item: item, station: station)
            } catch {
                if !Task.isCancelled {
                    self.state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func attach(item: AVPlayerItem, station: Station) {
        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observedItem, _ in
            let status = observedItem.status
            Task { @MainActor [weak self] in
                self?.handleStatusChange(status, station: station)
            }
        }
        player.replaceCurrentItem(with: item)
    }

    private func handleStatusChange(_ status: AVPlayerItem.Status, station: Station) {
        guard currentStation?.id == station.id else { return }
        switch status {
        case .readyToPlay:
            player.play()
            state = .playing
            updateNowPlaying()
        case .failed:
            handlePlaybackFailure(station: station)
        default:
            break
        }
    }

    private func handlePlaybackFailure(station: Station) {
        // token 可能过期 —— 强制刷新后重试一次。
        if !retriedOnce {
            retriedOnce = true
            startPlayback(station, forceRefresh: true)
        } else {
            state = .failed(T.playFailed)
            updateNowPlaying()
        }
    }

    // MARK: - 音频会话

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    /// 路由变化与中断的观察。切到 AirPlay（Mac / HomePod）时 `AVPlayer` 常常停在
    /// `rate == 0`，不重新 `play()` 就表现为「设备已连上却没有声音」；
    /// 来电之类的中断结束后同样需要自己恢复，否则会一直停在暂停态。
    private func observeAudioSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.routeChangeNotification,
                               object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
                let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init) ?? .unknown
                Task { @MainActor [weak self] in self?.handleRouteChange(reason) }
            })
        sessionObservers.append(
            center.addObserver(forName: AVAudioSession.interruptionNotification,
                               object: session, queue: .main) { [weak self] note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let type = raw.flatMap(AVAudioSession.InterruptionType.init)
                let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init) ?? []
                Task { @MainActor [weak self] in self?.handleInterruption(type, options) }
            })
    }

    private func handleRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .oldDeviceUnavailable:
            // 耳机被拔、AirPlay 目标消失：与系统行为一致地暂停，别突然从扬声器炸出来。
            if state == .playing { pause() }
        default:
            // 换了输出设备（含选中 AirPlay）：本该继续播的话就把它推起来。
            if state == .playing, player.rate == 0 {
                try? AVAudioSession.sharedInstance().setActive(true)
                player.play()
            }
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType?,
                                    _ options: AVAudioSession.InterruptionOptions) {
        switch type {
        case .began:
            // 系统已经把我们静音了；只把状态改对，好让界面与锁屏一致。
            resumeAfterInterruption = (state == .playing)
            if state == .playing { pause() }
        case .ended:
            guard resumeAfterInterruption else { return }
            resumeAfterInterruption = false
            guard options.contains(.shouldResume) else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
            resume()
        default:
            break
        }
    }

    // MARK: - 锁屏 / 控制中心

    private func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        // 记下每个 target，好在播录音时整批摘掉（见 `yieldNowPlaying`）——
        // 否则直播与录音两套处理器都挂在同一个共享命令上，一次点击会同时触发两边。
        func add(_ command: MPRemoteCommand,
                 _ handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            commandTargets.append((command, command.addTarget(handler: handler)))
        }
        add(center.playCommand) { [weak self] _ in self?.resume(); return .success }
        add(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
        add(center.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayPause(); return .success }
        add(center.nextTrackCommand) { [weak self] _ in self?.onNext?(); return .success }
        add(center.previousTrackCommand) { [weak self] _ in self?.onPrevious?(); return .success }
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
    }

    /// 播录音时把媒体卡片与远程控制让出去：录音播放器会装上自己的一套。
    /// 不摘掉这些 target，锁屏上按暂停会连直播一起暂停、并把卡片改回直播台。
    func yieldNowPlaying() {
        guard !yieldedNowPlaying else { return }
        yieldedNowPlaying = true
        for (command, target) in commandTargets { command.removeTarget(target) }
        commandTargets.removeAll()
    }

    /// 录音停了 / 播放界面关了：把媒体卡片收回来，重挂远程控制并重贴台标。
    func reclaimNowPlaying() {
        guard yieldedNowPlaying else { return }
        yieldedNowPlaying = false
        setupRemoteCommands()
        artworkURL = nil            // 录音期间卡片被对方改过，强制重贴一次台标
        updateNowPlaying()
        if let station = currentStation { setArtwork(url: station.largeLogoURL) }
    }

    /// 刷新锁屏/控制中心的文字。
    ///
    /// 识出歌了就把**曲名放第一行**（那一行字最大，是用户第一眼看的），
    /// 但**电台名不能因此消失** —— 它跟着歌手一起进第二行，同时单独写进
    /// `AlbumTitle`：控制中心只显示前两行，CarPlay 与部分车机会显示专辑名那一行，
    /// 两处都放才保证「歌名与台名同时看得到」。
    private func updateNowPlaying() {
        // 让给录音播放器时不写卡片（否则直播的暂停态会盖回录音信息）。
        guard !yieldedNowPlaying else { return }
        guard let station = currentStation else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        // 直连台（ListenRadio）的频率是为了拨盘定位合成出来的，不是真频率，别摆到锁屏上。
        let stationLine = station.isDirect
            ? station.name
            : "\(station.name) · \(station.frequencyText) MHz"
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let song {
            info[MPMediaItemPropertyTitle] = song.title
            info[MPMediaItemPropertyArtist] = song.artist.isEmpty
                ? stationLine
                : "\(song.artist) — \(stationLine)"
        } else {
            info[MPMediaItemPropertyTitle] = station.name
            info[MPMediaItemPropertyArtist] = "\(station.frequencyText) MHz · \(station.tagline)"
        }
        info[MPMediaItemPropertyAlbumTitle] = stationLine
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = (state == .playing) ? 1.0 : 0.0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// 把台标贴到锁屏/控制中心的缩略图上（换台时调用）。
    private func loadArtwork(for station: Station) {
        setArtwork(url: station.largeLogoURL)
    }

    /// 实时识曲的结果 → 媒体界面：曲名/歌手进文字（见 `updateNowPlaying`），
    /// 专辑封面替掉缩略图里的台标。
    /// 传 `nil`（结果被清掉、或识别停了）则整体退回当前台的台名与台标。
    func showSong(title: String?, artist: String?, artworkURL: URL?) {
        if let title, !title.isEmpty {
            song = (title, artist ?? "")
        } else {
            song = nil
        }
        updateNowPlaying()
        setArtwork(url: artworkURL ?? currentStation?.largeLogoURL)
    }

    /// 下载并贴图。同一地址不重复下载；下载期间若又换了台/换了曲，回来的那张按序号丢弃。
    private func setArtwork(url: URL?) {
        guard !yieldedNowPlaying else { return }
        guard url != artworkURL else { return }
        artworkToken += 1
        let token = artworkToken
        artworkURL = url
        guard let url else {
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = nil
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            return
        }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                guard let self, self.artworkToken == token else { return }
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                info[MPMediaItemPropertyArtwork] = artwork
                MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            }
        }
    }
}

// MARK: - 睡眠定时器

/// 到点自动暂停播放的睡眠定时器。倒计时通过 `remaining` 对外发布，
/// 触发时回调 `onFire`（由界面接到 `RadioPlayer.pause()`）。
@MainActor
final class SleepTimer: ObservableObject {
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var isActive = false

    /// 计时结束时的动作（例如暂停播放）。
    var onFire: (() -> Void)?

    private var task: Task<Void, Never>?

    /// 剩余时间的显示字符串，例如 "28:05"。
    var remainingText: String {
        let total = Int(remaining.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 启动/重设定时器（分钟）。传入 0 或负数视为关闭。
    func start(minutes: Int) {
        cancel()
        guard minutes > 0 else { return }
        let end = Date().addingTimeInterval(TimeInterval(minutes) * 60)
        remaining = end.timeIntervalSinceNow
        isActive = true
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                let left = end.timeIntervalSinceNow
                if left <= 0 {
                    self.remaining = 0
                    self.fire()
                    return
                }
                self.remaining = left
            }
        }
    }

    /// 取消定时器（不触发 onFire）。
    func cancel() {
        task?.cancel()
        task = nil
        isActive = false
        remaining = 0
    }

    private func fire() {
        task = nil
        isActive = false
        remaining = 0
        onFire?()
    }
}

// MARK: - 识曲（ShazamKit）

/// 识别正在播放的曲目。**优先内源识别**：直接从电台的 HLS 流里抓最近十几秒音频，
/// 生成 Shazam 指纹去匹配 —— 不需要麦克风权限、不需要外放、戴耳机/AirPlay 也能识。
///
/// 为什么不是 `MTAudioProcessingTap`：那只能挂在本地解码的音轨上，HLS 直播流拿不到；
/// 所以内源识别走「另开一路 HTTP 抓同一份分片」的办法（`LiveRecorder.snippet`），
/// 与播放器互不干扰，也不会打断正在播的音频。
///
/// 内源识别拿不到音频时（流地址解析失败等）**自动退回麦克风**路径，
/// 那条路要求电台正在外放。
///
/// 指纹用 ShazamKit 在本机生成，**查曲库这一步走 `ShazamWebMatcher`**（Shazam 客户端
/// 自己在用的接口），因此不需要付费开发者账号的 ShazamKit 能力 —— 原因见那个文件的说明。
/// 两条路都用同一个匹配函数，失败原因（HTTP 状态 / 指纹魔数）会带到界面上。
///
/// 有两种开法：手动点一次（`start(station:)`）和跟着播放自动开的**实时识别**
/// （`start(station:auto: true)`，界面上那个开关，默认开）—— 差别见 `isAuto`。
@MainActor
final class SongRecognizer: ObservableObject {

    struct Song: Equatable, Identifiable {
        let id = UUID()
        let title: String
        let artist: String
        let artworkURL: URL?
        let appleMusicURL: URL?
    }

    enum Status: Equatable { case idle, listening, matched, noMatch, denied, failed }

    /// 音频来源：内源（流）/ 麦克风 / 本地录音文件。界面用它区分提示文案。
    enum Source: Equatable { case stream, mic, file }

    @Published private(set) var status: Status = .idle
    @Published private(set) var song: Song?
    @Published private(set) var source: Source = .stream

    /// 识别是否在跑。**必须是 `@Published`**：以前它是 `task != nil` 的计算属性，
    /// SwiftUI 观察不到 —— 再点一下取消之后，界面没有任何publish可依，
    /// 「識別中/識別失敗」那条横条就一直挂着不动，看起来就是「点了没反应、失败不消失」。
    @Published private(set) var isActive = false

    /// 是否是「跟着播放自动开」的那次识别。自动模式与手动模式有三处刻意的差别：
    /// 1. **绝不退回麦克风** —— 用户没主动要求识曲，悄悄开麦并把音频类别切成
    ///    `.playAndRecord` 不是该默默做的事；内源抓不到就安静地不识。
    /// 2. **不显示「識別中…」横条** —— 自动模式一直在跑，那条会永久挂着；只有识出结果才出声。
    /// 3. **连续失败到上限就收手**（见 `autoFailureLimit`），免得每几秒重弹一次同样的错。
    @Published private(set) var isAuto = false

    /// 当前正在识哪台（自动模式据此判断「换台了要不要重启」）。
    @Published private(set) var stationID: String?

    /// 失败的真实原因（`NSError` 的 domain / code / 描述）。
    /// 识曲的失败模式太多 —— 抓不到音频、抓到的音频解不开、Shazam 侧直接拒绝 ——
    /// 只显示一句「識別失敗」的话根本没法往下查，所以把原始错误带到界面上。
    @Published private(set) var failureDetail: String?

    /// 循环已经停了、但有话要说（失败原因 / 麦克风被拒 / 这一段没匹配上）—— 界面据此保留提示条。
    /// `.noMatch` 也算：一次性识别（录音里点「识别这一段」）跑完没匹配上时，
    /// 若什么都不显示，用户看到的就是「转了一圈然后没反应」。
    var showsFailure: Bool {
        !isActive && (status == .failed || status == .denied || status == .noMatch)
    }

    private var task: Task<Void, Never>?
    /// 每次 `start` 自增。老任务收尾时凭它判断「我已经被换掉了」——
    /// 否则前一轮的 `finishTask()` 会把刚起的这一轮状态清成 idle。
    private var generation = 0
    /// 连续失败轮数（识出一次就归零）。
    private var consecutiveFailures = 0
    /// 自动模式下连续失败多少轮就停手。
    private static let autoFailureLimit = 3

    private var autoShouldGiveUp: Bool { isAuto && consecutiveFailures >= Self.autoFailureLimit }

    func toggle(station: Station?) { isActive ? stop() : start(station: station) }

    /// 开始识别。`auto = true` 为跟着播放自动开的实时识别（见 `isAuto`）。
    func start(station: Station?, auto: Bool = false) {
        guard !isActive else { return }
        // 自动模式没有台就没得识 —— 它不碰麦克风。
        if auto && station == nil { return }
        song = nil
        failureDetail = nil
        status = .listening
        isActive = true
        isAuto = auto
        stationID = station?.id
        consecutiveFailures = 0
        source = station == nil ? .mic : .stream
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            guard let self else { return }
            // 先试内源；连一段音频都抓不到才退回麦克风（自动模式不退）。
            if let station, await self.streamLoop(station: station) {
                self.finishTask(gen)
                return
            }
            if Task.isCancelled || auto { self.finishTask(gen); return }
            self.source = .mic
            await self.micLoop()
            self.finishTask(gen)
        }
    }

    // MARK: - 本地录音识别（录音播放界面：识别播放头附近那一段）

    /// 识别本地录音里 `position` 处正在放的曲子。
    ///
    /// 与直播那两条路刻意不同的地方：
    /// 1. **只跑一次** —— 录音不会自己往前走出新歌，要识别别处让用户把播放头拖过去再点。
    /// 2. **绝不退回麦克风** —— 音频就在文件里，开麦只会把手机自己的外放再录一遍。
    /// 3. 裁片这一步照旧不能省（见 `signature(of:)`）：整段一小时的录音送过去只会得到
    ///    `200 no match`。反过来说录音识曲比直播更准 —— 送出去的就是用户听到的那一段原样音频。
    func recognizeClip(file: URL, at position: TimeInterval) {
        task?.cancel()
        song = nil
        failureDetail = nil
        status = .listening
        isActive = true
        isAuto = false
        stationID = nil
        consecutiveFailures = 0
        source = .file
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let signature = try await Self.clipSignature(of: file, at: position)
                if !Task.isCancelled { await self.matchAndHandle(signature) }
            } catch is CancellationError {
            } catch {
                self.note(error, stage: "clip")
            }
            self.finishTask(gen)
        }
    }

    /// 跟着播放实时识曲：每隔一段从**当前播放头**裁一小段来识（录音播放界面的「自动识别」开关）。
    /// 与 `recognizeClip` 的一次性不同，这条会一直盯着播放头往前识下一首；
    /// 与直播的 `streamLoop` 不同：音频就在文件里，从不抓流、也绝不退回麦克风。
    ///
    /// `position` 传闭包而非定值 —— 循环每轮现取播放头：拖动进度、暂停继续都要按此刻真正听到的位置识。
    func startAutoClips(file: URL, position: @escaping @MainActor () -> TimeInterval) {
        guard !isActive else { return }
        song = nil
        failureDetail = nil
        status = .listening
        isActive = true
        isAuto = true
        stationID = nil
        consecutiveFailures = 0
        source = .file
        generation += 1
        let gen = generation
        task = Task { [weak self] in
            guard let self else { return }
            await self.clipLoop(file: file, position: position)
            self.finishTask(gen)
        }
    }

    /// `startAutoClips` 的循环体。播放头没往前挪够一段长度（暂停中、或原地打转）就跳过这轮 ——
    /// 识了也是同一个答案，白跑一趟网络请求。
    private func clipLoop(file: URL, position: @escaping @MainActor () -> TimeInterval) async {
        var lastAt: TimeInterval = -.infinity
        while !Task.isCancelled {
            let now = position()
            if abs(now - lastAt) < Self.snippetSeconds {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                continue
            }
            do {
                let signature = try await Self.clipSignature(of: file, at: now)
                if Task.isCancelled { return }
                lastAt = now
                await matchAndHandle(signature)
            } catch is CancellationError {
                return
            } catch {
                note(error, stage: "clip")
                if autoShouldGiveUp { return }
            }
            // 匹配上之后放慢：一首歌好几分钟，30 秒一次足够跟上换曲；没匹配上就按一段的长度追。
            let pause: UInt64 = status == .matched ? 30 : Self.autoClipInterval
            try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
        }
    }

    /// 没匹配上时两轮识别之间的间隔（秒）。取一段的长度：再密也只是把同一段重送。
    private static let autoClipInterval: UInt64 = 12

    /// 从本地文件里取 `position` 开始的 `snippetSeconds` 秒算指纹。
    private static func clipSignature(of file: URL,
                                      at position: TimeInterval) async throws -> SHSignature {
        let asset = AVURLAsset(url: file)
        let total = (try? await asset.load(.duration))?.seconds ?? 0
        // 整段本来就短于一段的长度（也含拿不到时长的裸 AAC）：直接整段算。
        guard total.isFinite, total > snippetSeconds + 1 else {
            return try await SHSignatureGenerator.signature(from: asset)
        }
        let start = min(max(0, position), total - snippetSeconds)
        guard let clip = await trim(file, from: start, seconds: snippetSeconds) else {
            // 裁不出来时**不要**退回整段：那必然是 no match，反而看不出真正的毛病在导出这一步。
            throw NSError(domain: "JPRadio.Recognize", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "clip export failed (\(Int(start))s +\(Int(snippetSeconds))s of \(Int(total))s)"])
        }
        defer { try? FileManager.default.removeItem(at: clip) }
        return try await SHSignatureGenerator.signature(from: AVURLAsset(url: clip))
    }

    /// 再点一下就取消识别：停掉循环、收起横条、把失败提示一起清掉。
    /// 已经匹配到的曲目卡片留着 —— 那正是用户想看的结果，不该被取消动作抹掉。
    func stop() {
        task?.cancel()
        task = nil
        restorePlaybackSession()
        isActive = false
        failureDetail = nil
        if status != .matched { status = .idle }
    }

    /// 循环自己跑完（被取消、或麦克风被拒）之后把状态收干净。
    /// `gen` 不是最新一轮就什么都不做 —— 那说明这条收尾来自已被换掉的旧任务。
    private func finishTask(_ gen: Int) {
        guard gen == generation else { return }
        task = nil
        isActive = false
        if status == .listening { status = .idle }
    }

    /// 清除当前识别结果卡片 / 失败提示。
    func clear() {
        song = nil
        failureDetail = nil
        if status != .listening { status = .idle }
    }

    // MARK: - 接口自检

    /// 自检报告（真机上跑出来的原文，界面原样显示、可复制）。
    @Published private(set) var probeReport: String?
    @Published private(set) var isProbing = false

    /// 抓一段音频算出指纹，然后把查曲库那一步的每种请求形状各试一遍。
    ///
    /// 为什么要在 App 里放这个：那个接口被拒时只回 `400` 加空正文，从状态码看不出是
    /// locale、地区、设备段、开关串还是签名容器不被接受；而开发机连不上 `amp.shazam.com`，
    /// 只能在真机上试。一次装包只验一种形状太慢，所以一次全打出去，看报告里哪一行是 200。
    func runProbe(station: Station?) {
        guard !isProbing, let station else { return }
        isProbing = true
        probeReport = nil
        Task { [weak self] in
            let text = await Self.probeText(station: station)
            guard let self else { return }
            self.isProbing = false
            self.probeReport = text
        }
    }

    func clearProbe() { probeReport = nil }

    private static func probeText(station: Station) async -> String {
        let scratch = FileManager.default.temporaryDirectory
        guard let file = await LiveRecorder.snippet(station: station,
                                                    seconds: snippetSeconds,
                                                    into: scratch) else {
            return "no audio: stream URL or segment fetch failed (\(station.id))"
        }
        defer { try? FileManager.default.removeItem(at: file) }
        let signature: SHSignature
        do {
            signature = try await SHSignatureGenerator.signature(from: AVURLAsset(url: file))
        } catch {
            let ns = error as NSError
            return "signature failed: \(ns.domain) \(ns.code) — \(ns.localizedDescription)"
        }
        var report = await ShazamWebMatcher.diagnose(signature: signature)
        // 裁短再各打一次。**这两行才是识曲实际走的路**（见 `signature(of:)`）——
        // 上面 `standard` 那行送的是整段（~20 秒），已知会回 `200 no match`，
        // 留着当对照组：它与这两行的差别就是「指纹太长」这个结论本身。
        for seconds in [12.0, 5.0] where signature.duration > seconds + 1 {
            report += "\n\(Int(seconds))s cut      \(await trimmedProbe(file, seconds: seconds))"
        }
        return report
    }

    /// 把音频裁到前 `seconds` 秒再算一次指纹送出去，只回一行结论。
    private static func trimmedProbe(_ file: URL, seconds: Double) async -> String {
        guard let short = await trim(file, seconds: seconds) else { return "trim failed" }
        defer { try? FileManager.default.removeItem(at: short) }
        do {
            let signature = try await SHSignatureGenerator.signature(from: AVURLAsset(url: short))
            return await ShazamWebMatcher.probe(signature: signature.dataRepresentation,
                                                durationMS: Int(signature.duration * 1000))
        } catch {
            return "signature failed: \((error as NSError).code)"
        }
    }

    /// 从抓下来的分片算指纹 —— **超过 `snippetSeconds` 必须先裁短**。
    ///
    /// 这不是优化而是能不能识别的分界线，真机自检里同一段音频的三行结果就是证据：
    /// ```
    /// standard  (19966ms 整段)  200 no match
    /// 12s       (裁到前 12 秒)  200 Hakujitsu   ← 正确曲名
    /// 5s        (裁到前 5 秒)   200 Hakujitsu
    /// ```
    /// 请求本身没问题（都是 200），是**指纹太长**：Shazam 客户端自己送的就是十来秒，
    /// 更长的指纹服务端匹配不上。而 HLS 分片只能整片取，要 12 秒实际会拿到 ~20 秒，
    /// 所以这一步是必须的。
    ///
    /// 裁不出来（导出失败）时退回整段：宁可这一轮 no match，也不要直接放弃识别。
    private static func signature(of file: URL) async throws -> SHSignature {
        let asset = AVURLAsset(url: file)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        guard seconds > snippetSeconds + 1,
              let short = await trim(file, seconds: snippetSeconds) else {
            return try await SHSignatureGenerator.signature(from: asset)
        }
        defer { try? FileManager.default.removeItem(at: short) }
        return try await SHSignatureGenerator.signature(from: AVURLAsset(url: short))
    }

    /// 导出 `start` 起的 `seconds` 秒到一个新的 m4a。裁不出来就返回 `nil`。
    ///
    /// 输出固定放临时目录（而不是源文件旁边）：录音库里的文件旁边多出一个 .m4a
    /// 会成为没有元数据指向的孤儿，下次启动被 `RecordingStore.purgeOrphanFiles` 清掉之前
    /// 一直白占沙盒空间；文件名用 UUID，两处同时裁也不会撞。
    private static func trim(_ file: URL, from start: Double = 0, seconds: Double) async -> URL? {
        let asset = AVURLAsset(url: file)
        guard let session = AVAssetExportSession(asset: asset,
                                                presetName: AVAssetExportPresetAppleM4A) else { return nil }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).m4a")
        session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                        duration: CMTime(seconds: seconds, preferredTimescale: 600))
        session.outputURL = output
        session.outputFileType = .m4a
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { continuation.resume() }
        }
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: output)
            return nil
        }
        return output
    }

    // MARK: - 内源识别（HLS 分片 → 指纹 → 匹配）

    /// 循环「抓一小段 → 生成指纹 → 匹配」。
    /// 返回 `false` 表示这条路根本没跑起来（一段音频都没抓到），交给麦克风兜底。
    private func streamLoop(station: Station) async -> Bool {
        let scratch = FileManager.default.temporaryDirectory
        var everCaptured = false

        while !Task.isCancelled {
            guard let file = await LiveRecorder.snippet(station: station,
                                                       seconds: Self.snippetSeconds,
                                                       into: scratch) else {
                if everCaptured {
                    // 之前能抓到，说明只是这一轮不顺（换台/网络抖动）——等一下再试。
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    continue
                }
                return false
            }
            everCaptured = true
            defer { try? FileManager.default.removeItem(at: file) }
            if Task.isCancelled { return true }

            let signature: SHSignature
            do {
                signature = try await Self.signature(of: file)
            } catch {
                // 抓到了音频却生不出指纹 —— 这段分片没法解码（容器/编码不对）。
                note(error, stage: "signature")
                if autoShouldGiveUp { return true }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                continue
            }
            if Task.isCancelled { return true }
            await matchAndHandle(signature)
            if autoShouldGiveUp { return true }
            // 每轮都要真下 ~12 秒音频（等于给流量翻一倍），所以匹配上之后放慢节奏：
            // 一首歌好几分钟，30 秒一次足够跟上换曲。
            let pause: UInt64 = status == .matched ? 30 : 8
            try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
        }
        return true
    }

    /// 每轮取多少秒音频：Shazam 十来秒足够，太长会把两首歌的片段混进一个指纹。
    /// 也是**送出去的指纹的上限**（见 `signature(of:)`）——超过这个长度服务端只回 no match。
    private static let snippetSeconds: Double = 12

    // MARK: - 麦克风识别（内源不可用时的兜底）

    /// **不用 `SHManagedSession`**：它内部直接连 Apple 的 Shazam 目录服务，
    /// 正是需要付费能力的那一步。这里自己录一段麦克风音频生成指纹，
    /// 再交给 `ShazamWebMatcher` —— 与内源那条路完全同一个匹配入口。
    private func micLoop() async {
        let granted = await Self.requestMicPermission()
        if Task.isCancelled { return }
        guard granted else {
            status = .denied
            return
        }
        configureRecordingSession()
        while !Task.isCancelled {
            let signature: SHSignature
            do {
                signature = try await Self.micSignature(seconds: Self.snippetSeconds)
            } catch is CancellationError {
                return
            } catch {
                // 麦克风起不来 / 采样格式不被接受：重试也是白试。
                note(error, stage: "mic")
                return
            }
            if Task.isCancelled { return }
            await matchAndHandle(signature)
            let pause: UInt64 = status == .matched ? 30 : 2
            try? await Task.sleep(nanoseconds: pause * 1_000_000_000)
        }
    }

    /// 录 `seconds` 秒麦克风并算出指纹。
    /// 指纹在音频线程上逐块累加（`append` 要求 48k/44.1k/32k/16k 的 PCM，输入节点的
    /// 原生格式就在其中，所以不另做重采样），`signature()` 在停掉 tap 之后才读 —— 用锁隔开两边。
    private static func micSignature(seconds: Double) async throws -> SHSignature {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let generator = SHSignatureGenerator()
        let lock = NSLock()
        input.installTap(onBus: 0, bufferSize: 8192, format: input.outputFormat(forBus: 0)) { buffer, when in
            lock.withLock { try? generator.append(buffer, at: when) }
        }
        engine.prepare()
        // 取消（用户再点一下）时 sleep 抛出，defer 保证引擎与 tap 一定收干净。
        defer {
            input.removeTap(onBus: 0)
            engine.stop()
        }
        try engine.start()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        return lock.withLock { generator.signature() }
    }

    // MARK: - 结果处理（两条路共用）

    /// 查曲库并落到界面状态上。
    private func matchAndHandle(_ signature: SHSignature) async {
        do {
            guard let match = try await ShazamWebMatcher.match(signature: signature) else {
                if song == nil { status = .noMatch }
                consecutiveFailures = 0   // 接口通了、只是这段没匹配上 —— 不算失败。
                return
            }
            // 已经被取消（换台/关掉自动识别）就别再往界面上写旧台的结果。
            if Task.isCancelled { return }
            song = Song(title: match.title.isEmpty ? T.unknownTrack : match.title,
                        artist: match.artist,
                        artworkURL: match.artworkURL,
                        appleMusicURL: match.appleMusicURL)
            status = .matched
            failureDetail = nil
            consecutiveFailures = 0
            // 继续听下一首（实时更新）。
        } catch is CancellationError {
            return
        } catch {
            note(error, stage: "match")
        }
    }

    /// 记下失败原因。`domain`/`code`/描述最能说明问题：
    /// - `signature` 阶段失败 → 抓到的那段音频解不开（分片容器/编码不对）。
    /// - `mic` 阶段失败 → 麦克风引擎起不来，或采样格式不被指纹生成器接受。
    /// - `match` 阶段失败 → 指纹算出来了，是查曲库这一步不通：
    ///   描述里的 `HTTP <状态>` 是 Shazam 接口的回应，`[sig 8025feca/…B]` 是**实际送出去的**
    ///   那份指纹的形状（剥壳之后的，见 `ShazamWebMatcher.unwrap`）——
    ///   魔数不是 `8025feca` 就说明剥壳这一步没生效，那才是要先查的；
    ///   魔数正常则问题在接口侧（限流、字段变更、网络），这时用长按识曲键里的
    ///   「识曲接口自检」把几种送法各试一遍。
    private func note(_ error: Error, stage: String) {
        let ns = error as NSError
        failureDetail = "\(stage): \(ns.domain) \(ns.code) — \(ns.localizedDescription)"
        consecutiveFailures += 1
        if song == nil { status = .failed }
    }

    // MARK: - 私有

    private static func requestMicPermission() async -> Bool {
        await withCheckedContinuation { cont in
            AVAudioApplication.requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
    }

    /// 切到「可录音」类别，保持外放的同时让麦克风可用。
    /// 带上 `.allowAirPlay`：否则 `.playAndRecord` 会把输出拽回本机扬声器，
    /// 正投到 Mac 上听时按一下麦克风识曲就断了。
    private func configureRecordingSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default,
                                 options: [.mixWithOthers, .defaultToSpeaker,
                                           .allowBluetoothA2DP, .allowAirPlay])
        try? session.setActive(true)
    }

    /// 识曲结束后恢复纯播放类别。仅内源识别时不动音频类别，避免打断播放。
    private func restorePlaybackSession() {
        guard source == .mic else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }
}
