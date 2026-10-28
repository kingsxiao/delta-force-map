# MOTION.md — 双端动效规范 v1.0（2026-10）

> 适用：网页 `apps/web`（Vue3 + hash 路由 5 页）与 iOS `apps/ios/DeltaForce`（SwiftUI，iOS 17，Tab 5 个）。
> 风格基准：简洁、好看、精致——动效服务理解（空间关系 / 状态变化 / 因果反馈），少而准，反对炫技。
> 硬约束（全程有效）：
> ① iOS **不允许新建 Swift 文件**（xcodeproj 由 xcodegen 生成），共享动效只能写进 `Theme.swift` / `Components.swift` / `PriceChart.swift` / `RootView.swift`；
> ② **不得重命名现有 CSS class 与 iOS 启动参数**（`server/smoke.mjs`、`scripts/ios-wf.sh` 依赖，受保护清单见 §6-6）；
> ③ 网页可新建 css / 组件文件；本规范只定义 API 与取值，施工排期另行。

---

## 0. 现状盘点结论（2026-10 实读）

### 0.1 网页端已有资产

| 资产 | 位置 | 现值 |
|------|------|------|
| 时长令牌 | `apps/web/src/assets/styles/base.css:117-122` | `--t-fast .15s` / `--t-med .18s` / `--t-slow .22s` / `--t-collapse .25s` |
| 缓动令牌 | 同上 | `--ease: cubic-bezier(.22,.61,.36,1)`（全站唯一缓动） |
| 页面入场 | `base.css:214-219` + `composables/useReveal.js` | `.reveal` opacity 0→1 + translateY(12px)，`.42s`（字面值） |
| 列表级联 | `base.css:225-234` | `.reveal-group` 子项按 `--ri` 错峰 60ms，封顶 5 档 |
| reduced-motion | `base.css:236-240` + 各组件 scoped 兜底 | reveal/行 hover/tab 等均已降级 |
| 折叠 | `components/CollapseCol.vue:94-99`、`views/ttk/RankRow.vue:431-436` | grid-rows `0fr→1fr`，`--t-collapse` |
| 微交互语汇 | 全站 | chip/star/search 过渡 `--t-fast`；按钮按下 `scale(.98)`；卡片 hover `translateY(-2px)`（SignalCard/SellCard）；BackTop `<transition name="totop">` 淡入+8px |
| 数字/文字脉冲 | `.live-dot`（三页）2.2s `pulse`；AccountView `.sync-dot` 1.2s | 已有 |

### 0.2 iOS 端已有资产

| 资产 | 位置 | 现状 |
|------|------|------|
| 时长令牌 | `App/Theme.swift:51-53` | `durFast 0.15` / `durMed 0.22`；缓动惯例一律 `.easeOut(duration:)` |
| 触感 | 各页（`AmmoView.swift:255-260` 等） | 刷新成败二分 `.success/.error`、菜单/自选 `.selection`，trigger 只绑页面局部 `@State`（DESIGN.md §5 纪律） |
| 状态过渡 | `AmmoView.swift:188,206`、`TtkView.swift:270,285` 等 | `.transition(.opacity)` + `.animation(reduceMotion ? nil : .easeOut(durFast), value:)` |
| 数字滚动 | `ItemDetailView.swift:148-151` | `.contentTransition(.numericText())` + `durMed` |
| 图标动效 | `ItemDetailView.swift:103-111`（star bounce）、`SettingsView.swift:78-80`（刷新中 `.symbolEffect(.pulse, options: .repeating)`；DESIGN 标注的 `.rotate` 实为 iOS 18 API，已刻意降级为 pulse，见该行注释） | 已带 Reduce Motion 跳过 |
| 图表查值 | `PriceChart.swift:152-155` | 拖动逐点 `.selection` 触感 + 十字线 `durFast` 淡入 |
| 回顶/滚动 | `AmmoView.swift:339-344` 等 | `withAnimation(.easeOut(durMed))` + `scrollTo`；RM 直达 |
| Tab 转场 | `RootView.swift:60-62` | 系统默认，明确不自绘 |

### 0.3 缺口（本规范要补的）

| # | 缺口 | 证据 |
|---|------|------|
| G1 | **首载无骨架屏**（用户点名 P0）：网页是一行文字，iOS 是裸 `ProgressView()` | `AmmoMarketView.vue:677`（`.state-tip`「正在加载行情…」）、`MarketRadarView.vue:244,430-437`（`.load-hold` 空盒）、`CraftView.vue:235`；iOS `AmmoView.swift:189-193`、`RadarView.swift:87`、`CraftView.swift:88`、`TtkView.swift:86` |
| G2 | 路由切换无过渡（瞬时硬切） | `App.vue:11` 裸 `<router-view />` |
| G3 | 表格展开行 `tr.expander` 瞬现瞬隐 | `AmmoMarketView.vue:957`、`MarketRadarView.vue:371`、`CraftView.vue:424`（v-if 直插） |
| G4 | 状态提示（refreshTip / notifyTip / stale-tip）瞬现瞬隐 | `AmmoMarketView.vue:873`（refreshTip）、`:667`（notifyTip）、`:671`（stale-tip）、`MarketRadarView.vue:288` |
| G5 | 现存红线违例一处：TTK 条 `transition: width` | `RankRow.vue:400`（全仓唯一，grep 验证） |
| G6 | 台账行增删无过渡 | `AmmoMarketView.vue:724-766` |

