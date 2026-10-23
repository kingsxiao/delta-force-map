# 三角洲行动 · 高清地图与打法详解

多端 monorepo：**网页端**（Vite + Vue 3，`apps/web`）+ **iOS 原生端**（Swift 6 + SwiftUI，`apps/ios`）+ **Node 后端**（`server/`，静态托管 + 行情抓取 + SSE）+ **跨端契约与共享逻辑**（`shared/`）。内容：烽火地带六张地图（零号大坝 / 长弓溪谷 / 巴克什 / 航天基地 / 潮汐监狱 / AZ3核电站）的高清标注大图 + 实战打法 + 物资爆率参考、**枪械 TTK 击杀时间排行**页（全枪械 7 兵种 × 各级弹药与护甲）、**子弹行情实时监控**页（交易行子弹的买卖点与税后利润，主源分钟级 + SSE 实时通道），以及**全品类异动雷达**页（子弹以外的钥匙 / 护甲 / 配件 / 物资涨幅榜 + 分位信号 + 双源交叉验证）。`legacy/` 旧单文件页已整体完成组件化迁移，仅作只读留档。

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
  雷达循环默认 10 分钟，均带 kkrb 兜底）→ 原子写快照 → 静态托管 `apps/web/dist` + `/events` SSE
  推送（`market` / `radar` 两个事件，两个页面都实时），页面端到端延迟 = 源分钟粒度 +
  60s 快轮询 + 5s。站点与 SSE 同源，https 反代（nginx / caddy）即可上线；系统通知默认
  关闭，`--notify` 开启；雷达节奏 `--radar-interval N` 可调。iOS 端连的也是这同一个服务。
  **云服务器部署**（阿里云 ECS 等）见 [deploy/aliyun.md](deploy/aliyun.md)：systemd 常驻 +
  nginx https 反代 + 一键更新脚本，`deploy/` 目录里有现成物料。服务器上执行
  `deploy/update.sh` 即可完成本次 monorepo 迁移（脚本会自动同步 systemd 单元里的
  `ExecStart=node server/server.mjs` 并 daemon-reload）。

- 路由为 **hash 模式**（`/#/`、`/#/tactics`、`/#/ttk`、`/#/ammo`、`/#/radar`），静态托管零配置；页内锚点一律 `scrollIntoView`，禁止向 hash 写入裸锚点。
- 旧单文件页（`index.html`、`ttk.html`、`shaders.iife.js`）已挪到 **`legacy/`** 留档（只读，不再维护）；特效库的运行时副本在 `apps/web/src/vendor/shaders.iife.js`，由特效组件动态 import。
- 静态目录为默认的 **`apps/web/public/`**（dev 于 `/` 下访问、build 原样拷入 dist 根）；仓库根 `assets/` 原图为制作期留档，运行时不引用。

## 特效层验证

`server/verify-effects.mjs` 自包含、零 npm 依赖，只 spawn headless Chrome，**不拉起 dev server**。使用流程：

```bash
npm run dev                                                # 终端 1
node server/verify-effects.mjs http://localhost:5173/ shots   # 终端 2（reduced 模式加 --reduced）
```

verify 依赖的 DOM 契约（页面迁移时必须保持；`.hs`/`.map-section` 判据由脚本启动时从源数据动态求和，不冻结数字）：

- `.map-section` 个数 = `apps/web/src/data/maps` 图数（当前 6）、`.hs` 个数 ≥ `apps/web/src/data/hotspots` 全部点位总数（当前 166）
- `button[data-act="full"]`（地图卡「全屏查看」按钮）
- `#fxHero`、`#fxLb`（特效画布）、`#lbClose`（灯箱关闭按钮）
- `document.documentElement` 的 `locked` 类随灯箱开关加 / 删
- `<html data-fx>` ∈ { on, off, fallback, unsupported, reduced }

## 功能

