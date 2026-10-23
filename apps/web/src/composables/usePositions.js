/* ============================================================
   usePositions.js — 囤货台账的中央存储（localStorage key=ammo-positions）
   ------------------------------------------------------------
   原先台账状态内联在 AmmoMarketView（与星标同模式），账号云同步需要
   跨视图读写，抽为模块级单例：
     · positions 为全站共享的响应式数组（[{name, qty, cost}]）
     · 视图沿用「直接改 positions.value 再调 save()」的既有写法
     · 变更统一经 save / replacePositions 收口：持久化 + 订阅通知
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
      .map((p) => ({ name: p.name, qty: Math.max(1, Math.round(+p.qty)), cost: Math.max(0, +p.cost) }))
  } catch {
    return []
  }
}

const positions = ref(loadPositions())
const listeners = new Set()

function persist() {
  try {
    // 只存账本事实三字段：内存里的行对象可能被视图 join 进展示字段（item/curve 等），
    // 整体落盘会污染本地与云端 ledger.ammo（多次编辑即超 64KB 上限）
    localStorage.setItem(POSITIONS_KEY, JSON.stringify(loadSanitized(positions.value)))
  } catch {
    /* 隐私模式等写入失败时仅本次会话生效 */
  }
}

function emitChange(source) {
  for (const fn of listeners) fn(positions.value, source)
}

export function usePositions() {
  return {
    positions,
    /** 视图改完 positions.value 后调用（持久化 + 通知，source='save' 触发云推送） */
    save() {
      persist()
      emitChange('save')
    },
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
    .map((p) => ({ name: p.name, qty: Math.max(1, Math.round(+p.qty)), cost: Math.max(0, +p.cost) }))
}
