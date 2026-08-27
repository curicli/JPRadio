// web 版的离线自检：不碰网络，只验「解析 / 换算 / 改写」这些一旦悄悄坏掉就很难查的逻辑。
//
//   node web/test/check.mjs      # 全部通过 → 退出码 0
//
// **为什么值得有**：radiko / ListenRadio 都不能在这台机器上真连（也不该在自检里连），
// 而真正咬人的从来不是网络，是 partialkey 切错一个字节、playlist 改写把 `#EXTINF` 也换了、
// 12 位时刻被当成 14 位读、放送日没按 05:00 起算 —— 这些全都能离线钉住。
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import * as radiko from '../lib/radiko.mjs'
import * as pg from '../lib/programs.mjs'
import { rewritePlaylist, uriKind, collectSegments, firstURI, isMediaPlaylist, URLVault } from '../lib/hls.mjs'
import { mapPool } from '../lib/pool.mjs'
import { collectPeaks, decodeSignature, encodeSignature, signature } from '../lib/shazam.mjs'
import { looksLikeTS, tsToADTS } from '../lib/adts.mjs'
import { SHAPE, parseTrack, tagRequest } from '../lib/shazamapi.mjs'
import { makeProbe } from './sigdiff.mjs'

const here = dirname(fileURLToPath(import.meta.url))

let failed = 0
const eq = (label, got, want) => {
  const ok = JSON.stringify(got) === JSON.stringify(want)
  if (!ok) {
    failed++
    console.error(`✗ ${label}\n    得到 ${JSON.stringify(got)}\n    期望 ${JSON.stringify(want)}`)
  }
  return ok
}
const ok = (label, cond) => eq(label, !!cond, true)

// MARK: - partialkey

{
  const key = Buffer.from('0123456789abcdef', 'utf8')
  eq('partialkey 正常切片', radiko.partialKey(key, 3, 4), Buffer.from('3456').toString('base64'))
  // 越界要退回整把 key（让错误停在服务端，而不是抛异常打断请求）。
  eq('partialkey 越界退回整把', radiko.partialKey(key, 14, 8), key.toString('base64'))
  eq('partialkey 长度 0 退回整把', radiko.partialKey(key, 0, 0), key.toString('base64'))
}

// MARK: - 伪造 GPS

{
  const [lat, lon, tag] = radiko.location('JP27').split(',')
  eq('GPS 末尾标记', tag, 'gps')
  ok('GPS 纬度在大阪附近（±0.03）', Math.abs(Number(lat) - 34.6863) < 0.03)
  ok('GPS 经度在大阪附近（±0.03）', Math.abs(Number(lon) - 135.52) < 0.03)
  // 未知地区退到东京，不该抛。抖动是 ±0.025 度，所以只能按数值比，
  // 不能拿字符串前缀断言（35.7145 也是合法结果，那样会随机挂）。
  const [fbLat, fbLon] = radiko.location('JP99').split(',').map(Number)
  ok('未知地区退回东京（纬度）', Math.abs(fbLat - radiko.GPS.JP13[0]) < 0.03)
  ok('未知地区退回东京（经度）', Math.abs(fbLon - radiko.GPS.JP13[1]) < 0.03)
  eq('userID 长度', radiko.randomUserID().length, 32)
}

// MARK: - playlist 改写

{
  const master = [
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-STREAM-INF:BANDWIDTH=48000',
    'chunklist_b48000.m3u8',
    '#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example.jp/key.bin",IV=0x00',
    '#EXT-X-MAP:URI="init.mp4"',
    '',
  ].join('\n')
  const out = rewritePlaylist(master, 'https://si-f-radiko.smartstream.ne.jp/so/playlist.m3u8?a=1',
    (abs, kind) => `[${kind}]${abs}`)
  const lines = out.split('\n')
  eq('非 URI 行原样保留', lines.slice(0, 3), [
    '#EXTM3U', '#EXT-X-VERSION:3', '#EXT-X-STREAM-INF:BANDWIDTH=48000',
  ])
  eq('相对 playlist 按 baseURL 解析', lines[3],
     '[playlist]https://si-f-radiko.smartstream.ne.jp/so/chunklist_b48000.m3u8')
  eq('KEY 的 URI 按分片处理', lines[4],
     '#EXT-X-KEY:METHOD=AES-128,URI="[segment]https://cdn.example.jp/key.bin",IV=0x00')
  eq('MAP 的相对 URI 也改', lines[5],
     '#EXT-X-MAP:URI="[segment]https://si-f-radiko.smartstream.ne.jp/so/init.mp4"')
  eq('末尾空行保留', lines[6], '')

  const chunk = ['#EXTM3U', '#EXTINF:5.0,', 'media_1.aac', '#EXTINF:5.0,', '/abs/media_2.aac', ''].join('\n')
  const rewritten = rewritePlaylist(chunk, 'https://cdn.example.jp/dir/chunklist.m3u8', () => 'X')
  eq('#EXTINF 一个字都不动', rewritten.split('\n').filter((l) => l.startsWith('#EXTINF')),
     ['#EXTINF:5.0,', '#EXTINF:5.0,'])
  eq('分片行都被改写', rewritten.split('\n').filter((l) => l === 'X').length, 2)

  eq('uriKind 认 m3u8（带 query）', uriKind('chunklist.m3u8?token=1'), 'playlist')
  eq('uriKind 认 aac', uriKind('media_1.aac'), 'segment')

  // radiko 直播的 master 里，变体地址**不带扩展名**。按扩展名猜会把 chunklist 当分片
  // 透传（里面的分片地址就没被改写，浏览器绕过反代直连 CDN → CORS 失败）。
  // `#EXT-X-STREAM-INF` 的下一个 URI 行一定是 playlist，这条必须靠上下文而不是扩展名。
  const noExt = [
    '#EXTM3U',
    '#EXT-X-STREAM-INF:PROGRAM-ID=1,BANDWIDTH=52973,CODECS="mp4a.40.5"',
    'https://si-f-radiko.smartstream.ne.jp/so/playlist?station_id=JOAK-FM&l=15',
    '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="jp",URI="alt_audio"',
    '#EXT-X-KEY:METHOD=AES-128,URI="key"',
    '',
  ].join('\n')
  const kinds = rewritePlaylist(noExt, 'https://si-f-radiko.smartstream.ne.jp/so/x', (abs, kind) => kind)
    .split('\n')
  eq('STREAM-INF 之后没扩展名也算 playlist', kinds[2], 'playlist')
  eq('EXT-X-MEDIA 的备用轨是 playlist',
     kinds[3], '#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="jp",URI="playlist"')
  eq('没扩展名的 KEY 仍按分片取', kinds[4], '#EXT-X-KEY:METHOD=AES-128,URI="segment"')
  // 上下文只作用于紧跟的那一行，不该漏到后面的分片上。
  const oneShot = rewritePlaylist(
    ['#EXT-X-STREAM-INF:BANDWIDTH=1', 'child', '#EXTINF:5.0,', 'seg.aac', ''].join('\n'),
    'https://e.jp/p.m3u8', (abs, kind) => kind)
  eq('变体标记只管一行', oneShot.split('\n').slice(0, 4), ['#EXT-X-STREAM-INF:BANDWIDTH=1', 'playlist', '#EXTINF:5.0,', 'segment'])
}

