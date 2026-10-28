// ItemDetailView.swift — 单品详情（子弹 / 雷达物品共用）：大图 + 统计 + 预计卖出 + 双源校验
// 数据解冻（§4.2-1）：body 现查 environment 两路快照，push 时刻的冻结 item 仅作同名查无时的兜底；
// 头部 hero 现价 + 年龄角标（§4.2-2/3）、下拉刷新（§4.2-4）、数字滚动与星标弹跳（§5）。
import DeltaForceCore
import SwiftUI

struct ItemDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: MarketItem
    // 本页局部触觉 tick（星标 / 刷新成败；trigger 只绑本页 State）
    @State private var favTick = 0
    @State private var refreshOkTick = 0
    @State private var refreshErrTick = 0
    // 囤货试算（交易测算组内）：数量档 + 我的成本；posTick = 记入/移出台账的账本操作触感
    @State private var calcQty = 100
    @State private var calcCost = 0.0 // 0 = 未初始化，onAppear 回填（台账已录价 ?? 现价）
    @State private var posTick = 0
    @State private var calcTick = 0 // 试算 chip 选择（§5 筛选/菜单类交互：.selection 触感）
    @State private var posPulse = 0 // 记账确认脉冲触发器（记入/更新囤货 +1，移出不弹；trigger 只绑本页 State）
    // 数量档 chips 选中底滑移（matchedGeometryEffect）的几何命名空间：须由视图持有、跨 chip 共享
    @Namespace private var calcNS
    // 数字键盘（numberPad/decimalPad）无回车键，输入框宽度需随字阶同步放大才装得下特大号输入
    @ScaledMetric(relativeTo: .footnote) private var qtyFieldWidth = 72
    @ScaledMetric(relativeTo: .footnote) private var costFieldWidth = 90
    // 键盘收起出口（数字键盘无回车）：scrollDismissesKeyboard 要「滚动」才能收，而键盘恰好
    // 遮着正下方的试算结果——FocusState + 键盘上沿「完成」给一步收起的标准出口
    private enum CalcField: Hashable { case qty, cost }
    @FocusState private var calcField: CalcField?

    /// 解冻命中路径（§4.2-3）：年龄角标的数据源必须跟随——两路快照独立轮询、
    /// lastRefreshAt 各自不同，照单数「feed」必然出现雷达物品挂行情年龄的错配
    private enum FeedOrigin { case market, radar, frozen }

    private var origin: FeedOrigin {
        if app.market.items.contains(where: { $0.name == item.name }) { return .market }
        if app.radar.items.contains(where: { $0.name == item.name }) { return .radar }
        return .frozen
    }

    /// 实时条目（§4.2-1）：两路快照按名称命中即跟随（60s 轮询 / SSE 版本前进自动更新），全未命中回落冻结值
    private var resolved: MarketItem {
        app.market.items.first { $0.name == item.name }
            ?? app.radar.items.first { $0.name == item.name }
            ?? item
    }

    /// 两路快照皆败（与 refreshErrTick 触感同口径）：单路活着页面数据仍可跟随，不出横幅打扰；
    /// 任一路刷新成功即置 lastError = nil（State/FeedModel.swift:84）→ 横幅自动退场
    private var bothFeedsFailed: Bool {
        app.market.lastError != nil && app.radar.lastError != nil
    }

    /// TTK 联动：弹名 → 穿透等级（shared/data/ammo-alias.json 映射；nil = 无映射
    /// 不显徽章——一对多歧义 / 国服命名差异 / 弓弩箭矢，宁缺勿错）
    private var pen: Int? {
        app.ammoAlias.pen(marketName: item.name, calibers: app.ttk.data?.calibers ?? [:])
    }

    var body: some View {
        let it = resolved
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                // 刷新失败可见回声（§1.5 闭环反馈）：触感二分只覆盖开振动的用户，横幅补齐视觉位——
                // 「拉了但没更新」不再靠猜；文案取主源（行情），成功任一路即淡出
                if bothFeedsFailed {
                    FeedErrorBanner(message: app.market.lastError)
                        .transition(.opacity)
                }
                header(it)
                chartCard(it)
                stats(it)
                sellEta(it)
                if it.hiRank != nil { radarCard(it) }
                MethodNote(source: nil).card()
            }
            .padding(12)
            // 横幅进出（MOTION.md §3-H 状态进场档）：animSwap 淡入淡出，RM 门内建于 .contentSwap；
            // 只绑错误布尔，不影响其他内容更新
            .contentSwap(bothFeedsFailed)
            // regular 宽度（iPad / 横屏）内容列上限 640 居中：对齐网页 --wrap 可读列，大图不再全宽拉伸
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        // 数字键盘没有回车键：滚动跟手收起，否则输入成本后键盘常驻、遮住试算结果下半区
        .scrollDismissesKeyboard(.interactively)
        // TTK 联动兜底：从雷达页进详情时 ttk.json 可能尚未加载（行情页 onAppear 已加载则空转）；
        // 囤货试算成本回填也在此：台账已录价优先，无记录按现价（resolved 首帧已就绪）
        .onAppear {
            app.ttk.loadIfNeeded()
            if calcCost == 0 {
                calcCost = app.positions.position(of: item.name)?.cost ?? (resolved.current ?? 0)
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        // 详情可下拉刷新（§4.2-4）：只是调用既有方法，与列表页手势心智一致；
        // 二分触感（§5）——两路都失败才算失败（单路活着，页面数据仍可跟随）
        .refreshable {
            await app.market.refresh()
            await app.radar.refresh()
            if app.market.lastError != nil, app.radar.lastError != nil {
                refreshErrTick += 1
            } else {
                refreshOkTick += 1
            }
        }
        // 触感语义分层收紧：星标自选是轻交互，降为轻 impact；.success 只留给
        // 刷新成败类任务结果（下方 refreshOkTick），避免「记事成功」的错觉语义
        .sensoryFeedback(.impact(weight: .light), trigger: favTick)
        .sensoryFeedback(.success, trigger: refreshOkTick)
        .sensoryFeedback(.error, trigger: refreshErrTick)
        .sensoryFeedback(.selection, trigger: posTick)
        .sensoryFeedback(.selection, trigger: calcTick)
        .toolbar {
            // 星标须包 ToolbarItem：本闭包加入键盘位 ToolbarItemGroup 后走多元素
            // ToolbarContentBuilder 路径，裸 Button + accessibilityLabel（ModifiedContent）
            // 不满足 ToolbarContent 约束；navigationBarTrailing 即裸按钮的原自动落位，观感不变
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    app.favorites.toggle(it.name)
                    favTick += 1
                } label: {
                    starIcon(starred: app.favorites.contains(it.name))
                }
                .accessibilityLabel(app.favorites.contains(it.name) ? "取消自选" : "加入自选")
            }
            // 键盘上沿「完成」（试算输入的唯一显式收起出口；无焦点时系统自动隐藏本组）
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { calcField = nil }
            }
        }
    }

    /// 自选星标（§5 P2）：切换时图标弹跳；Reduce Motion 跳过 symbolEffect（§7-9）
    @ViewBuilder
    private func starIcon(starred: Bool) -> some View {
        let icon = Image(systemName: starred ? "star.fill" : "star")
            .foregroundStyle(Theme.warn)
        if reduceMotion {
            icon
        } else {
            icon.symbolEffect(.bounce, value: starred)
        }
    }

    // MARK: - 头部

    /// 头部（§4.2-2）：徽标行 ViewThatFits 降级（宽不足先省「涨幅榜」chip 再省分类 chip）；
    /// 现价迁 hero 档 + minScale 0.75（页面唯一主角数字，不得截断），下挂数据年龄角标（§4.2-3）
    private func header(_ it: MarketItem) -> some View {
        HStack(spacing: Theme.Space.md) {
            ItemThumb(pic: it.pic, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        GradeBadge(grade: it.grade)
                        if let pen { PenBadge(pen: pen) }
                        if let c = it.category { CategoryChip(text: c) }
                        if let r = it.hiRank { CategoryChip(text: "涨幅榜 #\(r)") }
                    }
                    HStack(spacing: 6) {
                        GradeBadge(grade: it.grade)
                        if let pen { PenBadge(pen: pen) }
                        if let c = it.category { CategoryChip(text: c) }
                    }
                    HStack(spacing: 6) {
                        GradeBadge(grade: it.grade)
                    }
                }
                HStack(spacing: Theme.Space.sm) {
                    SignalChip(signal: it.signal, anomaly: it.isAnomaly)
                    Text(it.isAnomaly ? "双源口径分歧，信号压制为观望" : it.signal.hint)
                        .font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Theme.Space.xs) {
                Text("现价").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                // 现价数字滚动（§4.2-6 / MOTION.md §3-E 单点关键数字）：收编到共享 .numericChange
                // （= contentTransition(.numericText()) + animMed，RM 门内建 .identity + 无动画，行为不变）
                Mono(Fmt.price(it.current), step: .hero, minScale: 0.75)
                    .numericChange(value: it.current)
                ageBadge
            }
        }
        .card()
    }

    /// 数据年龄角标（§4.2-3）：「数据 X 分钟前 · 版本 vX」micro faint（>5 分钟转 warn），
    /// TimelineView 30s 刷新；数据源跟随解冻命中路径，frozen 兜底固定文案。
    /// 尾挂 .id(ageResetID)：TimelineView 只按 30s 周期 tick，刷新成功（lastRefreshAt 前进）后
    /// 若不重建视图，角标会带着旧 ctx.date 继续显示旧年龄——对齐共享层 C6 的 id 方案，
    /// 任一前进即重建、以当前时间立即归零（frozen 无年龄，用 origin 定身防 market↔radar 串味）
    private var ageBadge: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            switch origin {
            case .market:
                ageText(app.market.ageMinutes(now: ctx.date), version: app.market.snapshot?.version)
            case .radar:
                ageText(app.radar.ageMinutes(now: ctx.date), version: app.radar.snapshot?.version)
            case .frozen:
                Text("数据可能过期").foregroundStyle(Theme.faint)
            }
        }
        .font(Theme.font(.micro))
        .monospacedDigit()
        .lineLimit(1)
        .id(ageResetID)
    }

    /// 角标重算身份键：命中路的 lastRefreshAt（秒值）+ origin 前缀——同一字符串 ⇔ 无需重建
    private var ageResetID: String {
        switch origin {
        case .market: "m\(app.market.lastRefreshAt?.timeIntervalSince1970 ?? 0)"
        case .radar: "r\(app.radar.lastRefreshAt?.timeIntervalSince1970 ?? 0)"
        case .frozen: "f"
        }
    }

    @ViewBuilder
    private func ageText(_ age: Double?, version: String?) -> some View {
        if let age {
            // 含中文：默认 design + 等宽数字；>5 分钟转 warn 提示数据陈旧。
            // 版本走视图层短版（shortVersion）：Core 全格式 16 字符在头部右列（现价 hero
            // 决定的 ~133pt 列宽）必然截断成「版本 2026-08-2…」（截图实证），年份信息
            // 在此价值最低；minScale 直接挂 Text（容器级不传播到子 Text）
            Text("数据 \(MarketMeta.fmtAge(minutes: age))前 · \(shortVersion(version))")
                .minimumScaleFactor(0.8)
                .foregroundStyle(age > 5 ? Theme.warn : Theme.faint)
        } else {
            Text("数据可能过期").foregroundStyle(Theme.faint)
        }
    }

    /// 版本串（202608210500 型）→「08-21 05:00」月日时分短标签：头部角标专用。
    /// formatVersionLabel（Core）的全格式「2026-08-21 05:00」由设置页等有整行空间的
    /// 场景继续使用；此处不重复造轮子只裁剪同源数据，异常短串回退 Core 原格式兜底
    private func shortVersion(_ v: String?) -> String {
        guard let v, v.count >= 10 else { return MarketMeta.formatVersionLabel(v) }
        let s = Array(v)
        let md = "\(String(s[4..<6]))-\(String(s[6..<8]))"
        let hm = s.count >= 12 ? "\(String(s[8..<10])):\(String(s[10..<12]))" : "\(String(s[8..<10])):00"
        return "\(md) \(hm)"
    }

    // MARK: - 走势图卡

    /// 图表卡（打磨起点「P25/P75 参考线图例」）：此前是全页唯一无眉题的卡，与「预计卖出时间」
    /// 「双源交叉验证」的标题节拍脱队；图内参考线自带数值标注（P25 1,234）但不解释语义，
    /// 图例补上分位含义（P25=低位 / P75=高位），配色与图内 RuleMark（PriceChart.swift P25 ok /
    /// P75 danger）及统计组「参考区间」取值列逐一同源；宽不足时图例折到标题下（ViewThatFits
    /// 降级，AX 特大字号不丢信息）
    private func chartCard(_ it: MarketItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Space.xs) {
                    chartTitle
                    Spacer(minLength: Theme.Space.sm)
                    legend
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    chartTitle
                    legend
                }
            }
            .accessibilityElement(children: .combine) // 眉题 + 图例合并一次读完
            PriceChart(item: it)
        }
        .card()
    }

    private var chartTitle: some View {
        // 含中文标题：默认 design；标题自带实义数字「7」，等宽修饰让它与其余口径数字同节拍
        Text("7 天走势").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
    }

    /// 参考线图例：短划线微标 + 语义标签，教会「绿线=该买的低位区、红线=该卖的高位区」
    private var legend: some View {
        HStack(spacing: Theme.Space.sm) {
            dashLegend(color: Theme.ok, text: "P25 低位参考")
            dashLegend(color: Theme.danger, text: "P75 高位参考")
        }
    }

    private func dashLegend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            // 缩微虚线：两枚 1.5pt 短划模拟图内 [4,3] 虚线参考线（同色同义）；纯装饰，
            // 语义由文本承担（a11y 纪律与 Sparkline 等纯图形一致）
            HStack(spacing: 1.5) {
                Capsule().fill(color).frame(width: 3, height: 1.5)
                Capsule().fill(color).frame(width: 3, height: 1.5)
            }
            .accessibilityHidden(true)
            // 信号语义色上数据文案：与 SignalChip、「参考区间」P25/P75 取值列同款既有用法
            Text(text).font(Theme.font(.micro, weight: .semibold)).foregroundStyle(color)
        }
        .fixedSize(horizontal: true, vertical: false) // 图例恒单行：让 VTF 按理想宽测量，放不下整体走降级变体
    }

    // MARK: - 统计

    /// 三组统计（§4.2-7）：micro faint 语义眉题（参考区间 / 区间极值 / 交易测算）；
    /// 四格行换共享 StatQuadRow（C5：本页原私有 statQuad 已删，4→2×2 降级由共享组件承担）
    /// 24h 涨跌色（外部参照组）：涨绿跌红（涨跌色恒定语义，同行情行方向标）
    private func chgColor(_ chg: Double?) -> Color? {
        guard let chg else { return nil }
        return chg >= 0 ? Theme.ok : Theme.danger
    }

    /// 军需处倒挂幅度：现价相对材料折算价的高出比例（折算价无效时 0）；>30% 转警示色
    private func tradeSpread(_ it: MarketItem) -> Double {
        guard let t = it.trade, t.costPerRound > 0, let cur = it.current, cur.isFinite else { return 0 }
        return cur / t.costPerRound - 1
    }

    private func stats(_ it: MarketItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            statGroup("参考区间") {
                StatQuadRow(
                    StatCell(label: "7 天分位", value: Fmt.rankPercent(it.rank)),
                    StatCell(label: "P25", value: Fmt.price(it.p25), color: Theme.ok),
                    StatCell(label: "P50", value: Fmt.price(it.p50)),
                    StatCell(label: "P75", value: Fmt.price(it.p75), color: Theme.danger)
                )
            }
            Divider().overlay(Theme.line2) // 弱分隔（T5）：统计组之间用更轻的分隔线
            statGroup("区间极值") {
                StatQuadRow(
                    StatCell(label: "周低", value: Fmt.price(it.weekLow)),
                    StatCell(label: "周高", value: Fmt.price(it.weekHigh)),
                    StatCell(label: "税率", value: Fmt.pct(it.taxRate).replacingOccurrences(of: "+", with: "")),
                    StatCell(label: "样本", value: "\(it.curve.count) 点")
                )
            }
            // 外部参照组（旁路参照不进信号；四项至少有一项才出组，缺项显「—」）：
            // 24h 涨跌（快照 chg24h）/ 官方均价与偏离（腾讯 AMS 对账口径）/ 军需处兑换折算
            if it.chg24h != nil || it.official != nil || it.trade != nil {
                Divider().overlay(Theme.line2)
                statGroup("外部参照（旁路，不进信号）") {
                    StatQuadRow(
                        StatCell(label: "24h 涨跌", value: Fmt.pct(it.chg24h), color: chgColor(it.chg24h) ?? Theme.tx),
                        StatCell(label: "官方均价", value: Fmt.price(it.official?.avg)),
                        StatCell(
                            label: "官方偏离",
                            value: Fmt.pct(it.official?.dev),
                            color: (abs(it.official?.dev ?? 0) > 0.15) ? Theme.warn : Theme.tx
                        ),
                        StatCell(label: "军需处折算/发", value: Fmt.price(it.trade?.costPerRound), color: tradeSpread(it) > 0.3 ? Theme.warn : Theme.tx)
                    )
                }
            }
            Divider().overlay(Theme.line2)
            statGroup("交易测算") {
                StatQuadRow(
                    // 标签压到单行宽（~69pt）：全形「目标挂卖 (近3天P75)」(~100pt) 在四格 ~80pt
                    // 列宽内必折行，把本格数值顶离行基线（截图实证）；完整口径由页脚 MethodNote
                    // 「目标挂卖价取近 3 天 P75」承担，此处只留可读短形
                    StatCell(label: "挂卖 (3天P75)", value: Fmt.price(it.targetSell), color: Theme.danger),
                    StatCell(label: "税后到手", value: Fmt.price(it.netSell)),
                    StatCell(label: "预赚 / 发", value: Fmt.price(it.profitPerRound), color: (it.profitPerRound ?? 0) > 0 ? Theme.ok : Theme.faint),
                    StatCell(label: "收益率", value: Fmt.pct(it.profitPct), color: (it.profitPct ?? 0) > 0 ? Theme.ok : Theme.faint)
                )
                Divider().overlay(Theme.line2)
                positionCalc(it)
            }
            RankBar(item: it)
            HStack {
                Text("周低").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                Spacer()
                Text("P25–P75 区间").font(Theme.font(.micro)).foregroundStyle(Theme.accent)
                Spacer()
                Text("周高").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
            }
        }
        .card()
    }

    /// 统计组眉题（§4.2-7）：标注每组口径；数值档位不动。色相修正：原 micro faint regular
    /// 与 StatCell 字段名（Components.swift 同款 micro faint）逐字同款——「参考区间」与
    /// 「7 天分位」两行相叠层级不可辨（同层级同字号的反面）；眉题升 semibold + accent，
    /// 对齐全站眉题语言（「口径」xs accent、§4.5-1「micro accent 眉题风格」），字段名仍 faint 让位
    private func statGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.font(.micro, weight: .semibold)).foregroundStyle(Theme.accent)
            content()
        }
    }

    // MARK: - 囤货试算（交易测算组内，补齐数量试算 + 成本口径两档到手对比）

    /// 按我的成本试算：数量档 100/500/1000/自定义 + 成本价输入（默认台账已录价，无记录按现价）。
    /// 两档到手与台账 / 网页端同口径：现价直出 = current×(1−税率)，挂 P75 = netSell；
    /// 「记入囤货」把当前数量与成本写进本机台账（同名即更新，行情页「我的囤货」区即时可见）
    private func positionCalc(_ it: MarketItem) -> some View {
        let qty = max(1, calcQty)
        let qtyD = Double(qty)
        let cost = calcCost > 0 ? calcCost : (it.current ?? 0)
        let netNow = (it.current ?? 0) * (1 - it.taxRate)
        let gainNow = (netNow - cost) * qtyD
        let gainP75 = ((it.netSell ?? 0) - cost) * qtyD
        let inBook = app.positions.contains(it.name)
        return VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: 6) {
                Text("数量").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                // AX 韧性（§7-6 AX5 验收口径）：chips 与输入框都是刚性宽且随字阶放大（ScaledMetric
                // 放大后仅自定义框就 ~180pt），直排 HStack 在特大字号下把输入框推出屏外且不可达；
                // 包横向 ScrollView（TTK 筛选区 §4.4-3 / 手册章节导航同款手法）——默认字号内容
                // 恰容、观感不变，AX 下改为可滚到达，不丢任何档位
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach([100, 500, 1000], id: \.self) { n in
                            CalcChip(label: "\(n)", on: qty == n, slide: (calcNS, "calcQty")) {
                                calcQty = n
                                calcTick += 1 // 选择触感（§5）：chip 选中是菜单类交互，与筛选/排序同款 .selection
                            }
                        }
                        TextField("自定义", value: $calcQty, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .focused($calcField, equals: .qty) // 「完成」收起（calcField 置 nil）
                            .frame(width: qtyFieldWidth) // ScaledMetric：字阶放大时输入框同步放宽（Dynamic Type）
                            .padding(.vertical, 4).padding(.horizontal, 9)
                            .background(Capsule().fill(Theme.card2))
                            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                            .font(Theme.monoFont(.xs))
                            .frame(minHeight: 44) // 触控垫层：视觉 ~21pt、命中 44pt（数字键盘手指操作，防误触）
                    }
                }
            }
            // 选中底滑移事务：calcQty 变化驱动 matchedGeometryEffect 在档位间滑移
            // （自定义档位 = 全不选中，胶囊退场）；RM 门内建于 .motion（置 nil 即瞬跳）
            .motion(Theme.animFast, value: calcQty)
            HStack(spacing: 6) {
                Text("我的买入价").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                // 同上：成本行五字标签 + 放大后的输入框在 AX3 起同样越界，横向 ScrollView 兜底
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        TextField("成本 / 发", value: $calcCost, format: .number.grouping(.never))
                            .keyboardType(.decimalPad)
                            .focused($calcField, equals: .cost) // 同上：键盘上沿「完成」一步收起
                            .frame(width: costFieldWidth) // 同上：宽度随字阶缩放
                            .padding(.vertical, 4).padding(.horizontal, 9)
                            .background(Capsule().fill(Theme.card2))
                            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                            .font(Theme.monoFont(.xs))
                            .frame(minHeight: 44) // 同上：触控垫层垫到 44pt
                        CalcChip(label: "现价", on: false) {
                            calcCost = it.current ?? 0
                            calcTick += 1 // 同上：回填也是一次选择动作
                        }
                    }
                }
            }
            // 数字滚动（§5 / MOTION.md §3-E 单点关键数字）：档位 chip 与成本输入是用户主动操作，
            // 结果数字滚动 = 动作回声；四格各挂自身数值的方向感知 numericChange（涨上滚 / 跌下滚）。
            // 60s 静默刷新时现价驱动的那几格也随之轻滚——试算区共 5 个数字、非整表，
            // 与 hero 现价同待遇（§3-E 禁滚动的是「表格多行」）
            calcQuad(
                StatCell(label: "总投入", value: Fmt.price(cost * qtyD))
                    .numericChange(value: cost * qtyD),
                StatCell(label: "现价直出到手", value: Fmt.price(netNow * qtyD))
                    .numericChange(value: netNow * qtyD),
                StatCell(label: "挂 P75 到手", value: Fmt.price((it.netSell ?? 0) * qtyD))
                    .numericChange(value: (it.netSell ?? 0) * qtyD),
                StatCell(label: "到价利润", value: Fmt.signedPrice(gainP75), color: gainP75 >= 0 ? Theme.ok : Theme.danger)
                    .numericChange(value: gainP75)
            )
            // 直出档利润单独一行：四格放不下第五个数，且它是「急用钱立卖」的决策数；
            // 此行即浮盈（现价口径未实现盈亏）——记账成功后在此播两帧确认脉冲（profitPulseText）
            profitPulseText(gainNow: gainNow)
            HStack(spacing: Theme.Space.sm) { // 记入 / 移出并置（T8：卡内 sm）
                Button {
                    app.positions.upsert(AmmoPosition(name: it.name, qty: qty, cost: cost))
                    posTick += 1
                    posPulse += 1 // 记账确认脉冲（比触感更可见的闭环，见 profitPulseText）
                } label: {
                    // 含中文：默认 design + 等宽数字
                    Label(inBook ? "更新囤货" : "记入囤货", systemImage: "tray.and.arrow.down")
                        .font(Theme.font(.xs, weight: .semibold))
                }
                .buttonStyle(.bordered)
                // §7-8 触控目标 ≥44pt：记台账是本组唯一写操作出口，bordered 默认 ~34pt 偏小
                // （同款先例：共享 RetryErrorRow 的重试按钮）
                .controlSize(.large)
                if inBook {
                    Button(role: .destructive) {
                        app.positions.remove(it.name)
                        posTick += 1
                    } label: {
                        Label("移出", systemImage: "trash")
                            .font(Theme.font(.xs, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large) // 同上：与记入并置的两枚同规格，命中区一致
                    // 记入后「移出」淡入 / 移出后淡出（MOTION.md §3-B 增删进出档）：只 opacity 不位移，
                    // 原先瞬现瞬隐；由下方按 inBook 挂的动画驱动（.transition 须由 if 切换触发才生效）
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
            }
            // 在册态切换挂一次 animMed（§5 元素进出 220ms 档）；RM 门内建于 .motion（置 nil 即瞬时）
            .motion(Theme.animMed, value: inBook)
            Text("台账（数量 × 成本）登录后随账号云同步（按弹名合并，本机优先）；未登录仅存本机。浮盈随行情快照实时计算。")
                .font(Theme.font(.xs)).foregroundStyle(Theme.faint)
        }
    }

    /// 带数字滚动的四格行：结构与共享 StatQuadRow 同构（宽足一行 4 列 / 窄屏 2×2，ViewThatFits
    /// 降级），但格子收「已挂 numericChange 的 StatCell」——共享组件参数锁死 StatCell 具体类型，
    /// 滚动修饰符只能挂在格子外围（已写进 sharedRequests，待共享层开放 per-cell 动画通道后收编）
    private func calcQuad<A: View, B: View, C: View, D: View>(_ a: A, _ b: B, _ c: C, _ d: D) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { a; b; c; d }
            VStack(alignment: .leading, spacing: Theme.Space.sm) { // 与共享 StatQuadRow 降级档同值（T8 卡内 sm）
                HStack { a; b }
                HStack { c; d }
            }
        }
    }

    /// 记账确认脉冲（keyframe 两帧，总时长 0.25s = durSwap 档、仅 scaleEffect 不动布局）：
    /// 记入 / 更新囤货成功后浮盈行轻弹一下，把「账已按此价记下、浮盈按这个数」落到视线处——
    /// 比 .selection 触感更可见的操作闭环；RM 下跳过（装饰动效全关，§7-9），
    /// ok/danger 语义色即静态等价物
    @ViewBuilder
    private func profitPulseText(gainNow: Double) -> some View {
        // 数字滚动挂在 keyframe 内层：改档位 / 输入成本时浮盈随四格同滚（方向感知，负值下滚），
        // 记账时刻的 scale 脉冲在外层独立触发，两层动画互不干扰
        let base = Text("现价直出利润 \(Fmt.signedPrice(gainNow))")
            .font(Theme.font(.xs)).monospacedDigit()
            .foregroundStyle(gainNow >= 0 ? Theme.ok : Theme.danger)
            .numericChange(value: gainNow)
        if reduceMotion {
            base
        } else {
            base.keyframeAnimator(initialValue: PosPulse(), trigger: posPulse) { v, p in
                // 锚 leading：左对齐读数行从左缘起弹，中锚会让行首文字瞬时左右游移
                v.scaleEffect(p.scale, anchor: .leading)
            } keyframes: { _ in
                KeyframeTrack(\.scale) {
                    CubicKeyframe(1.08, duration: 0.1) // 弹起半帧
                    CubicKeyframe(1.0, duration: 0.15)  // 回落半帧
                }
            }
        }
    }

    // MARK: - 预计卖出

    @ViewBuilder
    private func sellEta(_ it: MarketItem) -> some View {
        if let eta = SellEtaEngine.predict(item: it) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // 含中文标题：默认 design（标题无数字，等宽修饰只留给正文里的实义数字）
                Text("预计卖出时间").font(Theme.font(.xs, weight: .bold)).foregroundStyle(Theme.accent)
                if eta.atTarget {
                    Text("现价已达挂卖价，可直接挂单。").font(Theme.font(.sm)).foregroundStyle(Theme.tx)
                } else if let med = eta.medianH {
                    StatQuadRow(
                        StatCell(label: "历史中位历时", value: SellEtaEngine.fmtHours(med)),
                        StatCell(label: "最快", value: SellEtaEngine.fmtHours(eta.fastestH.map(Double.init))),
                        StatCell(label: "样本", value: "\(eta.episodes) 次"),
                        StatCell(label: "预计到价", value: eta.etaLabel ?? "—", color: Theme.accent)
                    )
                    if eta.episodes < 2 {
                        Text("仅 1 次完整上涨样本，历时参考价值低。").font(Theme.font(.xs)).foregroundStyle(Theme.warn)
                    }
                } else {
                    Text("近 7 天没有从当前价位涨到挂卖价的完整样本。").font(Theme.font(.sm)).foregroundStyle(Theme.dim)
                }
                if let peak = SellEtaEngine.fmtPeak(start: eta.peakStart, end: eta.peakEnd) {
                    HStack(spacing: 6) {
                        Image(systemName: "clock").font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                        Text("日内 \(peak) 通常最贵" + (eta.liftPct.map { "（高出低谷 \(Fmt.pct($0))）" } ?? ""))
                            .font(Theme.font(.xs)).foregroundStyle(Theme.tx)
                        Spacer()
                        // 「近 6h ↗」中英混排：默认 design + 等宽数字
                        Text(trendLabel(eta.trend)).font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.faint)
                    }
                }
                Text("历史统计不代表未来；口径：从 ≤ 现价首次涨到 ≥ P75 的完整上涨段历时。")
                    .font(Theme.font(.xs)).foregroundStyle(Theme.faint)
            }
            .card()
        }
    }

    // MARK: - 双源交叉

    private func radarCard(_ it: MarketItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            // 含中文标题：默认 design（标题无数字，等宽修饰只留给四格里的实义数字）
            Text("双源交叉验证").font(Theme.font(.xs, weight: .bold)).foregroundStyle(Theme.accent)
            StatQuadRow(
                StatCell(label: "中位偏差", value: it.crossDev.map { Fmt.pct($0).replacingOccurrences(of: "+", with: "") } ?? "样本不足", color: it.isAnomaly ? Theme.warn : Theme.txStrong),
                StatCell(label: "重叠小时", value: "\(it.crossOverlap ?? 0)"),
                StatCell(label: "原始信号", value: it.rawSignal?.label ?? "—"),
                StatCell(label: "涨幅榜位", value: it.hiRank.map { "#\($0)" } ?? "—")
            )
            Text(it.isAnomaly
                 ? "两路独立曲线在重叠小时上的中位偏差 > 15%：口径分歧时宁可漏报，信号强制观望、不通知。"
                 : "两源曲线偏差在 15% 以内，信号可信；重叠不足 24 小时不做结论。")
                .font(Theme.font(.xs)).foregroundStyle(Theme.dim)
        }
        .card()
    }

    private func trendLabel(_ t: PriceTrend) -> String {
        switch t {
        case .up: "近 6h ↗"
        case .down: "近 6h ↘"
        case .flat: "近 6h →"
        }
    }
}

