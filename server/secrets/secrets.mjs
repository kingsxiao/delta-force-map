/* ============================================================
   secrets.mjs — 每日地图密码快照（零 npm 依赖）
   ------------------------------------------------------------
   数据源（2026-11-05 双源实测对齐，6 张图 4 位密码完全一致）：
     · 主源：腾讯官方 AMS 免登录接口（WeGame 三角洲助手同款请求）
       GET https://comm.ams.game.qq.com/ide/?iChartId=430437
           &sIdeToken=xXpyy2&method=dfm%2Fcenter.day.secret
       → {ret,iRet,sMsg, jData:{data:{code,data:{list:[{mapID,mapName,secret}]}}}}
     · 兜底：moligod.com /api/daily-secrets（官方源的社区转发，形状更平，
       带 fetch_date 与 updated_at；主源维护窗口期顶上）
   官方密码北京时间每天 0 点轮换、无小时内变化——轮询 30 分钟一轮纯属
   兜「0 点轮换时刻的服务波动」，读到的内容不变就不写盘、不广播。
   位置图为官方 WeGame 助手静态资源，已下载打包进 apps/web/public/
   secrets/img/password{1..6}.jpg（season 更新可能换图，届时重新导出）；
   快照只存相对路径，mapID 1..6 之外的图如实置 null。
   产物 apps/web/public/secrets/secrets.json（+ dist 联动），契约见
   shared/API.md §1.4；SSE 事件 secrets（server.mjs 集成，仅内容变化时）。
   用法：node server/secrets/secrets.mjs [--once] [--interval 分钟=30]
   ============================================================ */
import { readFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { writeSnapshotPair } from '../ammo/fetch-once.mjs'

const OFFICIAL_URL =
  'https://comm.ams.game.qq.com/ide/?iChartId=430437&sIdeToken=xXpyy2&method=dfm%2Fcenter.day.secret'
const MOLI_URL = 'https://moligod.com/api/daily-secrets'
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

/** 本地打包的位置图相对路径（mapID 1..6 与图号一一对应；超出范围无图） */
export function secretImagePath(mapId) {
  const n = Number(mapId)
  return Number.isInteger(n) && n >= 1 && n <= 6 ? `secrets/img/password${n}.jpg` : null
}

/** 北京墙钟日期：'YYYY-MM-DD'（密码口径的「今天」，UTC+8 直加不依赖本机时区） */
export function beijingDate(iso = new Date().toISOString()) {
  const d = new Date(iso)
  const p = (n) => String(n).padStart(2, '0')
  const bj = new Date(d.getTime() + 8 * 3600 * 1000)
  return `${bj.getUTCFullYear()}-${p(bj.getUTCMonth() + 1)}-${p(bj.getUTCDate())}`
}

/* ---------- 上游解析（纯函数，selftest 覆盖） ---------- */

/**
 * 解析官方 AMS 载荷 → 统一条目 [{mapId, mapName, secret}]。
 * 只认 ret/iRet 双零 + 内层 code 0 + 非空 list；缺密码/缺名的条目丢弃，
 * 全军覆没视为解析失败（throw），让调用方走兜底源而不是落空快照。
 */
export function parseOfficialSecrets(raw) {
  const ok = raw && raw.ret === 0 && raw.iRet === 0
  const list = raw?.jData?.data?.data?.list
  if (!ok || raw?.jData?.data?.code !== 0 || !Array.isArray(list) || list.length === 0) {
    throw new Error(`官方密码接口返回异常：${JSON.stringify(raw).slice(0, 120)}`)
  }
  const items = list
    .filter((e) => e && String(e.mapName || '').trim() && String(e.secret || '').trim())
    .map((e) => ({ mapId: Number(e.mapID), mapName: String(e.mapName).trim(), secret: String(e.secret).trim() }))
  if (!items.length) throw new Error('官方密码接口 list 无有效条目（缺名或缺密码）')
  return items
}

/**
 * 解析 moligod 兜底载荷 → 同形状条目（外加 fetch_date 供 version 对齐）。
 * status !== 'ok' 或 data 空即 throw。
 */
export function parseMoligodSecrets(raw) {
  const list = raw?.data
  if (raw?.status !== 'ok' || !Array.isArray(list) || list.length === 0) {
    throw new Error(`moligod 密码接口返回异常：${JSON.stringify(raw).slice(0, 120)}`)
  }
  const items = list
    .filter((e) => e && String(e.map_name || '').trim() && String(e.secret || '').trim())
    .map((e) => ({
      mapId: Number(e.map_id),
      mapName: String(e.map_name).trim(),
      secret: String(e.secret).trim(),
      upstreamDate: String(e.fetch_date || '').trim() || null,
    }))
  if (!items.length) throw new Error('moligod 密码接口 data 无有效条目')
  return items
}

/* ---------- 整形（纯函数，selftest 覆盖） ---------- */

/**
 * 统一条目 → 契约快照。version / date 取北京墙钟（密码 0 点轮换，日期即版本）；
 * source 如实标注实际服务的源（official-ams | moligod-mirror）。条目按 mapId 升序，
 * 展示稳定且与图片编号对齐。
 */
export function buildSecretsSnapshot(entries, { fetchedAt = new Date().toISOString(), source } = {}) {
  const items = (entries || [])
    .slice()
    .sort((a, b) => a.mapId - b.mapId)
    .map((e) => ({
      mapId: e.mapId,
      mapName: e.mapName,
      secret: e.secret,
      img: secretImagePath(e.mapId),
    }))
  const date = beijingDate(fetchedAt)
  return {
    version: date.replaceAll('-', ''),
    fetchedAt,
    date,
    source: source || 'official-ams',
    items,
    stats: { total: items.length },
  }
}

/* ---------- 抓取与循环 ---------- */

async function getJson(url) {
  const res = await fetch(url, {
    headers: { 'User-Agent': UA, Accept: 'application/json', Referer: 'https://www.wegame.com.cn/' },
    signal: AbortSignal.timeout(20000), // 口径同 ams-client / craft 的 20s 挂起兜底
  })
  if (!res.ok) throw new Error(`HTTP ${res.status} ${new URL(url).host}`)
  return res.json()
}

/**
 * 抓一轮：主源官方 AMS，失败回落 moligod 镜像（source 如实切换）。
 * 与盘上快照同 version 且条目一致 → 跳过写盘（changed:false），SSE 不广播。
 * @param {{webDir?:string, fetchImpl?:Function, now?:string|Date}} opts
 *   fetchImpl 供 selftest 注入桩；now 覆盖抓取时刻（selftest 模拟跨天，生产不传）
 * @returns {Promise<{version:string, source:string, total:number, changed:boolean}>}
 */
export async function runSecretsCycle({ webDir, fetchImpl, now } = {}) {
  const get = fetchImpl || getJson
  let entries
  let source
  try {
    entries = parseOfficialSecrets(await get(OFFICIAL_URL))
    source = 'official-ams'
  } catch {
    // 主源挂了走兜底；兜底也失败就让异常上抛（循环只记日志，下一轮自然补）
    entries = parseMoligodSecrets(await get(MOLI_URL))
    source = 'moligod-mirror'
  }
  const out = buildSecretsSnapshot(entries, { fetchedAt: now, source })
  const dir = webDir || process.cwd()
  // 内容不变不写盘：日更数据 30 分钟一轮的轮询里，99% 的轮次都该是空转
  const prev = await readSnapshot(dir).catch(() => null)
  const same =
    prev &&
    prev.version === out.version &&
    JSON.stringify(prev.items) === JSON.stringify(out.items)
  if (!same) await writeSnapshotPair(dir, path.join('secrets', 'secrets.json'), JSON.stringify(out))
  return { version: out.version, source, total: out.stats.total, changed: !same }
}

async function readSnapshot(webDir) {
  const pub = path.join(webDir, 'public', 'secrets', 'secrets.json')
  return JSON.parse(await readFile(pub, 'utf8'))
}

/* ---------- CLI：单跑 / 常驻监控（selftest import 时不执行） ---------- */

const IS_CLI =
  process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)

if (IS_CLI) {
  const argv = process.argv.slice(2)
  const INTERVAL_MIN = argv.includes('--interval') ? Number(argv[argv.indexOf('--interval') + 1]) || 30 : 30
  const ONCE = argv.includes('--once')
  const WEB_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../apps/web')

  async function cycle() {
    try {
      const r = await runSecretsCycle({ webDir: WEB_DIR })
      console.log(
        `[${new Date().toLocaleString('zh-CN')}] ${r.version} · ${r.total} 张图 · 源 ${r.source}${r.changed ? ' · 已更新' : ' · 未变化'}`,
      )
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] 每日密码抓取失败: ${e.message}`)
    }
  }

  if (ONCE) {
    await cycle()
  } else {
    console.log(`每日密码快照监控启动：每 ${INTERVAL_MIN} 分钟一轮（Ctrl+C 退出）`)
    await cycle()
    const schedule = () => setTimeout(async () => { await cycle(); schedule() }, INTERVAL_MIN * 60 * 1000)
    schedule()
  }
}
