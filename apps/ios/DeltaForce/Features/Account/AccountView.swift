// AccountView.swift — 账号与云同步（从设置的「账号」入口推入）
// 三态：未登录（登录 / 注册表单）/ 已登录（信息 + 云同步 + 退出登录）。
// 样式与设置页同一范式：rowTitle / sectionHeader / Theme 字阶与卡片底。
// 表单精修（对齐 Web 端登录页）：字段级实时校验（失焦后亮红、合规亮绿勾，
// 避免边打边报错）、密码显隐切换、键盘回车流转（用户名 → 密码 → 提交）、
// 主操作实心按钮 + 按压反馈 + 失能降透明、错误行带警示图标。
import DeltaForceCore
import SwiftUI

struct AccountView: View {
    @Environment(AppModel.self) private var app
    // §7-9 Reduce Motion：本环境值现仅作同步按钮 pulse 图标的 isActive 门；
    // 其余动画（面板互切 / 错误行 / 角标 / 文案交叉）的 RM 门统一内建于 .motion（置 nil 即瞬时）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // 二分触感：登录/注册成功 / 失败各自 tick（§4.5-3 同口径）
    @State private var okTick = 0
    @State private var errTick = 0
    // 退出登录二次确认（防误触）：destructive 动作使全部已登录设备下线，误触代价高
    @State private var confirmLogout = false
    // 登录 ↔ 注册切换触感 tick：只由底部文字链点击自增（切换语义 → .selection）。不直接绑 mode——
    // 退出登录会程序性把 mode 复位 "login"，绑 mode 会在非用户切换时凭空响一声
    @State private var modeTick = 0

    @State private var mode = "login"
    @State private var username = ""
    @State private var password = ""
    @State private var submitting = false
    @State private var errorText: String?
    @State private var syncing = false
    // 表单精修态
    @State private var showPassword = false
    @State private var touchedUsername = false // 失焦后才亮红（onFocusChange 置位）
    @State private var touchedPassword = false
    @FocusState private var focusedField: Field?

    private enum Field { case username, password }

    /// 与服务端同口径的客户端预检（server/auth/store.mjs 的 /^\p{L}\p{N}_$/u）：
    /// 2–16 位任意 Unicode 字母 / 数字 / 下划线（中文、假名、谚文、西里尔、带重音
    /// 拉丁等均合法）——预检不得比服务端窄，否则此类账号在本端永远无法登录
    private static let usernameRegex = /^[\p{L}\p{N}_]{2,16}$/

    private var usernameOk: Bool {
        (try? Self.usernameRegex.wholeMatch(in: username.trimmingCharacters(in: .whitespaces))) != nil
    }
    private var passwordOk: Bool { password.count >= 8 }

    private var canSubmit: Bool {
        usernameOk && passwordOk && !submitting
    }

    /// 主按钮是否压暗：只在「表单未合规且不在提交中」时降透明。canSubmit 把 submitting 也算进失能，
    /// 直接拿它驱动 opacity 会让提交中的按钮跟着变暗（见主按钮处注释）
    private var primaryDimmed: Bool {
        !canSubmit && !submitting
    }

    /// 校验角标三态（MOTION.md §3-D 行内反馈）：作 .motion(value:) 的驱动键——
    /// 逐字输入不改变 mark 时不触发动画，只在「无 ↔ 绿勾 ↔ 红叹号」档位切换时动
    private enum FieldMark: Equatable { case none, ok, bad }

    private var usernameMark: FieldMark {
        if username.isEmpty { return .none }
        if usernameOk { return .ok }
        return touchedUsername ? .bad : .none
    }

    private var passwordMark: FieldMark {
        if password.isEmpty { return .none }
        if passwordOk { return .ok }
        return touchedPassword ? .bad : .none
    }