---

## 1. 原则（5 条，评审与验收都以此为准）

1. **动效服务理解，不为炫技**：只做三类动效——表达空间关系（展开属于哪一行）、表达状态变化（骨架→内容、空/错态进场）、表达因果反馈（按压、刷新成败）。装饰性循环动画只保留既有语义位（live-dot 脉冲 = 实时承诺；骨架扫光 = 系统工作中）。
2. **一套时长档位 + 一个缓动家族**：微交互 ≤220ms，一律取现有令牌（网页 `--t-fast/-med/-slow`，iOS `durFast/durMed`）；页面级入场与面板 250–420ms（网页 `--t-page .42s`、`--t-panel .25s`，iOS `durSwap 0.25`）；缓动唯一家族——网页 `--ease`，iOS `.easeOut(duration:)`。**档位封闭**：出现新场景先对号入座 §5 表，禁止档位外新时长。
3. **少而准；删掉无意义动效也是优化**：表格多行数字刷新**不**做滚动（60s 静默刷新会整表闪动＝噪声）；大表重排**不**做行级 FLIP、也**不**做整表 out-in 重建（几十~200 行 DOM 重建、滚动位置与展开行全丢，代价大于收益）；Tab 转场交给系统；路由切换只淡入、位移与级联错峰全部交给页内 `.reveal`（避免「离场淡出＋进场淡入＋页内入场」三层叠加近 1 秒连续动效）；网页图表保持静态。每一处「不做」都是决策，不是遗漏。
4. **双端同语义同时长**：同一交互在两端档位一致（§5 对照表），允许实现手段不同（hover ↔ 按压）。
5. **所有动效可关**：`prefers-reduced-motion: reduce` / `accessibilityReduceMotion` 下降级为**瞬时或仅淡入**（骨架扫光、位移、缩放、shake 全停；触感保留——触感不属动效，iOS DESIGN.md §7-9 口径）。**唯一例外**：进度指示类循环动画（`.mini-spin` / `ProgressView`）RM 下保留——它承担「进行中」的状态语义而非装饰，等同系统进度控件行为。

---

## 2. 令牌与共享 API

新增总量刻意压到最少：网页 3 个变量 + 1 个新 CSS 文件 + 1 个组件；iOS 4 个常量 + 4 个小视图，全部进现有文件。

### 2.1 网页端

**新 CSS 变量（加进 `base.css` `:root`，紧随现有动效块 base.css:117-122；去重原则——与既有令牌同值的一律复用，不造第二个名字）：**

| 变量 | 取值 | 用途 |
|------|------|------|
| `--t-page` | `.42s` | 页面级入场。收编 `.reveal` / `.reveal-group` 现有字面值 `.42s`（base.css:217,230），不改行为只消灭魔数 |
| `--t-panel` | `.25s` | 面板/状态切换档（骨架→内容、空/错态进场、提示条进出、路由淡入）。与既有 `--t-collapse`（base.css:122，.25s）**同值**：`--t-collapse` 保留为折叠场景专名（引用多、不改名不改引用），**新代码一律写 `--t-panel`**（含新折叠场景）——两者是同一 250ms 档的「新名 + 历史别名」关系，不是两个档 |
| `--sk-base` | `var(--card2)` | 骨架底色。card2 比 card **亮一档**（base.css:23-24 注释，1.10:1）——骨架块取面阶里最浅的 `--card2` 作低对比占位，靠「无文字、无描边语义」与真实内容拉开静噪差；扫光高光**不新增令牌**，直接用既有 `--lift`（白 6%，base.css:71，恰为 §6-9 幅度上限） |

**新文件 `apps/web/src/assets/styles/motion.css`（`main.js` 在 base.css 之后 import），四类工具：**

