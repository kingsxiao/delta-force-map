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
| `p75Local` | number | 近 72h 曲线 P75（体制内目标锚） |
| `weekHigh` `weekLow` | number | 7 天最高 / 最低 |
| `targetSell` | number | 目标挂卖价 = 近 72h P75（体制内目标；结构下行里 7 天 P75 是幻影目标） |
| `netSell` | number | 目标挂卖价税后到手 |
| `netHigh` | number | 7 天最高税后到手（乐观目标） |
| `profitPerRound` | number | 每发利润 = netSell − current |
| `profitPct` | number | 收益率 = 利润 / 现价 |
| `slope48` | number | 近 48h 回归斜率（%/h，相对区间均值归一） |
| `lowAgeH` | number | 7 天最低价距今小时数 |
| `bounceOffLow` | number | 现价相对 7 天低点的离底幅度 |
| `stopLoss` | number | 止损位 = max(7天低点×0.97, 现价×0.95) |
| `maxHoldH` | number | 建议最长持有小时数（168） |
| `signal` | `"BUY" \| "WATCH" \| "SELL" \| "WAIT"` | 见下方信号口径 |
| `reason` | string | 仅数据不足时出现（"数据不足"） |

**信号口径**（`server/ammo/analyze.mjs`，三端不得另立；参数集中在 `RULES`，
调参先跑 `server/ammo/backtest.mjs --grid` 回测验证）：

2026-10-26 起 v2：21 天真实数据 walk-forward 回测，旧口径 284 笔 / 31% 胜率 /
单笔均 −6.6%（慢性阴跌里「贴 7 天低位」恒真而 7 天 P75 是跌前幻影，信号专挑
接飞刀）；v2 为 14 笔 / 79% 胜率 / 单笔均 +9.6%——更少但更对。税负数学：
15% 税下止损 −5% 价差即净亏 −19.3%，止盈需 ≥+17.6% 价差才回本，故宁缺毋滥。

- `BUY`：五重门槛全部满足（缺一降级 WATCH）
  - `rank ≤ 0.20`（现价处 7 天曲线下 1/5）
  - 目标挂卖（72h P75）税后 `profitPct ≥ 0.10`
  - 曲线 ≥ 48 点；`bounceOffLow ≥ 0.03`（离底确认）；`lowAgeH ≥ 12`（近 12h 无新低=止跌确认）
  - `slope48 ≥ +0.02%/h`（体制不向下）
  - 随信号给 `stopLoss`（破位离场）与 `maxHoldH`（超时未达目标离场）
- `WATCH`：`rank ≤ 0.35`（接近低位但未满足 BUY 全部门槛，先挂限价观察）
- `SELL`：`rank ≥ 0.80` 且 `slope48 ≤ 0.05%/h`（贴近 7 天高位且动能转弱；
  强势上冲不催卖——守则使信号后 24h 平均跌幅 −0.53%→−0.77%）
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

## 7. 静态附属数据与官方源基础设施（实现方 = 后端）

直连腾讯官方 AMS 的基础设施与静态附属产物：基础库 `server/official/`（`ams-client` 请求客户端 + `object-directory` 物品目录缓存），以及建在其上的 TTK 官方对账 CLI（`server/ttk/official-audit.mjs`）与子弹官方均价锚（`server/official/ammo-anchor.mjs`）——**纯库 / 纯脚本、零 npm 依赖、不起服务**。本节全部内容**不是快照契约变更**（§1 各快照形状不变，不动 schema 与 SSE 事件），**iOS 端无消费方**（不进 `export:ios` 导出面）：目录缓存与均价锚是纯后端 sidecar；TTK 对账报告虽落 `apps/web/public/data/`，但当前前端 / iOS 均不消费，仅供人工复核。

### 7.1 官方接口（免登录公开接口，2026-10-26 双人 curl 复核 + 本仓实测）

| 用途 | 接入点 | 口径 |
| --- | --- | --- |
| 物品目录 `dfm/object.list` | `POST https://comm.ams.game.qq.com/ide/`（chartId 352143，token `YWRywA`） | 表单 `source=1` + `param={primary,second,third,objectID}`，primary 逐类单独传（gun/ammo/protect/acc/props）；取值路径 `jData.data.data.list`；实测 gun 68 条全带 gunDetail、ammo 113 条 |
| 小时均价 | `POST https://dfm.ams.game.qq.com/ide/`（chartId 352246，token `Zek01X`） | 表单直传 `propid=<id,…>` 与 `stat_hour=YYYYMMDDHH`（北京墙钟，必填但值被忽略）；单次 ≤5 个 id；**实测** `jData.data` 为 `{<objectID>:{avg_buyprice:Number}}` 直接映射（并兼容累计数组取末元素口径，两种形状自测均覆盖） |

