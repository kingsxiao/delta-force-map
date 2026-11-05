/* ============================================================
   server.mjs — 同源部署服务：静态站 + 实时行情（node:http 零依赖）
   ------------------------------------------------------------
   一个进程五件事：定时抓上游（弹药 fast/slow 双循环 + 雷达循环 + 特勤处
   制造循环 + 每日密码循环，均复用既有抓取器与兜底源）→ 原子写快照
   （apps/web/public 与其 dist 联动）→ SSE 推送（event:market / event:radar /
   event:craft / event:secrets）→ 静态托管 apps/web/dist。
   另挂一个日级 sidecar：官方均价锚（server/official/ammo-anchor.mjs，默认
   24h 一轮、启动 2 分钟后首跑、每轮 ≤15 请求）只拿官方均价校验 moligod
   现价并落 data/ammo/official-anchor.json——不改口径、不写快照、不广播。
   多端 monorepo 布局：Node 后端在 server/，网页端在 apps/web（vite 构建），
   iOS 原生端 apps/ios 只消费本服务的 HTTP + SSE 接口（契约 shared/API.md）。
   站点与 /events 同源是关键：https 部署下无 mixed content、无 CORS，
   页面端 liveChannelUrl() 直接连 ${origin}/events 即为实时模式。
   雷达与特勤处节奏默认 10 分钟（雷达榜单约每小时滚动、特勤处利润随分钟
   价推进，10 分钟已跟上实际变化；请求量与弹药侧合计仍低于每秒 1 次）
   ——--radar-interval / --craft-interval N 可调。
   路由：
     /events  SSE（连接即 hello；落盘广播 market / radar，实现同 live.mjs）
     /health  {ok, source, version, cycles, ...}（弹药侧状态）
     其余     apps/web/dist/ 静态文件（/ → index.html；/assets/ 哈希文件长
              缓存；*.json 数据与 html 走 no-cache，快照顶层 fingerprint
              兼作 ETag——If-None-Match 命中回 304 不重发整包；路径归一化
              防目录穿越）
   通知默认关闭（部署形态通常无桌面）；--notify 开启。
   用法：npm run build && npm run serve [--port 8080] [--host 0.0.0.0] [--notify]
         [--radar-interval 10] [--anchor-interval-hours 24] [--no-anchor] [--trust-proxy[=N]]
   环境变量 PORT / HOST / RADAR_INTERVAL_MIN / ANCHOR_INTERVAL_HOURS 与参数同义。上 https 用
   nginx/caddy 反代即可；限速 IP 取 XFF 从右数第 N 跳：--trust-proxy 为
   单层反代（1 跳），多级链（CDN→nginx→node 等）须 --trust-proxy=N 指明。
   注意：与 ammo:live / ammo:monitor / radar:monitor / 手动 fetch 同为写盘者，
   同时只跑一个。
   ============================================================ */
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createLiveServer } from './ammo/live.mjs'
import { notify as osascriptNotify } from './ammo/notify.mjs'
import { openBarkRegistry, createBarkOutlet } from './push/bark.mjs'
import { runRadarCycle } from './market/radar.mjs'
import { runCraftCycle } from './craft/snapshot.mjs'
import { runTradehouseCycle } from './market/tradehouse.mjs'
import { runSecretsCycle } from './secrets/secrets.mjs'
import { runAnchorCycle } from './official/ammo-anchor.mjs'
import { createAuthApi } from './auth/api.mjs'

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
/** 网页端目录（多端 monorepo：public/ 与 dist/ 都挂在 apps/web 下） */
const WEB_DIR = path.join(ROOT, 'apps', 'web')
const log = (msg) => console.log(`[${new Date().toLocaleString('zh-CN')}] ${msg}`)

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2',
}

/**
 * 创建同源站点服务（不 listen；selftest 用 port 0 自取临时端口）。
 * @param {{rootDir?:string, webDir?:string, noNotify?:boolean, statePath?:string,
 *          radarCycle?:Function, radarMs?:number,
 *          craftCycle?:Function, craftMs?:number,
 *          anchorCycle?:Function|null, anchorMs?:number, anchorDelayMs?:number}} opts
 *   rootDir 仓库根（data/ 留档与监控 state 挂这里）；webDir 网页端目录
 *   （public/dist 写入与静态托管，默认 = rootDir，selftest 传临时目录即原行为）；
 *   statePath live 去抖 state 文件（缺省 = rootDir 下 data/ammo/monitor-state.json，
 *   selftest 传临时目录路径即与常驻监控进程的共享 state 隔离）；
 *   anchorCycle 官方均价锚（null 关闭），首跑延迟 anchorDelayMs 后每 anchorMs 一轮
 * @returns {{server:http.Server, live:object, start:Function, close:Function,
 *            triggerRadarCycle:Function, triggerCraftCycle:Function, triggerAnchorCycle:Function}}
 */
