# 多端共享接口契约（shared/API.md）

本目录是多端共享层：**接口契约**（本文 + `schema/*.json`）与**纯函数域逻辑**（`js/`）的唯一事实来源。
三个消费方必须与本契约对齐：

| 端 | 位置 | 消费方式 |
| --- | --- | --- |
| Node 后端 | `server/` | 产出快照 / SSE 事件（本契约的**实现方**） |
| 网页端 | `apps/web`（Vue 3） | fetch 快照 + EventSource SSE，`@shared/js` 直引纯函数 |
| iOS 端 | `apps/ios`（SwiftUI） | URLSession 快照 + URLSession.bytes SSE；`js/` 中口径**同构移植**为 Swift（`MarketMeta.swift` / `SellEta.swift` / `NotifyPolicy.swift` / `AccountData.swift`，测试用 `fixtures/` 固定样本） |

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

### GET `/craft/craft.json` — 特勤处制造利润快照

Schema：暂无独立 schema 文件（字段以本节为准）。数据源 moligod 特勤处制造页同名接口（公开传输编码：AES-256-GCM + gzip，密钥随响应头下发，`server/craft/snapshot.mjs` 内解码），利润口径为上游算好的预估值：**材料按现价买入 → 产出按现价 × 数量挂卖 → 扣手续费**。

顶层：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `version` | string | 12 位分钟档 `YYYYMMDDHHmm`，= 全部配方产出 `lastUpdate`（北京墙钟）最大值 |
| `fetchedAt` / `generatedAt` | ISO-8601 | 本服务抓取时刻 / 上游生成时刻 |
| `source` | `"moligod-craft"` | 恒定；时效阈值按分钟级档（同 `moligod`，10/30 分钟） |
| `places` | `{id, label}[]` | 制造台展示序：workbench 工作台 / armory 防具台 / tech 技术中心 / pharmacy 制药台 |
| `items` | Item[] | 全量配方（当前 230，过滤上游 `is_special_ops_visible === false`） |
| `stats` | `{total, complete, profitable}` | 完整 = 材料与产出价格齐全；可盈利 = 完整且 `profit > 0` |

Item 字段：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | int | 上游配方 id（唯一键） |
| `place` | string | 制造台 id（见 `places`） |
| `requiredLevel` | int | 制造台解锁等级 |
| `category` | string \| null | 产出品类（ammo / protect / gun / acc / props …） |
| `output` | `{name, grade, pic, count, price, lastUpdate}` | 产物：名称 / 品级 / 官方图标 / 数量 / 现价 / 价格更新时刻（北京墙钟）；缺价时 `price` 为 null |
| `materials` | `{name, grade, pic, count, price, cost}[]` | 材料清单；缺价材料 `price` 为 null |
| `cost` `fee` `feeRate` `revenue` `profit` | number | 材料成本 / 手续费 / 费率 / 产出收入（价×数量）/ 预估净利润；`profit = revenue − fee − cost` |
| `profitPerHour` `roi` | number \| null | 服务端派生：时利 = profit / periodHours（periodHours ≤ 0 为 null）；回报率 = profit / cost |
| `periodHours` `periodLabel` | number, string | 制造耗时（小时 / 原始标签如 `12h`） |
| `todayMaxProfit` `sevenDayMaxProfit` | number | 今日 / 7 日最高利润（乐观参照，非承诺） |
| `missingPriceCount` | int | 材料或产出缺价计数；> 0 时利润估算不可用，客户端应降级展示 |

**最佳口径（三端一致）**：`missingPriceCount === 0` 且 `profitPerHour` 最大的配方（制造台同一时间只能跑一条，时利才是真实约束）；单次利润最高可作次序展示。

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
| `craft` | `{version, total, complete, profitable}` | 特勤处制造快照落盘后 |

**事件是轻量 ping，不带全量数据**：客户端收到后比较 `version`，版本前进才重新 GET 对应快照（复用既有数据路径，与网页端行为一致）。

