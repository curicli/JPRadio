// 有并发上限的 map。
//
// タイムフリー 要把一档节目切成 300 秒一个的窗口分别去取（radiko 一次最多给这么多），
// 一档两小时的节目就是 24 个窗口、48 个请求：串行要半分钟以上，全部一起放出去又会
// 被上游掐。所以固定几条并发慢慢啃。
//
// **顺序必须原样保留** —— 拼出来的是一条 VOD playlist，分片顺序错了就是音频错乱，
// 而且这种错听起来像「上游给的数据不对」，极难查。所以结果按下标回填，
// 不是谁先回来算谁的。

/**
 * @template T, R
 * @param {T[]} items
 * @param {number} limit  同时在跑的最大条数（至少 1）
 * @param {(item: T, index: number) => Promise<R>} fn
 * @returns {Promise<R[]>} 与 items 一一对应、顺序一致
 */
export async function mapPool(items, limit, fn) {
  const out = new Array(items.length)
  let next = 0
  const worker = async () => {
    while (next < items.length) {
      const i = next++
      out[i] = await fn(items[i], i)
    }
  }
  const workers = Math.max(1, Math.min(Math.trunc(limit) || 1, items.length))
  await Promise.all(Array.from({ length: workers }, worker))
  return out
}
