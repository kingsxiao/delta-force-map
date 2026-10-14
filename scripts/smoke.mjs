// smoke.mjs — 构建产物真实浏览器冒烟验证（自包含、零 npm 依赖，node >= 22：原生 fetch/WebSocket，低版本启动即友好报错）
// 模式照搬 scripts/verify-effects.mjs（本仓库现成的 CDP 驱动模板）。
// 前置：本脚本只 spawn headless Chrome，不拉起 preview server——先另开终端运行：
//   npm run preview -- --port 4173 --strictPort
// 用法:
//   node scripts/smoke.mjs                     # 默认 http://localhost:4173/，截图到 shots/vue-smoke/
//   node scripts/smoke.mjs <baseUrl> <shotsDir>
// 注意：src/router.js 用 createWebHashHistory（hash 路由，静态托管免 SPA fallback），
//       四个 tab 的实际 URL 是 /#/、/#/tactics、/#/ttk、/#/ammo。
// 路由是 hash 模式，因此“/tactics”这一 tab 对应 URL `/#/tactics`。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const argv = process.argv.slice(2);
const BASE = (argv[0] || 'http://localhost:4173').replace(/\/+$/, '');
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'); // 仓库根（scripts/ 上溯）
const SHOTS = argv[1] || path.join(ROOT, 'shots', 'vue-smoke'); // 仓库相对默认，脱离本机绝对路径
fs.mkdirSync(SHOTS, { recursive: true });

// Node 20（package.json engines 下限）无全局 WebSocket——置于 spawn Chrome 之前：
// 死得早不拉孤儿进程，报错自解释而非误导性 ReferenceError
if (typeof WebSocket === 'undefined') {
  console.error('此脚本需要 Node >= 22（原生 WebSocket），当前 ' + process.version
    + '；dev/build 不受影响（package.json engines >=20.19），仅检查脚本需 22');
  process.exit(1);
}

/* CDP 端口：--remote-debugging-port=0 由内核自动分配（多实例并行天然不冲突、
   不受残留 Chrome 占口影响），实际监听地址从本实例 stderr 的
   "DevTools listening on ws://…" 行读取——归属确定，不会错连别人的 Chrome。 */

