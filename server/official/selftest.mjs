/* ============================================================
   selftest.mjs — 官方 AMS 客户端与物品目录自测（node 直接运行）
   ------------------------------------------------------------
   离线（默认，零外网，fetch 全注桩）覆盖：
     ① callFlow：ret=0 解析（Content-Type text/html 正文 JSON）+ 表单/头形状
     ② callFlow：ret=-11009 → 抛错含 sMsg（token 兜底链重试后仍如实抛）
     ③ token 兜底链：坏 token → GET 流目录 → 新 token 重试成功（域名不被 sIdeUrl 覆盖）
     ④ fetchObjectList：object.list 归一化（objectID String 化 / detail 透传 / 杂字段不外泄）
     ⑤ fetchHourlyAvgPrice：累计数组取末元素 + 去重后 ≤5 分批 + stat_hour 键格式
     ⑥ fetchHourlyAvgPrice：单批失败不炸整体
     ⑦ normalizeName：星号 / 零宽 / 全角 / 空白折叠变体
     ⑧ 目录持久化：TTL 内二次加载零请求 + findByName 精确 / 归一化 / ambiguous
     ⑨ 目录 TTL 过期 → 重新抓取
     ⑩ 官方均价锚 ammo-anchor：名称映射精确 / 归一化 / 歧义 / 未命中 + 别名兜底
        （命中 / 失效 / grade 不符）；runAnchorCycle 分批请求计数（真实
        fetchHourlyAvgPrice + fetch 桩）+ 产物形状落盘 + market.json 只读 +
        --limit 预算；dev 计算与 >15% 逐弹告警 + maxDev / devOver15 + SUMMARY
        行可解析；server.mjs anchorCycle 可注入 / null 关闭 / close 不抛
   --online 追加真实请求 2 次（开发期总预算 ≤6 次，不登录不绕风控）：
     object.list primary=gun 断言 ret=0 且 ≥60 条带 gunDetail；
     352246 propid=18010000001 断言 avg_buyprice 为正数。
   全部通过 exit 0；失败写 stderr 后 exit 1。
   用法：node server/official/selftest.mjs [--online]
   ============================================================ */
