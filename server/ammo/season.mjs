/* ============================================================
   season.mjs — 赛季日历（kkrb getActivityCalendarData，TTL 缓存）
   ------------------------------------------------------------
   上游：kkrb「活动日历」接口，给当前赛季的名称与起止时间（ISO-8601
   带时区，国服口径）+ 赛季内活动列表。赛季起止驱动 Playbook「版本与
   赛季窗口」的倒计时与阶段判定（囤货窗 T−7~T−3 / 赛季末 T−3 / 开更
   出货窗 +3 天，phase 计算在 shared/js/marketMeta.js seasonPhase）。
   模块级 TTL 缓存 6 小时：日历按天变化，一轮抓取周期内基本恒定；
   由 fetch-once 调用并 join 进 market.json 顶层 season，失败静默跳过
   （口径同 official-anchor / quartermaster join，永不阻塞主链路）。
   ============================================================ */
import { kkrbRequest } from './kkrb-client.mjs'

/** 缓存时长（ms） */
export const SEASON_TTL_MS = 6 * 60 * 60 * 1000

let cache = null // { at: number, data: object }

/** ISO-8601 字串校验（Date.parse 可解析且有限） */
function validIso(s) {
  return typeof s === 'string' && Number.isFinite(Date.parse(s)) ? s : null
}

/**
 * 拉取赛季日历（带 TTL 缓存）。
 * @param {{force?:boolean, now?:number, request?:Function}} opts
 *   request 可注入替身（离线自测），默认 kkrbRequest
 * @returns {Promise<{name:string, start:string, end:string, fetchedAt:string,
 *            events:{name:string,start:string,end:string,type:string}[]}|null>}
 *   无有效赛季起止（上游改版）时返回 null——调用方按无数据跳过 join
 * @throws 上游网络失败
 */
export async function fetchSeason({ force = false, now = Date.now(), request = kkrbRequest } = {}) {
  if (!force && cache && now - cache.at < SEASON_TTL_MS) return cache.data
  const j = await request('getActivityCalendarData', { referer: 'https://www.kkrb.net/?viewpage=view%2Factivity%2Fact_calendar' })
  const d = j?.data
  const name = typeof d?.seasonName === 'string' ? d.seasonName : ''
  const start = validIso(d?.seasonStartTime)
  const end = validIso(d?.seasonEndTime)
  if (!name || !start || !end || Date.parse(start) >= Date.parse(end)) {
    cache = { at: now, data: null } // 形状变了：缓存空结果，别每轮重打上游
    return null
  }
  const events = (Array.isArray(d.seasonEvent) ? d.seasonEvent : [])
    .map((e) => ({
      name: typeof e?.name === 'string' ? e.name : '',
      start: validIso(e?.start),
      end: validIso(e?.end),
      type: typeof e?.type === 'string' ? e.type : '',
    }))
    .filter((e) => e.name && e.start && e.end)
    .slice(0, 30)
  const data = { name, start, end, fetchedAt: new Date().toISOString(), events }
  cache = { at: now, data }
  return data
}

/** 仅供测试：清空模块级缓存 */
export function resetSeasonCacheForTest() { cache = null }
