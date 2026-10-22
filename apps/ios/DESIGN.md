# iOS 端设计规范 v1.0（2026-10）

> 品牌基准：`apps/web/src/assets/styles/base.css`（设计规范 v2.2「深色战术指挥台」）+ `DeltaForce/App/Theme.swift`。
> 本规范是**精修不是换血**：色板、深色锁定、令牌化方向全部延续现状，只解决两份审计（交互 13 项 + 视觉 14 项）暴露的权重倒挂、双轨字阶、三套范式、反馈闭环缺口。
> 硬约束（全程有效）：`State/` 与 `Packages/DeltaForceCore/` 一律不动；不引第三方依赖；共享组件只新增 API 或优化默认实现、禁止破坏现有调用点；iOS 17+ API。
> 优先级定义：**P0** 本轮必做 ｜ **P1** 应做 ｜ **P2** 时间富余再做。

---

## 0. 并行施工边界（4 位工程师必读）

编制 = 共享层 1 人 + 页面 3 人，覆盖全部四个 Tab + 共享详情页。**每个文件有且仅有一位 owner**：

| Owner | 施工范围（仅这些文件） |
|-------|------------------------|
| **A · 共享层 + 设置** | `App/Theme.swift`、`Features/Shared/`（Components.swift、PriceChart.swift、新增 TabIcon 资产/文件）、`App/RootView.swift`（Tab 图标）、`Features/Settings/SettingsView.swift`（设置页改动最小，与令牌同 PR 合入最顺） |
| **B · 行情 + 详情** | `Features/Ammo/`（AmmoView.swift、ItemDetailView.swift、PlaybookView.swift）。ItemDetailView 虽被雷达共用，归行情 owner 单点施工（主要入口与 `AmmoView.swift:108` 的 navigationDestination 同目录） |
| **C · 雷达** | `Features/Radar/RadarView.swift` |
| **D · TTK** | `Features/TTK/TtkView.swift`（含 GunDetailView / PenMatrixView，同文件） |

- §2（Theme.swift）、§3（Components.swift / PriceChart.swift）、§6.2（Tab 图标 + RootView.swift）由 **A** 施工；**PriceChart 的 P1–P5 全部归 A**，§4.2-5 只是 B 的验收项，不是 B 的施工项。
- 共享组件一律「新增 API 或带默认值的新参数」，现有调用点零改动可编译；各页自决何时迁移到新 API。
- 跨 owner 依赖必须经共享层新 API 表达（如 C10 `RetryErrorRow`、C11 `ConnectionDot`），**禁止为省事去改别的 owner 目录里的组件定义**——`FeedErrorView` 定义在 `AmmoView.swift:304`（B 的文件），雷达页防空转因此走 C10 新组件而非改它（见 §4.3-6）。
- 视图层允许**读** State 公开属性（`feed.lastError` / `feed.isLoading` / `feed.items` / `feed.lastRefreshAt` / `app.favorites` 等，见 `State/FeedModel.swift:16-19,78-80`）并**调用**既有方法（`refresh()` / `loadIfNeeded()`），但不得改写任何 State 文件。

---

## 1. 设计方向（五个关键词）

### 1.1 主数字立权（Hero Number）
每屏一个无可争议的主角数字：行情=预赚/收益率、TTK=毫秒数、雷达=现价、详情=现价。主角数字用 hero/lead 档等宽字 + 语义色；输入类数据（挂卖价、税率、样本数）降一档让位。
**理由**：视觉审计 high——默认排序依据是收益率（`AmmoView.swift:12`），但它只是列表行 12pt 小字（`AmmoView.swift:219`）、SignalCard 内最小文字（`AmmoView.swift:274`），决策最关键的盈亏数字被输入数据压住。数据工具的扫读效率取决于第一眼看到的数字。

### 1.2 单一冷钢青（One Accent）
`Theme.accent`（#2DD4BF，`Theme.swift:16`，对齐 base.css `--accent`）保持全站唯一强调色：激活、选中、进行中、导航。等级色/信号色只用于游戏语义数据（等级/穿透/信号徽标、等级列），Tab、导航、通用控件一律不越界。
**理由**：base.css:7-9 的用色硬约束是品牌纪律；雷达名次整列 accent（`RadarView.swift:119`）已经稀释了「唯一强调色」，规范把 accent 从「装饰」收回「指针」。

### 1.3 战术等宽节拍（Tactical Mono Rhythm）
全部实义数字走令牌化等宽档位（hero 22 / lead 16 / sub 14 / micro 12 四档）。**档位跟随数字在页内的层级，而非数字本身**：每个列表行的主数字一律 `lead`、行内次级数字一律 `sub`、`hero` 只给页面唯一主角——跨页恒量的是「同层级同档」。因此行情行主数字=收益率（lead）、现价为次级（sub），雷达行主数字=现价（lead），两者按层级规则完全一致。
**理由**：实测 `Mono(` 显式 size 分布为 12×7 / 13×2 / 14×3 / 15×1 / 16×1 / 22×1（grep 全仓），同一个「现价」在行情行 15、雷达行 14、详情头 22 三种大小；`Theme.swift:64` 自述「全站禁止裸字号」而 Mono 本身就是裸字号通道，双轨制自相矛盾。

