import SwiftUI

/// 识曲结果条：识出曲子时是一张卡片（封面 + 曲名/歌手 + Apple Music 链接 + 关闭钮），
/// 还在识或识别失败时是一行说明（失败原因原样带出来，可长按复制）。
///
/// 直播界面（`TunerView`）与录音播放界面（`RecordingPlayerView`）共用这一套外观 ——
/// 两处的状态机是同一个 `SongRecognizer`，横条的显示规则也完全一样，
/// 各写一份的话改了一处忘另一处，两个界面就会长得不一样。
///
/// 显示规则（与直播界面原先的行为一致）：
/// - 有结果 → 曲目卡片，一直留着直到用户关掉或换台。
/// - 「識別中…」**只在手动点的那次显示**：自动识别一直在跑，那条横条会永久挂着。
/// - 失败/麦克风被拒（此时循环已经停了）两种都显示 —— 原因不摆出来就只能靠猜。
struct SongBanner: View {
    @ObservedObject var recognizer: SongRecognizer

    var body: some View {
        if let song = recognizer.song {
            card(song)
        } else if recognizer.showsFailure || (recognizer.isActive && !recognizer.isAuto) {
            statusLine
        }
    }

    // MARK: - 曲目卡片

    private func card(_ song: SongRecognizer.Song) -> some View {
        HStack(spacing: 12) {
            AsyncImage(url: song.artworkURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(width: 46, height: 46)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(song.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !song.artist.isEmpty {
                    Text(song.artist)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let url = song.appleMusicURL {
                Link(destination: url) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                }
            }
            Button {
                recognizer.clear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
        // 卡片上下都要留白：它夹在电台卡片与拨盘之间，只给下边留 6pt 会挤成一条。
        .padding(.top, 10)
        .padding(.bottom, 12)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - 识别中 / 失败

    private var statusLine: some View {
        HStack(alignment: .top, spacing: 8) {
            if recognizer.isActive {
                ProgressView().controlSize(.small).tint(.white)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange.opacity(0.9))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                if let detail = recognizer.failureDetail {
                    // 技术细节（SHError 的 domain/code、HTTP 状态）：可长按选中复制。
                    Text(detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            if !recognizer.isActive {
                Button {
                    recognizer.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 20)
    }

    /// 文案随音频来源变：流 / 麦克风 / 本地录音三条路的失败含义完全不同
    /// （外放没开、这个流识不了、这一段识不出），一句通用的「识别失败」帮不上忙。
    private var text: String {
        switch recognizer.status {
        case .noMatch:
            // 还在跑 → 「仍在聆听」；已经收手（一次性识别）→ 「没有匹配到」。
            return recognizer.isActive ? T.noMatchListening : T.noMatchFound
        case .denied:
            return T.micDenied
        case .failed:
            switch recognizer.source {
            case .file:   return T.identifyFailedRecording
            case .stream: return T.identifyFailedStream
            case .mic:    return T.identifyFailed
            }
        default:
            switch recognizer.source {
            case .file:   return T.listeningRecording
            case .stream: return T.listeningStream
            case .mic:    return T.listening
            }
        }
    }
}
