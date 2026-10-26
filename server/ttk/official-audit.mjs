/* ============================================================
   official-audit.mjs — TTK 数据官方对账（npm run ttk:audit，手动赛季级 CLI）
   ------------------------------------------------------------
   目的：把 apps/web/src/data/ttk/{guns,calibers,armor}.js 从「无对账纯人工」
   升级为「官方 diff 驱动」。本脚本只报告差异，绝不改任何数值文件；改数走
   人工：改三件套 → npm run export:ios → swift test。不加常驻循环。
   数据源（全部免登录 / 静态 JSON；两处 24h 磁盘缓存，/data/ 整体 gitignore）：
     · 官方 AMS object.list（server/official/object-directory.mjs，gun/ammo/
       protect 共 3 请求，缓存 data/official/object-directory.json）
     · dfttk v3 manifest + catalog/weapons.json（2 请求；weapons.json 按
       manifest 的 sha256 校验，不符只告警；缓存 data/dfttk/weapons-cache.json。
       仓库约定避免对 dfttk 产生持续流量，见 server/dfttk/snapshot-balance.mjs）
       ——只作 diff 条目第三列参考，不参与判定
   对账口径（先读本地字段语义再定；官方值一律折算到本地口径后并列）：
     枪械 join 键：本地 img = 官方 objectID。dmg↔meatHarm、admg↔armorHarm、
       rpm↔fireSpeed、mag↔capacity、cal↔caliber。
       - 霰弹枪（cls sg）本地面板为 8 弹丸合计，官方 / dfttk 为单弹丸：官方值
         ×弹丸数（取 dfttk projectileCount，缺省 8）后再比，note 记原值
       - 三连发（burst）本地面板自述为含 burst 间隔的持续均值，与官方 fireSpeed /
         dfttk displayFireRateRpm 同口径 → 直接比，note 附 dfttk burst 内射速
       - cal：官方 caliber 是松散字符串（ammo5.56x45 / 5.7x28mm / .45ACP /
         ammo.45 …），normCaliber 归一后查 CAL_OFFICIAL_TOKENS；编码未登记的
         进 noted 只记录不判错
     弹药 按名匹配（本地 calibers.js 无 objectID）：候选 = AMMO_PREFIX[cal] + n
       归一化（* × → x、毫米 → mm、去空白与连字符、去零宽）对官方 objectName；
       个别不规则命名走 AMMO_NAME_ALIAS。pen↔penetrationLevel（官方 null =
       本地 0）；flesh↔harmRatio/100（官方为百分比）。12ga 独头 / 单弹丸弹本地
       flesh 已折算「1 弹丸 vs 8 弹丸」，与官方单弹丸口径不可直接比 → noted。
       匹配不上（含官方同名多条歧义）进 unmatched。
     护甲 本地 DUR / HEAD_DUR 逐级 vs 官方 secondClass armor / helmet 同级全部
       型号 durability 区间：区间外进 diff；每级区间与型号完整记录在
       armor.levels；bag / chest 无 protectLevel 不参与。
   产物：apps/web/public/data/ttk-audit.json（apps/web/dist/data 目录存在时同
         内容双写，参照 server/ammo/fetch-once.mjs）。形状：
     { source:{official,dfttk}, fetchedAt,
       guns:{checked,matched,diff[],noted[]}, ammo:{同}, armor:{checked,matched,diff[],levels[]},
       unmatched:{guns[],ammo[],armor[]} }
     diff / noted 条目：{zh,objectID,field,local,official,dfttk,note?}
     checked = 成功 join 的本地条目数；matched = 其中 diff 为零者；noted 不影响 matched。
   CLI 末行：SUMMARY {"guns":{checked,matched,diff},"ammo":{…},"armor":{…},
             "unmatched":N,"top":["枪名 字段 本地X→官方Y",…≤10]}
   protect 抓取失败不阻塞 gun/ammo（armor 段 checked=0，source.official.protectError）；
   dfttk 失败只告警（source.dfttk=null，dfttk 列为 null）。
   用法：node server/ttk/official-audit.mjs [--force]   （--force 绕过两处缓存重抓）
   ============================================================ */
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { getDirectory } from '../official/object-directory.mjs'
import { writeJsonAtomic } from '../ammo/fetch-once.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const WEB_DIR = path.join(ROOT, 'apps', 'web')

