// 录制：把一串 HLS 分片接成一个能直接播的本地文件。
//
// 与 iOS 端 `ios/JPRadio/Recording/RadioRecorder.swift` 的 `SegmentWriter` 同源，三条规矩照搬
// （都是真机上踩出来的）：
//
// 1. **容器要按第一个分片的内容判，不能按扩展名。** radiko 的分片是裸 ADTS AAC
//    （首尾相接就是一个能播的 .aac），ListenRadio 的是 MPEG-TS —— TS 直接拼出来的文件
//    浏览器和 QuickTime 都放不了，必须先抽出 AAC 基本流（`lib/adts.mjs`，识曲已经在用
//    同一份实现）。上游哪天换了容器，判错的表现是「文件在那儿但打不开」，很难查。
// 2. **文件在拿到第一个分片之后才建**：一次失败的录制不该留下 0 字节的空壳，
//    而且扩展名在那之前根本还不知道。
// 3. **裸 ADTS 没有时长索引**，播放器只能按码率估。所以时长由这里按 `#EXTINF` 累加、
//    写进元数据，界面显示的是这个数，不问播放器要。
//
// 这个文件不碰网络也不认识 radiko：分片怎么取（加什么头、要不要重新鉴权）由
// `server.mjs` 用 `fetchBytes` / `pull` 两个回调注入 —— 于是它能单独自检。

import { open, unlink } from 'node:fs/promises'
import { join } from 'node:path'
import { looksLikeTS, tsToADTS } from './adts.mjs'
import { mapPool } from './pool.mjs'

/// 分片容器 → 落盘扩展名。TS 拆出来的是裸 ADTS，所以也是 .aac。
export const CONTAINER_EXT = { adts: '.aac', ts: '.aac', mp4: '.m4a', raw: '.aac' }

/// 看内容判容器。`raw` 是「认不出来」：照原样拼，至少不比丢掉更差。
export function sniff(bytes) {
  if (!bytes || bytes.length < 4) return 'raw'
  if (looksLikeTS(bytes)) return 'ts'
  if (bytes.length >= 8) {
    const tag = String.fromCharCode(bytes[4], bytes[5], bytes[6], bytes[7])
    if (tag === 'ftyp' || tag === 'styp' || tag === 'moof' || tag === 'moov' || tag === 'sidx') {
      return 'mp4'
    }
  }
  // ADTS 同步字是 12 个 1，紧跟的 layer 两位必须是 00（AAC 没有 layer）。
  if (bytes[0] === 0xff && (bytes[1] & 0xf6) === 0xf0) return 'adts'
  if (bytes[0] === 0x49 && bytes[1] === 0x44 && bytes[2] === 0x33) return 'adts'  // ID3 前缀
  return 'raw'
}

/// 一次录制的落盘器。
///
/// 容器与文件名在**第一个非空分片**到手时才定下来（见文件头第 1、2 条）。
/// `append` 返回 false 表示这一片没能写进去（拆不出音频流），调用方据此决定是不是要报错。
export class SegmentWriter {
  #dir
  #base
  #handle = null
  #container = null
  #ext = ''
  #bytes = 0
  #seconds = 0

  /// @param dir  录音目录（必须已存在）
  /// @param base 文件名主干（不含扩展名），一般就是录音 id
  constructor(dir, base) {
    this.#dir = dir
    this.#base = base
  }

