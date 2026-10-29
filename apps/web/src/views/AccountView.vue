<script setup>
/* ============================================================
   AccountView — 账号与云同步（/account）
   ------------------------------------------------------------
   四态：会话恢复中（ready 门控的短暂加载态，避免登录表单闪现）/
   未登录（分栏登录 / 注册舞台） / 已登录（用户信息 + 云同步
   状态 + 立即同步 + 退出登录·两步确认）。同步对象是三项用户创作内容
   （契约 §6.3：自选星标并集 / 台账按名合并 / 买入价按键合并）；登录失败
   按 code 给可行动的中文提示。
   未登录态为「价值面板 + 表单卡」分栏舞台（≥820px 双栏，窄屏表单
   优先单栏）：左面板承接品牌叙事（为什么登录），右卡片只留表单本
   身；登录 / 注册切换走「底部文字链」而非分段控件——单一主操作 +
   上下文切换，是登录页的成熟范式。
   ============================================================ */
import { computed, nextTick, onMounted, reactive, ref, watch } from 'vue'
import { useAccount } from '../composables/useAccount'
import { useStars } from '../composables/useStars'
import { usePositions } from '../composables/usePositions'
import { useReveal } from '../composables/useReveal'
import { AuthApiError } from '../api/auth'

const { user, syncState, syncError, lastSyncAt, ready, login, register, logout, syncNow } = useAccount()
const { stars } = useStars()
const { positions } = usePositions()

const ledgerCount = computed(() => positions.value.length)
/* 买入价读数必须挂响应式依赖：mycostMap() 只读 localStorage（非响应式源），零依赖
   computed 首算后永不失效（Vue 惰性求值 + 缓存，已实测）——账号页停留时点「立即
   同步」，云端买入价合并落库（useAccount 的 saveMycost）后本读数与 syncEmpty 仍停
   留旧值；stars / positions 是 ref 会即时刷新，唯独 mycost 对用户撒谎。读 lastSyncAt
   建立依赖：它在每次成功同步落库的同一时刻被更新（useAccount.js 的 pullAndMerge /
   schedulePush 尾部），失效时机与数据写盘严格同步，不多算一次也不少算一次 */
const mycostCount = computed(() => {
  void lastSyncAt.value
  return Object.keys(mycostMap()).length
})
/* 三项同步内容全零 = 还没有可同步的数据：读数行会连说三个 0 并声称「已并入云端」，
   语义失真——换一条带出路的空态文案（去哪产生数据），任一项有数据即恢复读数 */
const syncEmpty = computed(
  () => stars.value.size === 0 && ledgerCount.value === 0 && mycostCount.value === 0
)
function mycostMap() {
  try {
    const raw = JSON.parse(localStorage.getItem('ammo-mycost'))
    return raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {}
  } catch {
    return {}
  }
}

/* ---------- 入场（全站 useReveal 范式；未登录舞台走级联） ---------- */
const rootEl = ref(null)
const { observeRoot } = useReveal()
onMounted(() => observeRoot(rootEl.value))
/* observeRoot 只在挂载时查询一次节点；ready / user 翻转后 v-if/v-else 重建的
   .reveal / .reveal-group 是新节点，若不重挂观察会永远停在 opacity:0
   （登录成功 / 刷新恢复会话都会触发）——状态翻转后补一次观察。 */
watch([ready, user], () => nextTick(() => observeRoot(rootEl.value)))
/* 三态舞台套了 out-in 过渡（见模板）：新舞台要等旧节点淡出完才插入，上面 watch
   的 nextTick 那一刻它还不在 DOM 里，observeRoot 会扑空、新 .reveal 永远停在
   opacity:0——@enter 在节点插入后立刻触发，这里补挂一次（observeRoot 只观察尚未
   .in 的节点，重复调用无副作用；watch 保留给 RM 等过渡被关成瞬时的场景兜底） */
function onStageEnter() { observeRoot(rootEl.value) }

/* ---------- 表单 ---------- */
const mode = ref('login') // login | register
const form = reactive({ username: '', password: '' })
const submitting = ref(false)
const formError = ref('')
const formErrorTip = ref('') // NETWORK 错误的次要开发者提示（title 悬浮可见，不打扰线上用户）
const syncing = ref(false)
const showPw = ref(false) // 密码可见性
const capsOn = ref(false) // 大写锁定提示（仅按键期间可探测）
const touched = reactive({ username: false, password: false }) // 失焦后才亮红，避免边打边报错

/* 与服务端同口径（server/auth/store.mjs 的 /^\p{L}\p{N}_$/u）：2–16 位任意
   Unicode 字母 / 数字 / 下划线——预检不得比服务端窄，否则此类账号在本端永远无法登录 */
const USER_RE = /^[\p{L}\p{N}_]{2,16}$/u
const usernameOk = computed(() => USER_RE.test(form.username))
const passwordOk = computed(() => form.password.length >= 8)

const canSubmit = computed(
  () => !submitting.value && usernameOk.value && passwordOk.value
)

/* 字段状态行：空 → 中性提示；失焦且不合规 → 红；合规 → 绿勾（只此三态） */
const userSt = computed(() => {
  if (usernameOk.value) return { cls: 'ok', text: '' }
  if (touched.username) return { cls: 'bad', text: '2–16 位字母 / 数字 / 下划线，各类文字均可' }
  return { cls: '', text: '2–16 字符' }
})
const pwSt = computed(() => {
  if (passwordOk.value) return { cls: 'ok', text: '' }
  if (touched.password) return { cls: 'bad', text: '至少 8 位' }
  return { cls: '', text: mode.value === 'register' ? '至少 8 位' : '' }
})

function switchMode(m) {
  if (mode.value === m) return
  mode.value = m
  formError.value = ''
  formErrorTip.value = ''
  touched.username = false
  touched.password = false
}

