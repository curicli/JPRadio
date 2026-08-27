# JPRadio web 版

浏览器里听日本电台：**radiko**（6 个地区 39 台，含 auth1/auth2 鉴权、境外绕过、タイムフリー 存档回放）
与 **ListenRadio**（8 个地区 77 台社区 FM）。界面照搬 iOS 版：FM 刻度尺选台、卡片轮播、
番組表、收藏、睡眠定时、识曲（含自动识曲）、英/中/日三语。

台表与 iOS 版共用同一份出处（`ios/JPRadio/Models/Station.swift`），零第三方依赖，只要一个 Node。

## 跑起来

```sh
node web/server.mjs            # → http://127.0.0.1:8787
node web/server.mjs --port 9000 --host 0.0.0.0
```

Safari 原生就能放 HLS；Chrome / Firefox / Edge 靠页面里从 CDN 引的 hls.js。
需要 Node 18+（用到内置 `fetch`），实测 Node 26。

### 让同网段的手机 / 平板也能听

```sh
node web/server.mjs --host 0.0.0.0
```

监听在通配地址时启动横幅会把**每块网卡上真正能输入的地址**都列出来，在手机上开哪一个照抄即可：

```
JPRadio web  →  http://127.0.0.1:8787  (本机)
                http://192.168.1.21:8787  (en0)
                http://198.18.0.1:8787  (utun6)
```

`en0` / `en1` 那条是要的；**`utun*` 是 VPN 或代理软件挂上来的，别的设备连不通**
（所以横幅才把网卡名一起打出来）。

三件事先知道：

- **没有任何鉴权**。同网段的人拿到这个地址就能听，而且是**借你的 IP 去打 radiko**。
  只在自己家的网络里开，用完就关。
- 局域网地址是普通 `http://`，**不是 secure context**。前端没用到任何只在 https 下
  可用的接口（Web Audio、`OfflineAudioContext`、module worker、`localStorage`
  在 http 下都能用），所以识曲照样能跑；但如果以后要加 Service Worker 之类的东西，
  就得先解决证书。
- 手机连不上先看 macOS 的防火墙（系统设置 → 网络 → 防火墙）有没有拦 `node` 的传入连接 ——
  本机自己访问那个地址是通的，看不出这个问题。

## 为什么必须有个服务端（不能是纯静态页）

四条都是硬拦路，缺一条都绕不过去：

1. `api.radiko.jp` / `radiko.jp` / `listenradio.jp` **都不给 CORS 头** —— 浏览器里 `fetch`
   直接被拦，连番組表都取不到。
2. radiko 拉流时 **playlist 请求必须带 `X-Radiko-AuthToken`，分片请求反而不能带**（带了 403）。
   浏览器无法为 HLS 内部请求分别设头。
3. ListenRadio 的 smartstream CDN 按 **Referer / Origin 防盗链**，同样是 HLS 内部请求，同样设不了。
4. 境外绕过靠 auth2 时**上报伪造 GPS**，这只能由服务端发。

所以形状是「本机 Node 反代 + 同源静态前端」：浏览器只跟 `127.0.0.1` 打交道，
鉴权、加头、改写 m3u8 全在服务端做。

**顺带白捡的好处**：反代每次请求都重新加一个新鲜 token，所以 web 版不存在 iOS 上
「token 冻在 `AVURLAsset` 里、过期后静默断流」那个毛病（iOS 端为此加了播放头看门狗）。

## 路由