| 类 / at-rule | 定义要点 |
|--------------|----------|
| `.swap-enter-active` / `.swap-leave-active` | `transition: opacity var(--t-panel) var(--ease)`；enter 另含 `transform`（同时长） |
| `.swap-enter-from` | `opacity: 0; transform: translateY(6px)`（4–8px 上移取 6px） |
| `.swap-leave-to` | `opacity: 0`（离场只淡出不位移，防布局跳动） |
| `.sk` | 骨架基块：`background: var(--sk-base); border-radius: var(--radius-sm); position: relative; overflow: hidden` |
| `.sk::after` | 扫光层：`inset:0; transform: translateX(-100%)`，`background: linear-gradient(90deg, transparent, var(--lift), transparent)`，`animation: sk-pass 1.6s linear infinite`（周期 ≥1.2s 达标，白 6% 达 §6-9 上限，**只动 transform**） |
| `@keyframes sk-pass` | `to { transform: translateX(100%) }` |
| `.sk-line`（文字条 12px 高，宽由 `style="--w:60%"` 或修饰类定）、`.sk-num`（右对齐数字条）、`.sk-thumb`（28×18 图标位）、`.sk-bar`（110×7 分位条）、`.sk-chart`（130×30 走势位）、`.sk-badge`（胶囊徽标位） | 全部由 `.sk` 派生：`class="sk sk-line"` |
| `.sk-row` / `.sk-tbl` / `.sk-cards` | 组合件：表格行（thumb+名+5 数字条+chart 位）×N、带表头条；卡片网格 |
| `.route-enter-active` | 路由进场**只淡入**：`transition: opacity var(--t-panel) var(--ease)`。**不写任何 `.route-leave-*` 与位移**——离场瞬时（Vue `<Transition>` 无 leave 过渡类时立即卸载），位移与级联错峰全部交给页内 `.reveal`（base.css:214-234），杜绝「离场淡出+进场淡入+页内入场」三层叠加（原则 3） |
| `.route-enter-from` | `opacity: 0` |
| `.mini-spin` | 12px 环形：`border: 2px solid var(--line); border-top-color: var(--dim); border-radius: 50%; animation: spin .7s linear infinite`（嵌入刷新 chip 的内联进度；与 AccountView scoped `.spinner` 同形态） |
| `@keyframes spin` | `to { transform: rotate(1turn) }`（motion.css 自带定义；AccountView.vue:532 的同名 keyframes 为 scoped，不冲突） |
| `.flip-move` | `transition: transform var(--t-slow) var(--ease)`（TransitionGroup 行重排） |
| `.flip-enter-active/.flip-leave-active` | `transition: opacity var(--t-med)`；`-from/-to` `opacity:0`（leave 态 `position:absolute`，容器须相对定位，见 §3-B） |
| `@media (prefers-reduced-motion: reduce)` | 文件尾统一兜底：`.sk::after{animation:none}`（扫光停帧为静态骨架块）、`.swap-*`/`.route-*`/`.flip-*` `transition:none`、`.swap-enter-from` `transform:none`（`.route-enter-from` 本就只含 opacity，不动）。**`.mini-spin` 不在关闭之列**——进度语义按原则 5 例外保留 |

**新组件 `apps/web/src/components/SkeletonView.vue`（唯一新组件）：**

```vue
<!-- props: variant: 'table'|'cards'|'hero'; rows=8; cols=8 -->
<!-- 内部只输出 .sk-* 结构，不拉数据、不占 .state-card 类名（smoke.mjs 兼容，见 §6-6） -->
<SkeletonView v-if="loadState === 'loading'" variant="table" :rows="8" />
```

| variant | 结构 | 用于 |
|---------|------|------|
| `table` | 表头条 + `rows` × `.sk-row`（雷达 10 行 / 弹药 8 行） | /ammo /radar /craft 首载 |
| `cards` | 2×3 信号卡骨架 | /ammo 买入区（可选） |
| `hero` | 时利最佳主卡骨架 | /craft 首载 |

**路由过渡（`App.vue` 改造，配 `.route-enter-*`；只淡入，见 §3-A）：**

```vue
<router-view v-slot="{ Component, route }">
  <Transition name="route">   <!-- 无 mode="out-in"：离场无过渡类=瞬时卸载，新视图随即淡入 -->
    <component :is="Component" :key="route.path" />
  </Transition>
</router-view>
```

### 2.2 iOS 端（只进 Theme.swift / Components.swift）

**Theme.swift 追加（紧随 `durFast/durMed` Theme.swift:51-53，约 10 行）：**

```swift
/// 状态切换（骨架→内容 / 空错态进场）：对齐 web --t-panel（MOTION.md §2.1）
static let durSwap: TimeInterval = 0.25
/// 动画预设：缓动惯例唯一家族 .easeOut（Theme.swift:51 注释口径）
static let animFast = Animation.easeOut(duration: durFast)   // 0.15 微交互
static let animMed  = Animation.easeOut(duration: durMed)    // 0.22 数字滚动/回顶
static let animSwap = Animation.easeOut(duration: durSwap)   // 0.25 状态切换
/// 骨架底色（对齐 web --sk-base）；扫光高光不新增令牌，复用既有 lift（白 6%，Theme.swift:34，
/// 恰为 MOTION.md §6-9 幅度上限）
static let skBase = card2
```

**Components.swift 追加（4 个视图 + 1 个修饰符，全部带默认值、零调用点破坏）：**

