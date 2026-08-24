import SwiftUI
import AVKit

/// 录音的播放界面：与直播界面同一套外观（台标配色渐变背景 + 大号台标 + 白色圆形播放键），
/// 只把「频率 / 上一台下一台」换成录音自己的东西 —— 进度条、±15 秒、识别这一段。
///
/// **这里的识曲比直播更准**：不必另开一路去抓流，直接从录音文件里裁播放头附近的 12 秒
/// （`SongRecognizer.recognizeClip`），送出去的就是用户此刻听到的那段原样音频。
/// 只识一次 —— 录音不会自己走出新歌，想识别别处把播放头拖过去再点。
///
/// 播放器实例（`playback`）由录音库列表持有再传进来，所以关掉这一屏回到列表时那条录音
/// 仍在播、进度也接着走（列表行上的迷你进度条就是同一份状态）。
struct RecordingPlayerView: View {
    let recording: Recording
    @ObservedObject var store: RecordingStore
    @ObservedObject var playback: LocalPlayback

    @Environment(\.dismiss) private var dismiss
    @StateObject private var palette = PaletteStore()
    @StateObject private var recognizer = SongRecognizer()
    @AppStorage(L.key) private var appLanguageRaw = AppLanguage.en.rawValue
    /// 「播放时自动识曲」总开关（与直播那屏各记各的，键不同）。默认开。
    @AppStorage("autoRecognizeRecording") private var autoRecognize = true

    /// 录音里存的台号可能已经不在电台表里（数据表调整过）—— 那就只显示台名、不取台标。
    private var station: Station? { Station.station(id: recording.stationID) }
    private var url: URL { store.fileURL(for: recording) }
    private var isCurrent: Bool { playback.currentID == recording.id }
    /// ±15 秒（Apple 播放器的习惯步长，对应 `gobackward.15` / `goforward.15` 两个图标）。
    private static let skipSeconds: TimeInterval = 15

