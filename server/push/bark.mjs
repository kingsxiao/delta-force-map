/* ============================================================
   bark.mjs — Bark 推送出口 + 设备注册表（零 npm 依赖）
   ------------------------------------------------------------
   链路：live.mjs 判出 BUY/SELL（shared/js/notify-policy.js 去抖后的
   「已判定要通知」事件）→ 本模块按注册偏好过滤 → POST Bark 服务器
   （默认公共 https://api.day.app，可自建）→ iPhone 锁屏横幅。
   App / 网页端无需运行、无需开发者账号（推送由 Bark app 接收）。
   契约：shared/API.md §6.4（先于实现撰写，两端 parseBarkUrl 同构）。

   注册表：data/push/bark.json {devices:{<uid>:{server,key,buys,sells,savedAt}}}
   落盘复用 server/auth/store.mjs 的 writeAtomic（0600 tmp+rename），
   损坏隔离同款 .corrupt-<ts> 留档（账号表同口径，不抄两份仅此一处差异：
   quarantine 在 auth store 闭包内，此处按同语义本地实现）。
   出口契约与 osascript notify 一致：失败只 console.error，绝不抛——
   通知失败不能拖垮行情抓取主循环。
   ============================================================ */
import { readFile, rename } from 'node:fs/promises'
import path from 'node:path'
import { writeAtomic } from '../auth/store.mjs'

/** Bark 公共服务器（自建 Bark 填自己的 https 源覆盖） */
export const DEFAULT_BARK_SERVER = 'https://api.day.app'
/** 设备 key：Bark app「复制URL」路径里那段设备标识（字母数字） */
const KEY_RE = /^[A-Za-z0-9]{10,80}$/
/** 单条推送超时；Bark 服务器抖动不得拖慢行情主循环（outlet 并发发） */
const BARK_TIMEOUT_MS = 5000

/** 语义化错误：code 供客户端分支（同 AuthError 形状），status 供 HTTP 层 */
export class BarkError extends Error {
  constructor(code, message, status = 400) {
    super(message)
    this.code = code
    this.status = status
  }
}

/**
 * 解析用户粘贴的 Bark 地址（两端同构：Swift 镜像见 DeltaForceCore BarkPush.swift，
 * 改这里必须同步）。接受三种形态：
 *   · 裸 key                    "aBcDeFgHiJkLm"
 *   · 样例 URL                  "https://api.day.app/<key>/这里改成你的推送内容"
 *   · bark scheme               "bark://api.day.app/<key>/…" 或 "bark:///<key>"
 * @param {string} input
 * @returns {{server:string, key:string}|null} 解析不出合法 key 返回 null
 */
export function parseBarkUrl(input) {
  const s = String(input ?? '').trim()
  if (!s) return null
  if (KEY_RE.test(s)) return { server: DEFAULT_BARK_SERVER, key: s }
  let u
  try {
    u = new URL(s)
  } catch {
    return null
  }
  let server
  if (u.protocol === 'https:') server = u.origin
  else if (u.protocol === 'bark:') server = u.host ? `https://${u.host}` : DEFAULT_BARK_SERVER
  else return null
  const key = u.pathname.split('/').find(Boolean)
  return KEY_RE.test(key ?? '') ? { server, key } : null
}

/**
 * 打开 Bark 注册表（懒加载首访读盘，写穿；进程内单实例）。
 * @param {{rootDir?:string}} opts rootDir 仓库根（数据挂 data/push/）
 */
export function openBarkRegistry({ rootDir = process.cwd() } = {}) {
  const file = path.join(rootDir, 'data', 'push', 'bark.json')
  /** @type {Record<string, {server:string,key:string,buys:boolean,sells:boolean,savedAt:string}>|null} */
  let devices = null
  /** 注册读改写串行链（同 auth store 的并发安全网） */
  let queue = Promise.resolve()

  /** 损坏留档（语义同 store.mjs quarantine：可手工恢复，不静默当空覆盖） */
  async function quarantine(why) {
    const keep = `${file}.corrupt-${new Date().toISOString().replace(/[:.]/g, '')}`
    try {
      await rename(file, keep)
      console.error(`[push] bark.json 损坏（${why}），已留档 ${path.basename(keep)}，按空注册表初始化`)
    } catch {
      /* 原文件不存在等：无需留档 */
    }
  }

  async function load() {
    if (devices) return
    try {
      const j = JSON.parse(await readFile(file, 'utf8'))
      devices = j.devices && typeof j.devices === 'object' ? j.devices : {}
    } catch (e) {
      if (e.code !== 'ENOENT') await quarantine(e.message)
      devices = {}
    }
  }

  async function save() {
    await writeAtomic(file, JSON.stringify({ devices }) + '\n')
  }

  /** 串行化读改写（put/delete 竞争安全） */
  function chained(fn) {
    queue = queue.then(fn).catch((e) => console.error(`[push] bark 注册表写失败：${e.message}`))
    return queue
  }

  return {
    /** 全量注册（outlet 用；未加载时 {}） */
    async all() {
      await load()
      return { ...devices }
    },
    /** 当前用户注册（未注册 null）；await 必需（懒加载读盘） */
    async get(uid) {
      await load()
      return devices[uid] ?? null
    },
    /** upsert 注册；返回 savedAt（先确保懒加载完成——chained 里的写盘任务
        异步执行，不能依赖它之前有人调过 get/all） */
    async put(uid, { server, key, buys, sells }) {
      await load()
      const savedAt = new Date().toISOString()
      await chained(() => {
        devices[uid] = { server, key, buys, sells, savedAt }
        return save()
      })
      return savedAt
    },
    /** 注销（幂等：未注册也是删了个不存在键） */
    async del(uid) {
      await load()
      await chained(() => {
        delete devices[uid]
        return save()
      })
    },
  }
}

/**
 * 单条 Bark 推送（test 端点与 outlet 共用）。Bark POST /push 契约：
 * {device_key, title, body, group}，HTTP 2xx 即成功（body {code:200}）。
 * @returns {Promise<{ok:true}|never>} 失败抛 BarkError（BARK_FAILED, 502）
 */
export async function sendBark(reg, { title, body, group = 'ammo-signal' }) {
  let res
  try {
    res = await fetch(`${reg.server}/push`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=utf-8' },
      body: JSON.stringify({ device_key: reg.key, title, body, group }),
      signal: AbortSignal.timeout(BARK_TIMEOUT_MS),
    })
  } catch (e) {
    throw new BarkError('BARK_FAILED', `Bark 服务不可达：${e.message}`, 502)
  }
  if (!res.ok) {
    throw new BarkError('BARK_FAILED', `Bark 推送失败：HTTP ${res.status}`, 502)
  }
  return { ok: true }
}

/**
 * 推送出口工厂：供 live.mjs / monitor.mjs 的 sendNotifications 第三参
 * （notifyFn）组合调用。消息的 kind 由 notify-policy 传入（'buy'|'sell'），
 * 按各注册偏好过滤；无注册时零网络开销。永不抛（通知失败不拖垮主循环）。
 * @returns {(msg:{title:string,body:string,kind?:string}) => Promise<void>}
 */
export function createBarkOutlet(registry) {
  return async function barkNotify({ title, body, kind }) {
    const regs = Object.values(await registry.all())
    const targets = regs.filter((r) => (kind === 'sell' ? r.sells : r.buys))
    if (!targets.length) return
    await Promise.allSettled(
      targets.map((r) =>
        sendBark(r, { title, body }).catch((e) =>
          console.error(`[push] bark 推送失败（${r.server}）：${e.message}`)
        ),
      ),
    )
  }
}