| API | 签名与要点 |
|-----|-----------|
| `SkeletonBlock` | `init(width: CGFloat, height: CGFloat, radius: CGFloat = Theme.radiusTile)`；`RoundedRectangle` 填 `skBase`，overlay 扫光条（`LinearGradient(transparent, Theme.lift, transparent)` 宽 40%）`.offset(x:)` 动画 `.linear(duration: 1.6).repeatForever(autoreverses: false)`，`@Environment(\.accessibilityReduceMotion)` 为 true 时不启动（静态块）；`accessibilityHidden(true)` |
| `SkeletonLine` | `init(width: CGFloat? = nil, height: CGFloat = 12)` → `SkeletonBlock(width: width ?? 90, height: height, radius: 2)` |
| `SkeletonRow` | 无参。对齐 `AmmoRow` 行结构：`ItemThumb` 位 40×40 + 名称条 44% + 右列两组 `SkeletonLine`（lead/sub 档高度）+ `SkeletonBlock(width: 56, height: 8)` 分位条位；行高 ≈ 真实行 ±10%。作 List 行使用时挂 `.listRowSeparator(.hidden)` + `.listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))`（对齐信号卡行口径 `AmmoView.swift:153`）+ `.listRowBackground(Color.clear)` |
| `SkeletonList` | `init(rows: Int = 8, cards: Bool = true)`；`cards` 为 true 时顶部先给一行 2.5 张卡位（对应买入信号横滑区），主体 `ForEach(0..<rows)` 出 `SkeletonRow`。List 整合（§4.2）：骨架行放在数据 Section 的空态分支位置，**骨架期间 Section 头隐藏计数**（`snapshot == nil` 时头文案退化为中性词，如 `Section("行情")`，否则「全部 · 0 种」与 8 条假行同屏矛盾，`AmmoView.swift:178`） |
| `.contentSwap(_:)` | 见下方实现——**必须是 ViewModifier 结构体（存储属性 `@Environment`）**，不许写成 View 扩展函数体内局部 `@Environment`：局部 property wrapper 不进 SwiftUI 环境注入管线，swiftc 可编译但渲染期恒读默认值（NSHostingView 探针实测：函数体内局部 `@Environment` 读 false、存储属性读 true），照抄即 Reduce Motion 降级**静默全失效** |

**`.contentSwap` 实现（Components.swift 内，私有修饰符 + 转发扩展）：**

```swift
/// 状态切换动画挂载（MOTION.md §2.2）：RM 下动画置 nil（仅淡入/瞬时）。
/// 注意：@Environment 必须是修饰符结构体的存储属性——View 扩展函数体内的
/// 局部 @Environment 读不到注入值（NSHostingView 实测恒得默认值），禁用该写法。
private struct ContentSwapModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: V
    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : Theme.animSwap, value: value)
    }
}
extension View {
    func contentSwap<V: Equatable>(_ value: V) -> some View {
        modifier(ContentSwapModifier(value: value))
    }
}
```

**用法（AmmoView.swift:189-193 的裸 ProgressView 行替换，其余三页同构；状态机与 §4.2 单一定义，错误优先、其余无快照一律骨架）：**

```swift
if app.market.snapshot == nil, let err = app.market.lastError {
    RetryErrorRow(message: err, retry: { … }, busy: app.market.isLoading)
        .transition(.opacity)
} else if app.market.snapshot == nil {
    SkeletonList(rows: 8)          // 不再判 isLoading：FeedModel.isLoading 初值 false、
        .transition(.opacity)      // configure() 首拉才置 true（FeedModel.swift:29,51-53），
} else { …内容… }                  // idle 窗口真实存在——一律骨架比空白/闪错安全
.contentSwap(app.market.snapshot == nil)   // 一次挂全 Section
```

**`.redacted(reason: .placeholder)` 取舍（结论：不用它做首载骨架）**：优点是一行代码且贴合真实布局；缺点在本仓不可解——① 首载时 `snapshot == nil`，要用 redact 必须先伪造 `MarketItem` 假数据喂给真视图，假行有流进 judge/通知/自选比对的污染风险；② `Sparkline` / `RankBar` / Charts 自绘层不被 redact，仍需自制占位；③ iOS 17 的 redact 无内置脉动，观感是死灰块。**自定义 `SkeletonList` 胜在结构保真 + 扫光 + 零假数据**；redact 仅当未来出现「已有真实视图、只欠子资源」的场景才启用（当前无此场景）。

---

## 3. 交互场景目录

> 读法：**应该怎么动** ｜ 网页实现 ｜ iOS 实现 ｜ 取值 ｜ Reduce Motion 降级。标记〔已有〕= 盘点确认存在、保持即可；〔补〕= 本规范新增；〔改〕= 修正现状。

### A. 导航与路由

| 场景 | 应该怎么动 | 实现 | 取值 | RM |
|------|-----------|------|------|-----|
| 顶栏 Tab hover/选中〔已有〕 | 文字提亮 + 底部指示条左起展开 | `SiteHeader.vue:187-208` `.tab::after scaleX(0→1)` | `--t-med` + `--ease` | `transition:none`（已兜底 :227-229） |
| 路由/Tab 切换〔补〕 | 新页**只淡入** `.25s`；离场瞬时；位移与级联错峰全部交给页内 `.reveal`——杜绝「离场淡出 + 进场淡入 + 页内 .42s 入场 + 5×60ms 级联」叠加出的近 1 秒连续动效（原则 3 的取舍：路由层管「换页了」，`.reveal` 管「内容来了」，各只做一件事） | `App.vue` 套 `<Transition name="route">`（§2.1 片段，无 `mode="out-in"`） | 淡入 `--t-panel .25s` | `.route-*` 全关，瞬时切换 |
| iOS Tab 切换〔已有〕 | 系统默认转场，不自绘 | `RootView.swift:60-62` 注释口径保持 | 系统 | — |
| 返回顶部〔已有〕 | 按钮淡入 + 8px 上移；点击平滑滚顶 | `BackTop.vue` `totop` 过渡 + `scrollTo(behavior:'smooth')` | `--t-med` | 按钮瞬现；滚动 `behavior:'auto'`（已兜底 :12-13,86-88） |

