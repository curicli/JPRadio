import SwiftUI
import BackgroundTasks

@main
struct JPRadioApp: App {
    @StateObject private var favorites = FavoritesStore()
    @StateObject private var recordings = RecordingStore()
    @StateObject private var reservations = ReservationStore()
    @StateObject private var reminders = ReminderStore()
    @StateObject private var favoritePrograms = FavoriteProgramStore()
    /// 必须在启动最早期就建好：它在 init 里接管 UNUserNotificationCenter.delegate，
    /// 晚了的话「App 没运行时点通知启动」那一次回调会丢。
    @StateObject private var router = NotificationRouter()

    @Environment(\.scenePhase) private var scenePhase

    /// 后台刷新任务标识（与 Info.plist 的 BGTaskSchedulerPermittedIdentifiers 一致）。
    private static let refreshTaskID = "com.jpradio.refreshRecordings"

    var body: some Scene {
        WindowGroup {
            TunerView()
                // 系统自己画的控件（Slider、Menu、侧滑按钮、ProgressView…）跟着这个走。
                // 用代码常量而不是 asset catalog 的 AccentColor：手工打的未签名 ipa 没有
                // Assets.car，`accentColor` 会退回系统蓝，见 Models/Theme.swift。
                .tint(.brand)
                .environmentObject(favorites)
                .environmentObject(recordings)
                .environmentObject(reservations)
                .environmentObject(reminders)
                .environmentObject(favoritePrograms)
                .environmentObject(router)
                // 冷启动时 scenePhase 可能已经是 .active 而不再发变化事件，
                // 所以心跳要在这里也起一次（内部有幂等保护）。
                .task {
                    reservations.startTicking(into: recordings)
                    reminders.prune()
                    await reconcile()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // 开 App 即对账 + 起心跳：心跳让预约在 App 开着时准点动作
                // （只对一次账的话，一直开着 App 反而什么都不会发生）。
                Task { await reconcile() }
                reservations.startTicking(into: recordings)
                // 播完的提醒清掉：通知早就发过了，留着只让「预定」列表越来越长。
                reminders.prune()
            case .background:
                // 挂起后心跳不会被执行，留着只会在恢复时空转一轮；停掉更干净。
                // 正在进行的实时抓流任务不受影响（App 被挂起就自然停，这是 iOS 限制）。
                reservations.stopTicking()
                scheduleRefresh()
            default:
                break
            }
        }
        // iOS 的后台刷新是「机会性」调度，不保证准点；就绪通知作为兜底提醒。
        .backgroundTask(.appRefresh(Self.refreshTaskID)) {
            await reconcile()
            await scheduleRefresh()
        }
    }

    /// 补录已结束的预约 + 为正在播出的直连台预约尽力实时录。
    @MainActor
    private func reconcile() async {
        reservations.tickWhileActive(into: recordings)
        await reservations.reconcile(into: recordings)
    }

    private func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
