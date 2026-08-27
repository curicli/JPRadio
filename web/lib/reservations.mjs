// 预约录制。与 iOS 端 `ios/JPRadio/Recording/ReservationStore.swift` 同源，但**执行策略更简单**，
// 因为这里的前提不一样：iOS 上 App 随时会被杀掉，web 版的前提是这个 Node 进程一直开着。
//
//   - **radiko 台：不实时录，等节目播完直接下 タイムフリー。** 存档是最完整的一份
//     （iOS 端也优先用它），而且这样预约期间不多占一份带宽；进程在节目播出时没开着
//     也没关系 —— 下次启动对账时补下来即是。代价是**radiko 关掉 タイムフリー 的那些节目
//     录不到**（会以 `failed` 加上原因入账，不会假装成功）。
//   - **ListenRadio（直连台）：只能实时录。** 它没有任何存档，进程没开着就是真的错过了
//     （状态 `missed`）。
//
// 状态机：
//   pending  ──正在播出（直连台）──> recording ──播完──> completed / missed
//   pending  ──播完（radiko）────> fetching   ──────> completed / failed
//                                      └─ 取不到就退回 pending，5 分钟后再试，6 次放弃
//
// `note` 一定要写：「没录到」如果不带 HTTP 状态或失败在哪一步，事后永远查不出来
// （iOS 端为这个专门在预约行上显示原因，这里照搬）。

import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

const FILE = 'reservations.json'

export const RETRY_DELAY_MS = 300_000
export const MAX_ATTEMPTS = 6
/// 已经结束很久的预约就别再试了：radiko 的存档只有一周。
export const GIVE_UP_AFTER_MS = 7 * 86400_000

const DONE = new Set(['completed', 'failed', 'missed'])

export function reservation({ id, stationID, stationName, areaID, direct, title, start, end, status, note }) {
  return {
    id, stationID, stationName, areaID: areaID ?? null,
    direct: !!direct,
    title: title ?? '',
    start, end,
    status: status ?? 'pending',
    note: note ?? null,
  }
}

export class Reservations {
  #dir
  #items = []
  /// 只活在内存里的重试账（重启即清零，跟 iOS 端一样 —— 重启本身就该再试一次）。
  #attempts = new Map()
  #retryAfter = new Map()

  constructor(dir) {
    this.#dir = dir
  }

  list() { return this.#items }
  get(id) { return this.#items.find((r) => r.id === id) ?? null }
  attempts(id) { return this.#attempts.get(id) ?? 0 }

  async open() {
    await mkdir(this.#dir, { recursive: true })
    try {
      const raw = JSON.parse(await readFile(join(this.#dir, FILE), 'utf8'))
      const list = Array.isArray(raw?.reservations) ? raw.reservations : []
      this.#items = list.filter((r) => r?.id && Number.isFinite(r?.start) && Number.isFinite(r?.end))
                        .map(reservation)
      // 进程上次退出时正卡在中间状态的，回到 pending 让对账重新决定 ——
      // 「录制中」「获取中」都是内存里的事实，重启之后不再成立。
      for (const r of this.#items) if (!DONE.has(r.status)) r.status = 'pending'
    } catch (e) {
      if (e?.code !== 'ENOENT') console.error(`[预约] ${FILE} 读不出来：${e?.message ?? e}`)
      this.#items = []
    }
    this.#sort()
    return this
  }

  #sort() { this.#items.sort((a, b) => a.start - b.start) }

  /// 加一条。id 用节目 id（番組表里要靠它判「已预约」）；自定义时段自己造一个。
  /// 重复预约同一档直接返回原来那条，不报错。
  async add(fields) {
    const existing = this.get(fields.id)
    if (existing) return existing
    const r = reservation(fields)
    this.#items.push(r)
    this.#sort()
    await this.persist()
    return r
  }

  async remove(id) {
    const before = this.#items.length
    this.#items = this.#items.filter((r) => r.id !== id)
    this.#attempts.delete(id)
    this.#retryAfter.delete(id)
    if (this.#items.length === before) return false
    await this.persist()
    return true
  }

  async setStatus(id, status, note = null) {
    const r = this.get(id)
    if (!r) return null
    r.status = status
    r.note = note
    await this.persist()
    return r
  }

  /// 取存档失败了：还有额度就退回 pending 等下一轮，用完就 failed。
  /// 返回 true 表示「还会再试」。
  async backoff(id, note, now = Date.now()) {
    const r = this.get(id)
    if (!r) return false
    const n = this.attempts(id) + 1
    this.#attempts.set(id, n)
    this.#retryAfter.set(id, now + RETRY_DELAY_MS)
    const expired = now - r.end > GIVE_UP_AFTER_MS
    if (n >= MAX_ATTEMPTS || expired) {
      await this.setStatus(id, 'failed', expired ? `${note}（存档已过期，不再重试）` : note)
      return false
    }
    await this.setStatus(id, 'pending', `${note}（第 ${n} 次，5 分钟后重试）`)
    return true
  }

  /// 这一轮对账该动哪些。`live` 是要开实时录的（只有直连台），`archive` 是要下存档的。
  plan(now = Date.now()) {
    const live = []
    const archive = []
    for (const r of this.#items) {
      if (DONE.has(r.status)) continue
      if (now < r.start) continue
      if (now < r.end) {
        // 正在播出：直连台必须实时录，radiko 等播完下存档（见文件头）。
        if (r.direct && r.status === 'pending') live.push(r)
        continue
      }
      if (r.status === 'recording' || r.status === 'fetching') continue
      if ((this.#retryAfter.get(r.id) ?? 0) > now) continue
      if (r.direct) continue        // 直连台播完了还是 pending，说明整段都没开着 → 由调用方判 missed
      archive.push(r)
    }
    return { live, archive, missed: this.#missed(now) }
  }

  /// 直连台的节目已经播完、却一片都没录到 —— 真的错过了，没有补救办法。
  #missed(now) {
    return this.#items.filter((r) => r.direct && !DONE.has(r.status) && now >= r.end && r.status !== 'recording')
  }

  async persist() {
    await mkdir(this.#dir, { recursive: true })
    await writeFile(
      join(this.#dir, FILE),
      JSON.stringify({ version: 1, reservations: this.#items }, null, 2),
    )
  }
}
