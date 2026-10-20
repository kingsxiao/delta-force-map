// MapsView.swift — 高清地图 / 打法：直接载入自托管网页端（hash 路由 /#/、/#/tactics）
// 这两页是重内容（6 张大图 + 166 点位 + 打法卡），原生重做收益低；WebView 复用网页端即全量覆盖。
// 加载三态（进行中/完成/失败+重试）+ UIRefreshControl 下拉刷新 + hash 路由白名单双向同步；
// 网页端 viewport 未做 viewport-fit=cover（apps/web/index.html），原生侧让出 Home 指示条区域。
import DeltaForceCore
import SwiftUI
import WebKit

/// WebView 加载三态：进行中（带进度）/ 完成 / 失败（带可读原因）
enum WebLoadState: Equatable {
    case loading, loaded, failed(String)
}

/// hash 白名单：fragment 为空或 “/” 视作首页，“/tactics” 视作打法页；其余（外链、未知 fragment）一律不识别
private func routeFromFragment(_ fragment: String?) -> String? {
    switch fragment ?? "" {
    case "", "/": return "/"
    case "/tactics": return "/tactics"
    default: return nil
    }
}

/// 去掉 URL 的 hash 部分（用于判断是否仍在本站范围内）
private func stripHash(_ u: URL) -> String {
    var s = u.absoluteString
    if let i = s.firstIndex(of: "#") { s = String(s[..<i]) }
    return s
}

