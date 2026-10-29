// PlaybookView.swift — 倒卖手册（与 apps/web/src/views/ammo/Playbook.vue 同一份静态内容）
// 顶部动态区：全市场日内节律卡（MarketClock）——数据驱动的「现在几点，该扫货
// 还是该出货」，与下方静态 WINDOWS 共识时段互补；算法 DeltaForceCore marketClock
// （shared/js/sellEta.js 同构对拍）。
import SwiftUI
import DeltaForceCore

struct PlaybookView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var app
    // 章节跳转的 RM 判定（§7-9：scrollTo 无动画直达）与跳转触感 tick（trigger 只绑本页 State）
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var navTick = 0

    private struct Window: Identifiable {
        let id = UUID()
        let time: String, tag: String, buy: Bool, note: String
        /// 窗口起止小时（左闭右开，如 19:00–23:00 覆盖 19~22 点整段）——
        /// 供「当前」点亮判定（对齐 web Playbook WINDOWS 的 from/to 字段）
        let from: Int, to: Int
    }

    private struct Card: Identifiable {
        let id = UUID()
        let idx: String, en: String, title: String, warn: Bool
        let items: [(lead: String, text: String)]
    }

    /// 数据时刻是否落在该窗（左闭右开）；无判读（nil）时全部不点亮，不硬凑——web 同款
    private func inWindow(_ w: Window, nowHour: Int?) -> Bool {
        guard let nowHour else { return false }
        return nowHour >= w.from && nowHour < w.to
    }

    private let windows: [Window] = [
        .init(time: "02:00–05:00", tag: "扫货", buy: true, note: "挂机党下线甩卖，全天低位（约低两成）", from: 2, to: 5),
        .init(time: "07:00–09:00", tag: "囤货", buy: true, note: "工作日早间黄金期：上班族未上线，卖压轻", from: 7, to: 9),
        .init(time: "12:00–14:00", tag: "上架", buy: false, note: "午休补弹潮，挂单可比凌晨高约 10%", from: 12, to: 14),
        .init(time: "19:00–23:00", tag: "出货", buy: false, note: "晚间高峰；周日晚 20–23 点是全周最佳抛售窗口", from: 19, to: 23),
    ]

    private let cards: [Card] = [
        .init(idx: "01", en: "BUY", title: "买什么、去哪买", warn: false, items: [
            ("流动性优先：", "4 级弹是多数对局的主力弹种、进出最快；5 级弹单价高但需求窄，适合大资金慢周转。"),
            ("军需处倒挂：", "军需处每日限购（约凌晨 5 点刷新）兑换价低于交易行时先扫军需处；在交易行购买也会自动按军需处的更低档成交。"),
            ("看信号进场：", "「买入」信号 = 现价处 7 天下 1/5 分位、已止跌企稳（离底 ≥3%、近 12 小时无新低、48 小时趋势转平向上）、且按近 3 天 75 分位挂卖税后仍 ≥10%，随信号给止损位；只倒自己打得出去的弹，价格不涨还能自用。"),
        ]),
        .init(idx: "02", en: "SELL", title: "挂单定价，卖得快又不贱卖", warn: false, items: [
            ("删位法（日常清仓）：", "把参考价末位删 1 位让面板出现新低价区，选从左数第 4 个价格块——当前仍能快速成交的最高价。"),
            ("柱状图法（急用钱）：", "挑最短柱子的档位挂（挂单最少、成交最快）；参考减价幅度：配件 5–6 档、普通武器 3–4 档、基础材料 2–3 档。"),
            ("分批抛：", "一次性挂太多会自己砸盘，多人同时抛售更会加速下跌；大仓位拆成几天、多档位出。"),
        ]),
        .init(idx: "03", en: "WINDOW", title: "版本与赛季窗口（利润最厚）", warn: false, items: [
            ("更新前 3–7 天囤货：", "新赛季/大版本前囤热门口径（新枪配套弹、5.56 等主流弹）；赛季末物价低迷同样是囤货窗口。"),
            ("开更后 3 天内出货：", "全服补弹需求暴增，是主要抛售窗口（AP6.3 更新后涨至约 4.5 万/格）。"),
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
        ("费率以游戏内为准：", "挂单 12 / 24 小时费率不同、成交后才扣除；利润按实测税率（约 15%）逐弹计算。"),
    ]

    /// 「当前」徽标（对齐 web .pw-now）：accent 文字 + accentBg 底 + accentDim 描边，
    /// 跟随时段文字排、不与右侧语义 tag 抢角——accent 是唯一强调色。
    /// 窄列放不下时由时间行的 ViewThatFits 降级为「accent 时间」，徽标整体退场（见时间行注释）
    private var nowBadge: some View {
        Text("当前")
            .font(Theme.font(.micro, weight: .semibold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .badgeCoat(Theme.accent, in: Capsule(), fill: 0.09, stroke: 0.38)
            .accessibilityLabel("当前所处窗（按行情数据时刻判定）")
    }

    var body: some View {
        // 节律卡数据源提到 body 顶（同 ItemDetailView `let it = resolved` 写法）：
        // 下方 contentSwap 以「有无卡」布尔作切换键
        let clock = SellEtaEngine.marketClock(app.market.items)
        NavigationStack {
            // 章节跳转须要 ScrollViewReader 提供 proxy（scrollTo 锚点；导航本体见 PlaybookNav）
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Space.md) {
                        // 章节导航（打磨起点「手册章节导航」）：长文 sheet 一屏看不全结构，
                        // 顶部 chips 兼做「目录 + 一键跳段」；与三页筛选回顶同款 animMed 平滑滚、
                        // RM 直达（§7-9），跳转配 .selection 触感（导航类切换，§5）
                        PlaybookNav { id in
                            if reduceMotion {
                                proxy.scrollTo(id, anchor: .top)
                            } else {
                                withAnimation(Theme.animMed) { proxy.scrollTo(id, anchor: .top) }
                            }
                            navTick += 1
                        }

                        // 全市场日内节律（数据驱动）：快照不足时静默跳过，手册静态内容不受影响。
                        // 手册入口不等数据，可在首个快照落地前打开（marketClock([]) = nil）：卡随后
                        // 到达时按 MOTION.md §3-H 内容进场（淡入 + 6pt 轻上移），下方静态区随之平滑
                        // 让位，不再瞬插顶推；首开即有数据时无状态变化、不播进场。不做骨架：
                        // 本页主体是本地静态内容（§4.2「本地已有数据…不动」），且 marketClock 可因
                        // 样本不足永久为 nil，占位会变成永不兑现的「加载中」
                        if let clock {
                            MarketClockCard(clock: clock)
                                .swapTransition()
                        }

                        // 动线四步加粗提亮（对齐 web .pb-lede b）：导语唯一的「怎么读」记忆点，
                        // 通篇 dim 里立出主线，避免手册入口读起来是一堵均匀灰墙
                        (Text("倒卖 = 低价囤消耗品 + 高位分批抛售。信号解决「哪种弹、什么价」，下面是验证过的「什么时间、怎么操作」——按 ")
                            + Text("时段 → 买 → 卖 → 窗口").foregroundStyle(Theme.txStrong).fontWeight(.bold)
                            + Text(" 串成一条完整动线。"))
                            .font(Theme.font(.sm)).foregroundStyle(Theme.dim)

                        // 共识时段眉题：与顶部 MarketClock 卡读出行的「实测」前缀构成口径对照
                        // （本区是静态社区共识、上面是全市场曲线实测；样式对齐 MethodNote「口径」眉题心智）
                        VStack(alignment: .leading, spacing: Theme.Space.xs) {
                            Text("共识时段").font(Theme.font(.xs, weight: .bold)).foregroundStyle(Theme.accent)
                            // 自适应列：iPhone 2 列，iPad / 横屏按可用宽度自动多列
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                                ForEach(windows) { w in
                                    // 当前所处窗点亮（对齐 web .pw.now）：数据时刻落在本窗才亮——
                                    // 上方 MarketClock 判「现在该干嘛」，此处即时印证「正处这个窗」，
                                    // 两处口径同为快照末点墙钟（不随设备时区漂移）
                                    let now = inWindow(w, nowHour: clock?.dataHour)
                                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                                        HStack {
                                            // 时间行 ViewThatFits 降级：iPhone 双列卡内宽 ~155pt，点亮卡
                                            // 「时间 92.7 + 当前徽标 38 + 右侧标签 38 + 间距」实测 ~193pt
                                            // 放不下（CoreText 实测；非点亮卡 ~147pt 恰容）——完整版（徽标，
                                            // 对齐 web .pw-now）留给 iPad / 非点亮卡；放不下退「accent 时间」
                                            // 版：徽标让位、时间本身转 accent（§1.2 accent=「当前/激活」语义），
                                            // 与 accentDim 卡描边仍构成双信号，四卡行结构保持一致；
                                            // 「当前所处窗」语义在降级版由时间自身 a11y label 转述，不丢失
                                            ViewThatFits(in: .horizontal) {
                                                HStack(spacing: Theme.Space.xs) {
                                                    // 纯 ASCII 时间窗（02:00–05:00）：mono sub 档；
                                                    // minScale 防特大字号从 en-dash 处折行断成两截时间码
                                                    Mono(w.time, step: .sub, minScale: 0.75)
                                                    if now { nowBadge }
                                                }
                                                Mono(w.time, step: .sub, color: now ? Theme.accent : Theme.txStrong, minScale: 0.75)
                                                    .accessibilityLabel(now ? "\(w.time)，当前所处窗（按行情数据时刻判定）" : w.time)
                                            }
                                            Spacer()
                                            // 时间窗标签换共享 StatusChip（§3 C2 复用点）：替代本页 h7/v1 + 胶囊描边的
                                            // 第四种徽标配方（§1.4 四族合一），buy=ok / sell=danger 语义不变
                                            StatusChip(text: w.tag, tint: w.buy ? Theme.ok : Theme.danger)
                                        }
                                        Text(w.note).font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                                    }
                                    .card()
                                    // 点亮态描边换 accentDim（web .pw.now 另有 accentBg 底色，
                                    // iOS 以描边 + （徽标 | accent 时间）双信号承载，底色从简——去掉多余装饰）
                                    .overlay {
                                        if now {
                                            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                                                .stroke(Theme.accentDim, lineWidth: 1)
                                        }
                                    }
                                }
                            }
                        }
                        .id("pb-windows") // 章节导航锚点：时段

                        ForEach(cards) { c in
                            VStack(alignment: .leading, spacing: Theme.Space.sm) { // 卡内条目（T8 sm）
                                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) { // 编号码与标题（T8 sm）
                                    // 纯 ASCII 编号码（01 BUY / SELL / WINDOW / MAIL）：保留 mono
                                    Text("\(c.idx) \(c.en)").font(Theme.monoFont(.micro, weight: .bold)).foregroundStyle(Theme.accent)
                                    Text(c.title).font(Theme.font(.md, weight: .bold)).foregroundStyle(Theme.txStrong)
                                }
                                ForEach(Array(c.items.enumerated()), id: \.offset) { _, it in
                                    // lead 用 tx（对齐 web li b --tx + 600）：条目重点词介于标题
                                    // txStrong 与正文 dim 之间，不与卡片标题抢最高档
                                    (Text(it.lead).foregroundStyle(Theme.tx).fontWeight(.semibold) + Text(it.text).foregroundStyle(Theme.dim))
                                        .font(Theme.font(.sm))
                                }
                            }
                            .card()
                            // 章节导航锚点：pb-01 买什么 / 02 怎么卖 / 03 窗口 / 04 卡邮件
                            .id("pb-\(c.idx)")
                        }

                        VStack(alignment: .leading, spacing: Theme.Space.sm) { // 卡内条目（T8 sm）
                            // 标题含中文：默认 design + 等宽数字
                            Text("RISK · 风险与红线").font(Theme.font(.micro, weight: .bold)).monospacedDigit().foregroundStyle(Theme.danger)
                            ForEach(Array(risks.enumerated()), id: \.offset) { _, r in
                                // lead 用 tx（同上，对齐 web li b --tx + 600）
                                (Text(r.lead).foregroundStyle(Theme.tx).fontWeight(.semibold) + Text(r.text).foregroundStyle(Theme.dim))
                                    .font(Theme.font(.sm))
                            }
                        }
                        .card()
                        .id("pb-risk") // 章节导航锚点：风险

                        // 实义长文本（版权声明）：footnote 而非 caption2
                        Text("机制与数值随版本变动，以游戏内实际为准。")
                            .font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                    }
                    .padding(12)
                    // regular 宽度内容列上限 640 居中（对齐网页 --wrap 可读列）
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
                    // 有无节律卡的状态切换挂一次 animSwap（驱动上方 .swapTransition 与静态区让位）；
                    // RM 门内建于 .contentSwap（置 nil 即瞬时插入）
                    .contentSwap(clock != nil)
                }
                .background(Theme.bg)
                .navigationTitle("倒卖手册")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("完成") { dismiss() } }
                // 章节跳转 = 导航类切换（§5 selection 档）
                .sensoryFeedback(.selection, trigger: navTick)
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// 章节导航（手册 6 段一动线的「目录」）：chip 观感与 CalcChip / FilterChipLabel 同族
/// （card2 底 / line 描边），视觉紧凑但触控垫层 ≥44pt（通用原则：视觉可以小、垫层要足）；
/// 横向 ScrollView 收纳全部段名，AX 特大字号不折行不截断
private struct PlaybookNav: View {
    let jump: (String) -> Void