### 1.4 一套徽章语言（One Badge Language）
徽标四族（SignalChip / GradeBadge / PenBadge / CategoryChip）合一配方：文字=语义色、底=同色 12%、描边=同色 40%、内边距 h8/v2；圆角按语义二分——状态类=胶囊、属性类=方角 6。
**理由**：现状四族三种配方并存（仅描边 `Components.swift:42`、仅填充 `:60`、填充+描边 `:23-24`、实底 `:82`），同行并置时粗细轻重不齐；PlaybookView 还有第四种 7/1 内边距的做法（`PlaybookView.swift:75-76`）。

### 1.5 闭环反馈（Closed-Loop Feedback）
每个主动作（下拉刷新/筛选切换/拖动查值/自选）都要有「可见结果 + 可触结果」：刷新成败二分触感与可见提示、数据年龄即时归零、换筛选回顶、查值逐点触感。
**理由**：交互审计 medium 群像——刷新触感不分成败（`AmmoView.swift:109-114`）、错误提示在视野外、年龄行滞后 30s（`Components.swift:246`）、换筛选不回顶。行情工具的信任感来自每个动作都有回声。

---

## 2. Theme.swift 令牌增改清单（共享层 owner A 施工）

全部为**新增**，现有令牌与签名一律不改（引用行号为 `App/Theme.swift` 现状）：

| # | 条目 | 内容 | 依据 |
|---|------|------|------|
| T1 | `enum MonoStep` | `hero(22, bold) / lead(16, semibold) / sub(14, semibold) / micro(12, medium)`；提供 `init(nearest raw: CGFloat)` 兼容映射：22→hero，15/16→lead，13/14→sub，12→micro | 视觉审计「数字字阶双轨制」；收敛 6 档→4 档 |
| T2 | `Mono` 组件新增 `init(_ text:, step:, weight:, color:, relativeTo:)` | 现有 `init(size:)`（`Theme.swift:144-155`）保留原行为作为兼容通道并注释「新代码禁用」；默认实现不变，现有调用点零改动 | 硬约束：不破坏调用点 |
| T3 | `Mono` 组件新增可选 `minScale: CGFloat? = nil` 参数 | 非 nil 时套 `.minimumScaleFactor(minScale)` + `.lineLimit(1)`；详情现价等溢出高危位使用 | 交互审计 low（头部 22pt 现价被截断风险） |
| T4 | 色彩令牌：`accentDim = accent.opacity(0.38)`、`accentSoft = accent.opacity(0.62)`、`accentBg = accent.opacity(0.09)` | 仅供描边 / hover 面 / 强调底，禁止作文字色（与 base.css:41-44 同纪律） | base.css:41-44 有、iOS 缺 |
| T5 | `line2 = Color(hex: 0x1F262E)`、`lineHover = Color(hex: 0x39434F)` | 弱分隔线（Divider overlay 现用 `Theme.line` 偏重）、可点卡片描边提亮 | base.css:26-27 |
| T6 | `edgeLight = Color.white.opacity(0.04)` | CardModifier 顶缘微高光（见 §3 C9） | base.css:72-73 三层卡片手法，iOS 现缺第三层 |
| T7 | `lift = Color.white.opacity(0.06)` | 按压面（自定义 ButtonStyle 用），对齐 base.css `--lift` | base.css:71 |
| T8 | `enum Space { xs=4, sm=8, md=12, lg=16, xl=24 }` | 间距阶梯对齐 base.css:95-104；**行内垂直间距统一 xs(4)**、徽标行横向 6、卡内 sm(8)、区块间 md(12)。收编现状 2/3/4 混用（Ammo 4/3、Radar 4/3、TTK 3/2、GunDetail 2/2） | base.css 间距纪律在 iOS 行内没有对应物 |
| T9 | `radiusBadge=6 / radiusTile=8 / radiusCard=12` | 收编散落的 `cornerRadius: 6/8/12` 字面量（`Components.swift:42,60,336`、`Theme.swift:121-122` 等） | base.css:106-110 |
| T10 | 动效令牌：`durFast=0.15 / durMed=0.22`、`easeOutQuad = .easeOut(duration:)` 惯例 | 微交互 ≤220ms，对齐 base.css `--t-fast/-slow` | base.css:117-121 |
| T11 | `CardModifier` 默认实现优化：加 `edgeLight` 顶缘高光 overlay（inset 0 1）；新增带默认值参数 `hoverable: Bool = false`（true 时描边换 `lineHover`，供可点卡片） | 不改调用点即获得第三层层次 | base.css:72-73；视觉审计 low（卡片层次少一层、可点卡片无按压差异） |

**迁移约定**：T1-T3 合入后，各页面工程师把本页 `Mono(size:)` 调用迁到 `Mono(step:)`（页面条目内列出）；迁移完成前新旧通道并存，渲染结果一致。

---

## 3. Components.swift / PriceChart.swift 组件升级清单（共享层 owner A 施工）

### Components.swift