/* ---------- dfttk v3 加载（24h 磁盘缓存） ---------- */

export const DFTTK_MANIFEST_URL = 'https://dfttk.com/data/v3/manifest.json'
export const DFTTK_WEAPONS_URL = 'https://dfttk.com/data/v3/catalog/weapons.json'
export const DFTTK_TTL_MS = 24 * 60 * 60 * 1000
const DFTTK_CACHE_REL = path.join('data', 'dfttk', 'weapons-cache.json')
const REQUEST_TIMEOUT_MS = 20000

async function fetchBytes(fetchFn, url) {
  let res
  try {
    res = await fetchFn(url, { headers: { accept: 'application/json' }, signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) })
  } catch (e) {
    throw new Error(`GET ${url} 失败: ${e.message}`)
  }
  const buf = Buffer.from(await res.arrayBuffer())
  if (!res.ok) throw new Error(`GET ${url} → HTTP ${res.status}: ${buf.toString('utf8').slice(0, 120)}`)
  return buf
}

/** 在 manifest.files（数组或 path→entry 映射）里找 fileName 对应的 sha256（找不到返回 null） */
export function findManifestSha256(manifest, fileName) {
  const files = manifest?.files
  let entries = []
  if (Array.isArray(files)) entries = files
  else if (files && typeof files === 'object') {
    entries = Object.entries(files).map(([k, v]) => (v && typeof v === 'object' ? { path: k, ...v } : { path: k, sha256: v }))
  }
  for (const e of entries) {
    const p = String(e?.path ?? e?.name ?? e?.file ?? e?.url ?? '')
    if (!p.includes(fileName)) continue
    const h = e?.sha256 ?? e?.hash ?? e?.sha ?? null
    return h ? String(h).toLowerCase().replace(/^sha256[:-]/, '') : null
  }
  return null
}

/**
 * dfttk v3：manifest + catalog/weapons.json（2 请求；缓存命中则零请求）。
 * @returns {Promise<{fetchedAt:string, fromCache:boolean, manifest:object, weapons:object,
 *   sha256:{expected:string|null, actual:string, ok:boolean|null}}>}
 */
export async function loadDfttk({ force = false, rootDir = ROOT, fetchFn = globalThis.fetch, warn = console.error } = {}) {
  const fp = path.join(rootDir, DFTTK_CACHE_REL)
  if (!force && existsSync(fp)) {
    try {
      const raw = JSON.parse(await readFile(fp, 'utf8'))
      if (Number.isFinite(raw.fetchedAtMs) && Date.now() - raw.fetchedAtMs < DFTTK_TTL_MS && raw.weapons) {
        return { fetchedAt: raw.fetchedAt, fromCache: true, manifest: raw.manifest, weapons: raw.weapons, sha256: raw.sha256 }
      }
    } catch {
      /* 缓存损坏当无缓存重抓 */
    }
  }
  const manifest = JSON.parse((await fetchBytes(fetchFn, DFTTK_MANIFEST_URL)).toString('utf8'))
  const expected = findManifestSha256(manifest, 'weapons.json')
  const weaponsBuf = await fetchBytes(fetchFn, DFTTK_WEAPONS_URL)
  const actual = createHash('sha256').update(weaponsBuf).digest('hex')
  const ok = expected ? expected === actual : null
  if (ok === false) warn(`[ttk-audit] dfttk weapons.json sha256 不符（manifest ${expected} ≠ 实际 ${actual}），仅告警继续`)
  if (ok === null) warn('[ttk-audit] dfttk manifest 未找到 weapons.json 的 sha256，跳过校验')
  const weapons = JSON.parse(weaponsBuf.toString('utf8'))
  const now = Date.now()
  const out = { fetchedAt: new Date(now).toISOString(), fetchedAtMs: now, ttlMs: DFTTK_TTL_MS, manifest, weapons, sha256: { expected, actual, ok } }
  await writeJsonAtomic(fp, JSON.stringify(out))
  return { fetchedAt: out.fetchedAt, fromCache: false, manifest, weapons, sha256: out.sha256 }
}

/* ---------- 口径映射（本地 calibers.js 键 → 官方写法） ---------- */

/** 霰弹枪本地面板的弹丸数（guns.js 文件头：面板为 8 弹丸合计伤） */
export const SHOTGUN_PELLETS = 8