    var body: some View {
        Form {
            if let user = app.auth.user {
                // 登录成功 → 账号面板整组进场（§3-H 状态切换）：淡入淡出互切，驱动挂 Form 层
                // .contentSwap(user != nil)。刻意不用 .swapTransition 的 6pt 上移——Form 多 Section
                // 插删已带列表布局动画，再叠位移是双重运动（上移留给页面级内容区分支）
                Group {
                Section {
                    LabeledContent {
                        Text(user.username)
                            .font(Theme.font(.md, weight: .semibold))
                            .foregroundStyle(Theme.txStrong)
                    } label: {
                        rowTitle("用户名")
                    }
                    LabeledContent {
                        // 行值统一 semibold（同设置页「上次通知」等时间值口径，原先 regular 与同列混排粗细不一）
                        Text(createdAtText(user.createdAt))
                            .font(Theme.font(.md, weight: .semibold))
                            .monospacedDigit() // 日期数字等宽（§4.5-4：与同列「上次同步」/ 设置页「上次通知」口径补齐）
                            .foregroundStyle(Theme.dim)
                    } label: {
                        rowTitle("注册时间")
                    }
                } header: {
                    sectionHeader("账号")
                }
                .listRowBackground(Theme.card)

                Section {
                    LabeledContent {
                        syncStateText
                    } label: {
                        rowTitle("云端同步")
                    }
                    LabeledContent {
                        // 全零空态（对齐 web syncEmpty 整行换出路文案，AccountView.vue:37-41 / 378-382：
                        // 「读数行连说 0 并声称已并入云端，语义失真」）：新账号首屏「自选 0 · 台账 0」
                        // 是无信息读数，换成「去哪产生数据」的出路（思路库「空态给一条出路」）；任一项
                        // 有数据即恢复读数。出路文字取 sm faint 与读数行值（md dim）分层——它是指引
                        // 不是数据；「上次同步」时间戳行不受影响（showLastSync 独立门禁）
                        if syncEmpty {
                            Text("还没有可同步的内容——在行情页点亮星标、或记一笔囤货台账，下次同步会自动带上")
                                .font(Theme.font(.sm))
                                .foregroundStyle(Theme.faint)
                                .multilineTextAlignment(.trailing)
                                .transition(.opacity)
                        } else {
                            Text("自选 \(app.favorites.names.count) · 台账 \(app.positions.positions.count)")
                                .font(Theme.font(.md, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.dim)
                                // 合并结果的数字滚动回声（§3-E 单点关键数字档）：登录 / 手动同步把另一端
                                // 数据并进来、计数跳变的那一下用 numericText 滚动，是「同步确实做了事」的
                                // 可见反馈；与设置页「收到推送」被动计数保持瞬时（原则 3）不矛盾——这里只随
                                // 用户动作的结果变化。驱动键聚合两计数成字符串（tuple 不满足 Equatable 泛型约束）
                                .numericChange(value: "\(app.favorites.names.count)·\(app.positions.positions.count)")
                                .transition(.opacity)
                        }
                    } label: {
                        rowTitle("同步内容")
                    }
                    // 空态 ↔ 读数互切淡入淡出（animFast 行内档）：点亮首个星标 / 记首笔台账后出路文案
                    // 让位给真实读数，是「数据产生了」的回声；驱动键与分支条件同源
                    .motion(Theme.animFast, value: syncEmpty)
                    if showLastSync, let t = app.auth.lastSyncAt {
                        LabeledContent {
                            Text(t.formatted(date: .omitted, time: .shortened))
                                .font(Theme.font(.md, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(Theme.dim)
                        } label: {
                            rowTitle("上次同步")
                        }
                        // 行首次出现淡入（§3-H）；后续同步的时间文字更新保持瞬时（原则 3）
                        .transition(.opacity)
                    }
                    Button {
                        guard !syncing else { return }
                        syncing = true
                        Task {
                            await app.syncUserData()
                            syncing = false
                            // 同步成败二分触感（§1.5 闭环 / 与设置页「立即刷新」§4.5-3 同口径）：原先按钮结束后
                            // 零触感，用户只能靠盯行值文字确认结果。pullAndMerge 收尾即写 syncState，
                            // 这里按它分流；.idle（user 为空被 guard 掉）不发声——没有任务结果就没有结果触感
                            switch app.auth.syncState {
                            case .ok: okTick += 1
                            case .error: errTick += 1
                            default: break
                            }
                        }
                    } label: {
                        // 进行中双通道与设置页「立即刷新全部快照」同构（图标 pulse + 状态文案）：
                        // 原先静默图标 + 突现 spinner 环，动作状态不可见且三信号重复（MOTION.md 原则 3）
                        Label(syncing ? "同步中…" : "立即同步", systemImage: "arrow.clockwise")
                            .font(Theme.font(.md, weight: .semibold))
                            // .rotate 属 iOS 18 API（RotateSymbolEffect），iOS 17 以 .repeating .pulse
                            // 等价表达「进行中」（§5 对照表钦定）；Reduce Motion 跳过
                            .symbolEffect(.pulse, options: .repeating, isActive: syncing && !reduceMotion)
                            .contentTransition(.opacity)
                            .motion(Theme.animFast, value: syncing)
                    }
                    .disabled(syncing)
                } header: {
                    sectionHeader("云同步")
                } footer: {
                    // 云同步 footer = 「立即同步」动作的可见结果，与设置页「数据」区 dataFooter 同一范式
                    // （SettingsView.swift）：失败警示行 ↔ 合并规则说明互切走 animSwap 淡入淡出（§3-H 状态进场）——
                    // 原先 syncState error↔ok 翻转时两分支硬切，web 端同位置 sync-err 走 swap Transition（AccountView.vue）
                    syncFooter
                        .motion(Theme.animSwap, value: syncErrorMessage != nil)
                }
                .listRowBackground(Theme.card)

                Section {
                    Button(role: .destructive) {
                        confirmLogout = true // 先确认再执行：一次误触不应让全部设备下线
                    } label: {
                        // 语义色纪律（§7-4 / §1.2）：破坏性动作走令牌 Theme.danger，不用系统 .destructive 的饱和红——
                        // 全页其余色都在蓝黑中性阶与令牌内，一枚系统红会跳出调色板；web .logout 同样取 --danger。
                        // role 保留（a11y 语义 + 系统对破坏性按钮的处理），仅覆盖标签文字色
                        Text("退出登录")
                            .font(Theme.font(.md, weight: .semibold))
                            .foregroundStyle(Theme.danger)
                    }
                    .confirmationDialog(
                        // 两步确认文案对齐 Web 端账号页口径（视觉复验修复）：标题明确指向当前账号，
                        // 「所有设备下线」后果从按钮文案移入 message（信息不丢，按钮回到 取消/退出 二元选择）
                        "确定退出当前账号？",
                        isPresented: $confirmLogout,
                        titleVisibility: .visible
                    ) {
                        Button("退出", role: .destructive) {
                            Task {
                                await app.logoutAccount()
                                // 表单复位到「登录」：注册并登录后退出，原先带着注册态回来（停在「注册」
                                // 模式、标题「注册」），重新登录还要先切回；换 mode 顺带触发
                                // onChange 清错误与校验标记，表单以干净登录态迎接下一位用户
                                mode = "login"
                            }
                        }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text("退出会让所有已登录设备一起下线；本机自选保留，只是不再同步。")
                    }
                } footer: {
                    Text("退出会让所有已登录设备一起下线；本机自选保留，只是不再同步。")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)
                }
                .transition(.opacity)
            } else {
                Section {
                    // 登录 / 注册切换不再用顶部系统分段控件，改表单底部文字链（见本 Section 末尾的切换行）——
                    // 对齐 web 登录卡「单一主操作 + 上下文切换」范式（AccountView.vue 头注释钦定「文字链而非分段控件」）；
                    // 系统 segmented 的材质与深色卡面不同族（DESIGN.md §4.4-3 对 TTK 同类控件的同一批评），
                    // 且占表单首位与主按钮抢层级。当前模式仍有三处指示：导航标题 / 主按钮文案 / 文字链问句

                    // 用户名行：失焦后不合规亮红、合规亮绿勾（空值不亮，避免开场报错）
                    HStack(spacing: Theme.Space.sm) {
                        TextField("用户名（2–16 字符）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            // 回车流转已是行为（onSubmit → 密码框），键面文案对齐为「下一项」——
                            // 键盘回车键是流转的发现性入口，默认 return 文案不提示这个能力
                            .submitLabel(.next)
                            .focused($focusedField, equals: .username)
                            .onSubmit { focusedField = .password }
                        usernameStatusIcon
                    }
                    // 校验角标进出驱动（animFast 微交互档）：value 取三态 mark 而非原始文本——
                    // 只在「无 ↔ 绿勾 ↔ 红叹号」切换时动，逐字输入不触发动画
                    .motion(Theme.animFast, value: usernameMark)
                    // 密码行：SecureField / TextField 按 showPassword 切换，右侧眼睛切换不夺键盘焦点。
                    // 字段互切刻意保持瞬时：淡入淡出会让新旧两个输入框短暂并存，键盘焦点易跳（原则 3 取舍）
                    HStack(spacing: Theme.Space.sm) {
                        Group {
                            if showPassword {
                                TextField(placeholderPassword, text: $password)
                            } else {
                                SecureField(placeholderPassword, text: $password)
                            }
                        }
                        .focused($focusedField, equals: .password)
                        .onSubmit { submit() }
                        .submitLabel(.go)
                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash" : "eye")
                                .font(Theme.font(.md))
                                .foregroundStyle(focusedField == .password ? Theme.tx : Theme.faint)
                                // 眼睛开合用符号替换过渡（iOS 17 contentTransition，只动 opacity/scale 层）；
                                // RM 下 motion 置 nil 即瞬时换图
                                .contentTransition(.symbolEffect(.replace))
                                .motion(Theme.animFast, value: showPassword)
                                // 触控垫层（HIG 44pt 下限 / 思路库「视觉可小、命中区用 padding 补足」）：图标视觉 ~18pt，
                                // 原命中区只有图标本身，输密码时反复点显隐极易落空。横向直接撑到 44（HStack 有余量）；
                                // 纵向不能用 frame(minHeight: 44)——会把本 Form 行撑高、与上方用户名行不齐，
                                // 改为「padding 垫出命中形状 → contentShape → 负 padding 收回布局占位」：行高不变、
                                // 命中区 44×≈42，且只向上下扩、不向左侵入输入框（避免点字段末尾误触显隐）
                                .frame(minWidth: 44)
                                .padding(.vertical, 12)
                                .contentShape(Rectangle())
                                .padding(.vertical, -12)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(showPassword ? "隐藏密码" : "显示密码")
                        passwordStatusIcon
                    }
                    .motion(Theme.animFast, value: passwordMark)

                    // 主操作：全宽实心主色按钮（行背景透明化，CTA 不嵌卡片条）
                    Button {
                        submit()
                    } label: {
                        HStack(spacing: Theme.Space.sm) {
                            // 提交中 spinner 淡入淡出（原先突现突隐）；主按钮无图标，环是唯一「进行中」视觉，保留
                            if submitting { ProgressView().tint(Theme.bg).transition(.opacity) }
                            Text(submitting
                                 ? (mode == "login" ? "登录中…" : "注册中…")
                                 : (mode == "login" ? "登录" : "注册并登录"))
                                .contentTransition(.opacity) // 「登录」↔「登录中…」/ 登录 ↔ 注册文案交叉淡入
                        }
                        .motion(Theme.animFast, value: submitting)
                        .motion(Theme.animFast, value: mode)
                    }
                    .buttonStyle(AuthPrimaryButtonStyle())
                    // 失能降透明只给「表单未合规」：提交中不压暗（web .submit:disabled.busy { opacity: 1 } 同口径，
                    // AccountView.vue）——spinner + 「登录中…」本身就是进行中反馈，原先 submitting 连带 canSubmit=false
                    // 把整颗按钮压到 0.45，恰在用户最需要确认「动作已发出」的那两秒削弱了它
                    .opacity(primaryDimmed ? 0.45 : 1)
                    // 失能降透明随校验结果平滑过渡（原先逐字输入到合规瞬间硬跳 0.45 → 1）
                    .motion(Theme.animFast, value: primaryDimmed)
                    .disabled(!canSubmit)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                    if let errorText {
                        // §5 P2：错误行淡入淡出（纯透明度，Reduce Motion 跳过）；出现/消失由下方
                        // .motion(animSwap, value: errorText) 统一驱动，赋值处无需各自 withAnimation。
                        // 呈现复用共享 FeedErrorBanner（C7 配方：danger 8% 底胶囊 + 警告图标）——全站错误行一个长相，
                        // 行情 / 雷达 / 制造列表顶部的刷新失败与这里的登录失败同款；顺带收编原先的
                        // exclamationmark.triangle.fill：§6.1-2 固定映射是不带 .fill 的 exclamationmark.triangle
                        FeedErrorBanner(message: errorText)
                            .transition(.opacity)
                    }

                    // 登录 ↔ 注册切换文字链（web .ac-switch 同构：「还没有账号？创建账号」/「已有账号？直接登录」）：
                    // 居中一行、清底脱出输入卡块（与主按钮同为动作区），问句 faint、动作词 accent（导航动作色）
                    HStack(spacing: Theme.Space.xs) {
                        Text(mode == "login" ? "还没有账号？" : "已有账号？")
                            .font(Theme.font(.sm))
                            .foregroundStyle(Theme.faint)
                        Button {
                            mode = (mode == "login") ? "register" : "login"
                            modeTick += 1
                        } label: {
                            Text(mode == "login" ? "创建账号" : "直接登录")
                                .font(Theme.font(.sm, weight: .semibold))
                                // 触控垫层（与设置页「前往设置」/ 密码眼睛同手法）：sm 文字命中区纵向不足 44，
                                // 正 padding 垫出命中形状 → contentShape → 负 padding 收回，行高不变只扩命中
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                                .padding(.vertical, -13)
                        }
                        // 行内独立命中：List 行里按钮默认样式会把整行点击转给它，点问句也切模式属误触；
                        // borderless 只响应自身文字区域且保留 accent 着色
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity)
                    // 两段文案随 mode 交叉淡入（主按钮「登录」↔「注册并登录」同一驱动键、同一档位）
                    .contentTransition(.opacity)
                    .motion(Theme.animFast, value: mode)
                    .listRowBackground(Color.clear)
                } header: {
                    sectionHeader("账号")
                } footer: {
                    Text("账号数据存放在你自己的服务器上，用于把自选星标同步到多台设备；不要使用与其他网站相同的密码。")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)
                // 登录表单分支与账号面板（if 分支 Group）对称：互切淡入淡出（§3-H）
                .transition(.opacity)
            }
        }
        .themedList()
        // 账号面板 ↔ 登录表单互切驱动（§3-H 状态切换 animSwap 档；RM 门内建于 .motion）；
        // 「上次同步」条件行的进出由下方 showLastSync motion 一并驱动
        .contentSwap(app.auth.user != nil)
        .motion(Theme.animSwap, value: showLastSync)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        // 标题跟随三态：已登录「账号」/ 登录态「登录」/ 注册态「注册」——原先注册态落到「账号」，
        // 切到「注册」时标题反而变成与表单无关的词，与主按钮 / 切换文字链的文案不对应
        .navigationTitle(app.auth.user != nil ? "账号" : (mode == "login" ? "登录" : "注册"))
        // 失焦探测：字段从聚焦 → 离开（nil 或切到另一字段）时置「已触碰」，之后才允许亮红
        .onChange(of: focusedField) { old, new in
            if old == .username, new != .username { touchedUsername = true }
            if old == .password, new != .password { touchedPassword = true }
        }
        // 登录 ↔ 注册切换：清错误与「已触碰」标记（换模式不带着旧校验状态走）
        .onChange(of: mode) { _, _ in
            errorText = nil
            touchedUsername = false
            touchedPassword = false
        }
        .sensoryFeedback(.success, trigger: okTick)
        .sensoryFeedback(.error, trigger: errTick)
        // 密码显隐是「切换」不是「任务结果」：触感语义分层里 selection 给切换（与设置页通知开关
        // 同款）；showPassword 只由眼睛按钮改写，trigger 无程序性变更路径、不会凭空响
        .sensoryFeedback(.selection, trigger: showPassword)
        // 登录 ↔ 注册切换同为「切换」语义：.selection（原系统分段控件无触感，文字链补齐与密码显隐同款回声）
        .sensoryFeedback(.selection, trigger: modeTick)
        // 错误行出现 / 消失（提交失败、切换方式清除）统一淡入淡出：animSwap 档对齐兄弟页
        // 错误 banner（AmmoView/RadarView 的 bannerMessage 同款）；全站 .animation 一律经 .motion 挂载
        .motion(Theme.animSwap, value: errorText)
    }

    /* ---------- 私有 ---------- */

    /// 密码占位随模式切换（注册态显式提示长度下限）
    private var placeholderPassword: String {
        mode == "login" ? "密码" : "密码（至少 8 位）"
    }

    /// 字段校验角标：合规 → 绿勾（ok 成功语义色）；失焦后不合规 → 红叹号；空 / 未触碰 → 无（不打扰输入）。
    /// 角标带 a11y label（非 hidden）：校验状态对 VoiceOver 可达，不只在提交报错后才被感知。
    /// 进出用缩放 + 淡入（行内星标同款，只动 opacity / transform）——条件插入视图上
    /// symbolEffect(.bounce) 在插入帧不触发，transition 才可靠（AmmoView 行内星标口径）
    @ViewBuilder
    private var usernameStatusIcon: some View {
        if !username.isEmpty && usernameOk {
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.font(.md))
                // 合规勾走 ok 成功语义色（web .f-st.ok 同款，AccountView.vue:520-522 钦定
                // 「--accent 收回强调/选中本职——同页同义不双色」）：校验通过是「成功」结果，
                // 不在 accent 的激活/选中/进行中语义清单里（DESIGN.md §1.2）；原先 accent 勾
                // 与 danger 叹号同屏并置——同是校验结果，一个用强调色一个用结果色，不成对
                .foregroundStyle(Theme.ok)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("用户名格式正确")
        } else if !username.isEmpty && touchedUsername {
            Image(systemName: "exclamationmark.circle.fill")
                .font(Theme.font(.md))
                .foregroundStyle(Theme.danger)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("用户名格式不符")
        }
    }

    @ViewBuilder
    private var passwordStatusIcon: some View {
        if !password.isEmpty && passwordOk {
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.font(.md))
                .foregroundStyle(Theme.ok) // 同用户名勾：ok 成功语义（理由见 usernameStatusIcon 注释）
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("密码符合要求")
        } else if !password.isEmpty && touchedPassword {
            Image(systemName: "exclamationmark.circle.fill")
                .font(Theme.font(.md))
                .foregroundStyle(Theme.danger)
                .transition(.scale.combined(with: .opacity))
                .accessibilityLabel("密码不足 8 位")
        }
    }

    private func submit() {
        guard canSubmit else { return }
        submitting = true
        errorText = nil
        let name = username.trimmingCharacters(in: .whitespaces)
        let pass = password
        Task {
            do {
                if mode == "login" {
                    try await app.loginAccount(username: name, password: pass)
                } else {
                    try await app.registerAccount(username: name, password: pass)
                }
                password = ""
                okTick += 1
            } catch {
                errorText = friendlyError(error)
                errTick += 1
            }
            submitting = false
        }
    }

    /// 按 code 翻译成可行动提示（契约 §6.2 错误码）
    private func friendlyError(_ error: Error) -> String {
        if let api = error as? APIError, case .server(let code, let message) = api {
            switch code {
            case "USERNAME_TAKEN": return "这个用户名已被注册，换一个试试"
            case "AUTH_FAILED": return "用户名或密码不对，请检查后重试"
            case "INVALID_USERNAME": return "用户名需 2–16 个字符（字母 / 数字 / 下划线，各类文字均可）"
            case "INVALID_PASSWORD": return "密码需 8–64 个字符"
            case "RATE_LIMITED", "NETWORK": return message
            default: return message
            }
        }
        return error.localizedDescription
    }

    private var syncStateText: some View {
        // 行值字阶与同列其余行（用户名 / 同步内容）及设置页同口径：.md semibold——
        // 原先漏挂 font 会回退系统 body regular，同屏行值粗细不一。
        // 文案与颜色（tx/ok/danger）随同步状态平滑切换：单一 Text + contentTransition 交叉淡入，
        // 驱动键 syncState（SyncState: Equatable）；原先四个分支硬切。
        // syncing 用 tx 正文色（对齐 web .sync-v：syncing 不降色，AccountView.vue:742）——
        // 「同步中」是进行中的状态陈述，原先 dim 让它比两个结果态（ok/danger）都弱一档，
        // 盯着这行等同步完成的用户读到的却是一条像注释的灰字
        let pair: (text: String, color: Color)
        switch app.auth.syncState {
        case .idle: pair = (user == nil ? "未登录" : "待同步", Theme.dim)
        case .syncing: pair = ("同步中…", Theme.tx)
        case .ok: pair = ("已同步", Theme.ok)
        case .error: pair = ("同步失败", Theme.danger)
        }
        return Text(pair.text)
            .font(Theme.font(.md, weight: .semibold))
            .foregroundStyle(pair.color)
            .contentTransition(.opacity)
            .motion(Theme.animFast, value: app.auth.syncState)
    }

    private var user: AuthUser? { app.auth.user }

    /// 同步失败原因（syncState .error 载荷）；nil = 未失败。作 footer 分支条件与其 .motion 驱动键的同一来源
    private var syncErrorMessage: String? {
        if case .error(let message) = app.auth.syncState { return message }
        return nil
    }

    /// 云同步区页脚（与设置页 dataFooter 同构）：失败 → 警示图标 + danger 文案点名原因并指引重试；
    /// 否则 → 合并规则说明。警示图标固定 exclamationmark.triangle（§6.1-2 语义映射）——原先纯文字 danger
    /// 与设置页「X刷新失败」的 Label 图标行不是一个长相，同为 Section footer 里的错误说明却两套呈现；
    /// 两分支各挂 .transition(.opacity)，进出场由 footer 处的 .motion(animSwap) 驱动
    @ViewBuilder
    private var syncFooter: some View {
        if let message = syncErrorMessage {
            Label("\(message)。可点「立即同步」重试，本地功能不受影响。", systemImage: "exclamationmark.triangle")
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.danger)
                .transition(.opacity)
        } else {
            Text("自选星标取并集、囤货台账按弹名合并（同名以本机为准），任何一端的数据都不会丢；登录期间改动自动上云。")
                .font(Theme.font(.xs))
                .foregroundStyle(Theme.faint)
                .transition(.opacity)
        }
    }

    /// 「上次同步」行显示门禁：lastSyncAt 不随登出清零（AuthStore 禁改，logout/clearLocal 均不碰它），
    /// 换账号登录的首同步完成前会短暂显示上一账号的时间戳；syncState 在登出时被置 .idle、
    /// 首同步一开始（pullAndMerge）即离开 .idle——用它挡掉跨账号陈旧值。同用户冷启动时
    /// lastSyncAt 本就为 nil（不持久化），观感无变化
    private var showLastSync: Bool {
        app.auth.lastSyncAt != nil && app.auth.syncState != .idle
    }

    /// 同步内容全零（对齐 web syncEmpty：自选与台账任一项有数据即恢复读数；iOS 端无买入价项，两项即全量）
    private var syncEmpty: Bool {
        app.favorites.names.isEmpty && app.positions.positions.isEmpty
    }

    private func createdAtText(_ iso: String) -> String {
        // ISO-8601（契约带毫秒）→ 本地日期展示；解析失败原样显示
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        return date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? iso
    }

    private func rowTitle(_ s: String) -> some View {
        Text(s).font(Theme.font(.md)).foregroundStyle(Theme.tx)
    }

    private func sectionHeader(_ s: String) -> some View {
        Text(s).font(Theme.font(.micro, weight: .bold)).foregroundStyle(Theme.accent)
    }
}

/// 登录 / 注册主操作按钮：全宽 accent 实心、bg 深字（对齐 base.css .submit 的同款语义），
/// 按压 0.82 透明度 + animFast；动画挂载收编 .motion（RM 置 nil 即按压瞬时切换，色面态仍生效）
private struct AuthPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.font(.md, weight: .bold))
            .foregroundStyle(Theme.bg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.radiusTile, style: .continuous))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .motion(Theme.animFast, value: configuration.isPressed)
    }
}