| # | 条目 | 优先级 | 说明 |
|---|------|--------|------|
| C1 | 徽标配方统一 | P0 | 四族合一（§1.4）：GradeBadge 补 12% 底（现仅描边，`Components.swift:42`）、PenBadge 补 40% 描边（现仅底，`:60`）、CategoryChip 从 card2 实底改为 `dim` 色 10% 底 + 30% 描边、SignalChip 保持胶囊双涂层不变。`lineLimit(1)+fixedSize` 单行纪律与既有 a11y 行为保持 |
| C2 | 新增 `StatusChip(text:tint:)` | P0 | 状态语义胶囊（胶囊圆角、12% 底 + 40% 描边、h8/v2），供 PlaybookView 时间窗标签（现 7/1 第四种做法，`PlaybookView.swift:75-76`）与雷达态势计数（§4.3-1）复用 |
| C3 | SignalChip 异常态去 Unicode | P0 | 「⚠ 双源异常」（`Components.swift:14`）改为 `exclamationmark.triangle` SF Symbol +「双源异常」文本（图标 10pt 同色、`accessibilityHidden`）。U+26A0 无变体选择符可能渲染成彩色 emoji，破坏「信号色唯一来源 Theme」纪律；与 `RadarView.swift:27` 的 SF Symbol 统一同源 |
| C4 | StatCell 加 `emphasis` | P0 | 新增 `enum Emphasis { plain, hero }` 参数默认 `.plain`（现行为不变）；`.hero` 时数值走 `MonoStep.lead` + `minimumScaleFactor(0.8)`。供「主数字立权」条目把关键格升档 |
| C5 | 新增 `StatQuadRow` | P1 | 把 `ItemDetailView.swift:101-109` 私有 `statQuad`（ViewThatFits 4→2×2 降级）提为共享组件；详情页与 GunDetailView（`TtkView.swift:203-211` 现无降级）共用。详情页原私有实现由行情 owner（B）删除并改调用，TTK 调用点由 D 落地 |
| C6 | FeedHeader 年龄即时归零 | P1 | TimelineView 挂 `.id()`，**id 绑 `feed.snapshot?.version` 与 `feed.lastRefreshAt` 的组合值**（如 `"\(version)-\(lastRefreshAt.timeIntervalSince1970)"`）。只绑 version 不够：`State/FeedModel.swift:60` 的 changed 判断明确处理「version 不变、fetchedAt 前进」的同版本重拉（此时 version 不变、id 不变、视图不重建，恰好漏掉要消灭的滞后），而 `lastRefreshAt` 在每次成功刷新后都会更新（`:63`，公开属性 `:19`）。任一前进即重建视图、以当前时间重算年龄，30s 周期兜底保留。纯视图改动，不动 FeedModel（`Components.swift:246-264`） |
| C7 | FeedHeader 错误行升格 | P1 | `lastError` 行（`Components.swift:271-275`）从纯文本改为 danger 图标 + danger 8% 底胶囊行，保证断网时在列表顶部可一眼看到（配合 §5 刷新二分触感） |
| C8 | FilterChipLabel 降级 | P1 | chip 行加 ViewThatFits：正常 caption+value 单行；特大字号/窄屏时 value 允许 2 行或缩排，不再压成「护甲 …」（`Components.swift:144` 现 lineLimit(1)；交互审计 medium） |
| C9 | Sparkline 统一规格 | P2 | 尺寸统一 **56×26**（行情 `AmmoView.swift:225` 现值；雷达 `RadarView.swift:146` 50×24 由雷达工程师对齐——组件不动，写进页面条目）。此条仅记录决议，组件无改动 |
| C10 | 新增 `RetryErrorRow(message:, retry:, busy: Bool = false)` | P1 | 带重试的错误行组件（C7 错误胶囊样式同款 + `busy` 为 true 时按钮禁用并显示内联 ProgressView）。**为什么不改旧 FeedErrorView**：它定义在 `AmmoView.swift:304`（行情 owner 的文件），雷达/设置 owner 无权改；且直接在 Components.swift 新增同名组件会与旧定义冲突。**合入顺序（安全序，不可倒置）**：① A 新增 `RetryErrorRow` → ② C 换雷达调用点（`RadarView.swift:38`）为新组件并传 `busy: app.radar.isLoading`（旧 FeedErrorView 仍在，编译通过）→ ③ B **最后**删除 `AmmoView.swift` 内旧 FeedErrorView 定义并换行情调用点（§4.1-6）。倒置会在 ②③ 之间留下编译红窗口：B 先删定义、C 未换调用点时 `RadarView.swift:38` 引用不存在的类型；若 B、C 无法保证先后，两条必须同 PR 合入。注意：步骤 ①-③ 期间各 owner 均有可做的独立工作，但「删旧定义」这一步必须等 C 的换用合入后（或同 PR），不存在全序皆安全的排列 |
| C11 | 新增 `ConnectionDot(state: LiveChannel.State, error: Bool = false, stale: Bool = false)` | P1 | 连接状态小组件（8pt 圆点 + state.label 文案）。着色规则与 `Components.swift:287-291` FeedHeader.dotColor 逐步对齐：`state.isLive && !stale` → ok；`error` → danger；其余 → faint。**签名必须带 `error`/`stale` 两个带默认值参数**——LiveChannel.State 六态（idle/probing/connecting/live/reconnecting/unavailable，`State/LiveChannel.swift:11-17`）没有 error 态，dotColor 的 danger 分支来自 `feed.lastError != nil`（`Components.swift:289`）、ok 分支还要求 `!feed.isDotStale(now:)`（`:288`），单参签名承载不了这两个维度：既无输入来源实现 danger，也不能让 FeedHeader 无观感变化地复用。调用方式：SettingsView 只传 `state`（§4.5-2，默认 error/stale 均为 false：live 显 ok、其余 faint）；FeedHeader 由 A 传全参复用（`error: feed.lastError != nil, stale: feed.isDotStale(now: ctx.date)`），观感与现状逐分支等价。dotColor 现为 private，本条把它提为共享 API |

