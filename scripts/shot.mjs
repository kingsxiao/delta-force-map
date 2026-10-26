// shot.mjs — 视觉巡检截图工具（自包含、零 npm 依赖，node >= 22 原生 WebSocket）。
// CDP 驱动模板与 server/smoke.mjs 同源（spawn headless Chrome，--remote-debugging-port=0
// 多实例并行天然不冲突）。与 smoke 的分工：smoke 是构建产物 DOM 断言门禁；本脚本只负责
// 「把指定路由在指定视口/交互态下渲染成整页截图（自动纵向切片），供视觉审查」。
//
// 用法：
//   node scripts/shot.mjs <baseUrl> <outDir> --preset all      # 全页面基线：6 路由 × 桌面/移动/交互态
//   node scripts/shot.mjs <baseUrl> <outDir> --preset probe    # 快速自检：仅子弹行情桌面一张
//   node scripts/shot.mjs <baseUrl> <outDir> --preset ammo     # 单页基线（ammo|radar|craft|ttk|account|notfound）
//   node scripts/shot.mjs <baseUrl> <outDir> --route /ttk --name my-shot \
//        [--w 1440 --h 900 --dsf 1] [--steps '<json>'] [--token <jwt>] [--png]
//        # 自定义单张：steps = [{"click":".seg-btn"},{"type":["input.q","文字"]},
//        #                    {"eval":"js 表达式"},{"wait":500},{"reload":true}]
//
// 输出：JPEG（q85，整页超过 SLICE 高度自动按 3600px 纵向切片，命名 <name>-1.jpg / -2.jpg …）；
//       结束打印 JSON 摘要（每张的文件/是否 ready/console 错误/告警）。退出码 0 = 跑完（含局部告警），
//       非 0 = 致命（Chrome 起不来 / 导航失败）。局部问题（选择器未命中、ready 超时）只记告警不失败——
//       视觉审查要的恰恰是「页面此刻长什么样」，包括坏掉的样子。
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const SLICE = 3600;          // 单张切片最大高度（px）：过高的整页截图被查看器缩放后看不清细节
const JPEG_Q = 85;

const argv = process.argv.slice(2);
const BASE = (argv[0] || '').replace(/\/+$/, '');
const OUT = argv[1] || 'shots/wf';
if (!BASE) { console.error('用法: node scripts/shot.mjs <baseUrl> <outDir> [--preset ...|--route ...]'); process.exit(2); }
fs.mkdirSync(OUT, { recursive: true });

function opt(name, dflt) { const i = argv.indexOf(name); return i >= 0 ? argv[i + 1] : dflt; }
const hasFlag = (name) => argv.includes(name);
const WANT_PNG = hasFlag('--png');

/* ---------- 路由就绪判定（口径与 server/smoke.mjs 对齐：离开 loading 到任一终态） ---------- */
const READY = {
  '/ammo': `document.querySelectorAll('.site-topbar .tab').length === 5 && !!document.querySelector('.wrap.page .compact-head h1') && (document.querySelectorAll('.page .block').length >= 1 || document.querySelectorAll('.page .state-card').length >= 1)`,
  '/radar': `document.querySelectorAll('.site-topbar .tab').length === 5 && !!document.querySelector('.wrap.page .compact-head h1') && (document.querySelectorAll('.page .ctl-bar').length >= 1 || document.querySelectorAll('.page .state-card').length >= 1)`,
  '/craft': `document.querySelectorAll('.site-topbar .tab').length === 5 && !!document.querySelector('.wrap.page .compact-head h1') && (document.querySelectorAll('.page .hero').length >= 1 || document.querySelectorAll('.page .state-card').length >= 1)`,
  '/ttk': `document.querySelectorAll('.site-topbar .tab').length === 5 && document.querySelectorAll('.ttk-page').length === 1 && document.querySelectorAll('.rk-row').length >= 1`,
  '/account': `document.querySelectorAll('.site-topbar .tab').length === 5 && !!document.querySelector('.compact-head h1') && (document.querySelectorAll('.auth-stage').length >= 1 || document.querySelectorAll('.auth-card').length >= 1)`,
};
const readyFor = (route) => READY[route] ||
  `document.querySelectorAll('.site-topbar .tab').length === 5 && document.body.innerText.length > 50`;

