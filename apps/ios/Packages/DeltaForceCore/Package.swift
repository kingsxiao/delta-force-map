// swift-tools-version: 6.0
// DeltaForceCore — iOS 端的纯逻辑内核（Foundation-only，无 UI 依赖）
// 放进本地 Swift Package 的原因：
//   · 契约口径（shared/js 的 sellEta / marketMeta / notify-policy、server 的 TTK
//     模型）在这里同构移植，`swift test` 在 macOS 上就能跑单测，不依赖模拟器
//   · App 壳（apps/ios/DeltaForce）只做 SwiftUI 视图与状态编排，逻辑可独立演进
import PackageDescription

let package = Package(
    name: "DeltaForceCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DeltaForceCore", targets: ["DeltaForceCore"]),
    ],
    targets: [
        .target(name: "DeltaForceCore"),
        .testTarget(name: "DeltaForceCoreTests", dependencies: ["DeltaForceCore"]),
    ],
    swiftLanguageModes: [.v6]
)
