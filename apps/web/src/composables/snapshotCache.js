/* ============================================================
   snapshotCache.js — 行情快照的会话级内存缓存（URL → 快照对象）
   ------------------------------------------------------------
   /ammo 与 /ttk 消费同一份 ammo/market.json（约 400KB）：弹药页随
   轮询 / SSE 已拉到的快照直接内存复用给 TTK 页，省一次全量下载；
   反向（先访 TTK 再进弹药页）也成立——弹药页的刷新链路不受缓存
   影响（拉取照发，结果覆写缓存），缓存只消灭「同一份快照的重复
   整包下载」。
   快照顶层 fingerprint（数据管道写入的内容指纹，见
   server/ammo/fetch-once.mjs）顺带充当协商缓存验证符：
   useSnapshotFeed 携 If-None-Match 重询，部署形态（server.mjs 以
   fingerprint 为 ETag）内容未变即回 304、免整包下发。缓存无 TTL
   ——会话级复用，新鲜度由各消费方按快照 fetchedAt 如实标注。
   ============================================================ */

/** url → { json }（fingerprint 就在 json 顶层，不另存一份防漂移） */
const cache = new Map()

/** 读会话缓存（未拉过返回 null）。返回同一对象引用，消费方只读不改 */
export function peekSnapshot(url) {
  return cache.get(url)?.json ?? null
}

/** 快照写入会话缓存（整包 200 拉到后调用；304 复用旧值无需重写） */
export function storeSnapshot(url, json) {
  if (json && typeof json === 'object') cache.set(url, { json })
}

/** 当前缓存可用的协商验证符（快照顶层 fingerprint 的带引号 ETag 形态）。
    无指纹的快照（radar / craft 暂无该字段）返回 null——对应请求不带
    If-None-Match，与无 ETag 能力的服务行为一致 */
export function snapshotEtag(url) {
  const fp = cache.get(url)?.json?.fingerprint
  return typeof fp === 'string' && fp ? `"${fp}"` : null
}
