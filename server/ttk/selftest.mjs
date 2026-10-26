/* ============================================================
   selftest.mjs — TTK 官方对账离线自测（node 直接运行，零外网）
   ------------------------------------------------------------
   覆盖（official-audit.mjs 的可测面；网络层全注桩）：
     ① 归一函数：normCaliber（ammo 前缀 / mm 后缀 / 空白）、
        normAmmoName（* × → x、毫米 → mm、空白与连字符、零宽字符）
     ② auditGuns：M4A1 官方 31/33 全匹配 + checked / matched 计数
     ③ auditGuns：故意不一致的枪 → diff 条目六字段齐全且值命中（dfttk 第三列）
     ④ auditGuns：霰弹枪官方单弹丸 ×8 折算（dmg 出 diff 带 note、admg 折算后匹配）
     ⑤ auditGuns：三连发 rpm diff，note 附 dfttk burst 内射速
     ⑥ auditGuns：cal 编码未登记 → noted 不判错；cal 错配 → diff；无 img / 官方多余 → unmatched
     ⑦ auditAmmo：pen null→0、flesh×100↔harmRatio（星号 / 毫米 / 空白 / 别名归一）、
        独头单弹丸 → noted、同名歧义与无同名 → unmatched、官方多余归集
     ⑧ auditArmor：区间内 matched / 区间外 diff（note 含型号明细）/ 无同级型号 →
        unmatched / bag（无 protectLevel）忽略
     ⑨ summarize / summaryLine：可 JSON.parse、top ≤10 且格式「… 本地X→官方Y」
     ⑩ runAudit 集成：protect 失败不阻塞 gun/ammo（armor 段 0 + protectError）、
        public 与 dist/data 双写同内容、目录缓存落临时 rootDir、SUMMARY 为末行
     ⑪ runAudit：无 dist 目录只写 public；dfttk 抓取失败只告警（source.dfttk=null）
     ⑫ loadDfttk：sha256 不符只告警继续；缓存命中零请求
     ⑬ findManifestSha256：数组 / 映射两种 manifest 形状；未命中返回 null
   全部通过 exit 0；失败写 stderr 后 exit 1。
   用法：node server/ttk/selftest.mjs
   ============================================================ */
