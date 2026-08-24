import SwiftUI

/// 单个电台的大卡片：白色台标徽章 + 大号频率 + 台名。
struct StationCardView: View {
    let station: Station
    let isCurrent: Bool
    let isLoading: Bool
    let isPlaying: Bool
    var isFavorite: Bool = false
    var onToggleFavorite: () -> Void = {}

    var body: some View {
        VStack(spacing: 22) {
            badge
            info
        }
    }

    private var badge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white)
                .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 16)

            AsyncImage(url: station.largeLogoURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFit()
                        .padding(28)
                case .empty:
                    ProgressView().tint(.gray)
                default:
                    Image(systemName: "radio")
                        .font(.system(size: 56))
                        .foregroundStyle(.gray.opacity(0.5))
                }
            }

            if isLoading {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.black.opacity(0.06))
                ProgressView()
                    .controlSize(.large)
                    .tint(.gray)
            }

            if isCurrent && isPlaying {
                livePill
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
            }

            if isCurrent {
                favoriteButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(16)
            }
        }
        .aspectRatio(1.5, contentMode: .fit)
        .scaleEffect(isCurrent ? 1.0 : 0.9)
        .opacity(isCurrent ? 1.0 : 0.55)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: isCurrent)
    }

    /// 收藏星标（在白色徽章右上角，与左上角 LIVE 徽标镜像）。
    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(isFavorite ? Color.yellow : Color.black.opacity(0.32))
                .frame(width: 40, height: 40)
                .background(.black.opacity(0.05), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var livePill: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 7, height: 7)
            Text("LIVE").font(.system(size: 11, weight: .heavy)).foregroundStyle(.red)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(.red.opacity(0.12), in: Capsule())
    }

    private var info: some View {
        // 社区FM 的频率也已按真实广播频率填好，所以两类台用同一套版式：
        // 大号频率 + 台名 + 所在地（台名可能很长，允许两行并自动缩放）。
        VStack(spacing: 6) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("FM")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
                Text(station.frequencyText)
                    .font(.system(size: 66, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                Text("MHz")
                    .font(.system(size: 18, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(station.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 12)
            Text(station.tagline)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .opacity(isCurrent ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.25), value: isCurrent)
    }
}
