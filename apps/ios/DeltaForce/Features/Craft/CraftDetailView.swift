// CraftDetailView.swift — 制造配方详情：利润拆解 + 材料清单 + 参照区间
import DeltaForceCore
import SwiftUI

struct CraftDetailView: View {
    @Environment(AppModel.self) private var app
    let item: CraftItem
    let placeLabel: String

    // 本页局部触觉 tick（刷新成败二分；trigger 只绑本页 State，对齐 ItemDetailView）
    @State private var refreshOkTick = 0
    @State private var refreshErrTick = 0

    /// 数据解冻（§4.2-1，对齐 ItemDetailView.resolved）：按 id 现查制造快照，
    /// SSE craft 事件 / 轮询替换 snapshot 后页面数字自动跟随；查无（配方下架 /
    /// 快照未到）回落 push 时刻的冻结值
    private var resolved: CraftItem {
        app.craft.snapshot?.items.first { $0.id == item.id } ?? item
    }

    private var profitColor: Color {
        if let p = resolved.profit { return p >= 0 ? Theme.ok : Theme.danger }
        return Theme.dim
    }

    /// 刷新失败横幅文案（对齐 CraftView.bannerMessage 去重口径）：有快照的刷新失败才提示；
    /// 无快照不会停在本页（详情由有快照的列表 push 进来），无需 RetryErrorRow 兜底
    private var bannerMessage: String? {
        app.craft.snapshot != nil ? app.craft.lastError : nil
    }

