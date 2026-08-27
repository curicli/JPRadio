import Foundation

/// 一个可在 FM 拨盘上出现的电台。
/// `frequency` 是该台真实的 FM 频率（MHz），用于在调频刻度尺上定位；
/// `id` 是 radiko 的 station id（用于鉴权后拉流）。
struct Station: Identifiable, Hashable {
    let id: String            // radiko station id，例如 "FMT"
    let name: String          // 显示名
    let frequency: Double     // FM 频率（MHz）
    let areaID: String        // radiko 区域，例如 "JP13"（东京）
    let tagline: String       // 副标题 / 一句话介绍

    /// 非 radiko 台（如 ListenRadio 社区FM）的直连 HLS 流地址；
    /// 为 nil 时走 radiko 鉴权拉流。
    var directStreamURL: String? = nil
    /// 自定义台标地址；为 nil 时用 radiko 官方台标。
    var logoOverride: String? = nil

    /// 是否为直连流（非 radiko，不需要鉴权 / 区域伪造 / 番組表）。
    var isDirect: Bool { directStreamURL != nil }

    /// 台标（radiko 官方多尺寸台标，或直连台的自定义台标）。
    var logoURL: URL? {
        if let logoOverride { return URL(string: logoOverride) }
        return URL(string: "https://radiko.jp/v2/static/station/logo/\(id)/224x100.png")
    }

    /// 大尺寸台标（用于详情卡）。
    var largeLogoURL: URL? { logoURL }

    /// 频率的显示字符串，例如 "80.0"。
    var frequencyText: String {
        String(format: "%.1f", frequency)
    }
}

/// 一个地区（radiko 区域）及其策展电台列表。切地区 = 换一整条 FM 拨盘。
struct Region: Identifiable, Hashable {
    let id: String            // radiko areaID，例如 "JP13"
    let name: String          // 主显示名，例如 "東京"
    let subtitle: String      // 副标题，例如 "関東"
    let stations: [Station]   // 该地区拨盘上的电台（频率升序、互不撞车）
}

extension Station {
    /// 拨盘刻度尺的频率范围。
    static let dialLowerBound: Double = 76.0
    static let dialUpperBound: Double = 95.0

    /// radiko 地区（境外绕过后逐区伪造 GPS）。同一地区内频率互不相同，保证拨盘上不会重叠。
    static let radikoRegions: [Region] = [
        Region(id: "JP13", name: "東京",   subtitle: "関東",   stations: kantoFM),
        Region(id: "JP27", name: "大阪",   subtitle: "関西",   stations: kansaiFM),
        Region(id: "JP23", name: "名古屋", subtitle: "中部",   stations: chubuFM),
        Region(id: "JP01", name: "札幌",   subtitle: "北海道", stations: hokkaidoFM),
        Region(id: "JP40", name: "福岡",   subtitle: "九州",   stations: kyushuFM),
        Region(id: "JP47", name: "那覇",   subtitle: "沖縄",   stations: okinawaFM),
    ]

    /// 全部地区 = radiko 六区 + ListenRadio 全国コミュニティFM（直连，无需鉴权）。
    static var regions: [Region] { radikoRegions + listenRadioRegions }

    /// 所有地区的全部电台（用于按 id 查表：收藏区/录音/预约需要跨区还原一台）。
    static let allStations: [Station] = regions.flatMap(\.stations)

