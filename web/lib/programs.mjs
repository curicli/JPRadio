// 番組表：radiko 的官方 XML 与 ListenRadio 自己的 JSON，都归一成同一种形状给前端。
//
// 对应 iOS 端 ios/JPRadio/Radiko/RadikoStream.swift（RadikoProgramService）与
// ios/JPRadio/ListenRadio/*.swift。两个接口都在服务端取：radiko 番組表虽然不用鉴权，
// 但一样没有 CORS 头；ListenRadio 还要 Referer/UA 才不给错误页。
//
// 时间一律用 **JST**。日本不用夏令时，UTC+9 恒定，所以 `yyyyMMddHHmmss` ↔ epoch
// 直接 `Date.UTC(y, m-1, d, H-9, …)` 换算就是精确的，不需要时区库。
// 放送日按日本习惯 **05:00 起算**：凌晨 0:00–4:59 属于前一放送日。

const JST_OFFSET_MS = 9 * 3600 * 1000

export const DAY_RANGE = { min: -7, max: 7 }

const BROWSER_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15'

/// `yyyyMMddHHmm(ss)` (JST) → epoch 毫秒。位数不对返回 null。
export function jstStampToEpoch(stamp) {
  const s = String(stamp ?? '').replace(/[^0-9]/g, '')
  if (s.length !== 12 && s.length !== 14) return null
  const y = +s.slice(0, 4), mo = +s.slice(4, 6), d = +s.slice(6, 8)
  const h = +s.slice(8, 10), mi = +s.slice(10, 12), se = s.length === 14 ? +s.slice(12, 14) : 0
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 29 || mi > 59) return null
  // 注意 radiko 的 ft 里 **小时可以 ≥ 24**（「24:30」表示次日 0:30，深夜档的惯例写法）；
  // Date.UTC 会自然进位到第二天，正是想要的结果。
  return Date.UTC(y, mo - 1, d, h - 9, mi, se)
}

/// 某个 epoch 在 JST 下的年月日时分。
export function jstParts(epoch) {
  const d = new Date(epoch + JST_OFFSET_MS)
  return {
    year: d.getUTCFullYear(), month: d.getUTCMonth() + 1, day: d.getUTCDate(),
    hour: d.getUTCHours(), minute: d.getUTCMinutes(),
  }
}

/// epoch 毫秒 → `yyyyMMddHHmmss`（JST）。タイムフリー 的 ft/to/start_at/end_at 要这个形状。
export function epochToJSTStamp(epoch) {
  const d = new Date(epoch + JST_OFFSET_MS)
  const pad = (n) => String(n).padStart(2, '0')
  return `${d.getUTCFullYear()}${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}` +
    `${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}${pad(d.getUTCSeconds())}`
}

/// 放送日的起点（JST 当日 05:00）的 epoch。dayOffset=0 是今天。
export function broadcastDayStart(dayOffset = 0, now = Date.now()) {
  const p = jstParts(now)
  // 凌晨 0:00–4:59 仍属前一放送日 → 先退 5 小时再取当天。
  const base = Date.UTC(p.year, p.month - 1, p.day, -9, 0, 0) // 该 JST 日期的 00:00
  const shifted = base + (p.hour < 5 ? -1 : 0) * 86400_000 + dayOffset * 86400_000
  return shifted + 5 * 3600_000
}

/// 放送日的 `yyyyMMdd`（radiko 番組表 URL 用）。
export function broadcastDateString(dayOffset = 0, now = Date.now()) {
  const p = jstParts(broadcastDayStart(dayOffset, now))
  const pad = (n) => String(n).padStart(2, '0')
  return `${p.year}${pad(p.month)}${pad(p.day)}`
}

// MARK: - radiko 番組表 XML

const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", '#39': "'" }

