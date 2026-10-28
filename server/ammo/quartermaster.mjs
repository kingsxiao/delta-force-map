/* ============================================================
   quartermaster.mjs — 军需处兑换子弹数据（kkrb getTradeAmmoData，TTL 缓存）
   ------------------------------------------------------------
   上游：kkrb「军需处兑换子弹利润」页的数据接口，返回可兑换弹种的
   材料清单（含市价）、折算成本与交易行现价——军需处兑换是弹价的地板
   之一：现价远高于材料折算价时先扫军需处（见 Playbook 01「军需处倒挂」）。
   国服数据（data.cn，约 7 种可兑换弹）；international 为国际服，不消费。
   模块级 TTL 缓存：上游分钟级更新，10 分钟足够新鲜且把请求压到约
   6 次/小时；由 fetch-once 在每次抓取时调用（join 进 market.json 的
   items[].trade），失败如实抛出、调用方静默跳过——军需处参照永不阻塞
   主行情链路（口径同 official-anchor join）。
   ============================================================ */
import { kkrbRequest } from './kkrb-client.mjs'

/** 缓存时长（ms） */
export const QUARTERMASTER_TTL_MS = 10 * 60 * 1000

let cache = null // { at: number, data: object }

/**
 * 清洗单条兑换行（纯函数，selftest 用）：只留 join 与展示需要的字段，
 * 数值非有限数的材料剔除；材料清单原样保留（展示「拿什么换」要用）。
 * @param {object} raw getTradeAmmoData data.cn 的一行
 * @returns {{name:string, perCount:number, costPerRound:number, marketPrice:number,
 *            materials:{name:string,count:number,perPrice:number}[], version:string}|null}
 */
export function normalizeTradeRow(raw, version = '') {
  if (!raw || typeof raw !== 'object') return null
  const name = typeof raw.itemName === 'string' ? raw.itemName : ''
  const perCount = Math.round(Number(raw.perCount))
  const totalMaterialValue = Number(raw.totalMaterialValue)
  const marketPrice = Number(raw.singlePrice)
  if (!name || !Number.isFinite(perCount) || perCount < 1) return null
  if (!Number.isFinite(totalMaterialValue) || totalMaterialValue < 0) return null
  if (!Number.isFinite(marketPrice) || marketPrice <= 0) return null
  const materials = (Array.isArray(raw.totalMaterialLists) ? raw.totalMaterialLists : [])
    .map((m) => ({
      name: typeof m?.itemName === 'string' ? m.itemName : '',
      count: Math.round(Number(m?.count)),
      perPrice: Number(m?.perPrice),
    }))
    .filter((m) => m.name && Number.isFinite(m.count) && m.count >= 1 && Number.isFinite(m.perPrice) && m.perPrice >= 0)
  return {
    name,
    perCount,
    costPerRound: Math.round((totalMaterialValue / perCount) * 100) / 100,
    marketPrice,
    materials,
    version,
  }
}

/**
 * 拉取军需处兑换数据（带 TTL 缓存）。
 * @param {{force?:boolean, now?:number, request?:Function}} opts
 *   request 可注入替身（离线自测），默认 kkrbRequest
 * @returns {Promise<{version:string, fetchedAt:string, items:Array}|null>}
 *   形状异常当轮抛出并缓存空结果，TTL 内后续调用返回 null（join 侧跳过）
 * @throws 上游失败（调用方决定静默跳过 join）
 */
export async function fetchQuartermaster({ force = false, now = Date.now(), request = kkrbRequest } = {}) {
  if (!force && cache && now - cache.at < QUARTERMASTER_TTL_MS) return cache.data
  const j = await request('getTradeAmmoData', { referer: 'https://www.kkrb.net/?viewpage=view%2Fdepartment%2Ftrade_ammo' })
  const rows = j?.data?.cn
  if (!Array.isArray(rows)) {
    cache = { at: now, data: null } // 形状变了：缓存空结果，别每轮重打上游（口径同 season.mjs）
    throw new Error('getTradeAmmoData 形状异常（data.cn 非数组）')
  }
  const version = typeof j.version === 'string' ? j.version : ''
  const data = {
    version,
    fetchedAt: new Date().toISOString(),
    items: rows.map((r) => normalizeTradeRow(r, version)).filter(Boolean),
  }
  cache = { at: now, data }
  return data
}

/** 仅供测试：清空模块级缓存 */
export function resetQuartermasterCacheForTest() { cache = null }
