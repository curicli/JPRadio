> [English](README.md) · **中文**

# JPRadio / 日本ラジオ

用 FM 拨盘的手感收听日本电台——**radiko**（auth1/auth2 + GPS 伪造绕过地域限制，含
タイムフリー 存档回放）与 **ListenRadio**（全国コミュニティFM，直连 HLS）。左右滑动或拖动
拨盘，拨盘按**真实广播频率**定位。支持番組表、电台/节目收藏、睡眠定时，以及播放中自动识曲，
英/中/日三语。

两个前端共用同一份台表：

- **iOS app**——纯 SwiftUI，部署目标 iOS 17。另有节目提醒和带预约录制的完整录音库。
- **web 版**（`web/`）——本机 Node 反向代理 + 同源静态页面，电脑上任意浏览器都能听。
  零第三方依赖，只要一个 Node 进程。

## 截图

<p>
  <img src="docs/screenshots/ios-tuner.png" alt="拨盘 / 选台" width="30%">
  <img src="docs/screenshots/ios-schedule.png" alt="番組表" width="30%">
  <img src="docs/screenshots/ios-recognize.png" alt="识曲" width="30%">
</p>

> 把你的三张 iOS 截图放进 `docs/screenshots/`，命名为 `ios-tuner.png`、`ios-schedule.png`、
> `ios-recognize.png`（见 [docs/screenshots/README.md](docs/screenshots/README.md)）。

## iOS app

**收听**
- 116 个台、14 条拨盘：radiko 6 区（東京 JP13 / 大阪 JP27 / 名古屋 JP23 / 札幌 JP01 /
  福岡 JP40 / 沖縄 JP47，39 台）+ ListenRadio 全国コミュニティFM 8 区（77 台）。另有两条
  合成拨盘：**★ 收藏** 与**全部**（116 台挤一条刻度）。