| 路径 | 作用 |
| --- | --- |
| `/stream/<台 id>.m3u8` | 入口 playlist：鉴权 → 解析上游地址 → 改写成本机地址 |
| `/p/<token>.m3u8` | 嵌套 playlist（master → chunklist），每次重新加新鲜 token；会话过期会自动重建 |
| `/s/<token>` | 分片透传（radiko 不加头、直连台加浏览器头、`Range` 原样转发） |
| `/timefree/<台 id>.m3u8?start=&end=` | タイムフリー：把多个 5 分钟窗口接成一条 VOD playlist |
| `/api/programs?station=&day=` | 番組表（day 取 −7..7），radiko XML 与 ListenRadio JSON 归一 |
| `/api/image?u=` | 台标反代（只放 radiko / listenradio 两个域名，为的是能取主色做背景） |
| `/api/snippet/<台 id>?seconds=&start=` | 抓一段音频给识曲用：接几个分片的字节，TS 会先拆成 ADTS（带 `start` 就是从存档里抓） |
| `/api/recognize` | `POST {uri, samplems}` → 转发到 `amp.shazam.com` 查曲库 |
| `/lib/shazam.mjs` | 把服务端那份指纹实现原样给浏览器 worker 用（只开放这一个文件） |
| `/api/rec` | 录音库快照：已完成录音 + 正在录/正在下的 job + 预约 + 落盘目录 |
| `/api/rec/live` | `POST {station,title}` 开一条实时录制；`/api/rec/stop {id}` 停并收尾 |
| `/api/rec/archive` | `POST {station,start,end,title}` 把一整档 タイムフリー 存成文件 |
| `/api/rec/delete` | `POST {id}` 删一条录音（正在录的会 409） |
| `/rec/<id>` | 回放录音文件（普通音频，非 HLS；支持 `Range`，`?dl=1` 触发下载） |
| `/api/reservations` | `POST` 新增预约；`/api/reservations/delete {id}` 取消 |
| `/api/health` | 鉴权模式、台数、内存里缓存的地址数 |

## 文件

```
web/
  server.mjs          反代 + 路由（唯一的服务端进程）
  lib/radiko.mjs      auth1 → partialkey → auth2、伪造 GPS、直播/存档地址解析
  lib/hls.mjs         m3u8 改写、上游地址 ⇄ 短 token 映射、分片列表收集
  lib/programs.mjs    番組表：radiko XML / ListenRadio JSON → 同一种形状；JST 与放送日换算
  lib/pool.mjs        有并发上限、保序的 map（タイムフリー 拼窗口用）
  lib/adts.mjs        MPEG-TS → 裸 ADTS AAC（ListenRadio 的分片是 TS，浏览器解不了）
  lib/recorder.mjs    录制：把一串 HLS 分片接成一个能直接播的本地文件（按内容判容器、TS 先拆 ADTS）
  lib/library.mjs     录音库：磁盘上的录音文件 + 一份元数据 JSON（元数据坏了绝不误删文件）
  lib/reservations.mjs 预约录制：radiko 等播完下 タイムフリー、直连台实时录；带重试与失败原因
  lib/shazam.mjs      Shazam 客户端指纹的纯 JS 实现（已与 ShazamKit 逐字节对照过）
  lib/shazamapi.mjs   amp.shazam.com 的请求形状与结果解析
  public/             静态前端（index.html / style.css / app.js / dial.js / i18n.js）
  public/library.js   录音库 / 预约 UI：实时录制、存档下载、回放、删除、新增预约
  public/recognize.js 识曲：抓音 → 解码重采样到 16k → worker 算指纹 → 查曲库 → 卡片
  public/sig-worker.js  算指纹的 module worker（12 秒音频约 1450 次 FFT，不能占主线程）
  public/stations.json  台表，由 Station.swift 导出，勿手改
  test/check.mjs      离线自检
  test/sigdiff.mjs    指纹对照台（跟 tools/ShazamSigRef.swift 配着用）
  sync-stations.sh    重新导出台表
```

## 上游的四个坑（真机上一个个踩出来的，改代码前先看这里）

1. **radiko 直播 master 里的变体地址不带 `.m3u8`** —— 按扩展名判断类型会把 chunklist 当成
   aac 分片直接透传，里面的分片地址于是没被改写，浏览器绕过反代直连 CDN（CORS 失败）。
   所以 `#EXT-X-STREAM-INF` 的下一个 URI 行**一律按 playlist 处理**（`lib/hls.mjs`）。
2. **chunklist 地址背后是一个会话，停止轮询约一分钟就 404**（实测 8 秒还活着、102 秒已死）。
   暂停一会儿再继续、或者切到后台标签页都会踩到，而播放器不会自己回到入口地址重来。
   所以 `/p/<token>` 取上游失败时会**悄悄重建一条会话**，并让同一个 token 指向新地址。
3. **タイムフリー 的每个窗口回的也是 master**，得再往下一层才是分片。直接收 master 的话
   一档 15 分钟的节目只会拼出 15 秒（那条变体地址被当成一个 5 秒分片）。