    var body: some View {
        let it = resolved
        List {
            // 头部：图标 / 名称 / 徽标 / 主角数字（时利 hero）
            Section {
                // 刷新失败可见回声（§1.5 闭环反馈，对齐 ItemDetailView 横幅）：下方 .refreshable 的
                // 成败二分触感只覆盖开振动的用户，此前关振动的用户下拉失败后页面毫无变化——
                // 「拉了但没更新」只能靠猜。横幅成功任一次刷新即随 lastError 置 nil 退场；
                // 进出场事务由 List 层 .motion(value: bannerMessage != nil) 驱动（§3-F 提示条口径）
                if let msg = bannerMessage {
                    FeedErrorBanner(message: msg)
                        .transition(.opacity)
                }
                HStack(spacing: Theme.Space.md) {
                    ItemThumb(pic: it.output.pic, size: 52)
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        HStack(spacing: 6) {
                            Text(it.output.name)
                                .font(Theme.font(.lg, weight: .semibold))
                                .foregroundStyle(Theme.txStrong)
                                .lineLimit(2)
                            if it.output.count > 1 {
                                Text("×\(it.output.count)")
                                    .font(Theme.monoFont(.xs, weight: .semibold))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                        // 徽标行 ViewThatFits 降级（§4.2-2 详情头部 / §7-6 AX 韧性，对齐 ItemDetailView 头部）：
                        // 三枚徽标 fixedSize 恒保理想宽，特大字号下横向溢出名称列。先省「Lv.N 解锁」
                        //（利润拆解 / 材料区不依赖它）再省台名，等级徽标恒留——与列表最佳卡同序
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 6) {
                                CategoryChip(text: placeLabel)
                                GradeBadge(grade: it.output.grade)
                                if let lv = it.requiredLevel {
                                    StatusChip(text: "Lv.\(lv) 解锁", tint: Theme.dim)
                                }
                            }
                            HStack(spacing: 6) {
                                CategoryChip(text: placeLabel)
                                GradeBadge(grade: it.output.grade)
                            }
                            GradeBadge(grade: it.output.grade)
                        }
                    }
                }
                .padding(.vertical, Theme.Space.xs)
                // 缺价配方的服务端字段是 0 而非 null（契约 §1.3 降级展示）：
                // 时利 hero 以 hasEstimate 为门槛，否则走缺价警示而非「+0」绿色
                if it.hasEstimate, let p = it.profitPerHour {
                    // 主角数字（§1.1）：详情页唯一 hero；数字滚动（§3-E 单点关键数字）——
                    // SSE craft 事件替换快照后 resolved 自动跟随，RM 下 .identity 直跳
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        // hero 补 minScale 0.75（§4.2-2「最重要的数字不得被截成 12…」）：全仓其余
                        // hero / lead Mono 均带缩放兜底（ItemDetailView 详情现价同场景同参 0.75），本页是
                        // 最后一处裸 hero——AX 大字号 × 七位数时利与右侧单位同行争宽时缩放让位而非截断。
                        // 列表最佳卡 hero 是 0.7：窄列可用宽更紧、地板随宽走，非漏改
                        Mono(p >= 0 ? "+\(Fmt.price(p))" : Fmt.price(p), step: .hero, color: profitColor, minScale: 0.75)
                            .numericChange(value: p)
                        Text("每小时 · \(it.periodLabel ?? "—")")
                            .font(Theme.font(.xs))
                            .foregroundStyle(Theme.faint)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("每小时利润 \(Fmt.price(p))，制造耗时 \(it.periodLabel ?? "未知")")
                    .transition(.opacity) // 与缺价警示互切淡入淡出（§3-H，事务由 List 层 .motion 驱动）
                } else if !it.isComplete {
                    Label("材料或产出缺价（\(it.missingPriceCount) 项），利润无法估算", systemImage: "exclamationmark.triangle")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.warn)
                        .transition(.opacity) // 同上：分支互切淡入淡出
                } else {
                    Label("制造耗时数据缺失，时利无法估算", systemImage: "exclamationmark.triangle")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.warn)
                        .transition(.opacity)
                }
            }
            .listRowBackground(Theme.card)

            // 利润拆解（缺价时整节退场）
            if it.hasEstimate {
                Section("利润拆解") {
                    StatQuadRow(
                        StatCell(label: "产出收入", value: Fmt.price(it.revenue), color: Theme.txStrong),
                        // 费率并入标签而非拼进数值：全角括号后缀曾把本格值撑宽 ~20pt，
                        // 与「材料成本」的列距被挤到其余两列的 1/3（§1.3 同层级同档，四格值宽须同量级）
                    StatCell(label: feeLabel, value: Fmt.price(it.fee), color: Theme.dim),
                        StatCell(label: "材料成本", value: Fmt.price(it.cost), color: Theme.dim),
                        StatCell(label: "净利润", value: Fmt.price(it.profit), color: profitColor, emphasis: .hero)
                    )
                    .padding(.vertical, Theme.Space.xs)
                    // 公式行：与网页端展开区同文案；正文含实义金额，走等宽数字（同 MethodNote 口径）。
                    // 「；」后强制换行：自然折行时「＝」可能恰好落在第二行行首（SwiftUI 不做中文避头尾），分段后行首恒为「收入」
                    Text("利润 = 收入 \(Fmt.price(it.revenue)) − 手续费 \(Fmt.price(it.fee)) − 材料 \(Fmt.price(it.cost))；\n收入 = 产出单价 \(Fmt.price(it.output.price)) × \(it.output.count)。")
                        .font(Theme.font(.xs))
                        .monospacedDigit()
                        .foregroundStyle(Theme.faint)
                }
                .listRowBackground(Theme.card)
            }

            // 材料清单
            Section("材料 · \(it.materials.count) 项") {
                ForEach(it.materials) { m in
                    HStack(spacing: Theme.Space.sm) {
                        ItemThumb(pic: m.pic, size: 32)
                        // 行内垂直间距统一 Space.xs（T8 收编 2/3/4 混用；本行原为字面量 2）
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            HStack(spacing: 6) {
                                Text(m.name).font(Theme.font(.sm, weight: .semibold)).foregroundStyle(Theme.txStrong)
                                Text("×\(m.count)").font(Theme.monoFont(.xs)).foregroundStyle(Theme.dim)
                            }
                            // 单价行常驻：缺价材料原先整行消失——行高随价格有无跳动、且缺价无线索；
                            // 缺价显「无价」warn，与头部缺价警示 / 列表行「价格缺失」徽标同语义同色，
                            // 指认「这一项是配方无法估算的原因」；金额走等宽数字（同公式行口径）
                            Text(m.price != nil ? "单价 \(Fmt.price(m.price))" : "无价")
                                .font(Theme.font(.xs))
                                .monospacedDigit()
                                .foregroundStyle(m.price != nil ? Theme.faint : Theme.warn)
                        }
                        Spacer(minLength: 4)
                        // 合计位占位「—」faint + 常规字重（全站缺价口径 = web .na「faint + 400」）：警示留在
                        // 来源位（单价「无价」），占位符不再抢语义色、也不借 sub 档默认 semibold 冒充一枚
                        // 有分量的数字；以 price 判缺价——无价材料的 cost 不可当真实成本
                        if m.price != nil {
                            Mono(Fmt.price(m.cost), step: .sub, color: Theme.txStrong)
                        } else {
                            Mono("—", step: .sub, weight: .regular, color: Theme.faint)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(matA11y(m))
                }
            }
            .listRowBackground(Theme.card)

            // 参照区间（缺价项的 ROI / 产出单价同样以 hasEstimate 门槛降级为「—」）
            Section("参照") {
                StatQuadRow(
                    // 参照格缺价口径（对齐 web .na）：估算不可用（!hasEstimate）或字段缺值时「—」faint。
                    // 有值时走 dim 而非 warn（web 今日最高列即 dimtx、7 日最高亦为 faint 正文）：warn 在本页
                    // 已被「价格缺失」徽标 / 「无价」单价 / 头部缺价警示三处占用为「数据缺失」语义，
                    // 历史最高只是次级参照数据，同色会让两个毫不相干的含义在同一屏撞色（§1.2 信号色
                    // 只上游戏语义数据；「乐观参照，不构成承诺」由下方说明文字承担，不靠颜色暗示）
                    StatCell(label: "今日最高", value: refValue(it.todayMaxProfit), color: it.hasEstimate && it.todayMaxProfit != nil ? Theme.dim : Theme.faint),
                    StatCell(label: "7 日最高", value: refValue(it.sevenDayMaxProfit), color: it.hasEstimate && it.sevenDayMaxProfit != nil ? Theme.dim : Theme.faint),
                    StatCell(label: "成本回报", value: roiText, color: roiColor),
                    StatCell(label: "产出单价", value: it.hasEstimate ? Fmt.price(it.output.price) : "—", color: it.hasEstimate ? Theme.txStrong : Theme.faint)
                )
                .padding(.vertical, Theme.Space.xs)
                Text("今日 / 7 日最高利润为历史乐观参照，不构成承诺；制造期间价格波动、挂单深度与实际成交均会造成偏差。")
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.faint)
            }
            .listRowBackground(Theme.card)
        }
        .themedList()
        .listStyle(.insetGrouped)
        // 状态进场（MOTION.md §3-H / 原则 1「表达状态变化」）：SSE 刷新补齐 / 失去价格时
        // hasEstimate 翻转——hero↔缺价警示互换、「利润拆解」整节进出、材料行单价行增减，挂
        // animSwap 事务后不再瞬现瞬隐、下方内容平滑让位（拆解节 ≈150pt 高，硬切会整页跳动）。
        // 键只认 hasEstimate：价格数值本身的变化不触发——hero 数字另有 .numericChange 专管，
        // 材料行 / 拆解四格 / 参照区的多行数字维持瞬时更新（§3-E / 原则 3）
        .motion(Theme.animSwap, value: it.hasEstimate)
        // 刷新失败横幅进出场淡入淡出（§3-F 提示条口径，与 CraftView 列表页同款挂法）：键只认有无横幅，
        // 文案变化不触发；横幅在头部 Section 首行，带事务后名称行随布局平滑让位而非整页跳动
        .motion(Theme.animSwap, value: bannerMessage != nil)
        // 导航标题用产物名（对齐 ItemDetailView）：长列表滚到中段时导航栏仍指示当前配方
        .navigationTitle(it.output.name)
        .navigationBarTitleDisplayMode(.inline)
        // 详情可下拉刷新（§4.2-4 同款）：只调用既有 refresh，与列表页手势心智一致
        .refreshable {
            await app.craft.refresh()
            if app.craft.lastError != nil { refreshErrTick += 1 } else { refreshOkTick += 1 }
        }
        .sensoryFeedback(.success, trigger: refreshOkTick)
        .sensoryFeedback(.error, trigger: refreshErrTick)
    }

    /// 手续费格标签：费率以「手续费·13%」形式放进 micro 标签（值列只留金额；nil fee 由 Fmt.price 兜底「—」）
    private var feeLabel: String {
        guard let rate = resolved.feeRate else { return "手续费" }
        return "手续费·\(Int((rate * 100).rounded()))%"
    }
    /// 参照格数值：估算不可用时一律「—」——今日 / 7 日最高虽是独立字段，但缺价配方的
    /// 参照无决策意义，与 web 端 missingPriceCount 门槛同口径（CraftView.vue 今日最高列）
    private func refValue(_ v: Double?) -> String {
        resolved.hasEstimate ? Fmt.price(v) : "—"
    }
    /// 材料行成句朗读：名称 / 数量 / 单价（缺价=无价）/ 合计——单价补进朗读，
    /// 与视觉常驻单价行信息对齐（原先只有名称 + 合计）
    private func matA11y(_ m: CraftMaterial) -> String {
        var parts = ["\(m.name) 数量 \(m.count)"]
        parts.append(m.price != nil ? "单价 \(Fmt.price(m.price))" : "无价")
        if m.price != nil, let cost = m.cost { parts.append("合计 \(Fmt.price(cost))") }
        return parts.joined(separator: "，")
    }
    private var roiText: String {
        guard resolved.hasEstimate, let roi = resolved.roi else { return "—" }
        return roi >= 0 ? "+\(Int((roi * 100).rounded()))%" : "\(Int((roi * 100).rounded()))%"
    }
    private var roiColor: Color {
        if resolved.hasEstimate, let roi = resolved.roi { return roi >= 0 ? Theme.ok : Theme.danger }
        // 占位「—」faint（与主卡 roiColor 同步）：缺价时参照区四格占位全部 faint 整排安静退场，
        // 不留 dim/txStrong/warn 三色混杂的「半数据」观感
        return Theme.faint
    }
}
