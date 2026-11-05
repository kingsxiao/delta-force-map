/* ============================================================
   selftest.mjs — 每日密码快照纯逻辑离线自测（node 直接运行，零外网）
   ------------------------------------------------------------
   覆盖（secrets.mjs 的可测面，网络全走注入桩）：
     ① parseOfficialSecrets：正常载荷 / ret 非零 / list 空 / 条目缺密码过滤
     ② parseMoligodSecrets：形状转换 + fetch_date 提取 / status 非 ok throw
     ③ buildSecretsSnapshot：北京墙钟 version/date、mapId 升序、图片路径
        1..6 映射与越界 null、stats
     ④ runSecretsCycle（注入桩 + 临时 webDir）：首轮落盘 public、二轮同内容
        不写盘（changed:false）、密码变化重写、主源失败回落 moligod 且
        source 如实切换、主源与兜底全挂 → throw、官方源部分图（维护期
        2/6 < KNOWN_MAP_COUNT）保留盘上旧档不覆盖不广播、部分图且无旧档
        如实落盘
   全部通过 exit 0；失败写 stderr 后 exit 1。
   用法：node server/secrets/selftest.mjs
   ============================================================ */
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import path from 'node:path'
import {
  parseOfficialSecrets,
  parseMoligodSecrets,
  buildSecretsSnapshot,
  runSecretsCycle,
  beijingDate,
  secretImagePath,
} from './secrets.mjs'

function assert(cond, msg) {
  if (!cond) throw new Error(msg)
}
const checks = []
const check = (name, fn) => checks.push([name, fn])

/* ---------- 上游形状 ---------- */

/** 六图齐全的官方 list（图名对齐 API.md §1.4；selftest 桩须齐全——
 *  runSecretsCycle 对 < KNOWN_MAP_COUNT 的载荷按维护期部分图保留旧档） */
const FULL_LIST = [
  { mapID: 1, mapName: '零号大坝', secret: '5437' },
  { mapID: 2, mapName: '长弓溪谷', secret: '5946' },
  { mapID: 3, mapName: '巴克什', secret: '1122' },
  { mapID: 4, mapName: '航天基地', secret: '3344' },
  { mapID: 5, mapName: '潮汐监狱', secret: '5566' },
  { mapID: 6, mapName: 'AZ3', secret: '7788' },
]

/** 官方 AMS 载荷（2026-11-05 实测形状） */
const OFFICIAL_OK = {
  ret: 0,
  iRet: 0,
  sMsg: 'succ',
  jData: {
    data: {
      code: 0,
      msg: 'ok',
      data: {
        list: FULL_LIST,
      },
    },
  },
}

/** moligod 兜底载荷（同日实测形状） */
const MOLI_OK = {
  status: 'ok',
  data: FULL_LIST.map((e) => ({
    map_id: e.mapID,
    map_name: e.mapName,
    secret: e.secret,
    fetch_date: '2026-11-05',
  })),
  updated_at: '2026-11-04T16:00:12.802824+00:00',
}

/* ---------- ①② 上游解析 ---------- */

check('parseOfficialSecrets：正常载荷 → 统一条目', () => {
  const items = parseOfficialSecrets(OFFICIAL_OK)
  assert(items.length === FULL_LIST.length, '条目数')
  assert(items[0].mapId === 1 && items[0].mapName === '零号大坝' && items[0].secret === '5437', '条目字段')
})

check('parseOfficialSecrets：ret 非零 / list 空 / 缺 jData → throw', () => {
  for (const [raw, why] of [
    [{ ...OFFICIAL_OK, ret: 1 }, 'ret 非零'],
    [{ ...OFFICIAL_OK, jData: { data: { code: 0, data: { list: [] } } } }, 'list 空'],
    [{ ret: 0, iRet: 0 }, '缺 jData'],
    [null, 'null 载荷'],
  ]) {
    let threw = false
    try {
      parseOfficialSecrets(raw)
    } catch {
      threw = true
    }
    assert(threw, `${why}应 throw`)
  }
})

check('parseOfficialSecrets：缺密码 / 缺名条目被过滤，全无效 throw', () => {
  const filtered = parseOfficialSecrets({
    ...OFFICIAL_OK,
    jData: { data: { code: 0, data: { list: [
      { mapID: 1, mapName: '零号大坝', secret: '5437' },
      { mapID: 2, mapName: '长弓溪谷', secret: '' },
      { mapID: 3, mapName: '', secret: '1111' },
    ] } } },
  })
  assert(filtered.length === 1 && filtered[0].mapName === '零号大坝', '无效条目应被过滤')
  let threw = false
  try {
    parseOfficialSecrets({ ...OFFICIAL_OK, jData: { data: { code: 0, data: { list: [{ mapID: 9, secret: '' }] } } } })
  } catch {
    threw = true
  }
  assert(threw, '全部无效应 throw')
})