### B. 筛选 / 排序 / 搜索

| 场景 | 应该怎么动 | 实现 | 取值 | RM |
|------|-----------|------|------|-----|
| chip 选中〔已有〕 | 颜色/描边/底三态切换，无位移 | `.chip.on`（三页）与 `ControlSeg.vue:72` `.seg-btn` | `--t-fast` | `transition:none`（已兜底） |
| 大表重排 | **无动画**（原则 3）：不做行级 FLIP，也**不做**整表 key 换绑 + out-in 淡出重建——几十~200 行 DOM 重建、滚动位置与展开行状态全丢，代价远大于「排序变化可感」的收益；命中数 `.bhc` 瞬时更新即为可感反馈 | 网页：现状即正确，保持；iOS：同理，靠回顶（下行）建立「换了榜单」的感知 | — | — |
| 小列表增删重排（囤货台账 ≤20 行）〔补〕 | 行位移补位 + 淡入淡出 | `<TransitionGroup name="flip">` 包 `.pos-list` 的 `v-for`；leave 态 `position:absolute` **要求容器 `.pos-list { position: relative }` 作定位锚点**（不加则离场行飞出列表容器）；tag 保持 `ul` | move `--t-slow` / 进出 `--t-med` | `.flip-*` 全关 |
| 搜索聚焦 / 清词〔已有〕 | 边框提亮，无位移 | `.search:focus` border-color | `--t-fast` | 已兜底 |
| 筛选切换回顶 | 换筛选=换榜单，回顶 | 网页无（表内滚容器高度有限，不强制）；iOS〔已有〕`onChange(of: filter)` → `withAnimation(Theme.animMed)` + `proxy.scrollTo(top)`（`AmmoView.swift:339-344`） | iOS `durMed` | iOS RM：`scrollTo` 无动画直达（已实现） |
| iOS 菜单选择反馈〔已有〕 | 系统菜单 + 触感 | `.sensoryFeedback(.selection, trigger: menuTick)` | 瞬时+触感 | 触感保留 |

### C. 展开 / 折叠

| 场景 | 应该怎么动 | 实现 | 取值 | RM |
|------|-----------|------|------|-----|
| 折叠列（CollapseCol / RankRow / AmmoTable）〔已有〕 | 高度 0fr→1fr 展开 + 箭头旋转 180° | grid-rows 技法（`CollapseCol.vue:94-99`、`RankRow.vue:431-436`）；箭头现状**三档并存**——`CollapseCol.vue:91` `.chev` 用 `--t-collapse`、`RankRow.vue:426` `.caret` 用 `--t-slow`、`AmmoMarketView.vue:1365` `.row-chev` 用 `--t-fast`——登记待收编：折叠箭头统一 `--t-slow .22s`（与折叠体 .25s 协调），新代码即用统一值 | 体 `--t-panel .25s`（旧代码 `--t-collapse` 同值）；箭头统一 `--t-slow` | `transition:none`（已兜底 :101-103,759-760） |
| 表格展开行 `tr.expander`〔改〕 | 展开内容从 0 高度铺开，不再是瞬现 | td 内层包 `.exp-clip { display:grid; grid-template-rows:0fr; transition: grid-template-rows var(--t-panel) var(--ease) }`（雷达页可直接复用现有 `.exp-hold` 外再包一层）；td 的 padding 移入内层随 0fr 一并裁剪。`v-if` 保留（行本身仍瞬时插入，动的是内容高度） | `--t-panel .25s` | 过渡关，瞬开瞬合 |
| 展开后定位〔已有〕 | 平滑滚到可视 | `scrollIntoView({ behavior:'smooth' })`（`AmmoMarketView.vue:527-534`） | 系统 smooth | `behavior:'auto'`（已带 RM 判断） |

### D. 按压 / 悬停

| 场景 | 应该怎么动 | 实现 | 取值 | RM |
|------|-----------|------|------|-----|
| 主按钮按下〔已有〕 | `scale(.98)` 微缩 = 「按实」 | `.retry/.empty-clear/.pos-add-btn:active`（全站语汇） | `--t-fast` | `transform:none`（已兜底 :1490） |
| 卡片 hover〔已有〕 | 上浮 2px + 描边提亮 + 顶缘高光 | SignalCard/SellCard `translateY(-2px)` + `--edge-hover` | `--t-med` | `transform:none`（已兜底） |
| iOS 按压态〔已有〕 | 按压 `lift` 面 + `lineHover` 描边 | 自定义 ButtonStyle + `.animation(animFast, value: isPressed)`（`AmmoView.swift:704-713`；animFast 为 §2.2 预设别名，等价现状字面值） | `durFast` | RM：动画置 nil，色面态仍生效 |
| 星标切换〔已有〕 | 网页色/透明度渐变；iOS 图标 bounce + 触感 | `.star` 过渡；`symbolEffect(.bounce, value: starred)`（`ItemDetailView.swift:103-111`） | `--t-fast` / 系统默认 | 网页已兜底；iOS RM 跳过 symbolEffect（已实现） |