4. **Safari 取 MPEG-TS 分片会先发 `Range` 探针**，拿到 200 全量就 abort 再试，然后卡在
   `readyState 0` 不动 —— 表现是「一直连接中…」，控制台里连错误都没有。所以 `/s/` 把
   `Range` 原样转给上游、把 206 原样转回来。ListenRadio 的 TS 分片就是这么栽的。

radiko 的 full key **不在 web 目录里复制一份**：`lib/radiko.mjs` 启动时从
`ios/JPRadio/Radiko/RadikoProfile.swift` 里正则抠出来（那 167KB base64 在仓库里只该存在一处）。
抠不到就自动退回公开的 `pc_html5` key —— 那把 key 只在日本境内 / 日本 IP 有效，
启动横幅与 `/api/health` 会写明当前是哪种模式：

```
radiko 鉴权：android + GPS（境外可听）   ← 抠到了安卓 key
radiko 鉴权：pc_html5（仅日本境内/日本 IP）  ← 没抠到
```

## 台表同步

改过 `ios/JPRadio/Models/Station.swift` 就跑一次（编译 Station.swift 再打印，避免手抄漂移）：

```sh
zsh web/sync-stations.sh
```

## 识曲

按 ♪ 立刻识一次；**A** 是自动识曲开关（默认开，跟 iOS 版一样，播着就一直识：
命中后歇 30 秒，没命中歇 8 秒，连续失败 3 次就自己停下）。
**它每轮真的会多下约 16 秒音频，流量差不多翻倍** —— 蜂窝网络上介意的话把 A 关掉。

链路是：

```
/api/snippet/<台 id>          服务端抓 ~16 秒分片，TS 先拆成 ADTS
  → decodeAudioData            在 16 kHz 的 OfflineAudioContext 上解码（浏览器自己重采样）
  → 下混单声道 + 只留最后 12 秒
  → sig-worker.js              module worker 里跑 lib/shazam.mjs 算指纹
  → POST /api/recognize        服务端转发 amp.shazam.com
```

三个不明显但都必须这么做的点：

1. **抓音必须在服务端**，不能在浏览器里给 `<audio>` 挂 Web Audio。Safari 放原生 HLS 时
   `createMediaElementSource` 只给到静音（音频归媒体管道所有），而且挂上之后页面本身也没声了；
   iPhone 上又没有普通 MSE 可以退回 hls.js。iOS 端的 `LiveRecorder.snippet` 也是另开一路抓的。
2. **指纹只能是 ~12 秒**。整段 20 秒发上去，`amp.shazam.com` 回 200 但没有 `track` 键 ——
   跟「曲库里没有这首」一模一样，查不出所以然（真机上试过：20 秒无匹配，12 秒 / 5 秒都对）。
   所以浏览器裁到 12 秒，服务端还会把 `samplems > 13000` 直接 400 掉，不让它伪装成 no match。
3. **重采样别让它自己线性插值**。走的是「解码时就指定 16 kHz 上下文」这条路，用的是浏览器
   自带的高质量重采样器（等价于 iOS 的 `AVAudioConverter`）。万一某个浏览器不理这个采样率，
   退路是渲染两遍，且**先过三级 7 kHz biquad 低通再降采样** —— Chrome 的
   `AudioBufferSourceNode` 变速是线性插值，不先滤的话 10.5–15.75 kHz 会折回 250–5500 Hz，
   正好砸在指纹的四个频段上。

`lib/shazam.mjs` 服务端和浏览器共用同一份（走 `/lib/shazam.mjs` 那条只读白名单路由），
不复制到 `public/` —— 复制出来的那份迟早跟对照过的这份漂开。

一轮大概 20 秒：抓音本身要 18 秒左右（radiko 的分片是 5 秒一个，凑到 16 秒得多轮几次
chunklist），解码 0.4 秒、算指纹 1 秒、查曲库 1.6 秒。所以按下 ♪ 之后先出现「識別中…」。

## 自检

```sh
node web/test/check.mjs      # → 全部通过
```

