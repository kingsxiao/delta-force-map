/* ============================================================
   usePositions.js — 囤货台账的中央存储（localStorage key=ammo-positions）
   ------------------------------------------------------------
   原先台账状态内联在 AmmoMarketView（与星标同模式），账号云同步需要
   跨视图读写，抽为模块级单例：
     · positions 为全站共享的响应式数组（[{name, qty, cost, at?}]，at=记账时刻
       epoch ms 可选，iOS 端同构透传，契约 shared/API.md §6.3）
     · 视图沿用「直接改 positions.value 再调 save()」的既有写法；按弹名
       增改一行走 upsert（字段清洗 + 记账时刻语义收口在此）
     · 变更统一经 save / upsert / replacePositions 收口：持久化 + 订阅通知
       （source: 'save' = 用户编辑，'replace' = 云合并落地）
   ============================================================ */
import { ref } from 'vue'

const POSITIONS_KEY = 'ammo-positions'

function loadPositions() {
  try {
    const raw = JSON.parse(localStorage.getItem(POSITIONS_KEY))
    if (!Array.isArray(raw)) return []
    return raw
      .filter((p) => p && typeof p.name === 'string' && Number.isFinite(+p.qty) && Number.isFinite(+p.cost))
      .map((p) => ({
        name: p.name,
        qty: Math.max(1, Math.round(+p.qty)),
        cost: Math.max(0, +p.cost),
        // at（记账时刻 epoch ms）：旧存档无此字段则不带；非法值剔除
        ...(Number.isFinite(+p.at) && +p.at > 0 ? { at: +p.at } : {}),
      }))
  } catch {
    return []
  }
}

const positions = ref(loadPositions())
const listeners = new Set()

function persist() {
  try {
    // 只存账本事实字段（name/qty/cost/at）：内存里的行对象可能被视图 join 进展示
    // 字段（item/curve 等），整体落盘会污染本地与云端 ledger.ammo（多次编辑即超
    // 64KB 上限）
    localStorage.setItem(POSITIONS_KEY, JSON.stringify(loadSanitized(positions.value)))
  } catch {
    /* 隐私模式等写入失败时仅本次会话生效 */
  }
}

function emitChange(source) {
  for (const fn of listeners) fn(positions.value, source)
}

function commit() {
  persist()
  emitChange('save')
}

/** 台账唯一写入口（原 PositionLedger 内部实现上收：详情页「记入囤货」与
    台账行内编辑/删除共用，不再各自手写落库）。只入账本事实字段——调用方
    可能传 join 行情后的展示对象（含 item/curve），整体入库会污染 localStorage
    与云端 ledger.ammo（多次编辑即超 64KB 上限）。at（记账时刻 epoch ms）：
    显式传入优先；更新已有行不改记账时刻；新行取当下 */
function upsert(p) {
  const i = positions.value.findIndex((x) => x.name === p.name)
  const at = Number.isFinite(p.at) && p.at > 0
    ? p.at
    : (i >= 0 ? positions.value[i].at : Date.now())
  const clean = { name: p.name, qty: p.qty, cost: p.cost, ...(at != null ? { at } : {}) }
  if (i >= 0) positions.value[i] = clean
  else positions.value.push(clean)
  commit()
}

export function usePositions() {
  return {
    positions,
    /** 视图直接改 positions.value 后调用（持久化 + 通知，source='save' 触发云推送）；
        按弹名增改一行请走 upsert，别绕过字段清洗 */
    save: commit,
    upsert,
    /** 云端合并落地（source='replace'，不触发云推送） */
    replacePositions(next) {
      positions.value = loadSanitized(next)
      persist()
      emitChange('replace')
    },
    /** 订阅变更，返回退订函数 */
    onPositionsChange(fn) {
      listeners.add(fn)
      return () => listeners.delete(fn)
    },
  }
}

function loadSanitized(list) {
  if (!Array.isArray(list)) return []
  return list
    .filter((p) => p && typeof p.name === 'string' && Number.isFinite(+p.qty) && Number.isFinite(+p.cost))
    .map((p) => ({
      name: p.name,
      qty: Math.max(1, Math.round(+p.qty)),
      cost: Math.max(0, +p.cost),
      ...(Number.isFinite(+p.at) && +p.at > 0 ? { at: +p.at } : {}),
    }))
}
