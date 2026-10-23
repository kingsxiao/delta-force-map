/* ============================================================
   useAccount.js — 账号会话与云同步（模块级单例，跨视图共享）
   ------------------------------------------------------------
   职责：
     · 会话：启动时用存量 token 调 /me 恢复（失效即清）；登录 / 注册 /
       登出（服务器使全设备令牌失效 + 清本地）
     · 云同步（口径 shared/API.md §6.3，三项用户创作内容）：
         - stars.ammo 自选星标：并集合并（mergeStars）
         - ledger.ammo 囤货台账：按弹名并集、同名本机优先（mergePositions）
         - mycost.ammo 买入价（SignalCard 自录）：按弹名并集、同名本机优先
         - 登录后拉云端与本地逐项合并落回两端，云端其他键原样保留；
           登录期间星标 / 台账变化 → 2s 防抖回推（推送前先拉最新云端，
           三键按同款口径合并，不用内存旧快照整文档覆盖对端改动）
         - 未登录不动云；登出只清会话，本地数据保留
   云端存什么的原则：只存「用户创作内容」（自选、台账、买入价这类丢了
   会心疼的），不存设备偏好（通知开关等每台设备自己的）——本 composable
   是唯一写云入口，新增同步项在此登记键名并同步更新契约 §6.3。
   ============================================================ */
import { ref } from 'vue'
import {
  authRegister, authLogin, authLogout, authMe,
  getAccountData, putAccountData,
  getStoredSession, setStoredSession, clearStoredSession,
} from '../api/auth.js'
import { mergeStars, mergePositions, mergeLocalWins, normalizeAccountDoc } from '@shared/js/accountData.js'
import { useStars } from './useStars.js'
import { usePositions } from './usePositions.js'

const user = ref(null) // {uid, username, createdAt} | null（未登录）
/** 同步状态：idle 未登录/未同步 | syncing | ok | error（不影响本地功能） */
const syncState = ref('idle')
const syncError = ref('')
const lastSyncAt = ref(null)
/** 云端文档缓存（上推时保留其他键；登录拉取后有效） */
let cloudDoc = {}
let pushTimer = null
let wired = false

const { stars, replaceStars, onStarsChange } = useStars()
const { positions, replacePositions, onPositionsChange } = usePositions()

/** 星标数组快照（上推用；Set → 排序数组与 mergeStars 口径一致） */
const starsList = () => [...stars.value].sort()

const MYCOST_KEY = 'ammo-mycost'

/** SignalCard 自录买入价（{弹名: 成本}；读失败按空对象） */
function loadMycost() {
  try {
    const raw = JSON.parse(localStorage.getItem(MYCOST_KEY))
    return raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
  } catch {
    return {}
  }
}

function saveMycost(map) {
  try {
    localStorage.setItem(MYCOST_KEY, JSON.stringify(map))
  } catch { /* 隐私模式写入失败：仅本次会话生效 */ }
}

async function pullAndMerge() {
  syncState.value = 'syncing'
  syncError.value = ''
  try {
    const token = getStoredSession()?.token
    // 无 token（隐私模式 localStorage 读写全废等极端场景）：复位状态避免卡
    // 「同步中」，账号页如实显示「待同步」；本地星标/台账功能不受影响
    if (!token) {
      syncState.value = 'idle'
      return
    }
    const { data } = await getAccountData(token)
    cloudDoc = normalizeAccountDoc(data) ?? {}
    const mergedStars = mergeStars(starsList(), cloudDoc['stars.ammo'])
    const mergedPositions = mergePositions(positions.value, cloudDoc['ledger.ammo'])
    const mergedMycost = mergeLocalWins(loadMycost(), cloudDoc['mycost.ammo'])
    replaceStars(mergedStars)
    replacePositions(mergedPositions)
    saveMycost(mergedMycost)
    cloudDoc['stars.ammo'] = mergedStars
    cloudDoc['ledger.ammo'] = mergedPositions
    cloudDoc['mycost.ammo'] = mergedMycost
    await putAccountData(token, cloudDoc)
    lastSyncAt.value = new Date()
    syncState.value = 'ok'
  } catch (e) {
    // 令牌已被吊销（他设备登出）/ 过期 → 清会话回未登录（对齐 iOS 的 isAuthExpired 即清）
    if (e?.status === 401) {
      clearStoredSession()
      user.value = null
      syncState.value = 'idle'
      syncError.value = ''
      return
    }
    syncState.value = 'error'
    syncError.value = e?.message || '云同步失败'
  }
}