- **境外可听**：复刻 [rajiko](https://github.com/jackyzy823/rajiko) 的 radiko
  `auth1`/`auth2` 流程 + GPS 坐标伪造。ListenRadio 是独立服务，直连 HLS，不需要鉴权。
- 睡眠定时器、AirPlay、锁屏与控制中心的 Now Playing（含台标/封面）。
- 三语界面（English / 中文 / 日本語，默认英文），顶部 🌐 随时切换。

**番組表**——radiko 官方 XML 与 ListenRadio 自家 JSON，前后 ±7 天，打开即滚到正在播的那档。
放送日按日本习惯从 05:00 起算，时刻一律 JST。

**收藏与提醒**——★ 收藏**电台**（拨盘最前面多一条「★」区），或 🔖 收藏**节目**（汇总在顶部，
点一条直接翻到那一档）。节目收藏的键是「台号 + 节目名」，每周复播的明天也认得出来，并自动
排本地通知，点通知开播即跳台。

**录制与回放**——手动录直播流；radiko 还可**预约**（用 タイムフリー 在播完后下载整档，比「到点
唤醒 App 抓直播」可靠得多，见「已知限制」）。录音库带播放器：进度拖动、±15 秒、后台播放、
锁屏控制。

**识曲**——ShazamKit 本机生成指纹，查询走 Shazam 自家 `amp.shazam.com`，因此**不需要付费的
catalog 能力**。直播与录音回放都能识；识出后曲名/歌手/封面盖到卡片上。

## Web 版

电脑上任意浏览器都能听——同样的台、同样的界面，还多了录制与预约录制（常驻的 Node 进程让
这两件都成为可能）。手机上是一台收音机；屏幕宽了就把两侧空白摊开成有用的东西：≥980px 多一栏
电台列表，≥1200px 再多一栏**常驻番組表**（三栏等高、各自滚动）。完整说明见
[web/README.md](web/README.md)。

```bash
node web/server.mjs                        # → http://127.0.0.1:8787
node web/server.mjs --host 0.0.0.0         # 同网段的手机/平板也能连
node web/server.mjs --port 9000 --rec-dir /Volumes/ext/rec
```

需要 Node 18+（用到内置 `fetch`）。Safari 原生放 HLS；其他浏览器用页面从 CDN 引的 hls.js。

**配置**。几乎没什么要配的——形状就是「本机反代 + 静态前端」，需要的东西都从仓库里读：

- **radiko 境外绕过 key**：启动时从 `ios/JPRadio/Radiko/RadikoProfile.swift` 里抠出来
  （那 167KB key 全仓库只存一处）。抠不到安卓 key 就退回公开的 `pc_html5` key——那把 key
  只在日本境内/日本 IP 有效。启动横幅与 `/api/health` 会写明当前是哪种模式。
- **台表**：`web/public/stations.json`，由 `ios/JPRadio/Models/Station.swift` 导出。改过
  Swift 台表就跑 `zsh web/sync-stations.sh` 重新导出。
- **命令行参数**：`--host`（默认 `127.0.0.1`）、`--port`（默认 `8787`）、`--rec-dir`
  （默认 `web/recordings/`）。

⚠️ **没有任何鉴权。** `--host 0.0.0.0` 会把它暴露到局域网：同网段任何人都能用你的 IP 听，
也点得到会往你磁盘写文件的录制/删除接口。只在自己信任的网络里开，**别做端口转发挂到公网上**。

为什么必须有个服务端（纯静态页做不到）：radiko / ListenRadio 都不给 CORS 头；HLS 的 playlist
请求要带 `X-Radiko-AuthToken` 而分片请求反而不能带；ListenRadio 的 CDN 按 Referer/Origin
防盗链；境外绕过还要上报伪造 GPS 头——这些都只能在服务端做。

## 打未签名 ipa（不经 xcodebuild）

```bash
zsh tools/make_unsigned_ipa.sh
```

产出根目录的 `JPRadio-unsigned.ipa`，装机前需自行用 Sideloadly / AltStore 签名。

## 目录结构

```
ios/                            SwiftUI app（打开 ios/JPRadio.xcodeproj）
  JPRadio/
    JPRadioApp.swift            @main；各 Store、通知路由、后台刷新
    Models/                     Station.swift（数据 + 三语字符串）、Theme.swift
    Radiko/                     RadikoProfile / RadikoAuth / RadikoStream（鉴权、GPS、流地址）
    ListenRadio/                コミュニティFM 的番組表 JSON
    Player/                     RadioPlayer、ShazamWebMatcher、ColorExtractor、FavoritesStore
    Recording/                  RadioRecorder、RecordingStore、ReservationStore、ReminderStore…
    Views/                      TunerView、FrequencyDialView、ProgramSheet、RecordingsSheet…
  JPRadio.xcodeproj/
web/                            浏览器版（Node 反代 + 静态前端）
  server.mjs                    唯一的服务端进程；路由 + 反向代理
  lib/                          radiko 鉴权、m3u8 改写、番組表、录制、识曲…
  public/                       静态前端（index.html / style.css / app.js / dial.js…）
  test/                         离线自检
docs/screenshots/               README 缩略图
tools/                          离线自测与打包脚本（不会被编进 app）
channellist.json                ListenRadio 台表的原始抓取结果，Station.swift 里 77 条字面量的出处
```

iOS 工程按相对路径引用源码，所以 `JPRadio/` 与 `JPRadio.xcodeproj/` 是**一起**挪进 `ios/`
的——不用改工程文件。

## 已知限制

- **「到点自动录直播」在 iOS 上做不到。** 系统不保证在设定时刻唤醒一个已被杀掉的 App，
  所以预约录制的实现是「等节目播完，用 タイムフリー 把整档下载下来」；实时抓流只在 App 恰好
  活着时作为补充。ListenRadio 没有 タイムフリー，因此**只能手动录**。（web 版是常驻进程，
  没有这个限制。）

## 致谢

- [jackyzy823/rajiko](https://github.com/jackyzy823/rajiko) —— radiko 鉴权与地域绕过。
- [shazamio](https://github.com/dotX12/ShazamIO) / [SongRec](https://github.com/marin-m/SongRec)
  —— Shazam 查询协议与指纹格式的说明。