    /// 段定义（chip 文案 → 正文锚点 id），与正文各段 .id() 一一对应。
    /// 用小结构体而非元组：ForEach 的 id: KeyPath 不支持元组元素
    private struct Section: Identifiable {
        let id: String
        let label: String
    }

    private static let sections: [Section] = [
        Section(id: "pb-windows", label: "时段"), Section(id: "pb-01", label: "买什么"),
        Section(id: "pb-02", label: "怎么卖"), Section(id: "pb-03", label: "窗口"),
        Section(id: "pb-04", label: "卡邮件"), Section(id: "pb-risk", label: "风险"),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Self.sections) { s in
                    Button {
                        jump(s.id)
                    } label: {
                        Text(s.label)
                            .font(Theme.font(.sm, weight: .semibold))
                            .foregroundStyle(Theme.dim)
                            .padding(.horizontal, 13).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.card2))
                            .overlay(Capsule().strokeBorder(Theme.line, lineWidth: 1))
                            // 触控垫层：视觉 ~28pt、命中 44pt（垫层在视觉层外，胶囊观感不变）
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    // 按压态与 CalcChip / FilterChipLabel 同族（共享 lift 面 + animFast 档，MOTION.md §3-D）：
                    // 跳转是本页最高频动作，.plain 无按压视觉＝动作无回声；胶囊取形传 radius .infinity
                    .buttonStyle(PressableButtonStyle(radius: .infinity))
                    // VO 成句：按钮文本只是段名，不读 hint 不知道是「跳过去」
                    .accessibilityHint("跳转到该章节")
                }
            }
            .padding(.vertical, 2)
        }
    }
}