struct MapsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.tabSelection) private var tabSelection
    @State private var route = "/"
    @State private var reloadToken = 0
    @State private var loadState = WebLoadState.loading
    @State private var progress: Double = 0
    @State private var refreshDoneTick = 0 // 刷新完成反馈（本页局部 tick，操作后自增）

    var body: some View {
        NavigationStack {
            Group {
                if let client = app.settings.client {
                    webLayer(client)
                } else {
                    // 首次演示模式：直接给出「去设置」动线（经 RootView 暴露的 AppTab Binding 切页）
                    ContentUnavailableView {
                        Label("未配置服务器", systemImage: "server.rack")
                    } description: {
                        Text("在「设置」填入自托管服务地址后，这里加载网页版的高清地图与打法（同一后端）。")
                    } actions: {
                        Button {
                            tabSelection.wrappedValue = .settings
                        } label: {
                            Label("去设置", systemImage: "gearshape")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .background(Theme.bg)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    // 分段控件即页面身份（不另设动态 navigationTitle，避免与 principal 冲突）
                    Picker("页面", selection: $route) {
                        Text("地图").tag("/")
                        Text("打法").tag("/tactics")
                    }
                    .pickerStyle(.segmented)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        progress = 0
                        loadState = .loading
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新页面")
                    .disabled(app.settings.client == nil)
                }
            }
            .onChange(of: app.settings.settings.baseURL) { _, _ in
                // 服务器地址变更 → 整页重载，重新走三态
                progress = 0
                loadState = .loading
            }
            .sensoryFeedback(.selection, trigger: route) // 地图 / 打法分段切换
            .sensoryFeedback(.success, trigger: refreshDoneTick) // 刷新完成轻触反馈
        }
    }

    /// WebView 主体 + 加载中 / 失败覆盖层（成功态不遮挡网页内容）
    @ViewBuilder
    private func webLayer(_ client: APIClient) -> some View {
        ZStack {
            WebView(
                url: client.webURL(route: route),
                reloadToken: reloadToken,
                onState: { loadState = $0 },
                onProgress: { progress = $0 },
                onRoute: { route = $0 },
                onPullRefresh: { reloadToken += 1 }, // 下拉刷新不叠加 loading 遮罩，由转圈指示器承担反馈
                onRefreshDone: { refreshDoneTick += 1 }
            )
            switch loadState {
            case .loaded:
                EmptyView()
            case .loading:
                VStack(spacing: 8) {
                    ProgressView(value: min(max(progress, 0.05), 1))
                        .frame(maxWidth: 240)
                    Text("正在加载网页版内容…")
                        .font(Theme.font(.xs))
                        .foregroundStyle(Theme.dim)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            case .failed(let message):
                ContentUnavailableView {
                    Label("加载失败", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("重试") {
                        progress = 0
                        loadState = .loading
                        reloadToken += 1
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg)
            }
        }
    }
}

struct WebView: UIViewRepresentable {
    let url: URL
    var reloadToken = 0
    // SwiftUI 侧接线（makeUIView 注入）：加载三态 / 进度 / hash 路由回写 / 下拉刷新
    var onState: (@MainActor (WebLoadState) -> Void)?
    var onProgress: (@MainActor (Double) -> Void)?
    var onRoute: (@MainActor (String) -> Void)?
    var onPullRefresh: (@MainActor () -> Void)?
    var onRefreshDone: (@MainActor () -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = UIColor(Theme.bg)
        web.scrollView.backgroundColor = UIColor(Theme.bg)
        web.scrollView.alwaysBounceVertical = true // 内容不满一屏也保住下拉刷新手势
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator

        let coordinator = context.coordinator
        coordinator.onState = onState
        coordinator.onProgress = onProgress
        coordinator.onRoute = onRoute
        coordinator.onPullRefresh = onPullRefresh
        coordinator.onRefreshDone = onRefreshDone

        // 下拉刷新（与全站 .refreshable 同一心智）：触发 reloadToken+1，didFinish 停转并给完成反馈
        let control = UIRefreshControl()
        control.addTarget(coordinator, action: #selector(Coordinator.pullRefreshed), for: .valueChanged)
        web.scrollView.addSubview(control)
        coordinator.refreshControl = control

        // KVO 回调为非隔离：先算出纯值，再经 Task { @MainActor } 落回主线程（Swift 6 严格并发）
        let onProgress = coordinator.onProgress
        let onRoute = coordinator.onRoute
        coordinator.observations = [
            web.observe(\.estimatedProgress, options: [.new]) { _, change in
                let p = change.newValue ?? 0
                Task { @MainActor in onProgress?(p) }
            },
            web.observe(\.url, options: [.new]) { _, change in
                // 仅本站地址 + 白名单 hash 才回写 route；外链 / 未知 fragment 一律忽略；
                // 基址比对在主线程读 Coordinator.base（随每次 load 更新），改服务器地址后回写不失效
                guard let current = change.newValue ?? nil,
                      let target = routeFromFragment(current.fragment)
                else { return }
                Task { @MainActor in
                    guard stripHash(current) == coordinator.base else { return }
                    onRoute?(target)
                }
            },
        ]

        coordinator.load(url, in: web, force: true)
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        let force = context.coordinator.reloadToken != reloadToken
        context.coordinator.reloadToken = reloadToken
        context.coordinator.load(url, in: web, force: force)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var reloadToken = 0
        /// 本站基址（去 hash）：随每次 load 更新，供 KVO 回写比对；地址变更后不残留旧基址
        var base = ""
        private var lastURL: URL?
        /// 自上次 didFinish 后是否发生过整页重载（区分首载与刷新，驱动「刷新完成」反馈）
        private var reloadedSinceFinish = false
        var onState: (@MainActor (WebLoadState) -> Void)?
        var onProgress: (@MainActor (Double) -> Void)?
        var onRoute: (@MainActor (String) -> Void)?
        var onPullRefresh: (@MainActor () -> Void)?
        var onRefreshDone: (@MainActor () -> Void)?
        weak var refreshControl: UIRefreshControl?
        var observations: [NSKeyValueObservation] = []

        /// 下拉刷新触发（UIRefreshControl valueChanged，主线程）
        @objc func pullRefreshed() {
            onPullRefresh?()
        }

        // MARK: WKNavigationDelegate — 加载三态切换

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleLoadError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleLoadError(error)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onState?(.loaded)
            refreshControl?.endRefreshing()
            if reloadedSinceFinish {
                reloadedSinceFinish = false
                onRefreshDone?() // 刷新完成 → 轻触反馈
            }
        }

        private func handleLoadError(_ error: Error) {
            refreshControl?.endRefreshing()
            reloadedSinceFinish = false
            let ns = error as NSError
            // -999（新导航打断旧导航）不算失败，避免 hash 切换 / 快速操作时误报错误态
            guard !(ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled) else { return }
            onState?(.failed("无法加载网页：\(ns.localizedDescription)。请检查服务器地址与网络后重试。"))
        }

        /// hash 路由切换只需改 location（不整页重载）；地址变化或手动刷新才 load
        func load(_ url: URL, in web: WKWebView, force: Bool) {
            base = stripHash(url)
            if !force, let last = lastURL, last == url { return }
            if force { reloadedSinceFinish = true }
            if !force, let last = lastURL, stripHash(last) == stripHash(url), let hash = url.fragment {
                web.evaluateJavaScript("location.hash = '#\(hash)'")
            } else {
                web.load(URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 30))
            }
            lastURL = url
        }
    }
}
