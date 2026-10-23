/* ============================================================
   export-ios-data.mjs — 跨端数据导出（npm run export:ios）
   ------------------------------------------------------------
   多端 monorepo 里网页端的 JS 数据模块是唯一事实来源；原生端不能 import
   JS，于是把它们确定性地导出成 JSON 放进 shared/，由 apps/ios 的工程
   文件（project.yml）直接引用——不在 git 里复制第二份：
     apps/web/src/data/ttk/{guns,calibers,armor}.js → shared/data/ttk.json
     apps/web/src/data/ttk/ammo-market-alias.js     → shared/data/ammo-alias.json
     apps/web/public/ammo/market.json               → shared/fixtures/market-sample.json
     apps/web/public/market/radar.json              → shared/fixtures/radar-sample.json
   fixtures 是固定样本：iOS 单测断言口径移植（sellEta / marketMeta /
   NotifyPolicy）与「演示模式」离线数据都吃它；只在契约或 TTK 数据
   变化时重跑本脚本并一起提交。
   PARTS.dur 是函数不能序列化：导出耐久表 + 覆盖规则枚举，Swift 端按
   同一规则实现（chest: al>0 用 DUR；belly: al≥3 用 DUR（1-2 级甲不
   护腹）；head: al>0 用 HEAD_DUR）。
   用法：node server/export-ios-data.mjs
   ============================================================ */
import { mkdir, readFile, writeFile } from 'node:fs/promises'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const WEB = path.join(ROOT, 'apps', 'web')
const SHARED = path.join(ROOT, 'shared')

const { GUNS } = await import(path.join(WEB, 'src/data/ttk/guns.js'))
const { CAL } = await import(path.join(WEB, 'src/data/ttk/calibers.js'))
const { DUR, HEAD_DUR, ARMOR_META, PARTS } = await import(path.join(WEB, 'src/data/ttk/armor.js'))
const { AMMO_MARKET_PAIRS, AMMO_MARKET_UNMAPPED } = await import(path.join(WEB, 'src/data/ttk/ammo-market-alias.js'))

/** 兵种标签（与 TtkView 页面分段控件一致） */
const CLASSES = [
  { id: 'ar', label: '步枪' },
  { id: 'smg', label: '冲锋枪' },
  { id: 'dmr', label: '射手步枪' },
  { id: 'snp', label: '狙击枪' },
  { id: 'lmg', label: '轻机枪' },
  { id: 'sg', label: '霰弹枪' },
  { id: 'pst', label: '手枪' },
]

/** 部位覆盖规则：函数 → 枚举（Swift 端 TtkEngine.partDurability 同名实现） */
const COVER_RULE = { chest: 'armor', belly: 'armorLv3Plus', head: 'helmet' }

const ttk = {
  generatedFrom: 'apps/web/src/data/ttk (npm run export:ios)',
  classes: CLASSES,
  guns: GUNS,
  calibers: CAL,
  armor: {
    dur: DUR,
    headDur: HEAD_DUR,
    meta: ARMOR_META,
  },
  parts: Object.entries(PARTS).map(([id, p]) => ({
    id,
    label: p.label,
    mult: p.mult,
    coverRule: COVER_RULE[id],
    ...(p.hint ? { hint: p.hint } : {}),
  })),
}

await mkdir(path.join(SHARED, 'data'), { recursive: true })
await mkdir(path.join(SHARED, 'fixtures'), { recursive: true })
await writeFile(path.join(SHARED, 'data', 'ttk.json'), JSON.stringify(ttk, null, 1) + '\n')
console.log(`✓ shared/data/ttk.json：${GUNS.length} 枪 · ${Object.keys(CAL).length} 口径 · ${Object.values(CAL).reduce((n, c) => n + c.ammo.length, 0)} 弹药`)

// TTK 弹药 ↔ 行情弹名 映射（TTK 页标现价 / 行情页标穿透共用；映射口径见源文件头注释）
const alias = {
  generatedFrom: 'apps/web/src/data/ttk/ammo-market-alias.js (npm run export:ios)',
  pairs: AMMO_MARKET_PAIRS,
  unmapped: AMMO_MARKET_UNMAPPED,
}
await writeFile(path.join(SHARED, 'data', 'ammo-alias.json'), JSON.stringify(alias, null, 1) + '\n')
console.log(`✓ shared/data/ammo-alias.json：${AMMO_MARKET_PAIRS.length} 对映射 · ${AMMO_MARKET_UNMAPPED.length} 条显式不映射`)

for (const [from, to] of [
  ['public/ammo/market.json', 'market-sample.json'],
  ['public/market/radar.json', 'radar-sample.json'],
]) {
  const j = JSON.parse(await readFile(path.join(WEB, from), 'utf8'))
  await writeFile(path.join(SHARED, 'fixtures', to), JSON.stringify(j) + '\n')
  console.log(`✓ shared/fixtures/${to}：version ${j.version} · ${j.items.length} 项`)
}