- 响应 Content-Type 是 `text/html` 但正文 JSON——按 `text()` 读回再解析，不信 Content-Type；`ret≠0` 时错误文案在 `sMsg`（`ret=-11009` = 流程未发布），错误对象带 `.ret` / `.sMsg`
- 请求带浏览器 UA 与 `Origin/Referer: https://df.qq.com/`，20s 超时；**不登录、不绕风控、不保存任何凭据**
- `sIdeToken` 随活动配置轮换、非凭据：内置现行表 → 请求失败且症状像 token 问题时 GET 流目录（`comm.ams.game.qq.com/ide/page/21_3LXYAj`；`tokens` 是 token→chartId 映射，反转后使用）刷新模块态并重试一次，每进程至多刷一次

### 7.2 请求预算（如实）

物品目录 TTL 24h，gun/ammo/protect 三类各 1 次即 **约 3 请求/天**；小时均价按需（≤5 物品/批，默认 400ms 批间隔，单批失败跳过不炸整体）；流目录仅在 token 失效兜底时 1 次。`official:selftest --online` 每次运行 2 次真实请求（object.list gun ≥60 条 + 352246 单物品正数均价），离线模式零外网。

### 7.3 目录缓存（`data/official/object-directory.json`，随 `/data/` gitignore）

```json
{ "fetchedAt": "ISO", "fetchedAtMs": 1798000000000, "ttlMs": 86400000,
  "primaries": { "gun": [条目…], "ammo": […], "protect": […] } }
```

条目 = `{objectID(String), objectName, grade, primaryClass, secondClass, avgPrice, pic}`，`gunDetail` / `ammoDetail` / `protectDetail` 仅存在时透传。双层缓存（进程级 + 磁盘原子写），未过期且覆盖所需 primaries 时直接加载**零请求**；`getDirectory({primaries, force, rootDir})` 刷新失败如实抛错，由调用方决定回落（不做静默兜底）。名字匹配 `findByName(name)`：精确 objectName → 归一化（`normalizeName`：去 U+200B 等零宽字符 / 全角转半角 / `*`→`x` / 小写 / 空格折叠——官方名实测有「7.62*39mm AP SUB」星号变体），一对多返回 `{ambiguous:true, matches}` 交调用方裁决。

### 7.4 TTK 官方对账报告 `data/ttk-audit.json`

`npm run ttk:audit`（手动赛季级 CLI，不常驻）产出的静态报告，前端 / iOS 当前不消费，供人工复核 TTK 三件套（`apps/web/src/data/ttk/{guns,calibers,armor}.js`）与官方数据的差异。**只报告，不自动改任何数值。** 产物 `apps/web/public/data/ttk-audit.json`，`apps/web/dist/data` 目录存在时同内容双写。

| 字段 | 说明 |
| --- | --- |
| `source.official` | 腾讯官方 AMS `object.list`（chartId 352143，免登录）：`api`、`fetchedAt`（目录缓存时刻，`data/official/` 24h TTL）、`counts.{gun,ammo,protect}`；protect 抓取失败时 `counts.protect=null` 并带 `protectError`（不阻塞 gun/ammo） |
| `source.dfttk` | DFTTK v3：`manifest` / `weapons` URL、`dataVersion`、`version`、`fetchedAt`（`data/dfttk/` 24h 缓存）、`sha256.{expected,actual,ok}`（weapons.json 按 manifest 校验，不符仅告警）、`weaponCount`；抓取失败为 `null` |
| `fetchedAt` | 本次审计运行时刻（ISO） |
| `guns` / `ammo` | `checked` 成功 join 的本地条目数；`matched` 其中 diff 为零者；`diff[]` 可比字段不一致；`noted[]` 口径不同只记录不判错（不影响 `matched`） |
| `armor` | `checked` / `matched` / `diff[]` 同上（本地逐级满耐久落在官方同级型号区间外才进 diff）；`levels[]` 每级完整记录 `{type:'armor'|'helmet', lv, field:'DUR'|'HEAD_DUR', local, official:{min,max,models:[{objectID,objectName,durability}]}, inRange}` |
| `unmatched.{guns,ammo,armor}` | `side:'local'`（本地无 img / 官方无同名 / 官方同名多条歧义 / 官方无该级型号）或 `side:'official'`（官方有本地无），各带 `reason` |