/** 按 code 翻译成可行动提示（契约 §6.2 的错误码） */
function friendlyError(e) {
  if (!(e instanceof AuthApiError)) return e?.message || '操作失败，请稍后再试'
  if (e.code === 'USERNAME_TAKEN') return '这个用户名已被注册，换一个试试'
  if (e.code === 'AUTH_FAILED') return '用户名或密码不对，请检查后重试'
  if (e.code === 'INVALID_USERNAME') return '用户名需 2–16 个字符（字母 / 数字 / 下划线，各类文字均可）'
  if (e.code === 'INVALID_PASSWORD') return '密码需 8–64 个字符'
  if (e.code === 'RATE_LIMITED') return e.message
  // 主文案面向线上用户；本地部署排查提示（npm run serve）降级为 title 悬浮
  if (e.code === 'NETWORK') {
    formErrorTip.value = '开发者排查：本地需先 npm run serve（dev 由代理转发）'
    return '连接服务器失败，请检查网络后重试'
  }
  return e.message
}

async function submit() {
  // 回车提交（按钮禁用挡不住 Enter）：先亮出字段错误再拦下，不静默吞掉
  touched.username = true
  touched.password = true
  if (!canSubmit.value) return
  submitting.value = true
  formError.value = ''
  formErrorTip.value = ''
  try {
    if (mode.value === 'login') await login(form.username.trim(), form.password)
    else await register(form.username.trim(), form.password)
    form.password = ''
  } catch (e) {
    formError.value = friendlyError(e)
  } finally {
    submitting.value = false
  }
}

/** 大写锁定探测：仅在 keydown/keyup 事件里可靠（W3C getModifierState） */
function capsCheck(e) {
  if (typeof e.getModifierState === 'function') capsOn.value = e.getModifierState('CapsLock')
}

/* 显隐切换不夺输入焦点（mousedown 预防默认 + click 切换） */
function togglePw() { showPw.value = !showPw.value }

async function onSyncNow() {
  if (syncing.value) return
  syncing.value = true
  try { await syncNow() } finally { syncing.value = false }
}

/* ---------- 退出登录：两步确认（防误触） ----------
   退出会让服务器吊销全部设备令牌（useAccount.logout），属高影响操作、
   移动端易误触：首次点击只进入「确认」态（按钮变红改文案），3 秒内
   再点才真正退出；超时 / 失焦 / Esc 自动回退到安全态。 */
const confirmLogout = ref(false)
let logoutTimer = null
function onLogout() {
  if (confirmLogout.value) {
    resetLogout()
    logout()
    return
  }
  confirmLogout.value = true
  clearTimeout(logoutTimer)
  // 3s 与样式里 .logout.arming::before 倒计时条的 animation 时长成对，改一处同改另一处
  logoutTimer = setTimeout(() => { confirmLogout.value = false }, 3000)
}
function resetLogout() {
  clearTimeout(logoutTimer)
  confirmLogout.value = false
}

const syncStateText = computed(() => ({
  idle: user.value ? '待同步' : '未登录',
  syncing: '同步中…',
  ok: '已同步',
  error: '同步失败',
}[syncState.value] ?? ''))

const lastSyncText = computed(() => {
  if (!lastSyncAt.value) return '—'
  return lastSyncAt.value.toLocaleString('zh-CN', { hour12: false })
})
</script>