/* ---------- 视口与基线场景 ---------- */
const DESKTOP = { w: 1440, h: 900, dsf: 1, mobile: false };
const MOBILE = { w: 390, h: 844, dsf: 2, mobile: true };
// 交互态选择器全部「命中才点」：改版后选择器变了只降级为少一张图，不会挂死
const PRESETS = {
  ammo: [
    { name: 'ammo-desktop', route: '/ammo', ...DESKTOP },
    { name: 'ammo-desktop-row-open', route: '/ammo', ...DESKTOP, steps: [{ click: '.page .tbl tbody tr' }, { wait: 600 }] },
    { name: 'ammo-mobile', route: '/ammo', ...MOBILE },
  ],
  radar: [
    { name: 'radar-desktop', route: '/radar', ...DESKTOP },
    { name: 'radar-desktop-row-open', route: '/radar', ...DESKTOP, steps: [{ click: '.page .tbl tbody tr' }, { wait: 600 }] },
    { name: 'radar-mobile', route: '/radar', ...MOBILE },
  ],
  craft: [
    { name: 'craft-desktop', route: '/craft', ...DESKTOP },
    { name: 'craft-desktop-chip2', route: '/craft', ...DESKTOP, steps: [{ click: '.page .chips .chip:nth-child(2)' }, { wait: 800 }] },
    { name: 'craft-mobile', route: '/craft', ...MOBILE },
  ],
  ttk: [
    { name: 'ttk-desktop', route: '/ttk', ...DESKTOP },
    { name: 'ttk-desktop-row-open', route: '/ttk', ...DESKTOP, steps: [{ click: '.rk-row' }, { wait: 600 }] },
    { name: 'ttk-mobile', route: '/ttk', ...MOBILE },
  ],
  // account 第三张「已登录」面板态：现场注册一次性测试号（wfvis-*，跑完由工作流清理）注入 localStorage
  account: [
    { name: 'account-desktop-loggedout', route: '/account', ...DESKTOP },
    { name: 'account-mobile-loggedout', route: '/account', ...MOBILE },
    { name: 'account-desktop-loggedin', route: '/account', ...DESKTOP, loggedIn: true },
  ],
  notfound: [
    { name: 'notfound-desktop', route: '/wf-404-probe', ...DESKTOP },
    { name: 'notfound-mobile', route: '/wf-404-probe', ...MOBILE },
  ],
};

let shots;
const preset = opt('--preset', null);
if (preset) {
  if (preset === 'all') shots = Object.values(PRESETS).flat();
  else if (preset === 'probe') shots = PRESETS.ammo.slice(0, 1);
  else if (PRESETS[preset]) shots = PRESETS[preset];
  else { console.error(`未知 preset: ${preset}（可用: all|probe|${Object.keys(PRESETS).join('|')}）`); process.exit(2); }
} else {
  const route = opt('--route', '/ammo');
  shots = [{
    name: opt('--name', 'custom'), route,
    w: +opt('--w', 1440), h: +opt('--h', 900), dsf: +opt('--dsf', 1), mobile: false,
    steps: (() => { const s = opt('--steps', null); try { return s ? JSON.parse(s) : []; } catch { console.error('--steps 不是合法 JSON'); process.exit(2); } })(),
    token: opt('--token', null),
  }];
}

/* ---------- CDP 基座（与 smoke.mjs 同套路） ---------- */
if (typeof WebSocket === 'undefined') { console.error('需要 Node >= 22（原生 WebSocket），当前 ' + process.version); process.exit(1); }
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const profileDir = fs.mkdtempSync('/tmp/shot-');
let chrome, ws = null;
const warnings = [];
const summary = [];