时效（如实）：全网无秒级公开源，分钟级已是上限。端到端典型 2–3.5 分钟 = 源分钟粒度 + 服务端 60s 快轮询 + SSE ≤5s；无 SSE 时客户端 60s 轮询兜底（静态环境退 30 分钟，且仅在版本前进时提示）。

## 3. 数据时效口径（`js/marketMeta.js`，三端同构）

| source | 变灰阈值 | 过期提示阈值 |
| --- | --- | --- |
| `moligod`（分钟级） | 10 分钟 | 30 分钟 |
| `moligod-craft`（分钟级，特勤处制造） | 10 分钟 | 30 分钟 |
| `kkrb`（小时级兜底） | 60 分钟 | 360 分钟 |

年龄计算锚点：`fetchedAt`（心跳会刷新它）；年龄可读化 <60min 用分钟、<24h 用小时、更长用天。

## 4. 域纯函数（`js/`）

- `js/sellEta.js` — 预计卖出时间：A) 历史完整上涨段中位/最快历时（从 ≤现价 首次涨到 ≥P75）；B) 日内节律（7 天同小时均价的连续 3 小时最高窗口，允许跨午夜）。时钟锚点 `max(曲线末点, now)`；etaLabel 的「今日/明日 HH:00」按**北京墙钟（+08:00）**渲染（时间键即北京墙钟口径）：网页端 keyToDate / friendlyClock 与 iOS 固定 Asia/Shanghai 同口径，不随访问者设备时区漂移；**历史统计不代表未来，展示层必须带这句**。
- `js/marketMeta.js` — 版本双格式展示、时效阈值、来源文案、图标缩略、年龄可读化。
- `js/liveChannel.js` — 网页端 SSE 端点判定（原生端不用：直接连 `${baseURL}/events`）。
- `js/accountData.js` — 账号云数据口径：文档校验（键名 / 64KB）、星标并集与台账按名合并（§6.3）。
- `js/notify-policy.js` — 信号通知去抖（三端同构，唯一事实来源在 shared：服务端 monitor/live/雷达的 macOS 通知、网页端浏览器通知、iOS 本地通知共用本口径）：首次出现立即通知；信号切换需连续 2 轮确认；同信号 6h 冷却；BUY 冷却期内价格较上次通知价累计再跌 ≥5% 重报。

## 5. fixtures

`fixtures/market-sample.json`、`fixtures/radar-sample.json`：固定样本快照（脱敏自真实数据），供 iOS 单测与「演示模式」捆绑；后端自测另有自己的注入桩。契约变化时同步更新 fixtures。

## 6. 账号与云同步（`server/auth/`，实现方 = 后端）

自托管账号体系：注册 / 登录 / 登出 + **账号云数据**（不透明 K/V 文档，服务端只存不解析）。网页端与 iOS 端用它同步自选星标、囤货台账等本地数据。与快照接口同源同进程（`server/server.mjs` 挂载 `/api/*`），无需额外部署。

### 6.1 鉴权方式

- `Authorization: Bearer <token>`；token 为**无状态签名令牌** `v1.<uid>.<tokenVersion>.<expMs>.<hmac>`，HMAC-SHA256 密钥仅存服务器（`data/auth/secret.key`，首次运行自动生成，gitignore）。
- 有效期 30 天。**登出 = 服务器把该用户 `tokenVersion` +1**：该用户全部已发 token 立即失效（语义为「退出所有设备」，工具型单用户场景够用；无单设备吊销）。
- 密码哈希 `scrypt`（N=16384, r=8, p=1, 32B + 16B 随机盐），比对走 `timingSafeEqual`。

### 6.2 接口