/** 本地 cal 键 → 官方 gunDetail.caliber 经 normCaliber 后的可接受写法（2026-10-26 实测全集） */
export const CAL_OFFICIAL_TOKENS = {
  919: ['9x19'],
  45: ['.45', '.45acp'],
  46: ['4.6x30'],
  57: ['5.7x28'],
  939: ['9x39'],
  545: ['5.45x39'],
  556: ['5.56x45'],
  58: ['5.8x42'],
  76239: ['7.62x39'],
  76251: ['7.62x51'],
  68: ['6.8x51'],
  300: ['7.62x35'],
  127: ['12.7x55'],
  547: ['7.62x54'],
  338: ['.338'],
  '50bmg': ['.50bmg'],
  4570: ['.45-70'],
  '12ga': ['12'],
  '50ae': ['.50'],
  357: ['.357'],
}
const KNOWN_CAL_TOKENS = new Set(Object.values(CAL_OFFICIAL_TOKENS).flat())

/** 本地 cal 键 → 官方弹药 objectName 前缀（官方前缀本身不统一，逐口径登记） */
export const AMMO_PREFIX = {
  919: '9x19mm',
  45: '.45 ACP',
  46: '4.6x30mm',
  57: '5.7x28mm',
  939: '9x39mm',
  545: '5.45x39mm',
  556: '5.56x45mm',
  58: '5.8x42mm',
  76239: '7.62x39mm',
  76251: '7.62x51mm',
  68: '6.8x51mm',
  300: '.300BLK',
  127: '12.7x55mm',
  547: '7.62x54R',
  338: '.338 Lap Mag',
  '50bmg': '.50 BMG',
  4570: '45-70 Govt',
  '12ga': '12 Gauge',
  '50ae': '.50 AE',
  357: '.357 Magnum',
}

/** 「cal|本地弹名」→ 官方 objectName 精确值（前缀 + 弹名归一化仍对不上的不规则命名） */
export const AMMO_NAME_ALIAS = {
  '46|亚音速': '4.6x30mm Subsonic SX',
  '76251|Ultra Nosler': '7.62x51mm UN',
  '300|V 亚音速': '.300BLK V SUB',
  '300|BCP 亚音速': '.300BLK BCP SUB',
  '338|.338 AP': '.338 Lap Mag AP',
  '357|鼠弹': '.357 Magnum 9号霰射"鼠弹"',
}

/** 官方 caliber 归一：小写、去 ammo 前缀、去 mm、去空白（ammo5.56x45 / 5.7x28mm → 5.56x45 / 5.7x28） */
export function normCaliber(s) {
  return String(s ?? '').toLowerCase().replace(/^ammo/, '').replace(/mm/g, '').replace(/\s+/g, '')
}

/** 弹名归一（比对用）：小写、去零宽、* × → x、毫米 → mm、去空白与连字符类 */
export function normAmmoName(s) {
  return String(s ?? '')
    .toLowerCase()
    .replace(/[\u200B\u200C\u200D\u2060\uFEFF]/g, '')
    .replace(/[×*]/g, 'x')
    .replace(/毫米/g, 'mm')
    .replace(/[\s\-‐‑–—]+/g, '')
}

/* ---------- 对账核心（纯函数，selftest 直接喂数据） ---------- */

const isNum = (v) => typeof v === 'number' && Number.isFinite(v)
const dfttkSol = (weapons, id) => weapons?.objects?.[id]?.combatSummaryByMode?.sol ?? null
/** dfttk 面板射速：displayFireRateRpm 为整数面板值；缺（unmodeled）时取 fireRateRpm 四舍五入 */
const dfttkRpm = (sol) => (sol ? (isNum(sol.displayFireRateRpm) ? sol.displayFireRateRpm : isNum(sol.fireRateRpm) ? Math.round(sol.fireRateRpm) : null) : null)

/**
 * 枪械对账。
 * @param {object[]} localGuns guns.js 的 GUNS
 * @param {object[]} officialGuns object-directory 条目（带 gunDetail）
 * @param {object|null} dfttkWeapons dfttk weapons.json（objects[objectID].combatSummaryByMode.sol）
 */