### PriceChart.swift

| # | 条目 | 优先级 | 说明 |
|---|------|--------|------|
| P1 | 拖动查值逐点触感 | P0 | `.sensoryFeedback(.selection, trigger: selected?.id) { _, new in new != nil }`——选点跨数据点时轻「咯哒」。**condition 必须带**：`PriceChart.swift:115` 的 onEnded 把 selected 置 nil，`selected?.id` 从非 nil 变 nil 同样是一次 trigger 变化，不带条件抬手会多一声咯哒，与意图不符（iOS 17 的 `sensoryFeedback(_:condition:trigger:)` 形态；trigger 绑图内局部 state，遵守现有触感纪律） |
| P2 | 十字线气泡淡入 | P1 | 选中态 RuleMark + annotation 以 `.easeOut(durFast)` opacity/scale 0.98 过渡出现，抬手消失同速（`PriceChart.swift:77-93` 现瞬现瞬隐）。Swift Charts annotation 对 transition 支持有限，实现不了过渡时允许降级为瞬现并在此注明 |
| P3 | 标注字号收编 | P1 | P25/P75/现价/气泡内数字全部迁 `MonoStep.micro`（`PriceChart.swift:74,86`） |
| P4 | VoiceOver 逐点听值 | P1 | 图表在现有摘要 label（`PriceChart.swift:120-121`）之上加 `.accessibilityAdjustableAction`：上下滑动逐点朗读「M月d日 HH:mm，价格 X」，起点为最新点。补齐「查任意时刻价格」对视障用户的缺失（交互审计 low） |
| P5 | 现价标注联动 | P2 | 现价 PointMark 加呼吸/高亮不做——保持克制，仅把 annotation 数字与详情头部 hero 数字同源（详见 §4.2-8 contentTransition） |

---

## 4. 四个页面改造条目

### 4.1 行情（AmmoView，含 SignalCard）

| # | 条目 | 优先级 |
|---|------|--------|
| 1 | **列表行权重反转**：右列改为「收益率/预赚」在上、`MonoStep.lead` + ok 色；现价降 `sub` 档 tx 色在下。默认排序=收益率，扫读第一行就是排序依据（`AmmoView.swift:216-221` 现为现价 15pt / 预赚 12pt 倒挂；视觉审计 high）。a11y 成句 label 语序同步对齐视觉顺序 | P0 |
| 2 | **SignalCard 主数字立权**：「预赚 +X/发」与收益率升 `lead` 档 ok 色加粗；买入≤/挂卖/到手三格降 `sub`；卡片保留 RankBar 与 ETA 行不动（`AmmoView.swift:264-275`） | P0 |
| 3 | **刷新反馈二分**：`refreshable` 完成后读 `app.market.lastError`——成功 `.success` 触感 + 年龄行归零（C6）；失败 `.error` 触感 + FeedHeader 错误胶囊（C7）短暂强调。替换现无条件 `.impact(light)`（`AmmoView.swift:109-114`；交互审计 medium） | P0 |
| 4 | **筛选/排序切换回顶**：对齐 TTK 方案——`onChange(of: filter/sort)` 里 `withAnimation(Theme.durMed)` + `scrollTo` 列表榜首锚点（TTK 参考 `TtkView.swift:139-142`）。换筛选=换榜单，不再停在长列表深处 | P1 |
| 5 | **搜索栏呈现统一**：保持 `.navigationBarDrawer(displayMode: .always)` 常驻（`AmmoView.swift:106`），TTK 侧对齐过来（§4.4-6）。数据密集工具常驻搜索是跨 Tab 恒量 | P1 |
| 6 | **FeedErrorView 重试防空转**：调用点换共享层新组件 `RetryErrorRow(message:retry:busy:)`（C10），传 `busy: app.market.isLoading`——加载中禁用 + 内联 ProgressView，结束后可点。消除「点了没反应」的空转（`AmmoView.swift:56-60`；`FeedModel.refresh` 的 isLoading 守卫在 `State/FeedModel.swift:55`，只读不改）。同时由 B（行情 owner）删除 `AmmoView.swift:304` 的旧 FeedErrorView 定义——**须在 C 的雷达换用（§4.3-6）合入之后或同 PR**（旧定义被 RadarView.swift:38 引用，先行删除会留下编译红，见 C10 安全序） | P1 |
| 7 | **可点卡片按压态**：SignalCard 所在 NavigationLink 套自定义 ButtonStyle：按压 `lift` 面 + 描边 `lineHover`（T5/T7/T11）；选中态不引入 accentBg（卡片非持久选中）。提升「这是入口」的可发现性（视觉审计 low） | P2 |
| 8 | **买入信号区滚动条**：横滑信号卡区加 `.scrollClipPadding` 视觉出血 + 首卡 `lineHover` 描边暗示可滑。非必须，P2 | P2 |

