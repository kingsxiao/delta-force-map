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

/**
 * 拉取一次完整子弹行情。
 * @returns {Promise<{code:number, version:string, data:Array, fetchedAt:string}>}
 *   data 每项字段：itemName / pic / grade / currectPrice / thisWeekHighestPrice(±AfterTax) /
 *   thisWeekLowestPrice / lastWeek* / yesterday* / priceCurve({"YYYYMMDDHHmm": price})
 * @throws {Error} 网络失败或业务 code !== 1
 */
export async function fetchAmmoMarket({ retries = 2 } = {}) {
  let jar = {}
  let lastErr = null

  for (let attempt = 0; attempt <= retries; attempt++) {
    try {
      // 步骤 1：拿 PHPSESSID
      const home = await fetch(BASE + '/', {
        headers: { 'User-Agent': UA, Accept: 'text/html' },
        redirect: 'follow',
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
      })
      Object.assign(jar, pickCookies(menu))
      await menu.arrayBuffer()
      if (!jar.csrf_token) throw new Error('getMenu 未签发 csrf_token')

      // 步骤 3：真正的数据接口
      const data = await fetch(BASE + '/getAmmoPLData', {
        method: 'POST',
        headers: {
          'User-Agent': UA,
          'X-Requested-With': 'XMLHttpRequest',
          'x-csrf-token': jar.csrf_token,
          Referer: BASE + '/?viewpage=view%2Fmarket%2Fammo_price_pl',
          Cookie: cookieHeader(jar),
        },
      })
      const json = await data.json()
      if (json.code !== 1 || !Array.isArray(json.data)) {
        throw new Error(`getAmmoPLData 业务失败 code=${json.code} msg=${json.msg || ''}`)
      }
      return { code: 1, version: json.version, data: json.data, fetchedAt: new Date().toISOString() }
    } catch (e) {
      lastErr = e
      jar = {}
      if (attempt < retries) await new Promise((r) => setTimeout(r, 3000 * (attempt + 1)))
    }
  }
  throw lastErr
}