- **账号与云同步**（两端，`/#/account` / iOS 设置 → 账号）：注册 / 登录 / 登出（token 存网页 localStorage、iOS Keychain），**自选星标 + 囤货台账云同步**——登录后云端与本地合并（星标并集 / 台账按弹名并集·同名本地优先），任何一端的数据都不丢，登录期间改动自动上云（防抖 2s）。口径见 [shared/API.md](shared/API.md) §6：账号数据是不透明 K/V 文档（≤64KB，服务端只存不解析，落 `data/auth/`），密码 scrypt 哈希、令牌 HMAC 签名 30 天有效、登出 = 全设备下线；按 IP 限速防爆破。云端只存「用户创作内容」（自选、台账这类丢了会心疼的），不存设备偏好（通知开关等每台设备自己的）。
- **页内交互地图查看器**：拖拽平移、滚轮以光标为中心缩放（1–7x）、双击放大、+/−/复位按钮、触屏单指拖动与双指捏合、键盘操作
- **166 个可点击标注**：出生点 / 撤离点 / Boss / 高价值物资点，四类分层可开关，点击弹出要点信息卡
- **逐出生点打法卡**：每个出生点四块——打法思路 / 需要注意 / 能抽过点的位置 / 哪里要封烟
- 撤离点条件、资源搜刮路线、Boss 情报、实战建议
- 每图物资点爆率表（社区统计口径）

## TTK 排行页

- **68 把武器 × 20 种口径 × 93 种弹药**的 TTK / BTK 排行（步枪 / 冲锋枪 / 射手步枪 / 狙击枪 / 轻机枪 / 霰弹枪 / 手枪），可切目标部位（胸 / 腹 / 头）、护甲等级（无甲 ~ 6 级）与子弹筛选（每枪最佳 / 全部组合 / 按穿透等级 0-7 级），每枪可展开全部弹药的逐发模拟对比
- **穿透 × 护甲判定矩阵**（0% / 50% / 75% / 100% 国服社区实测口径）与弹药库全表
- 计算口径：100 血单血池、部位倍率、碎甲 k 值规则、TTK = (BTK−1)×60000/RPM，全部假设与来源在页内注明

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
- **买卖口径（不变）**：近 7 天每小时价格曲线分位数回归——当前价 ≤ P25 且税后收益率 ≥ 8% 判「买入」，≥ P80 判「卖出」；目标挂卖价取 P75，税率按税后价实测反推（约 15%，逐弹计算；moligod 无税后字段时回退 15%）
- **通知去重**（notify-policy，live/monitor 共用）：首次出现立即通知；信号切换需连续 2 轮确认（分钟级数据在分位边界抖动防刷屏）；同信号 6 小时冷却；BUY 冷却期内价格再跌 5% 立即再报
- **纯静态部署不白屏**：页面吃构建时快照并如实标注「数据已 X 分钟未更新」与来源；时效阈值按 source 分档（moligod 10/30 分钟，kkrb 沿用 60/360 分钟）。静态环境（探测不到服务端）自动轮询退回 30 分钟、且仅在版本前进时才提示「已更新」，不对静态主机打每分钟无效流量。线上快照由 CI 定时任务自动刷新（见「部署」）；要 SSE 级实时用 `npm run serve` 自托管模式
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

- **扩品类数据源（2026-10-14 实测验证）**：异动清单来自 kkrb `getHIPriceCurveData`（免登录免配额，自带 7 天小时曲线）；曲线主源 moligod `/api/market/history?lookup=name` **不限品类**（航天冷却剂 / 雷达侧门钥匙等均返回 168 点小时曲线，`interval=1m` 可拿到分钟级现价）。moligod 的全物品快照 `trade-house-snapshot` 为前端加密接口，未使用；kkrb 单物品曲线查询未登录配额为 0，同样未使用
- **双源交叉验证（真实性闸门）**：同一物品 kkrb 与 moligod 曲线在重叠小时上的**中位偏差** >15% 判「双源异常」——信号强制观望、不发通知（口径分歧时宁可漏报；实测曾抓到名称撞旧赛季数据、偏差 85% 的案例）。重叠不足 24 小时不做结论，如实标「样本 N」
- **物品名以榜单为准**：moligod 按名查曲线，名称不精确会拿到旧赛季数据或空曲线（「D1钥匙」「重型突击背片」均有踩坑），一律从 kkrb 榜单/建议框取名
- **请求量**：每轮 1 次 kkrb 榜单 + 每物品 2 次 moligod（1h + 1m）+ 400ms 间隔 ≈ 21 请求/轮，30 分钟一轮负载可忽略
- 页面：榜单表（榜单名次 / 品类标签 / 信号 / 预赚每件 / 7 天分位条 / 周区间 / 走势 / 双源偏差），行点击展开 P25/P75 大图；双源异常行 ⚠ 标记并可单独筛出
- `data/market/`（监控状态）已 gitignore；与 ammo 管线互不写同一文件，可并行跑