    /// 「全部」拨盘：所有电台放在同一条刻度上，按频率升序。
    ///
    /// 频率相同的台（不同城市复用同一频率在日本社区FM里很常见，全国合到一条尺子上会更多）
    /// 在刻度上重叠，拖到该刻度时由 `FrequencyDialView` 依次轮换选中 —— 想精确挑台还是
    /// 滑上方的卡片。并列时按 id 兜底排序：`sorted` 不保证稳定，不定序会让「上一台/下一台」
    /// 每次启动的次序都不一样。
    static let allStationsByFrequency: [Station] = {
        var seen = Set<String>()
        return allStations
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.frequency, $0.id) < ($1.frequency, $1.id) }
    }()

    /// 按 radiko station id 查一台（找不到返回 nil）。
    static func station(id: String) -> Station? {
        allStations.first { $0.id == id }
    }

    // MARK: - 各地区电台（AM 台使用其 ワイドFM 频率）

    /// 関東 / 東京（JP13）。
    static let kantoFM: [Station] = [
        Station(id: "HOUSOU-DAIGAKU", name: "放送大学",     frequency: 77.1, areaID: "JP13", tagline: "FM · 生涯学習"),
        Station(id: "BAYFM78", name: "bayfm78",            frequency: 78.0, areaID: "JP13", tagline: "千葉 · CHIBA"),
        Station(id: "NACK5",   name: "NACK5",              frequency: 79.5, areaID: "JP13", tagline: "埼玉 · Music Bird"),
        Station(id: "FMT",     name: "TOKYO FM",           frequency: 80.0, areaID: "JP13", tagline: "JFN · 東京"),
        Station(id: "FMJ",     name: "J-WAVE",             frequency: 81.3, areaID: "JP13", tagline: "81.3 · Tokyo"),
        Station(id: "JOAK-FM", name: "NHK FM 東京",         frequency: 82.5, areaID: "JP13", tagline: "NHK-FM"),
        Station(id: "YFM",     name: "FM ヨコハマ",          frequency: 84.7, areaID: "JP13", tagline: "横浜 · 84.7"),
        Station(id: "INT",     name: "InterFM897",         frequency: 89.7, areaID: "JP13", tagline: "東京 · Bilingual"),
        Station(id: "TBS",     name: "TBS ラジオ",           frequency: 90.5, areaID: "JP13", tagline: "ワイドFM · 954kHz"),
        Station(id: "QRR",     name: "文化放送",             frequency: 91.6, areaID: "JP13", tagline: "ワイドFM · 1134kHz"),
        Station(id: "JORF",    name: "ラジオ日本",           frequency: 92.4, areaID: "JP13", tagline: "横浜 · ワイドFM"),
        Station(id: "LFR",     name: "ニッポン放送",          frequency: 93.0, areaID: "JP13", tagline: "ワイドFM · 1242kHz"),
    ]

    /// 関西 / 大阪（JP27）。
    static let kansaiFM: [Station] = [
        Station(id: "CCL",     name: "FM COCOLO",  frequency: 76.5, areaID: "JP27", tagline: "多言語 · 関西"),
        Station(id: "802",     name: "FM802",      frequency: 80.2, areaID: "JP27", tagline: "大阪 · 80.2"),
        Station(id: "FMO",     name: "FM大阪",      frequency: 85.1, areaID: "JP27", tagline: "OSAKA · 85.1"),
        Station(id: "JOBK-FM", name: "NHK FM 大阪", frequency: 88.1, areaID: "JP27", tagline: "NHK-FM"),
        Station(id: "MBS",     name: "MBS ラジオ",   frequency: 90.6, areaID: "JP27", tagline: "毎日放送 · ワイドFM"),
        Station(id: "OBC",     name: "ラジオ大阪",   frequency: 91.9, areaID: "JP27", tagline: "OBC · ワイドFM"),
        Station(id: "ABC",     name: "ABC ラジオ",   frequency: 93.3, areaID: "JP27", tagline: "朝日放送 · ワイドFM"),
    ]

    /// 中部 / 名古屋（JP23）。
    static let chubuFM: [Station] = [
        Station(id: "ZIP-FM",  name: "ZIP-FM",       frequency: 77.8, areaID: "JP23", tagline: "名古屋 · 77.8"),
        Station(id: "FMAICHI", name: "FM AICHI",     frequency: 80.7, areaID: "JP23", tagline: "愛知 · 80.7"),
        Station(id: "JOCK-FM", name: "NHK FM 名古屋", frequency: 82.5, areaID: "JP23", tagline: "NHK-FM"),
        Station(id: "SF",      name: "東海ラジオ",     frequency: 92.9, areaID: "JP23", tagline: "ワイドFM · 92.9"),
        Station(id: "CBC",     name: "CBC ラジオ",     frequency: 93.7, areaID: "JP23", tagline: "ワイドFM · 93.7"),
    ]

    /// 北海道 / 札幌（JP01）。
    static let hokkaidoFM: [Station] = [
        Station(id: "AIR-G'",    name: "AIR-G'",        frequency: 80.4, areaID: "JP01", tagline: "FM北海道 · 札幌"),
        Station(id: "NORTHWAVE", name: "FM NORTH WAVE", frequency: 82.5, areaID: "JP01", tagline: "北海道 · 82.5"),
        Station(id: "JOIK-FM",   name: "NHK FM 札幌",    frequency: 85.2, areaID: "JP01", tagline: "NHK-FM"),
        Station(id: "STV",       name: "STV ラジオ",      frequency: 90.4, areaID: "JP01", tagline: "ワイドFM · 札幌"),
        Station(id: "HBC",       name: "HBC ラジオ",      frequency: 91.5, areaID: "JP01", tagline: "北海道放送 · ワイドFM"),
    ]

    /// 九州 / 福岡（JP40）。
    static let kyushuFM: [Station] = [
        Station(id: "LOVEFM",    name: "LOVE FM",    frequency: 76.1, areaID: "JP40", tagline: "福岡 · 多言語"),
        Station(id: "CROSSFM",   name: "CROSS FM",   frequency: 78.7, areaID: "JP40", tagline: "福岡 · 78.7"),
        Station(id: "FMFUKUOKA", name: "FM FUKUOKA", frequency: 80.7, areaID: "JP40", tagline: "福岡 · 80.7"),
        Station(id: "JOLK-FM",   name: "NHK FM 福岡", frequency: 84.8, areaID: "JP40", tagline: "NHK-FM"),
        Station(id: "RKB",       name: "RKB ラジオ",   frequency: 90.2, areaID: "JP40", tagline: "毎日放送 · ワイドFM"),
        Station(id: "KBC",       name: "KBC ラジオ",   frequency: 90.6, areaID: "JP40", tagline: "九州朝日 · ワイドFM"),
    ]

    /// 沖縄 / 那覇（JP47）。
    static let okinawaFM: [Station] = [
        Station(id: "FM_OKINAWA", name: "FM沖縄",       frequency: 87.3, areaID: "JP47", tagline: "JFN · 沖縄"),
        Station(id: "JOAP-FM",    name: "NHK FM 沖縄",  frequency: 88.1, areaID: "JP47", tagline: "NHK-FM"),
        Station(id: "ROK",        name: "ラジオ沖縄",    frequency: 92.1, areaID: "JP47", tagline: "ワイドFM · 864kHz"),
        Station(id: "RBC",        name: "RBCiラジオ",   frequency: 92.5, areaID: "JP47", tagline: "琉球放送 · ワイドFM"),
    ]

    /// 兼容旧引用（默认取関東拨盘）。
    static var tokyoFM: [Station] { kantoFM }
}

