// PlaybookView.swift — 倒卖手册（与 apps/web/src/views/ammo/Playbook.vue 同一份静态内容）
import SwiftUI

struct PlaybookView: View {
    @Environment(\.dismiss) private var dismiss

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
                VStack(alignment: .leading, spacing: 14) {
                    Text("倒卖 = 低价囤消耗品 + 高位分批抛售。信号解决「哪种弹、什么价」，下面是社区攻略里验证过的「什么时间、怎么操作」——按 时段 → 买 → 卖 → 窗口 串成一条完整动线。")
                        .font(Theme.font(.sm)).foregroundStyle(Theme.dim)

                    // 自适应列：iPhone 2 列，iPad / 横屏按可用宽度自动多列
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                        ForEach(windows) { w in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Mono(w.time, size: 13, relativeTo: .footnote)
                                    Spacer()
                                    // 中文标签（扫货 / 囤货…）：默认 design + 等宽数字
                                    Text(w.tag)
                                        .font(Theme.font(.micro, weight: .bold))
                                        .monospacedDigit()
                                        .foregroundStyle(w.buy ? Theme.ok : Theme.danger)
                                        .padding(.horizontal, 7).padding(.vertical, 1)
                                        .overlay(Capsule().stroke((w.buy ? Theme.ok : Theme.danger).opacity(0.4)))
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