<template>
  <main ref="rootEl" class="wrap account-page">
    <!-- 页头（紧凑单行，直接走 base.css .compact-head：h1 + 右置 .meta，
         与 TTK / 子弹 / 雷达同构；不再套 .wrap——外层 main 已是 .wrap，
         嵌套会让分隔线比正文窄 56px） -->
    <div class="compact-head">
      <h1>账号</h1>
      <p class="meta">自选星标云同步 · 换设备不丢</p>
    </div>

    <!-- 三态舞台（下方三个 v-if 分支）互切走 .swap out-in：旧舞台先淡出、新舞台再
         淡入上移（MOTION §2.1 / §3-H）——登录成功的「翻面」、会话恢复完成、退出登录
         是本页最大的状态变化时刻，此前瞬时硬切。out-in 让两套高度不同的卡片不同屏，
         避免并行模式下页面高度翻倍的跳动；@enter 补挂 .reveal 观察（见 script） -->
    <Transition name="swap" mode="out-in" @enter="onStageEnter">
    <!-- ============ 会话恢复中：短暂加载态（避免登录表单闪现后翻面） ============ -->
    <section v-if="!ready" class="card pend" role="status" aria-label="正在恢复登录状态">
      <span class="pend-spin" aria-hidden="true"></span>
      正在恢复登录状态…
    </section>

    <!-- ============ 未登录：价值面板 + 表单卡 的分栏舞台 ============ -->
    <section v-else-if="!user" class="auth-stage reveal-group" aria-label="登录或注册">
      <!-- 左：品牌叙事（为什么登录） -->
      <aside class="auth-hero" style="--ri: 0">
        <p class="hero-kicker">三角洲行动 · 云同步</p>
        <h2 class="hero-title">换台设备，<br>数据随身带</h2>
        <p class="hero-lede">
          一个账号，把自选、台账与买入价同步到每一台设备；登录即自动合并，任何一端的数据都不会丢。
        </p>
        <ul class="hero-feats">
          <li>
            <i class="feat-mark" aria-hidden="true"></i>
            <div>
              <b>自选星标</b>
              <span>多端并集合并，标过的都在</span>
            </div>
          </li>
          <li>
            <i class="feat-mark" aria-hidden="true"></i>
            <div>
              <b>囤货台账</b>
              <span>按弹名合并，同名以本机为准</span>
            </div>
          </li>
          <li>
            <i class="feat-mark" aria-hidden="true"></i>
            <div>
              <b>买入价</b>
              <span>卡片上自录的成本随账号走</span>
            </div>
          </li>
        </ul>
        <p class="hero-foot">
          <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5a2.5 2.5 0 0 1 2.5 2.5v1.5h.5a1.5 1.5 0 0 1 1.5 1.5v6A1.5 1.5 0 0 1 11 14.5H5A1.5 1.5 0 0 1 3.5 13V7A1.5 1.5 0 0 1 5 5.5h.5V4A2.5 2.5 0 0 1 8 1.5Zm0 1.2A1.3 1.3 0 0 0 6.7 4v1.5h2.6V4A1.3 1.3 0 0 0 8 2.7Z" fill="currentColor"/></svg>
          数据只存放在你自己部署的服务器上，不经过第三方
        </p>
      </aside>

      <!-- 右：表单卡（单一主操作；登录 / 注册由底部文字链切换） -->
      <div class="auth-card" style="--ri: 1">
        <!-- 登录/注册切换只换卡头（标题 + 副题）：.25s out-in 上移淡切；字段与已输入
             内容不动——整卡换 key 会重建输入框丢焦点，得不偿失 -->
        <Transition name="swap" mode="out-in">
          <div :key="mode" class="ac-head">
            <h3 class="ac-title">{{ mode === 'login' ? '欢迎回来' : '创建账号' }}</h3>
            <p class="ac-sub">
              {{ mode === 'login' ? '登录后开启自选星标云端同步' : '注册即自动登录，本机数据与云端合并' }}
            </p>
          </div>
        </Transition>

        <form novalidate @submit.prevent="submit()">
          <div class="f-group">
            <div class="f-row">
              <label class="f-k" for="auth-user">用户名</label>
              <span id="user-st" class="f-st" :class="userSt.cls">
                <svg v-if="userSt.cls === 'ok'" class="st-ic" viewBox="0 0 16 16" aria-hidden="true"><path d="m3 8.6 3.2 3.2L13 5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>{{ userSt.text }}
              </span>
            </div>
            <input
              id="auth-user" v-model.trim="form.username" class="f-in"
              :class="{ bad: touched.username && !usernameOk }"
              type="text" autocomplete="username" autocapitalize="off" spellcheck="false"
              placeholder="2–16 个字符，字母 / 数字 / 下划线，各类文字均可"
              maxlength="16" required aria-describedby="user-st"
              :aria-invalid="touched.username && !usernameOk ? 'true' : undefined"
              @blur="touched.username = true"
            >
          </div>

          <div class="f-group">
            <div class="f-row">
              <label class="f-k" for="auth-pass">密码</label>
              <span id="pass-st" class="f-st" :class="pwSt.cls">
                <svg v-if="pwSt.cls === 'ok'" class="st-ic" viewBox="0 0 16 16" aria-hidden="true"><path d="m3 8.6 3.2 3.2L13 5" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>{{ pwSt.text }}
              </span>
            </div>
            <div class="f-in-wrap">
              <input
                id="auth-pass" v-model="form.password" class="f-in mono"
                :class="{ bad: touched.password && !passwordOk }"
                :type="showPw ? 'text' : 'password'"
                :autocomplete="mode === 'login' ? 'current-password' : 'new-password'"
                placeholder="至少 8 个字符" required minlength="8" maxlength="64"
                :aria-describedby="capsOn ? 'pass-st caps-warn' : 'pass-st'"
                :aria-invalid="touched.password && !passwordOk ? 'true' : undefined"
                @blur="touched.password = true; capsOn = false"
                @keydown="capsCheck" @keyup="capsCheck"
              >
              <button
                type="button" class="pw-toggle"
                :aria-pressed="String(showPw)"
                :aria-label="showPw ? '隐藏密码' : '显示密码'"
                @mousedown.prevent @click="togglePw"
              >
                <svg v-if="!showPw" viewBox="0 0 20 20" aria-hidden="true"><path d="M10 4.5c-3.6 0-6.6 2.2-8 5.5 1.4 3.3 4.4 5.5 8 5.5s6.6-2.2 8-5.5c-1.4-3.3-4.4-5.5-8-5.5Zm0 9.2a3.7 3.7 0 1 1 0-7.4 3.7 3.7 0 0 1 0 7.4Zm0-1.6a2.1 2.1 0 1 0 0-4.2 2.1 2.1 0 0 0 0 4.2Z" fill="currentColor"/></svg>
                <svg v-else viewBox="0 0 20 20" aria-hidden="true"><path d="M2.7 2.7a.9.9 0 0 0 0 1.3l1.9 1.9C2.8 7.3 1.5 9 1 10c1.4 3.3 4.4 5.5 8 5.5 1.5 0 2.9-.4 4.2-1.1l2.5 2.6a.9.9 0 0 0 1.3-1.3L4 2.7a.9.9 0 0 0-1.3 0Zm5.5 2.8 4.9 4.9a3.7 3.7 0 0 1-4.9-4.9ZM10 4.5c-.6 0-1.2.1-1.8.2l1.5 1.5a2.1 2.1 0 0 1 2.5 2.5l3.5 3.5c1-.9 1.8-2 2.3-3.2-1.4-3.3-4.4-5.5-8-5.5Z" fill="currentColor"/></svg>
              </button>
            </div>
            <Transition name="swap">
              <p v-if="capsOn" id="caps-warn" class="caps-warn" aria-live="polite">
                <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.8 14.4 12H1.6L8 1.8Zm-.9 4v3.4h1.8V5.8H7.1Zm0 4.4v1.7h1.8v-1.7H7.1Z" fill="currentColor"/></svg>
                已开启大写锁定
              </p>
            </Transition>
          </div>

          <button class="submit" type="submit" :class="{ busy: submitting }" :disabled="!canSubmit" :aria-busy="submitting">
            <span v-if="submitting" class="spinner" aria-hidden="true"></span>
            {{ submitting ? (mode === 'login' ? '登录中…' : '注册中…') : mode === 'login' ? '登录' : '注册并登录' }}
          </button>
        </form>

        <Transition name="swap">
          <p v-if="formError" class="form-err" role="alert" :title="formErrorTip || undefined">
            <svg viewBox="0 0 16 16" aria-hidden="true"><path d="M8 1.5A6.5 6.5 0 1 0 8 14.5 6.5 6.5 0 0 0 8 1.5ZM7.3 4.5h1.4v5H7.3v-5Zm0 5.9h1.4v1.4H7.3v-1.4Z" fill="currentColor"/></svg>
            {{ formError }}
          </p>
        </Transition>

        <div class="ac-switch">
          <span>{{ mode === 'login' ? '还没有账号？' : '已有账号？' }}</span>
          <button type="button" :disabled="submitting" @click="switchMode(mode === 'login' ? 'register' : 'login')">
            {{ mode === 'login' ? '创建账号' : '直接登录' }}
          </button>
        </div>

        <p class="ac-note">
          账号仅用于多设备同步自选星标、囤货台账与买入价；请勿使用与其他网站相同的密码，也不要往账号数据里存敏感信息。
        </p>
      </div>
    </section>

    <!-- ============ 已登录：账号信息 + 云同步 ============ -->
    <section v-else class="card logged-in reveal" aria-label="账号信息">
      <div class="who">
        <span class="avatar" aria-hidden="true">{{ user.username.slice(0, 1).toUpperCase() }}</span>
        <div class="who-main">
          <p class="name" :title="user.username">{{ user.username }}</p>
          <p class="meta">注册于 {{ new Date(user.createdAt).toLocaleDateString('zh-CN') }}</p>
        </div>
        <button
          class="logout" :class="{ arming: confirmLogout }"
          :aria-pressed="String(confirmLogout)"
          @click="onLogout" @blur="resetLogout" @keydown.esc="resetLogout"
        >{{ confirmLogout ? '确认退出？' : '退出登录' }}</button>
      </div>

      <!-- role="status" 只挂 sync-v：live region 若挂在整盒（原写法），idle→syncing→ok 每次
           状态翻转读屏都会把盒内按钮文字与三行计数一并重播；收窄到状态文本单点，
           播报的正是用户要听的那句（按钮/计数各有自身语义，不该卷进状态播报） -->
      <div class="sync-box" :class="syncState">
        <div class="sync-line">
          <span class="sync-dot" aria-hidden="true"></span>
          <span class="sync-k">云端同步</span>
          <span class="sync-v" role="status">{{ syncStateText }}</span>
          <button class="sync-btn" :class="{ busy: syncing }" :disabled="syncing" :aria-busy="syncing" @click="onSyncNow">
            <svg v-if="!syncing" viewBox="0 0 16 16" aria-hidden="true"><path d="M8 2.5a5.5 5.5 0 1 0 5.3 7h-1.6A4 4 0 1 1 8 4v2l3-2.5L8 1v1.5Z" fill="currentColor"/></svg>
            <!-- 同步中换共享层 12px 进度环（.mini-spin，进度语义 RM 下保留）：
                 按钮禁用 + 文案 + 内联环三件套构成完整进度反馈 -->
            <i v-else class="mini-spin" aria-hidden="true"></i>
            {{ syncing ? '同步中…' : '立即同步' }}
          </button>
        </div>
        <!-- 全零空态：三个 0 的读数行换成「去哪产生数据」的出路文案（空态给一条出路）；
             时间戳保留——同步机制仍在工作的证据不该随空态一起消失 -->
        <p v-if="syncEmpty" class="sync-detail">
          还没有可同步的内容——在行情页点亮星标、或记一笔囤货台账，下次同步会自动带上
          · <span class="sync-last">上次同步 {{ lastSyncText }}</span>
        </p>
        <p v-else class="sync-detail">
          自选 <b>{{ stars.size }}</b> 项 · 囤货台账 <b>{{ ledgerCount }}</b> 条 · 买入价 <b>{{ mycostCount }}</b> 条已并入云端
          · <span class="sync-last">上次同步 {{ lastSyncText }}</span>
          <!-- 机制说明拆出独立行（对齐 iOS 端信息分层：读数行干净，合并规则放 footer，
               AccountView.swift:159）：原先 15 字括号混在读数句中段，「N 条已并入云端」
               的因果读法被规则文本拦腰打断，扫读时主数字还要跳过一行术语 -->
          <span class="sync-rule">星标并集 / 台账按弹名合并 · 同名本机优先</span>
        </p>
        <!-- 同步失败提示与 form-err / caps-warn 同口径：淡入淡出（MOTION §3-F），
             不再瞬现瞬隐——error↔idle 切换正是「状态变化」动效该服务的场景 -->
        <Transition name="swap">
          <p v-if="syncState === 'error'" class="sync-err" role="alert">{{ syncError }}。可点「立即同步」重试，本地功能不受影响。</p>
        </Transition>
      </div>

      <p class="hint">退出会同时让所有已登录设备下线；本机的自选、台账与买入价保留，只是不再同步。</p>
    </section>
    </Transition>
  </main>