// MARK: - 多语言支持（代码内本地化，默认英文）

/// 界面语言。默认英文，可在应用内切换。
enum AppLanguage: String, CaseIterable, Identifiable {
    case en, zh, ja
    var id: String { rawValue }
    var label: String {
        switch self {
        case .en: return "English"
        case .zh: return "中文"
        case .ja: return "日本語"
        }
    }

    /// 用于日期/星期格式化的区域标识。
    var localeID: String {
        switch self {
        case .en: return "en_US"
        case .zh: return "zh_CN"
        case .ja: return "ja_JP"
        }
    }
}

/// 当前语言的读写（持久化在 UserDefaults，键与界面的 @AppStorage 一致）。
enum L {
    static let key = "appLanguage"
    static var language: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .en }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// 本地化字符串表。`T.xxx` 按当前语言返回英/中/日文案。
enum T {
    private static func pick(_ en: String, _ zh: String, _ ja: String) -> String {
        switch L.language {
        case .en: return en
        case .zh: return zh
        case .ja: return ja
        }
    }

    static var title: String { pick("Japan FM Radio", "日本 FM 电台", "日本 FM ラジオ") }

    // 播放状态
    static var statusIdle: String { pick("Swipe to tune · Tap to play", "滑动选台 · 点击播放", "スワイプで選局 · タップで再生") }
    static var connecting: String { pick("Connecting…", "连接中…", "接続中…") }
    static var live: String { pick("● LIVE", "● 直播中", "● LIVE 放送中") }
    static var paused: String { pick("Paused", "已暂停", "一時停止") }
    static var playFailed: String { pick("Playback failed, please try again", "播放失败，请稍后重试", "再生に失敗しました") }
    // 播放键的读屏名字（图标本身说明不了要做什么）。
    static var play: String { pick("Play", "播放", "再生") }
    static var pause: String { pick("Pause", "暂停", "一時停止") }

    // 睡眠定时器
    static var sleep: String { pick("Sleep", "睡眠", "スリープ") }
    static var sleepOff: String { pick("Turn off timer", "关闭定时", "タイマー解除") }
    static func minutesStop(_ m: Int) -> String { pick("Stop in \(m) min", "\(m) 分钟后停止", "\(m) 分後に停止") }

    // 识曲
    static var identify: String { pick("Identify", "识曲", "曲名検索") }
    static var unknownTrack: String { pick("Unknown track", "未知曲目", "不明な曲") }
    static var identifying: String { pick("Listening…", "识别中…", "識別中…") }
    static var listening: String { pick("Listening to the broadcast…", "正在聆听广播…", "放送を聴いています…") }
    static var noMatchListening: String { pick("No match yet, still listening…", "暂时没有匹配，仍在聆听…", "まだ一致なし、聴取中…") }
    /// 一次性识别（录音里点「识别这一段」）跑完却没匹配上 —— 循环已经结束，不能再说「仍在聆听」。
    static var noMatchFound: String { pick("No match found", "没有匹配到曲目", "一致する曲が見つかりません") }
    static var identifyFailed: String { pick("Recognition failed — make sure the radio is playing aloud", "识别失败，请确保广播正在外放", "認識失敗、スピーカー再生をご確認ください") }
    /// 内源识别（直接读流）时的提示：不需要外放，所以文案与麦克风路径不同。
    static var listeningStream: String { pick("Listening to the stream…", "正在从流中识别…", "ストリームから識別中…") }
    static var identifyFailedStream: String { pick("Recognition failed on this stream", "无法识别该流的音频", "このストリームを認識できません") }
    static var micDenied: String { pick("Microphone access is required", "需要麦克风权限", "マイクの許可が必要です") }
    /// 自动实时识别（跟着播放一直识）。菜单里的开关文案。
    static var autoIdentify: String { pick("Auto-identify while playing", "播放时自动识曲", "再生中に自動で曲名検索") }
    /// 工具条槽位上的短标（9pt，放不下长词）。
    static var autoShort: String { pick("AUTO", "自动", "自動") }
    static var identifyOnce: String { pick("Identify once now", "立即识别一次", "今すぐ一度だけ検索") }
    /// 识曲接口自检（长按识曲键 → 菜单最后一项）。报告原样显示、可复制。
    static var identifyProbe: String { pick("Diagnose recognition", "识曲接口自检", "曲名検索の自己診断") }
    static var probing: String { pick("Diagnosing…", "自检中…", "診断中…") }

