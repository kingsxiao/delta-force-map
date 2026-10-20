# 多端共享接口契约（shared/API.md）

本目录是多端共享层：**接口契约**（本文 + `schema/*.json`）与**纯函数域逻辑**（`js/`）的唯一事实来源。
三个消费方必须与本契约对齐：

| 端 | 位置 | 消费方式 |
| --- | --- | --- |
| Node 后端 | `server/` | 产出快照 / SSE 事件（本契约的**实现方**） |
| 网页端 | `apps/web`（Vue 3） | fetch 快照 + EventSource SSE，`@shared/js` 直引纯函数 |
| iOS 端 | `apps/ios`（SwiftUI） | URLSession 快照 + URLSession.bytes SSE；`js/` 中口径**同构移植**为 Swift（`MarketMeta.swift` / `SellEta.swift` / `NotifyPolicy.swift`，测试用 `fixtures/` 固定样本） |

任何字段增删 / 语义变化：先改本文件与 schema，再改三端，PR 描述注明契约变更。

---

## 0. 部署形态与基准地址

- 后端 = 单进程 Node 服务（`npm run serve`，见 `server/server.mjs`）：静态托管网页构建产物 + 行情抓取循环 + SSE。
- **基准地址（baseURL）**：自托管，由用户配置。默认形态 `http://<服务器IP或域名>:8080`（nginx https 反代后为 `https://…`）。
- 原生端忽略 CORS（仅浏览器需要）；`/events` 与 `/health` 也带 `Access-Control-Allow-Origin: *`，网页跨端口开发可用。
- 明文 http（IP 直连）是合法部署形态——iOS 端在 Info.plist 以 `NSAppTransportSecurity → NSAllowsArbitraryLoads` 放行（自托管内网/未备案场景），上线 App Store 前建议切 https。

## 1. 快照接口

### GET `/ammo/market.json` — 子弹行情快照（前端唯一数据源）

Schema：[schema/market-snapshot.schema.json](schema/market-snapshot.schema.json)

顶层：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `version` | string | 数据版本号 = 全部曲线最新点的时间键最大值。**双格式**：主源 moligod 为 12 位分钟档 `YYYYMMDDHHmm`；兜底 kkrb 为 10 位小时档 `YYYYMMDDHH`。客户端按长度分流展示，不自造分钟 |
| `fetchedAt` | ISO-8601 | 上游真实抓取时刻（心跳重写会刷新） |
| `generatedAt` | ISO-8601 | 分析产物生成时刻 |
| `source` | `"moligod" \| "kkrb"` | 实际服务源，页面来源标签如实切换 |
| `fingerprint` | hex-64 | 价格向量 sha256（内容门槛用，客户端可忽略） |
| `items` | Item[] | 全量弹药（当前 67 种），含 WAIT |
| `signals` | `{buy, sell, watch}` | `items` 的过滤副本（BUY / SELL / WATCH），仅为方便，客户端可自行过滤 |
| `stats` | `{total, buy, sell, watch}` | 计数 |

Item 字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `name` | string | 游戏内名称（唯一键） |
| `grade` | int 1–6 \| null | 弹药等级 |
| `pic` | url \| null | 官方弹药图标（playerhub 原图，可用 `?imageMogr2/thumbnail/96x` 缩略，见 `js/marketMeta.js picThumb`） |
| `current` | number | 现价（源无现价时取曲线末点） |
| `taxRate` | number | 税率（本周最高价税前/税后反推；缺数据兜底 0.15） |
| `curve` | [[key, price]] | 近 7 天小时级曲线，按时间键升序。时间键同 `version` 双格式 |
| `rank` | number \| null | 现价在 7 天曲线中的分位（0=最低 1=最高）；**null = 数据不足**（曲线 <24 点，此时 signal 恒为 WAIT） |
| `p10 p25 p50 p75 p90` | number | 7 天价格分位（线性插值） |
| `weekHigh` `weekLow` | number | 7 天最高 / 最低 |
| `targetSell` | number | 目标挂卖价 = P75（常规，可达成性高） |
| `netSell` | number | P75 税后到手 |
| `netHigh` | number | 7 天最高税后到手（乐观目标） |
| `profitPerRound` | number | 每发利润 = netSell − current |
| `profitPct` | number | 收益率 = 利润 / 现价 |
| `signal` | `"BUY" \| "WATCH" \| "SELL" \| "WAIT"` | 见下方信号口径 |
| `reason` | string | 仅数据不足时出现（"数据不足"） |

**信号口径**（`server/ammo/analyze.mjs`，三端不得另立）：

