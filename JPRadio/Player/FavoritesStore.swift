import Foundation

/// 收藏电台。跨地区收藏一组 station id，持久化在 UserDefaults。
/// 界面据此在地区栏最前面合成一条「★ 收藏」拨盘（见 `TunerView`）。
@MainActor
final class FavoritesStore: ObservableObject {
    private static let key = "favoriteStations"

    @Published private(set) var ids: Set<String>

    init() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
        ids = Set(saved)
    }

    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// 切换收藏状态。
    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(Array(ids), forKey: Self.key)
    }
}