    // 节目表
    static var program: String { pick("Schedule", "节目表", "番組表") }
    static var loading: String { pick("Loading…", "加载中…", "読み込み中…") }
    static var loadFailed: String { pick("Failed to load schedule", "节目表加载失败", "番組表の取得に失敗しました") }
    static var retry: String { pick("Retry", "重试", "再試行") }
    static var close: String { pick("Close", "关闭", "閉じる") }
    static var noProgram: String { pick("No schedule available", "暂无节目表", "番組情報がありません") }
    static var onAir: String { pick("ON AIR", "直播中", "放送中") }
    static var jstNote: String { pick("Times in JST", "时间为日本时间", "日本時間") }
    static var today: String { pick("Today", "今天", "今日") }
    static var yesterday: String { pick("Yesterday", "昨天", "昨日") }
    static var tomorrow: String { pick("Tomorrow", "明天", "明日") }
    static var noProgramTitle: String { pick("(untitled)", "（无节目名）", "（番組名なし）") }
    // 番組表取不到时的自查报告（把真实响应原样带出来，便于对上字段名）。
    static var diagnose: String { pick("Diagnostics", "诊断", "診断") }
    static var copy: String { pick("Copy", "复制", "コピー") }

    // 收藏
    static var favorites: String { pick("Favorites", "收藏", "お気に入り") }
    static var noFavorites: String { pick("No favorite stations yet", "还没有收藏电台", "お気に入りの局がありません") }

    // 「全部」拨盘（所有电台放在同一条刻度上）
    static var allRegion: String { pick("All", "全部", "すべて") }
    static func stationCount(_ n: Int) -> String { pick("\(n) stations", "\(n) 个台", "\(n) 局") }

    // 收藏节目（按「台 + 节目名」记住一档节目，跨天仍认得出同一档）
    // 收藏 = 每次播出前自动提醒，所以这些文案都要把「通知」这层意思带出来。
    static var favoritePrograms: String { pick("Favorite shows", "收藏节目", "お気に入り番組") }
    static var noFavoritePrograms: String {
        pick("No favorite shows yet", "还没有收藏节目", "お気に入りの番組がありません")
    }
    static var favoriteProgram: String {
        pick("Favorite · remind me", "收藏并提醒", "お気に入り・通知")
    }
    static var unfavoriteProgram: String {
        pick("Remove from favorites (stops reminders)", "取消收藏（同时取消提醒）", "お気に入り解除（通知も解除）")
    }
    static var favoriteProgramsHint: String {
        pick("Favorites are reminded before every broadcast. Long-press to change the timing; tap to open that station's schedule.",
             "收藏的节目每次播出前都会提醒。长按可改提前时间，点一下打开该台节目表。",
             "お気に入りの番組は放送前に毎回通知します。長押しで通知タイミングを変更、タップで番組表を開きます。")
    }
    /// 番組表底部的说明：★ 那一颗现在同时管收藏与提醒。
    static var favoriteRemindNote: String {
        pick("★ Favorite a show and it reminds you before every broadcast (long-press to change the timing).",
             "★ 收藏一档节目，每次播出前都会提醒（长按可改提前时间）。",
             "★ お気に入りにすると毎回の放送前に通知します（長押しで通知タイミングを変更）。")
    }

    // 录制 / 录音库
    static var record: String { pick("Record", "录制", "録音") }
    static var recording: String { pick("Recording", "录制中", "録音中") }
    static var recordStop: String { pick("Stop", "停止", "停止") }
    static var recordings: String { pick("Recordings", "录音库", "録音一覧") }
    static var noRecordings: String { pick("No recordings yet", "还没有录音", "録音がありません") }
    static var recordStartFailed: String { pick("Couldn't start recording", "无法开始录制", "録音を開始できません") }
    static var recordSaved: String { pick("Saved to Recordings", "已保存到录音库", "録音一覧に保存しました") }
    static var export: String { pick("Export", "导出", "書き出し") }
    static var delete: String { pick("Delete", "删除", "削除") }
    static var sourceLive: String { pick("Live", "实时", "ライブ") }
    static var sourceTimefree: String { pick("Timefree", "存档", "タイムフリー") }

