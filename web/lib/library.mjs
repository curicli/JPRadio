// 录音库：磁盘上的录音文件 + 一份元数据 JSON。
//
// 与 iOS 端 `ios/JPRadio/Recording/RecordingStore.swift` 同源，两条要紧的规矩照搬：
//
// 1. **时长不问播放器要。** 录下来的裸 ADTS 没有时长索引，浏览器只能按码率估，
//    所以录的时候按 `#EXTINF` 累加、存进元数据，界面显示这个数。
// 2. **元数据读不出来时绝不删文件。** `load()` 只在 JSON **成功解析**之后才去清理
//    没有元数据对应的孤儿文件；解析失败（磁盘写坏、手改坏了）就当成「一条都没有」
//    并把清理跳过 —— 宁可留着一堆孤儿文件，也绝不误删用户的录音。
//
// 目录默认是 `web/recordings/`，可以用 `--rec-dir` 换（录音会占空间，放外挂盘上很正常）。

import { mkdir, readFile, writeFile, readdir, unlink, stat } from 'node:fs/promises'
import { join } from 'node:path'

const META = 'recordings.json'

/// 元数据一条录音。`seconds` / `bytes` 是录的时候数出来的，`note` 记降级原因
/// （比如「存档取不到，入库的是实时录的那份」）—— 否则「录得不对」永远查不出所以然。
export function entry({ id, title, stationID, stationName, source, date, seconds, bytes, file, container, note }) {
  return {
    id, title, stationID, stationName,
    source: source === 'timefree' ? 'timefree' : 'live',
    date: date ?? Date.now(),
    seconds: seconds ?? 0,
    bytes: bytes ?? 0,
    file, container: container ?? null,
    note: note ?? null,
  }
}

export class Library {
  #dir
  #items = []
  #ok = false          // 元数据这一轮读成功了吗（决定敢不敢清孤儿文件）

  constructor(dir) {
    this.#dir = dir
  }

  get dir() { return this.#dir }
  /// 新的在前（与 iOS 端 `add` 插到 index 0 一致）。
  list() { return this.#items }
  get(id) { return this.#items.find((r) => r.id === id) ?? null }
  pathFor(rec) { return join(this.#dir, rec.file) }

  async open() {
    await mkdir(this.#dir, { recursive: true })
    await this.load()
    return this
  }

  async load() {
    let raw
    try {
      raw = JSON.parse(await readFile(join(this.#dir, META), 'utf8'))
    } catch (e) {
      // 文件不存在是全新安装，正常；解析失败是坏了 —— 两种都别清理，见文件头第 2 条。
      this.#items = []
      this.#ok = e?.code === 'ENOENT'
      if (!this.#ok) console.error(`[录音库] ${META} 读不出来，这一轮不清理孤儿文件：${e?.message ?? e}`)
      return this.#items
    }
    const list = Array.isArray(raw?.recordings) ? raw.recordings : []
    // 元数据在、文件没了（用户自己删了）就不再列出来。
    const alive = []
    for (const r of list) {
      if (!r?.id || !r?.file) continue
      try {
        await stat(join(this.#dir, r.file))
        alive.push(entry(r))
      } catch { /* 文件不在了 */ }
    }
    this.#items = alive
    this.#ok = true
    if (alive.length !== list.length) await this.persist()
    await this.purgeOrphans()
    return this.#items
  }

  /// 没有元数据对应的音频文件（录到一半进程被杀之类）。**只在元数据读成功之后才做。**
  async purgeOrphans() {
    if (!this.#ok) return 0
    const known = new Set(this.#items.map((r) => r.file))
    let gone = 0
    for (const name of await readdir(this.#dir).catch(() => [])) {
      if (name === META || known.has(name)) continue
      if (!/\.(aac|m4a|ts|mp3)$/i.test(name)) continue      // 只碰音频文件，别动别人的东西
      await unlink(join(this.#dir, name)).catch(() => {})
      gone++
    }
    if (gone) console.log(`[录音库] 清掉 ${gone} 个没有元数据的音频文件`)
    return gone
  }

  async add(rec) {
    const item = entry(rec)
    this.#items.unshift(item)
    await this.persist()
    return item
  }

  /// 先删文件再删元数据：反过来的话文件会变成孤儿，而 `purgeOrphans` 要等下次启动。
  async remove(id) {
    const hit = this.get(id)
    if (!hit) return false
    await unlink(this.pathFor(hit)).catch(() => {})
    this.#items = this.#items.filter((r) => r.id !== id)
    await this.persist()
    return true
  }

  async persist() {
    await mkdir(this.#dir, { recursive: true })
    await writeFile(
      join(this.#dir, META),
      JSON.stringify({ version: 1, recordings: this.#items }, null, 2),
    )
  }
}
