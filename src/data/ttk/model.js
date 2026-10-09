/* ============================================================
   model.js — TTK 计算模型（纯函数，无 DOM / 无状态）
   自 legacy/ttk.html 模型区一字不差迁移，计算口径保持原样：
   - passRate：弹药穿透等级 × 护甲等级 → 伤害通过率（0 / 50% / 75% / 100%）
   - simulate：逐发模拟"碎甲 — 掉血"，返回击杀所需发数与碎甲用弹数
   - ttkOf：TTK = (BTK − 1) × 60000 / RPM（首发命中即刻出膛，不计入时间）；
     三连发武器（M16A4 / MK4 / 93R）传入的 rpm 即面板持续均值（含 burst 间隔），
     匀速近似：跨 burst 击杀平均误差小，单 burst 内击杀实际更快（burst 内射速高于面板）
   - combo：simulate + ttk 的一站式封装
   ============================================================ */

export function passRate(pen, al){
  if(al <= 0) return 1;
  var d = pen - al;
  if(d < 0) return 0;
  if(d === 0) return 0.5;
  if(d === 1) return 0.75;
  return 1;
}
/* 逐发模拟：返回击杀所需发数与碎甲用弹数 */
export function simulate(gun, am, al, part){
  var mult = part.mult;
  if(gun.belly != null && part.label === "腹部") mult = gun.belly;
  var fleshFull = gun.dmg * (am.flesh || 1) * mult;
  var dur = part.dur(al);
  var admg = gun.admg * (am.amult || 1);
  var pass = dur > 0 ? passRate(am.pen, al) : 1;
  var hp = 100, left = dur, n = 0, broke = 0, guard = 300;
  while(hp > 1e-9 && n < guard){
    n++;
    var d;
    if(left > 0){
      var k = Math.min(1, left / admg);
      d = fleshFull * (k * pass + (1 - k));
      left -= admg; broke++;
    } else {
      d = fleshFull;
    }
    hp -= d;
  }
  return {btk:n, broke:broke, pass:pass, flesh:fleshFull,
          noArmorBtk:Math.max(1, Math.ceil(100 / fleshFull))};
}
export function ttkOf(btk, rpm){ return (btk - 1) * 60000 / rpm; }
export function combo(gun, am, al, part){
  var r = simulate(gun, am, al, part);
  r.gun = gun; r.am = am; r.ttk = ttkOf(r.btk, gun.rpm);
  return r;
}