### 4.2 详情页（ItemDetailView + PriceChart，行情/雷达共享，归行情 owner B 单点施工；PriceChart.swift 归共享层 owner A）

| # | 条目 | 优先级 |
|---|------|--------|
| 1 | **数据解冻（本轮最高价值）**：`ItemDetailView`（`ItemDetailView.swift:7` 现按值冻结在 push 时刻）在视图层解析实时条目：`app.market.items.first(where: { $0.name == item.name }) ?? app.radar.items.first(...) ?? item`，body 全部走 resolved 值。60s 轮询 / SSE 版本前进后详情自动跟随。**不触碰 State/、不改 AmmoView/RadarView 的 `navigationDestination` 调用点**（`AmmoView.swift:108`、`RadarView.swift:89`） | P0 |
| 2 | **头部降级与 hero 数字**：徽标行 ViewThatFits（宽不足时先省略「涨幅榜 #N」chip 再省略分类 chip）；现价迁 `MonoStep.hero` + `minScale: 0.75`（T3）。现价是页面上最重要的数字，不得被截成「12…」（`ItemDetailView.swift:43-63`；交互审计 low） | P0 |
| 3 | **头部数据年龄角标**：现价下补「数据 X 分钟前 · 版本 vX」`micro` faint 行（TimelineView 30s 刷新；>5 分钟转 warn 色）。**数据源必须跟随 §4.2-1 的 resolved 命中路径**：命中 `app.market.items` 读 `app.market.ageMinutes`/版本，命中 `app.radar.items` 读 `app.radar` 同款——两路快照独立轮询、`lastRefreshAt` 各自不同（`State/FeedModel.swift:19,63`），照单数「feed」实现必然出现雷达物品挂行情年龄的错配；两路都未命中（回落到冻结 item）则显示「数据可能过期」固定文案 | P1 |
| 4 | **详情可下拉刷新**：`.refreshable { await app.market.refresh(); await app.radar.refresh() }`——只是调用既有方法，与列表页手势心智一致 | P1 |
| 5 | **PriceChart 三项升级**：逐点触感 + 气泡淡入 + VO 逐点听值（§3 P1-P4）。**施工归共享层 owner A（PriceChart.swift 在 A 的范围），本条是详情 owner B 的验收项**——验证升级后在本页拖动查值有触感、气泡有过渡、VO 可逐点听值 | P1（验收） |
| 6 | **现价数字滚动**：resolved 现价变化时 `.contentTransition(.numericText())` + `Theme.durMed`，涨跌不闪跳（iOS 17 API，见 §5） | P2 |
| 7 | **统计三组语义眉题**：三组 statQuad 上方各加 `micro` faint 眉题（参考区间 / 区间极值 / 交易测算），配合 C5 组件化；数值档位不动 | P2 |
| 8 | **徽标迁移**：头部 GradeBadge/CategoryChip 随 C1 新配方自动换装（零调用点改动，验收即可） | P0（验收） |

### 4.3 雷达（RadarView）

| # | 条目 | 优先级 |
|---|------|--------|
| 1 | **市场态势行升格**：`statsLine`（`RadarView.swift:106-109`）从 FeedHeader 第三行 faint 灰字拆出为 FeedHeader 下方一行 StatusChip 组：买入 N（ok）/ 卖出 N（danger）/ 关注 N（warn）/ 异常 N（warn）、榜单 N 项（dim）。本页唯一全局数据不再比口径说明还不起眼（视觉审计 medium；组件 C2） | P0 |
| 2 | **「只看双源异常」并入 chip 族**：整卡 Toggle（`RadarView.swift:25-32`）改为 FilterMenu 胶囊（selection: 全部/仅异常，defaultId=全部）放进态势行右侧或其下——消灭「一个布尔开关占一张卡」的密度浪费，三页筛选范式归一（视觉审计 medium） | P0 |
| 3 | **名次语言统一**：`#N` 全列 accent（`RadarView.swift:119`）改为零填充 `01` + 仅前三 accent 其余 faint（对齐 `TtkView.swift:153`）。accent 不再被整列稀释；两榜名次列符号、字号（sub 档）、着色规则跨页恒量（视觉审计 medium） | P1 |
| 4 | **右列主数字**：现价迁 `lead`、分位/偏差迁 `sub`；Sparkline 统一 56×26（`RadarView.swift:145-146` 现值 50×24）（视觉审计 low） | P1 |
| 5 | **筛选切换回顶**：仅异常 chip 切换时 `withAnimation + scrollTo` 榜首（对齐 §4.1-4 与 TTK 行为，三页一致） | P1 |
| 6 | **刷新反馈二分**：同 §4.1-3（`RadarView.swift:90-95` 现无条件 `.impact(light)`）。错误态防空转走共享层 `RetryErrorRow`（C10）——**不改 FeedErrorView**：其定义在 `AmmoView.swift:304`（行情 owner 的文件，`RadarView.swift:38` 只是调用点），雷达 owner 按合入顺序换用新组件并传 `busy: app.radar.isLoading` 即可，不越界、不空等 | P1 |
| 7 | **行内节奏**：名称列/右列 spacing 统一 `Space.xs`（`RadarView.swift:122,159` 现 4/3）（视觉审计 low） | P2 |