不碰网络，只钉住那些坏了很难查的地方：partialkey 切片、playlist 改写（相对地址、
`URI="…"` 标签、`#EXTINF` 一个字都不许动、没扩展名的变体地址要按 playlist 算）、
token 映射的淘汰与 retarget、番組表 XML 的 CDATA 与实体、ListenRadio 的 12 位时刻、
放送日 05:00 起算、并发池保序、stations.json 的完整性，以及所有不联网的路由分支
（未知台、过期 token、目录穿越、图片域名白名单、识曲的 405/400/403）。
识曲那几段钉的是：指纹的峰数与几个已跟 ShazamKit 核对过的峰、签名头部的每个字段、
`amp.shazam.com` 的 URL 与请求头（locale 写成裸 `en` 就是 400，所以钉死成 `en-US`）、
结果解析的几种形状，以及 MPEG-TS 拆包 —— 后者用测试里自己拼的一段 TS（PAT/PMT/PES、
adaptation field、加扰包、多分片首尾相接）对拆出来的 ES 做逐字节比较。
它悄悄坏掉的表现是「30 个 ListenRadio 台全都识不出曲」，靠人是查不出来的。

### 指纹对照（要 macOS + ShazamKit，所以不在 `check.mjs` 里）

`lib/shazam.mjs` 的正确性没法靠自己证明 —— `amp.shazam.com` 对错的指纹只回
`200 no match`，看不出错在第几个常数上。所以拿 ShazamKit 当标尺：

```sh
SDK=/Applications/xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
swiftc -sdk "$SDK" -module-cache-path "$TMPDIR/mcache" -disable-sandbox \
       -O -parse-as-library -o "$TMPDIR/shazamsig" tools/ShazamSigRef.swift

node web/test/sigdiff.mjs wav  "$TMPDIR/probe.wav"                    # 造一段确定性音频
"$TMPDIR/shazamsig"            "$TMPDIR/probe.wav" "$TMPDIR/probe.sig"  # ShazamKit 算一份
node web/test/sigdiff.mjs bytes "$TMPDIR/probe.sig"                   # 只验字节格式
node web/test/sigdiff.mjs diff  "$TMPDIR/probe.wav" "$TMPDIR/probe.sig" # 连算法一起验
```

对出来的结果（12 秒探针）：

- **字节格式逐字节相同**：把 ShazamKit 那份解出来、用我们的写入器重打，2388 字节里
  只有偏移 4（crc32，随头部任一字段变）和偏移 12（magic2 的可选值）不同 ——
  TLV 嵌套、频段块 tag、delta 编码与 0xFF 转义、4 字节补齐、两处长度字段、CRC32 全对。
  5 秒那份（1140 字节）同样。
- **算法对得上**：ShazamKit 的 459 个峰里，落在我们帧号范围内的 432 个**一个不漏**，
  `(帧号, 频点)` 完全相等，幅度 89% 完全相等、其余差 1 个最低位。
- **唯一的实质差别**：我们的峰是**超集**（1304 对 459）。ShazamKit 之后还筛一轮
  （大致每个频段留最强的一百多个，但不是纯阈值也不是逐帧 top-N），我们不筛；
  SongRec 也不筛而它能查到曲子。**这一条已经用真曲库收尾了**：J-WAVE、
  三角山放送局（ListenRadio）、以及三小时前的 タイムフリー 都一次就查中了正确的曲名，
  所以多出来的峰只是多几个候选散列，不影响命中。

## 录制 / 预约

服务端是个常驻进程，所以 iOS 版的录制、预约、录音库这次**搬过来了**（浏览器自己做不到：
关掉页面就没人接分片了，预约更得有人一直守着）。三条策略照搬 iOS 端，都在真机上踩过：

- **实时录制**：`/api/rec/live` 开一条，服务端一直接分片写文件，`/api/rec/stop` 收尾。
  容器**按第一个分片的内容判**，不看扩展名 —— radiko 是裸 ADTS AAC，ListenRadio 是
  MPEG-TS（TS 得先拆成 ADTS 才存，否则文件在那儿却打不开）。时长按 `#EXTINF` 累加写进
  元数据，不问播放器要（裸 ADTS 没有时长索引）。
- **存档整档下载**：`/api/rec/archive` 把一档 タイムフリー 一次拼成文件。radiko 的存档是
  最完整的一份，所以能下存档就不实时录。
