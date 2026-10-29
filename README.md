# 三角洲行动 · 数据工具

多端 monorepo：**网页端**（Vite + Vue 3，`apps/web`）+ **iOS 原生端**（Swift 6 + SwiftUI，`apps/ios`）+ **Node 后端**（`server/`，静态托管 + 行情抓取 + SSE）+ **跨端契约与共享逻辑**（`shared/`）。内容：**子弹行情实时监控**页（交易行子弹的买卖点与税后利润，主源分钟级 + SSE 实时通道）、**全品类异动雷达**页（子弹以外的钥匙 / 护甲 / 配件 / 物资涨幅榜 + 分位信号 + 双源交叉验证）、**枪械 TTK 击杀时间排行**页（全枪械 7 兵种 × 各级弹药与护甲），以及**特勤处制造**页（工作台 / 防具台 / 技术中心 / 制药台全量配方的实时利润估算与时利最佳推荐）。`legacy/` 旧单文件页已整体完成组件化迁移，仅作只读留档。

## 多端架构

```
delta-force-map/
├── apps/
│   ├── web/        网页端：Vite + Vue 3（index.html / vite.config.js / src / public）
│   └── ios/        iOS 端：SwiftUI App + 本地 Swift Package（DeltaForceCore）+ xcodegen 工程
├── server/         Node 后端（零 npm 依赖）：server.mjs 同源站点 + ammo/ market/ 抓取分析 + auth/ 账号云同步 + 自测 + 导出脚本
├── shared/         跨端共享：API.md 接口契约、schema/ JSON Schema、js/ 纯函数域逻辑（网页端 @shared 别名 /
│                   后端相对引用）、data/ fixtures/（导出给 iOS 捆绑与单测的数据与固定样本）
├── deploy/         systemd 单元 / nginx 示例 / 一键更新脚本
├── assets/ legacy/ 制作期留档（运行时不引用）
└── package.json    仓库根 = Node 工程；npm 脚本名不变（dev/build/serve/…），内部指向 apps/web 与 server/
```

- **后端只有一份**：`server/server.mjs` 一个进程托管网页端构建产物 `apps/web/dist`、跑抓取循环、写快照、推 SSE；iOS 端只消费它的 HTTP + SSE 接口，不自带抓取。
- **契约先行**：字段 / 口径以 [shared/API.md](shared/API.md) 与 `shared/schema/*.json` 为唯一事实来源，三端对齐；改契约先改这里再改三端。
- **共享逻辑**：`shared/js/`（sellEta / marketMeta / liveChannel）被网页端与后端自测直接 import；iOS 端在 `DeltaForceCore` 同构移植（`SellEta.swift` / `MarketMeta.swift` / `NotifyPolicy.swift` / `TtkEngine.swift`），单测用同一份 `shared/fixtures` 样本对账，TTK 用例与网页端 JS 模型逐发核对。
- **数据不复制**：TTK 数据与契约样本由 `npm run export:ios` 从网页端 JS 模块确定性导出到 `shared/`，iOS 工程以文件引用捆绑（枪械图直接引用 `apps/web/public/guns`）。
- iOS 端详情见 [apps/ios/README.md](apps/ios/README.md)。

## 开发

```bash
npm install        # 安装依赖（仓库根，一份 package.json 管网页端构建与后端脚本）
npm run dev        # 启动网页端开发服务器（默认 http://localhost:5173/，vite root = apps/web）
npm run build      # 构建网页端产物到 apps/web/dist/
npm run preview    # 本地预览构建产物
npm run serve      # 同源部署服务：静态站 + 实时行情 SSE（见「部署」）
npm run refresh    # 手动刷一次弹药 + 雷达数据（serve 常驻时可不做，进程内会自动刷）
npm run export:ios # TTK 数据 / 契约样本 → shared/data、shared/fixtures（iOS 捆绑 + 单测用）

cd apps/ios/Packages/DeltaForceCore && swift test   # iOS 逻辑内核单测（macOS 直接跑）
cd apps/ios && xcodegen generate                    # 改 project.yml 后重新生成 Xcode 工程
```

