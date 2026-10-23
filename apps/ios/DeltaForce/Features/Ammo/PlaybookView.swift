// PlaybookView.swift — 倒卖手册（与 apps/web/src/views/ammo/Playbook.vue 同一份静态内容）
// 顶部动态区：全市场日内节律卡（MarketClock）——数据驱动的「现在几点，该扫货
// 还是该出货」，与下方静态 WINDOWS 共识时段互补；算法 DeltaForceCore marketClock
// （shared/js/sellEta.js 同构对拍）。
import SwiftUI
import DeltaForceCore

struct PlaybookView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app

    private struct Window: Identifiable {
        let id = UUID()
        let time: String, tag: String, buy: Bool, note: String
    }

    private struct Card: Identifiable {
        let id = UUID()
        let idx: String, en: String, title: String, warn: Bool
        let items: [(lead: String, text: String)]
    }

    private let windows: [Window] = [
        .init(time: "02:00–05:00", tag: "扫货", buy: true, note: "挂机党下线甩卖，全天低位（社区观察约低两成）"),
        .init(time: "07:00–09:00", tag: "囤货", buy: true, note: "工作日早间黄金期：上班族未上线，卖压轻"),
        .init(time: "12:00–14:00", tag: "上架", buy: false, note: "午休补弹潮，挂单可比凌晨高约 10%"),
        .init(time: "19:00–23:00", tag: "出货", buy: false, note: "晚间高峰；周日晚 20–23 点是全周最佳抛售窗口"),
    ]

    private let cards: [Card] = [
        .init(idx: "01", en: "BUY", title: "买什么、去哪买", warn: false, items: [
            ("流动性优先：", "4 级弹是多数对局的主力弹种、进出最快；5 级弹单价高但需求窄，适合大资金慢周转。"),
            ("军需处倒挂：", "军需处每日限购（约凌晨 5 点刷新）兑换价低于交易行时先扫军需处；在交易行购买也会自动按军需处的更低档成交。"),
            ("看信号进场：", "「买入」信号 = 当前价 ≤ 7 天 25 分位、且按 P75 挂卖税后仍 ≥ 8%；只倒自己打得出去的弹，价格不涨还能自用。"),
        ]),
        .init(idx: "02", en: "SELL", title: "挂单定价，卖得快又不贱卖", warn: false, items: [
            ("删位法（日常清仓）：", "把参考价末位删 1 位让面板出现新低价区，选从左数第 4 个价格块——当前仍能快速成交的最高价。"),
            ("柱状图法（急用钱）：", "挑最短柱子的档位挂（挂单最少、成交最快）；参考减价幅度：配件 5–6 档、普通武器 3–4 档、基础材料 2–3 档。"),
            ("分批抛：", "一次性挂太多会自己砸盘，多人同时抛售更会加速下跌；大仓位拆成几天、多档位出。"),
        ]),
        .init(idx: "03", en: "WINDOW", title: "版本与赛季窗口（利润最厚）", warn: false, items: [
            ("更新前 3–7 天囤货：", "新赛季/大版本前囤热门口径（新枪配套弹、5.56 等主流弹）；赛季末物价低迷同样是囤货窗口。"),
            ("开更后 3 天内出货：", "全服补弹需求暴增，是主要抛售窗口（社区案例：AP6.3 更新后涨至约 4.5 万/格）。"),
            ("活动公告驱动：", "新玩法、夜战等活动公布即囤对应消耗品；研发部门新配方、特勤处制作活动会拉动特定材料价格。"),
        ]),
        .init(idx: "04", en: "MAIL", title: "卡邮件：邮箱当临时仓库", warn: true, items: [
            ("机制：", "邮件附件可暂存物资当扩容仓库用；邮件物资 30 天有效，逾期消失。"),
            ("全装包法（半官方机制）：", "先用占格杂物把仓库塞满，再打开全装包并勾选「打开后立即装备」——空间冲突后，原身上装备整套转为补偿邮件。"),
            ("断网重连类卡法属漏洞利用：", "官方可能判违规、有封号风险，高价值物资也可能卡失败，谨慎使用。"),
            ("对倒卖的意义：", "囤子弹最卡的正是仓库格子；邮件能顶 30 天，恰好盖住一轮「囤→卖」，记得回来领。"),
        ]),
    ]

    private let risks: [(lead: String, text: String)] = [
        ("倒卖本身合规：", "交易行是官方自由市场，低买高卖属正常玩法；但卡邮件漏洞法、多开搬砖属灰色操作，风险自负。"),
        ("变现红线：", "哈夫币不能直接交易；私下交易骗子多，比例明显偏离行情的基本是骗局；官方市集安全但手续费约 30%，出手前先算净所得。"),
        ("行情会跌：", "囤货可能不涨反跌，多人同时抛售会加速下跌；历史分位不代表未来走势，本站信号同理。"),
        ("费率以游戏内为准：", "挂单 12 / 24 小时费率不同、成交后才扣除；利润按上游税后价实测税率（约 15%）逐弹计算，与部分攻略引用的基础费率（约 5%）口径不一。"),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    // 全市场日内节律（数据驱动）：快照不足时静默跳过，手册静态内容不受影响
                    if let clock = SellEtaEngine.marketClock(app.market.items) {
                        MarketClockCard(clock: clock)
                    }

                    Text("倒卖 = 低价囤消耗品 + 高位分批抛售。信号解决「哪种弹、什么价」，下面是社区攻略里验证过的「什么时间、怎么操作」——按 时段 → 买 → 卖 → 窗口 串成一条完整动线。")
                        .font(Theme.font(.sm)).foregroundStyle(Theme.dim)

                    // 自适应列：iPhone 2 列，iPad / 横屏按可用宽度自动多列
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(windows) { w in
                            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                HStack {
                                    // 纯 ASCII 时间窗（02:00–05:00）：mono sub 档
                                    Mono(w.time, step: .sub)
                                    Spacer()
                                    // 时间窗标签换共享 StatusChip（§3 C2 复用点）：替代本页 h7/v1 + 胶囊描边的
                                    // 第四种徽标配方（§1.4 四族合一），buy=ok / sell=danger 语义不变
                                    StatusChip(text: w.tag, tint: w.buy ? Theme.ok : Theme.danger)
                                }
                                Text(w.note).font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                            }
                            .card()
                        }
                    }

                    ForEach(cards) { c in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                // 纯 ASCII 编号码（01 BUY / SELL / WINDOW / MAIL）：保留 mono
                                Text("\(c.idx) \(c.en)").font(Theme.monoFont(.micro, weight: .bold)).foregroundStyle(Theme.accent)
                                Text(c.title).font(Theme.font(.md, weight: .bold)).foregroundStyle(Theme.txStrong)
                            }
                            ForEach(Array(c.items.enumerated()), id: \.offset) { _, it in
                                (Text(it.lead).foregroundStyle(Theme.txStrong).fontWeight(.semibold) + Text(it.text).foregroundStyle(Theme.dim))
                                    .font(Theme.font(.sm))
                            }
                        }
                        .card()
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        // 标题含中文：默认 design + 等宽数字
                        Text("RISK · 风险与红线").font(Theme.font(.micro, weight: .bold)).monospacedDigit().foregroundStyle(Theme.danger)
                        ForEach(Array(risks.enumerated()), id: \.offset) { _, r in
                            (Text(r.lead).foregroundStyle(Theme.txStrong).fontWeight(.semibold) + Text(r.text).foregroundStyle(Theme.dim))
                                .font(Theme.font(.sm))
                        }
                    }
                    .card()

                    // 实义长文本（版权 / 来源声明）：footnote 而非 caption2
                    Text("要点整理自社区公开攻略（2026-10）：挂单定价技巧 · 游民星空 / 卡邮件机制 · 游侠网 / 交易行系统篇 · TapTap / 搬砖全攻略 · TapTap。机制与数值随版本变动，以游戏内实际为准。")
                        .font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                }
                .padding(12)
                // regular 宽度内容列上限 640 居中（对齐网页 --wrap 可读列）
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.bg)
            .navigationTitle("倒卖手册")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("完成") { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }
}

