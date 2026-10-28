/* ============================================================
   kkrb-client.mjs — 三角洲一图流（kkrb.net）交易行子弹数据客户端
   ------------------------------------------------------------
   数据源：KK三角洲一图流 https://www.kkrb.net （B站 Key725 / KK日报）
   页面  ?viewpage=view/market/ammo_price_pl（子弹盈亏数据一览）
   接口  POST https://www.kkrb.net/getAmmoPLData
   鉴权为三步会话引导（纯 Node fetch，零 npm 依赖）：
     1. GET  /             → Set-Cookie: PHPSESSID
     2. POST /getMenu      → Set-Cookie: csrf_token（服务端签发、绑定会话，
        自造值无效；不带上会被业务层以 code -101 / 229 拒绝）
     3. POST /getAmmoPLData（携带两个 cookie）→ 子弹快照
   上游约每小时更新一次（响应 version 形如 2026101310 = 10 月 13 日 10 时）。
   返回 88 种子弹：当前价 / 昨日·本周·上周高低点（含税后）/ priceCurve
   （每小时一个点、近 7 天约 168 点）。名称为游戏内名称。
   另导出 kkrbRequest：同一套会话引导调任意业务接口（fetchAmmoMarket 与
   子弹以外的品类共用，如全物品涨幅榜 getHIPriceCurveData——server/market/radar.mjs）。
   ============================================================ */

const BASE = 'https://www.kkrb.net'
const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'

/** 从响应 Set-Cookie 头解析出 "k=v" 映射（Node ≥ 20 的 getSetCookie） */
function pickCookies(res) {
  const jar = {}
  const list = typeof res.headers.getSetCookie === 'function' ? res.headers.getSetCookie() : []
  for (const line of list) {
    const [pair] = line.split(';')
    const i = pair.indexOf('=')
    if (i > 0) jar[pair.slice(0, i).trim()] = pair.slice(i + 1).trim()
  }
  return jar
}

const cookieHeader = (jar) =>
  Object.entries(jar)
    .map(([k, v]) => `${k}=${v}`)
    .join('; ')

/** 三步会话引导的前两步：GET / 拿 PHPSESSID → POST /getMenu 签发 csrf_token */
async function bootstrapSession() {
  const jar = {}
  // 步骤 1：拿 PHPSESSID
  const home = await fetch(BASE + '/', {
    headers: { 'User-Agent': UA, Accept: 'text/html' },
    redirect: 'follow',
    signal: AbortSignal.timeout(20000), // 上游 TCP 挂起兜底（口径同 ams-client 的 20s）
  })
  Object.assign(jar, pickCookies(home))
  await home.arrayBuffer() // 读完释放连接

  // 步骤 2：getMenu 签发 csrf_token（POST 体与线上页面一致）
  const menu = await fetch(BASE + '/getMenu', {
    method: 'POST',
    headers: {
      'User-Agent': UA,
      'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
      'X-Requested-With': 'XMLHttpRequest',
      Referer: BASE + '/',
      Cookie: cookieHeader(jar),
    },
    body: 'globalData=false',
    signal: AbortSignal.timeout(20000),
  })
  Object.assign(jar, pickCookies(menu))
  await menu.arrayBuffer()
  if (!jar.csrf_token) throw new Error('getMenu 未签发 csrf_token')
  return jar
}

/**
 * 调 kkrb 任意业务接口（新会话引导 + POST，带重试）。
 * 供任意品类接口使用（如全物品涨幅榜 getHIPriceCurveData）；
 * getAmmoPLData 由 fetchAmmoMarket 基于本函数封装（外加 version / data 形状校验）。
 * @param {string} path 接口名，如 'getHIPriceCurveData'
 * @param {{body?:object, referer?:string, retries?:number}} opts
 * @returns {Promise<object>} code===1 的业务 JSON（data 形状由调用方自查）
 */
export async function kkrbRequest(path, { body = {}, referer, retries = 2 } = {}) {
  let lastErr = null
  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      const jar = await bootstrapSession()
      const res = await fetch(BASE + '/' + path, {
        method: 'POST',
        headers: {
          'User-Agent': UA,
          'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8',
          'X-Requested-With': 'XMLHttpRequest',
          'x-csrf-token': jar.csrf_token,
          Referer: referer || BASE + '/',
          Cookie: cookieHeader(jar),
        },
        body: new URLSearchParams(body).toString(),
        signal: AbortSignal.timeout(20000),
      })
      const json = await res.json()
      if (json.code !== 1) throw new Error(`${path} 业务失败 code=${json.code} msg=${json.msg || ''}`)
      return json
    } catch (e) {
      lastErr = e
      if (attempt < retries) await new Promise((r) => setTimeout(r, 3000 * (attempt + 1)))
    }
  }
  throw lastErr
}

/**
 * 拉取一次完整子弹行情（会话引导 / POST / code!==1 检查 / 3s 递增退避重试
 * 全部复用 kkrbRequest，这里只做本接口额外的形状校验）。
 * @returns {Promise<{code:number, version:string, data:Array, fetchedAt:string}>}
 *   data 每项字段：itemName / pic / grade / currectPrice / thisWeekHighestPrice(±AfterTax) /
 *   thisWeekLowestPrice / lastWeek* / yesterday* / priceCurve({"YYYYMMDDHHmm": price})
 * @throws {Error} 网络失败 / 业务 code !== 1 / data 非数组 / version 不合规
 */
export async function fetchAmmoMarket({ retries = 2 } = {}) {
  const json = await kkrbRequest('getAmmoPLData', {
    referer: BASE + '/?viewpage=view%2Fmarket%2Fammo_price_pl',
    retries,
  })
  if (!Array.isArray(json.data)) {
    throw new Error(`getAmmoPLData 形状异常（data 非数组）: ${JSON.stringify(json.data).slice(0, 60)}`)
  }
  // version 会被拼进留档文件路径（fetch-once: data/ammo/history/<version>.json），
  // 只放行纯数字串（上游实为 YYYYMMDDHH 共 10 位；moligod 侧同性质校验 12 位；
  // 数字类型的十进制表示同样接受）。不合规即拒收本轮快照——防上游被攻破后
  // 用 '../../../x' 类值穿越写任意路径
  const version = typeof json.version === 'number' ? String(json.version) : json.version
  if (typeof version !== 'string' || !/^\d{8,14}$/.test(version)) {
    throw new Error(`getAmmoPLData version 不合规: ${JSON.stringify(json.version)}`)
  }
  return { code: 1, version, data: json.data, fetchedAt: new Date().toISOString() }
}
