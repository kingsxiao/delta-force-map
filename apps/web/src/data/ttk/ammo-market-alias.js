/* ============================================================
   ammo-market-alias.js — TTK 弹药 ↔ 行情弹名 映射（单一事实来源）
   ------------------------------------------------------------
   TTK 数据（calibers.js，93 弹）与行情快照（/ammo/market.json，67 弹）
   是两套独立命名体系：TTK 用国际通用型号（"AP 6.3"/"DVP-88"），行情用
   游戏内名称（"9x19mm AP6.3"/"5.8x42mm DVP88"）。本模块把能一一对应
   的条目显式登记成对，供三处消费：
     · TTK 页（弹药库 / 排行展开）：按 cal+ammo 查现价 → 跳行情页；
     · 行情页全表：按弹名查穿透等级（PenBadge）；
     · npm run export:ios 导出 shared/data/ammo-alias.json 供 iOS 捆绑。
   映射口径（宁可少标不错标——标错穿透比不标更误导）：
     1) 同名归一化命中（normalizeAmmoName）或手工核实的命名差异
        （Subsonic SX↔亚音速、9号霰射"鼠弹"↔鼠弹、7.62x54R↔7.62×54mm R、
        8.5毫米鹿弹↔8.5mm 鹿弹、12 Gauge独头↔独头）→ 登记为 pair；
     2) 一对多歧义（紫/蓝/金.300BLK ↔ TTK 4 条 .300 BLK 弹，颜色档
        与型号无法确定对应）与国服命名无同型条目（DBP10、PD12双头弹、
        HT/HT+、LS、ST 系、.45 ACP Super）→ 不登记，行情页穿透列显「—」；
     3) TTK 无该口径（3 条箭矢，TTK 未收录弓弩）→ 不登记，同显「—」。
   实测行情名「.45 ACP Super​」尾部含零宽字符 U+200B——归一化函数必须
   显式剥离零宽字符（ZERO_WIDTH），两侧比对才不漏。
   未消费条目与其原因见 AMMO_MARKET_UNMAPPED（导出进 ammo-alias.json，
   行情页表尾「— = 无穿透数据」的口径说明）。
   ============================================================ */

/** 零宽 / 不可见字符：ZWSP U+200B、ZWNJ U+200C、ZWJ U+200D、WJ U+2060、BOM U+FEFF */
const ZERO_WIDTH = /[\u200B\u200C\u200D\u2060\uFEFF]/g

/**
 * 弹名归一化（比对用，不改数据）：小写 → 剥零宽字符 → × 归一为 x →
 * 去全部空白与连字符类（-‐‑–—）。两侧名经此变换后相等才视为同名，
 * 例："9x19mm AP6.3" ≡ "9×19mm" + "AP 6.3"、"5.8x42mm DVP88" ≡ "5.8×42mm" + "DVP-88"。
 */
export function normalizeAmmoName(s) {
  return String(s)
    .toLowerCase()
    .replace(ZERO_WIDTH, '')
    .replace(/×/g, 'x')
    .replace(/[\s\-‐‑–—]+/g, '')
}

/**
 * 可映射条目（52 / 67 行情弹）。cal = calibers.js 口径键；ammo = TTK 弹药名；
 * market = 行情弹名（market.json items[].name 的唯一键）。
 * 顺序按 calibers.js 口径组序排列，便于人工对账。
 */