## 数据说明

- 点位坐标来自官方地图工具公开数据；打法与爆率整理自社区公开资料（官方工具、wiki、图文与视频攻略），**未在游戏内逐条实测**
- 爆率为社区统计口径（S/A/B 分级 + 定性排名），官方从未公布精确百分比，可能与实际掉落有出入
- 数据基线 2026-08 ~ 2026-10，版本更新后以游戏内战术地图为准

## 目录

- `package.json` — 仓库根 Node 工程：网页端构建依赖 + 全部 npm 脚本（名字不变，内部指向 `apps/web` 与 `server/`）
- `apps/web/` — 网页端：`index.html` / `vite.config.js`（`@shared` 别名指向仓库根 `shared/`）、`src/`（Vue 视图、组件、样式设计令牌与数据，自 `legacy/` 迁移完成）、`public/`（构建时原样拷入 dist 的静态资源：抽取出的图片、`ammo/market.json` 行情快照、`market/radar.json` 雷达快照、`guns/` 枪械图）；构建产物 `apps/web/dist/`
- `apps/ios/` — iOS 原生端（Swift 6 + SwiftUI）：`project.yml`（xcodegen）、`DeltaForce/`（App 壳）、`Packages/DeltaForceCore/`（纯逻辑内核 + Swift Testing 单测）；说明见 [apps/ios/README.md](apps/ios/README.md)
- `server/` — Node 后端（零 npm 依赖）：`server.mjs` 同源站点（静态托管 + 抓取循环 + SSE）、`refresh-data.mjs`、`export-ios-data.mjs`（跨端数据导出）、`verify-effects.mjs` / `smoke.mjs`（浏览器验证）、`extract-*.mjs`（一次性抽取留档）
  - `server/ammo/` — 子弹行情抓取 / 分析 / 监控：moligod-client（主源）/ kkrb-client（兜底源）/ analyze / notify / fetch-once / monitor / live（SSE 本地服务）/ selftest（离线自测）；通知去抖用 `shared/js/notify-policy.js`
  - `server/market/` — 全品类异动雷达：radar（kkrb 涨幅榜 + moligod 全品类曲线 + 双源交叉）/ selftest（离线自测）；复用 `server/ammo/` 的 analyze / moligod-client / kkrb-client，去抖同引 `shared/js/notify-policy.js`
  - `server/auth/` — 账号与云同步：store（scrypt 密码 + HMAC 无状态令牌 + 原子落盘 `data/auth/`）/ api（`/api/auth/*`、`/api/account/data`，挂 server.mjs 同进程）/ selftest（离线自测）
- `shared/` — 跨端共享层：`API.md` 接口契约、`schema/`（market / radar 快照与 SSE 事件的 JSON Schema）、`js/`（sellEta / marketMeta / liveChannel 纯函数，网页端与后端共用）、`data/ttk.json` 与 `fixtures/*.json`（`npm run export:ios` 产出，iOS 捆绑 + 单测样本）
- `deploy/` — systemd 单元、nginx 示例、`update.sh` 一键更新（含单元文件自动同步）、阿里云部署文档
- `legacy/` — 旧单文件页留档：`index.html`（含全部数据与图片）、`ttk.html`（TTK 排行）、`shaders.iife.js`（WebGPU 特效库；只读，运行时以 `apps/web/src/vendor/` 副本为准）
- `assets/<地图>/hotspots.json` — 各图点位标定数据留档
- `assets/` 其余 — 各图原始高清底图留档

## 版权

游戏素材（底图瓦片等）版权归腾讯/天美所有。本项目仅供个人学习参考，请勿用于商业用途。