export function auditGuns(localGuns, officialGuns, dfttkWeapons = null) {
  const byId = new Map(officialGuns.map((o) => [String(o.objectID), o]))
  const seen = new Set()
  const diff = []
  const noted = []
  const unmatched = []
  let checked = 0
  let matched = 0
  for (const g of localGuns) {
    const id = g.img ? String(g.img) : ''
    const o = id ? byId.get(id) : null
    if (!o) {
      unmatched.push({ side: 'local', zh: g.zh, img: g.img ?? null, reason: g.img ? '官方目录无此 objectID' : '本地无 img（官方 objectID）' })
      continue
    }
    seen.add(id)
    if (!o.gunDetail) {
      unmatched.push({ side: 'local', zh: g.zh, img: id, reason: '官方条目无 gunDetail' })
      continue
    }
    checked++
    const d = o.gunDetail
    const sol = dfttkSol(dfttkWeapons, id)
    const before = diff.length
    const push = (field, local, official, dfttk, note) =>
      diff.push({ zh: g.zh, objectID: id, field, local, official: official ?? null, dfttk: dfttk ?? null, ...(note ? { note } : {}) })

    // dmg / admg：霰弹枪官方单弹丸 ×弹丸数折算到本地 8 弹丸合计口径
    const isShotgun = g.cls === 'sg'
    const pellets = isShotgun ? (isNum(sol?.projectileCount) ? sol.projectileCount : SHOTGUN_PELLETS) : 1
    const scale = (v) => (isNum(v) ? v * pellets : null)
    for (const [field, ok, dk] of [
      ['dmg', 'meatHarm', 'baseFleshDamage'],
      ['admg', 'armorHarm', 'baseArmorDamage'],
    ]) {
      const official = scale(d[ok])
      if (official !== g[field]) {
        const note = isShotgun
          ? `霰弹枪本地为 ${pellets} 弹丸合计；官方单弹丸 ${d[ok] ?? '—'}${isNum(sol?.[dk]) ? `、dfttk ${sol[dk]}` : ''} 已 ×${pellets}`
          : undefined
        push(field, g[field], official, scale(sol?.[dk]), note)
      }
    }
    // rpm：三连发本地面板自述为含间隔持续均值，与官方同口径直接比
    {
      const official = isNum(d.fireSpeed) ? d.fireSpeed : null
      if (official !== g.rpm) {
        let note
        if (g.burst) {
          const inner = sol?.fireScheduleRules?.find?.((r) => isNum(r?.rpm))?.rpm
          note = `三连发：官方面板为含 burst 间隔的持续均值${isNum(inner) ? `；dfttk burst 内 ≈${Math.round(inner)} RPM` : ''}`
        }
        push('rpm', g.rpm, official, dfttkRpm(sol), note)
      }
    }
    // mag
    {
      const official = isNum(d.capacity) ? d.capacity : null
      if (official !== g.mag) push('mag', g.mag, official, null)
    }
    // cal：归一后查登记表；编码未登记只记录不判错
    {
      const tok = normCaliber(d.caliber)
      const expect = CAL_OFFICIAL_TOKENS[g.cal] ?? []
      if (!expect.includes(tok)) {
        const entry = { zh: g.zh, objectID: id, field: 'cal', local: g.cal, official: d.caliber ?? null, dfttk: dfttkWeapons?.objects?.[id]?.ammoTypeId ?? null }
        if (KNOWN_CAL_TOKENS.has(tok)) diff.push(entry)
        else noted.push({ ...entry, note: '官方 caliber 编码未登记 CAL_OFFICIAL_TOKENS，仅记录' })
      }
    }
    if (diff.length === before) matched++
  }
  for (const o of officialGuns) {
    if (!seen.has(String(o.objectID))) unmatched.push({ side: 'official', objectID: String(o.objectID), objectName: o.objectName, reason: '官方有本地无' })
  }
  return { checked, matched, diff, noted, unmatched }
}

/**
 * 弹药对账（按名匹配）。
 * @param {object} CAL calibers.js 的 CAL
 * @param {object[]} officialAmmo object-directory 条目（带 ammoDetail）
 */