/// 全市场日内节律卡（手册顶部动态区）：24 格水位色带 + 数据时刻指针 + 三档判读。
/// 布局与配色语义对齐网页端 apps/web/src/views/ammo/MarketClock.vue（低=ok / 中=faint /
/// 高=danger，▼ 指针标数据时刻）；判读口径在 DeltaForceCore marketClock（与 web 对拍）。
private struct MarketClockCard: View {
    let clock: MarketClock

    /// 有效水位区间（色带高度 / 三档配色统一取位；平坦时全部居中）
    private var span: (low: Double, high: Double)? {
        let valid = clock.levels.compactMap { $0 }
        guard let low = valid.min(), let high = valid.max() else { return nil }
        return (low, high)
    }

    private func pos(_ v: Double?) -> Double? {
        guard let v, let s = span, s.high - s.low > 1e-9 else { return v != nil ? 0.5 : nil }
        return (v - s.low) / (s.high - s.low)
    }

    private var verdictTint: Color {
        switch clock.verdict {
        case .buy: Theme.ok
        case .sell: Theme.danger
        case .wait, nil: Theme.faint
        }
    }

    private var verdictNote: String {
        switch clock.verdict {
        case .buy: "全市场处日内相对低位，适合进货"
        case .sell: "全市场处日内相对高位，适合挂卖"
        case .wait: "处日内中段，等窗口再动手"
        case nil: "样本不足"
        }
    }