export function createSiteServer({
  rootDir = ROOT,
  webDir = rootDir,
  noNotify = true,
  /** live 去抖 state 文件（缺省透传 undefined → live 侧回落 rootDir 下
      data/ammo/monitor-state.json；selftest 传临时目录路径即隔离真实 state） */
  statePath,
  radarCycle = runRadarCycle,
  radarMs = 10 * 60 * 1000,
  craftCycle = runCraftCycle,
  craftMs = 10 * 60 * 1000,
  /** 每日密码：日更数据 30 分钟兜一轮；内容不变模块内自动跳过写盘与广播 */
  secretsCycle = runSecretsCycle,
  secretsMs = 30 * 60 * 1000,
  /** 交易行全量快照 + 指数 + 战备差价：上游 ttl 分钟级，10 分钟一轮 */
  tradehouseCycle = runTradehouseCycle,
  tradehouseMs = 10 * 60 * 1000,
  /** 官方均价锚 sidecar：日级只读校验；默认延迟 2 分钟首跑，离线自测在 close()
      前不会打网（selftest 不注入也安全） */
  anchorCycle = runAnchorCycle,
  anchorMs = 24 * 60 * 60 * 1000,
  anchorDelayMs = 2 * 60 * 1000,
  /** true = 单层反代（XFF 末段）；正整数 N = 多级反代从右数第 N 跳 */
  trustProxy = false,
} = {}) {
  const distDir = path.join(webDir, 'dist')
  // 组合投递器（契约 shared/API.md §6.4）：osascript 桌面通知受 noNotify
  // （--notify 开关）门控；Bark 推送与该开关解耦——有设备注册即推（手机锁屏
  // 收信号不依赖桌面通知开关；ECS Linux 上 osascript 本来就是 noop）。
  // 传给 live 的 noNotify 恒 false：门控移入本 dispatcher，否则 --notify 关闭
  // 时 Bark 会被一起关掉。selftest 环境无注册 → bark 出口零网络开销。
  const barkNotify = createBarkOutlet(openBarkRegistry({ rootDir }))
  const notifyFn = async (msg) => {
    if (!noNotify) await osascriptNotify(msg)
    await barkNotify(msg)
  }
  const live = createLiveServer({ rootDir, webDir, noNotify: false, statePath, trustProxyHops: typeof trustProxy === 'number' ? trustProxy : 1, notifyFn })
  // 账号 API（注册 / 登录 / 登出 / me + 账号云数据，契约 shared/API.md §6）：
  // 与站点同进程同源；POST/PUT 只进这一支，静态托管仍保持只读 GET/HEAD。
  // trustProxy：nginx 反代形态下显式开启才采信 X-Forwarded-For 做限速
  // （true = 单层反代取末段；数字 N = 多级反代从右数第 N 跳，见 api.mjs clientIp）
  const auth = createAuthApi({ rootDir, trustProxy })
  let radarTimer = null
  let craftTimer = null
  let secretsTimer = null
  let tradehouseTimer = null
  let anchorTimer = null
  let closing = false

  /* 雷达循环：失败只记日志不重试加速（榜单小时级滚动，下一轮自然补）；
     计时在本轮完成后重启，稳态无并发写 */
  async function cycleRadar() {
    try {
      const out = await radarCycle({ rootDir, webDir, noNotify: true })
      live.broadcast('radar', {
        version: out.version,
        total: out.stats.total,
        anomaly: out.stats.anomaly,
        buy: out.stats.buy,
        sell: out.stats.sell,
      })
      log(`[radar] version ${out.version} · 榜单 ${out.stats.total} 项 · 异常 ${out.stats.anomaly}`)
      return out
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] [radar] 抓取失败：${e.message}`)
      return null
    }
  }

  async function radarLoop() {
    if (closing) return
    await cycleRadar()
    if (closing) return
    radarTimer = setTimeout(radarLoop, radarMs)
  }

  /* 特勤处制造循环（同雷达范式）：失败只记日志，下一轮自然补 */
  async function cycleCraft() {
    try {
      const out = await craftCycle({ webDir })
      live.broadcast('craft', {
        version: out.version,
        total: out.stats.total,
        complete: out.stats.complete,
        profitable: out.stats.profitable,
      })
      log(`[craft] version ${out.version} · 配方 ${out.stats.total} · 完整 ${out.stats.complete} · 可盈利 ${out.stats.profitable}`)
      return out
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] [craft] 抓取失败：${e.message}`)
      return null
    }
  }

  async function craftLoop() {
    if (closing) return
    await cycleCraft()
    if (closing) return
    craftTimer = setTimeout(craftLoop, craftMs)
  }

  /* 每日密码循环（同雷达范式）：官方 AMS 日更数据，内容不变时模块内已跳过
     写盘；只在真变化（0 点轮换 / 兜底源切换）时广播，SSE 不被空转刷屏 */
  async function cycleSecrets() {
    try {
      const out = await secretsCycle({ webDir })
      if (out.changed) {
        live.broadcast('secrets', { version: out.version, total: out.total, source: out.source })
        log(`[secrets] version ${out.version} · ${out.total} 张图 · 源 ${out.source}`)
      }
      return out
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] [secrets] 抓取失败：${e.message}`)
      return null
    }
  }

  async function secretsLoop() {
    if (closing) return
    await cycleSecrets()
    if (closing) return
    secretsTimer = setTimeout(secretsLoop, secretsMs)
  }

  /* 交易行全量 + 指数 + 战备差价循环（同雷达范式）：失败只记日志，下一轮自然补；
     广播 tradehouse 事件（交易行 / 指数两页共用版本门控；战备差价页小时级走轮询） */
  async function cycleTradehouse() {
    try {
      const out = await tradehouseCycle({ webDir, rootDir })
      live.broadcast('tradehouse', {
        version: out.version,
        total: out.total,
        indexAll: out.indexAll,
        loadoutTotal: out.loadoutTotal,
      })
      log(`[tradehouse] version ${out.version} · 全市场 ${out.total} 件 · 总指数 ${out.indexAll?.toFixed(1) ?? '—'} · 战备差价 ${out.loadoutTotal ?? '保留旧档'}`)
      return out
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] [tradehouse] 抓取失败：${e.message}`)
      return null
    }
  }

  async function tradehouseLoop() {
    if (closing) return
    await cycleTradehouse()
    if (closing) return
    tradehouseTimer = setTimeout(tradehouseLoop, tradehouseMs)
  }

  /* 官方均价锚（日级 sidecar，同雷达范式）：只读校验、失败只记日志；不广播、不写快照 */
  async function cycleAnchor() {
    if (!anchorCycle) return null
    try {
      const out = await anchorCycle({ rootDir, webDir })
      const s = out?.summary ?? {}
      log(`[anchor] 官方均价锚 · 映射 ${s.joined}/${s.total} · 未命中 ${s.missed} · 歧义 ${s.ambiguous} · 偏差>15% ${s.devOver15} · 请求 ${s.requests}`)
      return out
    } catch (e) {
      console.error(`[${new Date().toLocaleString('zh-CN')}] [anchor] 校验失败：${e.message}`)
      return null
    }
  }

  async function anchorLoop() {
    if (closing) return
    await cycleAnchor()
    if (closing) return
    anchorTimer = setTimeout(anchorLoop, anchorMs)
  }

  function cacheControlFor(pathname) {
    if (pathname.startsWith('/assets/')) return 'public, max-age=31536000, immutable'
    if (pathname.endsWith('.html') || pathname === '/' || pathname.endsWith('.json')) return 'no-cache'
    return 'public, max-age=3600'
  }

  /** 快照协商缓存：*.json 顶层带 fingerprint（数据管道写入的内容指纹，见
   *  server/ammo/fetch-once.mjs）的以它为 ETag——客户端（网页端
   *  useSnapshotFeed）带 If-None-Match 重询时命中即回 304，未变轮次不再
   *  整包下发（弹药快照约 400KB × 分钟级轮询）。仅条件请求才解析 JSON，
   *  常规路径零开销；radar / craft 快照暂无 fingerprint 字段，行为不变 */
  function snapshotEtagOf(pathname, buf) {
    if (!pathname.endsWith('.json')) return null
    try {
      return JSON.parse(buf).fingerprint || null
    } catch {
      return null // 损坏 / 非 JSON：按无 ETag 处理，正常 200 走通
    }
  }

  async function serveStatic(req, pathname, res) {
    let p
    try {
      p = path.normalize(path.join(distDir, decodeURIComponent(pathname)))
    } catch {
      res.writeHead(400, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('bad path')
      return
    }
    // 防穿越：归一化后必须仍在 dist 内（目录本身放行，随后落 index.html）
    if (p !== distDir && !p.startsWith(distDir + path.sep)) {
      res.writeHead(403, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('forbidden')
      return
    }
    if (p === distDir || pathname.endsWith('/')) p = path.join(p, 'index.html')
    try {
      const buf = await readFile(p)
      const headers = {
        'Content-Type': MIME[path.extname(p).toLowerCase()] || 'application/octet-stream',
        'Cache-Control': cacheControlFor(pathname),
      }
      const inm = req.headers['if-none-match']
      const etag = inm ? snapshotEtagOf(pathname, buf) : null
      if (etag) {
        const quoted = `"${etag}"`
        headers.ETag = quoted
        // 子串比对兼容 W/"..." 弱验证与多值列表（fingerprint 为 64 位十六进制，误撞不可能）
        if (inm.includes(quoted)) {
          res.writeHead(304, { ETag: quoted, 'Cache-Control': headers['Cache-Control'] })
          res.end()
          return
        }
      }
      res.writeHead(200, headers)
      res.end(buf)
    } catch {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' })
      res.end('not found')
    }
  }

  const server = http.createServer(async (req, res) => {
    try {
      const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`)
      // SSE / health 直接复用 live 服务的处理器（emit 触发其 request 监听）
      if (url.pathname === '/events' || url.pathname === '/health') {
        live.server.emit('request', req, res)
        return
      }
      // /api/* 交给账号模块（含 OPTIONS 预检；未匹配路径由其统一 404 JSON）
      if (url.pathname.startsWith('/api/')) {
        if (await auth.handle(req, res, url)) return
      }
      if (req.method !== 'GET' && req.method !== 'HEAD') {
        res.writeHead(405, { 'Content-Type': 'text/plain; charset=utf-8' })
        res.end('method not allowed')
        return
      }
      await serveStatic(req, url.pathname, res)
    } catch {
      if (!res.headersSent) res.writeHead(500)
      res.end()
    }
  })

  async function close() {
    closing = true
    clearTimeout(radarTimer)
    clearTimeout(craftTimer)
    clearTimeout(secretsTimer)
    clearTimeout(tradehouseTimer)
    clearTimeout(anchorTimer)
    await live.close()
    await new Promise((resolve) => server.close(resolve))
  }
  /** 启动序列：弹药（live.start 自带冷启动 + 双循环）与雷达 / 特勤处 / 每日密码 /
      交易行初始轮并行；各循环失败不阻塞（catch 在各自 cycle 内），下一轮计时照常；
      官方均价锚不参与启动并行，延迟 anchorDelayMs 后首跑再按 anchorMs 循环 */
  async function start() {
    await Promise.all([live.start(), cycleRadar(), cycleCraft(), cycleSecrets(), cycleTradehouse()])
    radarTimer = setTimeout(radarLoop, radarMs)
    craftTimer = setTimeout(craftLoop, craftMs)
    secretsTimer = setTimeout(secretsLoop, secretsMs)
    tradehouseTimer = setTimeout(tradehouseLoop, tradehouseMs)
    if (anchorCycle) anchorTimer = setTimeout(anchorLoop, anchorDelayMs)
  }
  return {
    server,
    live,
    start,
    close,
    triggerRadarCycle: cycleRadar,
    triggerCraftCycle: cycleCraft,
    triggerSecretsCycle: cycleSecrets,
    triggerTradehouseCycle: cycleTradehouse,
    triggerAnchorCycle: cycleAnchor,
  }
}

// ---- CLI 直跑 ----
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const argv = process.argv.slice(2)
  const argOf = (name) => {
    const i = argv.indexOf(`--${name}`)
    return i >= 0 && argv[i + 1] ? argv[i + 1] : null
  }
  const port = Number(argOf('port') || process.env.PORT || 8080)
  const host = argOf('host') || process.env.HOST || '0.0.0.0'
  const radarIntervalMin = Number(
    argOf('radar-interval') || process.env.RADAR_INTERVAL_MIN || 10
  )
  const craftIntervalMin = Number(
    argOf('craft-interval') || process.env.CRAFT_INTERVAL_MIN || 10
  )
  // 每日密码：日更数据，默认 30 分钟兜一轮（只为接住 0 点轮换）
  const secretsIntervalMin = Number(
    argOf('secrets-interval') || process.env.SECRETS_INTERVAL_MIN || 30
  )
  // 交易行全量 + 指数 + 战备差价：上游分钟级，默认 10 分钟一轮
  const tradehouseIntervalMin = Number(
    argOf('tradehouse-interval') || process.env.TRADEHOUSE_INTERVAL_MIN || 10
  )
  // 官方均价锚：--no-anchor 关闭；小时数非法回落 24，并钳在 [1, 500]——
  // setTimeout 上限 2^31-1 ms（≈596h），超出会被 Node 当 1ms 立即触发
  const noAnchor = argv.includes('--no-anchor')
  const anchorHoursRaw = Number(argOf('anchor-interval-hours') || process.env.ANCHOR_INTERVAL_HOURS || 24)
  const anchorHours = Number.isFinite(anchorHoursRaw) ? Math.min(500, Math.max(1, anchorHoursRaw)) : 24
  if (!existsSync(path.join(WEB_DIR, 'dist', 'index.html'))) {
    console.error('缺少 apps/web/dist/index.html：先运行 npm run build，再启动服务')
    process.exit(1)
  }
  const notify = argv.includes('--notify')
  // --trust-proxy：单层 nginx 反代（取 XFF 末段）；--trust-proxy=N 或
  // TRUST_PROXY=N：N 级反代链，限速 IP 取 XFF 从右数第 N 跳。末段口径只对
  // 单层反代成立——CDN→nginx→node 等多级链不指明 N 的话，末段恒为上级代理
  // 内网 IP，全站用户聚合到同一限速键 / SSE 单 IP 上限互相挤掉配额。
  // 带值形式值非法则不采信（按 socket 直连地址限速，不因脏配置放松 XFF）
  const trustArg = argv.find((a) => a.startsWith('--trust-proxy'))
  const trustN = Number(trustArg !== undefined ? trustArg.replace(/^--trust-proxy=?/, '') : process.env.TRUST_PROXY)
  const trustOk = Number.isInteger(trustN) && trustN >= 1
  const trustProxy = trustArg === '--trust-proxy' ? true : trustOk ? trustN : false
  const site = createSiteServer({
    webDir: WEB_DIR,
    noNotify: !notify,
    radarMs: Math.max(1, radarIntervalMin) * 60 * 1000,
    craftMs: Math.max(1, craftIntervalMin) * 60 * 1000,
    secretsMs: Math.max(1, secretsIntervalMin) * 60 * 1000,
    tradehouseMs: Math.max(1, tradehouseIntervalMin) * 60 * 1000,
    anchorCycle: noAnchor ? null : runAnchorCycle,
    anchorMs: anchorHours * 60 * 60 * 1000,
    trustProxy,
  })
  site.server.listen(port, host, () => {
    log(`站点已启动：http://${host}:${port}/ · SSE /events · health /health（Ctrl+C 退出）`)
    log(`静态目录 apps/web/dist/ · 雷达每 ${radarIntervalMin} 分钟 · 特勤处制造每 ${craftIntervalMin} 分钟 · 每日密码每 ${secretsIntervalMin} 分钟 · 交易行/指数每 ${tradehouseIntervalMin} 分钟 · 官方均价锚${noAnchor ? '关闭' : `每 ${anchorHours} 小时（启动 2 分钟后首跑）`} · 系统通知${notify ? '开启' : '关闭（--notify 可开启）'} · 上游抓取循环随服务常驻`)
  })
  await site.start()
  const shutdown = (sig) => {
    log(`收到 ${sig}，关闭服务`)
    site.close().then(() => process.exit(0))
  }
  process.on('SIGINT', () => shutdown('SIGINT'))
  process.on('SIGTERM', () => shutdown('SIGTERM'))
}