| 方法 | 路径 | 鉴权 | 成功 | 失败 |
| --- | --- | --- | --- | --- |
| POST | `/api/auth/register` | — | `201 {token, user}` | `409` 用户名已存在；`400` 用户名/密码不合规 |
| POST | `/api/auth/login` | — | `200 {token, user}` | `401` 用户名或密码错误（不区分提示，防枚举） |
| POST | `/api/auth/logout` | Bearer | `204` | `401` |
| GET | `/api/auth/me` | Bearer | `200 {uid, username, createdAt}` | `401` |
| GET | `/api/account/data` | Bearer | `200 {data, savedAt}` | `401` |
| PUT | `/api/account/data` | Bearer | `200 {savedAt}`（整文档覆盖） | `400` 顶层非对象 / JSON 不合法；`413` 键名不合规或超 64KB |

- `user` / Session 形状：[schema/auth-response.schema.json](schema/auth-response.schema.json)；账号数据文档：[schema/account-data.schema.json](schema/account-data.schema.json)。
- 错误响应统一 `{error: "中文说明", code: "MACHINE_CODE"}`，`code` 供两端分支（如 `AUTH_FAILED` / `USERNAME_TAKEN` / `BAD_TOKEN` / `RATE_LIMITED`）。
- 请求体上限 128KB；鉴权响应一律 `Cache-Control: no-store`。
- 用户名 2–16 字符（字母 / 数字 / 下划线 / 中文，全表唯一，大小写不敏感）；密码 8–64 字符，无组成规则。
- 限速（按 IP）：注册 10 次/小时，登录 20 次/小时，超限 `429 {code:"RATE_LIMITED"}`。默认按**直连地址**计（XFF 可伪造，不采信）；nginx 反代形态启动时加 `--trust-proxy`（或 `TRUST_PROXY=1`）才按 `X-Forwarded-For` 首段计。
- CORS：`/api/*` 响应带 `Access-Control-Allow-Origin: *` 并处理 `OPTIONS` 预检（与 `/events` 同 posture；客户端用 token 而非 cookie，无凭证风险）。

### 6.3 账号数据口径（`js/accountData.js`，三端同构）

- 文档 = 不透明 K/V：键名 `^[A-Za-z0-9._-]{1,64}$`（点分命名空间），整体序列化 ≤ 64KB（**按 UTF-8 字节计**：JS 端 TextEncoder、iOS 端 JSONEncoder 输出字节数，两端同口径——中文按每字 3 字节计，不再按 UTF-16 code unit 低估；`normalizeAccountDoc` 校验，PUT 两侧共用）。台账条目的 qty / cost 只认 JSON number（字符串数字剔除，两端清洗一致）。
- 已约定键：`stars.ammo` = string[]（子弹自选弹名）；`ledger.ammo` = `[{name, qty, cost}]`（囤货台账：弹名 / 数量 / 成本单价）；`mycost.ammo` = `{弹名: 成本单价}`（网页端信号卡自录买入价，iOS 暂只透传保留不消费）。后续键按需增补，先改本节再改端。
- 首次登录 / 拉取合并口径：星标取**并集**（`mergeStars`，去重排序后回写两端与云端）；台账按弹名并集、**同名冲突本地优先**（`mergePositions`）；mycost 同为按键并集、本地优先（`mergeLocalWins`）——避免任何一端被覆盖丢数据。
- **云端只存「用户创作内容」**（自选、台账这类丢了会心疼的），不存「设备偏好」（通知开关、服务器地址、UI 状态——每台设备自己的，同步它们反而会互相踩）。
- iOS 同构实现：`DeltaForceCore/AccountData.swift`（`normalizeAccountDoc` / `mergeStars` / `mergePositions`），单测与 JS 口径逐项对账。
- 数据落盘：`data/auth/accounts.json`（账号表）+ `data/auth/account-data/<uid>.json`（每用户文档），原子写（tmp+rename），随 `/data/` 整体 gitignore。
- 隐私边界：文档内容不做加密（自托管单机、明文 http 合法形态下 TLS 由部署侧负责）；不要往里放任何敏感信息，见键名约定。