// MARK: - URLVault

{
  const vault = new URLVault()
  const a = vault.put('https://a.example/1.aac', { kind: 'radiko' })
  const again = vault.put('https://a.example/1.aac', { kind: 'radiko' })
  eq('同一地址拿到同一 token', a, again)
  eq('token 取回原地址', vault.get(a).url, 'https://a.example/1.aac')
  eq('未知 token 取不到', vault.get('zzzz'), undefined)
  for (let i = 0; i < 8100; i++) vault.put(`https://a.example/${i}.aac`, {})
  ok('容量有上限（不会一路涨到 OOM）', vault.size <= 8000)
  ok('最老的被淘汰', vault.get(a) === undefined)

  // 直播 chunklist 会话过期后要能把同一个 token 指到新会话（播放器手里那条地址不作废）。
  const v2 = new URLVault()
  const t = v2.put('https://old.example/chunklist', { kind: 'radiko', station: 'TBS' })
  ok('retarget 认已有 token', v2.retarget(t, 'https://new.example/chunklist'))
  eq('token 指向新地址', v2.get(t).url, 'https://new.example/chunklist')
  eq('没传 meta 就沿用旧的', v2.get(t).meta.station, 'TBS')
  eq('旧地址不再反查到这个 token', v2.put('https://old.example/chunklist', {}) === t, false)
  eq('新地址反查得到同一个 token', v2.put('https://new.example/chunklist', {}), t)
  eq('未知 token 不能 retarget', v2.retarget('zzzz', 'https://x.example/y'), false)
}

// MARK: - firstURI（重建直播会话要靠它从 master 里取变体地址）

{
  const master = [
    '#EXTM3U', '#EXT-X-VERSION:6',
    '#EXT-X-STREAM-INF:BANDWIDTH=52973,CODECS="mp4a.40.5"',
    'chunklist?session=abc',
    '#EXT-X-STREAM-INF:BANDWIDTH=99', 'second',
  ].join('\n')
  eq('取第一条 URI 并解析成绝对地址',
     firstURI(master, 'https://si-f-radiko.smartstream.ne.jp/so/playlist.m3u8?station_id=TBS'),
     'https://si-f-radiko.smartstream.ne.jp/so/chunklist?session=abc')
  eq('只有标签就是 null', firstURI('#EXTM3U\n#EXT-X-ENDLIST\n', 'https://e.jp/p.m3u8'), null)
}

// MARK: - JST 换算与放送日

{
  // 12 位与 14 位都要认（ListenRadio 给 12 位，radiko 给 14 位）。
  eq('14 位时刻', pg.jstStampToEpoch('20260824070000'), Date.UTC(2026, 7, 23, 22, 0, 0))
  eq('12 位时刻（ListenRadio 没有秒）', pg.jstStampToEpoch('202608240700'), Date.UTC(2026, 7, 23, 22, 0, 0))
  // radiko 深夜档写成「24:30」表示次日 0:30。
  eq('小时 ≥ 24 自然进位', pg.jstStampToEpoch('20260824243000'), Date.UTC(2026, 7, 24, 15, 30, 0))
  eq('位数不对返回 null', pg.jstStampToEpoch('2026082407'), null)
  eq('非时刻字符串返回 null', pg.jstStampToEpoch('FMわっぴー'), null)
  eq('月份非法返回 null', pg.jstStampToEpoch('20261324070000'), null)
  eq('往返：epoch → 时刻串', pg.epochToJSTStamp(Date.UTC(2026, 7, 23, 22, 0, 0)), '20260824070000')

  // 放送日按 05:00 起算：凌晨 2:30 仍算前一天。
  const lateNight = Date.UTC(2026, 7, 25, 17, 30, 0)  // 2026-08-26 02:30 JST
  eq('凌晨属前一放送日', pg.broadcastDayStart(0, lateNight), Date.UTC(2026, 7, 24, 20, 0, 0))
  eq('凌晨的放送日字符串', pg.broadcastDateString(0, lateNight), '20260825')
  const noon = Date.UTC(2026, 7, 26, 3, 0, 0)         // 2026-08-26 12:00 JST
  eq('白天就是当天', pg.broadcastDayStart(0, noon), Date.UTC(2026, 7, 25, 20, 0, 0))
  eq('白天的放送日字符串', pg.broadcastDateString(0, noon), '20260826')
  eq('昨天', pg.broadcastDateString(-1, noon), '20260825')
  eq('7 天后', pg.broadcastDateString(7, noon), '20260902')
  eq('放送日长度是一天', pg.broadcastDayStart(1, noon) - pg.broadcastDayStart(0, noon), 86400_000)
  eq('JST 时分', pg.jstParts(Date.UTC(2026, 7, 23, 22, 0, 0)).hour, 7)
}