try {
  let devtoolsWsUrl = null, stderrTail = '';
  chrome = spawn(CHROME, [
    '--remote-debugging-port=0', '--headless=new',
    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--hide-scrollbars', `--user-data-dir=${profileDir}`, 'about:blank',
  ], { stdio: ['ignore', 'ignore', 'pipe'] });
  chrome.stderr.on('data', (d) => {
    if (devtoolsWsUrl) return;
    stderrTail += d.toString();
    const m = stderrTail.match(/DevTools listening on (ws:\/\/\S+)/);
    if (m) devtoolsWsUrl = m[1];
  });
  for (let i = 0; i < 150 && !devtoolsWsUrl; i++) await sleep(100);
  if (!devtoolsWsUrl) throw new Error('Chrome DevTools 未就绪');

  ws = new WebSocket(devtoolsWsUrl);
  await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('CDP WebSocket 连接失败')); });
  let id = 0;
  const pend = new Map();
  const send = (method, params = {}, sessionId) => new Promise((res, rej) => {
    const i = ++id;
    pend.set(i, { res, rej });
    ws.send(JSON.stringify({ id: i, method, params, ...(sessionId ? { sessionId } : {}) }));
  });
  const errsBySession = new Map();
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pend.has(m.id)) {
      const { res, rej } = pend.get(m.id); pend.delete(m.id);
      m.error ? rej(new Error(m.error.message)) : res(m.result); return;
    }
    if (!m.method || !m.sessionId) return;
    const bucket = errsBySession.get(m.sessionId) || (errsBySession.set(m.sessionId, []).get(m.sessionId));
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error')
      bucket.push(m.params.args.map((a) => a.value ?? a.description ?? '').join(' '));
    if (m.method === 'Runtime.exceptionThrown')
      bucket.push(m.params.exceptionDetails?.exception?.description || m.params.exceptionDetails?.text);
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error' && !String(m.params.entry.url || '').startsWith('http://127.0.0.1:8787/'))
      bucket.push(m.params.entry.text);
  };
  ws.onclose = () => { for (const { rej } of pend.values()) rej(new Error('CDP WebSocket 已关闭')); pend.clear(); };

  // 注册一次性测试账号（仅 account 已登录态用；失败只降级，不致命）
  async function registerTestSession() {
    const u = 'wfvis-' + Date.now().toString(36);
    try {
      const r = await fetch(`${BASE}/api/auth/register`, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ username: u, password: 'Wfv-2026-visual' }),
      });
      if (!r.ok) { warnings.push(`测试账号注册失败(HTTP ${r.status})，跳过已登录态截图`); return null; }
      return await r.json(); // {token, user}
    } catch (err) { warnings.push(`测试账号注册异常: ${err.message}`); return null; }
  }

  async function waitReady(S, expr) {
    for (let i = 0; i < 80; i++) {
      await sleep(300);
      try {
        const r = await S('Runtime.evaluate', { expression: expr, returnByValue: true });
        if (r.result.value === true) return true;
      } catch { /* 页面导航瞬间 evaluate 可能抛错，继续轮询 */ }
    }
    return false;
  }

  async function runSteps(S, steps) {
    for (const st of steps || []) {
      if (st.wait) { await sleep(st.wait); continue; }
      if (st.reload) continue; // reload 在 navigate 层处理
      if (st.click) {
        const r = await S('Runtime.evaluate', {
          expression: `(() => { const el = document.querySelector(${JSON.stringify(st.click)}); if (!el) return false; el.scrollIntoView({block:'center'}); el.click(); return true; })()`,
          returnByValue: true,
        });
        if (!r.result.value) warnings.push(`click 选择器未命中: ${st.click}`);
        await sleep(500);
        continue;
      }
      if (st.type) {
        const [sel, text] = st.type;
        const r = await S('Runtime.evaluate', {
          expression: `(() => { const el = document.querySelector(${JSON.stringify(sel)}); if (!el) return false; el.focus(); el.value = ${JSON.stringify(text)}; el.dispatchEvent(new Event('input', {bubbles:true})); el.dispatchEvent(new Event('change', {bubbles:true})); return true; })()`,
          returnByValue: true,
        });
        if (!r.result.value) warnings.push(`type 选择器未命中: ${sel}`);
        await sleep(400);
        continue;
      }
      if (st.eval) { await S('Runtime.evaluate', { expression: st.eval, returnByValue: true, awaitPromise: true }); await sleep(300); }
    }
  }

  for (const shot of shots) {
    const url = `${BASE}/#${shot.route}`;
    const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
    const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
    errsBySession.set(sessionId, []);
    const S = (m, p) => send(m, p, sessionId);
    await S('Page.enable'); await S('Runtime.enable'); await S('Log.enable');
    await S('Emulation.setDeviceMetricsOverride', { width: shot.w, height: shot.h, deviceScaleFactor: shot.dsf, mobile: !!shot.mobile });

    let needsReload = false;
    if (shot.loggedIn || shot.token) {
      // 先到目标源再写 localStorage（about:blank 上写不进目标域），随后 reload 生效
      const nav0 = await S('Page.navigate', { url });
      if (nav0.errorText) throw new Error(`${shot.name} 导航失败: ${nav0.errorText}`);
      await sleep(1200);
      const session = shot.token
        ? { token: shot.token, user: { username: 'wfvis-token' } }
        : (await registerTestSession());
      if (session) {
        await S('Runtime.evaluate', {
          expression: `localStorage.setItem('df.auth.token', ${JSON.stringify(session.token)}); localStorage.setItem('df.auth.user', ${JSON.stringify(JSON.stringify(session.user))}); true`,
          returnByValue: true,
        });
        needsReload = true;
      } else warnings.push(`${shot.name}: 无可用会话，按未登录态截图`);
    }

    const nav = await S('Page.navigate', { url });
    if (nav.errorText) throw new Error(`${shot.name} 导航失败: ${nav.errorText}`);
    const ready = await waitReady(S, readyFor(shot.route));
    await sleep(1500); // 动画/懒加载收尾
    if (needsReload) { // 登录态：reload 后重新等就绪
      await S('Page.navigate', { url });
      await waitReady(S, readyFor(shot.route));
      await sleep(1500);
    }
    // 触发折叠区懒加载再回到顶部，随后整页截图
    await S('Runtime.evaluate', { expression: `window.scrollTo(0, document.body.scrollHeight); true`, returnByValue: true });
    await sleep(600);
    await S('Runtime.evaluate', { expression: `window.scrollTo(0, 0); true`, returnByValue: true });
    await sleep(400);
    await runSteps(S, shot.steps);

    const metrics = await S('Page.getLayoutMetrics');
    const content = metrics.cssContentSize || metrics.contentSize;
    const W = Math.ceil(content.width), H = Math.ceil(content.height);
    const files = [];
    const nSlices = Math.max(1, Math.ceil(H / SLICE));
    for (let i = 0; i < nSlices; i++) {
      const y = i * SLICE;
      const h = Math.min(SLICE, H - y);
      const cap = await S('Page.captureScreenshot', {
        format: WANT_PNG ? 'png' : 'jpeg', quality: JPEG_Q,
        clip: { x: 0, y, width: W, height: h, scale: 1 },
        captureBeyondViewport: true,
      });
      const file = path.join(OUT, nSlices === 1 ? `${shot.name}.${WANT_PNG ? 'png' : 'jpg'}` : `${shot.name}-${i + 1}.${WANT_PNG ? 'png' : 'jpg'}`);
      fs.writeFileSync(file, Buffer.from(cap.data, 'base64'));
      files.push(path.relative(process.cwd(), file));
    }
    summary.push({ name: shot.name, url, ready, page: `${W}x${H}`, files, consoleErrors: errsBySession.get(sessionId) || [] });
    console.log(`✓ ${shot.name} ${W}x${H} → ${files.length} 张${ready ? '' : '（ready 超时，按现状截取）'}`);
    await send('Target.closeTarget', { targetId });
  }
} catch (err) {
  console.error('致命错误: ' + err.message);
  console.log(JSON.stringify({ base: BASE, out: OUT, summary, warnings, fatal: err.message }, null, 2));
  process.exit(1);
} finally {
  try { ws && ws.close(); } catch { /* 忽略 */ }
  try { chrome && chrome.kill(); } catch { /* 忽略 */ }
  setTimeout(() => { try { fs.rmSync(profileDir, { recursive: true, force: true }); } catch { /* 忽略 */ } }, 300).unref();
}
console.log(JSON.stringify({ base: BASE, out: OUT, summary, warnings }, null, 2));