- `BUY`：`rank ≤ 0.25` 且 `profitPerRound > 0` 且 `profitPct ≥ 0.08`（税覆盖不掉的不报）
- `WATCH`：`rank ≤ 0.35`（接近低位，可挂限价）
- `SELL`：`rank ≥ 0.80`（贴近 7 天高位，建议出货）
- `WAIT`：其余；曲线不足 24 点时 `rank = null`

### GET `/market/radar.json` — 全品类异动雷达快照

Schema：[schema/radar-snapshot.schema.json](schema/radar-snapshot.schema.json)

顶层同上（`source` 恒为 `"kkrb-radar+moligod"`；无 `fingerprint`/`signals`），`items` 为涨幅榜 Top10。Item 在子弹 Item 基础上追加：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `hiRank` | int | kkrb 涨幅榜名次（1 起） |
| `category` | string | 品类（`props` / `key` / `armor` / `attachment` / `gun` …以榜单返回为准） |
| `crossDev` | number \| null | 双源曲线重叠小时的中位偏差（kkrb 榜单 vs moligod）；重叠 <24h 时为 null（无结论） |
| `crossOverlap` | int | 重叠小时数 |
| `anomaly` | boolean | `crossDev > 0.15` → 双源异常：**信号强制观望、不通知**（口径分歧宁可漏报） |
| `rawSignal` | string | 被异常压制前的原始信号 |
| `curveSource` | string | 实际采用的曲线源（`moligod` / `kkrb-radar`） |

### GET `/health` — 服务健康

```json
{"ok":true,"source":"moligod","version":"202610201121","generatedAt":"…",
 "lastSuccessAt":"…","consecutiveFailures":0,"cycles":1}
```

原生端把「能取到 `/health`」视为**实时服务在线**的判定（与网页端 gate 一致）；取不到则退化为纯轮询快照模式。

## 2. 实时通道（SSE）

### GET `/events` — `text/event-stream`

响应头：`Cache-Control: no-cache`、`X-Accel-Buffering: no`（防反代缓冲掐流）。每 25s 发注释心跳 `: ping`（客户端忽略以 `:` 开头的行，但可用它做连接活性判断）。

命名事件（`data` 均为单行 JSON）：

| event | data | 时机 |
| --- | --- | --- |
| `hello` | `{version, source, generatedAt}` | 连接建立即发（当前盘上快照元信息） |
| `market` | `{version, source, generatedAt}` | 弹药快照落盘后 |
| `radar` | `{version, total, anomaly, buy, sell}` | 雷达快照落盘后 |

**事件是轻量 ping，不带全量数据**：客户端收到后比较 `version`，版本前进才重新 GET 对应快照（复用既有数据路径，与网页端行为一致）。

时效（如实）：全网无秒级公开源，分钟级已是上限。端到端典型 2–3.5 分钟 = 源分钟粒度 + 服务端 60s 快轮询 + SSE ≤5s；无 SSE 时客户端 60s 轮询兜底（静态环境退 30 分钟，且仅在版本前进时提示）。

## 3. 数据时效口径（`js/marketMeta.js`，三端同构）

| source | 变灰阈值 | 过期提示阈值 |
| --- | --- | --- |
| `moligod`（分钟级） | 10 分钟 | 30 分钟 |
| `kkrb`（小时级兜底） | 60 分钟 | 360 分钟 |

年龄计算锚点：`fetchedAt`（心跳会刷新它）；年龄可读化 <60min 用分钟、<24h 用小时、更长用天。

## 4. 域纯函数（`js/`）

- `js/sellEta.js` — 预计卖出时间：A) 历史完整上涨段中位/最快历时（从 ≤现价 首次涨到 ≥P75）；B) 日内节律（7 天同小时均价的连续 3 小时最高窗口，允许跨午夜）。时钟锚点 `max(曲线末点, now)`；**历史统计不代表未来，展示层必须带这句**。
- `js/marketMeta.js` — 版本双格式展示、时效阈值、来源文案、图标缩略、年龄可读化。
- `js/liveChannel.js` — 网页端 SSE 端点判定（原生端不用：直接连 `${baseURL}/events`）。
- 信号通知去抖（`server/ammo/notify-policy.mjs`）：首次出现立即通知；信号切换需连续 2 轮确认；同信号 6h 冷却；BUY 冷却期内价格较上次通知价累计再跌 ≥5% 重报。iOS 本地通知同口径移植。

## 5. fixtures

`fixtures/market-sample.json`、`fixtures/radar-sample.json`：固定样本快照（脱敏自真实数据），供 iOS 单测与「演示模式」捆绑；后端自测另有自己的注入桩。契约变化时同步更新 fixtures。