// MARK: - radiko 番組表 XML

{
  const xml = `<?xml version="1.0"?><radiko><stations><station id="TBS">
    <progs>
      <prog id="p1" ft="20260826050000" to="20260826063000" dur="5400">
        <title><![CDATA[森本毅郎・スタンバイ!]]></title>
        <pfm>森本毅郎 &amp; 遠藤泰子</pfm>
        <img>https://program-static.cf.radiko.jp/x.jpg</img>
      </prog>
      <prog id="p2" ft="20260827003000" to="20260827013000">
        <title>JUNK &lt;深夜&gt;</title>
        <pfm></pfm>
      </prog>
    </progs></station></stations></radiko>`
  const list = pg.parseRadikoProgramXML(xml)
  eq('解析出两档', list.length, 2)
  eq('CDATA 剥掉', list[0].title, '森本毅郎・スタンバイ!')
  eq('实体还原（&amp;）', list[0].performer, '森本毅郎 & 遠藤泰子')
  eq('实体还原（&lt;&gt;）', list[1].title, 'JUNK <深夜>')
  eq('起止时刻', [list[0].start, list[0].end],
     [Date.UTC(2026, 7, 25, 20, 0, 0), Date.UTC(2026, 7, 25, 21, 30, 0)])
  eq('取到 id', list[0].id, 'p1')
  eq('没有 img 就是 null', list[1].image, null)
  eq('空 pfm 是空串', list[1].performer, '')
  eq('空 XML 不抛，返回空表', pg.parseRadikoProgramXML('<radiko/>'), [])
}

// MARK: - ListenRadio 番組表 JSON（真实形状 + 宽容路径）

{
  const real = {
    ProgramList: [{
      ChannelId: 30011,
      Schedule: [
        { ProgramName: 'モーニングわっぴー', ProgramSummary: '朝の情報番組',
          StartDate: '202608260700', EndDate: '202608260900' },
        { ProgramName: 'ひるどき', ProgramSummary: '', StartDate: '202608261200', EndDate: '202608261300' },
      ],
    }],
  }
  const rows = pg.collectRows(real)
  eq('收到两行', rows.length, 2)
  const list = pg.programsFromRows(rows)
  eq('标题', list[0].title, 'モーニングわっぴー')
  eq('12 位起始时刻', list[0].start, Date.UTC(2026, 7, 25, 22, 0, 0))
  eq('结束时刻', list[0].end, Date.UTC(2026, 7, 26, 0, 0, 0))
  eq('按时间排序', list[1].title, 'ひるどき')

  // 键名改了也要还能出东西（按关键词兜底）。
  const renamed = { list: [{ programTitleJa: 'X', onAirStartAt: '202608260700', castNames: 'A' }] }
  const fallback = pg.programsFromRows(pg.collectRows(renamed))
  eq('键名换了仍能解析出一档', fallback.length, 1)
  eq('键名换了仍能取到标题', fallback[0].title, 'X')

  eq('没有时刻的数组不算节目行', pg.collectRows({ a: [{ x: 1 }, { y: 2 }] }), [])
  eq('JSONP 外壳能剥掉', pg.looseJSON('cb({"a":1});')?.a, 1)
  eq('BOM 不影响解析', pg.looseJSON('﻿{"a":2}')?.a, 2)
  eq('不是 JSON 就返回 null', pg.looseJSON('<html>error</html>'), null)
  eq('频道号去掉 LR 前缀', pg.listenRadioChannel('LR30011'), '30011')
}

// MARK: - 直播地址与 stream XML

{
  const xml = `<urls>
    <url areafree="1" timefree="0"><playlist_create_url>https://af.example/af.m3u8</playlist_create_url></url>
    <url areafree="0" timefree="0"><playlist_create_url>https://live.example/live.m3u8</playlist_create_url></url>
    <url areafree="0" timefree="1"><playlist_create_url>https://tf.example/tf.m3u8</playlist_create_url></url>
  </urls>`
  const entries = radiko.parseStreamXML(xml)
  eq('解析出三条入口', entries.length, 3)
  // areafree=1 是给付费会员的，用 GPS 伪造出来的区域内 token 去请求会 403 —— 必须挑 areafree=0。
  const live = entries.filter((e) => !e.timefree).find((e) => !e.areafree)
  eq('直播挑 areafree=0', live.url, 'https://live.example/live.m3u8')
  const tf = entries.filter((e) => e.timefree).find((e) => !e.areafree)
  eq('タイムフリー 挑 timefree=1', tf.url, 'https://tf.example/tf.m3u8')

  const u = new URL(radiko.liveURL('https://live.example/live.m3u8', 'TBS', 'abc123'))
  eq('拉流参数 station_id', u.searchParams.get('station_id'), 'TBS')
  eq('拉流参数 l=15', u.searchParams.get('l'), '15')
  eq('拉流参数 lsid', u.searchParams.get('lsid'), 'abc123')
  eq('拉流参数 type=b', u.searchParams.get('type'), 'b')
}