### 4.4 TTK（TtkView + GunDetailView + PenMatrixView）

| # | 条目 | 优先级 |
|---|------|--------|
| 1 | **空态升级**：空态（`TtkView.swift:102-105` 现一行灰字）改 ContentUnavailableView 并按成因分文案：搜索无结果→「没有匹配的枪械」+「清空搜索」；筛选无结果→「当前筛选无匹配弹药」+「重置筛选」（兵种=ar/部位=chest/护甲=4/弹药=best）。四维度组合无结果不再让用户逐个猜（交互审计 medium；对齐 `AmmoView.swift:66-78`） | P0 |
| 2 | **主数字立权**：RankRow 的 TTK 毫秒数升 `lead` 档 bold（现 16，`TtkView.swift:172`）并为行内最强；GunImage 从 44pt/70pt 宽 card2 亮底（`TtkView.swift:155,262`）降为 36pt + `line` 描边透明底——排行页要比较的是毫秒数，不是枪图（视觉审计 low） | P0 |
| 3 | **筛选区首屏减负**：三行筛选卡（`TtkView.swift:77-99`）收敛为一行横向滚动 chips（兵种/部位/护甲/弹药四枚 FilterMenu 并排 `ScrollView(.horizontal)`）；部位 segmented 并入 FilterMenu（其「选中面=card2」的 web 纪律由 chip 天然满足，`TtkView.swift:87-90` 现系统材质与同卡 chip 不同族）。榜单首行上移到折叠线内（视觉审计 medium） | P1 |
| 4 | **错误态给出口**：`ContentUnavailableView`（`TtkView.swift:42`）加 actions——「复制错误信息」（UIPasteboard，纯视图）；「重试」受 `TtkStore.loadIfNeeded` 的 `guard data == nil, error == nil` 挡（`State/Stores.swift:69-80`，禁改），不给假按钮（交互审计 low，诚实降级） | P1 |
| 5 | **GunDetail 四格降级**：头部「肉伤/甲伤/射速/弹匣」改共享 `StatQuadRow`（C5），获得与详情页相同的 4→2×2 ViewThatFits 韧性（`TtkView.swift:203-211` 现硬排一行仅靠缩字兜底；交互审计 low） | P1 |
| 6 | **搜索栏统一常驻**：`.searchable` 加 `.navigationBarDrawer(displayMode: .always)`（`TtkView.swift:126` 现默认 automatic；交互审计 low） | P1 |
| 7 | **名次列对齐雷达**：RankRow 名次迁 `sub` 档（`TtkView.swift:153` 现 12 micro），与雷达统一零填充 + 前三 accent | P2 |
| 8 | **行内节奏与徽标**：行内 spacing 统一 `Space.xs`（`TtkView.swift:156,170,225,230` 现 3/2）；PenBadge 随 C1 换装验收 | P2 |

### 4.5 设置（SettingsView）

| # | 条目 | 优先级 |
|---|------|--------|
| 1 | **接入字阶与色令牌**：LabeledContent 标题迁 `Theme.font(.md)`、行值迁 `monoFont(.sm)` + txStrong/dim、Section header 迁眉题风格（`micro` accent，对齐各页「口径」标题心智）。整页现在只用系统默认字号与系统灰（`SettingsView.swift:17-71` 仅 :73-75 一处 Theme.font），是四 Tab 中唯一「原生系统」观感的页面（视觉审计 medium） | P0 |
| 2 | **「实时推送」行改造**：改「连接状态」+ 共享组件 `ConnectionDot(state:)`（C11 完整签名 `ConnectionDot(state:error:stale:)`，本页只传 `state`——live 显 ok、其余 faint，error/stale 维度归 FeedHeader）+ `channel.state.label` 值。消除左右同文的无信息行，用户能从行值看到连接变化（视觉审计 medium）。不直接调 FeedHeader 的 dotColor——它是 `Components.swift:287-291` 的 private 方法，跨 owner 只能抄逻辑；C11 已把它提为共享 API | P0 |
| 3 | **刷新按钮反馈二分**：「立即刷新两路快照」（`SettingsView.swift:31-46`）完成后按两路 `lastError` 分流 `.success` / `.error` 触感（现固定 `.success`，`:89`）；按钮期间 ProgressView 已有，保持 | P1 |
| 4 | **行值等宽对齐**：版本号、推送次数、时间戳全部 `monospacedDigit` + `MonoStep.sub`，数字列右对齐（LabeledContent trailing） | P1 |
| 5 | **关于区排版**：版权/来源声明保持 footnote 下限（`SettingsView.swift:73-75` 已达标）；「版本」值迁 mono | P2 |
| 6 | **表单宽度**：600pt 可读列保持（`SettingsView.swift:82-83`），不动 | P2（验收） |

