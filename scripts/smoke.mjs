// smoke.mjs — 构建产物真实浏览器冒烟验证（自包含、零 npm 依赖，node >= 22：原生 fetch/WebSocket）
// 模式照搬 scripts/verify-effects.mjs（本仓库现成的 CDP 驱动模板）。
// 前置：本脚本只 spawn headless Chrome，不拉起 preview server——先另开终端运行：
//   npm run preview -- --port 4173 --strictPort
// 用法:
//   node scripts/smoke.mjs                     # 默认 http://localhost:4173/，截图到 shots/vue-smoke/
//   node scripts/smoke.mjs <baseUrl> <shotsDir>
// 注意：src/router.js 用 createWebHashHistory（hash 路由，静态托管免 SPA fallback），
//       三个 tab 的实际 URL 是 /#/、/#/tactics、/#/ttk。
// 路由是 hash 模式，因此“/tactics”这一 tab 对应 URL `/#/tactics`。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const PORT = 9333;
const argv = process.argv.slice(2);
const BASE = (argv[0] || 'http://localhost:4173').replace(/\/+$/, '');
const SHOTS = argv[1] || '/Users/wangxiao/githubProject/delta-force-map/shots/vue-smoke';
fs.mkdirSync(SHOTS, { recursive: true });

// 每个 tab：路由路径（用于报告）、实际访问 URL、截图文件名、DOM 断言
const ROUTES = [
  {
    route: '/', file: 'home.png', expectActive: '地图',
    ready: `document.querySelectorAll('.site-topbar .tab').length === 3
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
    ok: s => s.tabs === 3 && s.activeTab === '地图' && s.mapSections >= 1 && s.imgs >= 1 && s.imgsLoaded >= 1,
  },
  {
    route: '/tactics', file: 'tactics.png', expectActive: '打法',
    ready: `document.querySelectorAll('.site-topbar .tab').length === 3
            && document.querySelectorAll('.tactics-page').length === 1
            && (document.querySelectorAll('.spawn-card').length >= 1 || document.querySelectorAll('.loot-table').length >= 1)`,
    assert: `JSON.stringify({
      tabs: document.querySelectorAll('.site-topbar .tab').length,
      activeTab: (document.querySelector('.site-topbar .tab.active') || {textContent: null}).textContent?.trim() ?? null,
      spawnCards: document.querySelectorAll('.spawn-card').length,
      lootTables: document.querySelectorAll('.loot-table').length,
      lootRows: document.querySelectorAll('.loot-table tbody tr').length
    })`,
    ok: s => s.tabs === 3 && s.activeTab === '打法' && (s.spawnCards >= 1 || s.lootTables >= 1),
  },
  {
    route: '/ttk', file: 'ttk.png', expectActive: 'TTK排行',
    ready: `document.querySelectorAll('.site-topbar .tab').length === 3
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
    ok: s => s.tabs === 3 && s.activeTab === 'TTK排行' && s.rankRows >= 1 && s.segBtns >= 1,
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
  // stderr 用 ignore：从不读取的 pipe 写满 64KB 会卡死 Chrome（verify-effects.mjs 同款经验）
  chrome = spawn(CHROME, [
    `--remote-debugging-port=${PORT}`,
    '--headless=new',
    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--enable-unsafe-webgpu',
    `--user-data-dir=${profileDir}`,
    '--window-size=1440,900',
    'about:blank',
  ], { stdio: ['ignore', 'ignore', 'ignore'] });

  async function waitPort() {
    for (let i = 0; i < 150; i++) {
      try {
        const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
        if (r.ok) return await r.json();
      } catch {}
      await sleep(100);
    }
    throw new Error('Chrome CDP 端口未就绪');
  }

  const ver = await waitPort();
  ws = new WebSocket(ver.webSocketDebuggerUrl);
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
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error')
      consoleErrors.push({ route, text: m.params.entry.text });
  };

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