  get container() { return this.#container }
  get bytes() { return this.#bytes }
  get seconds() { return this.#seconds }
  /// 还没写过任何东西时是 null —— 此时磁盘上也还没有文件。
  get file() { return this.#container ? this.#base + this.#ext : null }
  get path() { return this.file ? join(this.#dir, this.file) : null }

  async append(chunk, duration = 0) {
    if (!chunk || !chunk.length) return false
    if (!this.#container) {
      this.#container = sniff(chunk)
      this.#ext = CONTAINER_EXT[this.#container] ?? '.aac'
      this.#handle = await open(join(this.#dir, this.#base + this.#ext), 'w')
    }
    // TS 是**逐片**拆的：HLS 要求每个 TS 分片自带 PAT/PMT，所以每片都能独立拆开，
    // 不必等整段下完（也就不必把两小时的节目堆在内存里）。
    const body = this.#container === 'ts' ? Buffer.from(tsToADTS(chunk)) : Buffer.from(chunk)
    if (!body.length) return false
    await this.#handle.write(body)
    this.#bytes += body.length
    this.#seconds += duration
    return true
  }

  /// 收尾。一个字节都没写过就返回 null（磁盘上没有文件要收）。
  async finish() {
    if (!this.#handle) return null
    await this.#handle.close()
    this.#handle = null
    return {
      file: this.file,
      path: this.path,
      bytes: this.#bytes,
      seconds: Math.round(this.#seconds),
      container: this.#container,
    }
  }

  /// 放弃这次录制：关掉句柄并删掉半截文件。
  async discard() {
    const done = await this.finish()
    if (done) await unlink(done.path).catch(() => {})
    return null
  }
}

/// 顺序下载并写入一串**已知**的分片（タイムフリー 存档下载 / 预约补录）。
///
/// 分批取：一批 8 个并发、按序写盘。全量 `mapPool` 也能跑，但两小时的节目会先在内存里
/// 堆出四五十兆 —— 这个进程同时还在给播放器转发 HLS，没必要。
///
/// 只要有一片写进去了就算成功；一片都没有才抛（原因带上第一个失败的分片，
/// 否则「没录到」永远查不出是鉴权、播放列表还是分片挂了 —— 与 iOS 端同一条教训）。
export async function writeAll({ segments, fetchBytes, writer, init, onProgress, isCancelled, batch = 8 }) {
  // fMP4 的初始化段（`#EXT-X-MAP`）必须排在所有分片之前，缺了它整个文件解不开。
  if (init) await writer.append(await fetchBytes(init), 0)

  let firstError = null
  for (let at = 0; at < segments.length; at += batch) {
    if (isCancelled?.()) break
    const slice = segments.slice(at, at + batch)
    const parts = await mapPool(slice, batch, async (seg) => {
      try {
        return await fetchBytes(seg)
      } catch (e) {
        firstError ??= e
        return null
      }
    })
    for (let i = 0; i < slice.length; i++) {
      if (parts[i]) await writer.append(parts[i], slice[i].duration)
    }
    onProgress?.({ done: Math.min(at + batch, segments.length), total: segments.length, seconds: writer.seconds })
  }
  if (!writer.bytes) {
    throw new Error(firstError ? `分片全部取不到：${firstError.message ?? firstError}` : '没有取到任何分片')
  }
  return writer
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

/// 实时抓流：反复问 `pull()` 要当前 chunklist 的分片，没见过的就接到文件后面。
///
/// **第一轮只取最后一片。** chunklist 里通常挂着 25~30 秒已经播过的音频，按下「录制」
/// 却从半分钟前开始，听起来像录错了；预约录制更要求贴着节目开头。
///
/// **`pull()` 失败要能忍。** radiko 直播的 chunklist 背后是个会话，网抖一下或者会话过期
/// 都会取不到 —— 但录着的这条文件不该因此作废（重建会话是 `pull()` 自己的事，
/// 见 server.mjs 的 `livePull`）。连续失败到上限才收手，并把原因带回去。
export async function captureLive({
  pull, fetchBytes, writer, isCancelled, onProgress,
  pollMS = 4000, maxFailures = 8, maxSeconds = Infinity,
}) {
  const seen = new Set()
  let failures = 0
  let lastError = null
  let first = true

  while (!isCancelled?.() && writer.seconds < maxSeconds) {
    let batch = null
    try {
      batch = await pull()
      failures = 0
    } catch (e) {
      lastError = e
      if (++failures >= maxFailures) break
      await sleep(pollMS)
      continue
    }
    const list = batch?.segments ?? []
    if (first) {
      // 只留最后一片，其余当成「已经见过」。
      for (const seg of list.slice(0, -1)) seen.add(seg.url)
      if (batch?.init) await writer.append(await fetchBytes(batch.init).catch(() => null), 0)
      first = false
    }
    for (const seg of list) {
      if (seen.has(seg.url) || isCancelled?.()) continue
      seen.add(seg.url)
      try {
        await writer.append(await fetchBytes(seg), seg.duration)
      } catch (e) {
        lastError = e                                   // 掉一片就掉一片，别把整条录音废掉
      }
    }
    onProgress?.({ seconds: writer.seconds, bytes: writer.bytes })
    if (isCancelled?.() || writer.seconds >= maxSeconds) break
    await sleep(pollMS)
  }
  return { seconds: writer.seconds, bytes: writer.bytes, note: writer.bytes ? null : errorNote(lastError) }
}

const errorNote = (e) => (e ? String(e.message ?? e) : '没有取到任何分片')
