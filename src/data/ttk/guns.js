/* ============================================================
   guns.js — 68 把武器（步枪 24 + 冲锋枪 12 + 射手步枪 10 + 狙击枪 5
   + 轻机枪 4 + 霰弹枪 6 + 手枪 7）
   自 legacy/ttk.html 数据区迁移（var GUNS → export const GUNS，语义等价）。
   武器：dmg 肉伤面板 / admg 甲伤面板 / rpm 射速 / cal 口径 / mag 弹匣
   burst=true 表示三连发武器（M16A4 / MK4 / 93R）：面板射速为计入
   两轮 burst 之间间隔的持续平均值，burst 内部射速高于面板（社区口径
   称 MK4 burst 内接近 MP7 ~950）；TTK 按面板均值匀速近似，单 burst
   内的击杀实际更快。M14 为全自动，不是三连发。
   ============================================================ */

export const GUNS = [
  {zh:"M4A1",     en:"M4A1",            cls:"ar", dmg:29, admg:32, rpm:800,  cal:"556",   mag:30, note:"全能新手枪，配件生态最丰富"},
  {zh:"M16A4",    en:"M16A4",           cls:"ar", dmg:33, admg:39, rpm:672,  cal:"556",   mag:20, burst:true, note:"仅三连发 / 单发；面板射速为含 burst 间隔的均值，burst 内更快"},
  {zh:"CAR-15",   en:"CAR-15",          cls:"ar", dmg:27, admg:32, rpm:632,  cal:"556",   mag:20, note:"Model 723，强度平平常作高级弹发射器"},
  {zh:"K416",     en:"K416 (HK416)",    cls:"ar", dmg:31, admg:35, rpm:880,  cal:"556",   mag:30, note:"小口径高射速主力，双模式强势"},
  {zh:"K437",     en:"K437 (HK437)",    cls:"ar", dmg:34, admg:35, rpm:780,  cal:"300",   mag:30, note:"S4 新枪，亚音速定位，中近距离"},
  {zh:"KC17",     en:"KC17",            cls:"ar", dmg:30, admg:48, rpm:740,  cal:"545",   mag:30, note:"S5 新枪，高甲伤高射程，碎甲好手"},
  {zh:"AKM",      en:"AKM",             cls:"ar", dmg:40, admg:42, rpm:600,  cal:"76239", mag:30, note:"中间威力弹性价比代表"},
  {zh:"AK-12",    en:"AK-12",           cls:"ar", dmg:29, admg:41, rpm:735,  cal:"545",   mag:30, note:"低肉伤高甲伤，上场率偏低"},
  {zh:"九五式",    en:"QBZ95-1",         cls:"ar", dmg:28, admg:42, rpm:679,  cal:"58",    mag:30, note:"无托；被腾龙全面上位替代"},
  {zh:"腾龙",      en:"CI-19 (QBZ-191)", cls:"ar", dmg:35, admg:38, rpm:706,  cal:"58",    mag:30, note:"高速导气枪机后约 759 RPM，爆头强势"},
  {zh:"SG552",    en:"SG552",           cls:"ar", dmg:24, admg:31, rpm:906,  cal:"556",   mag:20, note:"步枪最低肉伤，靠射速吃饭"},
  {zh:"AUG",      en:"AUG",             cls:"ar", dmg:35, admg:35, rpm:679,  cal:"556",   mag:30, note:"无托精确稳定，操控步枪顶级"},
  {zh:"PTR-32",   en:"PTR-32",          cls:"ar", dmg:34, admg:36, rpm:632,  cal:"76239", mag:30, note:"G3 改膛 7.62×39，甲伤好操控低"},
  {zh:"MK47",     en:"MK47 Mutant",     cls:"ar", dmg:40, admg:46, rpm:625,  cal:"76239", mag:20, conflict:"另有来源记 30/48", note:"S6 新枪，AR 平台吃 AK 弹匣"},
  {zh:"MCX LT",   en:"MCX LT",          cls:"ar", dmg:34, admg:35, rpm:750,  cal:"300",   mag:30, est:true, note:"S8 季中新枪；甲伤缺实测，取同口径 K437 参考值"},
  {zh:"AR-57",    en:"AR-57",           cls:"ar", dmg:30, admg:31, rpm:900,  cal:"57",    mag:50, note:"S9 新枪，P90 弹匣上供弹的'步枪皮冲锋枪'"},
  {zh:"RM277",    en:"RM277",           cls:"ar", dmg:41, admg:42, rpm:550,  cal:"68",    mag:30, belly:1.0, note:"S10 新枪，胸腹同伤，初速 1155m/s"},
  {zh:"MDR",      en:"MDR",             cls:"ar", dmg:41, admg:43, rpm:650,  cal:"76251", mag:20, note:"S11 新枪，'M7 平替'，弹匣仅 20 发"},
  {zh:"M7",       en:"M7 (Spear)",      cls:"ar", dmg:38, admg:40, rpm:649,  cal:"68",    mag:20, note:"NGSW 战斗步枪，甲弹之王"},
  {zh:"G3",       en:"G3",              cls:"ar", dmg:39, admg:42, rpm:533,  cal:"76251", mag:20, note:"有效射程最远的步枪之一，后坐温和"},
  {zh:"SCAR-H",   en:"SCAR-H",          cls:"ar", dmg:40, admg:40, rpm:585,  cal:"76251", mag:20, note:"操控与改装空间优于 G3"},
  {zh:"ASh-12",   en:"ASh-12",          cls:"ar", dmg:56, admg:55, rpm:500,  cal:"127",   mag:20, note:"全游戏单发伤害最高的自动武器"},
  {zh:"AS Val",   en:"AS Val (巨浪)",    cls:"ar", dmg:29, admg:48, rpm:972,  cal:"939",   mag:15, note:"自带消音，射速媲美冲锋枪 + 高甲伤"},
  {zh:"AKS-74U",  en:"AKS-74U",         cls:"ar", dmg:34, admg:36, rpm:533,  cal:"545",   mag:20, note:"最便宜的满改枪之一，游戏内归步枪"},

  {zh:"MP5",      en:"MP5",             cls:"smg", dmg:30, admg:32, rpm:820,  cal:"919", mag:30, note:"最均衡的冲锋枪，腰射操控双满"},
  {zh:"维克托",    en:"Vector",          cls:"smg", dmg:32, admg:28, rpm:1091, cal:"45",  mag:17, note:"全游戏第二射速，自动武器近战 TTK 标杆"},
  {zh:"UZI",      en:"UZI",             cls:"smg", dmg:28, admg:35, rpm:780,  cal:"919", mag:25, note:"标准型，仅占 2×3 背包格"},
  {zh:"P90",      en:"P90",             cls:"smg", dmg:32, admg:35, rpm:898,  cal:"57",  mag:50, note:"自带 50 发弹匣，裸枪即好用"},
  {zh:"MP7",      en:"MP7",             cls:"smg", dmg:32, admg:28, rpm:950,  cal:"46",  mag:20, note:"PDW 高射速，可拉满腰射"},
  {zh:"野牛",      en:"PP-19 Bizon",     cls:"smg", dmg:32, admg:35, rpm:659,  cal:"919", mag:32, note:"弹筒供弹，可扩至 64 发"},
  {zh:"勇士",      en:"PP-19-01 Vityaz", cls:"smg", dmg:36, admg:35, rpm:700,  cal:"919", mag:30, note:"9mm 修脚名枪，以小博大代表"},
  {zh:"SMG-45",   en:"SMG-45",          cls:"smg", dmg:35, admg:40, rpm:605,  cal:"45",  mag:25, note:"稳定，冲锋枪内伤害可观"},
  {zh:"SR-3M",    en:"SR-3M",           cls:"smg", dmg:36, admg:48, rpm:747,  cal:"939", mag:15, note:"9×39 碎甲效率高，近战压制强"},
  {zh:"二〇式",    en:"QCQ171",          cls:"smg", dmg:36, admg:33, rpm:763,  cal:"919", mag:30, note:"高速枪机改件后射速上限更高"},
  {zh:"MK4",      en:"MK4 Banshee",     cls:"smg", dmg:34, admg:30, rpm:793,  cal:"46",  mag:24, belly:1.0, burst:true, conflict:"另有来源记 23/32", note:"默认单发+三连发，换枪管解锁全自动；面板射速含 burst 间隔"},
  {zh:"汤姆逊",    en:"Thompson",        cls:"smg", dmg:34, admg:36, rpm:880,  cal:"45",  mag:20, conflict:"另有来源记 22/900", note:"S11 新枪'芝加哥打字机'，甲伤>肉伤罕见组合"},

  /* ===== 精确射手步枪 ===== */
  {zh:"SKS",      en:"SKS",             cls:"dmr", dmg:44, admg:42, rpm:510,  cal:"76239", mag:10, note:"半自动老兵，7.62×39 弹池与 AKM 共用"},
  {zh:"SR-25",    en:"SR-25",           cls:"dmr", dmg:50, admg:55, rpm:364,  cal:"76251", mag:10, note:"社区称'连狙之王'，高甲伤"},
  {zh:"PSG-1",    en:"PSG-1",           cls:"dmr", dmg:50, admg:55, rpm:300,  cal:"76251", mag:10, note:"S3 上线；初速 750m/s 第一梯队"},
  {zh:"SR9",      en:"SR9",             cls:"dmr", dmg:50, admg:55, rpm:261,  cal:"76251", mag:10, note:"可通用 G3 配件，半自动里最慢最稳"},
  {zh:"Mini-14",  en:"Mini-14",         cls:"dmr", dmg:32, admg:38, rpm:590,  cal:"556",   mag:10, note:"低成本跑刀枪，5.56 弹池"},
  {zh:"M14",      en:"M14",             cls:"dmr", dmg:39, admg:41, rpm:727,  cal:"76251", mag:10, note:"DMR 唯一全自动异类，开局需手动切全自动"},
  {zh:"VSS",      en:"VSS Vintorez",    cls:"dmr", dmg:35, admg:48, rpm:480,  cal:"939",   mag:15, note:"自带整体式消音，枪声传播最短档"},
  {zh:"SVD",      en:"SVD",             cls:"dmr", dmg:56, admg:52, rpm:300,  cal:"547",   mag:10, note:"社区称'小巴雷特'，70m 内爆头秒"},
  {zh:"Marlin",   en:"Marlin",          cls:"dmr", dmg:70, admg:25, rpm:100,  cal:"4570",  mag:10, note:"S6 杠杆步枪；专属'蜂鸟杠杆'：射速 200、75/59、爆头 112"},
  {zh:"SVCH",     en:"SVCh",            cls:"dmr", dmg:48, admg:48, rpm:600,  cal:"547",   mag:10, conflict:"另有来源记 46/47", note:"S10 新枪；专属一体护木解锁全自动，爆发枪机前三发约 700 RPM"},

  /* ===== 狙击枪 ===== */
  {zh:"R93",      en:"R93 LRS",         cls:"snp", dmg:55, admg:53, rpm:50,   cal:"76251", mag:10, conflict:"旧社区口径记 61/58", note:"开镜快，可瞬狙"},
  {zh:"M700",     en:"M700",            cls:"snp", dmg:55, admg:53, rpm:48,   cal:"76251", mag:5,  conflict:"旧社区口径记 61/58", note:"S11'完全体'套件可改全自动"},
  {zh:"SV-98",    en:"SV-98",           cls:"snp", dmg:55, admg:53, rpm:40,   cal:"547",   mag:7,  conflict:"旧社区口径记 61/58", note:"架点型，稳定性高"},
  {zh:"AWM",      en:"AWM",             cls:"snp", dmg:100, admg:10, rpm:35,  cal:"338",   mag:5,  note:"甲伤极低为'留甲'特性；仅用全游戏唯一的 7 级 .338 AP"},
  {zh:"M82",      en:"M82 Barrett",     cls:"snp", dmg:100, admg:20, rpm:100, cal:"50bmg", mag:5,  conflict:"另有来源记基础伤 150", note:"S9 反器材狙，半自动；三款专用弹禁入安全箱"},

  /* ===== 轻机枪 ===== */
  {zh:"M249",     en:"M249",            cls:"lmg", dmg:30, admg:38, rpm:858,  cal:"556",   mag:100, note:"100 发弹链压制者，可改弹匣供弹"},
  {zh:"M250",     en:"M250",            cls:"lmg", dmg:55, admg:53, rpm:550,  cal:"68",    mag:125, note:"6.8 弹链 125 发，单发/全自动切换，有扳机延迟"},
  {zh:"PKM",      en:"PKM",             cls:"lmg", dmg:45, admg:42, rpm:669,  cal:"547",   mag:75,  note:"7.62×54R 弹链 75 发"},
  {zh:"QJB201",   en:"QJB201",          cls:"lmg", dmg:32, admg:38, rpm:785,  cal:"58",    mag:125, conflict:"另有社区源记 873/827", note:"S3 上线；弹链/弹匣双路供弹"},

  /* ===== 霰弹枪（面板为 8 弹丸合计伤） ===== */
  {zh:"M870",     en:"M870",            cls:"sg", dmg:112, admg:128, rpm:74,  cal:"12ga", mag:6,  note:"泵动老兵，军需 9 级解锁"},
  {zh:"M1014",    en:"M1014",           cls:"sg", dmg:112, admg:128, rpm:261, cal:"12ga", mag:7,  note:"半自动霰弹"},
  {zh:"S12K",     en:"S12K",            cls:"sg", dmg:104, admg:128, rpm:300, cal:"12ga", mag:5,  est:true, note:"弹匣供弹；撞火枪托可全自动；弹丸数按 8 计"},
  {zh:"725 双管",  en:"725 Double Barrel", cls:"sg", dmg:136, admg:144, rpm:375, cal:"12ga", mag:2, note:"'众生平等'，双管瞬发两连喷"},
  {zh:"FS-12",    en:"FS-12",           cls:"sg", dmg:112, admg:128, rpm:300, cal:"12ga", mag:6,  note:"S8 新枪；半自动⇄泵动双模式，可折叠进副武器槽"},
  {zh:"AA-12",    en:"AA-12",           cls:"sg", dmg:80,  admg:90,  rpm:320, cal:"12ga", mag:8,  est:true, conflict:"甲伤与弹匣未验证（甲伤按弹丸比例估 90）", note:"S11 新枪；首把原生全自动霰弹，四肢伤害特化"},

  /* ===== 手枪 ===== */
  {zh:"G17",      en:"Glock 17",        cls:"pst", dmg:27, admg:25, rpm:462,  cal:"919",  mag:17, note:"军需 0 级解锁的初始副武器"},
  {zh:"九二改",    en:"QSZ-92G",         cls:"pst", dmg:34, admg:32, rpm:375,  cal:"919",  mag:15, note:"固定弹匣 15 发，27m 优势射程"},
  {zh:"93R",      en:"Beretta 93R",     cls:"pst", dmg:34, admg:32, rpm:672,  cal:"919",  mag:12, burst:true, note:"三连发爆发手枪"},
  {zh:"G18",      en:"Glock 18",        cls:"pst", dmg:23, admg:16, rpm:1172, cal:"919",  mag:17, conflict:"另有来源记 22 肉伤", note:"全自动手枪，全游戏射速最快"},
  {zh:"沙漠之鹰",  en:"Desert Eagle",    cls:"pst", dmg:50, admg:34, rpm:207,  cal:"50ae", mag:7,  note:".50 AE 大口径副武器"},
  {zh:".357 左轮", en:".357 Revolver",   cls:"pst", dmg:56, admg:39, rpm:182,  cal:"357",  mag:6,  note:"双动左轮，弹巢固定 6 发"},
  {zh:"M1911",    en:"M1911",           cls:"pst", dmg:40, admg:30, rpm:373,  cal:"45",   mag:7,  note:"三角洲定制款 .45"}
];