## 部署

线上为自托管实时服务（页面代码自动探测实时通道）：

- **自托管实时服务（SSE 实时）**：`npm run build && npm run serve`（默认 `0.0.0.0:8080`，
  `PORT` / `HOST` 环境变量可改）。一个进程四件事：定时抓上游（弹药 fast/slow 双循环 +
  雷达循环与特勤处制造循环默认各 10 分钟；弹药带 kkrb 兜底）→ 原子写快照 → 静态托管
  `apps/web/dist` + `/events` SSE 推送（`market` / `radar` / `craft` 三个事件，页面实时），
  页面端到端延迟 = 源分钟粒度 +
  60s 快轮询 + 5s。站点与 SSE 同源，https 反代（nginx / caddy）即可上线；系统通知默认
  关闭，`--notify` 开启；雷达节奏 `--radar-interval N` 可调。iOS 端连的也是这同一个服务。
  **云服务器部署**（阿里云 ECS 等）见 [deploy/aliyun.md](deploy/aliyun.md)：systemd 常驻 +
  nginx https 反代 + 一键更新脚本，`deploy/` 目录里有现成物料。服务器上执行
  `deploy/update.sh` 即可完成本次 monorepo 迁移（脚本会自动同步 systemd 单元里的
  `ExecStart=node server/server.mjs` 并 daemon-reload）。

- 路由为 **hash 模式**（五个入口：`/#/ammo`、`/#/radar`、`/#/craft`、`/#/ttk`、`/#/account`，`/` 重定向到 `/#/ammo`），静态托管零配置；页内锚点一律 `scrollIntoView`，禁止向 hash 写入裸锚点。
- 旧单文件页（`index.html`、`ttk.html`、`shaders.iife.js`）已挪到 **`legacy/`** 留档（只读，不再维护）；地图时代特效库的运行时副本 `apps/web/src/vendor/shaders.iife.js` 已随地图模块删除（零引用死资源，`legacy/` 留档逐字节相同）。
- 静态目录为默认的 **`apps/web/public/`**（dev 于 `/` 下访问、build 原样拷入 dist 根）；仓库根 `assets/` 原图为制作期留档，运行时不引用。

## 构建产物冒烟验证

`server/smoke.mjs` 自包含、零 npm 依赖，只 spawn headless Chrome，**不拉起 preview server**（先 `npm run build`，再另开终端 `npm run preview -- --port 4173 --strictPort`）：

```bash
node server/smoke.mjs http://localhost:4173/ shots/vue-smoke
```

逐页截图并断言五个入口（`/#/ammo`、`/#/radar`、`/#/craft`、`/#/ttk`、`/#/account`）的骨架 DOM（顶栏 5 个 tab、页头与各页 loading 终态）。随地图模块（commit 14c938e 全端移除）一并删除了旧特效层验证脚本 `verify-effects.mjs`（其 DOM 契约指向已删的 `.map-section`/`#fxHero`/灯箱，对现站点必然假阳性报「SITE BROKEN」）。

## 功能

- **账号与云同步**（两端，`/#/account` / iOS 设置 → 账号）：注册 / 登录 / 登出（token 存网页 localStorage、iOS Keychain），**自选星标 + 囤货台账云同步**——登录后云端与本地合并（星标并集 / 台账按弹名并集·同名本地优先），任何一端的数据都不丢，登录期间改动自动上云（防抖 2s）。口径见 [shared/API.md](shared/API.md) §6：账号数据是不透明 K/V 文档（≤64KB，服务端只存不解析，落 `data/auth/`），密码 scrypt 哈希、令牌 HMAC 签名 30 天有效、登出 = 全设备下线；按 IP 限速防爆破。云端只存「用户创作内容」（自选、台账这类丢了会心疼的），不存设备偏好（通知开关等每台设备自己的）。