- **预约**（`/api/reservations`）分两种走法：**radiko 台不实时录，等节目播完直接下
  タイムフリー**（进程届时没开着也没关系，下次启动对账时补下来即可；代价是 radiko 关掉
  存档的那些节目录不到，会以 `failed` 加原因入账）；**ListenRadio 直连台没有存档，只能
  实时录**，进程没开着就是真的错过（状态 `missed`）。取不到会退回重试，5 分钟一次、6 次放弃。

录音落盘到 `web/recordings/`（`--rec-dir` 可改）。元数据是一份 JSON；**解析不出来时绝不删
文件** —— 宁可留孤儿文件，也不误删用户的录音。这个目录是 `.gitignore` 掉的（私人录音 +
预约状态，运行时生成，不进仓库）。

## 没有搬过来的功能

| iOS 版有 | web 版 | 原因 |
| --- | --- | --- |
| 节目提醒（本地通知） | 没有 | 浏览器要么依赖页面一直开着，要么得自己搭推送 |

录制、预约录制、录音库这次都搬过来了（见上一节）。其余（选台、直播、タイムフリー、
番組表、收藏、睡眠定时、识曲、三语、系统媒体控件）也都在。

## 安全

- **默认只监听 `127.0.0.1`，没有任何鉴权** —— 它是给自己用的本机播放器。
- 加 `--host 0.0.0.0` 会把它暴露到局域网：同网段任何人都能用你的 IP 听 radiko，
  也就是**用你的 IP 去打 radiko**；而且录制、删除录音、下存档这些**会往你磁盘写文件、
  也能删文件**的接口同样没有鉴权，同网段的人都点得到。只在自己信任的网络里这么做，
  用完就关（启动横幅这时会打一条 ⚠️ 提醒）。**别做端口转发把它挂到公网上** ——
  没有鉴权、没有限速，等于送出去一个日本 IP 的开放代理，外加一个能往你盘上写东西的口子。
- `/api/image` 只代理台标那几个域名，`/p` `/s` 只认本进程自己发出的 token，
  不是通用开放代理。
- 和 iOS 版一样：radiko 的境外绕过与 タイムフリー 是给自己听的，别拿去做公开服务。

## 排查

| 现象 | 大概是什么 |
| --- | --- |
| 手机打不开局域网地址 | 抄的是 `utun*`（VPN/代理）那条地址，或者 macOS 防火墙拦了 `node` 的传入连接；也确认手机和电脑在同一个网段 |
| 起播报 `auth2 失败` / `该地区受限（OUT）` | 没抠到安卓 key（看启动横幅是不是 `pc_html5`），或所在 IP 被判到日本境外 |
| 能出声几秒后停 | 上游抖动。前端有播放头看门狗（2 秒采样、卡 12 秒重建流），看状态是否闪 `连接中…` |
| 一直停在 `连接中…`，控制台里连错误都没有 | 分片响应吞掉了 `Range`（见上面第 4 条）。看 `/s/` 有没有把 206 原样转回来 |
| 暂停很久再继续，日志里出现 `chunklist 会话过期，已重建` | 正常：那是上游会话到期后自动重起的一条（见上面第 2 条） |
| `分片 token 已过期` | 页面开了很久没动，映射被淘汰了 —— 重新起播即可 |
| 番組表报错 | 错误里带着 HTTP 状态或解析到哪一步；ListenRadio 换过键名的话 `lib/programs.mjs` 的候选表要加一条 |
| 台标不显示、背景没颜色 | `/api/image` 被拦（改过 `IMAGE_HOSTS` 的话检查域名） |
| 识曲总是「没有匹配到」 | 先看是不是在放说话的节目。都在放歌还不中，就是指纹或裁剪出了问题（`/api/snippet/…?seconds=16` 直接下下来存成 `.aac` 能不能正常播） |
| 识曲报「解不开这段音频」 | ListenRadio 的 TS 没拆成 ADTS（`lib/adts.mjs`），或者上游换了编码 |
| 识曲报 `amp.shazam.com HTTP 4xx` | 请求形状被改动了（见 `lib/shazamapi.mjs`，`check.mjs` 里钉着一份） |