/// 全市场日内节律卡（手册顶部动态区）：24 格水位色带 + 数据时刻指针 + 三档判读。
/// 布局与配色语义对齐网页端 apps/web/src/views/ammo/MarketClock.vue（低=ok / 中=faint /
/// 高=danger，▼ 指针标数据时刻）；判读口径在 DeltaForceCore marketClock（与 web 对拍）。
private struct MarketClockCard: View {
    let clock: MarketClock
    // 点击查值选中的小时（nil = 收起）：触屏端读单小时水位的唯一途径（对齐 web .mc-pick）
    @State private var pickedHour: Int?

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
        // wait 用 dim 而非 faint：判读词升档后是本卡主角文字，faint 会掉到注释档
        // （对齐 web .mc-word wait 档同为 --dim）
        case .wait, nil: Theme.dim
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

    /// 读数行文案（ViewBuilder 内不能写 `line +=` 这类 Void 语句，字符串拼接收拢到这里）。
    /// 「实测」前缀：与下方四时段卡的「共识时段」眉题构成口径对照——同屏两种时间表述
    /// （实测峰值子窗口 vs 静态共识时段）若无标注，首读无法分辨哪个才准（终验 low 项）
    private var readout: String? {
        guard let peak = SellEtaEngine.fmtPeak(start: clock.peakStart, end: clock.peakEnd) else { return nil }
        var line = "实测高位窗口 \(peak)"
        if let lift = clock.liftPct { line += "（较最低小时 \(Fmt.pct(lift))）" }
        if let lh = lowHour { line += " · 最低小时 \(String(format: "%02d:00", lh)) 前后" }
        return line
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.xs) {
                Text("市场时钟").font(Theme.monoFont(.micro, weight: .bold)).foregroundStyle(Theme.accent)
                // 不限行：特大字号 / 窄屏时自然折行，优于截成「全市场日内节律 · 1…」。
                // verdict 徽标已并入下方判读行大字（与 web 同源）——头部不再重复一枚 micro 徽标，
                // 同一结论全卡只出现一次（本轮主题：去掉多余装饰）
                Text("全市场日内节律 · \(clock.counted) 种弹聚合")
                    .font(Theme.font(.xs))
                    .foregroundStyle(Theme.dim)
            }