## TTK 排行页

- **68 把武器 × 20 种口径 × 93 种弹药**的 TTK / BTK 排行（步枪 / 冲锋枪 / 射手步枪 / 狙击枪 / 轻机枪 / 霰弹枪 / 手枪），可切目标部位（胸 / 腹 / 头）、护甲等级（无甲 ~ 6 级）与子弹筛选（每枪最佳 / 全部组合 / 按穿透等级 0-7 级），每枪可展开全部弹药的逐发模拟对比
- **穿透 × 护甲判定矩阵**（0% / 50% / 75% / 100% 国服社区实测口径）与弹药库全表
- 计算口径：100 血单血池、部位倍率、碎甲 k 值规则、TTK = (BTK−1)×60000/RPM，全部假设与来源在页内注明
- **官方对账（`npm run ttk:audit`）**：TTK 三件套（`apps/web/src/data/ttk/{guns,calibers,armor}.js`）从「无对账纯人工」升级为「官方 diff 驱动」：
  - `npm run ttk:audit`：手动赛季级 CLI（不常驻）。拉官方 AMS `object.list` 的 gun / ammo / protect（3 请求，免登录，`data/official/` 24h 缓存）与 DFTTK v3 manifest + `catalog/weapons.json`（2 请求，sha256 校验不符只告警，`data/dfttk/` 24h 缓存），逐条 diff 本地枪械（dmg / admg / rpm / mag / cal，join 键 `img` = 官方 objectID）、弹药（pen / flesh，按名匹配）、护甲（DUR / HEAD_DUR 对官方同级型号耐久区间）。**只报告，绝不改任何数值文件**；`--force` 绕过两处缓存重抓；protect 失败不阻塞枪 / 弹。
  - 产物：`apps/web/public/data/ttk-audit.json`（`apps/web/dist/data` 存在时同内容双写），末行打印单行 JSON `SUMMARY {...}`；字段说明见 [shared/API.md](shared/API.md) §7.4「TTK 官方对账报告」。霰弹枪（官方单弹丸 ×8）、三连发（官方面板 = 含 burst 间隔持续均值）等口径差异已折算到本地口径；独头弹 flesh、未登记 caliber 编码归入 `noted` 只记录不判错。
  - `npm run ttk:selftest`：离线桩自测 13 项（注入官方 fixture 与故意不一致的枪，覆盖 diff 字段 / matched 计数 / protect 失败不阻塞 / unmatched 归集 / SUMMARY 可 parse / dist 双写），零外网。
  - 2026-10-26 已按官方把 M4A1 面板改为 `dmg 31 / admg 33`（官方 object.list `meatHarm=31 / armorHarm=33` 两名核验员各自 curl 复现，dfttk v3 亦 31/33），iOS `TtkEngineTests` 的 M4A1 期望同步（`flesh 55.1 → 58.9`，btk / ttk 不变）。审计首跑的其余差异（枪 37 条 / 弹 4 条 / 甲 2 条 / 未匹配 28）只记录在报告中，待人工逐条裁决。
  - **改三件套任一数值后必须**先 `npm run export:ios` 重生成 `shared/data/ttk.json`，再在 `apps/ios/Packages/DeltaForceCore` 跑 `swift test`——iOS 期望值与网页端 `model.js` 逐发对账，任一值漂移即失败。

## 子弹行情监控页（/#/ammo）

交易行子弹的实时价格、买卖点与**税后利润测算**（能赚多少），并在本机后台监控时弹出 macOS 系统通知——具体到哪种子弹、什么价格买入、挂多少钱卖出、每发预赚多少。

