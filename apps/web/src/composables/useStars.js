/* ============================================================
   useStars.js — 子弹自选星标的中央存储（localStorage key=ammo-stars）
   ------------------------------------------------------------
   原先星标状态内联在 AmmoMarketView，账号云同步需要跨视图读写
   （账号页合并云端、行情页点星标），抽为模块级单例：
     · stars 为全站共享的响应式 Set（组件直接 v-model 不了 Set，
       消费方仍按 has() 读，与原实现口径一致）
     · 变更统一走 toggleStar / replaceStars，持久化与订阅通知在此收口
   ============================================================ */
import { ref } from 'vue'

const STARS_KEY = 'ammo-stars'

function loadStars() {
  try {
    const raw = JSON.parse(localStorage.getItem(STARS_KEY))
    return new Set(Array.isArray(raw) ? raw.filter((n) => typeof n === 'string') : [])
  } catch {
    return new Set()
  }
}

const stars = ref(loadStars())
const listeners = new Set()

function persist() {
  try {
    localStorage.setItem(STARS_KEY, JSON.stringify([...stars.value]))
  } catch {
    /* 隐私模式等写入失败时仅本次会话生效 */
  }
}

function emitChange(source) {
  for (const fn of listeners) fn([...stars.value], source)
}

export function useStars() {
  return {
    stars,
    /** 单个切换（行情页星标按钮） */
    toggleStar(name) {
      const next = new Set(stars.value)
      if (next.has(name)) next.delete(name)
      else next.add(name)
      stars.value = next
      persist()
      emitChange('toggle')
    },
    /** 整体替换（云同步合并落地）；names 为弹名数组 */
    replaceStars(names) {
      const next = new Set(names.filter((n) => typeof n === 'string'))
      stars.value = next
      persist()
      emitChange('replace')
    },
    /** 订阅变更（source: 'toggle' | 'replace'），返回退订函数 */
    onStarsChange(fn) {
      listeners.add(fn)
      return () => listeners.delete(fn)
    },
  }
}