</template>

<style scoped>
.account-page { padding-top: var(--sp-6); padding-bottom: var(--sp-8); }
/* 页头走 base.css .compact-head（单行式），无本地覆盖 */

/* ============================================================
   未登录 · 分栏舞台：左价值面板（弹性）+ 右表单卡（定宽 400）
   ============================================================ */
.auth-stage {
  display: grid;
  grid-template-columns: minmax(0, 1fr) 400px;
  gap: var(--sp-6);
  align-items: stretch;
  max-width: 920px;
  margin: var(--sp-6) auto 0;
}

/* ---- 左：价值面板（HUD 括线 + 纵向渐变，同 sig-card 视觉锚点） ---- */
.auth-hero {
  position: relative;
  display: flex; flex-direction: column;
  padding: var(--sp-6);
  background: linear-gradient(180deg, var(--card2) 0%, var(--card) 58%);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  box-shadow: var(--edge-light);
}
/* HUD 对角括线：左上 / 右下 L 形，accent-dim 静态点亮（描边专用色） */
.auth-hero::before,
.auth-hero::after {
  content: '';
  position: absolute;
  width: 12px; height: 12px;
  border: 0 solid var(--accent-dim);
  pointer-events: none;
}
.auth-hero::before { top: 7px; left: 7px; border-top-width: 2px; border-left-width: 2px; }
.auth-hero::after { bottom: 7px; right: 7px; border-bottom-width: 2px; border-right-width: 2px; }