```bash
npm run ammo:live       # 本地 live 服务（推荐与 npm run dev 同跑）：60s 快轮询 + 30min 曲线补抓
                        #   + SSE 推送（落盘 ≤5s 到页面）+ 信号通知；--port/--no-notify/--no-dist 可调
npm run ammo:fetch      # 单次抓取 + 分析，落盘 apps/web/public/ammo/market.json（--source kkrb|--no-fallback|--no-dist）
npm run ammo:monitor    # 纯通知器循环（不开 SSE；默认 10 分钟一次，--interval N 可调，--no-notify 仅停通知、去抖 state 仍逐轮记录）
npm run ammo:selftest   # 刷新链路离线自测（不打外网，上游全用注入桩；--online 追加真实源检查）
npm run auth:selftest   # 账号体系离线自测（注册 / 登录 / 令牌 / 云数据 / 限速 / 站点挂载）
```

- **数据链路**：主源 moligod.com（分钟级，无鉴权）→ 本机 live / monitor / 手动 fetch 抓取并**原子落盘** `apps/web/public/ammo/market.json`（`apps/web/dist/ammo/` 存在时联动，vite preview 同样吃新数据）→ dev 实时读盘 / SSE 广播 → 页面。主源故障自动回落 kkrb.net（小时级，88 种兜底），页面来源标签如实切换
- **更新时效（如实）**：全网无秒级公开源，分钟级已是上限。主源 moligod 为分钟粒度（数据侧约 1–2.5 分钟滞后），端到端典型 2–3.5 分钟 = 源分钟粒度 + live 60s 快轮询 + SSE ≤5s（无 live 服务时页面 60s 轮询兜底）；「≤5s」只是本地腿（落盘→页面），端到端由源的更新粒度决定
- **请求量（按实现核算）**：fast 轮询每轮只打 1 次 catalog（对齐 ttl 60s，周期 ≈61s，约 59 次/小时）；slow 环每轮刷新曲线缓存（计时在本轮完成后重启，下轮曲线必已过 30min TTL，故稳态每轮全量 67 条 history + 1 次 catalog，实际周期 ≈31 分钟，约 132 次/小时）——稳态合计约 190 请求/小时（≈3.2 次/分钟），负载温和，不对源施压；429/5xx 时 fetch-once 内部重试 + live 指数退避（cap 10min）
- **官方数据源（腾讯 AMS）**：`server/official/` 直连官方免登录 AMS 接口（object.list 物品目录 chartId 352143 + 小时均价 chartId 352246，2026-10-26 实测复核），为名称解析（`findByName`：官方「7.62*39mm」星号变体等写法归一化）与价格核对提供官方口径。物品目录 24h TTL 缓存在 `data/official/object-directory.json`（gitignore，未过期零请求），稳态仅约 **3 次请求/天**（三类目录各 1 次）；小时均价按需 ≤5 物品/次。token 随活动配置轮换，失败自动经官方流目录刷新重试（token 非凭据；不登录、不绕风控）。自测：`npm run official:selftest`（离线零外网），`--online` 追加 2 次真实请求检查
- **官方均价锚（只校验不改口径）**：`server/official/ammo-anchor.mjs` 每天 1 轮（随 `npm run serve` 常驻，启动 2 分钟后首跑；`--anchor-interval-hours` / `ANCHOR_INTERVAL_HOURS` 可调、`--no-anchor` 关闭；`npm run anchor:fetch` 单跑）拿腾讯官方 AMS 352246 的「近期平均交易价格」给 67 弹现价做外部参照：弹名精确 → 归一化 → 显式别名表三步映射，一对多与未命中一律不猜（2026-10-26 实测命中 66/67，唯一未命中 `5.7x28mm HT` 因官方目录只有 `HT+` 无同名条目），逐弹算 `(moli − official)/official`，**|偏差| > 15% 逐弹告警**。每轮 ≤15 请求（目录 ≤1 次 + 均价 ≤14 批 ×5 id，串行 400ms 间隔），产物只落服务端 `data/ammo/official-anchor.json`（gitignore；不对外、不进快照、不广播）。官方口径是近期均价、无小时曲线，与 moligod 分钟级现价不是同一个量——所以只做校验，不替代主源、不改任何买卖口径
- **买卖口径（2026-10-26 v2 回测定稿，`server/ammo/backtest.mjs` 21 天 walk-forward：旧口径 284 笔 / 31% 胜率 / 单笔均 −6.6% → v2 14 笔 / 79% 胜率 / 单笔均 +9.6%）**：买入五重门槛——现价 ≤ 7 天 20% 分位、离 7 天低点 ≥3%、低点距今 ≥12h、48h 回归斜率 ≥ 0、按近 3 天 P75 挂卖税后收益率 ≥ 10%（缺一降级 WATCH）；随信号给止损位 max(7 天低点×0.97, 现价×0.95) 与 168h 持有上限。卖出：≥ 80% 分位且 48h 斜率 ≤ +0.05%/h（强势上冲不催卖）。税率按税后价实测反推（约 15%，逐弹计算；moligod 无税后字段时回退 15%）。15% 税下止盈需 ≥ +17.6% 价差才回本，宁缺毋滥；历史统计不代表未来
- **通知去重**（notify-policy，live/monitor 共用）：首次出现立即通知；信号切换需连续 2 轮确认（分钟级数据在分位边界抖动防刷屏）；同信号 6 小时冷却；BUY 冷却期内价格再跌 5% 立即再报
- **纯静态部署不白屏**：页面吃构建时快照并如实标注「数据已 X 分钟未更新」与来源；时效阈值按 source 分档（moligod 10/30 分钟，kkrb 沿用 60/360 分钟）。静态环境（探测不到服务端）自动轮询退回 30 分钟、且仅在版本前进时才提示「已更新」，不对静态主机打每分钟无效流量。线上快照由服务器上 serve 进程内的抓取循环持续刷新（见「部署」）；要 SSE 级实时用 `npm run serve` 自托管模式
- 页面含：买入信号卡（买入价 / 挂卖价 / 税后到手 / 预赚每发与收益率）、卖出高位简表、全表筛选排序、自选星标、每行 7 天走势 sparkline、点击行展开大图（P25/P75 参考线）；本地 dev 且 live 服务在跑时页头显示「实时通道已连接」
- 页尾 **PLAYBOOK 倒卖手册**（`apps/web/src/views/ammo/Playbook.vue`，静态内容；iOS 端同一份文案）：社区攻略整理的实操动线——一天内买卖时段（凌晨扫货 / 午休上架 / 晚间出货）、买入选品与军需处倒挂、挂单定价技巧（删位法 / 柱状图法 / 分批抛）、版本赛季窗口套利、卡邮件当临时仓库（含 30 天期限与封号风险警示）、变现红线与费率口径说明，附来源链接
- `data/ammo/`（历史快照与监控状态）已 gitignore，不入库；留档仅指纹变化且 ≥10 分钟才写一份，超 7 天或 1000 份自动清理
- **live / monitor / 手动 ammo:fetch 同为写盘者，同时只跑一个**（不互斥，同时跑会互相覆盖且通知可能重复）

