// 界面文案：英/中/日三语，与 iOS 端 `T`（ios/JPRadio/Models/Station.swift）逐条对应。
//
// 只搬 web 版真的会用到的那些条目 —— 节目提醒（本地通知）在浏览器里做不到（见 README），
// 硬搬过来只会留下点不动的按钮。识曲、录制、预约录制、节目收藏都搬了。
// 语言存 localStorage，键名与 app 的 `appLanguage` 一致。

const STRINGS = {
  title: ['Japan FM Radio', '日本 FM 电台', '日本 FM ラジオ'],
  statusIdle: ['Drag the dial · Tap to play', '滑动选台 · 点击播放', 'スワイプで選局 · タップで再生'],
  connecting: ['Connecting…', '连接中…', '接続中…'],
  live: ['● LIVE', '● 直播中', '● LIVE 放送中'],
  paused: ['Paused', '已暂停', '一時停止'],
  playFailed: ['Playback failed, please try again', '播放失败，请稍后重试', '再生に失敗しました'],
  play: ['Play', '播放', '再生'],
  pause: ['Pause', '暂停', '一時停止'],
  // 顶栏与两侧的图标钮没有文字，全靠 title / aria-label 说清楚自己是什么。
  prev: ['Previous station', '上一个台', '前の局'],
  next: ['Next station', '下一个台', '次の局'],
  language: ['Language', '语言', '言語'],

  sleep: ['Sleep', '睡眠', 'スリープ'],
  sleepOff: ['Sleep: off', '睡眠：关', 'スリープ：解除'],
  minutesStop: [(m) => `Stop in ${m} min`, (m) => `${m} 分钟后停止`, (m) => `${m} 分後に停止`],

  program: ['Schedule', '节目表', '番組表'],
  loading: ['Loading…', '加载中…', '読み込み中…'],
  loadFailed: ['Failed to load schedule', '节目表加载失败', '番組表の取得に失敗しました'],
  retry: ['Retry', '重试', '再試行'],
  noProgram: ['No schedule available', '暂无节目表', '番組情報がありません'],
  onAir: ['ON AIR', '直播中', '放送中'],
  jstNote: ['Times in JST', '时间为日本时间', '日本時間'],
  today: ['Today', '今天', '今日'],
  yesterday: ['Yesterday', '昨天', '昨日'],
  tomorrow: ['Tomorrow', '明天', '明日'],
  noProgramTitle: ['(untitled)', '（无节目名）', '（番組名なし）'],

  favorites: ['Favorites', '收藏', 'お気に入り'],
  noFavorites: ['No favorite stations yet', '还没有收藏电台', 'お気に入りの局がありません'],
  allRegion: ['All', '全部', 'すべて'],
  stationCount: [(n) => `${n} stations`, (n) => `${n} 个台`, (n) => `${n} 局`],
  favorite: ['Favorite', '收藏', 'お気に入り'],

  // タイムフリー（radiko 一周存档）。ListenRadio 没有这个功能。
  timefree: ['Timefree', '存档回放', 'タイムフリー'],
  timefreeOnlyRadiko: ['Timefree is radiko-only', 'ListenRadio 没有存档回放', 'タイムフリーは radiko のみ'],
  timefreeFuture: ['Not archived yet', '这档节目还没播完', 'まだ放送が終わっていません'],
  playingArchive: [(t) => `Archive · ${t}`, (t) => `存档 · ${t}`, (t) => `タイムフリー · ${t}`],
  backToLive: ['Back to live', '回到直播', 'ライブに戻る'],

  // 识曲。文案与 iOS 端 SongBanner 对应；「歇 30/8 秒」那套节奏在 recognize.js 里。
  identify: ['Identify song', '识曲', '曲名検索'],
  identifying: ['Listening…', '识别中…', '識別中…'],
  noMatch: ['No match', '没有匹配到', '一致する曲がありません'],
  identifyFailed: ['Recognition failed', '识曲失败', '識別に失敗しました'],
  identifyGaveUp: [
    'Stopped auto-identify after 3 failures',
    '连续失败 3 次，已停止自动识曲',
    '3 回続けて失敗したため自動識別を停止しました',
  ],
  identifyNoStation: ['Pick a station first', '先选一个电台', '先に局を選んでください'],
  identifyTooShort: [
    (n) => `Snippet too short (${n} bytes)`,
    (n) => `抓到的音频太短（${n} 字节）`,
    (n) => `音声が短すぎます（${n} バイト）`,
  ],
  autoIdentifyOn: [
    'Auto-identify: on (downloads ~16 s of audio each round)',
    '自动识曲：开（每轮会多下约 16 秒音频）',
    '自動識別：オン（毎回約 16 秒ぶん追加で通信します）',
  ],
  autoIdentifyOff: ['Auto-identify: off', '自动识曲：关', '自動識別：オフ'],
  appleMusic: ['Open in Apple Music', '在 Apple Music 打开', 'Apple Music で開く'],
  close: ['Close', '关闭', '閉じる'],

  // 节目收藏。存在浏览器 localStorage 里（与电台收藏同一处），服务端不需要知道。
  favProgram: ['Follow show', '收藏节目', '番組をお気に入り'],
  unfavProgram: ['Unfollow show', '取消收藏节目', 'お気に入りから外す'],
  favPrograms: ['Shows', '节目收藏', 'お気に入り番組'],
  noFavPrograms: ['No followed shows yet', '还没有收藏节目', 'お気に入りの番組がありません'],

  // 录制。录在服务端（那个 Node 进程），不是浏览器 —— 所以关掉页面也还在录。
  library: ['Recordings', '录音库', '録音'],
  record: ['Record', '录制', '録音'],
  recordStart: ['Record this station', '录制这个台', 'この局を録音'],
  recordStop: ['Stop recording', '停止录制', '録音を停止'],
  recording: [(t) => `REC ${t}`, (t) => `录制中 ${t}`, (t) => `録音中 ${t}`],
  recordStarted: ['Recording (server-side; safe to close this page)', '开始录制（录在服务端，可以关页面）', '録音開始（サーバー側で録音、ページを閉じても継続）'],
  recordSaved: [(t) => `Saved · ${t}`, (t) => `已保存 · ${t}`, (t) => `保存しました · ${t}`],
  recordFailed: ['Recording failed', '录制失败', '録音に失敗しました'],
  recordNothing: ['Nothing recorded', '一片都没录到', '何も録音できませんでした'],
  noRecordings: ['No recordings yet', '还没有录音', '録音がありません'],
  downloadArchive: ['Save archive', '下载存档', 'タイムフリーを保存'],
  downloadingArchive: [
    (a, b) => `Downloading ${a}/${b}`,
    (a, b) => `下载中 ${a}/${b}`,
    (a, b) => `ダウンロード中 ${a}/${b}`,
  ],
  download: ['Download', '下载', 'ダウンロード'],
  delete: ['Delete', '删除', '削除'],
  deleteBusy: ['Still recording — stop it first', '还在录，先停止', '録音中です。先に停止してください'],
  confirmDelete: [(t) => `Delete “${t}”?`, (t) => `删除《${t}》？`, (t) => `「${t}」を削除しますか？`],
  sourceLive: ['Live', '实时录', 'ライブ録音'],
  sourceTimefree: ['Archive', '存档', 'タイムフリー'],
  playingFile: [(t) => `Recording · ${t}`, (t) => `录音 · ${t}`, (t) => `録音 · ${t}`],

  // 预约录制。radiko 台等播完下存档，直连台只能实时录（详见 README）。
  reservations: ['Scheduled', '预约', '予約'],
  reserve: ['Schedule recording', '预约录制', '録音を予約'],
  reserved: ['Scheduled', '已预约', '予約済み'],
  cancelReserve: ['Cancel schedule', '取消预约', '予約を取消'],
  noReservations: ['No scheduled recordings', '没有预约', '予約はありません'],
  reserveDirectNote: [
    'This station has no archive — it can only be recorded while the server is running.',
    '这个台没有存档，只能在服务开着的时候实时录。',
    'この局は存档がないため、サーバー稼働中のみ録音できます。',
  ],
  reserveArchiveNote: [
    'radiko: downloaded from the archive after the show ends.',
    'radiko：等节目播完后从存档下载。',
    'radiko：放送終了後にタイムフリーから取得します。',
  ],
  statusPending: ['Waiting', '等待中', '待機中'],
  statusRecording: ['Recording', '录制中', '録音中'],
  statusFetching: ['Fetching archive', '下载存档中', 'タイムフリー取得中'],
  statusCompleted: ['Done', '已完成', '完了'],
  statusFailed: ['Failed', '失败', '失敗'],
  statusMissed: ['Missed', '错过了', '録り逃し'],

  webHint: [
    'Local proxy build. Recording runs on the server. Reminders are iOS-only.',
    '本机反代版。录制跑在服务端；节目提醒是 iOS 版独有的功能。',
    'ローカルプロキシ版。録音はサーバー側で動作。番組通知は iOS 版のみ。',
  ],
}

const LOCALES = ['en-US', 'zh-CN', 'ja-JP']
const LANGS = ['en', 'zh', 'ja']

const L = {
  key: 'appLanguage',
  get lang() {
    const v = localStorage.getItem(L.key)
    return LANGS.includes(v) ? v : 'en'
  },
  set lang(v) {
    localStorage.setItem(L.key, LANGS.includes(v) ? v : 'en')
  },
  get index() {
    return LANGS.indexOf(L.lang)
  },
  get locale() {
    return LOCALES[L.index]
  },
}

/// `T('connecting')` 取普通条目；`T('minutesStop', 30)` 取带参数的那几条。
function T(key, ...args) {
  const row = STRINGS[key]
  if (!row) return key
  const value = row[L.index] ?? row[0]
  return typeof value === 'function' ? value(...args) : value
}
