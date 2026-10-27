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
                        Text("自选 \(app.favorites.names.count) · 台账 \(app.positions.positions.count)")
                            .font(Theme.font(.md, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Theme.dim)
                    } label: {
                        rowTitle("同步内容")
                    }
                    if let t = app.auth.lastSyncAt {
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
                    if case .error(let message) = app.auth.syncState {
                        Text("\(message)。可点「立即同步」重试，本地功能不受影响。")
                            .font(Theme.font(.xs))
                            .foregroundStyle(Theme.danger)
                    } else {
                        Text("自选星标取并集、囤货台账按弹名合并（同名以本机为准），任何一端的数据都不会丢；登录期间改动自动上云。")
                            .font(Theme.font(.xs))
                            .foregroundStyle(Theme.faint)
                    }
                }
                .listRowBackground(Theme.card)

                Section {
                    Button("退出登录", role: .destructive) {
                        confirmLogout = true // 先确认再执行：一次误触不应让全部设备下线
                    }
                    .font(Theme.font(.md, weight: .semibold))
                    .confirmationDialog(
                        // 两步确认文案对齐 Web 端账号页口径（视觉复验修复）：标题明确指向当前账号，
                        // 「所有设备下线」后果从按钮文案移入 message（信息不丢，按钮回到 取消/退出 二元选择）
                        "确定退出当前账号？",
                        isPresented: $confirmLogout,
                        titleVisibility: .visible
                    ) {
                        Button("退出", role: .destructive) {
                            Task { await app.logoutAccount() }
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
                    Picker("方式", selection: $mode) {
                        Text("登录").tag("login")
                        Text("注册").tag("register")
                    }
                    .pickerStyle(.segmented)

                    // 用户名行：失焦后不合规亮红、合规亮绿勾（空值不亮，避免开场报错）
                    HStack(spacing: Theme.Space.sm) {
                        TextField("用户名（2–16 字符）", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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
                    .opacity(canSubmit ? 1 : 0.45)
                    // 失能降透明随校验结果平滑过渡（原先逐字输入到合规瞬间硬跳 0.45 → 1）
                    .motion(Theme.animFast, value: canSubmit)
                    .disabled(!canSubmit)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))

                    if let errorText {
                        // §5 P2：错误行淡入淡出（纯透明度，Reduce Motion 跳过）；出现/消失由下方
                        // .motion(animSwap, value: errorText) 统一驱动，赋值处无需各自 withAnimation
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.font(.xs))
                            .foregroundStyle(Theme.danger)
                            .transition(.opacity)
                    }
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
        // 「上次同步」条件行的进出由下方 lastSyncAt motion 一并驱动
        .contentSwap(app.auth.user != nil)
        .motion(Theme.animSwap, value: app.auth.lastSyncAt != nil)
        .frame(maxWidth: 600)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .navigationTitle(mode == "login" && app.auth.user == nil ? "登录" : "账号")
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
        // 错误行出现 / 消失（提交失败、切换方式清除）统一淡入淡出：animSwap 档对齐兄弟页
        // 错误 banner（AmmoView/RadarView 的 bannerMessage 同款）；全站 .animation 一律经 .motion 挂载
        .motion(Theme.animSwap, value: errorText)
    }

    /* ---------- 私有 ---------- */

    /// 密码占位随模式切换（注册态显式提示长度下限）
    private var placeholderPassword: String {
        mode == "login" ? "密码" : "密码（至少 8 位）"
    }

    /// 字段校验角标：合规 → 绿勾（accent）；失焦后不合规 → 红叹号；空 / 未触碰 → 无（不打扰输入）。
    /// 角标带 a11y label（非 hidden）：校验状态对 VoiceOver 可达，不只在提交报错后才被感知。
    /// 进出用缩放 + 淡入（行内星标同款，只动 opacity / transform）——条件插入视图上
    /// symbolEffect(.bounce) 在插入帧不触发，transition 才可靠（AmmoView 行内星标口径）
    @ViewBuilder
    private var usernameStatusIcon: some View {
        if !username.isEmpty && usernameOk {
            Image(systemName: "checkmark.circle.fill")
                .font(Theme.font(.md))
                .foregroundStyle(Theme.accent)
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
                .foregroundStyle(Theme.accent)
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
        // 文案与颜色（dim/ok/danger）随同步状态平滑切换：单一 Text + contentTransition 交叉淡入，
        // 驱动键 syncState（SyncState: Equatable）；原先四个分支硬切
        let pair: (text: String, color: Color)
        switch app.auth.syncState {
        case .idle: pair = (user == nil ? "未登录" : "待同步", Theme.dim)
        case .syncing: pair = ("同步中…", Theme.dim)
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