export function auditAmmo(CAL, officialAmmo) {
  const index = new Map()
  for (const o of officialAmmo) {
    const k = normAmmoName(o.objectName)
    if (!index.has(k)) index.set(k, [])
    index.get(k).push(o)
  }
  const exact = new Map(officialAmmo.map((o) => [o.objectName, o]))
  const seen = new Set()
  const diff = []
  const noted = []
  const unmatched = []
  let checked = 0
  let matched = 0
  for (const [cal, c] of Object.entries(CAL)) {
    for (const am of c.ammo || []) {
      const zh = `${c.label} ${am.n}`
      const alias = AMMO_NAME_ALIAS[`${cal}|${am.n}`]
      let o = alias ? (exact.get(alias) ?? null) : null
      if (!o) {
        const prefix = AMMO_PREFIX[cal]
        const hits = prefix ? (index.get(normAmmoName(`${prefix} ${am.n}`)) ?? []) : []
        if (hits.length > 1) {
          unmatched.push({ side: 'local', zh, cal, n: am.n, reason: `官方同名多条歧义（${hits.map((h) => h.objectID).join('/')}）` })
          continue
        }
        if (!hits.length) {
          unmatched.push({ side: 'local', zh, cal, n: am.n, reason: prefix ? '官方无同名条目' : '口径未登记 AMMO_PREFIX' })
          continue
        }
        o = hits[0]
      }
      const id = String(o.objectID)
      seen.add(id)
      checked++
      const det = o.ammoDetail || {}
      const before = diff.length
      const entry = (field, local, official, note) => ({ zh, objectID: id, field, local, official, dfttk: null, ...(note ? { note } : {}) })

      const localPen = am.pen ?? 0
      const officialPen = det.penetrationLevel == null ? 0 : det.penetrationLevel
      if (officialPen !== localPen) diff.push(entry('pen', localPen, officialPen, det.penetrationLevel == null ? '官方 penetrationLevel 为 null，按 0 计' : undefined))

      const localFlesh = am.flesh ?? 1
      const officialFlesh = isNum(det.harmRatio) ? det.harmRatio / 100 : null
      const singleProjectile = cal === '12ga' && /独头|单弹丸/.test(`${am.n} ${am.note ?? ''}`)
      if (singleProjectile) {
        if (officialFlesh !== null && Math.round(localFlesh * 100) !== det.harmRatio) {
          noted.push(entry('flesh', localFlesh, officialFlesh, `独头/单弹丸：本地 flesh 相对 ${SHOTGUN_PELLETS} 弹丸合计面板（折算单弹丸 ×${SHOTGUN_PELLETS} ≈ ${Math.round(localFlesh * SHOTGUN_PELLETS * 100) / 100}），官方 harmRatio 相对单弹丸；口径不同仅记录`))
        }
      } else if (officialFlesh === null || Math.round(localFlesh * 100) !== det.harmRatio) {
        diff.push(entry('flesh', localFlesh, officialFlesh, '官方 harmRatio 为百分比，已 /100 折算到 flesh 系数'))
      }
      if (diff.length === before) matched++
    }
  }
  for (const o of officialAmmo) {
    if (!seen.has(String(o.objectID))) unmatched.push({ side: 'official', objectID: String(o.objectID), objectName: o.objectName, reason: '官方有本地无' })
  }
  return { checked, matched, diff, noted, unmatched }
}

/**
 * 护甲对账：本地逐级满耐久 vs 官方同级全部型号 durability 区间。
 * @param {{DUR:object, HEAD_DUR:object}} tables armor.js 的 DUR / HEAD_DUR
 * @param {object[]} officialProtect object-directory protect 条目（带 protectDetail）
 */
export function auditArmor({ DUR, HEAD_DUR }, officialProtect) {
  const TYPES = [
    ['armor', '护甲', 'DUR', DUR],
    ['helmet', '头盔', 'HEAD_DUR', HEAD_DUR],
  ]
  const diff = []
  const levels = []
  const unmatched = []
  let checked = 0
  let matched = 0
  for (const [cls, label, field, table] of TYPES) {
    for (const lv of [1, 2, 3, 4, 5, 6]) {
      const local = table?.[lv]
      if (!isNum(local)) continue
      const zh = `${label} ${lv} 级`
      const models = officialProtect
        .filter((p) => p.secondClass === cls && p.protectDetail && Number(p.protectDetail.protectLevel) === lv && isNum(p.protectDetail.durability))
        .map((p) => ({ objectID: String(p.objectID), objectName: p.objectName, durability: p.protectDetail.durability }))
        .sort((a, b) => a.durability - b.durability)
      if (!models.length) {
        unmatched.push({ side: 'local', zh, field, lv, reason: '官方无该级型号' })
        continue
      }
      checked++
      const min = models[0].durability
      const max = models[models.length - 1].durability
      const inRange = local >= min && local <= max
      levels.push({ type: cls, lv, field, local, official: { min, max, models }, inRange })
      if (inRange) matched++
      else {
        diff.push({
          zh,
          objectID: null,
          field,
          local,
          official: { min, max },
          dfttk: null,
          note: `官方同级 ${models.length} 型号耐久区间外（${models.map((m) => `${m.objectName} ${m.durability}`).join(' / ')}）`,
        })
      }
    }
  }
  return { checked, matched, diff, levels, unmatched }
}