.hero-kicker {
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  letter-spacing: .26em;
  color: var(--accent);
}
.hero-title {
  margin-top: var(--sp-3);
  font-size: var(--fs-2xl);
  font-weight: 700;
  letter-spacing: .02em;
  line-height: 1.3;
  color: var(--tx-strong);
}
.hero-lede { margin-top: var(--sp-3); color: var(--dim); font-size: var(--fs-sm); line-height: var(--lh-body); }

.hero-feats {
  margin-top: var(--sp-5);
  padding-top: var(--sp-5);
  border-top: 1px solid var(--line2);
  display: flex; flex-direction: column; gap: var(--sp-4);
  list-style: none;
}
.hero-feats li { display: flex; gap: var(--sp-3); align-items: flex-start; }
/* 菱形锚点：与顶栏 brand-glyph 同一几何语言（对齐 b 首行视觉中心：
   fs-sm × lh 1.7 ≈ 22px 行框，中心 11px，8px 菱形取 margin-top 7px） */
.feat-mark {
  flex: none;
  width: 8px; height: 8px;
  margin-top: 7px;
  background: var(--accent);
  transform: rotate(45deg);
  box-shadow: 0 0 10px rgba(45, 212, 191, .35);
}
.hero-feats b { display: block; color: var(--tx); font-size: var(--fs-sm); font-weight: 600; letter-spacing: .02em; }
.hero-feats span { display: block; margin-top: 2px; color: var(--faint); font-size: var(--fs-xs); }

.hero-foot {
  margin-top: auto;
  padding-top: var(--sp-5);
  display: flex; align-items: center; gap: var(--sp-2);
  color: var(--faint); font-size: var(--fs-2xs);
  font-family: var(--mono); letter-spacing: .04em;
}
.hero-foot svg { flex: none; width: 13px; height: 13px; color: var(--dim); }

/* ---- 右：表单卡 ---- */
.auth-card {
  display: flex; flex-direction: column;
  padding: var(--sp-6);
  background: var(--card);
  border: 1px solid var(--line);
  border-radius: var(--radius-lg);
  box-shadow: var(--edge-light);
}
.ac-title { font-size: var(--fs-xl); font-weight: 700; letter-spacing: .02em; color: var(--tx-strong); }
.ac-sub { margin-top: var(--sp-2); color: var(--dim); font-size: var(--fs-sm); }
form { margin-top: var(--sp-5); display: flex; flex-direction: column; }

/* 字段组：标签行（等宽字标签 + 右侧状态）+ 输入 */
.f-group { margin-bottom: var(--sp-4); }
.f-row {
  display: flex; align-items: baseline; justify-content: space-between; gap: var(--sp-3);
  margin-bottom: var(--sp-2);
}
.f-k {
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  letter-spacing: .16em;
  color: var(--dim);
}
.f-st {
  font-family: var(--mono);
  font-size: var(--fs-2xs);
  color: var(--faint);
  display: inline-flex; align-items: center; gap: 4px;
  transition: color var(--t-fast) var(--ease); /* 中性→红→绿随校验结果平滑换色（状态过渡，无布局成本） */
}
.f-st.bad { color: var(--danger); }
/* 校验通过是 success 语义：与同页 .sync-box.ok 的「已同步」同语义同色（--ok 是 base.css
   反馈色段的成功位），--accent 收回「强调 / 选中」本职——同页同义不双色（语义色纪律） */
.f-st.ok { color: var(--ok); }
.st-ic { width: 11px; height: 11px; }

.f-in-wrap { position: relative; }
.f-in {
  width: 100%; box-sizing: border-box;
  background: var(--bg2); border: 1px solid var(--line); border-radius: var(--radius);
  color: var(--tx); font-size: var(--fs-md); padding: 10px 12px;
  transition: border-color var(--t-fast) var(--ease), box-shadow var(--t-fast) var(--ease);
}
.f-in:hover { border-color: var(--line-hover); }
.f-in:focus {
  outline: none;
  border-color: var(--accent);
  box-shadow: 0 0 0 3px var(--accent-bg);
}
/* 失焦后仍不合规才亮红边；聚焦时交还焦点态，不打断修改 */
.f-in.bad:not(:focus) { border-color: var(--danger); }
.f-in::placeholder { color: var(--faint); font-size: var(--fs-xs); }
.f-in.mono { font-family: var(--mono); letter-spacing: .04em; }
.f-in-wrap .f-in { padding-right: 40px; }

/* 深色表单的浏览器自动填充底色修正（Chrome 黄底 → 本站 bg2） */
.f-in:-webkit-autofill {
  -webkit-box-shadow: 0 0 0 1000px var(--bg2) inset;
  -webkit-text-fill-color: var(--tx);
  caret-color: var(--tx);
}

/* 密码显隐按钮：输入框内右侧，不夺焦点（mousedown 已 prevent） */
.pw-toggle {
  position: absolute; top: 50%; right: 4px;
  transform: translateY(-50%);
  display: inline-flex; align-items: center; justify-content: center;
  width: 30px; height: 30px;
  border: 0; background: none; border-radius: var(--radius-sm);
  color: var(--faint); cursor: pointer;
  transition: color var(--t-fast) var(--ease), background var(--t-fast) var(--ease);
}
.pw-toggle:hover { color: var(--tx); background: var(--lift); }
/* 触屏点按只有瞬态 :active、没有 hover——补按压态，hover 提示不独享给鼠标 */
.pw-toggle:active { color: var(--tx); background: var(--lift); }
.pw-toggle svg { width: 17px; height: 17px; }

