// verify-effects.mjs — 自包含、零 npm 依赖（node >= 22：原生 fetch/WebSocket，低版本启动即友好报错）
// 前置：本脚本只 spawn headless Chrome，不拉起 dev server——先 `npm run dev`，再另开终端运行：
// 用法:
//   node scripts/verify-effects.mjs                       # 默认 http://localhost:5173/：hero+lightbox 挂载且存活（硬判据）
//   node scripts/verify-effects.mjs --reduced             # --force-prefers-reduced-motion，要求 data-fx="reduced" 且无挂载
//   node scripts/verify-effects.mjs [--reduced] <url> <shotsDir>
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const CHROME = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const argv = process.argv.slice(2);
const REDUCED = argv.includes('--reduced');
const args = argv.filter(a => !a.startsWith('--'));
const PAGE_URL = args[0] || 'http://localhost:5173/';
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..'); // 仓库根（scripts/ 上溯）
const SHOTS = args[1] || path.join(ROOT, 'shots'); // 仓库相对默认，脱离本机绝对路径
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

// 期望值从源数据动态求和（不再冻结数字：新增地图/点位后判据自动跟随）：
// hotspots/*.json 顶层为纯数组，求和即全站点位数；图数与 maps/*.json 文件
// 一一对应（mapIndex.js 成对 import）。目录不存在（非仓库环境）时回退当前
// 快照值并在 summary 标注 (fallback)，避免崩溃。
const HS_FALLBACK = 166, SECTIONS_FALLBACK = 6;
function listJsonDir(dirUrl) {
  try { return fs.readdirSync(dirUrl).filter(f => f.endsWith('.json')); } catch { return null; }
}
const hsDirUrl = new URL('../apps/web/src/data/hotspots/', import.meta.url);
const mapsDirUrl = new URL('../apps/web/src/data/maps/', import.meta.url);
const hsFiles = listJsonDir(hsDirUrl);
const mapsFiles = listJsonDir(mapsDirUrl);
let expectedHs = HS_FALLBACK, expectedSections = SECTIONS_FALLBACK, expectedIsFallback = false;
if (hsFiles && mapsFiles) {
  expectedHs = hsFiles.reduce((n, f) => {
    const arr = JSON.parse(fs.readFileSync(new URL(f, hsDirUrl), 'utf8'));
    return n + (Array.isArray(arr) ? arr.length : 0);
  }, 0);
  expectedSections = mapsFiles.length;
} else {
  expectedIsFallback = true;
}

const consoleErrors = [];
const pageErrors = [];
let chrome;
let profileDir = null;

function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

