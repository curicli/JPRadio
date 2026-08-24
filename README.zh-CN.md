> [English](README.md) · **中文**

# JPRadio / 日本ラジオ

用 FM 拨盘的手感收听日本电台的 iOS app。左右滑动换台，拨盘按**真实广播频率**定位；
支持番組表、节目收藏与提醒、录制与回放，以及播放中自动识曲。

纯 SwiftUI，部署目标 iOS 17。

## 功能

**收听**
- 116 个台、14 条拨盘：radiko 6 区（東京 JP13 / 大阪 JP27 / 名古屋 JP23 / 札幌 JP01 /
  福岡 JP40 / 沖縄 JP47，39 台）+ ListenRadio 全国コミュニティFM 8 区（77 台）。
  另有两条合成拨盘：**★ 收藏**（收藏过电台才出现）与**全部**（116 台挤一条刻度）。
- **境外可听**：复刻 [rajiko](https://github.com/jackyzy823/rajiko) 的 radiko
  `auth1`/`auth2` 流程 + GPS 坐标伪造，绕过地域限制。ListenRadio 是独立服务，直连 HLS，
  不需要鉴权。
- 睡眠定时器、AirPlay、锁屏与控制中心的 Now Playing（含台标/封面）。
- 三语界面（English / 中文 / 日本語，默认英文），顶部 🌐 随时切换。

**番組表**
- radiko 走官方 XML（`v3/program/station/date/...`），ListenRadio 走它自己的 JSON。
- 可前后翻 ±7 天，打开即自动滚到正在播出的那一档。
- 放送日按日本习惯从 05:00 起算，时刻一律 JST。

**收藏与提醒**
- ★ 收藏**电台** → 拨盘最前面多一条「★」区。
- 🔖 收藏**节目** → 汇总在主界面顶部的书签按钮里，点一条直接开那台的番組表并翻到那一档
  （本周没排到就往后找）。键是「台号 + 节目名」，所以每周复播的节目明天也认得出来。
  收藏即自动排本地通知提醒，点通知直接跳台开播。

**录制与回放**
- 手动录制正在播的直播流；radiko 还可**预约**——利用 タイムフリー 在节目播完后下载整档存档
  （比「到点唤醒 App 抓直播」可靠得多，见下方「已知限制」）。
- 录音库带播放器：进度拖动、±15 秒、后台播放、锁屏控制。

**识曲**
- ShazamKit 在本机生成音频指纹，查询走 Shazam 自家的 `amp.shazam.com` 接口，
  因此**不需要付费开发者账号**的 ShazamKit catalog 能力。
- 直播与录音回放都能识；识出后曲名/歌手/专辑封面会盖到 Now Playing 卡片上，
  换台或换曲自动退回台名与台标。

## 打未签名 ipa（不经 xcodebuild）

```bash
zsh tools/make_unsigned_ipa.sh
```

产出根目录的 `JPRadio-unsigned.ipa`，装机前需自行用 Sideloadly / AltStore 签名。

## 目录结构

```
JPRadio/
  JPRadioApp.swift          @main；各 Store 的 @StateObject、通知路由、后台刷新
  Models/
    Station.swift           电台/地区数据表 + 代码内三语本地化（AppLanguage / L / T）
    Theme.swift             主题色常量 Color.brand
  Radiko/
    RadikoProfile.swift     Android app 伪装参数、full key、各区 GPS 坐标
    RadikoAuth.swift        auth1/auth2；token 按地区缓存
    RadikoStream.swift      流地址、番組表 XML、タイムフリー playlist
  ListenRadio/              コミュニティFM 的番組表 JSON
  Player/
    RadioPlayer.swift       AVPlayer 直播播放 + 睡眠定时器 + 识曲协调
    ShazamWebMatcher.swift  指纹剥壳与 amp.shazam.com 请求/解析
    ColorExtractor.swift    从台标取主色做背景
    FavoritesStore.swift    收藏电台
  Recording/
    RadioRecorder.swift     直播抓流 + タイムフリー 分片下载
    RecordingStore.swift    录音库
    ReservationStore.swift  预约与对账
    ReminderStore.swift     节目提醒（本地通知）
    FavoriteProgramStore.swift  收藏节目
  Views/                    TunerView（主界面）、FrequencyDialView（拨盘）、
                            ProgramSheet（番組表）、RecordingsSheet、RecordingPlayerView…
tools/                      离线自测与打包脚本（在 iOS target 之外，不会被编进 app）
channellist.json            ListenRadio 台表的原始抓取结果，Station.swift 里那 77 条字面量的出处
```

## 已知限制

- **「到点自动录直播」在 iOS 上做不到。** 系统不保证在设定时刻唤醒一个已被杀掉的 App。
  所以预约录制的实现是「等节目播完，用 タイムフリー 把整档下载下来」；实时抓流只在
  App 恰好活着时作为补充。ListenRadio 没有 タイムフリー，因此**只能手动录**。

## 致谢

- [jackyzy823/rajiko](https://github.com/jackyzy823/rajiko) —— radiko 鉴权与地域绕过。
- [shazamio](https://github.com/dotX12/ShazamIO) / [SongRec](https://github.com/marin-m/SongRec)
  —— Shazam 查询协议与指纹格式的说明。