// 每个 tab：路由路径（用于报告）、实际访问 URL、截图文件名、DOM 断言
const ROUTES = [
  {
    route: '/', file: 'home.png', expectActive: '地图',
    ready: `document.querySelectorAll('.site-topbar .tab').length === 5
            && document.querySelectorAll('.map-section').length >= 1
            && [...document.querySelectorAll('.fig-frame img')].some(i => i.complete && i.naturalWidth > 0)`,
    assert: `JSON.stringify({
      tabs: document.querySelectorAll('.site-topbar .tab').length,
      activeTab: (document.querySelector('.site-topbar .tab.active') || {textContent: null}).textContent?.trim() ?? null,
      mapSections: document.querySelectorAll('.map-section').length,
      figFrames: document.querySelectorAll('.fig-frame').length,
      imgs: document.querySelectorAll('.fig-frame img').length,
      imgsLoaded: [...document.querySelectorAll('.fig-frame img')].filter(i => i.complete && i.naturalWidth > 0).length
    })`,
    ok: s => s.tabs === 5 && s.activeTab === '地图' && s.mapSections >= 1 && s.imgs >= 1 && s.imgsLoaded >= 1,
  },
  {
    route: '/tactics', file: 'tactics.png', expectActive: '打法',
    ready: `document.querySelectorAll('.site-topbar .tab').length === 5
            && document.querySelectorAll('.tactics-page').length === 1
            && (document.querySelectorAll('.spawn-card').length >= 1 || document.querySelectorAll('.loot-table').length >= 1)`,
    assert: `JSON.stringify({
      tabs: document.querySelectorAll('.site-topbar .tab').length,
      activeTab: (document.querySelector('.site-topbar .tab.active') || {textContent: null}).textContent?.trim() ?? null,
      spawnCards: document.querySelectorAll('.spawn-card').length,
      lootTables: document.querySelectorAll('.loot-table').length,
      lootRows: document.querySelectorAll('.loot-table tbody tr').length
    })`,
    ok: s => s.tabs === 5 && s.activeTab === '打法' && (s.spawnCards >= 1 || s.lootTables >= 1),
  },
  {
    route: '/ttk', file: 'ttk.png', expectActive: 'TTK排行',
    ready: `document.querySelectorAll('.site-topbar .tab').length === 5
            && document.querySelectorAll('.ttk-page').length === 1
            && document.querySelectorAll('.rk-row').length >= 1
            && document.querySelectorAll('.seg-btn').length >= 1`,
    assert: `JSON.stringify({
      tabs: document.querySelectorAll('.site-topbar .tab').length,
      activeTab: (document.querySelector('.site-topbar .tab.active') || {textContent: null}).textContent?.trim() ?? null,
      rankRows: document.querySelectorAll('.rk-row').length,
      champCards: document.querySelectorAll('.champs .champ').length,
      segBtns: document.querySelectorAll('.seg-btn').length,
      segOnBtns: document.querySelectorAll('.seg-btn.on').length
    })`,
    ok: s => s.tabs === 5 && s.activeTab === 'TTK排行' && s.rankRows >= 1 && s.segBtns >= 1,
  },
  {
    // 子弹行情：loadState 四态（loading/ready/empty/error，AmmoMarketView.vue），
    // 断言只要求离开 loading 到达任一终态（.block=ready、.state-card=empty/error
    // 健康骨架页），不设行数门槛——无数据部署时 empty 也不应误报失败。
    route: '/ammo', file: 'ammo.png', expectActive: '子弹行情',
    ready: `document.querySelectorAll('.site-topbar .tab').length === 5
            && !!document.querySelector('.wrap.page .compact-head h1')
            && (document.querySelectorAll('.page .block').length >= 1 || document.querySelectorAll('.page .state-card').length >= 1)`,
    assert: `JSON.stringify({
      tabs: document.querySelectorAll('.site-topbar .tab').length,
      activeTab: (document.querySelector('.site-topbar .tab.active') || {textContent: null}).textContent?.trim() ?? null,
      h1: (document.querySelector('.compact-head h1') || {textContent: null}).textContent?.trim() ?? null,
      blocks: document.querySelectorAll('.page .block').length,
      stateCards: document.querySelectorAll('.page .state-card').length
    })`,
    ok: s => s.tabs === 5 && s.activeTab === '子弹行情' && (s.h1 || '').includes('子弹价格监控') && (s.blocks >= 1 || s.stateCards >= 1),
  },
  {
    // 异动雷达（MarketRadarView）：断言口径同子弹行情——离开 loading 到任一
    // 终态即可（.ctl-bar/.tbl-scroll=ready、.state-card=empty/error），不设行数门槛。
    route: '/radar', file: 'radar.png', expectActive: '异动雷达',
    ready: `document.querySelectorAll('.site-topbar .tab').length === 5
            && !!document.querySelector('.wrap.page .compact-head h1')
            && (document.querySelectorAll('.page .ctl-bar').length >= 1 || document.querySelectorAll('.page .state-card').length >= 1)`,
    assert: `JSON.stringify({
      tabs: document.querySelectorAll('.site-topbar .tab').length,
      activeTab: (document.querySelector('.site-topbar .tab.active') || {textContent: null}).textContent?.trim() ?? null,
      h1: (document.querySelector('.compact-head h1') || {textContent: null}).textContent?.trim() ?? null,
      ctlBars: document.querySelectorAll('.page .ctl-bar').length,
      stateCards: document.querySelectorAll('.page .state-card').length
    })`,
    ok: s => s.tabs === 5 && s.activeTab === '异动雷达' && (s.h1 || '').includes('全品类异动雷达') && (s.ctlBars >= 1 || s.stateCards >= 1),
  },
];

const consoleErrors = []; // 每条附 route 归属
const pageErrors = [];
const results = [];
let chrome;
let profileDir = null;
let ws = null;

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

