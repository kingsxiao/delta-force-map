// ItemDetailView.swift — 单品详情（子弹 / 雷达物品共用）：大图 + 统计 + 预计卖出 + 双源校验
import DeltaForceCore
import SwiftUI

struct ItemDetailView: View {
    @Environment(AppModel.self) private var app
    let item: MarketItem
    // 本页局部触觉 tick（星标切换成功；trigger 只绑本页 State）
    @State private var favTick = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                PriceChart(item: item).card()
                stats
                sellEta
                if item.hiRank != nil { radarCard }
                MethodNote(source: nil).card()
            }
            .padding(12)
            // regular 宽度（iPad / 横屏）内容列上限 640 居中：对齐网页 --wrap 可读列，大图不再全宽拉伸
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.success, trigger: favTick)
        .toolbar {
            Button {
                app.favorites.toggle(item.name)
                favTick += 1
            } label: {
                Image(systemName: app.favorites.contains(item.name) ? "star.fill" : "star")
                    .foregroundStyle(Theme.warn)
            }
            .accessibilityLabel(app.favorites.contains(item.name) ? "取消自选" : "加入自选")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ItemThumb(pic: item.pic, size: 56)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    GradeBadge(grade: item.grade)
                    if let c = item.category { CategoryChip(text: c) }
                    if let r = item.hiRank { CategoryChip(text: "涨幅榜 #\(r)") }
                }
                HStack(spacing: 8) {
                    SignalChip(signal: item.signal, anomaly: item.isAnomaly)
                    Text(item.isAnomaly ? "双源口径分歧，信号压制为观望" : item.signal.hint)
                        .font(Theme.font(.xs)).foregroundStyle(Theme.dim)
                }
            }
            Spacer()
            VStack(alignment: .trailing) {
                Text("现价").font(Theme.font(.micro)).foregroundStyle(Theme.faint)
                Mono(Fmt.price(item.current), size: 22, weight: .bold)
            }
        }
        .card()
    }

    private var stats: some View {
        VStack(spacing: 10) {
            statQuad(
                StatCell(label: "7 天分位", value: Fmt.rankPercent(item.rank)),
                StatCell(label: "P25", value: Fmt.price(item.p25), color: Theme.ok),
                StatCell(label: "P50", value: Fmt.price(item.p50)),
                StatCell(label: "P75", value: Fmt.price(item.p75), color: Theme.danger)
            )
            Divider().overlay(Theme.line)
            statQuad(
                StatCell(label: "周低", value: Fmt.price(item.weekLow)),
                StatCell(label: "周高", value: Fmt.price(item.weekHigh)),
                StatCell(label: "税率", value: Fmt.pct(item.taxRate).replacingOccurrences(of: "+", with: "")),
                StatCell(label: "样本", value: "\(item.curve.count) 点")
            )
            Divider().overlay(Theme.line)
            statQuad(
                StatCell(label: "目标挂卖 (P75)", value: Fmt.price(item.targetSell), color: Theme.danger),
                StatCell(label: "税后到手", value: Fmt.price(item.netSell)),
                StatCell(label: "预赚 / 发", value: Fmt.price(item.profitPerRound), color: (item.profitPerRound ?? 0) > 0 ? Theme.ok : Theme.faint),
                StatCell(label: "收益率", value: Fmt.pct(item.profitPct), color: (item.profitPct ?? 0) > 0 ? Theme.ok : Theme.faint)
            )
            RankBar(item: item)
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

    /// 统计四格行：宽度足够时一行 4 列，窄屏 / 特大字号自动折成 2×2 两行（ViewThatFits 纵向堆叠）
    private func statQuad(_ a: StatCell, _ b: StatCell, _ c: StatCell, _ d: StatCell) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack { a; b; c; d }
            VStack(alignment: .leading, spacing: 8) {
                HStack { a; b }
                HStack { c; d }
            }
        }
    }

    @ViewBuilder
    private var sellEta: some View {
        if let eta = SellEtaEngine.predict(item: item) {
            VStack(alignment: .leading, spacing: 8) {
                // 含中文标题：默认 design + 等宽数字（mono 只留给纯 ASCII）
                Text("预计卖出时间").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
                if eta.atTarget {
                    Text("现价已达挂卖价，可直接挂单。").font(Theme.font(.sm)).foregroundStyle(Theme.tx)
                } else if let med = eta.medianH {
                    statQuad(
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

    private var radarCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 含中文标题：默认 design + 等宽数字（mono 只留给纯 ASCII）
            Text("双源交叉验证").font(Theme.font(.xs, weight: .bold)).monospacedDigit().foregroundStyle(Theme.accent)
            statQuad(
                StatCell(label: "中位偏差", value: item.crossDev.map { Fmt.pct($0).replacingOccurrences(of: "+", with: "") } ?? "样本不足", color: item.isAnomaly ? Theme.warn : Theme.txStrong),
                StatCell(label: "重叠小时", value: "\(item.crossOverlap ?? 0)"),
                StatCell(label: "原始信号", value: item.rawSignal?.label ?? "—"),
                StatCell(label: "曲线源", value: item.curveSource ?? "—")
            )
            Text(item.isAnomaly
                 ? "kkrb 与 moligod 曲线在重叠小时上的中位偏差 > 15%：口径分歧时宁可漏报，信号强制观望、不通知。"
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