    /// 最低小时（首个取到全天最低水位的时刻，读数行展示用）
    private var lowHour: Int? {
        guard let s = span else { return nil }
        return clock.levels.firstIndex(where: { $0 == s.low })
    }

    /// 读数行文案（ViewBuilder 内不能写 `line +=` 这类 Void 语句，字符串拼接收拢到这里）
    private var readout: String? {
        guard let peak = SellEtaEngine.fmtPeak(start: clock.peakStart, end: clock.peakEnd) else { return nil }
        var line = "高位窗口 \(peak)"
        if let lift = clock.liftPct { line += "（较最低小时 \(Fmt.pct(lift))）" }
        if let lh = lowHour { line += " · 最低小时 \(String(format: "%02d:00", lh)) 前后" }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                Text("MARKET CLOCK").font(Theme.monoFont(.micro, weight: .bold)).foregroundStyle(Theme.accent)
                Text("全市场日内节律 · \(clock.counted) 种弹聚合")
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.xs)
                if let v = clock.verdict { StatusChip(text: v.label, tint: verdictTint) }
            }

            // 判读行：数据时刻（快照末点墙钟，不随设备时区漂移）+ 判读语
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("数据时刻").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                Mono(clock.dataHour.map { String(format: "%02d:00", $0) } ?? "—", step: .sub, color: Theme.tx)
                Text(verdictNote).font(Theme.font(.xs)).foregroundStyle(Theme.faint)
            }

            MarketClockBand(clock: clock, pos: pos)

            // 读数行：高位窗口 / 涨幅 / 最低小时（窗口缺失时整行不渲染，与网页端一致）
            if let line = readout {
                Text(line)
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
            }

            Text("按 \(clock.counted) 种子弹 7 天小时曲线逐弹归一（相对自身 7 天均价）后跨弹取中位聚合；「数据时刻」为快照曲线末点的墙钟时刻，不用设备本地时间。历史统计不代表未来。")
                .font(Theme.font(.xs)).foregroundStyle(Theme.faint)
        }
        .card()
    }
}

/// 24 格水位色带：每格竖槽内水位条按位置升起的迷你直方图 + 数据时刻 ▼ 指针
private struct MarketClockBand: View {
    let clock: MarketClock
    /// 与卡片同口径的水位取位函数（0-1；nil = 该小时无样本）
    let pos: (Double?) -> Double?

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { h in
                cell(h)
                    .frame(maxWidth: .infinity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(a11y)
    }

    @ViewBuilder
    private func cell(_ h: Int) -> some View {
        let p = pos(clock.levels[h])
        let now = clock.dataHour == h
        VStack(spacing: 2) {
            // 指针槽（固定高、常驻占位，仅数据时刻点亮——避免色带整体跳动）
            CaretDown()
                .fill(now ? Theme.accent : .clear)
                .frame(width: 8, height: 5)
                .frame(height: 9, alignment: .bottom)
            // 轨道 + 水位条（4pt 保底 + 40pt 按位置）
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous).fill(Theme.line2)
                if let p {
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(p <= 1.0 / 3.0
                            ? Theme.ok.opacity(0.55)
                            : p >= 2.0 / 3.0 ? Theme.danger.opacity(0.6) : Theme.faint.opacity(0.45))
                        .frame(height: 4 + 40 * p)
                }
            }
            .frame(height: 44)
            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .stroke(now ? Theme.accentDim : .clear, lineWidth: 1))
            // 小时标注：只标 0/6/12/18（纯 ASCII 时码走 mono）
            Text(h % 6 == 0 ? String(format: "%02d", h) : "")
                .font(Theme.monoFont(.micro))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .frame(height: 11)
        }
    }

    private var a11y: String {
        var s = "全市场 24 小时相对水位色带"
        if let h = clock.dataHour { s += "，数据时刻 \(String(format: "%02d", h)):00" }
        if let v = clock.verdict { s += "，判读\(v.label)" }
        if let p = SellEtaEngine.fmtPeak(start: clock.peakStart, end: clock.peakEnd) { s += "，高位窗口\(p)" }
        return s
    }
}

/// 小号下指箭头（数据时刻指针；自绘 Shape，避免裸 .font(.system(size:))）
private struct CaretDown: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