    var body: some View {
        // 显式依赖当前语言（同 TunerView）：切语言时这一屏的 T.* 重新求值。
        let _ = appLanguageRaw

        ZStack {
            background
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 4)
                cover
                info
                Spacer(minLength: 4)
                SongBanner(recognizer: recognizer)
                    .animation(.easeInOut(duration: 0.25), value: recognizer.song)
                    .animation(.easeInOut(duration: 0.25), value: recognizer.isActive)
                progress
                controls
                utilityBar
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if let station { palette.load(for: station) }
            playback.start(.init(recording: recording, url: url))
            syncAuto()
        }
        // 开关自动识曲、或这条不再是当前播放的录音时，跟上「该不该在识」。
        .onChange(of: autoRecognize) { _, _ in syncAuto() }
        .onChange(of: playback.currentID) { _, _ in syncAuto() }
        // 识出歌就把曲名/歌手/封面送进锁屏与控制中心（台名照旧保留，见 LocalPlayback.updateNowPlaying）；
        // 结果被清掉后自动退回录音标题与台标。
        .onChange(of: recognizer.song) { _, song in
            playback.showSong(title: song?.title, artist: song?.artist, artworkURL: song?.artworkURL)
        }
        // 关掉这一屏就别再识了（结果无处显示，还在白跑网络请求）。**播放不停**。
        .onDisappear { recognizer.stop() }
    }

    /// 让实时识别跟上「该不该识」：开着自动识曲、且这条正是当前录音时就一直识（暂停时
    /// `clipLoop` 会因为播放头没动而空转跳过，所以不必因暂停停掉 —— 停了反而会清掉已识出的曲卡）。
    private func syncAuto() {
        guard autoRecognize, isCurrent else {
            // 手动点起来的那次别被自动逻辑掐掉（比如想单独识一下这一段）。
            if recognizer.isActive && recognizer.isAuto { recognizer.stop() }
            return
        }
        guard !recognizer.isActive else { return }   // 已经在识（自动或手动一次）
        recognizer.startAutoClips(file: url) { playback.position }
    }
    // MARK: - 背景（与直播界面同一套：台标主色渐变 + 自上而下压黑）

    private var background: some View {
        ZStack {
            Color.black
            Rectangle()
                // 台标是异步取的，主色要等它到齐 —— 淡入一下，别硬切。
                .fill((station.map { palette.color(for: $0) } ?? PaletteStore.fallback).gradient)
                .animation(.easeInOut(duration: 0.55), value: palette.colors.count)
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.55), .black],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - 顶部（关闭 · 来源/时间）

    private var topBar: some View {
        ZStack {
            VStack(spacing: 2) {
                Text(recording.source.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(recording.dateText)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
            }
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 40, height: 40)
                        .background(.white.opacity(0.10), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(T.close)
                Spacer()
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }
    // MARK: - 台标（白色徽章，与直播界面的电台卡片同一个形状）

    /// 台标徽章。`station == nil`（台号已不在电台表里）时**不能**把 nil 交给 `AsyncImage` ——
    /// 那样它会永远停在 `.empty`，屏幕中央转一个永不停下的圈；直接画个波形字形代替。
    private var cover: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 16)

            if let station {
                AsyncImage(url: station.largeLogoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFit().padding(28)
                    case .empty:
                        ProgressView().tint(.gray)
                    default:
                        placeholderGlyph
                    }
                }
            } else {
                placeholderGlyph
            }
        }
        .aspectRatio(1.5, contentMode: .fit)
        .padding(.horizontal, 28)
    }

    private var placeholderGlyph: some View {
        Image(systemName: "waveform")
            .font(.system(size: 52))
            .foregroundStyle(.gray.opacity(0.5))
    }

    // MARK: - 标题 / 电台

    private var info: some View {
        VStack(spacing: 6) {
            Text(recording.displayTitle)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(stationLine)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .padding(.horizontal, 28)
        .padding(.top, 20)
    }

    /// 「TOKYO FM · 80.0 MHz」；台已不在电台表里时只剩台名。
    private var stationLine: String {
        guard let station else { return recording.stationName }
        return "\(recording.stationName) · \(station.frequencyText) MHz"
    }
    // MARK: - 进度

    /// 拖动期间只改本地位置、松手才真正 seek（与列表里的迷你进度条同一套逻辑，
    /// 因为它们绑的就是同一个 `playback`）。
    private var progress: some View {
        VStack(spacing: 2) {
            Slider(value: $playback.position,
                   in: 0...max(playback.seekableDuration, 1)) { editing in
                if editing { playback.beginScrub() } else { playback.endScrub() }
            }
            .tint(.white)
            HStack {
                Text(LocalPlayback.clock(playback.position))
                Spacer()
                // 剩余时间带负号，与系统播放器一致。
                Text("-" + LocalPlayback.clock(max(playback.seekableDuration - playback.position, 0)))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
        .disabled(!isCurrent)
        .padding(.horizontal, 28)
        .padding(.bottom, 12)
    }

    // MARK: - ±15 秒 / 播放暂停

    private var controls: some View {
        HStack(spacing: 36) {
            Button { playback.skip(-Self.skipSeconds) } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 26, weight: .regular))
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isCurrent)
            .accessibilityLabel(T.skipBack)

            playPauseButton

            Button { playback.skip(Self.skipSeconds) } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 26, weight: .regular))
                    .frame(width: 56, height: 56)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(!isCurrent)
            .accessibilityLabel(T.skipForward)
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.bottom, 14)
    }

    /// 白色圆形播放键（与直播界面同一个尺寸/重量）。
    /// 这里**不跟着 `isCurrent` 变灰**：万一别处把播放停了（`currentID` 清空），
    /// 这颗键还得能把这条录音重新播起来 —— 它是这一屏唯一的启动入口。
    private var playPauseButton: some View {
        let playing = isCurrent && playback.isPlaying
        return Button {
            playback.toggle(.init(recording: recording, url: url))
        } label: {
            ZStack {
                Circle()
                    .fill(.white)
                    .frame(width: 74, height: 74)
                    .shadow(color: .black.opacity(0.30), radius: 14, y: 8)
                Image(systemName: playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.black)
                    // play.fill 的视觉重心偏左，往右挪一点才居中。
                    .offset(x: playing ? 0 : 2)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(playing ? T.pause : T.play)
    }
    // MARK: - 底部工具条（AirPlay · 识别这一段 · 导出）

    /// 与直播界面同一条「玻璃条」，只是槽位换成录音用得上的三个。
    private var utilityBar: some View {
        HStack(spacing: 0) {
            RoutePickerButton()
                .frame(width: 34, height: 34)
                .frame(maxWidth: .infinity, minHeight: 48)
            shazamButton
            ShareLink(item: url) {
                slot(icon: "square.and.arrow.up", active: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(T.export)
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
        .padding(.horizontal, 20)
        .padding(.bottom, 18)
    }

    /// 识曲槽位。**点一下**开/关「播放时自动识曲」（跟着播放头往前识下一首）；
    /// **长按**出菜单，可以只识当前这一段。自动/手动都从文件裁片，绝不退回麦克风。
    private var shazamButton: some View {
        let listening = recognizer.isActive
        return Menu {
            Toggle(isOn: $autoRecognize) {
                Label(T.autoIdentify, systemImage: "shazam.logo")
            }
            Button {
                // 只识播放头这一段：停掉自动循环，跑一次性识别。
                recognizer.stop()
                recognizer.recognizeClip(file: url, at: playback.position)
            } label: {
                Label(T.identifyOnce, systemImage: "waveform.badge.magnifyingglass")
            }
        } label: {
            slot(icon: autoRecognize ? "shazam.logo.fill" : "shazam.logo",
                 caption: listening ? (recognizer.isAuto ? T.autoShort : T.identifying) : nil,
                 active: autoRecognize || listening,
                 pulse: listening)
        } primaryAction: {
            autoRecognize.toggle()
        }
        .accessibilityLabel(T.identifyHere)
    }

    /// 槽位外观（照搬直播界面的 `slotLabel`：等宽、图标同尺寸、命中区域同高）。
    private func slot(icon: String, caption: String? = nil, active: Bool,
                      pulse: Bool = false) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .symbolEffect(.pulse, isActive: pulse)
            if let caption {
                Text(caption)
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .foregroundStyle(active ? Color.brand : .white.opacity(0.82))
        .frame(maxWidth: .infinity, minHeight: 48)
        .contentShape(Rectangle())
    }
}