.caps-warn {
  display: flex; align-items: center; gap: 5px;
  margin-top: var(--sp-2);
  color: var(--warn); font-size: var(--fs-xs);
}
.caps-warn svg { width: 12px; height: 12px; flex: none; }

/* 主按钮：全宽主色实心；hover 提亮 / 按下下沉（与顶栏 tab 同「按实」语言） */
.submit {
  width: 100%; margin-top: var(--sp-2);
  display: inline-flex; align-items: center; justify-content: center; gap: var(--sp-2);
  background: var(--accent); border: none; border-radius: var(--radius);
  color: var(--bg); font-size: var(--fs-md); font-weight: 700; letter-spacing: .06em;
  padding: 11px 0; cursor: pointer;
  transition: background var(--t-fast) var(--ease), opacity var(--t-fast) var(--ease), transform var(--t-fast) var(--ease);
}
.submit:hover:not(:disabled) { background: var(--accent-soft); }
.submit:active:not(:disabled) { transform: translateY(1px); }
.submit:disabled { opacity: .45; cursor: not-allowed; }
/* 提交中不随 disabled 压暗：spinner 本身就是「进行中」反馈，半透明会削弱它（busy 保持全不透明） */
.submit:disabled.busy { opacity: 1; cursor: default; }
.spinner {
  width: 14px; height: 14px; flex: none;
  border-radius: 50%;
  border: 2px solid rgba(13, 16, 19, .3); /* --bg 派生（主按钮上的半透明轨道） */
  border-top-color: var(--bg);
  /* fade-in：进度环进场淡入（150ms 对齐 iOS animFast + .transition(.opacity) 的提交
     spinner 口径，AccountView.swift:273）——环原先随 v-if 瞬现，点击后的第一帧反馈
     生硬；离场保持瞬删（文案同时切回，完成信号已可感，双向淡出是多余动效） */
  animation: spin .7s linear infinite, fade-in var(--t-fast) var(--ease);
}
@keyframes spin { to { transform: rotate(1turn); } }
@keyframes fade-in { from { opacity: 0; } }

/* 错误条：警示图标 + 外层 <Transition name="swap"> 淡入淡出 + 抖动一次（每次 v-if
   重挂重新播放）；抖动时长收编 --t-panel .25s（MOTION.md §5 表单错误行的档位登记） */
.form-err {
  display: flex; align-items: flex-start; gap: var(--sp-2);
  margin-top: var(--sp-4);
  padding: var(--sp-3);
  border: 1px solid rgba(217, 106, 89, .45); /* --danger 派生 */
  border-radius: var(--radius);
  background: rgba(217, 106, 89, .08);
  color: var(--danger); font-size: var(--fs-sm); line-height: 1.6;
  animation: shake var(--t-panel) var(--ease);
}
.form-err svg { width: 14px; height: 14px; flex: none; margin-top: 3px; }
@keyframes shake {
  10%, 90% { transform: translateX(-1px); }
  20%, 80% { transform: translateX(2px); }
  30%, 50%, 70% { transform: translateX(-3px); }
  40%, 60% { transform: translateX(3px); }
}

/* 登录 / 注册切换：细分隔线 + 底部文字链（上下文切换，不与主按钮抢层级） */
.ac-switch {
  margin-top: var(--sp-5);
  padding-top: var(--sp-4);
  border-top: 1px solid var(--line2);
  display: flex; align-items: center; justify-content: center; gap: var(--sp-2);
  color: var(--faint); font-size: var(--fs-sm);
}
.ac-switch button {
  position: relative; /* 触屏命中垫层的定位锚（见 pointer:coarse 块） */
  border: 0; background: none; padding: 2px 2px;
  color: var(--accent); font-size: var(--fs-sm); font-weight: 600;
  cursor: pointer; border-radius: var(--radius-sm);
  transition: opacity var(--t-fast) var(--ease);
}
.ac-switch button:hover { opacity: .75; text-decoration: underline; text-underline-offset: 4px; }
.ac-switch button:active { opacity: .55; }
/* 提交中锁定切换：在途请求绑定的是提交时的 mode，此时切走会让按钮文案变成
   「注册中…」但实际发的是登录请求、失败错误挂到新卡头下——状态错乱。键盘侧
   disabled 本身已挡下；pointer-events 断掉 :hover 的下划线/提亮（disabled 元素
   在部分浏览器仍匹配 :hover 伪类），禁用视觉只此一处，与 .submit:disabled 同口径 */
.ac-switch button:disabled { opacity: .45; pointer-events: none; cursor: default; }

/* 与已登录态 .hint 同层级同字号（同口径收编，iOS 端两处对应 footer 均 .xs）：
   原先 fs-2xs(11px) + faint 承载 60 字长句，刚过 AA 的对比度叠最小长文字号，
   可读性 weakest；两个舞台的「页脚说明」是一个层级，不该两个字号 */
.ac-note { margin-top: var(--sp-4); color: var(--faint); font-size: var(--fs-xs); line-height: 1.7; }

/* ============================================================
   已登录 · 账号卡
   ============================================================ */
.card {
  max-width: 640px;
  margin: var(--sp-6) auto 0;
  border: 1px solid var(--line); border-radius: var(--radius-lg);
  background: var(--card); padding: var(--sp-6);
  box-shadow: var(--edge-light);
}

/* 会话恢复中（ready 门控）：居中一行暗调 spinner + 说明，替代闪现的登录表单 */
.pend {
  display: flex; align-items: center; justify-content: center; gap: var(--sp-2);
  color: var(--dim); font-size: var(--fs-sm);
}
.pend-spin {
  width: 14px; height: 14px; flex: none; border-radius: 50%;
  border: 2px solid var(--line); border-top-color: var(--dim);
  animation: spin .7s linear infinite;
}

