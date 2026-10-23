// RootView.swift — 五个 Tab：行情 / 雷达 / 制造 / TTK / 设置
// （tint 由 App 入口统一——DeltaForceApp.swift 根上已有 .tint(Theme.accent)，这里不重复设置）
import SwiftUI

/// Tab 枚举：纯视图状态（不触 State/ 数据层），供跨页深链切 Tab（如 UI 巡检 -startTab 启动参数）
enum AppTab: Hashable {
    case ammo, radar, craft, ttk, settings
}

/// 经 environment 暴露 Tab 选中 Binding 的 key（默认 .constant，保证预览/独立预览不炸）
private struct TabSelectionKey: EnvironmentKey {
    static let defaultValue: Binding<AppTab> = .constant(.ammo)
}

extension EnvironmentValues {
    /// 当前 Tab 选中 Binding：子页用 `@Environment(\.tabSelection)` 读写即可切 Tab
    var tabSelection: Binding<AppTab> {
        get { self[TabSelectionKey.self] }
        set { self[TabSelectionKey.self] = newValue }
    }
}

struct RootView: View {
    // UI 截图巡检钩子：`simctl launch` 传 -startTab <tab> 直达指定 Tab（生产无此参数，默认行情，行为不变）
    @State private var selection = RootView.launchStartTab()
    // 通知点击深链：pendingDetailName 置位时切回行情 Tab（详情 push 由 AmmoView 消费同一状态完成）
    @Environment(AppModel.self) private var app

    private static func launchStartTab() -> AppTab {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-startTab"), i + 1 < args.count else { return .ammo }
        switch args[i + 1] {
        case "radar": return .radar
        case "craft": return .craft
        case "ttk": return .ttk
        case "settings": return .settings
        default: return .ammo
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            AmmoView()
                // 自绘战术图标（Assets.xcassets 内 8 枚 symbolset）：未选中=线性，选中=线+核填充（DESIGN.md §6.2）
                .tabItem { Label("行情", image: selection == .ammo ? "tab-ammo-fill" : "tab-ammo-line") }
                .tag(AppTab.ammo)
            RadarView()
                .tabItem { Label("雷达", image: selection == .radar ? "tab-radar-fill" : "tab-radar-line") }
                .tag(AppTab.radar)
            CraftView()
                .tabItem { Label("制造", image: selection == .craft ? "tab-craft-fill" : "tab-craft-line") }
                .tag(AppTab.craft)
            TtkView()
                .tabItem { Label("TTK", image: selection == .ttk ? "tab-ttk-fill" : "tab-ttk-line") }
                .tag(AppTab.ttk)
            SettingsView()
                .tabItem { Label("设置", image: selection == .settings ? "tab-settings-fill" : "tab-settings-line") }
                .tag(AppTab.settings)
        }
        // Tab 根氛围（DESIGN.md §5 / §8-6）：转场保持系统默认（不自绘 Tab 切换动画）；
        // 背景只做 Theme.bg 全屏铺底（background 默认忽略安全区，含 Tab 栏下缘），
        // 五页统一纯净深底——web 端噪点 / 光晕背景明确不搬，列表页保持 Theme.bg
        .background(Theme.bg)
        .environment(\.tabSelection, $selection)
        // 消费后置 nil 会再次触发本 onChange（值变 nil），guard 挡住不重复切；
        // 通知点击时若停在别的 Tab，先切回行情，AmmoView 的 onAppear/onChange 再接手 push
        .onChange(of: app.pendingDetailName) { _, name in
            guard name != nil else { return }
            selection = .ammo
        }
    }
}