## 全品类异动雷达页（/#/radar）

子弹以外品类（钥匙 / 护甲 / 配件 / 物资 / 枪械）的异动监控：kkrb「全物品价格变化曲线」的**涨幅榜 Top10** 当异动雷达，逐项补 moligod 全品类小时曲线 + 分钟级现价，用与子弹页完全相同的分位数回归口径（P25 买入 / P80 卖出 / 税后 ≥8%；非子弹无税后字段，税率兜底 15%）出信号，macOS 通知去重复用 notify-policy。

```bash
npm run radar:fetch     # 单轮抓取 + 分析，落盘 apps/web/public/market/radar.json
npm run radar:monitor   # 常驻监控（默认 30 分钟一轮，--interval N 可调；--no-notify 仅停通知）
npm run radar:selftest  # 纯逻辑离线自测（不打外网）
```

- **扩品类数据源（2026-10-14 实测验证）**：异动清单来自 kkrb `getHIPriceCurveData`（免登录免配额，自带 7 天小时曲线）；曲线主源 moligod `/api/market/history?lookup=name` **不限品类**（航天冷却剂 / 雷达侧门钥匙等均返回 168 点小时曲线，`interval=1m` 可拿到分钟级现价）。moligod 的全物品快照 `trade-house-snapshot` 为前端加密接口，未使用；kkrb 单物品曲线查询未登录配额为 0，同样未使用。榜单物品名另经**官方物品目录**（`server/official/object-directory.mjs`：腾讯 AMS `object.list` 缓存，TTL 24h，仅 gun/ammo/protect 三类）做存在性校验并登记 objectID 与官方均价，审计落 `data/market/radar-name-audit.json`（`{fetchedAt, hits:[{name,objectID,officialAvgPrice}], misses:[name], retried:[{from,to,points}]}`，随 `data/` 已 gitignore）；仅当 moligod 1h 曲线为空且官方名与榜单名归一化同名而写法不同（如官方 `7.62*39mm` ↔ 社区 `7.62x39mm`）时用官方名重查一次曲线，其余查询仍用榜单原名；目录不可用整轮跳过校验，`radar.json` 契约、双源异常判定与通知行为零变化，雷达自身零新增官方请求。注意目录域（枪/弹/甲）窄于涨幅榜的全品类，物资 / 配件 / 钥匙类未命中属预期