    // 录音播放界面（与直播界面同一套外观：台标 + 进度 + 识曲）
    static var openPlayer: String { pick("Open player", "打开播放界面", "プレーヤーを開く") }
    static var identifyHere: String { pick("Identify this part", "识别这一段", "この部分を検索") }
    static var listeningRecording: String {
        pick("Identifying from the recording…", "正在从录音中识别…", "録音から識別中…")
    }
    static var identifyFailedRecording: String {
        pick("Couldn't identify this part", "这一段无法识别", "この部分を認識できません")
    }
    static var skipBack: String { pick("Back 15 seconds", "后退 15 秒", "15秒戻る") }
    static var skipForward: String { pick("Forward 15 seconds", "前进 15 秒", "15秒進む") }

    // 预约录制
    static var reserve: String { pick("Record", "预约录制", "録音予約") }
    static var reserved: String { pick("Reserved", "已预约", "予約済み") }
    static var cancelReserve: String { pick("Cancel reservation", "取消预约", "予約を取消") }
    static var reservations: String { pick("Scheduled", "预约", "予約") }
    static var noReservations: String { pick("No scheduled recordings", "没有预约", "予約がありません") }
    static var statusPending: String { pick("Scheduled", "待录制", "予約中") }
    static var statusCompleted: String { pick("Recorded", "已录制", "録音済み") }
    static var statusFailed: String { pick("Failed", "失败", "失敗") }
    static var statusMissed: String { pick("Missed", "已错过", "録り逃し") }
    static var statusAiring: String { pick("On air · recording", "播出中 · 录制", "放送中 · 録音") }
    static var statusFetching: String { pick("Fetching…", "获取中…", "取得中…") }
    static var statusAwaiting: String { pick("Awaiting archive", "等待存档", "アーカイブ待ち") }
    static var retryFetch: String { pick("Fetch now", "立即获取", "今すぐ取得") }
    static var captureFailed: String {
        pick("Live capture got no audio", "实时录制没有拿到音频", "ライブ録音で音声を取得できませんでした")
    }
    static func fellBackToLive(_ reason: String) -> String {
        pick("Archive unavailable (\(reason)) — saved the live capture instead.",
             "存档取不到（\(reason)），已改用实时录到的版本。",
             "タイムフリーを取得できず（\(reason)）、ライブ録音を保存しました。")
    }
    static var liveOnlyNote: String {
        pick("This is a community FM stream with no archive — scheduled recording only works while the app is open at air time.",
             "该社区FM无存档，预约仅在播出时 App 处于开启状态才能录到。",
             "このコミュニティFMは番組表・アーカイブがないため、予約録音は放送時にアプリを開いている場合のみ可能です。")
    }

    // 收听提醒（跟着 ★ 收藏走：收藏一档节目 = 每次播出前通知我）
    static var remind: String { pick("Remind me", "收听提醒", "リマインド") }
    static var reminded: String { pick("Reminder set", "已设提醒", "リマインド設定済み") }
    static var cancelRemind: String { pick("Remove reminder", "取消提醒", "リマインドを解除") }
    static var reminders: String { pick("Reminders", "收听提醒", "リマインド") }
    static var noReminders: String { pick("No reminders", "没有提醒", "リマインドはありません") }
    /// 长按 ★ 出来的「提前多久提醒」菜单标题。
    static var remindLead: String { pick("Remind me", "提前提醒", "通知タイミング") }
    static var remindAtStart: String { pick("When it starts", "开始时", "開始時") }
    static func remindBefore(_ m: Int) -> String {
        pick("\(m) min before", "提前 \(m) 分钟", "\(m) 分前")
    }
    /// 提醒行上的「提前多久」标签。
    static func leadLabel(_ m: Int) -> String { m == 0 ? remindAtStart : remindBefore(m) }
    static var notifSoonTitle: String { pick("Starting soon", "节目即将开始", "まもなく放送開始") }
    static func notifSoonBody(_ p: String, _ station: String, _ lead: Int) -> String {
        let when = lead == 0
            ? pick("now", "现在开始", "まもなく開始")
            : pick("in \(lead) min", "\(lead) 分钟后开始", "\(lead) 分後に開始")
        return pick("“\(p)” on \(station) — \(when). Tap to listen.",
                    "\(station)《\(p)》\(when)，点这里收听。",
                    "\(station)「\(p)」\(when)。タップして聴く。")
    }
    /// 节目已开播/已结束，排不了提醒。
    static var remindTooLate: String {
        pick("This program has already started.", "该节目已经开始了。", "この番組はすでに始まっています。")
    }