`diff` / `noted` 条目：`{zh, objectID, field, local, official, dfttk, note?}`。`official` / `dfttk` 一律已折算到**本地口径**：霰弹枪官方单弹丸 ×弹丸数（取 dfttk `projectileCount`，缺省 8）；弹药 `harmRatio`（百分比）/100 对应 `flesh`；`penetrationLevel` 为 null 视为 pen 0。`dfttk` 列只作参考不参与判定（ammo / armor 条目恒为 null）。

对账字段：枪 `dmg↔meatHarm`、`admg↔armorHarm`、`rpm↔fireSpeed`、`mag↔capacity`、`cal↔caliber`（join 键 `img` = 官方 `objectID`；官方 caliber 为松散字符串，经 `normCaliber` 归一后查 `CAL_OFFICIAL_TOKENS`，编码未登记进 `noted`）；弹 `pen↔penetrationLevel`、`flesh↔harmRatio`（按名匹配：`AMMO_PREFIX[cal] + n` 归一化对官方 `objectName`，不规则命名走 `AMMO_NAME_ALIAS`；12ga 独头 / 单弹丸弹 flesh 口径不同进 `noted`）；甲 `DUR` / `HEAD_DUR` 逐级对官方 `secondClass` `armor` / `helmet` 同级全部型号 `durability` 区间（`bag` / `chest` 无 protectLevel 不参与）。

CLI 末行：`SUMMARY {"guns":{"checked":N,"matched":N,"diff":N},"ammo":{…},"armor":{…},"unmatched":N,"top":["枪名 字段 本地X→官方Y",…]}`（前缀 `SUMMARY ` 后为单行合法 JSON；`top` 取枪→弹→甲 diff 顺序前 10 条；armor 的官方值格式为 `min-max`）。

### 7.5 `data/ammo/official-anchor.json` — 子弹官方均价锚（仅服务端 sidecar，不对外）

> 不经 HTTP / SSE 外发、不进 `apps/web/public`、不在任何快照契约里；随 `/data/` 整体 gitignore。网页端 / iOS 端**不消费**本文件。
> 由 `server/official/ammo-anchor.mjs` 产出：`npm run anchor:fetch` 单跑，或 `server.mjs` 每 24h 一轮（启动 2 分钟后首跑；`--anchor-interval-hours N` / `ANCHOR_INTERVAL_HOURS` 可调，`--no-anchor` 关闭）。

用途：拿腾讯官方 AMS 352246 的 `avg_buyprice`（「近期平均交易价格」口径，按 objectID 给值、无小时曲线）给 moligod 主源的 67 弹现价做外部参照——**只校验、不替代、不改口径**，绝不写 `market.json`。

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `fetchedAt` | ISO 字串 | 本轮校验时刻 |
| `total` | number | `market.json` 的 `items` 条数（当前 67） |
| `joined` | number | 名称映射唯一命中条数（= `items.length`） |
| `missed` | string[] | 精确 / 归一化 / 别名都没命中的 market 弹名（不猜、不请求均价） |
| `ambiguous` | `[{name, candidates:[{objectID, officialName, grade}]}]` | 一对多撞名（候选附 grade 供人工裁决；不请求均价） |
| `items[].name` | string | `market.json` 弹名（主键；源数据原样，含零宽字符） |
| `items[].objectID` | string | 官方 objectID |
| `items[].officialName` | string | 官方 `objectName` 原样 |
| `items[].via` | `exact` / `normalized` / `alias` | 命中路径（用于审计别名表命中） |
| `items[].moli` | number 或 null | `market.json` 的 `current` |
| `items[].official` | number 或 null | 官方 `avg_buyprice`（原样浮点）；null = 该批请求失败或未请求（`--limit` 之外） |
| `items[].dev` | number 或 null | `(moli − official) / official`，保留 4 位小数；`official` 缺失或非正时 null。abs(dev) > 0.15 时服务端逐弹 `console.warn` |

名称映射口径（宁缺毋滥，绝不模糊匹配）：精确 `objectName` → `object-directory.normalizeName` 归一化（去零宽 / 全角转半角 / `*`→`x` / 小写 / 空白折叠）→ 显式别名表 `AMMO_NAME_ALIASES`（market 名 → objectID，运行时再校验 objectID 在目录且 grade 一致，不符记 missed）。一对多进 `ambiguous`，其余进 `missed`，两者都不请求均价。

CLI 末行单行 JSON：`SUMMARY {"total","joined","missed","ambiguous","devOver15","maxDev":{"name","dev"},"requests"}`。`requests` 为 352246 实际批次数（≤5 id/批、串行、≥400ms 间隔，67 弹 ≤14）；官方目录刷新（`object-directory`，TTL 24h，≤1 次/天）不计入。`maxDev` 无任何定价项时为 `{"name":null,"dev":null}`。