            // 判读行：数据时刻（快照末点墙钟，不随设备时区漂移）+ 判读大字 + 判读语。
            // 判读词立权（对齐 web .mc-word：fs-xl 700 + 三档语义色）——「扫货/出货」是本卡
            // 唯一决策结论，此前只以头部 micro 徽标出现：全卡最小的字承载最大的信息，扫读路径倒挂
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("数据时刻").font(Theme.font(.xs)).foregroundStyle(Theme.faint)
                Mono(clock.dataHour.map { String(format: "%02d:00", $0) } ?? "—", step: .sub, color: Theme.tx)
                if let v = clock.verdict {
                    Text(v.label).font(Theme.font(.xl, weight: .bold)).foregroundStyle(verdictTint)
                }
                Text(verdictNote).font(Theme.font(.xs)).foregroundStyle(Theme.faint)
            }

            MarketClockBand(clock: clock, pos: pos, picked: pickedHour) { h in
                pickedHour = pickedHour == h ? nil : h // 再点同格收起（web 同款）
            }

            // 点击查值读数行（色带正下方固定位置、不贴指针——指尖不遮挡；通用原则：
            // 移动端查值读数放固定位置）。web .mc-pick 对拍：hover title 独享的信息在此有了触屏等价物
            if let ph = pickedHour {
                clockPickRow(hour: ph, level: pos(clock.levels[ph]))
                    // 进出淡入淡出（MOTION.md §3-B/§3-H：状态行不瞬现瞬隐）；事务由卡片级
                    // .motion(value: pickedHour) 驱动，RM 门内建（置 nil 即瞬时）
                    .transition(.opacity)
            }

            // 读数行：高位窗口 / 涨幅 / 最低小时（窗口缺失时整行不渲染，与网页端一致）
            if let line = readout {
                Text(line)
                    .font(Theme.font(.xs)).monospacedDigit().foregroundStyle(Theme.dim)
            }

            Text("按 \(clock.counted) 种子弹 7 天小时曲线逐弹归一（相对自身 7 天均价）后跨弹取中位聚合；「数据时刻」为快照曲线末点的墙钟时刻，不用设备本地时间。历史统计不代表未来。")
                .font(Theme.font(.xs)).foregroundStyle(Theme.faint)
        }
        // 查值行进出动画（animFast 微交互档）：选格/收起是查询类轻交互，快过面板档；
        // 同一 value 顺带驱动格描边两档切换（色过渡无布局成本，MOTION.md §6-1）
        .motion(Theme.animFast, value: pickedHour)
        // 选格触感（§5 selection 档：查询类轻交互）；trigger 只绑本卡局部 State
        .sensoryFeedback(.selection, trigger: pickedHour)
        .card()
    }

    /// 查值读数行：所选小时 + 相对水位（无样本小时如实标注，不冒充水位）；命中数据时刻追加标注。
    /// 主读数 txStrong semibold 立权（对齐 web .mc-pick b），收起提示 faint 收尾
    private func clockPickRow(hour: Int, level: Double?) -> some View {
        let val = level.map { "\(Int(($0 * 100).rounded()))%" } ?? "无样本"
        return (Text(String(format: "%02d:00 · 相对水位 ", hour)).foregroundStyle(Theme.dim)
            + Text(val).foregroundStyle(Theme.txStrong).fontWeight(.semibold)
            + Text(clock.dataHour == hour ? " · 数据时刻" : "").foregroundStyle(Theme.faint)
            + Text("（再点该格收起）").foregroundStyle(Theme.faint))
            .font(Theme.font(.xs))
            .monospacedDigit()
    }
}

