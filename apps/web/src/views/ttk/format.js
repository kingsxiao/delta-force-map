/* ============================================================
   format.js — TTK 页展示层格式化助手
   自 legacy/ttk.html 渲染区等义迁移（fmtMs L647 / passText L651 /
   comboDetailMeta 拆分 L657 / 单发伤害格式 L740 / 弹药系数格式 L890-891），
   输出口径与 legacy 逐字符一致；超弹匣警告段由模板条件渲染补齐。
   ============================================================ */

/* TTK 毫秒展示：0 视为"首发"（BTK=1 时 (BTK-1)×60000/RPM = 0） */
export function fmtMs(ms) {
  if (ms === 0) return '首发'
  return Math.round(ms) + ' ms'
}

/* 穿透通过率文案（展开行判定列用紧凑口径：碎甲过程由"碎甲 N 发"表达） */
export function passText(p) {
  if (p >= 1) return '穿透 100%'
  if (p >= 0.75) return '高 1 级 75%'
  if (p >= 0.5) return '同级 50%'
  return '无法穿透'
}

/* 详情卡元信息前段（通过率 · 碎甲 · 无甲）；"超弹匣"警告段由模板按 x.btk > x.gun.mag 追加 */
export function metaText(x) {
  const bits = [passText(x.pass)]
  if (x.broke > 0 && x.pass < 1) bits.push('碎甲 ' + x.broke + ' 发')
  bits.push('无甲 ' + x.noArmorBtk + ' 发')
  return bits.join(' · ')
}

/* 详情卡弹药备注（note · 置信度较低） */
export function extraText(x, calEst) {
  const bits = []
  if (x.am.note) bits.push(x.am.note)
  if (x.am.est || calEst) bits.push('置信度较低')
  return bits.join(' · ')
}

/* 排行"单发伤"列：带小数留一位，整数原样 */
export function fmtDmg(flesh) {
  return flesh % 1 ? flesh.toFixed(1) : String(flesh)
}

/* 弹药库系数列：无系数显示 ×1.00，有系数保留两位 */
export function fmtCoef(v) {
  return v ? '×' + v.toFixed(2) : '×1.00'
}

/* 场景标签（多选部位/护甲时行内标注归属场景）："5 级头" / "无甲胸" */
export const PART_CHAR = { chest: '胸', belly: '腹', head: '头' }
export function scenLabel(c) {
  return (c.armor > 0 ? c.armor + ' 级' : '无甲') + PART_CHAR[c.part]
}

/* 详情卡"部位单发"行：[['胸', 42], ...]，与排行"单发伤"列同口径（穿透全额后的肉伤）。
   部位倍率 头 ×1.9 / 胸 ×1.0 / 腹 ×0.9 / 四肢 ×0.4；RM277、MK4 胸腹同伤按 gun.belly 修正 */
export function partDmg(gun, am) {
  const f = gun.dmg * (am.flesh || 1)
  return [
    ['胸', f],
    ['腹', f * (gun.belly != null ? gun.belly : 0.9)],
    ['头', f * 1.9],
    ['肢', f * 0.4],
  ]
}
