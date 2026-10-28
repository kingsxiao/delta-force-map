// SettingsView.swift — 数据状态 / 信号通知 / 关于
// 字阶 / 色令牌接入（DESIGN.md §4.5-1）：标题 .md 档 tx 色、行值走 MonoStep.sub / 同锚默认 design，
// Section 眉题 micro accent（对齐各页「口径」标题心智），不再用系统默认字号与系统灰。
import DeltaForceCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    // §7-9 Reduce Motion：为 true 时跳过 symbolEffect（触感不属动效，保留）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 回前台重查通知授权：用户从「前往设置」放行后返回，本页仍在屏上、onAppear 不会再触发，
    // 不重查则「系统授权」行会一直停在「未允许」（根 handleScenePhase 不管通知授权，State 禁改，故本页自查）
    @Environment(\.scenePhase) private var scenePhase
    @State private var refreshing = false // 三路快照刷新进行中（防连点）
    // UI 巡检：-openAccount 启动参数直达账号页（见 onAppear 处注释）
    @State private var showAccount = false
    // 触觉反馈 tick：全部为本页局部状态、操作后自增（禁绑 Store 派生值）。
    // §4.5-3 刷新反馈二分：三路 lastError 任一非空 → .error，否则 → .success
    @State private var refreshOkTick = 0
    @State private var refreshErrTick = 0
    @State private var notifyTick = 0

    var body: some View {
        @Bindable var settings = app.settings
        NavigationStack {
            Form {
                Section {
                    // §4.5-2 连接状态行改造：共享 ConnectionDot（C11）替代纯文本行值——
                    // live 显 ok 点、其余 faint，行值随通道状态可见变化（消除左右同文的无信息行）；
                    // 本页只传 state，error/stale 维度归 FeedHeader 全参调用
                    LabeledContent {
                        // 行值字号对齐同列（§1.3「档位跟层级」）：ConnectionDot 内置文字是页头 FeedHeader 的 xs 档
                        // （Components.swift ConnectionDot），放进表单行值位比下方「行情版本」「收到推送」矮一档；
                        // 这里只取它的圆点（showLabel: false），文字按本列行值口径 .md semibold dim 自绘。
                        // a11y：圆点自带 state.label、再加文字会读两遍——整组合并为单元素、label 只取一份
                        HStack(spacing: Theme.Space.sm) {
                            ConnectionDot(state: app.channel.state, showLabel: false)
                            Text(app.channel.state.label)
                                .font(Theme.font(.md, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.dim)
                                // 状态文案交叉淡入（同页「系统授权」行值同款）：与圆点换色同一驱动键、同时渐变
                                .contentTransition(.opacity)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(app.channel.state.label)
                        // 圆点换色（live ok ↔ 掉线 faint）animFast 渐变：连接恢复 / 掉线正是用户
                        // 盯着这行的状态变化时刻，色块硬切不可感（MOTION.md §6-1 色允许作状态过渡）；
                        // RM 门内建于 .motion（置 nil 即硬切，色态仍生效）
                        .motion(Theme.animFast, value: app.channel.state)
                    } label: {
                        rowTitle("连接状态")
                    }
                    LabeledContent {
                        // 版本号为日期数字串（§4.5-4 等宽对齐：monospacedDigit + MonoStep.sub）
                        Mono(MarketMeta.formatVersionLabel(app.market.snapshot?.version), step: .sub, color: Theme.dim)
                    } label: {
                        rowTitle("行情版本")
                    }
                    LabeledContent {
                        Mono(MarketMeta.formatVersionLabel(app.radar.snapshot?.version), step: .sub, color: Theme.dim)
                    } label: {
                        rowTitle("雷达版本")
                    }
                    // 三路口径补齐：下方「立即刷新全部快照」与 footer 失败分支都点名制造路，
                    // 版本行却原先只有行情 / 雷达两路——制造快照健康度（版本新旧 / 首拉失败停「—」）
                    // 全 App 无处可看（制造页不显示版本），「制造刷新失败」点名时用户对不上哪路坏了
                    LabeledContent {
                        Mono(MarketMeta.formatVersionLabel(app.craft.snapshot?.version), step: .sub, color: Theme.dim)
                    } label: {
                        rowTitle("制造版本")
                    }
                    if app.channel.eventCount > 0 {
                        LabeledContent {
                            // 「N 次」含中文：默认 design + 等宽数字（mono design 仅限纯 ASCII），
                            // 锚定 .md（subheadline）与同列 MonoStep.sub 同档同行高
                            Text("\(app.channel.eventCount) 次")
                                .font(Theme.font(.md, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.dim)
                        } label: {
                            rowTitle("收到推送")
                        }
                        // 行首次出现淡入（§3-H 状态进场）；计数 +1 本身保持瞬时（原则 3，静默数字不加动画）
                        .transition(.opacity)
                    }
                    Button {
                        guard !refreshing else { return }
                        refreshing = true
                        Task {
                            // 三路快照同刷（与 handleScenePhase(.active) 同口径）：
                            // 制造页首拉失败后也能从这里补拉
                            await app.market.refresh()
                            await app.radar.refresh()
                            await app.craft.refresh()
                            refreshing = false
                            // 成功侧 refresh 会清掉自身 lastError，完成后判三路即成败二分
                            if app.market.lastError != nil || app.radar.lastError != nil || app.craft.lastError != nil {
                                refreshErrTick += 1
                            } else {
                                refreshOkTick += 1
                            }
                        }
                    } label: {
                        // 进行中双通道（图标 pulse + 状态文案），不再叠第三个 spinner 环——
                        // 一个按钮里「脉冲图标 + 转圈 + 文案」三信号同屏是重复表达（MOTION.md 原则 3）；
                        // 文案范式与账号页主按钮（「登录中…」）一致：动作状态文字可见
                        Label(refreshing ? "刷新中…" : "立即刷新全部快照", systemImage: "arrow.clockwise")
                            .font(Theme.font(.md, weight: .semibold))
                            // §5 刷新中图标微动效：DESIGN 标注的 .rotate 实为 iOS 18 API（RotateSymbolEffect），
                            // iOS 17 目标下以 .repeating .pulse 等价表达「进行中」；Reduce Motion 跳过
                            .symbolEffect(.pulse, options: .repeating, isActive: refreshing && !reduceMotion)
                            // 状态文案交叉淡入（contentTransition 需 animation 驱动，RM 下 motion 置 nil 即瞬时）
                            .contentTransition(.opacity)
                            .motion(Theme.animFast, value: refreshing)
                    }
                    .disabled(refreshing)
                } header: {
                    sectionHeader("数据")
                } footer: {
                    // §1.5 闭环：刷新成败除触感外还要有「看得见的回声」——原先失败只有一声 .error 震动、
                    // 成功而版本未变时整屏零变化，用户无法确认动作是否生效。页脚承接可见结果（见 dataFooter）
                    dataFooter
                        // 成败互切淡入淡出（§3-H 状态进场 animSwap 档）：刷新失败警示行出现 / 恢复后回到
                        // 节拍说明，是「立即刷新」动作的可见结果切换，原先两分支硬切；驱动键与分支条件同源
                        .motion(Theme.animSwap, value: feedFailure != nil)
                }
                .listRowBackground(Theme.card)

                Section {
                    Toggle(isOn: $settings.settings.notificationsEnabled) {
                        rowTitle("买入 / 卖出信号通知")
                    }
                    .onChange(of: settings.settings.notificationsEnabled) { _, on in
                        notifyTick += 1
                        if on { Task { await app.notifications.requestAuthorization() } }
                    }
                    LabeledContent {
                        // 纯中文行值：默认 design（同列锚定），已允许 txStrong / 未允许 dim 分层。
                        // 开关已开却未获系统授权 = 通知永远发不出去的「卡死态」：行值转 warn 点名问题，
                        // 并给出路「前往设置」直达系统通知页（思路库「空态给一条出路」；accent 只上导航动作，
                        // 状态色与动作色分离）。开关关着时「未允许」是中性事实，保持 dim、不给链接
                        HStack(spacing: Theme.Space.sm) {
                            Text(app.notifications.authorized ? "已允许" : "未允许")
                                .font(Theme.font(.md, weight: .semibold))
                                .foregroundStyle(authorizationColor)
                                // 行值文字交叉淡入：「前往设置 → 放行 → 返回」时 scenePhase 重查翻转
                                // authorized，文字与卡死态 warn 色同时变化——这条出路闭环的回声时刻，
                                // 硬切不可感（contentTransition 需 animation 驱动，由下方 .motion 承担）
                                .contentTransition(.opacity)
                            if needsSystemPermission, let url = URL(string: UIApplication.openSettingsURLString) {
                                Link(destination: url) {
                                    Text("前往设置")
                                        .font(Theme.font(.sm, weight: .semibold))
                                        // 触控垫层（思路库「视觉可小、命中区 ≥44pt」；与账号页密码显隐眼睛同手法）：
                                        // 四字 sm 文字命中区约 52×18，纵向远低于 44，这是卡死态唯一出路、落空即「点了没反应」。
                                        // 正 padding 垫出命中形状 → contentShape → 负 padding 收回布局占位：
                                        // 行高与同列行不变，只向上下扩命中、不侵入左侧状态文字
                                        .padding(.vertical, 13)
                                        .contentShape(Rectangle())
                                        .padding(.vertical, -13)
                                }
                                // 行内独立命中：List 行里的按钮默认样式可能把整行点击转给它，点「系统授权」标题
                                // 就跳系统设置属误触；borderless 只响应自身区域且保留 accent 着色（导航动作色）
                                .buttonStyle(.borderless)
                                // 授权通过后链接随之退场：随 authorized 同一驱动键淡出（开关关掉引发的退场
                                // 保持瞬时——开关自身动画已是回声，不叠加，原则 3）
                                .transition(.opacity)
                            }
                        }
                        // authorized 翻转驱动整组（含 warn → txStrong 色渐变）；RM 门内建于 .motion
                        .motion(Theme.animFast, value: app.notifications.authorized)
                    } label: {
                        rowTitle("系统授权")
                    }
                    if let t = app.notifications.lastDelivered {
                        LabeledContent {
                            // 本地化时间含中文（上午/下午）：默认 design + 等宽数字（§4.5-4）
                            Text(t.formatted(date: .omitted, time: .shortened))
                                .font(Theme.font(.md, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.dim)
                        } label: {
                            rowTitle("上次通知")
                        }
                        // 行首次出现淡入（§3-H）；时间文字后续刷新保持瞬时（原则 3）
                        .transition(.opacity)
                    }
                } header: {
                    sectionHeader("通知")
                } footer: {
                    Text("首次出现立即通知；信号切换需连续 2 轮确认；同信号 6 小时冷却；买入信号冷却期内再跌 5% 重报。通知只在 App 处于前台拿到最新数据时判定。")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)

                Section {
                    NavigationLink {
                        AccountView()
                    } label: {
                        // 入口行值直接显示登录态（web 顶栏账号入口同口径：登录后显示用户名、未登录显「登录」，
                        // SiteHeader.vue）：本区唯一的决策信息是「登没登、哪个号」，原先要推进二级页才知道。
                        // 已登录用户名 txStrong（身份主信息，与账号页「用户名」行同色）、未登录 dim（中性事实，
                        // 与「系统授权」关着时的「未允许」同口径）；文案「未登录」与账号页 syncState idle 态一致
                        LabeledContent {
                            Text(app.auth.user?.username ?? "未登录")
                                .font(Theme.font(.md, weight: .semibold))
                                .foregroundStyle(app.auth.user == nil ? Theme.dim : Theme.txStrong)
                                .lineLimit(1) // 用户名最长 16 字中文：单行截断兜底（web .name ellipsis 同款）
                        } label: {
                            rowTitle("账号与云同步")
                        }
                    }
                } header: {
                    sectionHeader("账号")
                } footer: {
                    Text("登录后自选星标与囤货台账在多台设备间保持同步（星标并集 / 台账按弹名合并，不丢数据）；账号数据存放在你自己部署的服务器上。")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)

                Section {
                    LabeledContent {
                        // §4.5-5「版本」值迁 mono（"x.y.z (build)" 纯 ASCII → MonoStep.sub）
                        Mono(appVersion, step: .sub, color: Theme.dim)
                    } label: {
                        rowTitle("版本")
                    }
                    Text("游戏素材版权归腾讯/天美所有，本 App 仅供个人学习参考。历史分位不代表未来走势，信号仅供参考。")
                        .font(Theme.font(.xs)) // 版权声明下限 footnote（原 11pt 固定字号不随系统字号设置）
                        .foregroundStyle(Theme.faint)
                } header: {
                    sectionHeader("关于")
                }
                .listRowBackground(Theme.card)
            }
            .themedList()
            // 条件信息行（收到推送 / 上次通知）进出统一淡入淡出驱动（§3-H 状态进场 animSwap 档）：
            // transition 挂在行上、animation 挂在包含 if 的 Form 层（TtkView 错误行同构写法）
            .motion(Theme.animSwap, value: app.channel.eventCount > 0)
            .motion(Theme.animSwap, value: app.notifications.lastDelivered != nil)
            // iPad/横屏 regular：表单列上限 600 居中（与详情 640 同一可读列节奏，§4.5-6 保持不动）；
            // 外层再满宽铺 Theme.bg，600pt 之外不露 NavigationStack 系统底色（与详情/手册同一写法）
            .frame(maxWidth: 600)
            .frame(maxWidth: .infinity)
            .background(Theme.bg)
            .navigationTitle("设置")
            // UI 巡检钩子（同 RootView -startTab 模式）：`-openAccount` 启动参数直达账号页，
            // 供 ios-wf.sh 类视觉验收截图；生产无此参数，行为不变
            .navigationDestination(isPresented: $showAccount) { AccountView() }
            .onAppear {
                if ProcessInfo.processInfo.arguments.contains("-openAccount") { showAccount = true }
                Task { await app.notifications.refreshAuthorization() }
            }
            // 从系统设置返回（scenePhase 回 active）重查授权：让「前往设置 → 放行 → 返回」这条出路闭环，
            // 行值即时从 warn「未允许」回到「已允许」（只调既有 refreshAuthorization，不动 State）
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                Task { await app.notifications.refreshAuthorization() }
            }
            // §4.5-3 二分触感：成功 / 失败各自 tick，分别挂不同 sensoryFeedback
            .sensoryFeedback(.success, trigger: refreshOkTick) // 全部快照刷新成功
            .sensoryFeedback(.error, trigger: refreshErrTick) // 任一路刷新失败
            // 通知开关是「切换」不是「任务结果」：触感语义分层（思路库）—— .success/.error 只留给刷新成败类
            // 结果，切换一律 .selection；与雷达 / 制造页 toggleTick 同款，原先 .success 让开关与刷新成功同声
            .sensoryFeedback(.selection, trigger: notifyTick)
        }
    }

    /// 行标题统一 .md 档 + tx 正文色（§4.5-1，替代系统默认灰标题）
    private func rowTitle(_ s: String) -> some View {
        Text(s).font(Theme.font(.md)).foregroundStyle(Theme.tx)
    }

    /// Section 眉题（§4.5-1）：micro accent 小节题，对齐各页「口径」标题心智
    private func sectionHeader(_ s: String) -> some View {
        Text(s).font(Theme.font(.micro, weight: .bold)).foregroundStyle(Theme.accent)
    }

    /// 数据区页脚 = 刷新动作的可见结果（§1.5 闭环「可见结果 + 可触结果」缺前者）：
    /// 任一路 lastError 非空 → danger 警示行点名失败的数据源并指引重试（后台轮询失败同样在此可见，
    /// 口径对齐各列表页 FeedErrorBanner「有快照的刷新失败也要一眼看到」）；否则 → 最近一次成功刷新时刻
    /// + 刷新节拍说明（顺带解释「连接状态 = 定时刷新」是什么意思，连接状态可视化不再只有一枚灰点）。
    /// lastRefreshAt 只在成功时前进（FeedModel.refresh），刷新一成功时间即归新——成功侧也有看得见的变化
    @ViewBuilder
    private var dataFooter: some View {
        if let failure = feedFailure {
            // 警示图标固定 exclamationmark.triangle（§6.1-2 语义映射），不用 .fill 变体；
            // 进出场淡入淡出由 Section footer 处的 .motion(animSwap) 驱动（§3-H 状态进场）
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.danger)
                .transition(.opacity)
        } else {
            Text(refreshCadenceText)
                .font(Theme.font(.xs))
                .monospacedDigit() // 时间数字等宽，刷新归新时位宽不跳
                .foregroundStyle(Theme.faint)
                .transition(.opacity)
        }
    }

    /// 三路快照里第一个失败的数据源（按行情 / 雷达 / 制造顺序点名，一次只报一条，避免页脚堆三行）
    private var feedFailure: String? {
        let feeds: [(name: String, error: String?)] = [
            ("行情", app.market.lastError),
            ("雷达", app.radar.lastError),
            ("制造", app.craft.lastError),
        ]
        guard let hit = feeds.first(where: { $0.error != nil }), let err = hit.error else { return nil }
        return "\(hit.name)刷新失败：\(err)。可点「立即刷新全部快照」重试。"
    }

    /// 刷新节拍说明（AppModel.channel.onStateChange：实时在线 5 分钟兜底轮询、否则 60s）；
    /// 有过成功刷新时前置「上次刷新 HH:mm:ss」
    private var refreshCadenceText: String {
        let cadence = "实时推送在线时价格变动即时到达，推送不可用时每 60 秒自动刷新。"
        let latest = [app.market.lastRefreshAt, app.radar.lastRefreshAt, app.craft.lastRefreshAt]
            .compactMap { $0 }
            .max()
        guard let latest else { return cadence }
        return "上次刷新 \(latest.formatted(date: .omitted, time: .standard))。" + cadence
    }

    /// 开关已开但系统未授权 = 通知发不出去的卡死态（requestAuthorization 已被拒后 authorized 恒 false）
    private var needsSystemPermission: Bool {
        app.settings.settings.notificationsEnabled && !app.notifications.authorized
    }

    /// 「系统授权」行值色：已允许 txStrong / 卡死态 warn（提醒需处理）/ 关着时未允许 dim（中性事实）
    private var authorizationColor: Color {
        if app.notifications.authorized { return Theme.txStrong }
        return needsSystemPermission ? Theme.warn : Theme.dim
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }
}