/// 24 格水位色带：每格竖槽内水位条按位置升起的迷你直方图 + 数据时刻 ▼ 指针
private struct MarketClockBand: View {
    let clock: MarketClock
    /// 与卡片同口径的水位取位函数（0-1；nil = 该小时无样本）
    let pos: (Double?) -> Double?
    /// 点击查值选中的小时（nil = 无选中）；高亮描边在格内、读数行由持有方（卡片）渲染
    var picked: Int? = nil
    /// 点格回调（「再点同格收起」的切换由卡片完成）
    var onPick: (Int) -> Void = { _ in }

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
            // 描边两档（对齐 web .pick/.now）：选中格 accent 实线全亮 > 数据时刻 accentDim；
            // 选中优先——用户主动查询的回声要强于数据被动标注
            .overlay(RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .stroke(picked == h ? Theme.accent : (now ? Theme.accentDim : .clear), lineWidth: 1))
            // 小时标注：只标 0/6/12/18（纯 ASCII 时码走 mono）。
            // fixedSize 按理想尺寸绘制：24 格均分后单格仅 ~13pt，两位时码（~13.2pt）原先
            // 被行内压缩成墨点/竖痕全部不可读（截图实证）；标注位左右相邻 5 格均为空，
            // 按理想宽绘制微溢出无碍。槽位固定高度保证 24 根水位条顶部对齐不受影响
            Text(h % 6 == 0 ? String(format: "%02d", h) : "")
                .font(Theme.monoFont(.micro))
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
                .fixedSize()
                .frame(maxWidth: .infinity)
                .frame(height: 14)
        }
        // 点击查值（触屏等价物，对齐 web mc-cell @click + 固定读数行）：格宽 ~13pt 低于 44pt
        // 命中区标准，但误触邻格的代价极低——读数行实时回显所选小时、即刻自纠（web 同款取舍）；
        // contentShape 把整列（指针槽 + 轨道 + 时码）都划进命中区，纵向尽量垫高
        .contentShape(Rectangle())
        .onTapGesture { onPick(h) }
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
