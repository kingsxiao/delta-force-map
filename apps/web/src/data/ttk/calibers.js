/* ============================================================
   calibers.js — 20 种口径与全部弹药
   自 legacy/ttk.html 数据区一字不差迁移（var CAL → export const CAL，语义等价）。
   口径：base = 基准枪肉伤面板，armor = 基准枪甲伤面板（参考值，随枪浮动）
   弹药：pen 穿透等级；flesh 肉伤系数（默认1）；amult 甲伤系数（默认1）；
        est=true 表示型号/数值置信度较低
   ============================================================ */

export const CAL = {
  "919":  {label:"9×19mm",            sub:"帕拉贝鲁姆", base:28, armor:35, ammo:[
    {n:"RIP",    pen:0, flesh:1.30, note:"空尖肉弹，专打无甲"},
    {n:"PSO",    pen:1},
    {n:"Pst",    pen:2},
    {n:"AP 6.3", pen:3},
    {n:"PBP",    pen:4}]},
  "45":   {label:".45 ACP",           sub:"大口径手枪弹", base:32, armor:28, ammo:[
    {n:"RIP", pen:0, flesh:1.30, note:"空尖肉弹"},
    {n:"HS",  pen:1},
    {n:"JHP", pen:2},
    {n:"FMJ", pen:3},
    {n:"AP",  pen:4}]},
  "46":   {label:"4.6×30mm",          sub:"PDW 弹", base:29, armor:27, ammo:[
    {n:"亚音速",  pen:3},
    {n:"FMJ SX", pen:4},
    {n:"AP SX",  pen:5}]},
  "57":   {label:"5.7×28mm",          sub:"PDW 弹", base:32, armor:35, ammo:[
    {n:"R37.F",   pen:0, flesh:1.30, note:"杂弹，低穿高肉"},
    {n:"SS198LF", pen:1},
    {n:"SS197SR", pen:2},
    {n:"L191",    pen:3},
    {n:"SS193",   pen:4},
    {n:"SS190",   pen:5}]},
  "939":  {label:"9×39mm",            sub:"亚音速", base:36, armor:48, ammo:[
    {n:"SP-5",   pen:3},
    {n:"PAB-7",  pen:3, flesh:0.85, note:"S10 赛季弹：同部位命中叠 20% 增伤，禁交易"},
    {n:"SP-6",   pen:4},
    {n:"PAB-9",  pen:4, flesh:0.85, note:"S10 赛季弹：同部位命中叠 20% 增伤"},
    {n:"BP",     pen:5}]},
  "545":  {label:"5.45×39mm",         sub:"小口径步枪弹", base:34, armor:36, ammo:[
    {n:"PRS", pen:1},
    {n:"T",   pen:2},
    {n:"PS",  pen:3},
    {n:"BT",    pen:4},
    {n:"BT ST", pen:4, note:"S9 赛季限定：爆头倍率 2.2（本表按标准倍率计）"},
    {n:"BS",    pen:5},
    {n:"BS ST+",pen:5, note:"S9 赛季限定：爆头倍率 2.2、腹部 ×1.0（本表按标准倍率计）"}]},
  "556":  {label:"5.56×45mm",         sub:"NATO", base:27, armor:32, ammo:[
    {n:"RRLP",   pen:1},
    {n:"FMJ",    pen:2},
    {n:"M855",   pen:3},
    {n:"M855 APC",     pen:3, amult:1.30, note:"S9 赛季限定：高甲伤"},
    {n:"M855A1",       pen:4},
    {n:"M855A1 APC+",  pen:4, flesh:1.10, amult:1.15, note:"S9 赛季限定：对 6 级甲额外 +10% 甲伤"},
    {n:"M995",   pen:5}]},
  "58":   {label:"5.8×42mm",          sub:"DBP 系列", base:35, armor:38, ammo:[
    {n:"DBP-87",  pen:2},
    {n:"DVP-88",  pen:3},
    {n:"SBP-10",  pen:4},
    {n:"DVC-12",  pen:5}], note:"国服型号译名或作 DBP-191 / DVP-88 等"},
  "76239":{label:"7.62×39mm",         sub:"中间威力弹", base:34, armor:36, ammo:[
    {n:"LP",      pen:1},
    {n:"T45M",    pen:2},
    {n:"PS",      pen:3},
    {n:"BP",      pen:4},
    {n:"BP SUB",  pen:4, flesh:1.05, amult:0.95, note:"S8 亚音速：爆头致听力衰减"},
    {n:"AP",      pen:5},
    {n:"AP SUB",  pen:5, flesh:1.05, amult:0.90, note:"S8 亚音速：爆头致听力衰减"}]},
  "76251":{label:"7.62×51mm",         sub:"全威力 NATO", base:39, armor:42, ammo:[
    {n:"Ultra Nosler", pen:2, flesh:1.10, note:"低穿高肉猎弹"},
    {n:"BPZ", pen:3},
    {n:"M80", pen:4},
    {n:"M62", pen:5},
    {n:"M61", pen:6, amult:1.20, note:"红弹：对 1-6 级甲均 120% 甲伤"}]},
  "68":   {label:"6.8×51mm",          sub:".277 Fury", base:38, armor:40, ammo:[
    {n:"FMJ",    pen:4},
    {n:"Hybrid", pen:5},
    {n:"AP",     pen:6}]},
  "300":  {label:".300 BLK",          sub:"7.62×35 亚音速平台", base:34, armor:35, est:true, ammo:[
    {n:"V 亚音速",   pen:3, flesh:1.05, amult:0.95, note:"命中头部降听力"},
    {n:"BCP 亚音速", pen:4, flesh:1.05, amult:0.95, note:"命中头部降听力"},
    {n:"超音速",     pen:4, est:true},
    {n:"超压 +P",    pen:4, flesh:1.08, est:true, note:"2026 新弹，系数为估算"}]},
  "127":  {label:"12.7×55mm",         sub:"大口径", base:56, armor:55, est:true, ammo:[
    {n:"PS12A", pen:3},
    {n:"PS12",  pen:4},
    {n:"PS12B", pen:5}], note:"型号与等级为国际服手册口径，国服或有出入"},
  "547":  {label:"7.62×54mm R",       sub:"莫辛-纳甘缘弹", base:56, armor:52, ammo:[
    {n:"T46M", pen:3},
    {n:"LPS",  pen:4},
    {n:"BT",   pen:5},
    {n:"SNB",  pen:6}], note:"SVD / SVCH / SV-98 / PKM 共用，面板随枪浮动极大（PKM 45 肉 ↔ SVD 56 肉）"},
  "338":  {label:".338 Lapua Magnum", sub:"远程栓狙弹", base:100, armor:10, est:true, ammo:[
    {n:".338 AP", pen:7, note:"全游戏穿透上限之一，禁交易、仅任务/手搓获取"}], note:"AWM 专用；AWM 甲伤极低为'留甲'特性（狙杀后敌人防具成色保留）"},
  "50bmg":{label:"12.7×99mm",         sub:".50 BMG 反器材", base:100, armor:20, est:true, ammo:[
    {n:"M903 SLAP", pen:7, note:"次口径脱壳穿甲，禁交易、禁入安全箱"},
    {n:"M10 RAZOR", pen:6, flesh:0.70, note:"创伤弹：命中后延缓用药（效果归属待核实）"},
    {n:"M3 K-0",    pen:6, flesh:0.70, note:"失能弹：减速 + 视角晃动（效果归属待核实）"}], note:"M82 专用"},
  "4570": {label:".45-70 Govt",       sub:"杠杆步枪弹", base:70, armor:25, est:true, ammo:[
    {n:"RN",  pen:1, flesh:1.50, est:true, note:"穿透等级未披露，按低级肉弹估"},
    {n:"FMJ", pen:4},
    {n:"FTX", pen:5}], note:"Marlin 专用"},
  "12ga": {label:"12 号霰弹",          sub:"12ga", base:112, armor:128, est:true, ammo:[
    {n:"8.5mm 鹿弹", pen:0, est:true, note:"基准鹿弹，8 弹丸"},
    {n:"7mm 鹿弹",   pen:1, flesh:0.75, note:"8 弹丸"},
    {n:"龙息弹",     pen:0, flesh:1.10, note:"附带烧灼效果，8 弹丸"},
    {n:"箭形弹",     pen:3, flesh:0.70, est:true, note:"弹丸数按 8 计"},
    {n:"独头 GT",    pen:2, flesh:0.44, est:true, note:"独头单弹丸，绝对总伤约 49 折算"},
    {n:"独头 FTX",   pen:3, flesh:0.44, est:true, note:"独头单弹丸，绝对总伤约 49 折算"},
    {n:"独头 AP-20", pen:4, flesh:0.44, est:true, note:"独头单弹丸，绝对总伤约 49 折算"},
    {n:"独头 APX",   pen:4, flesh:0.25, est:true, note:"独头单弹丸，绝对总伤约 28 折算"},
    {n:"独头 RIP",   pen:0, flesh:0.44, est:true, note:"独头单弹丸，绝对总伤约 49 折算"},
    {n:"DART",       pen:5, flesh:0.23, est:true, note:"单弹丸，绝对总伤约 26 折算"}], note:"面板为 8 弹丸鹿弹合计伤（8×14 肉 / 16×8 甲）；各弹种甲伤未逐条实测，统一按合计甲伤计"},
  "50ae": {label:".50 AE",            sub:"手枪大口径", base:50, armor:34, ammo:[
    {n:"HP",  pen:2},
    {n:"JHP", pen:3},
    {n:"FMJ", pen:4},
    {n:"AP",  pen:5, note:"特勤处工作台制造"}], note:"沙漠之鹰专用"},
  "357":  {label:".357 Magnum",       sub:"左轮弹", base:56, armor:39, ammo:[
    {n:"HP",   pen:2},
    {n:"JHP",  pen:3},
    {n:"FMJ",  pen:4},
    {n:"鼠弹", pen:0, flesh:0.50, est:true, note:"霰射独头（9 号霰弹），唯一 50% 加成弹"}]}
};