    // 从节目表选节目预约（免得手调起止时间）
    static var pickFromSchedule: String {
        pick("Pick from schedule", "从节目表选择", "番組表から選ぶ")
    }
    static var pickFromScheduleHint: String {
        pick("Choose a program and its exact start/end times are used automatically.",
             "选中一档节目即自动套用它的起止时间，不必手动调。",
             "番組を選ぶと開始・終了時刻がそのまま使われます。")
    }
    static var changeStation: String { pick("Change station", "更换电台", "放送局を変更") }

    // 自定义时间段预约
    static var customReserve: String { pick("Custom time range", "自定义时间段", "時間を指定して予約") }
    static var customReserveHint: String {
        pick("Pick any start and end time. radiko stations are fetched from the one-week archive after air time; community FM can only be captured live while the app is open.",
             "自由选择起止时间。radiko 台在播出后从一周存档下载；社区FM 只能在 App 开启时实时录。",
             "開始・終了時刻を自由に指定できます。radiko は放送後にタイムフリーから取得、コミュニティFMは放送中にアプリを開いている場合のみ録音できます。")
    }
    static var station: String { pick("Station", "电台", "放送局") }
    static var area: String { pick("Area", "地区", "エリア") }
    static var startTime: String { pick("Start", "开始", "開始") }
    static var endTime: String { pick("End", "结束", "終了") }
    static var titleField: String { pick("Title", "标题", "タイトル") }
    static var titleFieldPlaceholder: String { pick("Optional", "可留空", "任意") }
    static var durationLabel: String { pick("Duration", "时长", "長さ") }
    static var add: String { pick("Add", "添加", "追加") }
    static var cancel: String { pick("Cancel", "取消", "キャンセル") }
    static var invalidRange: String {
        pick("End time must be after start time.", "结束时间必须晚于开始时间。", "終了時刻は開始時刻より後にしてください。")
    }
    static var tooOldForArchive: String {
        pick("radiko keeps only one week of archive — pick a later start time.",
             "radiko 存档仅保留一周，请选择更晚的开始时间。",
             "radiko のタイムフリーは 1 週間のみです。もっと後の時刻を選んでください。")
    }
    static var downloadNow: String { pick("Fetching…", "正在获取…", "取得中…") }

    // 本地通知
    static var notifReadyTitle: String { pick("Recording ready", "录音就绪", "録音の準備ができました") }
    static func notifReadyBody(_ p: String) -> String {
        pick("“\(p)” aired — open the app to save it.", "《\(p)》已播完，打开应用即可保存。", "「\(p)」の放送が終了しました。アプリを開くと保存されます。")
    }
    static var notifLiveTitle: String { pick("Recording starting", "录制即将开始", "まもなく録音開始") }
    static func notifLiveBody(_ p: String) -> String {
        pick("“\(p)” is about to air — open the app to record it.", "《\(p)》即将开始，打开应用进行录制。", "まもなく「\(p)」が始まります。アプリを開いて録音してください。")
    }

    // 语言
    static var language: String { pick("Language", "语言", "言語") }

    // 错误
    static var errServer: String { pick("Cannot reach radiko", "无法连接 radiko 服务器", "radiko に接続できません") }
    static func errAuth1(_ c: Int) -> String { pick("Auth step 1 failed (HTTP \(c))", "鉴权第一步失败（HTTP \(c)）", "認証1失敗（HTTP \(c)）") }
    static func errAuth2(_ c: Int) -> String { pick("Auth step 2 failed (HTTP \(c))", "鉴权第二步失败（HTTP \(c)）", "認証2失敗（HTTP \(c)）") }
    static var errMissingHeaders: String { pick("Auth response is missing fields", "鉴权响应缺少必要字段", "認証応答に必要な項目がありません") }
    static func errArea(_ a: String) -> String { pick("Region restricted: \(a)", "该区域受限：\(a)", "地域制限：\(a)") }
}

// MARK: - ListenRadio 全国コミュニティFM（直连 HLS，无需 radiko 鉴权）
//
// 数据源：listenradio.jp channellist（AreaId / ChannelId）。
// 流地址规律（已实测 30022 / 30048）：
//   https://mtist.as.smartstream.ne.jp/{ChannelId}/livestream/playlist.m3u8
// 台标：https://listenradio.jp/img/rslogo/{ChannelId}r.png
//
// frequency 是**真实广播频率**：channellist 不提供，逐台按 ja.wikipedia「コミュニティ放送局一覧」
// 核对（2026-08）。这里原先放的是拨盘上的均匀「档位」，导致刻度尺读数与电台实际频率完全不符
// （例如 REDS WAVE 实为 87.3，却被排在 85.5）—— 别再那样做。
//
// 每个地区按频率升序排列，好让「滑卡片」与「拖刻度」方向一致。同频台（帯広 FM WING 与
// 稚内 FMわっぴー 都是 76.1）在刻度上会重叠 —— 不同城市复用同一频率是日本社区FM的常态，
// 拖到该刻度时由拨盘依次轮换选中（见 FrequencyDialView）。
extension Station {