function unescapeXML(s) {
  return s
    .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, '$1')
    .replace(/&(#?\w+);/g, (whole, name) => ENTITIES[name] ?? whole)
    .trim()
}

/// 解析 `<prog ft=".." to=".." id=".."><title/><pfm/><img/></prog>`。
export function parseRadikoProgramXML(xml) {
  const programs = []
  const re = /<prog\b([^>]*)>([\s\S]*?)<\/prog>/g
  let m
  while ((m = re.exec(xml))) {
    const attrs = m[1]
    const body = m[2]
    const attr = (name) => attrs.match(new RegExp(`${name}="([^"]*)"`))?.[1] ?? ''
    const tag = (name) => {
      const hit = body.match(new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`))
      return hit ? unescapeXML(hit[1]) : ''
    }
    const ft = attr('ft')
    const start = jstStampToEpoch(ft)
    const end = jstStampToEpoch(attr('to'))
    const title = tag('title')
    programs.push({
      id: attr('id') || ft,
      title: title || '—',
      performer: tag('pfm'),
      start,
      end,
      image: tag('img') || null,
    })
  }
  return programs
}

export async function radikoPrograms(stationID, dayOffset) {
  const date = broadcastDateString(dayOffset)
  const url = `https://radiko.jp/v3/program/station/date/${date}/${encodeURIComponent(stationID)}.xml`
  const res = await fetch(url, { headers: { 'User-Agent': BROWSER_UA } })
  if (!res.ok) throw new Error(`番組表失败：HTTP ${res.status}`)
  return parseRadikoProgramXML(await res.text())
}

// MARK: - ListenRadio 番組表 JSON

/// 已确认的真实形状（2026-08，`schedulelist.aspx?devtype=ios`）：
/// `{"ProgramList":[{"ChannelId":…,"Schedule":[{"ProgramName","ProgramSummary",
///   "StartDate":"202608240700","EndDate":"202608240900"}]}]}`
/// —— 注意 `StartDate` 是 **12 位、没有秒**。这里同时留了宽容路径：递归找「元素带时刻的
/// 字典数组」，键名按候选表 + 关键词兜底。接口哪天改了键名也还能出东西。
const TITLE_KEYS = ['ProgramName', 'ProgramTitle', 'ScheduleTitle', 'Title', 'Name']
const DETAIL_KEYS = ['ProgramSummary', 'Personality', 'Performer', 'ProgramDetail', 'Detail', 'Description']
const START_KEYS = ['StartDate', 'StartTime', 'StartDateTime', 'Start', 'OnAirStart']
const END_KEYS = ['EndDate', 'EndTime', 'EndDateTime', 'End', 'OnAirEnd']
const IMAGE_KEYS = ['ProgramLogo', 'ImageUrl', 'ImageURL', 'Logo', 'ProgramImage']

const pickKey = (row, keys, hints) => {
  for (const k of keys) if (row[k] != null && row[k] !== '') return row[k]
  for (const k of Object.keys(row)) {
    const lower = k.toLowerCase()
    if (hints.some((h) => lower.includes(h)) && row[k] != null && row[k] !== '') return row[k]
  }
  return null
}

const hasClock = (row) =>
  Object.values(row).some((v) => typeof v === 'string' && jstStampToEpoch(v) != null)

/// 递归收集像「节目行」的数组：元素是字典、且行里至少有一个能解析成时刻的值。
export function collectRows(json) {
  const groups = []
  const visit = (node) => {
    if (Array.isArray(node)) {
      const dicts = node.filter((x) => x && typeof x === 'object' && !Array.isArray(x))
      if (dicts.length === node.length && dicts.length > 0) {
        const rows = dicts.filter(hasClock)
        if (rows.length * 2 >= dicts.length && rows.length > 0) groups.push(rows)
      }
      node.forEach(visit)
    } else if (node && typeof node === 'object') {
      Object.values(node).forEach(visit)
    }
  }
  visit(json)
  if (!groups.length) return []
  // 番組表常按放送日拆成多个数组，只取最大的那一个会让别的日期整天空掉 →
  // 键名与最大分组有交集的，都算同一张表的片段，合并去重。
  const largest = groups.reduce((a, b) => (b.length > a.length ? b : a))
  const shape = new Set(Object.keys(largest[0] ?? {}).map((k) => k.toLowerCase()))
  const out = []
  const seen = new Set()
  for (const group of groups) {
    const keys = Object.keys(group[0] ?? {}).map((k) => k.toLowerCase())
    if (!keys.some((k) => shape.has(k))) continue
    for (const row of group) {
      const sig = JSON.stringify(row)
      if (seen.has(sig)) continue
      seen.add(sig)
      out.push(row)
    }
  }
  return out
}

export function programsFromRows(rows) {
  const out = []
  for (const row of rows) {
    const start = jstStampToEpoch(pickKey(row, START_KEYS, ['start', 'begin', 'from', '開始']))
    if (start == null) continue
    const end = jstStampToEpoch(pickKey(row, END_KEYS, ['end', 'finish', 'until', '終了']))
    const title = pickKey(row, TITLE_KEYS, ['title', 'name', '番組']) ?? '—'
    out.push({
      id: String(row.ProgramId ?? row.ScheduleId ?? `${start}`),
      title: String(title).trim() || '—',
      performer: String(pickKey(row, DETAIL_KEYS, ['detail', 'summary', 'cast', '出演']) ?? '').trim(),
      start,
      end,
      image: pickKey(row, IMAGE_KEYS, ['image', 'logo', 'thumb']) ?? null,
    })
  }
  return out.sort((a, b) => a.start - b.start)
}

const lrCache = new Map()

/// `LR30008` → `30008`
export const listenRadioChannel = (stationID) =>
  stationID.startsWith('LR') ? stationID.slice(2) : stationID

export async function listenRadioPrograms(stationID, dayOffset) {
  const channel = listenRadioChannel(stationID)
  const all = await loadListenRadio(channel)
  const dayStart = broadcastDayStart(dayOffset)
  const dayEnd = dayStart + 86400_000
  const slice = all.filter((p) => p.start >= dayStart && p.start < dayEnd)
  if (!slice.length && all.length) {
    // 解析出了节目却没有一档落在这一天，八成是时刻字段被解析成了别的日期。
    // 静默返回空数组就永远查不出来，所以把实际覆盖范围报出去。
    const first = jstParts(all[0].start), last = jstParts(all[all.length - 1].start)
    const fmt = (p) => `${p.year}-${p.month}-${p.day} ${p.hour}:${String(p.minute).padStart(2, '0')}`
    throw new Error(`这一天没有节目（共解析 ${all.length} 档，覆盖 ${fmt(first)} → ${fmt(last)}）`)
  }
  return slice
}

async function loadListenRadio(channel) {
  const hit = lrCache.get(channel)
  // 一次拉全（count=999 覆盖一周以上），10 分钟内不再打。
  if (hit && Date.now() - hit.at < 600_000) return hit.programs
  const variants = ['devtype=ios&', 'devtype=android&', '']
  const errors = []
  for (const extra of variants) {
    const url = `https://listenradio.jp/service/schedulelist.aspx?${extra}offset=0&count=999&channelId=${encodeURIComponent(channel)}`
    try {
      const res = await fetch(url, {
        headers: {
          'User-Agent': BROWSER_UA,
          Referer: 'https://listenradio.jp/',
          Accept: 'application/json, text/plain, */*',
        },
      })
      if (!res.ok) throw new Error(`HTTP ${res.status}`)
      const text = await res.text()
      const json = looseJSON(text)
      if (!json) throw new Error('响应不是 JSON')
      const programs = programsFromRows(collectRows(json))
      if (!programs.length) throw new Error('解析不出节目行')
      lrCache.set(channel, { at: Date.now(), programs })
      return programs
    } catch (e) {
      errors.push(`${extra || 'no devtype'}: ${e.message}`)
    }
  }
  throw new Error(`ListenRadio 番組表失败 —— ${errors.join('；')}`)
}

/// 去 BOM、剥 JSONP 外壳（`callback({…})`）之后再解析。
export function looseJSON(text) {
  const body = text.replace(/^﻿/, '').trim()
  try {
    return JSON.parse(body)
  } catch { /* 继续试剥壳 */ }
  const open = body.search(/[{[]/)
  const close = Math.max(body.lastIndexOf('}'), body.lastIndexOf(']'))
  if (open >= 0 && close > open) {
    try {
      return JSON.parse(body.slice(open, close + 1))
    } catch { /* 放弃 */ }
  }
  return null
}
