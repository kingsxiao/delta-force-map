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
    // 数字键盘（numberPad/decimalPad）无回车键，输入框宽度需随字阶同步放大才装得下特大号输入
    @ScaledMetric(relativeTo: .footnote) private var qtyFieldWidth = 72
    @ScaledMetric(relativeTo: .footnote) private var costFieldWidth = 90

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

    /// TTK 联动：弹名 → 穿透等级（shared/data/ammo-alias.json 映射；nil = 无映射
    /// 不显徽章——一对多歧义 / 国服命名差异 / 弓弩箭矢，宁缺勿错）
    private var pen: Int? {
        app.ammoAlias.pen(marketName: item.name, calibers: app.ttk.data?.calibers ?? [:])
    }

    var body: some View {
        let it = resolved
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                header(it)
                PriceChart(item: it).card()
                stats(it)
                sellEta(it)
                if it.hiRank != nil { radarCard(it) }
                MethodNote(source: nil).card()
            }
            .padding(12)
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
        .sensoryFeedback(.success, trigger: favTick)
        .sensoryFeedback(.success, trigger: refreshOkTick)
        .sensoryFeedback(.error, trigger: refreshErrTick)
        .sensoryFeedback(.selection, trigger: posTick)
        .sensoryFeedback(.selection, trigger: calcTick)
        .toolbar {
            Button {
                app.favorites.toggle(it.name)
                favTick += 1
            } label: {
                starIcon(starred: app.favorites.contains(it.name))
            }
            .accessibilityLabel(app.favorites.contains(it.name) ? "取消自选" : "加入自选")
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
                // 现价数字滚动（§4.2-6）：数值变化 contentTransition + durMed；Reduce Motion 跳过（§7-9）
                Mono(Fmt.price(it.current), step: .hero, minScale: 0.75)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    .animation(reduceMotion ? nil : .easeOut(duration: Theme.durMed), value: it.current)
                ageBadge
            }
        }
        .card()
    }

    /// 数据年龄角标（§4.2-3）：「数据 X 分钟前 · 版本 vX」micro faint（>5 分钟转 warn），
    /// TimelineView 30s 刷新；数据源跟随解冻命中路径，frozen 兜底固定文案
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
    }

    @ViewBuilder
    private func ageText(_ age: Double?, version: String?) -> some View {
        if let age {
            // 含中文：默认 design + 等宽数字；>5 分钟转 warn 提示数据陈旧
            Text("数据 \(MarketMeta.fmtAge(minutes: age))前 · 版本 \(MarketMeta.formatVersionLabel(version))")
                .foregroundStyle(age > 5 ? Theme.warn : Theme.faint)
        } else {
            Text("数据可能过期").foregroundStyle(Theme.faint)
        }
    }

    // MARK: - 统计

    /// 三组统计（§4.2-7）：micro faint 语义眉题（参考区间 / 区间极值 / 交易测算）；
    /// 四格行换共享 StatQuadRow（C5：本页原私有 statQuad 已删，4→2×2 降级由共享组件承担）
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
            Divider().overlay(Theme.line2)
            statGroup("交易测算") {
                StatQuadRow(
                    StatCell(label: "目标挂卖 (P75)", value: Fmt.price(it.targetSell), color: Theme.danger),
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

    /// 统计组眉题（§4.2-7）：micro faint，标注每组口径；数值档位不动
    private func statGroup(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text(title).font(Theme.font(.micro)).foregroundStyle(Theme.faint)
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
                ForEach([100, 500, 1000], id: \.self) { n in
                    CalcChip(label: "\(n)", on: qty == n) {
                        calcQty = n
                        calcTick += 1 // 选择触感（§5）：chip 选中是菜单类交互，与筛选/排序同款 .selection
                    }
                }
                TextField("自定义", value: $calcQty, format: .number.grouping(.never))
                    .keyboardType(.numberPad)
                    .frame(width: qtyFieldWidth) // ScaledMetric：字阶放大时输入框同步放宽（Dynamic Type）
                    .padding(.vertical, 4).padding(.horizontal, 9)
                    .background(Capsule().fill(Theme.card2))
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                    .font(Theme.monoFont(.xs))
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Text("我的买入价").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                TextField("成本 / 发", value: $calcCost, format: .number.grouping(.never))
                    .keyboardType(.decimalPad)
                    .frame(width: costFieldWidth) // 同上：宽度随字阶缩放
                    .padding(.vertical, 4).padding(.horizontal, 9)
                    .background(Capsule().fill(Theme.card2))
                    .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                    .font(Theme.monoFont(.xs))
                CalcChip(label: "现价", on: false) {
                    calcCost = it.current ?? 0
                    calcTick += 1 // 同上：回填也是一次选择动作
                }
                Spacer(minLength: 0)
            }
            StatQuadRow(
                StatCell(label: "总投入", value: Fmt.price(cost * qtyD)),
                StatCell(label: "现价直出到手", value: Fmt.price(netNow * qtyD)),
                StatCell(label: "挂 P75 到手", value: Fmt.price((it.netSell ?? 0) * qtyD)),
                StatCell(label: "到价利润", value: fmtSigned(gainP75), color: gainP75 >= 0 ? Theme.ok : Theme.danger)
            )
            // 直出档利润单独一行：四格放不下第五个数，且它是「急用钱立卖」的决策数
            Text("现价直出利润 \(fmtSigned(gainNow))")
                .font(Theme.font(.xs)).monospacedDigit()
                .foregroundStyle(gainNow >= 0 ? Theme.ok : Theme.danger)
            HStack(spacing: 8) {
                Button {
                    app.positions.upsert(AmmoPosition(name: it.name, qty: qty, cost: cost))
                    posTick += 1
                } label: {
                    // 含中文：默认 design + 等宽数字
                    Label(inBook ? "更新囤货" : "记入囤货", systemImage: "tray.and.arrow.down")
                        .font(Theme.font(.xs, weight: .semibold))
                }
                .buttonStyle(.bordered)
                if inBook {
                    Button(role: .destructive) {
                        app.positions.remove(it.name)
                        posTick += 1
                    } label: {
                        Label("移出", systemImage: "trash")
                            .font(Theme.font(.xs, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
            }
            Text("台账（数量 × 成本）登录后随账号云同步（按弹名合并，本机优先）；未登录仅存本机。浮盈随行情快照实时计算。")
                .font(Theme.font(.xs)).foregroundStyle(Theme.faint)
        }
    }

    /// 带符号金额（利润可为负）：+12,345 / -1,024
    private func fmtSigned(_ n: Double) -> String {
        "\(n >= 0 ? "+" : "-")\(Fmt.price(abs(n)))"
    }

    // MARK: - 预计卖出

    @ViewBuilder
    private func sellEta(_ it: MarketItem) -> some View {
        if let eta = SellEtaEngine.predict(item: it) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                // 含中文标题：默认 design + 等宽数字（mono 只留给纯 ASCII）
                Text("预计卖出时间").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
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
            // 含中文标题：默认 design + 等宽数字（mono 只留给纯 ASCII）
            Text("双源交叉验证").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
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
/// （观感对齐 FilterChipLabel）；文案含中文混排，走默认 design + 等宽数字
private struct CalcChip: View {
    let label: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.font(.xs, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(on ? Theme.accent : Theme.dim)
                .padding(.horizontal, 11).padding(.vertical, 5)
                .background(Capsule().fill(on ? Theme.accent.opacity(0.12) : Theme.card2))
                .overlay(Capsule().strokeBorder(on ? Theme.accent.opacity(0.45) : Theme.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