### E. 数字变化（关键决策：多数场景**不动**）

| 场景 | 应该怎么动 | 实现 | 取值 | RM |
|------|-----------|------|------|-----|
| 表格多行数字（60s 静默刷新） | **瞬时更新，不加动画**——整表滚动 = 噪声（原则 3） | 网页现状即正确，保持；iOS 列表行同理 | — | — |
| 详情页 hero 现价（单点关键数字）〔已有〕 | 数字滚动 | iOS `.contentTransition(.numericText())` + `.animation(animMed, value: it.current)`（`ItemDetailView.swift:148-151`） | `durMed` | `.identity`（已实现） |
| 计数徽章 / 命中数（radar `.chip-n`、`.bhc`） | 瞬时 | 现状保持 | — | — |

### F. 刷新

| 场景 | 应该怎么动 | 实现 | 取值 | RM |
|------|-----------|------|------|-----|
| 有数据时刷新〔已有〕 | **绝不回骨架/遮罩**；控制条按钮禁用 + 文案「刷新中…」+ 内联小环 | 网页 `.chip.refresh`（`:disabled` + 文案切换，`AmmoMarketView.vue:868-871`）；〔补〕`motion.css` 提供全局 `.mini-spin`（12px 环形，`animation: spin .7s linear infinite`，与 AccountView `.spinner` 同形态）可嵌入 chip；iOS 系统刷新指示（refreshable 自带） | `--t-fast` 态切换 | spin 动画是「进度语义」，RM 下保留（等同 iOS ProgressView） |
| 刷新结果提示〔改〕 | **所有 `v-if` 提示行**（refreshTip、notifyTip、stale-tip、雷达页 refreshTip）统一淡入、定时/条件消失时淡出 | 〔补〕各提示 `<p>` 外套 `<Transition name="swap">`（4s 自动消失 timer 现状保留）：`AmmoMarketView.vue:873`（refreshTip）、`:667`（notifyTip）、`:671`（stale-tip）、`MarketRadarView.vue:288` | `--t-panel` | 瞬现瞬隐 |
| 刷新成败触感〔已有〕 | 成功/失败二分 | iOS `.sensoryFeedback(.success/.error, trigger: refreshOk/ErrTick)` | 触感 | 保留（不属动效） |

### G. 图表

| 场景 | 应该怎么动 | 实现 | 取值 | RM |
|------|-----------|------|------|-----|
| iOS 拖动查值〔已有〕 | 十字线/气泡随指尖，跨数据点「咯哒」 | `PriceChart.swift:152-155` 触感 + `.animation(animFast, value: selected?.id)` | `durFast` | 动画置 nil（已实现），触感保留 |
| 网页走势图 | **保持静态**（展开即整图；悬停十字线列为 P2 可选，非本轮） | 现状 `PriceChart.vue` 静态 SVG | — | — |

### H. 状态进场（loading / 空 / 错）

见 §4 专章。总规则：四态互切一律 `.swap` / `animSwap` 淡入淡出，内容进场带 6px 上移。

---

## 4. Loading 专章（P0，用户点名重做）

**统一方案：骨架屏 → 内容。** 骨架是「结构预告」：贴近真实布局的占位（表头 + 行 / 卡片格）、低对比度（底 `--sk-base` = `--card2`，面阶里最浅的一档、远低于任何文字与数据的对比，且无文字无描边语义）、慢速低幅度扫光（周期 1.6s ≥1.2s，高光取 `--lift` 白 6% = §6-9 上限，transform 扫光）——安静地传达「系统在工作中」，不抢戏。

### 4.1 网页落地

| 页 | 现状（替换点） | 改为 |
|----|----------------|------|
| /ammo | `AmmoMarketView.vue:677` `.state-tip` 一行字 | `<Transition name="swap" mode="out-in">` 包四态（key=loadState）；loading 态渲染 `<SkeletonView variant="table" :rows="8" />` |
| /radar | `MarketRadarView.vue:244` `.load-hold` 空盒（430-437 的 min-height 560px 预留思路保留：ready 实测 ≈590px，10 行 ×~46px + 表头 ≈500px **不够**——骨架容器加 `min-height: max(560px, 60vh)` 兜底（motion.css `.sk-hold` 三页统一，560px 保验收③只增不减、60vh 保验收② ≥60vh），或行数取 12） | `<SkeletonView variant="table" :rows="10" />`（容器 `.sk-hold`：min-height max(560px, 60vh)） |
| /craft | `CraftView.vue:235` `.state-tip` | `variant="hero"` + `variant="table" :rows="8"`（最佳卡 + 榜单双段） |
| /ttk | 本地数据毫秒级加载，无 loading 态 | 不加骨架（原则 3） |
| /account | 会话恢复 `.pend` spinner + 登录提交 `.spinner`〔已有〕 | 保持（表单场景无「布局预告」可做，spinner 语义正确） |

