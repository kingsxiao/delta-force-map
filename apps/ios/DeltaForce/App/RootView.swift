// RootView.swift — 四个 Tab：行情 / 雷达 / TTK / 设置
// （tint 由 App 入口统一——DeltaForceApp.swift 根上已有 .tint(Theme.accent)，这里不重复设置）
import SwiftUI

/// Tab 枚举：纯视图状态（不触 State/ 数据层），供跨页深链切 Tab（如 UI 巡检 -startTab 启动参数）
enum AppTab: Hashable {
    case ammo, radar, ttk, settings
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

    private static func launchStartTab() -> AppTab {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-startTab"), i + 1 < args.count else { return .ammo }
        switch args[i + 1] {
        case "radar": return .radar
        case "ttk": return .ttk
        case "settings": return .settings
        default: return .ammo
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            AmmoView()
                .tabItem { Label("行情", systemImage: "chart.line.uptrend.xyaxis") }
                .tag(AppTab.ammo)
            RadarView()
                .tabItem { Label("雷达", systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppTab.radar)
            TtkView()
                .tabItem { Label("TTK", systemImage: "scope") }
                .tag(AppTab.ttk)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
        .background(Theme.bg)
        .environment(\.tabSelection, $selection)
    }
}