check('parseMoligodSecrets：形状转换 + fetch_date 提取', () => {
  const items = parseMoligodSecrets(MOLI_OK)
  assert(items.length === FULL_LIST.length, '条目数')
  assert(items[0].mapId === 1 && items[0].mapName === '零号大坝' && items[0].secret === '5437', '条目字段')
  assert(items[0].upstreamDate === '2026-11-05', 'fetch_date 提取')
})

check('parseMoligodSecrets：status 非 ok / data 空 → throw', () => {
  for (const [raw, why] of [
    [{ status: 'error', data: [] }, 'status 非 ok'],
    [{ status: 'ok', data: [] }, 'data 空'],
    [null, 'null 载荷'],
  ]) {
    let threw = false
    try {
      parseMoligodSecrets(raw)
    } catch {
      threw = true
    }
    assert(threw, `${why}应 throw`)
  }
})

/* ---------- ③ 整形 ---------- */

check('buildSecretsSnapshot：北京墙钟 version/date + mapId 升序 + 图片路径映射', () => {
  const snap = buildSecretsSnapshot(
    [
      { mapId: 2, mapName: '长弓溪谷', secret: '5946' },
      { mapId: 1, mapName: '零号大坝', secret: '5437' },
      { mapId: 7, mapName: '未知新图', secret: '0000' },
    ],
    { fetchedAt: '2026-11-04T16:30:00.000Z', source: 'official-ams' }, // 北京 11-05 00:30
  )
  assert(snap.version === '20261105' && snap.date === '2026-11-05', `version/date=${snap.version}/${snap.date}（UTC+8 应为 11-05）`)
  assert(snap.items.map((i) => i.mapId).join() === '1,2,7', 'mapId 升序')
  assert(snap.items[0].img === 'secrets/img/password1.jpg', '图 1 路径')
  assert(snap.items[2].img === null, '越界 mapId 无图')
  assert(snap.source === 'official-ams' && snap.stats.total === 3, 'source/stats')
})

check('beijingDate / secretImagePath：边界（跨日 ±8h、mapId 0 与 6）', () => {
  assert(beijingDate('2026-11-04T15:59:59.000Z') === '2026-11-04', 'UTC 15:59 仍是北京 11-04')
  assert(beijingDate('2026-11-04T16:00:00.000Z') === '2026-11-05', 'UTC 16:00 即北京 11-05')
  assert(secretImagePath(0) === null && secretImagePath(6) === 'secrets/img/password6.jpg', '0 无图 / 6 有图')
})

/* ---------- ④ 循环（注入桩 + 临时 webDir） ---------- */

async function tempWebDir() {
  const root = await mkdtemp(path.join(tmpdir(), 'df-secrets-selftest-'))
  // writeSnapshotPair 只在 dist/<dir> 已存在时才联动双写；建一个空 dist 模拟部署形态
  await (await import('node:fs/promises')).mkdir(path.join(root, 'dist', 'secrets'), { recursive: true })
  return root
}

/** 注入桩 fetch：语义对齐 getJson（直接返回解析后 JSON），按 URL 分发到给定载荷 / 抛错 */
function stubFetch(official, moli) {
  return async (url) => {
    if (url.includes('ams.game.qq.com')) {
      if (official instanceof Error) throw official
      return official
    }
    if (url.includes('moligod.com')) {
      if (moli instanceof Error) throw moli
      return moli
    }
    throw new Error('stubFetch：未知 URL ' + url)
  }
}

/** 次日官方载荷（模拟 0 点轮换后的新密码） */
const OFFICIAL_NEXT_DAY = {
  ...OFFICIAL_OK,
  jData: {
    data: {
      code: 0,
      msg: 'ok',
      data: {
        list: FULL_LIST.map((e, i) => ({ ...e, secret: String(8000 + i * 111) })),
      },
    },
  },
}

const NEW_DAY_MOLI = {
  status: 'ok',
  data: OFFICIAL_NEXT_DAY.jData.data.data.list.map((e) => ({
    map_id: e.mapID,
    map_name: e.mapName,
    secret: e.secret,
    fetch_date: '2026-11-06',
  })),
}

/** 官方源维护期部分图载荷（实测 2/6）：条目本身合法、只是不全，且密码与
 *  完好旧档不同——若门槛失效被整包覆盖，盘上内容立刻可见变化 */
const OFFICIAL_PARTIAL = {
  ...OFFICIAL_OK,
  jData: {
    data: {
      code: 0,
      msg: 'ok',
      data: {
        list: [
          { mapID: 1, mapName: '零号大坝', secret: '0000' },
          { mapID: 2, mapName: '长弓溪谷', secret: '0000' },
        ],
      },
    },
  },
}