/// 试算输入小 chip（数量档 / 现价回填）：card2 底 / line 描边，选中 accent
/// （观感对齐 FilterChipLabel）；文案含中文混排，走默认 design + 等宽数字。
/// slide 非 nil 时（数量档组）选中底经 matchedGeometryEffect 在组内滑移——替代逐枚点亮，
/// 「档位互斥单选」一眼可读；视觉尺寸紧凑但触控命中垫到 ≥44pt（通用原则：视觉可以小、垫层要足）
private struct CalcChip: View {
    let label: String
    let on: Bool
    /// 选中底滑移组（ns = 持有方 Namespace，id = 组内唯一键）；nil = 静态点亮（现行为，瞬时动作 chip 用）
    var slide: (ns: Namespace.ID, id: String)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.font(.xs, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(on ? Theme.accent : Theme.dim)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background {
                    ZStack {
                        if let slide {
                            // 滑移组：card2 底座常驻，选中面（accent 12%）随选择在 chip 间滑移；
                            // 滑移事务由行级 .motion(value: calcQty) 驱动（见 positionCalc）
                            Capsule().fill(Theme.card2)
                            if on {
                                Capsule()
                                    .fill(Theme.accent.opacity(0.12))
                                    .matchedGeometryEffect(id: slide.id, in: slide.ns)
                            }
                        } else {
                            Capsule().fill(on ? Theme.accent.opacity(0.12) : Theme.card2)
                        }
                    }
                }
                .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1))
                // 选中态（文字 / 描边）animFast 渐变、无位移（MOTION.md §3-B chip 选中档）；
                // 底色走滑移胶囊或本处渐变，RM 门内建于 .motion
                .motion(Theme.animFast, value: on)
                // 触控垫层（≥44pt）：视觉 ~28pt 不变，命中垫足——数量档相邻仅 6pt 间距，
                // 数字键盘场景手指精度低，防误触邻档；垫层在视觉层外，胶囊观感不受影响
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        // 按压态全站统一 lift 面（MOTION.md §3-D）：共享 PressableButtonStyle 已开放 radius 参数，
        // 传 .infinity（RoundedRectangle 钳到宽高一半）即胶囊取形——收编原本地 CapsulePressStyle，
        // 配方（lift 面 / animFast / RM 门）回归共享层单点维护；
        // 胶囊随标签（含 44pt 触控垫层）取形：点在垫层上也亮在指尖处，命中区与反馈区一致
        .buttonStyle(PressableButtonStyle(radius: .infinity))
    }
}

/// keyframe 载体：单 scale 一个维度足够承载两帧脉冲；Bool 不能参与插值，故用最小结构体。
/// 为什么是 Animatable 而非 iOS 17 原始的 KeyframeTrackValue：本机 Xcode（iOS 27.1 SDK，部署
/// 下限仍 17）的 SwiftUICore 里 KeyframeTrackValue 已移除，keyframes 构建器改为约束
/// Animatable（KeyframeTrackContentBuilder<Value> where Value : Animatable），且 Animatable
/// iOS 13 起可用，天然满足 17 上限纪律
private struct PosPulse: Animatable {
    var scale: CGFloat = 1
    // keyframes 按本通道插值（scale 一维）；CGFloat 即 VectorArithmetic，无需额外算术实现
    var animatableData: CGFloat {
        get { scale }
        set { scale = newValue }
    }
}