    /// 直连台的紧凑构造：流地址与台标都能由 ChannelId 推出，不必逐条重复长 URL。
    private static func lr(_ channel: Int, _ name: String, _ frequency: Double,
                           _ areaID: String, _ place: String) -> Station {
        Station(id: "LR\(channel)", name: name, frequency: frequency, areaID: areaID,
                tagline: place,
                directStreamURL: "https://mtist.as.smartstream.ne.jp/\(channel)/livestream/playlist.m3u8",
                logoOverride: "https://listenradio.jp/img/rslogo/\(channel)r.png")
    }

    static let listenRadioRegions: [Region] = [
        Region(id: "LR1", name: "北海道", subtitle: "コミュニティFM", stations: [
            lr(30011, "FMわっぴー", 76.1, "LR1", "北海道稚内市"),
            lr(30029, "FMくしろ", 76.1, "LR1", "北海道釧路市"),
            lr(30004, "FMはまなす", 76.1, "LR1", "北海道岩見沢市"),
            lr(30038, "FM WING", 76.1, "LR1", "北海道帯広市"),
            lr(30005, "三角山放送局", 76.2, "LR1", "北海道札幌市西区"),
            lr(30045, "FMねむろ", 76.3, "LR1", "北海道根室市"),
            lr(30025, "FMおたる", 76.3, "LR1", "北海道小樽市"),
            lr(30090, "FMアップル", 76.5, "LR1", "北海道札幌市豊平区"),
            lr(30044, "RadioYAMASHO FMドラマシティ", 77.6, "LR1", "北海道札幌市厚別区"),
            lr(30087, "wi-radio", 77.6, "LR1", "北海道伊達市"),
            lr(30016, "FM JAGA", 77.8, "LR1", "北海道帯広市"),
            lr(30003, "FM G'Sky", 77.9, "LR1", "北海道滝川市"),
            lr(30034, "ラジオカロスサッポロ", 78.1, "LR1", "北海道札幌市中央区"),
            lr(30058, "FM ABASHIRI", 78.7, "LR1", "北海道網走市"),
            lr(30015, "FMメイプル きたひろボールパークラジオ", 79.9, "LR1", "北海道北広島市"),
            lr(30032, "さっぽろ村ラジオ", 81.3, "LR1", "北海道札幌市東区"),
        ]),
        Region(id: "LR2", name: "東北", subtitle: "コミュニティFM", stations: [
            lr(30007, "RADIO3", 76.2, "LR2", "宮城県仙台市青葉区"),
            lr(30009, "SEA WAVE FMいわき", 76.2, "LR2", "福島県いわき市"),
            lr(30030, "FMゆーとぴあ", 76.3, "LR2", "秋田県湯沢市"),
            lr(30037, "ラジオ石巻", 76.4, "LR2", "宮城県石巻市"),
            lr(30079, "BeFM", 76.5, "LR2", "青森県八戸市"),
            lr(30017, "ラヂオもりおか", 76.9, "LR2", "岩手県盛岡市"),
            lr(30076, "横手かまくらエフエム", 77.4, "LR2", "秋田県横手市"),
            lr(30094, "ラヂオ気仙沼", 77.5, "LR2", "宮城県気仙沼市"),
            lr(30019, "FM Mot.com", 77.7, "LR2", "福島県本宮市"),
            lr(30050, "カシオペアFM", 77.9, "LR2", "岩手県二戸市"),
            lr(30056, "BAY WAVE", 78.1, "LR2", "宮城県塩竈市"),
            lr(30089, "鹿角きりたんぽFM", 79.1, "LR2", "秋田県鹿角市"),
            lr(30020, "KOCOラジ", 79.1, "LR2", "福島県郡山市"),
            lr(30014, "エフエム椿台", 79.6, "LR2", "秋田県秋田市"),
            lr(30018, "fmいずみ", 79.7, "LR2", "宮城県仙台市泉区"),
            lr(30092, "なとらじ801", 80.1, "LR2", "宮城県名取市"),
            lr(30097, "みやこハーバーラジオ", 82.6, "LR2", "岩手県宮古市"),
        ]),
        Region(id: "LR3", name: "関東", subtitle: "コミュニティFM", stations: [
            lr(30048, "FMわたらせ", 76.1, "LR3", "埼玉県加須市"),
            lr(30022, "FMぱるるん", 76.2, "LR3", "茨城県水戸市"),
            lr(30002, "フラワーラジオ", 76.7, "LR3", "埼玉県鴻巣市"),
            lr(30026, "775ライブリーFM", 77.5, "LR3", "埼玉県朝霞市"),
            lr(30081, "Tokyo Star Radio（八王子FM）", 77.5, "LR3", "東京都八王子市"),
            lr(30023, "FMひたち", 82.2, "LR3", "茨城県日立市"),
            lr(30027, "エフエム世田谷", 83.4, "LR3", "東京都世田谷区"),
            lr(30039, "調布FM", 83.8, "LR3", "東京都調布市"),
            lr(30057, "ＦＭカオン", 84.2, "LR3", "神奈川県海老名市"),
            lr(30033, "FMたちかわ", 84.4, "LR3", "東京都立川市"),
            lr(30043, "まえばしラジオ", 84.5, "LR3", "群馬県前橋市"),
            lr(30021, "FMうしくうれしく放送", 85.4, "LR3", "茨城県牛久市"),
            lr(30035, "FM Kawaguchi", 85.6, "LR3", "埼玉県川口市"),
            lr(30096, "ハローハッピー・こしがやエフエム", 86.8, "LR3", "埼玉県越谷市"),
            lr(30008, "REDS WAVE", 87.3, "LR3", "埼玉県さいたま市"),
            lr(30047, "FMふっかちゃん", 88.5, "LR3", "埼玉県深谷市"),
            lr(30036, "レインボータウンFM", 88.5, "LR3", "東京都江東区"),
        ]),
        Region(id: "LR4", name: "東海", subtitle: "コミュニティFM", stations: [
            lr(30040, "エフエムEGAO", 76.3, "LR4", "愛知県岡崎市"),
        ]),
        Region(id: "LR5", name: "北信越", subtitle: "コミュニティFM", stations: [
            lr(30006, "ラジオ・ミュー", 76.1, "LR5", "富山県黒部市"),
            lr(30001, "FM N1", 76.3, "LR5", "石川県野々市市"),
            lr(30012, "敦賀FM", 77.9, "LR5", "福井県敦賀市"),
        ]),
        Region(id: "LR6", name: "近畿", subtitle: "コミュニティFM", stations: [
            lr(30013, "FM ジャングル", 76.4, "LR6", "兵庫県豊岡市"),
            lr(30067, "エフエム花", 77.5, "LR6", "滋賀県甲賀市"),
            lr(30073, "FMたんご", 79.4, "LR6", "京都府京丹後市"),
            lr(30082, "京都三条ラジオカフェ", 79.7, "LR6", "京都市中京区"),
            lr(30061, "ラジオスイート", 81.5, "LR6", "滋賀県東近江市"),
            lr(30063, "FMおとくに", 86.2, "LR6", "京都府乙訓地域"),
            lr(30078, "BAN-BANラジオ", 86.9, "LR6", "兵庫県加古川市"),
            lr(30071, "FM87.0 RADIO MIX KYOTO", 87.0, "LR6", "京都市北区"),
        ]),
        Region(id: "LR7", name: "中国・四国", subtitle: "コミュニティFM", stations: [
            lr(30010, "FMびざん", 79.1, "LR7", "徳島県徳島市"),
            lr(30053, "DARAZ FM", 79.8, "LR7", "鳥取県米子市"),
            lr(30024, "FM815（高松）", 81.5, "LR7", "香川県高松市"),
        ]),
        Region(id: "LR8", name: "九州・沖縄", subtitle: "コミュニティFM", stations: [
            lr(30054, "あまみエフエム", 77.7, "LR8", "鹿児島県奄美市"),
            lr(30068, "fm那覇", 78.0, "LR8", "沖縄県那覇市"),
            lr(30072, "エフエムたつごう", 78.9, "LR8", "鹿児島県大島郡龍郷町"),
            lr(30091, "FMよなばる", 79.4, "LR8", "沖縄県島尻郡与那原町"),
            lr(30093, "FMぎのわん", 79.7, "LR8", "沖縄県宜野湾市"),
            lr(30098, "ぎのわんシティFM", 81.8, "LR8", "沖縄県宜野湾市"),
            lr(30083, "FMとよみ", 83.2, "LR8", "沖縄県豊見城市"),
            lr(30066, "オキラジ", 85.4, "LR8", "沖縄県沖縄市"),
            lr(30085, "チョクラジ", 86.1, "LR8", "福岡県直方市"),
            lr(30095, "FMやんばる", 87.7, "LR8", "沖縄県名護市"),
            lr(30052, "AIR STATION HIBIKI", 88.2, "LR8", "福岡県北九州市若松区"),
            lr(30088, "FMのべおか", 88.6, "LR8", "宮崎県延岡市"),
        ]),
    ]
}
