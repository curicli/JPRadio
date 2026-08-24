import SwiftUI

/// 左右滑动、吸附居中的电台分页。选中项通过 `selectedID` 与外部（拨盘、播放器）同步。
struct StationPagerView: View {
    let stations: [Station]
    @Binding var selectedID: String?
    @ObservedObject var player: RadioPlayer
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        GeometryReader { geo in
            let cardWidth = geo.size.width * 0.80
            let side = max((geo.size.width - cardWidth) / 2, 0)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 0) {
                    ForEach(stations) { station in
                        StationCardView(
                            station: station,
                            isCurrent: station.id == selectedID,
                            isLoading: isLoading(station),
                            isPlaying: isPlaying(station),
                            isFavorite: favorites.contains(station.id),
                            onToggleFavorite: { favorites.toggle(station.id) }
                        )
                        .frame(width: cardWidth)
                        .frame(maxHeight: .infinity)
                        .id(station.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            // 两端留白必须用 contentMargins 而不是给 HStack 加 padding：padding 是内容的一部分，
            // ScrollView 并不知道「可视区其实内缩了」，吸附与程序化定位就各算一套，卡片停不到中间。
            .contentMargins(.horizontal, side, for: .scrollContent)
            // anchor 必须显式给 .center。默认（nil）是「滚动最少的距离让它可见」——
            // 从拨盘往右调台时，只把下一张卡片刚好挪进右边缘就停手，于是卡片一直歪在偏右的位置。
            .scrollPosition(id: $selectedID, anchor: .center)
            .scrollClipDisabled()
        }
    }

    private func isLoading(_ station: Station) -> Bool {
        player.currentStation?.id == station.id && player.state == .loading
    }

    private func isPlaying(_ station: Station) -> Bool {
        player.currentStation?.id == station.id && player.state == .playing
    }
}