try {
  profileDir = fs.mkdtempSync('/tmp/verify-fx-');
  // stderr 用 pipe 并持续消费：既读取 DevTools 监听地址，也避免从不读取的
  // pipe 写满 64KB 卡死 Chrome
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
    ...(REDUCED ? ['--force-prefers-reduced-motion'] : []),
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

  const ws = new WebSocket(await waitDevtools());
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
  ws.onmessage = e => {
    const m = JSON.parse(e.data);
    if (m.id && pend.has(m.id)) {
      const { res, rej } = pend.get(m.id);
      pend.delete(m.id);
      m.error ? rej(new Error(m.error.message)) : res(m.result);
      return;
    }
    if (!m.method) return;
    if (m.method === 'Runtime.consoleAPICalled' && m.params.type === 'error')
      consoleErrors.push(m.params.args.map(a => a.value ?? a.description ?? '').join(' '));
    if (m.method === 'Runtime.exceptionThrown')
      pageErrors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
    if (m.method === 'Log.entryAdded' && m.params.entry.level === 'error')
      consoleErrors.push(m.params.entry.text);
  };
  // WS 意外断开（Chrome 被杀等）时 reject 全部 pending——fail loud 进 catch，
  // 而不是挂死在未决的顶层 await（实测 exit code 13）
  ws.onclose = () => { for (const { rej } of pend.values()) rej(new Error('CDP WebSocket 已关闭')); pend.clear(); };

  const { targetId } = await send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await send('Target.attachToTarget', { targetId, flatten: true });
  const S = (m, p) => send(m, p, sessionId);
  await S('Page.enable');
  await S('Runtime.enable');
  await S('Log.enable');
  await S('Emulation.setDeviceMetricsOverride', { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
  await S('Page.navigate', { url: PAGE_URL });

  // 轮询 data-fx 进入终态（慢机器友好），再留 1.5s 稳定
  const TERMINAL_FX = ['on', 'off', 'fallback', 'unsupported', 'reduced']; // off：移动端 coarsePointer 分支（桌面 headless 走不到，无副作用）
  for (let i = 0; i < 40; i++) {
    await sleep(500);
    const r = await S('Runtime.evaluate', { expression: 'document.documentElement.getAttribute("data-fx")', returnByValue: true });
    if (TERMINAL_FX.includes(r.result.value)) break;
  }
  await sleep(1500);

  async function readState() {
    const ev = await S('Runtime.evaluate', {
      expression: `JSON.stringify({
        hs: document.querySelectorAll('.hs').length,
        sections: document.querySelectorAll('.map-section').length,
        hasLib: !!(window.ShadersLib && window.ShadersLib.createShader),
        fxState: document.documentElement.getAttribute('data-fx'),
        locked: document.documentElement.classList.contains('locked'),
        heroFx: (document.getElementById('fxHero') || {}).getAttribute ? document.getElementById('fxHero').getAttribute('data-fx') : null,
        lbFx: (document.getElementById('fxLb') || {}).getAttribute ? document.getElementById('fxLb').getAttribute('data-fx') : null
      })`,
      returnByValue: true,
    });
    return JSON.parse(ev.result.value);
  }

  const site = await readState();
  fs.writeFileSync(path.join(SHOTS, 'after-hero.png'),
    Buffer.from((await S('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })).data, 'base64'));

  // lightbox 自动验证：点"全屏查看"（既有 L607-612 click 委托 → Lightbox.open）
  let lbOpened = false;   // 机制：html.locked 被观察到
  let lbMounted = false;  // 挂载：打开过程中 #fxLb data-fx === 'on'
  let lbAlive = false;    // 存活：二次打开后 canvas 像素 700ms 内变化（非静帧）
  if (!REDUCED) {
    const clk = await S('Runtime.evaluate', {
      expression: `(function(){ var b = document.querySelector('button[data-act="full"]'); if (!b) return 'no-button'; b.click(); return 'clicked'; })()`,
      returnByValue: true,
    });
    if (clk.result.value === 'clicked') {
      for (let i = 0; i < 20; i++) {
        await sleep(500);
        const st = await readState();
        if (st.locked) {
          lbOpened = true;
          if (st.lbFx === 'on') { lbMounted = true; break; }
        }
        if (!st.locked && i > 8) break;
      }
      if (lbOpened) {
        await sleep(1200);
        fs.writeFileSync(path.join(SHOTS, 'after-lightbox.png'),
          Buffer.from((await S('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })).data, 'base64'));
      }
      await S('Runtime.evaluate', { expression: `(document.getElementById('lbClose')||{click:function(){}}).click()`, returnByValue: true });
      for (let i = 0; i < 10; i++) {
        await sleep(300);
        if (!(await readState()).locked) break;
      }

      // 二次打开 + 像素存活断言（堵"挂载但已停摆"盲区）：data-fx='on' 是首次挂载时写入的静态属性，
      // 无法区分动画运行与静帧；rAF 计数已被实测证伪（心跳自身维持合成管线），像素差异才有效。
      await S('Runtime.evaluate', {
        expression: `document.querySelector('button[data-act="full"]').click()`,
        returnByValue: true,
      });
      for (let i = 0; i < 20; i++) {
        await sleep(500);
        const st = await readState();
        if (st.locked && st.lbFx === 'on') break;
      }
      await sleep(1200);
      const lv = await S('Runtime.evaluate', {
        expression: `(async function(){
          var c = document.getElementById('fxLb');
          if (!c) return JSON.stringify({ alive: false, why: 'no-canvas' });
          var a = c.toDataURL();
          await new Promise(function (r) { setTimeout(r, 700); });
          var b = c.toDataURL();
          return JSON.stringify({ alive: a !== b, why: a !== b ? 'animating' : 'frozen' });
        })()`,
        awaitPromise: true,
        returnByValue: true,
      });
      try { lbAlive = JSON.parse(lv.result.value).alive; } catch {}
      await S('Runtime.evaluate', { expression: `(document.getElementById('lbClose')||{click:function(){}}).click()`, returnByValue: true });
      for (let i = 0; i < 10; i++) {
        await sleep(300);
        if (!(await readState()).locked) break;
      }
    }
  }

  const site2 = await readState();
  fs.writeFileSync(path.join(SHOTS, 'after-full.png'),
    Buffer.from((await S('Page.captureScreenshot', { format: 'png', captureBeyondViewport: true })).data, 'base64'));

  // 分区逐屏截图：全页长图缩放后正文不可辨读，且未滚动到的分区 .reveal 未触发（opacity:0 全暗）；
  // 逐 section scrollIntoView 后按视口截屏，供逐段文字可读性核验（同时让入场渐显真实走完）
  const sectionShots = [];
  const secN = await S('Runtime.evaluate', { expression: 'document.querySelectorAll(".map-section").length', returnByValue: true });
  for (let i = 0; i < (secN.result.value || 0); i++) {
    await S('Runtime.evaluate', { expression: `document.querySelectorAll('.map-section')[${i}].scrollIntoView(true)`, returnByValue: true });
    await sleep(800);
    const name = `after-section-${i + 1}.png`;
    fs.writeFileSync(path.join(SHOTS, name),
      Buffer.from((await S('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false })).data, 'base64'));
    sectionShots.push(name);
  }

  const siteHealthy = site.hs >= expectedHs && site.sections === expectedSections
    && site2.hs >= expectedHs && site2.sections === expectedSections;
  const noErrors = consoleErrors.length === 0 && pageErrors.length === 0;
  const heroMounted = site.heroFx === 'on';
  const effectsMounted = site.fxState === 'on' && heroMounted && lbMounted && lbAlive; // 硬判据：三处全 on 且 lb 非静帧
  const reducedClean = site.fxState === 'reduced' && !heroMounted && !lbMounted;
  const ok = noErrors && siteHealthy
    && (REDUCED ? reducedClean : (effectsMounted && lbOpened)); // fallback/unsupported/vendor 缺失/停摆均 fail

  console.log('EFFECTS_VERIFY ' + JSON.stringify({
    ok,
    summary: `fxState=${site.fxState} heroFx=${site.heroFx} lbFx=${site.lbFx} lightboxOpened=${lbOpened} lbMounted=${lbMounted} lbAlive=${lbAlive}`
      + ` hs=${site.hs}/${expectedHs}${expectedIsFallback ? '(fallback)' : ''} sections=${site.sections}/${expectedSections}${expectedIsFallback ? '(fallback)' : ''} hasLib=${site.hasLib} mode=${REDUCED ? 'reduced' : 'default'}`
      + (ok ? '' : (siteHealthy ? ' | mount criterion not met (default mode REQUIRES real mount)' : ' | SITE BROKEN')),
    consoleErrors,
    effectsMounted,
    screenshots: ['after-hero.png', ...(lbOpened ? ['after-lightbox.png'] : []), 'after-full.png', ...sectionShots],
  }));
  ws.close();
  process.exitCode = ok ? 0 : 1;
} catch (err) {
  console.log('EFFECTS_VERIFY ' + JSON.stringify({
    ok: false,
    summary: 'harness error: ' + (err && err.message || err),
    consoleErrors,
    effectsMounted: false,
    screenshots: [],
  }));
  process.exitCode = 1;
} finally {
  if (chrome) {
    chrome.kill();
    await new Promise(r => { chrome.once('exit', () => r(null)); setTimeout(r, 2000); });
  }
  if (profileDir) { try { fs.rmSync(profileDir, { recursive: true, force: true }); } catch {} }
}