## 特勤处制造页（/#/craft）

工作台 / 防具台 / 技术中心 / 制药台全量配方（当前 230 条）的实时利润估算：材料与产出按分钟级现价、上游算好「材料现价买入 → 产出按现价 × 数量挂卖 → 扣手续费」的预估成本 / 收入 / 净利润，服务端再派生**时利**（每小时利润）与**成本回报率**。页面给出「时利最佳」主推荐（价格完整的配方中时利最大——制造台同一时间只能跑一条，时利才是真实约束）+ 各台最佳速览 + 可排序 / 筛选 / 搜索的利润榜单（行展开看材料明细与利润拆解公式）。iOS 端为第五个 Tab「制造」（榜单 + 最佳卡 + 配方详情）。

```bash
npm run craft:fetch     # 单轮抓取 + 整形，落盘 apps/web/public/craft/craft.json
npm run craft:monitor   # 常驻监控（默认 10 分钟一轮，--interval N 可调）
npm run craft:selftest  # 纯逻辑离线自测（不打外网）
```

- 数据源：moligod 特勤处制造页同名接口 `/api/market/special-ops-snapshot`（2026-10-23 实测验证）。响应体为公开传输编码（非鉴权，密钥随每个响应头 `x-special-ops-key` 下发）：`0x01` + 12B IV + AES-256-GCM 密文（尾附 16B tag），密钥 = SHA-256(响应头)，AAD = `special-ops-snapshot-v1`，明文再套 gzip——`server/craft/snapshot.mjs` 内 Node 同构解码，上游若撤编码（明文 JSON 直出）零改动兼容
- 利润口径为估算值：制造期间价格波动、挂单深度与实际成交均会造成偏差；今日 / 7 日最高利润为乐观参照，页面上如实标注
- **双源交叉验证（真实性闸门）**：同一物品 kkrb 与 moligod 曲线在重叠小时上的**中位偏差** >15% 判「双源异常」——信号强制观望、不发通知（口径分歧时宁可漏报；实测曾抓到名称撞旧赛季数据、偏差 85% 的案例）。重叠不足 24 小时不做结论，如实标「样本 N」
- **物品名以榜单为准**：moligod 按名查曲线，名称不精确会拿到旧赛季数据或空曲线（「D1钥匙」「重型突击背片」均有踩坑），一律从 kkrb 榜单/建议框取名
- **请求量**：每轮 1 次 kkrb 榜单 + 每物品 2 次 moligod（1h + 1m）+ 400ms 间隔 ≈ 21 请求/轮，30 分钟一轮负载可忽略
- 页面：榜单表（榜单名次 / 品类标签 / 信号 / 预赚每件 / 7 天分位条 / 周区间 / 走势 / 双源偏差），行点击展开 P25/P75 大图；双源异常行 ⚠ 标记并可单独筛出
- `data/market/`（监控状态）已 gitignore；与 ammo 管线互不写同一文件，可并行跑