/** 防抖上推（失败转手动「立即同步」恢复）：推送前先 GET 云端现值，三键按
    §6.3 口径（星标并集 / 台账·买入价同名本机优先）合并进最新云端再回推——
    多端并发时后推者不用旧快照整文档覆盖对端改动，云端其他键也原样保留
    （登录拉取未完成的窗口内推送同样安全） */
function schedulePush() {
  if (!user.value) return
  clearTimeout(pushTimer)
  pushTimer = setTimeout(async () => {
    const token = getStoredSession()?.token
    if (!token) return
    try {
      const { data } = await getAccountData(token)
      const remote = normalizeAccountDoc(data) ?? {}
      const doc = {
        ...remote,
        'stars.ammo': mergeStars(starsList(), remote['stars.ammo']),
        'ledger.ammo': mergePositions(positions.value, remote['ledger.ammo']),
        'mycost.ammo': mergeLocalWins(loadMycost(), remote['mycost.ammo']),
      }
      await putAccountData(token, doc)
      cloudDoc = doc
      lastSyncAt.value = new Date()
      syncState.value = 'ok'
    } catch (e) {
      if (e?.status === 401) {
        clearStoredSession()
        user.value = null
        syncState.value = 'idle'
        syncError.value = ''
        return
      }
      syncState.value = 'error'
      syncError.value = e?.message || '云同步失败'
    }
  }, 2000)
}

/** 星标 / 台账变化 → 云推送的接线（模块单例只挂一次） */
function wireStarsSync() {
  if (wired) return
  wired = true
  onStarsChange((_, source) => {
    // replace 来自云合并落地，不再回推（避免推拉循环）
    if (source === 'toggle') schedulePush()
  })
  onPositionsChange((_, source) => {
    if (source === 'save') schedulePush()
  })
}

/** 启动恢复：token 有效则恢复会话并拉一次云端（静默失败不打扰） */
async function restore() {
  const stored = getStoredSession()
  if (!stored?.token) return
  try {
    const me = await authMe(stored.token)
    user.value = me
    wireStarsSync()
    await pullAndMerge()
  } catch (e) {
    // 令牌失效（登出过 / 过期）→ 清会话；网络失败保留 token 下次再试
    if (e?.status === 401) clearStoredSession()
  }
}

async function login(username, password) {
  const session = await authLogin({ username, password })
  setStoredSession(session)
  user.value = session.user
  wireStarsSync()
  await pullAndMerge()
  return session.user
}

async function register(username, password) {
  const session = await authRegister({ username, password })
  setStoredSession(session)
  user.value = session.user
  wireStarsSync()
  await pullAndMerge()
  return session.user
}

/** 登出：服务器失效全部令牌（best-effort）→ 清本地会话；本地星标保留 */
async function logout() {
  const token = getStoredSession()?.token
  clearStoredSession()
  user.value = null
  syncState.value = 'idle'
  syncError.value = ''
  cloudDoc = {}
  clearTimeout(pushTimer)
  if (token) {
    try { await authLogout(token) } catch { /* 服务器不可达也已清本地 */ }
  }
}

/** 手动立即同步（账号页按钮；登录后可用） */
async function syncNow() {
  if (!user.value) return
  await pullAndMerge()
}

/** 供 router 守卫/入口用：恢复完成前避免闪烁（不阻塞路由） */
const ready = ref(false)
restore().finally(() => { ready.value = true })

export function useAccount() {
  return { user, syncState, syncError, lastSyncAt, ready, login, register, logout, syncNow }
}