.who { display: flex; align-items: center; gap: var(--sp-4); }
/* 用户名最长 16 个中文（256px+），不收缩会把退出按钮挤出屏：允许收缩 + 省略号兜底 */
.who-main { min-width: 0; }
.avatar {
  display: inline-flex; align-items: center; justify-content: center;
  width: 48px; height: 48px; border-radius: var(--radius-pill);
  background: var(--accent-bg); border: 1px solid var(--accent-dim);
  color: var(--accent); font-family: var(--mono); font-size: var(--fs-lg); font-weight: 700;
}
.name {
  color: var(--tx-strong); font-size: var(--fs-lg); font-weight: 600;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.meta { color: var(--faint); font-size: var(--fs-xs); margin-top: 2px; }
.logout {
  margin-left: auto;
  position: relative; /* 触屏命中垫层的定位锚（见 pointer:coarse 块） */
  background: none; border: 1px solid var(--line); border-radius: var(--radius-pill);
  color: var(--dim); font-size: var(--fs-sm); padding: 6px 18px; cursor: pointer;
  transition: color var(--t-fast) var(--ease), border-color var(--t-fast) var(--ease), background var(--t-fast) var(--ease), transform var(--t-fast) var(--ease); /* arming 的微警示底也走过渡 */
}
.logout:hover { color: var(--danger); border-color: var(--danger); }
/* 按压下沉 1px——与 submit / sync-btn 同「按实」语言，触屏也有按压反馈 */
.logout:active { transform: translateY(1px); }
/* 两步确认的第一步：常驻危险色 + 微警示底，与 hover 态区分开（hover 是瞬态提示，arming 是持续状态） */
.logout.arming {
  color: var(--danger); border-color: var(--danger);
  background: rgba(217, 106, 89, .08); /* --danger 派生，同 form-err 底 */
}
/* 时限可视化：arming 3 秒无操作自动回退（script logoutTimer），此前只有代码知道、按钮会
   静默还原——按钮底缘一条 danger 细线从满宽收缩到 0，与计时器同为 3s，「还剩多久」一眼
   可见。收缩走 transform: scaleX（MOTION §6-1，不动 width）、origin 靠左顺阅读方向；
   linear 而非 --ease：它映射真实时间流逝，曲线缓动会让剩余量失真（进度类同 .mini-spin /
   sk-pass 的 linear 先例）。走 ::before——pointer:coarse 的触控垫层已占 ::after；两端
   内缩 12px 不出胶囊圆角。每次重新进入 arming 类重新匹配、动画从头播 */
.logout.arming::before {
  content: '';
  position: absolute;
  left: 12px; right: 12px; bottom: 3px;
  height: 2px;
  border-radius: 1px;
  background: var(--danger);
  transform-origin: left;
  animation: logout-tick 3s linear forwards;
  pointer-events: none;
}
@keyframes logout-tick { to { transform: scaleX(0); } }

.sync-box {
  margin-top: var(--sp-5);
  border: 1px solid var(--line2); border-radius: var(--radius);
  background: var(--bg2);
  padding: var(--sp-4);
  transition: border-color var(--t-fast) var(--ease); /* idle→error 描边换色 */
}
.sync-box.error { border-color: var(--danger); }
.sync-line { display: flex; align-items: center; gap: var(--sp-3); }
.sync-dot {
  width: 8px; height: 8px; flex: none; border-radius: 50%;
  background: var(--faint);
  transition: background var(--t-fast) var(--ease); /* idle/ok/error 换色平滑 */
}
.sync-box.ok .sync-dot { background: var(--ok); }
.sync-box.error .sync-dot { background: var(--danger); }
.sync-box.syncing .sync-dot { background: var(--accent); animation: pulse 1.2s var(--ease) infinite; }
@keyframes pulse {
  0% { box-shadow: 0 0 0 0 rgba(45, 212, 191, .35); } /* --accent 派生 */
  70% { box-shadow: 0 0 0 6px rgba(45, 212, 191, 0); }
  100% { box-shadow: 0 0 0 0 rgba(45, 212, 191, 0); }
}
.sync-k { color: var(--dim); font-size: var(--fs-sm); }
.sync-v { color: var(--tx); font-size: var(--fs-sm); font-weight: 600; margin-right: auto; transition: color var(--t-fast) var(--ease); }
.sync-box.ok .sync-v { color: var(--ok); }
.sync-box.error .sync-v { color: var(--danger); }
.sync-btn {
  position: relative; /* 触屏命中垫层的定位锚（见 pointer:coarse 块） */
  display: inline-flex; align-items: center; gap: 6px;
  background: none; border: 1px solid var(--accent-dim); border-radius: var(--radius-pill);
  color: var(--accent); font-size: var(--fs-xs); font-weight: 600;
  padding: 5px 14px; cursor: pointer;
  transition: background var(--t-fast) var(--ease), opacity var(--t-fast) var(--ease), transform var(--t-fast) var(--ease);
}
.sync-btn svg { width: 12px; height: 12px; }
.sync-btn:hover:not(:disabled) { background: var(--accent-bg); }
.sync-btn:active:not(:disabled) { transform: translateY(1px); }
.sync-btn:disabled { opacity: .55; cursor: default; }
/* 同步中不随 disabled 压暗：与 .submit.busy 同口径——内联进度环本身就是「进行中」
   反馈，半透明会削弱它（MOTION 一致性：两处进度反馈同一语义同一呈现） */
.sync-btn:disabled.busy { opacity: 1; }
/* 共享层 .mini-spin（motion.css）在本页补同款进场淡入：与 .spinner 一个口径
   （iOS 双端进度指示均带 opacity 进场）。scoped 选择器特异性高于共享类，只影响
   本页；spin 引用 motion.css 的全局 keyframes，fade-in 用本文件 scoped 定义 */
.sync-btn .mini-spin { animation: spin .7s linear infinite, fade-in var(--t-fast) var(--ease); }
.sync-detail { margin-top: var(--sp-3); color: var(--faint); font-size: var(--fs-xs); }
/* 三项计数是已登录态唯一的数据读数：数字提亮一档立权 + 等宽数字，
   同步完成后数值变化不跳宽、扫读时可先行锚定（数据行扫读三件套口径） */
.sync-detail b { color: var(--tx); font-weight: 600; font-variant-numeric: tabular-nums; }
/* 「上次同步 + 时间戳」整段不断行：sync-detail 是一整段内联文本，断行点随机，
   桌面下四字词组曾拦腰拆到两行（首行末「上次」、次行起「同步 …」）；nowrap 后
   要么整段留在行尾、要么整体换到下一行，且整段约 20 字符远窄于移动端 sync-box
   内宽，不会引入横向溢出。tabular 让时间戳刷新时秒数跳变不牵动整段宽 */
.sync-last { white-space: nowrap; font-variant-numeric: tabular-nums; }
/* 机制说明独立成行：同 faint 同 fs-xs（辅助说明下限，不降 2xs——那是 kicker/表头
   白名单），靠「不在主读数句里」完成弱化，而不是再造一档更小的字 */
.sync-rule { display: block; }
.sync-err { margin-top: var(--sp-2); color: var(--danger); font-size: var(--fs-xs); }

/* 错误文案两行时均衡断行（渐进增强）：长错误文案（如用户名规则提示约 32 字）
   在卡内容宽 ~326px 下必折两行，默认折行头重脚轻；不支持 balance 的浏览器
   回退默认折行，功能完整无损 */
@supports (text-wrap: balance) {
  .form-err, .sync-err { text-wrap: balance; }
}

/* 触屏粗指针补足命中区：本页四个小按钮视觉尺寸 26–36px，低于 44px 最小
   可点目标——伪元素向四周扩 10px 做触控垫层，视觉零变化；桌面细指针
   （pointer: fine）不命中本块，hover 精度不受影响 */
@media (pointer: coarse) {
  .pw-toggle::after,
  .sync-btn::after,
  .logout::after,
  .ac-switch button::after {
    content: '';
    position: absolute;
    inset: -10px;
  }
}

.hint { margin-top: var(--sp-4); color: var(--faint); font-size: var(--fs-xs); line-height: 1.7; }

/* ============================================================
   响应式：平板（--bp-pad 820px）收单栏，表单优先；手机再收内距
   ============================================================ */
@media (max-width: 820px) {
  .auth-stage { grid-template-columns: 1fr; max-width: 480px; gap: var(--sp-5); }
  .auth-card { order: -1; }
}
@media (max-width: 680px) {
  /* iOS Safari 聚焦 <16px 输入框会强制放大页面；手机档升到 fs-lg(16px) 消除跳变 */
  .f-in { font-size: var(--fs-lg); }
  /* 长用户名 + 退出按钮：极窄屏挤不下时允许换行兜底（margin-left:auto 仍生效）。
     关键在 who-main 基准宽归零（flex:1 1 0）：wrap 布局里项目按固有宽参与折行、
     放不下是整块换行而非收缩——16 字中文长名（约 256px）会把 who-main 整块
     挤到第二行，头像独占首行右侧大片空白、退出按钮再折一行，摊成松散三行；
     归零后 who-main 恒与头像同行、按剩余宽收缩，.name 的 ellipsis 兜底截断 */
  .who { flex-wrap: wrap; row-gap: var(--sp-3); }
  .who-main { flex: 1 1 0; }
}
@media (max-width: 480px) {
  .auth-hero { padding: var(--sp-5); }
  .hero-title { font-size: var(--fs-xl); }
  /* kicker .42em 字距在窄卡内放不下会拦腰折行；按 --bp-mini「字距减半」约定收窄 */
  .hero-kicker { letter-spacing: .21em; }
  .auth-card { padding: var(--sp-5); }
  /* 极窄屏（~320px 机型）sync-line 内容宽 ≈172px，装不下「圆点 + 键值 + 胶囊按钮」
     ≈230px：flex 默认不换行，inline-flex 按钮被压缩到文字折行、胶囊变形。允许折行
     兜底（与 .who 的 wrap 同范式）——放得下的宽度 wrap 是被动零效果，只在真挤时
     按钮整只换到次行；margin-left:auto 让次行按钮右对齐回行尾（首行 sync-v 的
     margin-right:auto 照旧吸收首行剩余空隙，两个 auto 分属不同行互不干扰） */
  .sync-line { flex-wrap: wrap; row-gap: var(--sp-2); }
  .sync-btn { margin-left: auto; }
}

@media (prefers-reduced-motion: reduce) {
  /* shake 停；外层 swap 淡入淡出由 motion.css 文件尾 RM 兜底统一关停为瞬时 */
  .form-err { animation: none; }
  /* 倒计时收缩停、条静态满宽——保留「正处于确认态」的静态等价物（语义反馈不随装饰动效
     一起关）；失去的只是精确剩余量，3 秒后静默还原与改动前 RM 体验一致、不退化 */
  .logout.arming::before { animation: none; }
  /* spinner / pend-spin / mini-spin 是进度语义循环（MOTION.md 原则 5 例外），RM 下按原速 .7s
     保留——不再降速 1.4s：与本页共用的 .mini-spin 同速，且「降级禁留更慢版本」（§6-5） */
  .sync-box.syncing .sync-dot { animation: none; }
  /* 进度环的 fade-in 是装饰性进场过渡，RM 关（animation-name 收窄到只剩 spin：
     进度语义保留、淡入消失）；离去场本就瞬删，无残留在播的动画 */
  .spinner, .sync-btn .mini-spin { animation-name: spin; }
}
</style>