/** 组装完整报告（官方 protect 缺席时护甲段为空且不报错） */
export function buildAudit({ local, official, dfttk = null, now = new Date() }) {
  const guns = auditGuns(local.GUNS, official.gun ?? [], dfttk?.weapons ?? null)
  const ammo = auditAmmo(local.CAL, official.ammo ?? [])
  const armor = official.protect ? auditArmor(local, official.protect) : { checked: 0, matched: 0, diff: [], levels: [], unmatched: [] }
  return {
    source: {
      official: {
        api: 'AMS object.list（chartId 352143，免登录）',
        fetchedAt: official.fetchedAt ?? null,
        counts: { gun: official.gun?.length ?? 0, ammo: official.ammo?.length ?? 0, protect: official.protect ? official.protect.length : null },
        ...(official.protectError ? { protectError: official.protectError } : {}),
      },
      dfttk: dfttk
        ? {
            manifest: DFTTK_MANIFEST_URL,
            weapons: DFTTK_WEAPONS_URL,
            dataVersion: dfttk.manifest?.dataVersion ?? null,
            version: dfttk.manifest?.version ?? null,
            fetchedAt: dfttk.fetchedAt ?? null,
            sha256: dfttk.sha256 ?? null,
            weaponCount: Object.keys(dfttk.weapons?.objects ?? {}).length,
          }
        : null,
    },
    fetchedAt: now.toISOString(),
    guns: { checked: guns.checked, matched: guns.matched, diff: guns.diff, noted: guns.noted },
    ammo: { checked: ammo.checked, matched: ammo.matched, diff: ammo.diff, noted: ammo.noted },
    armor: { checked: armor.checked, matched: armor.matched, diff: armor.diff, levels: armor.levels },
    unmatched: { guns: guns.unmatched, ammo: ammo.unmatched, armor: armor.unmatched },
  }
}

const fmtVal = (v) => (v == null ? '—' : typeof v === 'object' ? (isNum(v.min) && isNum(v.max) ? `${v.min}-${v.max}` : JSON.stringify(v)) : String(v))

/** SUMMARY 行的数据体（枪 → 弹 → 甲 的 diff 顺序取前 10 条进 top） */
export function summarize(report) {
  const sec = (s) => ({ checked: s.checked, matched: s.matched, diff: s.diff.length })
  const unmatched = Object.values(report.unmatched).reduce((n, a) => n + a.length, 0)
  const top = [...report.guns.diff, ...report.ammo.diff, ...report.armor.diff]
    .slice(0, 10)
    .map((e) => `${e.zh} ${e.field} 本地${fmtVal(e.local)}→官方${fmtVal(e.official)}`)
  return { guns: sec(report.guns), ammo: sec(report.ammo), armor: sec(report.armor), unmatched, top }
}

export const summaryLine = (report) => `SUMMARY ${JSON.stringify(summarize(report))}`

/* ---------- 落盘 / 本地数据 ---------- */

/** 写 public/data/ttk-audit.json；dist/data 目录存在时同内容双写。返回写入路径列表 */
export async function writeAudit(report, { webDir = WEB_DIR } = {}) {
  const text = JSON.stringify(report, null, 2) + '\n'
  const pub = path.join(webDir, 'public', 'data', 'ttk-audit.json')
  await writeJsonAtomic(pub, text)
  const written = [pub]
  const distDir = path.join(webDir, 'dist', 'data')
  if (existsSync(distDir)) {
    const dist = path.join(distDir, 'ttk-audit.json')
    await writeJsonAtomic(dist, text)
    written.push(dist)
  }
  return written
}