try {
  profileDir = fs.mkdtempSync('/tmp/smoke-vue-');
  // stderr 用 pipe 并持续消费：既读取 DevTools 监听地址，也避免从不读取的
  // pipe 写满 64KB 卡死 Chrome（对 verify-effects.mjs 经验的改进）
  let devtoolsWsUrl = null;
  let stderrTail = '';
  chrome = spawn(CHROME, [
    '--remote-debugging-port=0',
    '--headless=new',
    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--enable-unsafe-webgpu',
    `--user-data-dir=${profileDir}`,
    '--window-size=1440,900',
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  chrome.stderr.on('data', d => {
    if (devtoolsWsUrl) return;
    stderrTail += d.toString();
    const m = stderrTail.match(/DevTools listening on (ws:\/\/\S+)/);
    if (m) devtoolsWsUrl = m[1];
  });

  async function waitDevtools() {
    for (let i = 0; i < 150; i++) {
      if (devtoolsWsUrl) return devtoolsWsUrl;
      await sleep(100);
    }
    throw new Error('Chrome DevTools 未就绪（stderr 无 listening 行）');
  }

  ws = new WebSocket(await waitDevtools());
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('CDP WebSocket 连接失败')); });

  let id = 0;
  const pend = new Map();
  function send(method, params = {}, sessionId) {
    return new Promise((res, rej) => {
      const i = ++id;
      pend.set(i, { res, rej });
      ws.send(JSON.stringify({ id: i, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  // sessionId → 当前 route（错误按 tab 归属，互不串扰）
  const routeBySession = new Map();
  ws.onmessage = e => {
    const m = JSON.parse(e.data);
    if (m.id && pend.has(m.id)) {
      const { res, rej } = pend.get(m.id);
      pend.delete(m.id);
      m.error ? rej(new Error(m.error.message)) : res(m.result);
      return;
    }
    if (!m.method || !m.sessionId) return;
    const route = routeBySession.get(m.sessionId) || '?';
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error')
      consoleErrors.push({ route, text: m.params.args.map(a => a.value ?? a.description ?? '').join(' ') });
    if (m.method === 'Runtime.exceptionThrown') {
      const d = m.params.exceptionDetails;
      pageErrors.push({ route, text: d.exception?.description || d.text });
    }
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error') {
      // 豁免：本地可选 live 通道（127.0.0.1:8787 SSE）连接被拒是设计内分支——
      // AmmoMarketView 的 connectLive 在 error 回调里关闭连接、回落 60s 轮询并
      // 标注 down 态；冒烟环境不跑 live 服务必然触发。按 entry.url 精确豁免，
      // 其余资源错误（含其他 ERR_CONNECTION_REFUSED）照常归集拦截。
      if (!String(m.params.entry.url || '').startsWith('http://127.0.0.1:8787/'))
        consoleErrors.push({ route, text: m.params.entry.text });
    }
  };
  // WS 意外断开（Chrome 被杀等）时 reject 全部 pending——fail loud 进 catch，
  // 而不是挂死在未决的顶层 await（实测 exit code 13）
  ws.onclose = () => { for (const { rej } of pend.values()) rej(new Error('CDP WebSocket 已关闭')); pend.clear(); };

  for (const R of ROUTES) {
    const url = `${BASE}/#${R.route === '/' ? '/' : R.route}`;
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    routeBySession.set(sessionId, R.route);
    const S = (m, p) => send(m, p, sessionId);
    await S('Page.enable');
    await S('Runtime.enable');
    await S('Log.enable');
    await S('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });

    // 每个 tab 用独立 target（独立 document），console/page error 天然按页分组
    const nav = await S('Page.navigate', { url });
    if (nav.errorText) throw new Error(`${R.route} 导航失败: ${nav.errorText}`);

    // 等渲染稳定：轮询该页 ready 表达式（Vue 挂载 + 关键内容就绪），慢机器友好
    let ready = false;
    for (let i = 0; i < 60; i++) {
      await sleep(300);
      const r = await S('Runtime.evaluate', { expression: R.ready, returnByValue: true });
      if (r.result.value === true) { ready = true; break; }
    }
    await sleep(1500); // 再留 1.5s 稳定（reveal 动画/懒加载收尾）

    const ev = await S('Runtime.evaluate', { expression: R.assert, returnByValue: true });
    let state = null;
    try { state = JSON.parse(ev.result.value); } catch {}
    const pass = ready && !!state && R.ok(state);

    fs.writeFileSync(path.join(SHOTS, R.file),
      Buffer.from((await S('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })).data, 'base64'));

    results.push({
      route: R.route,
      url,
      ready,
      pass,
      state,
      shot: R.file,
      consoleErrors: consoleErrors.filter(x => x.route === R.route),
      pageErrors: pageErrors.filter(x => x.route === R.route),
    });
    await send('Target.closeTarget', { targetId });
  }

  const allOk = results.length === ROUTES.length && results.every(r => r.pass)
    && consoleErrors.length === 0 && pageErrors.length === 0;

  console.log('SMOKE ' + JSON.stringify({
    ok: allOk,
    base: BASE,
    summary: results.map(r =>
      `${r.route}:${r.pass ? 'PASS' : 'FAIL'}(ready=${r.ready} ${JSON.stringify(r.state)})`).join(' | '),
    consoleErrors,
    pageErrors,
    results,
    screenshots: ROUTES.map(r => path.join(SHOTS, r.file)),
  }, null, 2));
  process.exitCode = allOk ? 0 : 1;
} catch (err) {
  console.log('SMOKE ' + JSON.stringify({
    ok: false,
    summary: 'harness error: ' + (err && err.message || err),
    consoleErrors,
    pageErrors,
    results,
    screenshots: [],
  }, null, 2));
  process.exitCode = 1;
} finally {
  try { ws && ws.close(); } catch {}
  if (chrome) {
    chrome.kill();
    await new Promise(r => { chrome.once('exit', () => r(null)); setTimeout(r, 2000); });
  }
  if (profileDir) { try { fs.rmSync(profileDir, { recursive: true, force: true }); } catch {} }
}