import { createHash } from 'node:crypto'
import { mkdtemp, mkdir, rm, readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import {
  auditGuns,
  auditAmmo,
  auditArmor,
  summarize,
  summaryLine,
  runAudit,
  loadDfttk,
  findManifestSha256,
  normCaliber,
  normAmmoName,
} from './official-audit.mjs'
import { setFetch, _resetForTest as resetAms } from '../official/ams-client.mjs'
import { _resetForTest as resetDir } from '../official/object-directory.mjs'

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/* ---------- 桩助手 ---------- */

const objectListResponse = (list) => ({
  ok: true,
  status: 200,
  text: async () => JSON.stringify({ ret: 0, iRet: 0, sMsg: 'succ', jData: { data: { code: 0, data: { list } } } }),
})
const errResponse = (msg) => ({ ok: true, status: 200, text: async () => JSON.stringify({ ret: -1, sMsg: msg }) })

const IDE_COMM = 'https://comm.ams.game.qq.com/ide/'

/** ams 桩：按 object.list 的 param.primary 回放目录；failPrimary 模拟该类失败 */
function amsStub(byPrimary, { failPrimary, failMsg = 'protect down' } = {}) {
  const calls = []
  const fn = async (url, init = {}) => {
    calls.push({ url: String(url), body: init.body || '' })
    if (String(url) !== IDE_COMM) throw new Error(`桩未处理请求: ${url}`)
    const p = Object.fromEntries(new URLSearchParams(init.body || ''))
    const param = JSON.parse(p.param)
    if (param.primary === failPrimary) return errResponse(failMsg)
    return objectListResponse(byPrimary[param.primary] || [])
  }
  fn.calls = calls
  return fn
}

const toAB = (s) => {
  const b = Buffer.from(s)
  return b.buffer.slice(b.byteOffset, b.byteOffset + b.byteLength)
}

/** dfttk 桩：manifest（files 为 path→{sha256} 映射）+ weapons.json（sha 可故意改错） */
function dfttkStub(weaponsObj, { sha } = {}) {
  const weaponsText = JSON.stringify(weaponsObj)
  const expected = sha ?? createHash('sha256').update(Buffer.from(weaponsText)).digest('hex')
  const manifest = { dataVersion: 'selftest-v3', files: { 'catalog/weapons.json': { sha256: expected } } }
  const calls = []
  const fn = async (url) => {
    calls.push(String(url))
    if (String(url).endsWith('manifest.json')) return { ok: true, status: 200, arrayBuffer: async () => toAB(JSON.stringify(manifest)) }
    if (String(url).endsWith('weapons.json')) return { ok: true, status: 200, arrayBuffer: async () => toAB(weaponsText) }
    throw new Error(`桩未处理请求: ${url}`)
  }
  fn.calls = calls
  return fn
}

/* ---------- fixture：本地三件套 + 官方原始条目 + dfttk ---------- */

const LOCAL = {
  GUNS: [
    { zh: 'M4A1', cls: 'ar', dmg: 31, admg: 33, rpm: 800, cal: '556', mag: 30, img: '18010000001' },
    { zh: 'AKM', cls: 'ar', dmg: 38, admg: 42, rpm: 600, cal: '76239', mag: 30, img: '18010000006' }, // dmg 故意不一致（官方 40）
    { zh: 'M870', cls: 'sg', dmg: 112, admg: 128, rpm: 74, cal: '12ga', mag: 6, img: '18030000004' },
    { zh: 'M16A4', cls: 'ar', dmg: 33, admg: 39, rpm: 672, cal: '556', mag: 20, burst: true, img: '18010000014' },
    { zh: 'M1911', cls: 'pst', dmg: 40, admg: 30, rpm: 373, cal: '45', mag: 7, img: '18070000033' },
    { zh: '怪枪', cls: 'smg', dmg: 30, admg: 30, rpm: 600, cal: '919', mag: 30, img: '18020000099' },
    { zh: '错配枪', cls: 'smg', dmg: 30, admg: 30, rpm: 600, cal: '556', mag: 30, img: '18020000098' },
    { zh: 'AA-12', cls: 'sg', dmg: 80, admg: 90, rpm: 320, cal: '12ga', mag: 8 }, // 无 img → unmatched
  ],
  CAL: {
    556: { label: '5.56×45mm', ammo: [{ n: 'M995', pen: 5 }, { n: 'M855 APC', pen: 3, amult: 1.3 }] },
    919: { label: '9×19mm', ammo: [{ n: 'RIP', pen: 0, flesh: 1.3 }, { n: 'AP 6.3', pen: 3 }] },
    '12ga': { label: '12 号霰弹', ammo: [{ n: '8.5mm 鹿弹', pen: 0 }, { n: '独头 GT', pen: 2, flesh: 0.44, note: '独头单弹丸，绝对总伤约 49 折算' }] },
    357: { label: '.357 Magnum', ammo: [{ n: '鼠弹', pen: 0, flesh: 0.5 }] },
    300: { label: '.300 BLK', ammo: [{ n: '超音速', pen: 4 }] }, // 官方两条同名 → 歧义
    58: { label: '5.8×42mm', ammo: [{ n: 'SBP-10', pen: 4 }] }, // 官方只有 DBP10 → 无同名
    4570: { label: '.45-70 Govt', ammo: [{ n: 'RN', pen: 1, flesh: 1.5 }] }, // 官方 pen 为 null → diff
  },
  DUR: { 1: 25, 2: 40 },
  HEAD_DUR: { 1: 15, 3: 40 }, // 1 级超官方区间（10-12）→ diff；3 级官方无型号 → unmatched
}

const OFFICIAL_GUNS = [
  { objectID: 18010000001, objectName: 'M4A1突击步枪', primaryClass: 'gun', gunDetail: { meatHarm: 31, armorHarm: 33, fireSpeed: 800, capacity: 30, caliber: 'ammo5.56x45' } },
  { objectID: 18010000006, objectName: 'AKM突击步枪', primaryClass: 'gun', gunDetail: { meatHarm: 40, armorHarm: 42, fireSpeed: 600, capacity: 30, caliber: 'ammo7.62x39' } },
  { objectID: 18030000004, objectName: 'M870霰弹枪', primaryClass: 'gun', gunDetail: { meatHarm: 17, armorHarm: 16, fireSpeed: 74, capacity: 6, caliber: 'ammo12' } },
  { objectID: 18010000014, objectName: 'M16A4突击步枪', primaryClass: 'gun', gunDetail: { meatHarm: 33, armorHarm: 39, fireSpeed: 508, capacity: 20, caliber: 'ammo5.56x45' } },
  { objectID: 18070000033, objectName: 'M1911', primaryClass: 'gun', gunDetail: { meatHarm: 40, armorHarm: 30, fireSpeed: 373, capacity: 7, caliber: '.45ACP' } },
  { objectID: 18020000099, objectName: '怪枪冲锋枪', primaryClass: 'gun', gunDetail: { meatHarm: 30, armorHarm: 30, fireSpeed: 600, capacity: 30, caliber: 'ammoMystery' } },
  { objectID: 18020000098, objectName: '错配枪冲锋枪', primaryClass: 'gun', gunDetail: { meatHarm: 30, armorHarm: 30, fireSpeed: 600, capacity: 30, caliber: 'ammo5.45x39' } },
  { objectID: 18150000001, objectName: '复合弓', primaryClass: 'gun', gunDetail: { meatHarm: 60, armorHarm: 10, fireSpeed: 40, capacity: 1, caliber: 'ammoArrow' } }, // 官方多余
]

const OFFICIAL_AMMO = [
  { objectID: 37100500001, objectName: '5.56x45mm M995', primaryClass: 'ammo', ammoDetail: { penetrationLevel: 5, harmRatio: 100 } },
  { objectID: 37100300002, objectName: '5.56*45mm M855 APC', primaryClass: 'ammo', ammoDetail: { penetrationLevel: 3, harmRatio: 110 } }, // 星号变体；flesh → diff
  { objectID: 37200000001, objectName: '9x19mm RIP', primaryClass: 'ammo', ammoDetail: { harmRatio: 130 } }, // 无 penetrationLevel = pen 0
  { objectID: 37200300001, objectName: '9x19mm AP6.3', primaryClass: 'ammo', ammoDetail: { penetrationLevel: 3, harmRatio: 100 } }, // 连写变体
  { objectID: 37250000001, objectName: '12 Gauge 8.5毫米鹿弹', primaryClass: 'ammo', ammoDetail: { harmRatio: 100 } }, // 毫米变体
  { objectID: 37250200002, objectName: '12 Gauge独头 GT', primaryClass: 'ammo', ammoDetail: { penetrationLevel: 2, harmRatio: 250 } }, // 独头 → noted
  { objectID: 37220000001, objectName: '.357 Magnum 9号霰射"鼠弹"', primaryClass: 'ammo', ammoDetail: { harmRatio: 50 } }, // 走 AMMO_NAME_ALIAS
  { objectID: 37290300001, objectName: '45-70 Govt RN', primaryClass: 'ammo', ammoDetail: { harmRatio: 150 } }, // pen null → diff
  { objectID: 37280300001, objectName: '.300BLK 超音速', primaryClass: 'ammo', ammoDetail: { penetrationLevel: 3, harmRatio: 100 } },
  { objectID: 37280400001, objectName: '.300BLK 超音速', primaryClass: 'ammo', ammoDetail: { penetrationLevel: 4, harmRatio: 100 } }, // 同名两条 → 歧义
  { objectID: 37130400001, objectName: '5.8x42mm DBP10', primaryClass: 'ammo', ammoDetail: { penetrationLevel: 4, harmRatio: 100 } }, // 官方多余
]

const OFFICIAL_PROTECT = [
  { objectID: 11010001001, objectName: '老式钢盔', primaryClass: 'protect', secondClass: 'helmet', protectDetail: { durability: 10, protectLevel: 1 } },
  { objectID: 11010001002, objectName: '户外棒球帽', primaryClass: 'protect', secondClass: 'helmet', protectDetail: { durability: 12, protectLevel: 1 } },
  { objectID: 11010001003, objectName: '通用战术背心', primaryClass: 'protect', secondClass: 'armor', protectDetail: { durability: 30, protectLevel: 1 } },
  { objectID: 11010001004, objectName: '摩托马甲', primaryClass: 'protect', secondClass: 'armor', protectDetail: { durability: 20, protectLevel: 1 } },
  { objectID: 11010002001, objectName: 'HT战术背心', primaryClass: 'protect', secondClass: 'armor', protectDetail: { durability: 40, protectLevel: 2 } },
  { objectID: 11010003001, objectName: 'D3战术登山包', primaryClass: 'protect', secondClass: 'bag' }, // 无 protectDetail → 忽略
]

const DFTTK_FIXTURE = {
  objects: {
    18010000001: { ammoTypeId: '10', combatSummaryByMode: { sol: { baseFleshDamage: 31, baseArmorDamage: 33, fireRateRpm: 800, displayFireRateRpm: 800, projectileCount: 1 } } },
    18010000006: { ammoTypeId: '11', combatSummaryByMode: { sol: { baseFleshDamage: 40, baseArmorDamage: 42, fireRateRpm: 600, displayFireRateRpm: 600, projectileCount: 1 } } },
    18030000004: { ammoTypeId: '25', combatSummaryByMode: { sol: { baseFleshDamage: 17, baseArmorDamage: 16, fireRateRpm: 74.07, displayFireRateRpm: 74, projectileCount: 8 } } },
    18010000014: {
      ammoTypeId: '10',
      combatSummaryByMode: { sol: { baseFleshDamage: 33, baseArmorDamage: 39, fireRateRpm: 508.47, displayFireRateRpm: 508, projectileCount: 1, fireScheduleRules: [{ type: 'fireSchedule', mode: 'repeatedBurst', shots: 3, rpm: 895.52 }] } },
    },
  },
}

/* ---------- ① 归一函数 ---------- */

check('normCaliber / normAmmoName：官方写法归一', () => {
  assert(normCaliber('ammo5.56x45') === '5.56x45', `ammo 前缀（got ${normCaliber('ammo5.56x45')}）`)
  assert(normCaliber('5.7x28mm') === '5.7x28' && normCaliber('ammo5.7x28') === '5.7x28', 'mm 后缀两写法同归一')
  assert(normCaliber('.50 BMG') === '.50bmg' && normCaliber('ammo.50') === '.50', '空格剥离；.50bmg 与 .50 区分')
  assert(normCaliber('ammo12') === '12' && normCaliber('ammo12.7x55') === '12.7x55', '12 与 12.7x55 区分')
  assert(normAmmoName('5.56*45mm M855 APC') === normAmmoName('5.56×45mm M855 APC'), '* 与 × 同归一')
  assert(normAmmoName('12 Gauge 8.5毫米鹿弹') === normAmmoName('12 Gauge 8.5mm 鹿弹'), '毫米 → mm')
  assert(normAmmoName('9x19mm AP6.3') === normAmmoName('9x19mm AP 6.3'), '空白剥离')
  assert(normAmmoName('45-70 Govt RN') === normAmmoName('45‐70 Govt RN'), '连字符剥离')
  assert(normAmmoName('.45 ACP Super\u200B') === normAmmoName('.45 ACP Super'), '零宽字符剥离')
})

/* ---------- ②~⑥ auditGuns ---------- */

let GUNS_RESULT = null
check('auditGuns：M4A1 官方 31/33 全匹配 + checked / matched 计数', () => {
  GUNS_RESULT = auditGuns(LOCAL.GUNS, OFFICIAL_GUNS, DFTTK_FIXTURE)
  assert(GUNS_RESULT.checked === 7, `checked 应 7（AA-12 无 img 不计，got ${GUNS_RESULT.checked}）`)
  assert(GUNS_RESULT.matched === 3, `matched 应 3（M4A1 / M1911 / 怪枪-noted，got ${GUNS_RESULT.matched}）`)
  const m4 = LOCAL.GUNS[0]
  assert(!GUNS_RESULT.diff.some((e) => e.zh === m4.zh), 'M4A1 31/33/800/30/556 不应出 diff')
})

check('auditGuns：故意不一致的枪 → diff 条目六字段齐全且值命中（含 dfttk 第三列）', () => {
  const e = GUNS_RESULT.diff.find((e) => e.zh === 'AKM')
  assert(e, 'AKM dmg 38≠40 应出 diff')
  for (const k of ['zh', 'objectID', 'field', 'local', 'official', 'dfttk']) assert(k in e, `条目缺字段 ${k}`)
  assert(e.zh === 'AKM' && e.objectID === '18010000006' && e.field === 'dmg', 'zh / objectID / field')
  assert(e.local === 38 && e.official === 40 && e.dfttk === 40, `local/official/dfttk（got ${JSON.stringify(e)}）`)
})

check('auditGuns：霰弹枪官方单弹丸 ×8 折算（dmg 出 diff 带 note，admg 折算后匹配）', () => {
  const e = GUNS_RESULT.diff.find((e) => e.zh === 'M870' && e.field === 'dmg')
  assert(e && e.official === 136 && e.dfttk === 136, `17×8=136（got ${JSON.stringify(e)}）`)
  assert(e.local === 112 && /×8/.test(e.note || ''), 'note 记录折算口径')
  assert(!GUNS_RESULT.diff.some((x) => x.zh === 'M870' && x.field === 'admg'), 'admg 128 = 16×8 不应出 diff')
})

check('auditGuns：三连发 rpm diff，note 附 dfttk burst 内射速', () => {
  const e = GUNS_RESULT.diff.find((e) => e.zh === 'M16A4')
  assert(e && e.field === 'rpm' && e.local === 672 && e.official === 508 && e.dfttk === 508, JSON.stringify(e))
  assert(/896 RPM/.test(e.note || ''), `note 应含 burst 内射速（got ${e.note}）`)
})

check('auditGuns：cal 未登记 → noted；cal 错配 → diff；无 img / 官方多余 → unmatched', () => {
  const noted = GUNS_RESULT.noted
  assert(noted.length === 1 && noted[0].zh === '怪枪' && noted[0].field === 'cal' && noted[0].official === 'ammoMystery', JSON.stringify(noted))
  const bad = GUNS_RESULT.diff.find((e) => e.zh === '错配枪' && e.field === 'cal')
  assert(bad && bad.local === '556' && bad.official === 'ammo5.45x39', '登记编码但口径不符 → diff')
  const unmatched = GUNS_RESULT.unmatched
  assert(unmatched.length === 2, `unmatched 应 2（got ${JSON.stringify(unmatched)}）`)
  assert(unmatched.some((u) => u.side === 'local' && u.zh === 'AA-12' && u.reason.includes('无 img')), '本地无 img 归集')
  assert(unmatched.some((u) => u.side === 'official' && u.objectID === '18150000001' && u.objectName === '复合弓'), '官方多余归集')
})

/* ---------- ⑦ auditAmmo ---------- */

check('auditAmmo：pen null→0、flesh×100↔harmRatio、名归一/别名命中、独头 → noted、歧义/无同名/官方多余归集', () => {
  const r = auditAmmo(LOCAL.CAL, OFFICIAL_AMMO)
  assert(r.checked === 8 && r.matched === 6, `checked 8 / matched 6（got ${r.checked}/${r.matched}）`)
  assert(r.diff.length === 2, `diff 应 2（got ${JSON.stringify(r.diff)}）`)
  const flesh = r.diff.find((e) => e.field === 'flesh')
  assert(flesh && flesh.zh === '5.56×45mm M855 APC' && flesh.local === 1 && flesh.official === 1.1 && flesh.dfttk === null, `harmRatio/100 折算（got ${JSON.stringify(flesh)}）`)
  const pen = r.diff.find((e) => e.field === 'pen')
  assert(pen && pen.zh === '.45-70 Govt RN' && pen.local === 1 && pen.official === 0 && /null/.test(pen.note || ''), 'pen null → 0 判 diff')
  assert(r.noted.length === 1 && r.noted[0].zh === '12 号霰弹 独头 GT' && r.noted[0].field === 'flesh', '独头单弹丸只记录不判错')
  assert(r.matched === 6 && !r.diff.some((e) => /M995|RIP|AP 6.3|鹿弹|鼠弹/.test(e.zh)), '名归一（星号/毫米/连写/别名）命中者无 diff')
  const local = r.unmatched.filter((u) => u.side === 'local')
  assert(local.length === 2, `本地 unmatched 2（got ${JSON.stringify(local)}）`)
  assert(local.some((u) => u.n === '超音速' && /歧义/.test(u.reason)), '同名多条 → 歧义')
  assert(local.some((u) => u.n === 'SBP-10' && /无同名/.test(u.reason)), '无同名条目')
  const official = r.unmatched.filter((u) => u.side === 'official')
  assert(official.length === 3 && official.some((u) => u.objectName === '5.8x42mm DBP10'), '官方多余归集（2 条歧义名 + DBP10）')
})

/* ---------- ⑧ auditArmor ---------- */

check('auditArmor：区间内 matched / 区间外 diff 含型号明细 / 无同级 → unmatched / bag 忽略', () => {
  const r = auditArmor(LOCAL, OFFICIAL_PROTECT)
  assert(r.checked === 3 && r.matched === 2, `checked 3 / matched 2（got ${r.checked}/${r.matched}）`)
  assert(r.diff.length === 1, `diff 应 1（got ${JSON.stringify(r.diff)}）`)
  const e = r.diff[0]
  assert(e.zh === '头盔 1 级' && e.field === 'HEAD_DUR' && e.local === 15 && e.official.min === 10 && e.official.max === 12, JSON.stringify(e))
  assert(/老式钢盔 10/.test(e.note || '') && /户外棒球帽 12/.test(e.note || ''), 'note 含型号明细')
  const lv = r.levels.find((l) => l.type === 'armor' && l.lv === 1)
  assert(lv && lv.inRange === true && lv.local === 25 && lv.official.models.length === 2, '区间内记 levels')
  assert(!r.levels.some((l) => l.type === 'helmet' && l.lv === 3), '官方无 3 级头盔型号不进 levels')
  assert(r.unmatched.length === 1 && r.unmatched[0].zh === '头盔 3 级', '无同级型号 → unmatched')
  assert(!JSON.stringify(r.levels).includes('bag'), 'bag（无 protectLevel）不参与')
})

/* ---------- ⑨ SUMMARY ---------- */

check('summarize / summaryLine：可 JSON.parse、top ≤10 且格式含「本地X→官方Y」', () => {
  const report = {
    guns: { checked: 7, matched: 3, diff: GUNS_RESULT.diff, noted: GUNS_RESULT.noted },
    ammo: { checked: 8, matched: 6, diff: [], noted: [] },
    armor: { checked: 3, matched: 2, diff: [{ zh: '头盔 1 级', objectID: null, field: 'HEAD_DUR', local: 15, official: { min: 10, max: 12 }, dfttk: null }], levels: [] },
    unmatched: { guns: GUNS_RESULT.unmatched, ammo: [], armor: [] },
  }
  const line = summaryLine(report)
  assert(line.startsWith('SUMMARY '), '前缀 SUMMARY')
  assert(summarize(report).unmatched === 2, 'summarize 与 summaryLine 同源')
  const s = JSON.parse(line.slice('SUMMARY '.length))
  assert(s.guns.checked === 7 && s.guns.matched === 3 && s.guns.diff === 4, `guns 段（got ${JSON.stringify(s.guns)}）`)
  assert(s.armor.diff === 1 && s.unmatched === 2, 'armor / unmatched 段')
  assert(Array.isArray(s.top) && s.top.length <= 10, 'top ≤10')
  assert(s.top[0] === 'AKM dmg 本地38→官方40', `top[0]（got ${s.top[0]}）`)
  assert(s.top[s.top.length - 1] === '头盔 1 级 HEAD_DUR 本地15→官方10-12', `armor 区间格式（got ${s.top[s.top.length - 1]}）`)
})

/* ---------- ⑩ runAudit 集成：protect 失败不阻塞 + 双写 ---------- */

check('runAudit 集成：protect 失败不阻塞 gun/ammo + public/dist 双写同内容 + SUMMARY 末行 + 缓存落临时 rootDir', async () => {
  resetAms()
  resetDir()
  const tmp = await mkdtemp(path.join(tmpdir(), 'ttk-audit-'))
  try {
    const webDir = path.join(tmp, 'web')
    await mkdir(path.join(webDir, 'public', 'data'), { recursive: true })
    await mkdir(path.join(webDir, 'dist', 'data'), { recursive: true })
    setFetch(amsStub({ gun: OFFICIAL_GUNS, ammo: OFFICIAL_AMMO, protect: OFFICIAL_PROTECT }, { failPrimary: 'protect' }))
    const logs = []
    const warns = []
    const { report, summary, written } = await runAudit({
      rootDir: tmp,
      webDir,
      local: LOCAL,
      dfttkFetch: dfttkStub(DFTTK_FIXTURE),
      log: (m) => logs.push(m),
      warn: (m) => warns.push(m),
    })
    assert(report.guns.checked === 7 && report.ammo.checked === 8, 'protect 失败不影响枪 / 弹对账')
    assert(report.armor.checked === 0 && report.armor.diff.length === 0, '护甲段为空')
    assert(String(report.source.official.protectError).includes('protect down'), 'protectError 记录')
    assert(warns.some((m) => m.includes('protect') && m.includes('不阻塞')), `应告警 protect 失败（got ${JSON.stringify(warns)}）`)
    assert(report.source.dfttk && report.source.dfttk.sha256.ok === true && report.source.dfttk.dataVersion === 'selftest-v3', 'dfttk 源信息')
    assert(written.length === 2, `dist/data 存在应双写（got ${written.length}）`)
    const pub = await readFile(path.join(webDir, 'public', 'data', 'ttk-audit.json'), 'utf8')
    const dist = await readFile(path.join(webDir, 'dist', 'data', 'ttk-audit.json'), 'utf8')
    assert(pub === dist && pub.includes('"fetchedAt"'), '双写同内容')
    assert(JSON.parse(pub).guns.checked === report.guns.checked, '落盘与返回一致')
    assert(existsSync(path.join(tmp, 'data', 'official', 'object-directory.json')), '目录缓存落临时 rootDir（不碰真实 data/）')
    assert(existsSync(path.join(tmp, 'data', 'dfttk', 'weapons-cache.json')), 'dfttk 缓存落临时 rootDir')
    const last = logs[logs.length - 1]
    assert(last.startsWith('SUMMARY ') && last === summary, 'SUMMARY 为日志末行')
    const s = JSON.parse(last.slice('SUMMARY '.length))
    assert(s.guns.checked === 7 && s.ammo.checked === 8 && s.armor.checked === 0, `SUMMARY 段（got ${last}）`)
    assert(s.unmatched === 7, `unmatched 合计 2+5+0=7（protect 失败则护甲 unmatched 亦不产生，got ${s.unmatched}）`)
    assert(s.top[0] === 'AKM dmg 本地38→官方40', `top[0]（got ${s.top[0]}）`)
  } finally {
    await rm(tmp, { recursive: true, force: true })
  }
})

/* ---------- ⑪ runAudit：无 dist 只写 public；dfttk 失败只告警 ---------- */

check('runAudit：无 dist 目录只写 public；dfttk 抓取失败只告警（source.dfttk=null）', async () => {
  resetAms()
  resetDir()
  const tmp = await mkdtemp(path.join(tmpdir(), 'ttk-audit-b-'))
  try {
    const webDir = path.join(tmp, 'web')
    await mkdir(path.join(webDir, 'public', 'data'), { recursive: true }) // 不建 dist
    setFetch(amsStub({ gun: OFFICIAL_GUNS, ammo: OFFICIAL_AMMO, protect: OFFICIAL_PROTECT }))
    const warns = []
    const { report, written } = await runAudit({
      rootDir: tmp,
      webDir,
      local: LOCAL,
      dfttkFetch: async () => {
        throw new Error('network down')
      },
      log: () => {},
      warn: (m) => warns.push(m),
    })
    assert(written.length === 1 && written[0].endsWith(path.join('public', 'data', 'ttk-audit.json')), '只写 public')
    assert(!existsSync(path.join(webDir, 'dist')), '未创建 dist')
    assert(report.source.dfttk === null, 'dfttk 失败置 null')
    assert(report.guns.diff.every((e) => e.dfttk === null), 'diff 的 dfttk 列为 null')
    assert(warns.some((m) => m.includes('dfttk')), `应告警 dfttk 失败（got ${JSON.stringify(warns)}）`)
    assert(report.armor.checked === 3, 'protect 成功时护甲段恢复对账')
  } finally {
    await rm(tmp, { recursive: true, force: true })
  }
})

/* ---------- ⑫ loadDfttk：sha 不符只告警 + 缓存零请求 ---------- */

check('loadDfttk：sha256 不符只告警继续；缓存命中零请求', async () => {
  const tmp = await mkdtemp(path.join(tmpdir(), 'ttk-dfttk-'))
  try {
    const warns = []
    const bad = dfttkStub(DFTTK_FIXTURE, { sha: 'deadbeef' })
    const r1 = await loadDfttk({ rootDir: tmp, fetchFn: bad, warn: (m) => warns.push(m) })
    assert(r1.sha256.ok === false && r1.sha256.expected === 'deadbeef', 'ok=false 且留痕')
    assert(Object.keys(r1.weapons.objects).length === 4, '解析不受 sha 失败影响')
    assert(warns.length === 1 && /sha256 不符/.test(warns[0]), '只告警不抛')
    const again = dfttkStub(DFTTK_FIXTURE)
    const r2 = await loadDfttk({ rootDir: tmp, fetchFn: again, warn: () => {} })
    assert(r2.fromCache === true && again.calls.length === 0, '24h 内缓存命中零请求')
  } finally {
    await rm(tmp, { recursive: true, force: true })
  }
})

/* ---------- ⑬ findManifestSha256 两种形状 ---------- */

check('findManifestSha256：数组 / 映射形状与未命中', () => {
  const sha = 'a'.repeat(64)
  assert(findManifestSha256({ files: [{ path: 'catalog/weapons.json', sha256: sha }] }, 'weapons.json') === sha, '数组形状')
  assert(findManifestSha256({ files: { 'catalog/weapons.json': { sha256: sha } } }, 'weapons.json') === sha, '映射形状')
  assert(findManifestSha256({ files: { 'catalog/ammo.json': { sha256: sha } } }, 'weapons.json') === null, '未命中返回 null')
  assert(findManifestSha256({ files: { 'catalog/weapons.json': { hash: sha } } }, 'weapons.json') === sha, 'hash 键兜底')
})

/* ---------- 跑测 ---------- */

let failed = 0
for (const [name, fn] of checks) {
  try {
    await fn()
    console.log(`✓ ${name}`)
  } catch (e) {
    failed++
    console.error(`✗ ${name}\n  ${e.message}`)
  }
}
if (failed) {
  console.error(`\n${failed}/${checks.length} 项失败`)
  process.exit(1)
}
console.log(`\n全部 ${checks.length} 项通过（离线模式，未打外网）`)
