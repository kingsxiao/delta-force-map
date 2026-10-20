/* ============================================================
   armor.js — 护甲满耐久 / 头盔满耐久 / 护甲档位元信息 / 部位判定（胸 / 腹 / 头）
   自 legacy/ttk.html 数据区迁移，头部耐久已修正为独立头盔表。
   PARTS.dur(al)：该部位在 al 级甲下的有效耐久（腹部 1-2 级甲不覆盖，按无甲计）。
   ============================================================ */

export const DUR = {1:25, 2:40, 3:75, 4:110, 5:125, 6:150};
/* 头盔满耐久（社区 wiki 实测满耐久，取各档主流型号）：
   3 级 DAS 40 / 4 级 GT1 48（D6 55 为上限）/ 5 级 GN 重型 50（Mask-1 铁壁 75 为特例上限）
   / 6 级 GT5 指挥官 60（全游戏最硬头盔）；1-2 级头耐久极低，取估计值。
   注意：头盔耐久远低于同档护甲（150 vs 60），不能复用 DUR 表。 */
export const HEAD_DUR = {1:15, 2:25, 3:40, 4:48, 5:50, 6:60};
export const ARMOR_META = [
  {lv:1, name:"无甲", short:"无甲"},
  {lv:1, name:"1 级甲"},{lv:2, name:"2 级甲"},{lv:3, name:"3 级甲"},
  {lv:4, name:"4 级甲"},{lv:5, name:"5 级甲"},{lv:6, name:"6 级甲"}
];

export const PARTS = {
  chest:{label:"胸部", mult:1.0, dur:function(al){ return al>0 ? DUR[al] : 0; }},
  belly:{label:"腹部", mult:0.9, dur:function(al){ return al>=3 ? DUR[al] : 0; }, hint:"1-2 级甲不护腹部：按无甲计算"},
  head:{label:"头部",  mult:1.9, dur:function(al){ return al>0 ? HEAD_DUR[al] : 0; }, hint:"假设目标佩戴与所选等级同级头盔，按主流型号满耐久计"}
};