四态切换规则（网页，`loadState: loading | ready | empty | error`）。**结构前提**：Vue `<Transition>` 要求单根子节点，而 `/ammo` 的 ready 分支是 `<template v-if="loadState === 'ready'">` 多兄弟节点（`AmmoMarketView.vue:687-1015` 约 330 行）——四态必须各包一层单根 `div`、以 `loadState` 字符串为 key：

```vue
<Transition name="swap" mode="out-in">
  <div v-if="loadState === 'loading'" key="loading" class="state-root">
    <SkeletonView variant="table" :rows="8" />
  </div>
  <div v-else-if="loadState === 'empty'" key="empty" class="state-root">
    <div class="state-card">…</div>       <!-- .state-card 类名保留在内部（smoke.mjs 依赖） -->
  </div>
  <div v-else-if="loadState === 'error'" key="error" class="state-root">
    <div class="state-card">…</div>
  </div>
  <div v-else key="ready" class="state-root">
    …原 <template v-if="loadState === 'ready'"> 的全部子节点移入…
  </div>
</Transition>
```

| 切换 | 行为 |
|------|------|
| loading → ready | 骨架淡出（无位移，`.swap-leave-to` 只 opacity），内容淡入 + 6px 上移，`--t-panel` |
| loading → empty / error | 骨架淡出，`.state-card` 淡入（**类名保留**，smoke.mjs 依赖）；错误态重试按钮可点 |
| error/empty → loading（重试/自动轮询恢复） | `.state-card` 淡出 → 骨架淡入 |
| ready → 刷新（silent） | **不换骨架**：内联 `.chip.refresh` 禁用 + `.mini-spin`；失败走 `refreshTip` 淡入（§3-F），旧数据不动 |

验收（可脚本化口径）：① 首帧同步渲染骨架（loading 是 `ref` 初值，无 JS 等待）；② 骨架渲染高度 ≥ `60vh`（任何首载页统一，首屏不空）；③ loading→ready 切换后 `document.scrollingElement.scrollHeight` **只增不减**（不出现滚动条消失/回弹；/radar 由 560px 预留保证，/ammo ready 内容天然长于骨架）；④ shimmer 1.6s linear 无回弹，RM 下静态。

### 4.2 iOS 落地

| 页 | 现状（替换点） | 改为 |
|----|----------------|------|
| 行情 | `AmmoView.swift:189-193` `HStack(ProgressView().mini + 文字)` | `SkeletonList(rows: 8, cards: true)`（含信号卡位） |
| 雷达 | `RadarView.swift:87` 同款裸 spinner 行 | `SkeletonList(rows: 10, cards: false)` |
| 制造 | `CraftView.swift:88` | `SkeletonList(rows: 8, cards: false)` |
| TTK | `TtkView.swift:86` `ProgressView()`（bundle 数据，毫秒级） | 不加骨架，保持（原则 3） |
| 详情/设置/账号 | 本地已有数据或瞬时加载 | 不动 |

**List 整合细节**（骨架行是 List 行，不是浮层）：① 每条 `SkeletonRow` 挂 `.listRowSeparator(.hidden)` + `.listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))`（对齐信号卡行口径 `AmmoView.swift:153`）+ `.listRowBackground(Color.clear)`；② 骨架期间数据 Section 头**隐藏计数**——`AmmoView.swift:178` 的 `Section("\(filter.rawValue) · \(rows.count) 种")` 在 `snapshot == nil && rows.isEmpty` 时会显示「全部 · 0 种」，与 8 条假行同屏矛盾，改为 `Section(app.market.snapshot == nil ? "行情" : "\(filter.rawValue) · \(rows.count) 种")`（雷达/制造同构）。

四态机（iOS，**与 §2.2 用法片段单一定义**；判据只看 `snapshot` 与 `lastError`，不看 `isLoading`）：`snapshot==nil && lastError!=nil` → RetryErrorRow〔已有，busy 参数承载 isLoading 防空转〕；`snapshot==nil`（其余一切情形，**含 idle 窗口**——`FeedModel.isLoading` 初值 false、`configure()` 首拉才置 true，`FeedModel.swift:29,51-53`，此窗口真实存在）→ SkeletonList；`snapshot!=nil && rows.isEmpty` → ContentUnavailableView〔已有〕；否则内容。互切挂 `.contentSwap(snapshot == nil)` + 各态 `.transition(.opacity)`。刷新（refreshable）永不回骨架——系统下拉指示已足够。

**双端共性红线**：刷新中禁止整页遮罩/回骨架；骨架行数固定（8/10；/radar 不足 560px 预留时以容器 `min-height` 兜底而非加行），不随屏幕无限堆；扫光只有一条、不叠加脉冲。

---

## 5. 双端一致性对照表