// MARK: - タイムフリー 分片收集

{
  const chunk = [
    '#EXTM3U', '#EXT-X-TARGETDURATION:5', '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXTINF:5.000,', 'a.aac',
    '#EXTINF:4.500,', 'https://cdn.example.jp/b.aac',
    '#EXT-X-ENDLIST', '',
  ].join('\n')
  const segs = collectSegments(chunk, 'https://cdn.example.jp/dir/chunklist.m3u8')
  eq('两个分片', segs.length, 2)
  eq('相对地址按 baseURL 解析', segs[0].url, 'https://cdn.example.jp/dir/a.aac')
  eq('时长跟着各自的 EXTINF', [segs[0].duration, segs[1].duration], [5, 4.5])
  eq('绝对地址原样', segs[1].url, 'https://cdn.example.jp/b.aac')
  eq('没有 EXTINF 时退回 5 秒', collectSegments('#EXTM3U\nx.aac\n', 'https://e.jp/p.m3u8')[0].duration, 5)

  // タイムフリー 的窗口回的是 master，必须先认出来再往下一层。直接收 master 的话，
  // 那条变体地址会被当成一个 5 秒分片 —— 15 分钟的节目只拼出 15 秒（真踩过）。
  const masterOnly = [
    '#EXTM3U', '#EXT-X-VERSION:6',
    '#EXT-X-STREAM-INF:BANDWIDTH=52973,CODECS="mp4a.40.5"', 'chunklist?session=abc', '',
  ].join('\n')
  eq('master 不是媒体 playlist', isMediaPlaylist(masterOnly), false)
  eq('chunklist 是媒体 playlist', isMediaPlaylist(chunk), true)
  eq('若误收 master 只会得到一条（所以必须先判断）',
     collectSegments(masterOnly, 'https://e.jp/so/playlist.m3u8').length, 1)
}

// MARK: - stations.json（由 Station.swift 导出，与 app 同一份）