check('runSecretsCycle：首轮落盘 public + dist 双写', async () => {
  const dir = await tempWebDir()
  try {
    const r = await runSecretsCycle({
      webDir: dir,
      fetchImpl: stubFetch(OFFICIAL_OK, MOLI_OK),
      now: '2026-11-05T10:00:00.000Z',
    })
    assert(r.changed === true && r.source === 'official-ams' && r.total === 6, JSON.stringify(r))
    assert(r.version === '20261105', `version=${r.version}`)
    const pub = JSON.parse(await readFile(path.join(dir, 'public', 'secrets', 'secrets.json'), 'utf8'))
    assert(pub.source === 'official-ams' && pub.items[0].secret === '5437', 'public 落盘内容')
    const dist = JSON.parse(await readFile(path.join(dir, 'dist', 'secrets', 'secrets.json'), 'utf8'))
    assert(dist.version === pub.version, 'dist 联动')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

check('runSecretsCycle：同内容二轮不写盘（changed:false）', async () => {
  const dir = await tempWebDir()
  try {
    const opts = { fetchImpl: stubFetch(OFFICIAL_OK, MOLI_OK), now: '2026-11-05T10:00:00.000Z' }
    await runSecretsCycle({ webDir: dir, ...opts })
    const pubPath = path.join(dir, 'public', 'secrets', 'secrets.json')
    const before = await readFile(pubPath, 'utf8')
    const r = await runSecretsCycle({ webDir: dir, ...opts })
    assert(r.changed === false, '同内容应跳过写盘')
    const after = await readFile(pubPath, 'utf8')
    assert(before === after, '文件不应被重写')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

check('runSecretsCycle：次日密码变化 → 重写并 changed:true', async () => {
  const dir = await tempWebDir()
  try {
    await runSecretsCycle({
      webDir: dir,
      fetchImpl: stubFetch(OFFICIAL_OK, MOLI_OK),
      now: '2026-11-05T10:00:00.000Z',
    })
    const r = await runSecretsCycle({
      webDir: dir,
      fetchImpl: stubFetch(OFFICIAL_NEXT_DAY, NEW_DAY_MOLI),
      now: '2026-11-06T10:00:00.000Z',
    })
    assert(r.changed === true && r.total === 6, JSON.stringify(r))
    const pub = JSON.parse(await readFile(path.join(dir, 'public', 'secrets', 'secrets.json'), 'utf8'))
    assert(pub.items[0].secret === '8000' && pub.version === '20261106', '新密码应落盘')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

check('runSecretsCycle：主源失败 → 回落 moligod，source 如实切换', async () => {
  const dir = await tempWebDir()
  try {
    const r = await runSecretsCycle({
      webDir: dir,
      fetchImpl: stubFetch(new Error('AMS 502'), MOLI_OK),
      now: '2026-11-05T10:00:00.000Z',
    })
    assert(r.source === 'moligod-mirror' && r.changed === true, JSON.stringify(r))
    const pub = JSON.parse(await readFile(path.join(dir, 'public', 'secrets', 'secrets.json'), 'utf8'))
    assert(pub.source === 'moligod-mirror', '快照 source 应如实标注')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

check('runSecretsCycle：主源与兜底全挂 → throw（循环侧接日志）', async () => {
  let threw = false
  try {
    await runSecretsCycle({
      webDir: await tempWebDir(),
      fetchImpl: stubFetch(new Error('AMS down'), new Error('moli down')),
    })
  } catch {
    threw = true
  }
  assert(threw, '双源全挂应上抛')
})

check('runSecretsCycle：官方源部分图（维护期 2/6）→ 保留盘上旧档不覆盖不广播', async () => {
  const dir = await tempWebDir()
  try {
    await runSecretsCycle({
      webDir: dir,
      fetchImpl: stubFetch(OFFICIAL_OK, MOLI_OK),
      now: '2026-11-05T10:00:00.000Z',
    })
    const pubPath = path.join(dir, 'public', 'secrets', 'secrets.json')
    const before = await readFile(pubPath, 'utf8')
    const r = await runSecretsCycle({
      webDir: dir,
      fetchImpl: stubFetch(OFFICIAL_PARTIAL, MOLI_OK),
      now: '2026-11-05T11:00:00.000Z',
    })
    assert(r.changed === false && r.keptOld === true, `部分图应保留旧档，实际 ${JSON.stringify(r)}`)
    assert(r.version === '20261105' && r.total === 6, `返回旧档元信息 version/total=${r.version}/${r.total}`)
    const after = await readFile(pubPath, 'utf8')
    assert(before === after, '盘上旧档不应被部分快照整包覆盖')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

check('runSecretsCycle：部分图且盘上无旧档 → 如实落盘（无旧档可保）', async () => {
  const dir = await tempWebDir()
  try {
    const r = await runSecretsCycle({
      webDir: dir,
      fetchImpl: stubFetch(OFFICIAL_PARTIAL, MOLI_OK),
      now: '2026-11-05T10:00:00.000Z',
    })
    assert(r.changed === true && r.total === 2 && r.keptOld === undefined, `无旧档应如实落盘，实际 ${JSON.stringify(r)}`)
    const pub = JSON.parse(await readFile(path.join(dir, 'public', 'secrets', 'secrets.json'), 'utf8'))
    assert(pub.items.length === 2 && pub.stats.total === 2, '部分快照如实落盘计数')
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

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
console.log(`\n全部 ${checks.length} 项通过（离线模式，网络走注入桩）`)
