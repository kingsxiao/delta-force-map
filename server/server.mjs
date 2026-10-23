/* ============================================================
   server.mjs — 同源部署服务：静态站 + 实时行情（node:http 零依赖）
   ------------------------------------------------------------
   一个进程四件事：定时抓上游（弹药 fast/slow 双循环 + 雷达循环 + 特勤处
   制造循环，均复用既有抓取器与 kkrb 兜底）→ 原子写快照（apps/web/public
   与其 dist 联动）→ SSE 推送（event:market / event:radar / event:craft）
   → 静态托管 apps/web/dist。
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
              缓存；*.json 数据与 html 走 no-cache；路径归一化防目录穿越）
   通知默认关闭（部署形态通常无桌面）；--notify 开启。
   用法：npm run build && npm run serve [--port 8080] [--host 0.0.0.0] [--notify]
         [--radar-interval 10]
   环境变量 PORT / HOST / RADAR_INTERVAL_MIN 与参数同义。上 https 用
   nginx/caddy 反代即可。
   注意：与 ammo:live / ammo:monitor / radar:monitor / 手动 fetch 同为写盘者，
   同时只跑一个。
   ============================================================ */
import { readFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import http from 'node:http'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createLiveServer } from './ammo/live.mjs'
import { runRadarCycle } from './market/radar.mjs'
import { runCraftCycle } from './craft/snapshot.mjs'
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
 * @param {{rootDir?:string, webDir?:string, noNotify?:boolean,
 *          radarCycle?:Function, radarMs?:number,
 *          craftCycle?:Function, craftMs?:number}} opts
 *   rootDir 仓库根（data/ 留档与监控 state 挂这里）；webDir 网页端目录
 *   （public/dist 写入与静态托管，默认 = rootDir，selftest 传临时目录即原行为）
 * @returns {{server:http.Server, live:object, start:Function, close:Function,
 *            triggerRadarCycle:Function, triggerCraftCycle:Function}}
 */
export function createSiteServer({
  rootDir = ROOT,
  webDir = rootDir,
  noNotify = true,
  radarCycle = runRadarCycle,
  radarMs = 10 * 60 * 1000,
  craftCycle = runCraftCycle,
  craftMs = 10 * 60 * 1000,
  trustProxy = false,
} = {}) {
  const distDir = path.join(webDir, 'dist')
  const live = createLiveServer({ rootDir, webDir, noNotify })
  // 账号 API（注册 / 登录 / 登出 / me + 账号云数据，契约 shared/API.md §6）：
  // 与站点同进程同源；POST/PUT 只进这一支，静态托管仍保持只读 GET/HEAD。
  // trustProxy：nginx 反代形态下显式开启才采信 X-Forwarded-For 做限速
  const auth = createAuthApi({ rootDir, trustProxy })
  let radarTimer = null
  let craftTimer = null
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

  function cacheControlFor(pathname) {
    if (pathname.startsWith('/assets/')) return 'public, max-age=31536000, immutable'
    if (pathname.endsWith('.html') || pathname === '/' || pathname.endsWith('.json')) return 'no-cache'
    return 'public, max-age=3600'
  }

  async function serveStatic(pathname, res) {
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
      res.writeHead(200, {
        'Content-Type': MIME[path.extname(p).toLowerCase()] || 'application/octet-stream',
        'Cache-Control': cacheControlFor(pathname),
      })
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
      await serveStatic(url.pathname, res)
    } catch {
      if (!res.headersSent) res.writeHead(500)
      res.end()
    }
  })

  async function close() {
    closing = true
    clearTimeout(radarTimer)
    clearTimeout(craftTimer)
    await live.close()
    await new Promise((resolve) => server.close(resolve))
  }
  /** 启动序列：弹药（live.start 自带冷启动 + 双循环）与雷达 / 特勤处初始轮并行；
      雷达 / 特勤处失败不阻塞（catch 在各自 cycle 内），下一轮计时照常 */
  async function start() {
    await Promise.all([live.start(), cycleRadar(), cycleCraft()])
    radarTimer = setTimeout(radarLoop, radarMs)
    craftTimer = setTimeout(craftLoop, craftMs)
  }
  return { server, live, start, close, triggerRadarCycle: cycleRadar, triggerCraftCycle: cycleCraft }
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
  if (!existsSync(path.join(WEB_DIR, 'dist', 'index.html'))) {
    console.error('缺少 apps/web/dist/index.html：先运行 npm run build，再启动服务')
    process.exit(1)
  }
  const notify = argv.includes('--notify')
  const trustProxy = argv.includes('--trust-proxy') || process.env.TRUST_PROXY === '1'
  const site = createSiteServer({
    webDir: WEB_DIR,
    noNotify: !notify,
    radarMs: Math.max(1, radarIntervalMin) * 60 * 1000,
    craftMs: Math.max(1, craftIntervalMin) * 60 * 1000,
    trustProxy,
  })
  site.server.listen(port, host, () => {
    log(`站点已启动：http://${host}:${port}/ · SSE /events · health /health（Ctrl+C 退出）`)
    log(`静态目录 apps/web/dist/ · 雷达每 ${radarIntervalMin} 分钟 · 特勤处制造每 ${craftIntervalMin} 分钟 · 系统通知${notify ? '开启' : '关闭（--notify 可开启）'} · 上游抓取循环随服务常驻`)
  })
  await site.start()
  const shutdown = (sig) => {
    log(`收到 ${sig}，关闭服务`)
    site.close().then(() => process.exit(0))
  }
  process.on('SIGINT', () => shutdown('SIGINT'))
  process.on('SIGTERM', () => shutdown('SIGTERM'))
}