/** 读本地三件套（与 server/export-ios-data.mjs 同一 import 方式） */
export async function loadLocalTtkData(webDir = WEB_DIR) {
  const base = path.join(webDir, 'src', 'data', 'ttk')
  const mod = (f) => import(pathToFileURL(path.join(base, f)).href)
  const [{ GUNS }, { CAL }, { DUR, HEAD_DUR }] = await Promise.all([mod('guns.js'), mod('calibers.js'), mod('armor.js')])
  return { GUNS, CAL, DUR, HEAD_DUR }
}

/* ---------- 主流程 ---------- */

/**
 * 跑一次对账：官方目录（gun/ammo 必须成功；protect 单独取，失败只告警）+ dfttk
 * （失败只告警）→ 对账 → 落盘 → 打印进度与 SUMMARY 行（末行）。
 * @param {{force?:boolean, rootDir?:string, webDir?:string, local?:object,
 *          dfttkFetch?:Function, log?:Function, warn?:Function}} opts
 *   rootDir 挂两处缓存（selftest 传临时目录）；webDir 为 public/dist 写入目录；
 *   local 直接注入三件套（缺省从 webDir 读）；dfttkFetch 注入 dfttk 请求桩
 *   （官方请求桩走 ams-client.setFetch）
 * @returns {Promise<{report:object, summary:string, written:string[]}>}
 */
export async function runAudit({
  force = false,
  rootDir = ROOT,
  webDir = WEB_DIR,
  local = null,
  dfttkFetch = globalThis.fetch,
  log = console.log,
  warn = console.error,
} = {}) {
  const localData = local ?? (await loadLocalTtkData(webDir))

  // gun/ammo 一次取（force 时 object-directory 会以本次结果重建缓存，必须同批）
  const ga = await getDirectory({ primaries: ['gun', 'ammo'], force, rootDir })
  const official = {
    fetchedAt: ga.fetchedAt,
    gun: ga.items.filter((i) => i.primaryClass === 'gun'),
    ammo: ga.items.filter((i) => i.primaryClass === 'ammo'),
    protect: null,
    protectError: null,
  }
  // protect 单独补缺：上一步已刷新 gun/ammo，这里不传 force 只补未覆盖的类；失败不阻塞
  try {
    const p = await getDirectory({ primaries: ['protect'], rootDir })
    official.protect = p.items
  } catch (e) {
    official.protectError = e.message
    warn(`[ttk-audit] protect 目录抓取失败（${e.message}），护甲段跳过，不阻塞 gun/ammo`)
  }

  let dfttk = null
  try {
    dfttk = await loadDfttk({ force, rootDir, fetchFn: dfttkFetch, warn })
  } catch (e) {
    warn(`[ttk-audit] dfttk 抓取失败（${e.message}），dfttk 列置空继续`)
  }

  const report = buildAudit({ local: localData, official, dfttk })
  const written = await writeAudit(report, { webDir })
  const summary = summaryLine(report)

  log(`✓ 官方目录：gun ${official.gun.length} · ammo ${official.ammo.length} · protect ${official.protect ? official.protect.length : '失败'}（${official.fetchedAt}）`)
  if (dfttk) {
    const sha = dfttk.sha256?.ok === true ? 'OK' : dfttk.sha256?.ok === false ? '不符' : '未校验'
    log(`✓ dfttk v3 ${dfttk.manifest?.dataVersion ?? ''}：weapons ${Object.keys(dfttk.weapons?.objects ?? {}).length} 条 · sha256 ${sha}${dfttk.fromCache ? '（缓存）' : ''}`)
  } else {
    log('⚠ dfttk 不可用，diff 的 dfttk 列为 null')
  }
  for (const [k, lbl] of [
    ['guns', '枪械'],
    ['ammo', '弹药'],
    ['armor', '护甲'],
  ]) {
    const s = report[k]
    log(`${lbl}：对账 ${s.checked} · 匹配 ${s.matched} · 差异 ${s.diff.length} 条${s.noted ? ` · 仅记录 ${s.noted.length}` : ''} · 未匹配 ${report.unmatched[k].length}`)
  }
  log(`✓ 写入 ${written.map((p) => path.relative(rootDir, p)).join(' + ')}`)
  log(summary)
  return { report, summary, written }
}

// ---- CLI 直跑 ----
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await runAudit({ force: process.argv.includes('--force') })
  } catch (e) {
    console.error(`❌ ttk:audit 失败: ${e.message}`)
    process.exit(1)
  }
}