{
  const doc = JSON.parse(readFileSync(join(here, '..', 'public', 'stations.json'), 'utf8'))
  const all = doc.regions.flatMap((r) => r.stations)
  eq('拨盘数', doc.regions.length, 14)
  eq('电台数', all.length, 116)
  eq('直连（ListenRadio）台数', all.filter((s) => s.direct).length, 77)
  eq('刻度范围', [doc.dialLowerBound, doc.dialUpperBound], [76, 95])
  eq('台 id 不重复', new Set(all.map((s) => s.id)).size, all.length)
  // 直连台的流地址必须带出来（服务端要靠它反代）；radiko 台反过来不该有。
  ok('直连台都有 streamURL', all.filter((s) => s.direct).every((s) => /^https?:\/\//.test(s.streamURL ?? '')))
  ok('radiko 台没有 streamURL', all.filter((s) => !s.direct).every((s) => s.streamURL == null))
  ok('频率都落在刻度范围内',
     all.every((s) => s.frequency >= doc.dialLowerBound && s.frequency <= doc.dialUpperBound))
  ok('radiko 台的 areaID 形如 JPnn', all.filter((s) => !s.direct).every((s) => /^JP\d{2}$/.test(s.areaID)))
  ok('每台都有名字与台标', all.every((s) => s.name && s.logo))
  ok('每条拨盘都标了 kind', doc.regions.every((r) => r.kind === 'radiko' || r.kind === 'listenradio'))
  // 服务端只按 areaID 取 token，所以 radiko 台涉及的每个地区都得在 GPS 表里有基准坐标，
  // 否则会静静退回东京、境外绕过就对不上区。
  const areas = new Set(all.filter((s) => !s.direct).map((s) => s.areaID))
  eq('GPS 表覆盖所有 radiko 地区', [...areas].filter((a) => !radiko.GPS[a]), [])
}

// MARK: - 前端资源齐不齐（少一个文件就是白屏，值得钉住）

{
  const need = ['index.html', 'style.css', 'app.js', 'dial.js', 'i18n.js',
                'recognize.js', 'sig-worker.js', 'stations.json']
  const missing = need.filter((f) => {
    try {
      return !readFileSync(join(here, '..', 'public', f), 'utf8')
    } catch {
      return true
    }
  })
  eq('public/ 下的文件齐全', missing, [])
  const read = (f) => readFileSync(join(here, '..', 'public', f), 'utf8')
  const html = read('index.html')
  ok('index.html 引了四个脚本',
     ['i18n.js', 'dial.js', 'app.js', 'recognize.js'].every((f) => html.includes(f)))
  // 识曲界面全靠这几个 id 找元素，改了名 recognize.js 会静默失效（按钮点了没反应）。
  ok('index.html 有识曲要的那几个元素',
     ['id="identify"', 'id="auto-identify"', 'id="song"', 'id="song-art"',
      'id="song-title"', 'id="song-artist"', 'id="song-link"', 'id="song-close"']
       .every((s) => html.includes(s)))

  const worker = read('sig-worker.js')
  const rjs = read('recognize.js')
  // 指纹只该有一份：worker 直接 import 服务端在用的那个文件（服务端为它开了 /lib/）。
  ok('worker import 的是 lib 里那份 shazam.mjs', worker.includes("from '/lib/shazam.mjs'"))
  ok('worker 按 module 起（不然 import 不了）', rjs.includes("{ type: 'module' }"))
  // 12 秒是硬上限：更长的话上游只回一个没有 track 的 200，会被当成「没这首歌」。
  ok('recognize.js 裁到 12 秒', /SIG_SECONDS\s*=\s*12\b/.test(rjs))
  // app.js 要真的把三个钩子都调起来，否则自动识曲永远不会开始。
  const ajs = read('app.js')
  for (const hook of ['stationChanged', 'playbackChanged', 'applyLanguage']) {
    ok(`app.js 调了 recognizeHooks.${hook}`, ajs.includes(`recognizeHooks?.${hook}`))
  }
  // 文案少一条，界面上会直接露出键名。
  const i18n = read('i18n.js')
  const keys = ['identify', 'identifying', 'noMatch', 'identifyFailed', 'identifyGaveUp',
                'identifyNoStation', 'identifyTooShort', 'autoIdentifyOn', 'autoIdentifyOff',
                'appleMusic', 'close']
  eq('i18n 识曲文案齐全', keys.filter((k) => !i18n.includes(`${k}:`)), [])
}

// MARK: - 并发池（タイムフリー 拼窗口用；顺序错了就是音频错乱，很难查）

{
  let running = 0
  let peak = 0
  const items = Array.from({ length: 20 }, (_, i) => i)
  const got = await mapPool(items, 5, async (n) => {
    running++
    peak = Math.max(peak, running)
    // 故意让后面的先返回：如果实现按「谁先回来算谁的」，顺序立刻就乱。
    await new Promise((r) => setTimeout(r, (20 - n) % 7))
    running--
    return n * 2
  })
  eq('结果顺序与输入一致', got, items.map((n) => n * 2))
  ok(`并发不超过上限（峰值 ${peak}）`, peak <= 5)
  ok('确实并发了（不是串行）', peak > 1)
  eq('空表不抛', await mapPool([], 4, async () => 1), [])
  eq('上限比条数大也没问题', await mapPool([1, 2], 99, async (n) => n + 1), [2, 3])
  eq('上限给 0 也当 1 用', await mapPool([1, 2], 0, async (n) => n + 1), [2, 3])
}

// MARK: - 路由（只走不联网的分支）
//
// 这台机器上 `listen()` 是被禁的（EPERM），所以不真起服务：直接调 server.mjs 导出的
// `handle(req, res)`，喂假的 req/res。能钉住的正是最容易写错的那些拒绝路径 ——
// 未知台、过期 token、目录穿越、不在白名单的图片域名、参数不合法的タイムフリー。

{
  const { handle, reachableURLs } = await import('../server.mjs')

  /// 记录 writeHead/end 的假 res（够 server.mjs 用了：它只用这两个 + headersSent）。
  /// `/api/recognize` 要读 body，所以假 req 也做成可异步迭代的。
  const call = async (path, { method, body } = {}) => {
    let status = 0
    let headers = {}
    const chunks = []
    const res = {
      headersSent: false,
      writeHead(s, h) { status = s; headers = h ?? {}; res.headersSent = true },
      end(body) { if (body != null) chunks.push(body) },
    }
    const req = {
      url: path,
      method,
      headers: { host: '127.0.0.1:8787' },
      async *[Symbol.asyncIterator]() { if (body != null) yield Buffer.from(body) },
    }
    await handle(req, res)
    return { status, headers, body: Buffer.concat(chunks.map((c) => Buffer.from(c))).toString('utf8') }
  }

  eq('/api/health 200', (await call('/api/health')).status, 200)
  const health = JSON.parse((await call('/api/health')).body)
  eq('health 台数', health.stations, 116)
  eq('health 拨盘数', health.dials, 14)
  ok('health 报了鉴权模式', typeof health.radiko.mode === 'string' && health.radiko.mode.length > 0)
  ok('health 不含 key 本身', !JSON.stringify(health).includes('androidFullKey'))

  eq('未知电台 404', (await call('/stream/NOPE.m3u8')).status, 404)
  eq('过期分片 token 410', (await call('/s/zzzz')).status, 410)
  eq('过期 playlist token 410', (await call('/p/zzzz.m3u8')).status, 410)
  eq('番組表未知电台 404', (await call('/api/programs?station=NOPE')).status, 404)
  eq('不在白名单的图片域名 403', (await call('/api/image?u=https://evil.example/x.png')).status, 403)
  eq('http 图片（非 https）403', (await call('/api/image?u=http://radiko.jp/x.png')).status, 403)
  eq('图片地址不合法 400', (await call('/api/image?u=notaurl')).status, 400)
  eq('直连台没有タイムフリー 400', (await call('/timefree/LR30011.m3u8?start=1&end=2')).status, 400)
  eq('タイムフリー 参数不合法 400', (await call('/timefree/TBS.m3u8?start=abc&end=2')).status, 400)
  eq('タイムフリー 未播完 400',
     (await call(`/timefree/TBS.m3u8?start=${Date.now() + 1000}&end=${Date.now() + 7200_000}`)).status, 400)

  const index = await call('/')
  eq('/ 返回首页 200', index.status, 200)
  eq('首页是 html', index.headers['Content-Type'], 'text/html; charset=utf-8')
  ok('首页确实是那份 index.html', index.body.includes('id="dial"'))
  eq('app.js 的 MIME', (await call('/app.js')).headers['Content-Type'], 'text/javascript; charset=utf-8')
  eq('stations.json 的 MIME', (await call('/stations.json')).headers['Content-Type'],
     'application/json; charset=utf-8')
  eq('不存在的文件 404', (await call('/nope.txt')).status, 404)
  // 目录穿越：`/../` 在 URL 里就被规范化掉了，`%2e%2e` 这类要 decode 之后才现形。
  // 两种写法都不许拿到 public/ 外面的东西 —— 落到 403（越界）或 404（在 public/ 里没这个文件）都行，
  // 唯独不能是 200 带着文件内容。
  for (const attack of ['/%2e%2e/%2e%2e/etc/passwd', '/..%2f..%2fetc/passwd', '/../../../etc/passwd']) {
    const r = await call(attack)
    ok(`穿越被挡住：${attack}（${r.status}）`, r.status === 403 || r.status === 404)
    ok(`没有读到 /etc/passwd：${attack}`, !r.body.includes('root:'))
  }
  eq('坏转义是 400 不是 500', (await call('/%ZZ')).status, 400)

  // 识曲这几条也都不联网：未知台在查 playlist 之前就被挡掉，坏 body / 超长 samplems /
  // 形状不对的 uri 都在 tagRequest 里就抛了。
  eq('抓音未知电台 404', (await call('/api/snippet/NOPE')).status, 404)
  eq('识曲不许 GET', (await call('/api/recognize')).status, 405)
  eq('识曲 body 不是 JSON → 400',
     (await call('/api/recognize', { method: 'POST', body: 'nope' })).status, 400)
  const tooLong = await call('/api/recognize', {
    method: 'POST', body: JSON.stringify({ uri: 'x', samplems: 20_000 }),
  })
  eq('识曲：超过 13 秒的指纹在服务端就被挡下（不然会被当成 no match）', tooLong.status, 400)
  ok('识曲：挡下时说清了原因', JSON.parse(tooLong.body).error.includes('20000'))
  const badURI = await call('/api/recognize', {
    method: 'POST', body: JSON.stringify({ uri: 'x', samplems: 12_000 }),
  })
  eq('识曲：uri 形状不对 → 502（tagRequest 抛，没发出去）', badURI.status, 502)

  const shared = await call('/lib/shazam.mjs')
  eq('/lib/shazam.mjs 200（worker 要 import 它）', shared.status, 200)
  eq('/lib/shazam.mjs 的 MIME', shared.headers['Content-Type'], 'text/javascript; charset=utf-8')
  eq('/lib/ 只开放白名单里那一个文件', (await call('/lib/radiko.mjs')).status, 403)

  // 开放到局域网时要报出手机上真正能输入的地址：`http://0.0.0.0:8787` 是打不开的。
  eq('只听本机时就报本机地址', reachableURLs('127.0.0.1', 8787),
     [{ url: 'http://127.0.0.1:8787', via: null }])
  const lan = reachableURLs('0.0.0.0', 8787)
  eq('通配地址时第一条仍是本机', lan[0].url, 'http://127.0.0.1:8787')
  ok('通配地址时报的都是能输入的 IPv4:端口',
     lan.every((u) => /^http:\/\/(\d{1,3}\.){3}\d{1,3}:8787$/.test(u.url)))
  ok('不报 link-local（169.254.x.x，没设备连得上）',
     lan.every((u) => !u.url.includes('://169.254.')))
  ok('每条都带网卡名（VPN 挂的那个地址要能看出来别选）', lan.every((u) => !!u.via))
}

// MARK: - MPEG-TS → ADTS（ListenRadio 的分片是 TS，decodeAudioData 读不了）
//
// 真分片要联网，所以这里自己拼一段 TS：PAT → PMT → PES。
// 这一段悄悄坏掉的表现是「30 个 ListenRadio 台全都识不出曲」，很难查，值得钉住。

{
  /// 拼一个 188 字节的 TS 包。`start` 是 payload_unit_start_indicator。
  /// `adaptation` 用来喂 adaptation field 那条分支（也顺便把不足 184 的尾包填满）。
  const packet = (pid, start, payload, adaptation = false) => {
    const p = Buffer.alloc(188, 0xff)
    p[0] = 0x47
    p[1] = (start ? 0x40 : 0) | ((pid >> 8) & 0x1f)
    p[2] = pid & 0xff
    let at = 4
    if (adaptation) {
      const pad = 184 - 1 - payload.length          // adaptation_field_length 自己占 1 字节
      p[3] = 0x30                                   // 有 adaptation field ＋ 有载荷
      p[4] = pad
      for (let i = 0; i < pad; i++) p[5 + i] = 0xff
      at = 5 + pad
    } else {
      p[3] = 0x10                                   // 只有载荷
    }
    payload.copy(p, at)
    return p
  }

  const pat = () => {
    const s = Buffer.alloc(184, 0xff)
    s[0] = 0                                        // pointer_field
    const b = s.subarray(1)
    b[0] = 0x00                                     // table_id: PAT
    b[1] = 0xb0; b[2] = 17                          // section_length：b[3] 起到 CRC 末尾
    b[3] = 0x00; b[4] = 0x01                        // transport_stream_id
    b[5] = 0xc1; b[6] = 0x00; b[7] = 0x00
    b[8] = 0x00; b[9] = 0x00                        // program_number 0 = NIT，应当被跳过
    b[10] = 0xe0; b[11] = 0x10                      // …它的 PID 别被当成 PMT
    b[12] = 0x00; b[13] = 0x01                      // program_number 1
    b[14] = 0xf0; b[15] = 0x00                      // PMT PID = 0x1000
    b.fill(0, 16, 20)                               // CRC32（解析器不校验）
    return s
  }

  const pmt = () => {
    const s = Buffer.alloc(184, 0xff)
    s[0] = 0
    const b = s.subarray(1)
    b[0] = 0x02                                     // table_id: PMT
    b[1] = 0xb0; b[2] = 28                          // section_length：5 + PCR 2 + 长度 2 + 描述 2 + 两条流 13 + CRC 4
    b[3] = 0x00; b[4] = 0x01
    b[5] = 0xc1; b[6] = 0x00; b[7] = 0x00
    b[8] = 0xe1; b[9] = 0x01                        // PCR PID
    b[10] = 0xf0; b[11] = 0x02                      // program_info_length = 2
    b[12] = 0x0e; b[13] = 0x00                      // 一条无关的 descriptor
    b[14] = 0x1b; b[15] = 0xe1; b[16] = 0x02        // stream_type 0x1B（H.264）在前
    b[17] = 0xf0; b[18] = 0x03                      // ES_info_length = 3 → 要跳过
    b[19] = 0x52; b[20] = 0x01; b[21] = 0x00
    b[22] = 0x0f; b[23] = 0xe1; b[24] = 0x03        // stream_type 0x0F（ADTS AAC），PID 0x103
    b[25] = 0xf0; b[26] = 0x00
    b.fill(0, 27, 31)
    return s
  }

  /// 一段 ES 拆成若干 PES 包：首包带 9 字节 PES 头，所以只装 175 字节，后面每包 184。
  const pes = (es, pid = 0x103) => {
    const out = []
    let at = 0
    let first = true
    while (at < es.length) {
      if (first) {
        const take = Math.min(175, es.length - at)
        const head = Buffer.alloc(9)
        head[2] = 0x01; head[3] = 0xc0               // 00 00 01 C0：音频流
        head[4] = ((take + 3) >> 8) & 0xff; head[5] = (take + 3) & 0xff
        head[6] = 0x80; head[7] = 0x00; head[8] = 0x00 // PES_header_data_length = 0
        const body = Buffer.concat([head, es.subarray(at, at + take)])
        out.push(packet(pid, true, body, body.length < 184))
        at += take
        first = false
      } else {
        const take = Math.min(184, es.length - at)
        const body = es.subarray(at, at + take)
        out.push(packet(pid, false, body, body.length < 184))
        at += take
      }
    }
    return out
  }

  const es = Buffer.from(Array.from({ length: 500 }, (_, i) => (i * 7 + 3) & 0xff))
  const segment = Buffer.concat([packet(0, true, pat()), packet(0x1000, true, pmt()), ...pes(es)])

  ok('TS：认得出来', looksLikeTS(segment))
  ok('TS：ADTS 不会被误判成 TS', !looksLikeTS(Buffer.alloc(400, 0xff)))
  ok('TS：太短的也不算', !looksLikeTS(Buffer.from([0x47, 0x00, 0x00])))
  eq('TS：ES 一字节不差地拆出来',
     Buffer.from(tsToADTS(segment)).toString('hex'), es.toString('hex'))
  // 一个抓音请求会把好几个分片首尾相接，每个分片都自带 PAT/PMT。
  eq('TS：多个分片拼起来也能拆', tsToADTS(Buffer.concat([segment, segment])).length, es.length * 2)
  eq('TS：只有 PAT 时拆出空', tsToADTS(packet(0, true, pat())).length, 0)
  // 加扰位（transport_scrambling_control）置上的包解不了，得整包跳过而不是当明文用。
  const scrambled = Buffer.from(segment)
  for (let at = 0; at + 188 <= scrambled.length; at += 188) {
    if ((((scrambled[at + 1] & 0x1f) << 8) | scrambled[at + 2]) === 0x103) scrambled[at + 3] |= 0xc0
  }
  eq('TS：加扰的包被跳过', tsToADTS(scrambled).length, 0)
}

// MARK: - amp.shazam.com 的请求形状
//
// 这个私有端点对形状很挑：locale 写成裸 `en` 就是 400。所以把 URL/头/body 都钉死，
// 一个都不联网 —— tagRequest 是纯函数，uuid/时间/时区都可以注进去。

{
  const req = tagRequest({
    uri: 'data:audio/vnd.shazam.sig;base64,AAAA',
    samplems: 12_000,
    uuid: (() => { let n = 0; return () => `uuid${++n}` })(),
    now: () => 1_700_000_000_123,
    timezone: () => 'Asia/Tokyo',
  })
  const url = new URL(req.url)
  eq('Shazam：host', url.host, 'amp.shazam.com')
  eq('Shazam：path', url.pathname, '/discovery/v5/en-US/JP/iphone/-/tag/uuid1/uuid2')
  eq('Shazam：两个 uuid 不是同一个', new Set(url.pathname.split('/').slice(-2)).size, 2)
  eq('Shazam：apiversion', url.searchParams.get('shazamapiversion'), 'v3')
  ok('Shazam：connected 是个空值参数（少了这个也会被挑）', url.searchParams.has('connected'))
  eq('Shazam：connected 确实为空', url.searchParams.get('connected'), '')
  eq('Shazam：POST', req.method, 'POST')
  eq('Shazam：Accept-Language 跟 locale 一致', req.headers['Accept-Language'], 'en-US')
  eq('Shazam：平台头', req.headers['X-Shazam-Platform'], 'IPHONE')
  // 故意不发 Accept-Encoding：让 undici 自己谈压缩、自己解，不然要自己处理 gzip。
  eq('Shazam：不自报 Accept-Encoding',
     Object.keys(req.headers).filter((k) => k.toLowerCase() === 'accept-encoding'), [])
  const body = JSON.parse(req.body)
  eq('Shazam：body 的键', Object.keys(body).sort(),
     ['context', 'geolocation', 'signature', 'timestamp', 'timezone'])
  eq('Shazam：samplems 原样带过去', body.signature.samplems, 12_000)
  eq('Shazam：uri 原样带过去', body.signature.uri, 'data:audio/vnd.shazam.sig;base64,AAAA')
  eq('Shazam：timestamp', body.timestamp, 1_700_000_000_123)
  eq('Shazam：timezone', body.timezone, 'Asia/Tokyo')
  // 当初 400 的根因就是 locale 写成了裸 `en`。
  ok('Shazam：locale 是 xx-XX 形式', /^[a-z]{2}-[A-Z]{2}$/.test(SHAPE.locale))

  const throws = (fn) => { try { fn(); return false } catch { return true } }
  ok('Shazam：uri 形状不对就抛', throws(() => tagRequest({ uri: 'x', samplems: 12_000 })))
  ok('Shazam：samplems 不合法就抛',
     throws(() => tagRequest({ uri: 'data:audio/vnd.shazam.sig;base64,AA', samplems: 0 })))

  eq('Shazam：解一条正常结果', parseTrack({
    title: 'Hakujitsu',
    subtitle: 'King Gnu',
    images: { coverart: 'https://x/lo.jpg', coverarthq: 'https://x/hq.jpg' },
    url: 'https://www.shazam.com/track/1',
    hub: { options: [{ actions: [{ uri: 'spotify:1' }, { uri: 'https://music.apple.com/jp/album/1' }] }] },
  }), {
    title: 'Hakujitsu',
    artist: 'King Gnu',
    artwork: 'https://x/hq.jpg',                    // 有高清就用高清
    appleMusic: 'https://music.apple.com/jp/album/1',
  })
  eq('Shazam：没有 Apple Music 链接时退回 track.url',
     parseTrack({ title: 'A', url: 'https://www.shazam.com/track/2' }).appleMusic,
     'https://www.shazam.com/track/2')
  eq('Shazam：没标题就不算一首歌', parseTrack({ subtitle: 'x' }), null)
  // 200 空壳（没有 track 键）跟「不在曲库里」长得一样，都得落到 null。
  eq('Shazam：200 空壳 → null', parseTrack(undefined), null)
}

// MARK: - Shazam 指纹

{
  // 这一段钉的是「跟 ShazamKit 对照过的那一次」的结果。
  // 对照怎么做见 web/test/sigdiff.mjs 与 tools/ShazamSigRef.swift；那次的结论是：
  //   - 字节格式与 ShazamKit **完全一致**（解开它的签名再用我们的写入器重打，一个字节不差）；
  //   - ShazamKit 那 432 个峰（帧号在我们范围内的）我们**一个不漏**，`(帧号, 频点)` 全等。
  // 这里不需要 ShazamKit 在场，只要这几个数还对得上，就说明窗函数分母、FFT 归一、
  // 扩散偏移、判定门、抛物线插值、频段边界、TLV 写入都没被动过。
  const pcm = makeProbe(12)
  const bands = collectPeaks(pcm)
  eq('指纹：四个频段的峰数', bands.map((b) => b.length), [34, 140, 417, 713])

  // 下面四个峰是 ShazamKit 也算出来的（前三个连幅度都一样，band 2 那个它是 15928 ——
  // 差一个最低位，两边浮点路径不完全同源，允许）。
  const at = (i, pass, bin) => {
    const p = bands[i].find((x) => x.pass === pass && x.bin === bin)
    return p ? [p.pass, p.bin, p.magnitude] : null
  }
  eq('指纹：band 0 的一个已核对峰', at(0, 35, 3211), [35, 3211, 31884])
  eq('指纹：band 1 的一个已核对峰', at(1, 14, 10716), [14, 10716, 26552])
  eq('指纹：band 2 的一个已核对峰', at(2, 8, 20496), [8, 20496, 15927])
  eq('指纹：band 3 的一个已核对峰', at(3, 757, 30728), [757, 30728, 17306])

  const bytes = signature(pcm)
  eq('指纹：签名字节数', bytes.length, 6616)
  const dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)
  eq('指纹：magic1', dv.getUint32(0, true).toString(16), 'cafe2580')
  eq('指纹：magic2 跟 ShazamKit 一致', dv.getUint32(12, true).toString(16), '43504010')
  eq('指纹：size-48 与实际长度相符', dv.getUint32(8, true), bytes.length - 48)
  eq('指纹：size-48 在偏移 52 复述了一遍', dv.getUint32(52, true), dv.getUint32(8, true))
  eq('指纹：采样率编号（16 kHz → 3）', dv.getUint32(28, true) >>> 27, 3)
  // 「样本数 + (u32)(f32)(采样率 * 0.24)」这一项 12 秒与 5 秒两份 ShazamKit 签名都核对过。
  eq('指纹：样本数那一项', dv.getUint32(40, true), 192000 + 3840)

  const back = decodeSignature(bytes)
  eq('指纹：解回来的峰数一致', back.bands.map((b) => b.length), bands.map((b) => b.length))
  eq('指纹：解回来的第一个峰一致', [back.bands[0][0].pass, back.bands[0][0].bin, back.bands[0][0].magnitude],
     [bands[0][0].pass, bands[0][0].bin, bands[0][0].magnitude])
  eq('指纹：没有认不出的 TLV', back.unknownTags.length, 0)
  // delta 编码里 pass 跨度 ≥255 要先写一个 0xFF 转义 —— 用一个人造的峰列表钉住。
  const wide = [[{ pass: 0, magnitude: 1, bin: 2 }, { pass: 400, magnitude: 3, bin: 4 }], [], [], []]
  eq('指纹：跨度 ≥255 的 delta 转义能原样解回',
     decodeSignature(encodeSignature(wide, 192000)).bands[0].map((p) => p.pass), [0, 400])
  // 空频段整块跳过：只有 band 2 有峰时，载荷里应当只有一个 chunk。
  const only2 = [[], [], [{ pass: 7, magnitude: 8, bin: 9 }], []]
  eq('指纹：空频段不写壳', encodeSignature(only2, 192000).length, 48 + 8 + 8 + 8)
  eq('指纹：只有 band 2 的那份能解回',
     decodeSignature(encodeSignature(only2, 192000)).bands.map((b) => b.length), [0, 0, 1, 0])
}

if (failed) {
  console.error(`\n${failed} 项未通过`)
  process.exit(1)
}
console.log('全部通过')