| 交互语义 | 档位 | 网页 | iOS |
|----------|------|------|-----|
| 微交互（chip/星标/聚焦/箭头/按压） | 150ms | `--t-fast` + `--ease` | `animFast`（.easeOut 0.15） |
| 数字滚动 / 回顶 / 卡片 hover | 220ms | `--t-med`~`--t-slow` | `animMed`（.easeOut 0.22） |
| 折叠展开 | 250ms | `--t-panel`（旧代码 `--t-collapse` 同值别名）+ `--ease` | 系统或 `animMed`（列表行内折叠沿用系统隐式动画） |
| 状态切换（骨架→内容/提示条/空错态） | 250ms | `--t-panel` + `.swap` | `animSwap`（.easeOut 0.25） |
| 页面级入场 | 420ms | `--t-page`（.reveal） | 系统转场（不自绘） |
| 路由切换 | 250ms | `.route` 只淡入 `--t-panel`（离场瞬时） | 系统 Tab 转场（不自绘） |
| 骨架扫光 | 1.6s 循环 | `sk-pass` linear（高光 `--lift` 白 6%） | `.linear(1.6).repeatForever`（高光 `Theme.lift`） |
| 进度指示（spin / ProgressView） | 0.7s 循环 | `.mini-spin` | 系统 `ProgressView` |
| 语义脉冲（live-dot） | 2.2s 循环 | `pulse` keyframes | —（iOS 用 ConnectionDot 静态点） |
| 语义脉冲（同步中 sync-dot） | 1.2s 循环 | `AccountView.vue:635`（现状保持） | — |
| 刷新中图标微动（iOS） | 系统循环 | — | `.symbolEffect(.pulse, options: .repeating)`（`SettingsView.swift:78-80`；`.rotate` 属 iOS 18 已降级） |
| 表单错误 shake | 一次性 .32s（现存档外，登记待收编至 .25s） | `AccountView.vue:543` | — |
| hover ↔ 按压 | 同 150ms 档 | `:hover` 上浮 2px | ButtonStyle 按压 `lift` 面（DESIGN.md §8-6 映射） |
| 刷新成败反馈 | 瞬时 | refreshTip 淡入（.25s） | 二分触感（瞬时） |

---

## 6. 性能与可访问性红线

1. **只动 `opacity` / `transform`**；折叠高度用 `grid-template-rows 0fr→1fr`（既有技法）。`color/background/border` 允许作状态过渡（无布局成本）。
2. **禁止 `transition: all`**（现状全仓无，grep 验证；新代码 review 必查）。
3. **禁止动画 `width/height/top/left`**。现存违例一处：`RankRow.vue:400` `.rk-bar i { transition: width }` →〔改〕改为 `width:100%; transform:scaleX(p); transform-origin:left` 过渡 transform（渐变随缩放拉伸可接受；父级 `.rk-bar` 保持定宽裁剪）。
4. **`will-change` 慎用**：默认不写；仅 profiler 证据下的持续动画元素可加，禁止静态挂。
5. **RM 全覆盖**：每个新增动画必须有降级路径——网页 `motion.css` 文件尾统一 `@media (prefers-reduced-motion: reduce)` 块兜底 + 组件内位移类单独关；iOS 一律 `reduceMotion ? nil : anim`（`.contentSwap` 已内建，**且其 `@Environment` 必须落在 ViewModifier 结构体存储属性上**——View 扩展函数体内的局部 `@Environment` 编译通过但渲染期恒读默认值，RM 降级会静默全失效，见 §2.2 探针结论）。降级 = 瞬时或仅淡入，禁止改留更慢版本。触感（sensoryFeedback）保留；进度指示类循环动画（`.mini-spin` / `ProgressView`）按原则 5 例外保留。
6. **不得重命名现有 class 与启动参数**。受保护清单（改动前必查）：
   - `server/smoke.mjs` 选择器：`.site-topbar .tab` / `.tab.active`、`.wrap.page .compact-head h1`、`.page .hero`、`.page .state-card`、`.page .ctl-bar`、`.page .tbl tbody tr`、`.ttk-page`、`.rk-row`、`.seg-btn(.on)`、`.champs .champ`、`.auth-stage`、`.auth-card form/.submit`、`.page .block`；`html.locked`（base.css:134-135 注释契约）。**骨架/新过渡一律用新命名**（`.sk-*` / `.swap-*` / `.route-*` / `.flip-*`，已 grep 确认无冲突）；空态/错误态必须保留 `.state-card` 类名。
   - `scripts/ios-wf.sh:19-32` 启动参数：`-startTab` / `-openAccount` / `-openDetailFirst` / `-openPlaybook` / `-openCraftFirst` / `-openGunFirst` / `-wfScrollEnd`（消费点 `RootView.swift:29-39` 等）。
7. **iOS 不新建 Swift 文件**：共享动效 API 只进 `Theme.swift` / `Components.swift` / `PriceChart.swift` / `RootView.swift`（xcodegen 约束）。
8. **时长档位封闭**：新动效只能取 §5 表内档位（150/180/220ms 微交互，250ms 面板与状态切换，420ms 页面级，循环类 0.7/1.2/1.6/2.2s 各语义位专属）；250ms 档网页统一写 `--t-panel`（`--t-collapse` 为同值历史别名，仅存量引用）；出现新场景先定档再写码。
9. **骨架纪律**：周期 ≥1.2s、扫光幅度 ≤6% 白、单条扫光、结构贴近真实布局、低对比度；刷新绝不回骨架。
10. **验收口径**：新增动效逐条过「服务理解吗？档内吗？RM 关得掉吗？只动 opacity/transform 吗？」四问，任何一问不过即删。