export const AMMO_MARKET_PAIRS = [
  // 9×19mm（帕拉贝鲁姆）
  { cal: '919', ammo: 'RIP', market: '9x19mm RIP' },
  { cal: '919', ammo: 'AP 6.3', market: '9x19mm AP6.3' },
  { cal: '919', ammo: 'PBP', market: '9x19mm PBP' },
  // .45 ACP（行情侧无 JHP：HS / JHP 未上架）
  { cal: '45', ammo: 'RIP', market: '.45 ACP RIP' },
  { cal: '45', ammo: 'FMJ', market: '.45 ACP FMJ' },
  { cal: '45', ammo: 'AP', market: '.45 ACP AP' },
  // 4.6×30mm（Subsonic SX = 国服英文命名，TTK 收录名为「亚音速」，同口径内唯一亚音速弹）
  { cal: '46', ammo: '亚音速', market: '4.6x30mm Subsonic SX' },
  { cal: '46', ammo: 'FMJ SX', market: '4.6x30mm FMJ SX' },
  { cal: '46', ammo: 'AP SX', market: '4.6x30mm AP SX' },
  // 5.7×28mm
  { cal: '57', ammo: 'R37.F', market: '5.7x28mm R37.F' },
  { cal: '57', ammo: 'L191', market: '5.7x28mm L191' },
  { cal: '57', ammo: 'SS193', market: '5.7x28mm SS193' },
  { cal: '57', ammo: 'SS190', market: '5.7x28mm SS190' },
  // 9×39mm
  { cal: '939', ammo: 'SP-5', market: '9x39mm SP5' },
  { cal: '939', ammo: 'SP-6', market: '9x39mm SP6' },
  { cal: '939', ammo: 'BP', market: '9x39mm BP' },
  // 5.45×39mm
  { cal: '545', ammo: 'PS', market: '5.45x39mm PS' },
  { cal: '545', ammo: 'BT', market: '5.45x39mm BT' },
  { cal: '545', ammo: 'BS', market: '5.45x39mm BS' },
  // 5.56×45mm
  { cal: '556', ammo: 'M855', market: '5.56x45mm M855' },
  { cal: '556', ammo: 'M855A1', market: '5.56x45mm M855A1' },
  { cal: '556', ammo: 'M995', market: '5.56x45mm M995' },
  // 5.8×42mm（DBP 系列）
  { cal: '58', ammo: 'DVP-88', market: '5.8x42mm DVP88' },
  { cal: '58', ammo: 'DVC-12', market: '5.8x42mm DVC12' },
  // 7.62×39mm
  { cal: '76239', ammo: 'PS', market: '7.62x39mm PS' },
  { cal: '76239', ammo: 'BP', market: '7.62x39mm BP' },
  { cal: '76239', ammo: 'AP', market: '7.62x39mm AP' },
  // 7.62×51mm
  { cal: '76251', ammo: 'BPZ', market: '7.62x51mm BPZ' },
  { cal: '76251', ammo: 'M80', market: '7.62x51mm M80' },
  { cal: '76251', ammo: 'M62', market: '7.62x51mm M62' },
  // 6.8×51mm
  { cal: '68', ammo: 'FMJ', market: '6.8x51mm FMJ' },
  { cal: '68', ammo: 'Hybrid', market: '6.8x51mm Hybrid' },
  // 12.7×55mm
  { cal: '127', ammo: 'PS12A', market: '12.7x55mm PS12A' },
  { cal: '127', ammo: 'PS12', market: '12.7x55mm PS12' },
  { cal: '127', ammo: 'PS12B', market: '12.7x55mm PS12B' },
  // 7.62×54mm R（行情名省作 54R，TTK 口径名为 54mm R）
  { cal: '547', ammo: 'T46M', market: '7.62x54R T46M' },
  { cal: '547', ammo: 'LPS', market: '7.62x54R LPS' },
  { cal: '547', ammo: 'BT', market: '7.62x54R BT' },
  // .45-70 Govt
  { cal: '4570', ammo: 'RN', market: '45-70 Govt RN' },
  { cal: '4570', ammo: 'FMJ', market: '45-70 Govt FMJ' },
  { cal: '4570', ammo: 'FTX', market: '45-70 Govt FTX' },
  // 12 号霰弹（行情中文数量词「毫米」与 TTK「mm」、「Gauge独头」连写差异）
  { cal: '12ga', ammo: '8.5mm 鹿弹', market: '12 Gauge 8.5毫米鹿弹' },
  { cal: '12ga', ammo: '箭形弹', market: '12 Gauge 箭形弹' },
  { cal: '12ga', ammo: '龙息弹', market: '12 Gauge 龙息弹' },
  { cal: '12ga', ammo: '独头 AP-20', market: '12 Gauge独头 AP-20' },
  { cal: '12ga', ammo: '独头 FTX', market: '12 Gauge独头 FTX' },
  { cal: '12ga', ammo: 'DART', market: '12 Gauge DART' },
  // .50 AE
  { cal: '50ae', ammo: 'JHP', market: '.50 AE JHP' },
  { cal: '50ae', ammo: 'FMJ', market: '.50 AE FMJ' },
  // .357 Magnum（9号霰射「鼠弹」= TTK 收录名「鼠弹」）
  { cal: '357', ammo: 'JHP', market: '.357 Magnum JHP' },
  { cal: '357', ammo: 'FMJ', market: '.357 Magnum FMJ' },
  { cal: '357', ammo: '鼠弹', market: '.357 Magnum 9号霰射"鼠弹"' },
]