---

## 5. 动效与触感清单（iOS 17 API）

总纪律：微交互 ≤ 0.22s（T10，对齐 base.css `--t-slow`）；触感 trigger 只绑页面局部 `@State`（现有注释规范，如 `AmmoView.swift:21`）；全部动效尊重 Reduce Motion（见 §7）。

| 场景 | 反馈 | API | 优先级 |
|------|------|-----|--------|
| 下拉刷新完成（行情/雷达/详情） | 成功 `.success` / 失败 `.error` 二分 | `.sensoryFeedback(.error, trigger:)`（iOS 17）替换无条件 `.impact(light)` | P0 |
| 自选切换（列表滑动/详情星标） | 保持 `.success` | 现状保留（`AmmoView.swift:113`） | 保持 |
| 筛选/排序/菜单选择 | 保持 `.selection` | 现状保留（`AmmoView.swift:115-118`） | 保持 |
| 拖动查值逐点 | 跨数据点「咯哒」（抬手置 nil 不触发） | `.sensoryFeedback(.selection, trigger: selected?.id) { _, new in new != nil }` | P0 |
| 筛选切换回顶 | 位置动画 | `withAnimation(.easeOut(0.22))` + `ScrollViewProxy.scrollTo`（TTK `TtkView.swift:139-142` 推广） | P1 |
| 详情现价/预赚变化 | 数字滚动 | `.contentTransition(.numericText())` + `.animation(Theme.durMed, value:)`（iOS 17） | P1 |
| 自选星标 | 图标弹跳 | `.symbolEffect(.bounce, value: starred)`（iOS 17，star/star.fill） | P2 |
| 设置刷新按钮 | 旋转 | `.symbolEffect(.rotate, options: .repeating, active: refreshing)`（iOS 17，arrow.clockwise） | P2 |
| PriceChart 气泡出现/消失 | 淡入轻缩 | `.transition(.opacity)` / `.animation(.easeOut(0.15))`（Charts 支持受限，允许降级瞬现） | P1 |
| 空态/错误行出现 | 淡入 | `.transition(.opacity)` + `Theme.durFast` | P2 |
| Tab 图标切换 | 系统默认 | 不自绘转场，保持系统 Tab 行为 | — |

---

## 6. 图标语言与 Tab 图标方案

### 6.1 页面内 SF Symbol 使用纪律

现状已有一套健康的符号用法（`AmmoView.swift:124-137` 菜单行图标、`Components.swift:272` 警告行），固化成规则：

1. **只用 SF Symbols，禁 Unicode 符号**：功能性图标一律 SF Symbol；现存违例「⚠」（`Components.swift:14`）由 C3 清除。`ItemDetailView.swift:169-171` 的 ↗↘→ 是等宽文本箭头（数据态符号而非图标），保留 mono 文本形式。
2. **语义映射固定，不得近义混用**：筛选=`line.3.horizontal.decrease.circle`（激活 `.fill` 变体）、排序=`arrow.up.arrow.down`、自选=`star`/`star.fill`（warn 色，游戏收藏金惯例的既有例外）、警告=`exclamationmark.triangle`、刷新=`arrow.clockwise`、手册=`book`、矩阵=`tablecells`、网络错误=`wifi.exclamationmark`、分类占位=`shippingbox`。
3. **尺寸与粗细跟字阶走**：图标字号由所在 `Theme.font/.monoFont` 档位决定（现状做法保持，如 `Components.swift:146`）；不裸设 `.font(.system(size:))`。
4. **色随语义**：图标可着 accent（激活）/ 信号色（数据语义）/ faint（装饰）；装饰性图标 `accessibilityHidden` 或由所在行合并 label 转述（现有纪律，`AmmoView.swift:228-231`）。
5. **等级色只上数据**：等级/穿透色永远只出现在等级徽标、穿透矩阵等游戏语义位置，不上导航与通用控件。

### 6.2 底部 Tab 图标方案（用户已点名不满意通用 SF Symbols）

现状：`RootView.swift:41-51` 四枚通用 SF Symbols（chart.line.uptrend.xyaxis / dot.radiowaves.left.and.right / scope / gearshape），与千万个 App 撞脸，且与「战术指挥台」气质无关。

**方向：自绘「战术瞄具」线性图标组，双态=线性 / 线+核填充。**

| 维度 | 规范 |
|------|------|
| 语言 | 线性骨架（未选中）+ 关键内腔填充（选中），取自战术装备的「分划 / 扫掠 / 阶梯」语汇；不用系统 `.fill` 全实心（过重、缺细节） |
| 网格与笔画 | 24×24 网格、16×16 安全区；笔画 **1.75pt**（±0.25），圆头端点/圆角转角——视觉重量对齐 SF Symbols `.medium`，保证与页内 SF Symbol 并置不突兀 |
| 四枚同权 | 同网格、同笔画、同留白，成套感优先于单枚表现力 |
| 与 accent 关系 | 未选中=线性（系统自动 dim 灰）；选中=线+核填 `Theme.accent`（根 `.tint` 已设，`DeltaForceApp.swift:14`）。**等级色/信号色永不上 Tab** |
| 与内容的关系 | 图标形态与其页面主数字语义呼应（行情=价格脉冲、TTK=命中分划），不做纯装饰图形 |