import { mkdtemp, mkdir, rm, readFile, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import {
  callFlow,
  fetchObjectList,
  fetchHourlyAvgPrice,
  setFetch,
  _resetForTest as resetAms,
  FLOW_DIR_URL,
  FLOW_DIR_REFRESH_COOLDOWN_MS,
} from './ams-client.mjs'
import {
  getDirectory,
  findByName,
  normalizeName,
  _resetForTest as resetDir,
} from './object-directory.mjs'
import {
  runAnchorCycle,
  matchAmmoNames,
  computeDeviation,
  buildSummary,
  formatSummaryLine,
  AMMO_NAME_ALIASES,
} from './ammo-anchor.mjs'
import { createSiteServer } from '../server.mjs'

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/* ---------- 桩助手：与原生 fetch 同形（ok/status/text），未匹配即抛 ---------- */

const jsonResponse = (obj, status = 200) => ({
  ok: status >= 200 && status < 300,
  status,
  text: async () => JSON.stringify(obj),
})

/** 记录型桩：handler(url, init) → 响应；返回假值按「桩未处理」抛错（fail fast） */
function stubFetch(handler) {
  const calls = []
  const fn = async (url, init = {}) => {
    calls.push({ url: String(url), method: init.method || 'GET', headers: init.headers || {}, body: init.body || '' })
    const r = await handler(String(url), init, calls)
    if (!r) throw new Error(`桩未处理请求: ${url}`)
    return r
  }
  fn.calls = calls
  return fn
}

const bodyParams = (body) => Object.fromEntries(new URLSearchParams(body))
const IDE_COMM = 'https://comm.ams.game.qq.com/ide/'
const IDE_DFM = 'https://dfm.ams.game.qq.com/ide/'

/** 上游 object.list 原始条目（字段名与 2026-10-26 真实响应一致） */
const RAW_GUN = {
  id: 2781,
  objectID: 18010000001,
  objectName: 'M4A1突击步枪',
  length: 5,
  width: 2,
  grade: 0,
  weight: 3400,
  primaryClass: 'gun',
  secondClass: 'gunRifle',
  secondClassCN: '突击步枪',
  desc: '均衡',
  pic: 'https://img.example/m4a1.png',
  prePic: 'https://img.example/m4a1-s.png',
  avgPrice: 76736,
  gunDetail: { meatHarm: 31, armorHarm: 33, fireSpeed: 700, capacity: 30, muzzleVelocity: 910, caliber: 'ammo5.56x45', ammo: [], accessory: [], allAccessory: [] },
}
const RAW_AMMO = {
  id: 9001,
  objectID: 31000000011,
  objectName: '5.56x45mm M855A1',
  grade: 4,
  primaryClass: 'ammo',
  secondClass: 'ammoRifle',
  pic: 'https://img.example/m855a1.png',
  avgPrice: 210,
  ammoDetail: { penetrationLevel: 3, harmRatio: 62 },
}
const objectListResponse = (list) =>
  jsonResponse({ ret: 0, iRet: 0, sMsg: 'succ', jData: { data: { code: 0, data: { list } } } })

/* ---------- ① callFlow：ret=0 解析 ---------- */

check('callFlow：ret=0 解析（text/html 正文 JSON）+ 表单与浏览器头形状', async () => {
  resetAms()
  const stub = stubFetch((url) => url === IDE_COMM && objectListResponse([]))
  setFetch(stub)
  const out = await callFlow({ chartId: 352143 })
  assert(out.jData.data.code === 0, `应返回解析后的响应（got ${JSON.stringify(out).slice(0, 60)}）`)
  assert(stub.calls.length === 1, '恰 1 次请求（成功不触发流目录）')
  const c = stub.calls[0]
  assert(c.method === 'POST', `应 POST（got ${c.method}）`)
  const p = bodyParams(c.body)
  assert(p.iChartId === '352143' && p.iSubChartId === '352143' && p.sIdeToken === 'YWRywA', `表单字段（got ${c.body}）`)
  assert(String(c.headers['User-Agent'] || '').startsWith('Mozilla/5.0'), '浏览器 UA')
  assert(c.headers.Origin === 'https://df.qq.com' && c.headers.Referer === 'https://df.qq.com/', 'Origin/Referer')
  assert(String(c.headers['Content-Type'] || '').includes('application/x-www-form-urlencoded'), '表单编码头')
})

/* ---------- ② ret=-11009 报错含 sMsg ---------- */

check('callFlow：ret=-11009 → 抛错含 sMsg（兜底链重试后仍如实抛）', async () => {
  resetAms()
  let dirGets = 0
  const stub = stubFetch((url) => {
    if (url === IDE_COMM) return jsonResponse({ ret: -11009, sMsg: '流程未发布' })
    if (url === FLOW_DIR_URL) {
      dirGets++
      return jsonResponse({ iRet: 0, tokens: { NewTok9: 352143 }, flows: [] })
    }
    return null
  })
  setFetch(stub)
  let err = null
  try {
    await callFlow({ chartId: 352143 })
  } catch (e) {
    err = e
  }
  assert(err, '应抛错')
  assert(err.message.includes('流程未发布'), `sMsg 应进错误信息（got ${err.message}）`)
  assert(err.ret === -11009 && err.sMsg === '流程未发布', 'err.ret / err.sMsg')
  assert(dirGets === 1, `-11009 算 token 类问题，应拉一次流目录重试（got ${dirGets}）`)
})

/* ---------- ③ token 刷新链 ---------- */

check('token 兜底链：坏 token → GET 流目录 → 新 token 重试成功', async () => {
  resetAms()
  const stub = stubFetch((url, init) => {
    if (url === FLOW_DIR_URL) {
      return jsonResponse({ iRet: 0, sIdeUrl: 'dfm.ams.game.qq.com/ide/', tokens: { NewTok9: 352143 } })
    }
    if (url === IDE_COMM) {
      const p = bodyParams(init.body)
      if (p.sIdeToken === 'NewTok9') return jsonResponse({ ret: 0, jData: { ok: 1 } })
      return jsonResponse({ ret: -1, sMsg: 'sIdeToken invalid' })
    }
    return null
  })
  setFetch(stub)
  const out = await callFlow({ chartId: 352143 })
  assert(out.jData.ok === 1, '重试后应成功')
  const posts = stub.calls.filter((c) => c.method === 'POST')
  assert(posts.length === 2, `应恰两次 POST（got ${posts.length}）`)
  assert(bodyParams(posts[1].body).sIdeToken === 'NewTok9', '重试应带目录新 token')
  assert(posts[1].url === posts[0].url && posts[0].url === IDE_COMM, '352143 域名不被流目录 sIdeUrl 覆盖（内置实测值优先）')
  assert(stub.calls.filter((c) => c.url === FLOW_DIR_URL).length === 1, '流目录只拉一次')
})

/* ---------- ③b token 兜底链的 daemon 形态：冷却窗口（防一次瞬时故障烧掉刷新机会） ---------- */

check('流目录刷新冷却窗口：冷却内不重刷、冷却过期后可再刷（daemon 常驻语义）', async () => {
  resetAms()
  let dirGets = 0
  const stub = stubFetch((url) => {
    if (url === IDE_COMM) return jsonResponse({ ret: -1, sMsg: 'sIdeToken invalid' }) // 恒失败：重试也不救
    if (url === FLOW_DIR_URL) {
      dirGets++
      return jsonResponse({ iRet: 0, tokens: { NewTok9: 352143 }, flows: [] })
    }
    return null
  })
  setFetch(stub)
  const expectThrow = async () => {
    try {
      await callFlow({ chartId: 352143 })
      return null
    } catch (e) {
      return e
    }
  }
  const err1 = await expectThrow()
  assert(err1 && dirGets === 1, `首次失败链应刷一次流目录后如实抛（gets=${dirGets}）`)
  const err2 = await expectThrow()
  assert(err2 && dirGets === 1, `冷却窗口内第二次失败不重刷流目录（gets=${dirGets}）`)
  const realNow = Date.now
  try {
    Date.now = () => realNow() + FLOW_DIR_REFRESH_COOLDOWN_MS + 60 * 1000 // 时间前进越过冷却窗口
    const err3 = await expectThrow()
    assert(err3 && dirGets === 2, `冷却过期后失败应可再刷（gets=${dirGets}）`)
  } finally {
    Date.now = realNow
  }
})

check('瞬时 5xx / 429 不触发流目录刷新（限流与服务端故障≠token 问题）', async () => {
  resetAms()
  const stub = stubFetch((url, init, calls) => {
    if (url === IDE_COMM) return jsonResponse({ note: 'gateway' }, calls.length <= 1 ? 503 : 429)
    if (url === FLOW_DIR_URL) return jsonResponse({ iRet: 0, tokens: {}, flows: [] })
    return null
  })
  setFetch(stub)
  for (const status of [503, 429]) {
    let err = null
    try {
      await callFlow({ chartId: 352143 })
    } catch (e) {
      err = e
    }
    assert(err && err.message.includes(String(status)), `HTTP ${status} 应如实抛错（got ${err && err.message}）`)
  }
  assert(stub.calls.filter((c) => c.url === FLOW_DIR_URL).length === 0, '5xx/429 不应触发流目录刷新')
})

/* ---------- ④ object.list 归一化 ---------- */

check('fetchObjectList：object.list 归一化（param 形状 / detail 透传 / 杂字段不外泄）', async () => {
  resetAms()
  let paramSeen = null
  setFetch(
    stubFetch((url, init) => {
      paramSeen = JSON.parse(bodyParams(init.body).param)
      return objectListResponse([RAW_GUN, RAW_AMMO])
    })
  )
  const items = await fetchObjectList({ primary: 'gun' })
  assert(
    paramSeen && paramSeen.primary === 'gun' && paramSeen.second === '' && paramSeen.third === '' && paramSeen.objectID === '',
    `param 形状（got ${JSON.stringify(paramSeen)}）`
  )
  const g = items[0]
  assert(g.objectID === '18010000001' && typeof g.objectID === 'string', 'objectID String 化')
  assert(g.objectName === 'M4A1突击步枪' && g.grade === 0 && g.primaryClass === 'gun' && g.secondClass === 'gunRifle', '基础字段映射')
  assert(g.avgPrice === 76736 && g.pic === RAW_GUN.pic, 'avgPrice / pic')
  assert(g.gunDetail && g.gunDetail.meatHarm === 31 && g.gunDetail.armorHarm === 33, 'gunDetail 透传')
  assert(!('id' in g) && !('prePic' in g) && !('desc' in g), '上游杂字段不外泄')
  const a = items[1]
  assert(a.ammoDetail && a.ammoDetail.penetrationLevel === 3 && !('gunDetail' in a), 'ammo 条目带 ammoDetail、无 gunDetail 键')
})

/* ---------- ⑤ 352246：实测形状解析 + 分批（附累计数组兼容口径） ---------- */

check('fetchHourlyAvgPrice：实测形状（id→{avg_buyprice} 直映射）+ 去重后 ≤5 分批 + stat_hour 键格式', async () => {
  resetAms()
  const stub = stubFetch((url, init) => {
    if (url !== IDE_DFM) return null
    const ids = bodyParams(init.body).propid.split(',')
    // 2026-10-26 真实响应形状：jData.data 直接是 id → {avg_buyprice}
    return jsonResponse({
      ret: 0,
      iRet: 0,
      jData: { data: Object.fromEntries(ids.map((id) => [id, { avg_buyprice: 76736.78 }])) },
    })
  })
  setFetch(stub)
  const ids = ['18010000001', '18010000002', '18010000003', '18010000004', '18010000005', '18010000006', '18010000006']
  const out = await fetchHourlyAvgPrice(ids, { paceMs: 0 })
  const posts = stub.calls.filter((c) => c.method === 'POST')
  assert(posts.length === 2, `7 id（去重 6）应 2 批（got ${posts.length}）`)
  const p0 = bodyParams(posts[0].body)
  assert(p0.iChartId === '352246' && p0.sIdeToken === 'Zek01X', `352246 表单（got ${JSON.stringify(p0)}）`)
  assert(p0.propid.split(',').length === 5, '首批 5 个')
  assert(bodyParams(posts[1].body).propid.split(',').length === 1, '次批 1 个')
  assert(/^\d{10}$/.test(p0.stat_hour), `stat_hour 应 YYYYMMDDHH（got ${p0.stat_hour}）`)
  assert(Object.keys(out).length === 6, `去重后 6 id 全返回（got ${Object.keys(out).length}）`)
  assert(Object.values(out).every((v) => v === 76736.78), `avg_buyprice 映射（got ${JSON.stringify(out)}）`)
})

check('fetchHourlyAvgPrice：累计数组形状取末元素（兼容口径）', async () => {
  resetAms()
  const stub = stubFetch((url, init) => {
    if (url !== IDE_DFM) return null
    const ids = bodyParams(init.body).propid.split(',')
    // 累计数组口径：末帧才是最新一小时
    const frame = (v) => Object.fromEntries(ids.map((id) => [id, { avg_buyprice: v }]))
    return jsonResponse({ ret: 0, iRet: 0, jData: { data: [frame(1), frame(2)] } })
  })
  setFetch(stub)
  const out = await fetchHourlyAvgPrice(['18010000001', '18010000002'], { paceMs: 0 })
  assert(
    Object.keys(out).length === 2 && Object.values(out).every((v) => v === 2),
    `应取累计末元素值 2（got ${JSON.stringify(out)}）`
  )
})

/* ---------- ⑥ 单批失败不炸 ---------- */

check('fetchHourlyAvgPrice：单批失败不炸整体（失败批缺席、后续批照常）', async () => {
  resetAms()
  const stub = stubFetch((url, init) => {
    if (url !== IDE_DFM) return null
    const ids = bodyParams(init.body).propid.split(',')
    if (ids.includes('B1')) return jsonResponse({ ret: -1, sMsg: 'other error' }) // 不像 token 问题，不触发流目录
    return jsonResponse({
      ret: 0,
      jData: { data: Object.fromEntries(ids.map((id) => [id, { avg_buyprice: 9 }])) },
    })
  })
  setFetch(stub)
  const out = await fetchHourlyAvgPrice(['B1', 'B2', 'B3'], { batchSize: 2, paceMs: 0 })
  // 批次 [B1,B2] / [B3]：失败批内的 B1、B2 都缺席（按批失败，不按 id）
  assert(out.B3 === 9, `后续批照常返回（got ${JSON.stringify(out)}）`)
  assert(!('B1' in out) && !('B2' in out), '失败批 id 缺席')
  assert(stub.calls.filter((c) => c.url === FLOW_DIR_URL).length === 0, '非 token 类失败不拉流目录')
})

/* ---------- ⑦ normalizeName ---------- */

check('normalizeName：星号 / 零宽 / 全角 / 空白折叠变体', () => {
  assert(normalizeName('7.62*39mm AP SUB') === '7.62x39mm ap sub', `* → x（got ${normalizeName('7.62*39mm AP SUB')}）`)
  assert(normalizeName('M4A1\u200B突击步枪') === 'm4a1突击步枪', '去 U+200B')
  assert(normalizeName('Ｍ４Ａ１　步枪') === 'm4a1 步枪', `全角转半角含全角空格（got ${normalizeName('Ｍ４Ａ１　步枪')}）`)
  assert(normalizeName('  9mm   AP ') === '9mm ap', '多空格折叠 + trim')
  assert(normalizeName('') === '' && normalizeName(null) === '', '空值安全')
})

/* ---------- ⑧ 目录持久化 + findByName ---------- */

check('目录持久化：TTL 内二次加载零请求 + findByName 精确 / 归一化 / ambiguous', async () => {
  resetAms()
  resetDir()
  const tmp = await mkdtemp(path.join(tmpdir(), 'official-dir-'))
  try {
    const byPrimary = {
      gun: [
        RAW_GUN,
        { ...RAW_GUN, id: 2, objectID: 18010000099, objectName: '7.62*39mm AP' },
        { ...RAW_GUN, id: 3, objectID: 18010000098, objectName: '7.62x39mm ap' },
      ],
      ammo: [RAW_AMMO],
      protect: [
        {
          id: 5,
          objectID: 55000000001,
          objectName: '重型突击背心',
          grade: 5,
          primaryClass: 'protect',
          secondClass: 'protectBody',
          avgPrice: 48000,
          pic: 'https://img.example/vest.png',
          protectDetail: { durability: 68, protectLevel: 5 },
        },
      ],
    }
    const stub = stubFetch((url, init) => {
      if (url !== IDE_COMM) return null
      const p = bodyParams(init.body)
      const param = JSON.parse(p.param)
      return objectListResponse(byPrimary[param.primary] || [])
    })
    setFetch(stub)
    const d1 = await getDirectory({ rootDir: tmp })
    assert(d1.items.length === 5, `三类并集 5 条（gun 3 + ammo 1 + protect 1，got ${d1.items.length}）`)
    assert(d1.primaries.join() === 'gun,ammo,protect', 'primaries 视图')
    assert(stub.calls.filter((c) => c.method === 'POST').length === 3, '三类各 1 次请求')
    assert(existsSync(path.join(tmp, 'data', 'official', 'object-directory.json')), '缓存文件已落盘 data/official/')

    // 清进程缓存 + 换 fail-fast 桩：TTL 内必须从磁盘加载、零请求
    resetDir()
    setFetch(stubFetch(() => null))
    const d2 = await getDirectory({ rootDir: tmp })
    assert(d2.items.length === d1.items.length, `磁盘加载条目一致（got ${d2.items.length}）`)

    const hit = await findByName('M4A1突击步枪', { rootDir: tmp })
    assert(hit && hit.objectID === '18010000001', '精确命中')
    const amb = await findByName('7.62X39MM AP', { rootDir: tmp }) // 精确不中（大小写）→ 归一化命中两条
    assert(
      amb && amb.ambiguous === true && amb.matches.length === 2,
      `星号变体一对多（got ${JSON.stringify(amb && amb.matches && amb.matches.map((m) => m.objectName))}）`
    )
    assert((await findByName('不存在的物品', { rootDir: tmp })) === null, '无命中返回 null')
  } finally {
    await rm(tmp, { recursive: true, force: true })
  }
})

/* ---------- ⑨ TTL 过期重抓 ---------- */

check('目录 TTL 过期 → 磁盘文件不再直接用，重新抓取', async () => {
  resetAms()
  resetDir()
  const tmp = await mkdtemp(path.join(tmpdir(), 'official-ttl-'))
  try {
    let hits = 0
    const onePerPrimary = () =>
      stubFetch((url, init) => {
        if (url !== IDE_COMM) return null
        hits++
        const param = JSON.parse(bodyParams(init.body).param)
        return objectListResponse([{ objectID: 1, objectName: `item-${param.primary}`, primaryClass: param.primary }])
      })
    setFetch(onePerPrimary())
    await getDirectory({ rootDir: tmp })
    assert(hits === 3, `首轮 3 请求（got ${hits}）`)

    // 把磁盘缓存拨回 25h 前，清进程缓存：过期 → 重抓
    const fp = path.join(tmp, 'data', 'official', 'object-directory.json')
    const raw = JSON.parse(await readFile(fp, 'utf8'))
    raw.fetchedAtMs = Date.now() - 25 * 3600 * 1000
    await writeFile(fp, JSON.stringify(raw))
    resetDir()
    hits = 0
    setFetch(onePerPrimary())
    const d = await getDirectory({ rootDir: tmp })
    assert(hits === 3, `过期后应重抓 3 次（got ${hits}）`)
    assert(d.items.length === 3, `重抓后条目齐全（got ${d.items.length}）`)
  } finally {
    await rm(tmp, { recursive: true, force: true })
  }
})

/* ---------- ⑩ 官方均价锚 ammo-anchor ---------- */

/** 往临时仓库根写一份最小 market.json（只含锚用到的 name / current / grade） */
async function writeTmpMarket(root, items) {
  const dir = path.join(root, 'apps', 'web', 'public', 'ammo')
  await mkdir(dir, { recursive: true })
  const text = JSON.stringify({ version: '202610261400', items })
  await writeFile(path.join(dir, 'market.json'), text)
  return text
}

check('matchAmmoNames：精确 / 归一化 / 歧义（精确同名 + 归一化撞名）/ 未命中 + 别名兜底（命中 / 失效 / grade 不符）', () => {
  const dir = [
    { objectID: '1', objectName: '5.56x45mm M855A1', grade: 4 },
    { objectID: '2', objectName: '7.62*39mm AP SUB', grade: 5 }, // 归一化：* → x、小写
    { objectID: '3', objectName: '.300BLK', grade: 3 },
    { objectID: '4', objectName: '.300BLK', grade: 4 }, // 与 3 精确同名 → 歧义（不用 grade 自动裁决）
    { objectID: '5', objectName: 'A*B', grade: 2 },
    { objectID: '6', objectName: 'AXB', grade: 2 }, // 与 5 归一化撞名 → 歧义
  ]
  const market = [
    { name: '5.56x45mm M855A1', current: 1551, grade: 4 }, // 精确
    { name: '7.62X39MM AP SUB', current: 5000, grade: 5 }, // 归一化
    { name: '.300BLK', current: 400, grade: 3 }, // 精确 2 条 → 歧义
    { name: 'axb', current: 1, grade: 2 }, // 归一化 2 条 → 歧义
    { name: '不存在的弹', current: 9, grade: 1 }, // 未命中
    { name: '蓝.300BLK', current: 407, grade: 3 }, // 别名 → 3，grade 一致
    { name: '紫.300BLK', current: 1687, grade: 4 }, // 别名 → 4
    { name: '金.300BLK', current: 5343, grade: 5 }, // 别名指向目录没有的 id → 失效 → 未命中
    { name: 'X', current: 1, grade: 9 }, // 别名 → 1 但 grade 9 ≠ 4 → 未命中
  ]
  const aliases = { '蓝.300BLK': '3', '紫.300BLK': '4', '金.300BLK': '37280500001', X: '1' }
  const r = matchAmmoNames(market, dir, { aliases })
  const by = Object.fromEntries(r.matched.map((m) => [m.name, m]))
  assert(r.matched.length === 4, `应 4 条命中（got ${r.matched.map((m) => m.name)}）`)
  assert(by['5.56x45mm M855A1'].via === 'exact' && by['5.56x45mm M855A1'].objectID === '1' && by['5.56x45mm M855A1'].moli === 1551, '精确命中带 moli')
  assert(by['7.62X39MM AP SUB'].via === 'normalized' && by['7.62X39MM AP SUB'].officialName === '7.62*39mm AP SUB', '归一化命中保留官方原名')
  assert(by['蓝.300BLK'].via === 'alias' && by['蓝.300BLK'].objectID === '3' && by['紫.300BLK'].objectID === '4', '别名命中 via=alias')
  assert(r.ambiguous.length === 2, `应 2 条歧义（got ${JSON.stringify(r.ambiguous.map((a) => a.name))}）`)
  const amb300 = r.ambiguous.find((a) => a.name === '.300BLK')
  assert(
    amb300 && amb300.candidates.length === 2 && amb300.candidates.every((c) => c.objectID && c.officialName === '.300BLK' && typeof c.grade === 'number'),
    `歧义候选带 objectID / officialName / grade（got ${JSON.stringify(amb300)}）`
  )
  assert(r.ambiguous.find((a) => a.name === 'axb').candidates.map((c) => c.objectID).join() === '5,6', '归一化撞名候选')
  assert(r.missed.join() === '不存在的弹,金.300BLK,X', `未命中集合（got ${r.missed}）`)
  // 内置别名表只登记 .300BLK 三档（grade 3/4/5 对应 蓝/紫/金）
  assert(
    Object.keys(AMMO_NAME_ALIASES).sort().join() === '紫.300BLK,蓝.300BLK,金.300BLK',
    `内置别名表（got ${Object.keys(AMMO_NAME_ALIASES)}）`
  )
  // 空输入安全
  const empty = matchAmmoNames([], [], { aliases: {} })
  assert(empty.matched.length === 0 && empty.missed.length === 0 && empty.ambiguous.length === 0, '空输入')
})

check('runAnchorCycle：分批请求计数（真实 fetchHourlyAvgPrice + fetch 桩）+ 产物形状落盘 + market.json 只读 + --limit 预算', async () => {
  resetAms()
  const tmp = await mkdtemp(path.join(tmpdir(), 'official-anchor-'))
  try {
    // 7 弹全部精确命中 → 7 id → 5 + 2 两批
    const names = ['弹1', '弹2', '弹3', '弹4', '弹5', '弹6', '弹7']
    const dir = names.map((n, i) => ({ objectID: String(100 + i), objectName: n, grade: 3 }))
    const marketText = await writeTmpMarket(tmp, names.map((n, i) => ({ name: n, current: 100 + i, grade: 3 })))
    const stub = stubFetch((url, init) => {
      if (url !== IDE_DFM) return null
      const ids = bodyParams(init.body).propid.split(',')
      return jsonResponse({ ret: 0, jData: { data: Object.fromEntries(ids.map((id) => [id, { avg_buyprice: 100 }])) } })
    })
    setFetch(stub)
    const dfmPosts = () => stub.calls.filter((c) => c.method === 'POST' && c.url === IDE_DFM)
    const r = await runAnchorCycle({ rootDir: tmp, paceMs: 0, loadDirectory: async () => ({ items: dir }), warn: () => {} })
    assert(dfmPosts().length === 2, `7 id 应 2 批（got ${dfmPosts().length}）`)
    assert(r.requests === 2 && r.summary.requests === 2, `requests 计数 = 实际批次（got ${r.requests}）`)
    assert(bodyParams(dfmPosts()[0].body).propid.split(',').length === 5, '首批 5 个')
    assert(stub.calls.filter((c) => c.url === FLOW_DIR_URL).length === 0, '成功路径不拉流目录')

    // 产物形状
    const fp = path.join(tmp, 'data', 'ammo', 'official-anchor.json')
    assert(existsSync(fp) && r.outPath === fp, '落盘 data/ammo/official-anchor.json')
    const saved = JSON.parse(await readFile(fp, 'utf8'))
    assert(
      Object.keys(saved).sort().join() === 'ambiguous,fetchedAt,items,joined,missed,total',
      `顶层键（got ${Object.keys(saved).sort()}）`
    )
    assert(JSON.stringify(saved) === JSON.stringify(r.anchor), '返回的 anchor 即落盘内容')
    assert(saved.total === 7 && saved.joined === 7 && saved.missed.length === 0 && saved.ambiguous.length === 0, '计数')
    assert(!Number.isNaN(Date.parse(saved.fetchedAt)), 'fetchedAt 为 ISO 时间')
    const it = saved.items[0]
    assert(
      Object.keys(it).sort().join() === 'dev,moli,name,objectID,official,officialName,via',
      `条目键（got ${Object.keys(it).sort()}）`
    )
    assert(
      it.name === '弹1' && it.objectID === '100' && it.officialName === '弹1' && it.via === 'exact' && it.moli === 100 && it.official === 100 && it.dev === 0,
      `条目值（got ${JSON.stringify(it)}）`
    )
    assert(saved.items[6].dev === 0.06, `dev 四位小数（got ${saved.items[6].dev}）`)
    // 只读：market.json 字节不变
    assert((await readFile(path.join(tmp, 'apps', 'web', 'public', 'ammo', 'market.json'), 'utf8')) === marketText, 'market.json 只读未改')

    // --limit 5：只送前 5 个 id → 1 批；其余 2 条 official/dev = null 但仍计入 joined
    const before = dfmPosts().length
    const r2 = await runAnchorCycle({ rootDir: tmp, paceMs: 0, limit: 5, loadDirectory: async () => ({ items: dir }), warn: () => {} })
    assert(dfmPosts().length - before === 1 && r2.requests === 1, `limit 5 应 1 批（got ${dfmPosts().length - before}）`)
    const nulls = r2.anchor.items.filter((i) => i.official === null && i.dev === null)
    assert(r2.anchor.joined === 7 && nulls.length === 2, `limit 外 official=null（got ${nulls.length}）`)
    // limit 0：不请求
    const before0 = dfmPosts().length
    const r0 = await runAnchorCycle({ rootDir: tmp, paceMs: 0, limit: 0, loadDirectory: async () => ({ items: dir }), warn: () => {} })
    assert(dfmPosts().length === before0 && r0.requests === 0 && r0.summary.maxDev.dev === null, 'limit 0 零请求、maxDev null')
  } finally {
    resetAms()
    await rm(tmp, { recursive: true, force: true })
  }
})

check('runAnchorCycle：dev=(moli−official)/official、|dev|>15% 逐弹告警、maxDev / devOver15 + SUMMARY 行可解析', async () => {
  const tmp = await mkdtemp(path.join(tmpdir(), 'official-anchor-dev-'))
  try {
    await writeTmpMarket(tmp, [
      { name: 'A', current: 125, grade: 3 }, // 官方 100 → +25% → 告警
      { name: 'B', current: 100, grade: 3 }, // → 0
      { name: 'C', current: 90, grade: 3 }, // → −10% 不告警
      { name: 'D', current: 50, grade: 3 }, // 官方 0 → dev null（不除零）
      { name: 'E', current: 50, grade: 3 }, // 官方未返回 → official null
      { name: 'Z', current: 1, grade: 1 }, // 目录无 → missed，不进请求
    ])
    const dir = ['A', 'B', 'C', 'D', 'E'].map((n, i) => ({ objectID: String(i + 1), objectName: n, grade: 3 }))
    const warned = []
    let idsSeen = null
    const r = await runAnchorCycle({
      rootDir: tmp,
      paceMs: 0,
      loadDirectory: async () => ({ items: dir }),
      fetchPrices: async (ids, opts) => {
        idsSeen = ids
        assert(opts.batchSize === 5 && opts.paceMs === 0, `batchSize 5 / paceMs 透传（got ${JSON.stringify(opts)}）`)
        return { 1: 100, 2: 100, 3: 100, 4: 0 }
      },
      warn: (m) => warned.push(m),
    })
    assert(idsSeen.join() === '1,2,3,4,5', `只请求已映射 id（got ${idsSeen}）`)
    const by = Object.fromEntries(r.anchor.items.map((i) => [i.name, i]))
    assert(by.A.dev === 0.25 && by.B.dev === 0 && by.C.dev === -0.1, `dev 值（got ${JSON.stringify([by.A.dev, by.B.dev, by.C.dev])}）`)
    assert(by.D.official === 0 && by.D.dev === null, 'official 0 → dev null')
    assert(by.E.official === null && by.E.dev === null, '未返回 → official/dev null')
    assert(warned.length === 1 && warned[0].includes('A') && warned[0].includes('25.0%'), `告警恰 1 条且带弹名与百分比（got ${JSON.stringify(warned)}）`)
    assert(r.anchor.missed.join() === 'Z' && r.anchor.joined === 5 && r.anchor.total === 6, '计数')
    const s = r.summary
    assert(s.devOver15 === 1 && s.maxDev.name === 'A' && s.maxDev.dev === 0.25, `summary（got ${JSON.stringify(s)}）`)
    assert(s.total === 6 && s.joined === 5 && s.missed === 1 && s.ambiguous === 0 && s.requests === 1, JSON.stringify(s))

    // SUMMARY 行：固定前缀 + 单行 + 合法 JSON + 键序固定 + 解析回等值
    const line = formatSummaryLine(s)
    assert(line.startsWith('SUMMARY {') && !line.includes('\n'), `单行（got ${line}）`)
    const parsed = JSON.parse(line.slice('SUMMARY '.length))
    assert(Object.keys(parsed).join() === 'total,joined,missed,ambiguous,devOver15,maxDev,requests', `键序（got ${Object.keys(parsed)}）`)
    assert(parsed.maxDev.name === 'A' && parsed.maxDev.dev === 0.25 && parsed.requests === 1, '解析回等值')

    // computeDeviation 边界：恰 15% 不算超、缺失 / 非正官方价 → null
    assert(computeDeviation(115, 100) === 0.15 && computeDeviation(100, null) === null, '15% 边界 / null')
    assert(computeDeviation(NaN, 100) === null && computeDeviation(100, -5) === null && computeDeviation(100, 0) === null, 'NaN / 负 / 零')
    assert(buildSummary({ total: 1, joined: 1, missed: [], ambiguous: [], items: [{ name: 'q', dev: 0.15 }] }, 1).devOver15 === 0, '恰 15% 不计入 devOver15')
  } finally {
    await rm(tmp, { recursive: true, force: true })
  }
})

check('server.mjs：anchorCycle 可注入（triggerAnchorCycle 直调带 rootDir/webDir）/ null 关闭 / close 清定时器不抛', async () => {
  const tmp = await mkdtemp(path.join(tmpdir(), 'official-site-'))
  try {
    const seen = []
    const summary = { total: 1, joined: 1, missed: 0, ambiguous: 0, devOver15: 0, maxDev: { name: null, dev: null }, requests: 1 }
    const site = createSiteServer({
      rootDir: tmp,
      noNotify: true,
      radarCycle: async () => ({ version: 'v', stats: {} }),
      craftCycle: async () => ({ version: 'v', stats: {} }),
      anchorCycle: async (opts) => {
        seen.push(opts)
        return { summary }
      },
      anchorDelayMs: 0,
    })
    try {
      const out = await site.triggerAnchorCycle()
      assert(seen.length === 1 && seen[0].rootDir === tmp && seen[0].webDir === tmp, `anchorCycle 收到 {rootDir, webDir}（got ${JSON.stringify(seen[0])}）`)
      assert(out && out.summary === summary, '返回透传')
      // 注入桩抛错：只记日志返回 null，不向外抛
      const bad = createSiteServer({
        rootDir: tmp,
        noNotify: true,
        radarCycle: async () => null,
        craftCycle: async () => null,
        anchorCycle: async () => {
          throw new Error('boom')
        },
      })
      try {
        assert((await bad.triggerAnchorCycle()) === null, '失败应返回 null 不抛')
      } finally {
        await bad.close()
      }
    } finally {
      await site.close()
    }
    const off = createSiteServer({ rootDir: tmp, noNotify: true, radarCycle: async () => null, craftCycle: async () => null, anchorCycle: null })
    try {
      assert((await off.triggerAnchorCycle()) === null, 'anchorCycle=null → 关闭，trigger 返回 null')
    } finally {
      await off.close()
    }
  } finally {
    await rm(tmp, { recursive: true, force: true })
  }
})

/* ---------- --online：真实请求（每次共 2 次，总预算见文件头） ---------- */

if (process.argv.includes('--online')) {
  check('online：object.list primary=gun 真实请求 ret=0 且 ≥60 条带 gunDetail', async () => {
    resetAms() // 清掉离线场景注入的桩
    const items = await fetchObjectList({ primary: 'gun' })
    assert(items.length >= 60, `gun 条目 ≥60（got ${items.length}）`)
    assert(items.filter((i) => i.gunDetail).length >= 60, `带 gunDetail ≥60（got ${items.filter((i) => i.gunDetail).length}）`)
  })
  check('online：352246 真实请求 propid=18010000001 → avg_buyprice 正数', async () => {
    resetAms()
    const out = await fetchHourlyAvgPrice(['18010000001'], { paceMs: 0 })
    const v = out['18010000001']
    assert(v !== undefined, `应返回均价（got ${JSON.stringify(out)}）`)
    assert(v > 0, `均价应为正数（got ${v}）`)
  })
}

/* ---------- 跑测 ---------- */
let failed = 0
for (const [name, fn] of checks) {
  try {
    await fn()
    console.log(`✓ ${name}`)
  } catch (e) {
    failed++
    console.error(`✗ ${name}\n  ${e.message}`)
  }
}
if (failed) {
  console.error(`\n${failed}/${checks.length} 项失败`)
  process.exit(1)
}
const mode = process.argv.includes('--online') ? '含 2 项 online 真实请求' : '离线模式，未打外网'
console.log(`\n全部 ${checks.length} 项通过（${mode}）`)