/**
 * 行情侧未消费条目（15 / 67）与原因——不标 pen 只显「—」的口径依据：
 * ambiguous = 一对多歧义；noTtkAmmo = TTK 无同型条目（国服命名差异 / 未收录）；noCal = TTK 无该口径。
 * 注意「.45 ACP Super」名尾含零宽字符 U+200B（源数据如此，勿"顺手清理"导致对不上）。
 */
export const AMMO_MARKET_UNMAPPED = [
  { market: '紫.300BLK', reason: 'ambiguous' },
  { market: '蓝.300BLK', reason: 'ambiguous' },
  { market: '金.300BLK', reason: 'ambiguous' },
  { market: '.45 ACP Super​', reason: 'noTtkAmmo' },
  { market: '5.8x42mm DBP10', reason: 'noTtkAmmo' },
  { market: '12.7x55mm PD12双头弹', reason: 'noTtkAmmo' },
  { market: '5.7x28mm HT', reason: 'noTtkAmmo' },
  { market: '5.7 x 28mm HT+', reason: 'noTtkAmmo' },
  { market: '7.62 x 51mm LS', reason: 'noTtkAmmo' },
  { market: '4.6 x 30mm AP ST', reason: 'noTtkAmmo' },
  { market: '4.6 x 30mm FMJ ST', reason: 'noTtkAmmo' },
  { market: '4.6 x 30mm CT', reason: 'noTtkAmmo' },
  { market: '玻纤柳叶箭矢', reason: 'noCal' },
  { market: '碳纤维刺骨箭矢', reason: 'noCal' },
  { market: '碳纤维穿甲箭矢', reason: 'noCal' },
]

/** 行情弹名 → 映射对（未登记返回 undefined = 无穿透数据） */
const BY_MARKET = new Map(AMMO_MARKET_PAIRS.map((p) => [p.market, p]))
/** cal|ammo → 行情弹名（TTK 侧反查现价） */
const BY_TTK = new Map(AMMO_MARKET_PAIRS.map((p) => [p.cal + '|' + p.ammo, p.market]))

/** TTK 口径 + 弹药名 → 行情弹名（无映射返回 null：未上架 / 命名差异 / 禁交易弹） */
export function ttkAmmoMarketName(calKey, ammoName) {
  return BY_TTK.get(calKey + '|' + ammoName) ?? null
}

/** 行情弹名 → { cal, ammo } 映射对（无映射返回 null） */
export function marketNameTtkPair(marketName) {
  return BY_MARKET.get(marketName) ?? null
}

/**
 * 行情弹名 → 穿透等级（0-7）。需要传 CAL（calibers.js 的口径表）以解析
 * pair 里的 pen——pen 的唯一事实来源始终是 calibers.js，本模块只管名字对齐。
 * 无映射 / 口径或弹名在 CAL 中查不到 → null（调用方显「—」）。
 */
export function marketNamePen(marketName, CAL) {
  const p = BY_MARKET.get(marketName)
  if (!p) return null
  const am = CAL[p.cal]?.ammo.find((a) => a.n === p.ammo)
  return am ? am.pen : null
}