## 目录

- `package.json` — 仓库根 Node 工程：网页端构建依赖 + 全部 npm 脚本（名字不变，内部指向 `apps/web` 与 `server/`）
- `apps/web/` — 网页端：`index.html` / `vite.config.js`（`@shared` 别名指向仓库根 `shared/`）、`src/`（Vue 视图、组件、样式设计令牌与数据，自 `legacy/` 迁移完成）、`public/`（构建时原样拷入 dist 的静态资源：`ammo/market.json` 行情快照、`market/radar.json` 雷达快照、`craft/craft.json` 特勤处制造快照、`guns/` 枪械图）；构建产物 `apps/web/dist/`（`figs/` 地图时代图片已删，原始高清版留档于仓库根 `assets/`）
- `apps/ios/` — iOS 原生端（Swift 6 + SwiftUI）：`project.yml`（xcodegen）、`DeltaForce/`（App 壳）、`Packages/DeltaForceCore/`（纯逻辑内核 + Swift Testing 单测）；说明见 [apps/ios/README.md](apps/ios/README.md)
- `server/` — Node 后端（零 npm 依赖）：`server.mjs` 同源站点（静态托管 + 抓取循环 + SSE）、`refresh-data.mjs`、`export-ios-data.mjs`（跨端数据导出）、`smoke.mjs`（构建产物浏览器冒烟）、`extract-*.mjs`（一次性抽取留档）
  - `server/ammo/` — 子弹行情抓取 / 分析 / 监控：moligod-client（主源）/ kkrb-client（兜底源）/ analyze / notify / fetch-once / monitor / live（SSE 本地服务）/ selftest（离线自测）；通知去抖用 `shared/js/notify-policy.js`
  - `server/market/` — 全品类异动雷达：radar（kkrb 涨幅榜 + moligod 全品类曲线 + 双源交叉）/ selftest（离线自测）；复用 `server/ammo/` 的 analyze / moligod-client / kkrb-client，去抖同引 `shared/js/notify-policy.js`
  - `server/craft/` — 特勤处制造：snapshot（moligod special-ops 快照解码 + 整形 + 时利派生 + 落盘）/ selftest（离线自测，含传输编码往返）
  - `server/auth/` — 账号与云同步：store（scrypt 密码 + HMAC 无状态令牌 + 原子落盘 `data/auth/`）/ api（`/api/auth/*`、`/api/account/data`，挂 server.mjs 同进程）/ selftest（离线自测）
- `shared/` — 跨端共享层：`API.md` 接口契约、`schema/`（market / radar 快照与 SSE 事件的 JSON Schema）、`js/`（sellEta / marketMeta / liveChannel 纯函数，网页端与后端共用）、`data/ttk.json` 与 `fixtures/*.json`（`npm run export:ios` 产出，iOS 捆绑 + 单测样本）
- `deploy/` — systemd 单元、nginx 示例、`update.sh` 一键更新（含单元文件自动同步）、阿里云部署文档
- `legacy/` — 旧单文件页留档：`index.html`（含全部数据与图片）、`ttk.html`（TTK 排行）、`shaders.iife.js`（WebGPU 特效库；只读留档，运行时副本 `apps/web/src/vendor/` 已删除，现仅存于此）
- `assets/<地图>/hotspots.json` — 各图点位标定数据留档
- `assets/` 其余 — 各图原始高清底图留档

## 版权

游戏素材（底图瓦片等）版权归腾讯/天美所有。本项目仅供个人学习参考，请勿用于商业用途。
