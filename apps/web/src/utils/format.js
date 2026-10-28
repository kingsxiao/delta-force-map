/* ============================================================
   format.js — 行情展示格式化（弹药 / 雷达 / 制造页与信号卡共用）
   ------------------------------------------------------------
   收编原先散落 5 个文件的同款本地实现：fmt / pct / fmtSigned /
   SIGNAL_META / SIG_COLOR / gradeVar。收敛口径（两处此前的漂移）：
     · pct 统一「带符号 + 一位小数」（+8.2% / -3.1%）：此前制造页的
       取整实现（+8%）与弹药 / 雷达 / 信号卡的一位小数实现并存；
     · gradeVar 品级下限取 1：制造产物存在 1 级品；弹药 / 雷达数据
       实测品级 2-6，1 级分支对它们只是防御性兜底（1 级给 --lv1
       而非 faint，语义同样成立）。
   纯展示函数，不接触响应式与网络。
   ============================================================ */

/** 整数金额：千分位（zh-CN）；缺失 / 非有限值显「—」 */
export const fmt = (n) => (Number.isFinite(n) ? Math.round(n).toLocaleString('zh-CN') : '—')

/** 带符号百分比（小数传入）：+8.2% / -3.1%；缺失显「—」 */
export const pct = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${(n * 100).toFixed(1)}%` : '—')

/** 带符号金额（浮盈可为负）：+12,345 / -1,024；缺失显「—」 */
export const fmtSigned = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : '-'}${Math.abs(Math.round(n)).toLocaleString('zh-CN')}` : '—')

/** 信号徽章文案与配色类（「数据不足」行走 WAIT 的素文本降级） */
export const SIGNAL_META = {
  BUY: { label: '买入', cls: 'buy' },
  WATCH: { label: '关注', cls: 'watch' },
  SELL: { label: '卖出', cls: 'sell' },
  WAIT: { label: '观望', cls: 'wait' },
}

/** 迷你走势末点语境色（Sparkline endColor）：与行内信号徽章同语义——
    BUY ok / SELL danger / WATCH info / WAIT（含数据不足行）faint */
export const SIG_COLOR = { BUY: 'var(--ok)', SELL: 'var(--danger)', WATCH: 'var(--info)', WAIT: 'var(--faint)' }

/** 品级 → base.css --lv* 语义变量（1 绿 ~ 6 红），界外 faint（内联 style 可用 var()） */
export const gradeVar = (g) => (g >= 1 && g <= 6 ? `var(--lv${g})` : 'var(--faint)')