四枚设计方向：

| Tab | 图形 | 选中态填充核 |
|-----|------|--------------|
| 行情 | 三级不均匀价格阶梯折线左下→右上，末端一枚数据点 | 阶梯下三角区 + 末端点 |
| 雷达 | 圆环 + 45° 扫掠扇形 + 环外两枚回波点 | 扫掠扇形 |
| TTK | 十字分划线 + 外圈四刻度 + 中心点（狙击分划，非整镜筒——与页内 `scope` 区分） | 中心点 + 四刻度 |
| 设置 | 三道横杆滑块（「校准」语义，比齿轮更贴指挥台） | 三枚滑块钮 |

实现路径（不引第三方依赖）：

- **首选**：Asset Catalog 模板矢量（SVG→PDF，Preserve Vector Data、Single Scale、Render As Template），每枚两态共 8 枚；`tabItem` 里 `Label("行情", image: selection == .ammo ? "tab-ammo-fill" : "tab-ammo-line")`——`RootView` body 随 selection 重算，切 Tab 即换态。
- **备选**：纯 SwiftUI `Shape`/`Path` 自绘（新文件 `Features/Shared/TabIcons.swift`），代码内双 path 切换；无资产文件、可运行时调笔画。
- Label 文字保留中文（a11y 名称由文本承担），图标 `Image(decorative:)` 语义。
- 该项属共享层（§0），由共享层 owner（A）一次合入 `RootView.swift` + 资产。

---

## 7. 无障碍与 Dynamic Type 守则

**保持现有四条纪律（已验证有效，工程师不得回退）：**

1. 列表行合并朗读：`accessibilityElement(children: .combine)` + 成句 label（`AmmoView.swift:228-231`、`RadarView.swift:152-154`、`TtkView.swift:180-182`）。
2. 纯图形 `accessibilityHidden`（ItemThumb / Sparkline / GunImage / RankBar 圆点），信息由合并 label 或 RankBar 成句转述承担（`Components.swift:183,223,337`）。
3. 徽标单行 `lineLimit(1) + fixedSize`，挤压由名称列截断承担（`Components.swift:17-19` 等四族同款注释）。
4. 文字用色只用 txStrong/tx/dim/faint + accent；等级/穿透文字色走 `levelText/penText` 对比度特例（`Theme.swift:33-47`）；`accentDim` 等新令牌禁止作文字色。

**本轮新增守则：**

5. 所有新数字一律 `MonoStep`（自动 ScaledMetric 缩放）；迁移完成后 grep 检查无 `Mono(size:` 新增调用。
6. AX 韧性三处补齐：TTK 筛选 chip 行（C8）、GunDetail 四格（C5/§4.4-5）、详情头部（§4.2-2）——特大字号（AX5 验收口径）下主数字不截断、chip 不压成竖排。
7. PriceChart 提供 VO 逐点听值（§3 P4 adjustable action）；图表摘要 label 保留兜底。
8. 触控目标 ≥44pt：FilterMenu chip、信号卡、自选滑动操作均达标；Sparkline / 徽标不是触控目标。
9. Reduce Motion：`@Environment(\.accessibilityReduceMotion)` 为 true 时跳过数字滚动、气泡过渡、symbolEffect（触感保留——触感不属动效）；回顶 scrollTo 改无动画直达。

---

## 8. 非目标（明确不做）

1. **不动业务逻辑 / 数据流 / 网络层**：`State/`（AppModel / FeedModel / Stores / LiveChannel / NotificationManager）与 `Packages/DeltaForceCore/` 一行不改。详情页解冻只在视图层现查 environment 数据；TTK 错误态不修 `loadIfNeeded` 守卫（受此约束，只给「复制错误」出口）。
2. **不引第三方依赖**：图表继续 Swift Charts，图标走 SF Symbols + 自绘，触感动效全系统 API。
3. **不做浅色模式**：`preferredColorScheme(.dark)` 锁定（`DeltaForceApp.swift:13`），对齐网页端单深色基调；不为浅色预留分支。
4. **不加新业务功能 / 设置项**：无新开关、无通知策略变化、无 TipKit 引导、无新页面。
5. **不动信息架构**：四 Tab 结构、页面导航拓扑（列表→详情、sheet 手册/矩阵）不变；只换 Tab 图标与页内精修。
6. **不追求 web 端 1:1**：hover 态映射为按压态，噪点/光晕背景不搬（列表页保持纯净 `Theme.bg`）；`--fs-display 30px` 等 web 大数字档不引入，iOS 密度上限为 hero 22。
7. **不做 iPad 专属布局**：保持现有 600/640 可读列（`SettingsView.swift:82`、`ItemDetailView.swift:23`）。
8. **不做多语言 / 文案重写**：中文文案为准，仅按空态成因等审计点补必要文案。
