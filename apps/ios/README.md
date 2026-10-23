# apps/ios — 三角洲行动助手（iOS 原生端）

SwiftUI 原生 App，与网页端共用同一个自托管后端（`server/`），不自带任何抓取逻辑：
读 `/ammo/market.json`、`/market/radar.json` 快照，连 `/events` SSE 实时通道（契约见
[shared/API.md](../../shared/API.md)）。

## 技术栈

| 项 | 选择 | 说明 |
| --- | --- | --- |
| 语言 | Swift 6（`SWIFT_STRICT_CONCURRENCY=complete`） | 全量严格并发，零数据竞争警告 |
| UI | SwiftUI + Observation（`@Observable`） | iOS 17+，iPhone / iPad 通用 |
| 图表 | Swift Charts | 7 天曲线 + P25/P75 参考线、行内 sparkline |
| 网络 | URLSession async/await；`URLSession.bytes` 做 SSE | 零第三方依赖 |
| 逻辑内核 | 本地 Swift Package `Packages/DeltaForceCore`（Foundation-only） | `swift test` 在 macOS 上直接跑，不依赖模拟器 |
| 测试 | Swift Testing | 32 个用例 / 7 个套件，含与网页端 JS 模型逐发对账的 TTK 参数化用例 |
| 工程 | [xcodegen](https://github.com/yonaskolb/XcodeGen) `project.yml` → `DeltaForce.xcodeproj` | 工程文件已提交；改 `project.yml` 后 `xcodegen generate` |
| 通知 | UserNotifications 本地通知 | 去抖口径同后端 notify-policy |

## 功能

- **行情**：买入信号卡（买入价 / 挂卖价 / 到手 / 预赚 / 预计到价）、全表筛选排序搜索、自选置顶（左滑星标）、
  行内 sparkline、详情大图（P25 / P75 参考线）、预计卖出时间、倒卖手册
- **雷达**：涨幅榜 Top10、品类 / 信号 / 双源偏差、「只看双源异常」、详情含交叉验证卡
- **TTK**：68 枪 × 20 口径 × 93 弹药，兵种 / 部位 / 护甲 / 弹药筛选，逐枪全弹药对比，穿透 × 护甲矩阵（完全离线）
- **地图**：WebView 载入自托管网页端的高清地图 / 打法页（重内容复用，不重做）
- **设置**：服务器地址 + 测试连接（探 `/health`）、演示模式（内置 `shared/fixtures` 样本，离线可看）、信号通知
- **账号**（设置 → 账号与云同步）：注册 / 登录 / 登出（token 存 Keychain），自选星标云同步——登录后云端与本地
  并集合并、改动防抖上云（契约 `shared/API.md` §6，与网页端 `/#/account` 同一套账号）

实时链路与网页端一致：首拉快照 → SSE ping（`version` 前进）→ 重拉；探不到 `/health` 退 60s 轮询；
实时在线时轮询放宽到 5 分钟兜底。首次安装默认**演示模式**，填好服务器地址「保存并连接」即切在线。

## 目录

```
apps/ios/
├── project.yml                      xcodegen 工程描述（资源以文件引用指向 shared/ 与 apps/web，不复制）
├── DeltaForce.xcodeproj             生成产物（已提交，可直接打开）
├── DeltaForce/
│   ├── App/        入口 / Tab 根 / 设计令牌（对齐网页端 base.css）
│   ├── State/      AppModel（编排）/ FeedModel（快照源）/ LiveChannel（SSE）/ Stores / AuthStore（账号 + 自选云同步）/ NotificationManager
│   ├── Features/   Ammo / Radar / TTK / Maps / Settings / Shared（组件、图表）
│   └── Resources/  Assets.xcassets
└── Packages/DeltaForceCore/         纯逻辑内核 + 单测
    ├── Sources/DeltaForceCore/      Models / APIClient / SSEClient / MarketMeta / SellEta / NotifyPolicy / TtkEngine
    └── Tests/DeltaForceCoreTests/   固定样本来自仓库 shared/fixtures、shared/data
```

捆绑资源（由 `project.yml` 引用）：`shared/data/ttk.json`（`npm run export:ios` 产出）、
`shared/fixtures/*.json`（演示模式 + 单测）、`apps/web/public/guns/`（枪械渲染图，文件夹引用）。

## 构建 / 测试 / 运行

```bash
# 0. 共享数据有变（TTK 数据或契约样本）时先在仓库根导出
npm run export:ios

# 1. 逻辑内核单测（macOS 直接跑，不需要模拟器）
cd apps/ios/Packages/DeltaForceCore && swift test

# 2. App 编译验证（任意 iOS 模拟器目标，不需要 runtime）
cd apps/ios && xcodebuild -project DeltaForce.xcodeproj -scheme DeltaForce \
  -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO

# 3. 模拟器运行：需要先装 iOS Simulator runtime（Xcode ▸ Settings ▸ Components / Platforms，
#    或 xcodebuild -downloadPlatform iOS），然后 Xcode 打开 DeltaForce.xcodeproj ⌘R，
#    或用 ios-simulator 插件：ios_build_and_run(project: "apps/ios/DeltaForce.xcodeproj", scheme: "DeltaForce")
```

# 4. 打包（Release 归档 / IPA 导出 / 体积报告；Release 已配 -Osize + Thin LTO + 符号剥离）
bash deploy/ios-archive.sh                          # 未签名 Release 构建 + 体积报告（本地体积检查）
bash deploy/ios-archive.sh --ipa --team <团队ID>    # 真机归档并导出 IPA；TestFlight 加 --method app-store-connect
#    可选 --refresh-data：打包前先 npm run export:ios 重导 TTK 数据

真机 / TestFlight：在 Xcode Signing & Capabilities 选自己的 Team 即可（`project.yml` 里 `DEVELOPMENT_TEAM` 留空）。
`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD=YES` 已打开，Apple Silicon Mac 也能装（需开发者签名）。

## 与契约对齐的约定

- 字段 / 口径以 `shared/API.md` + `shared/schema/*.json` 为准；`DeltaForceCore` 里 `MarketMeta` / `SellEta` /
  `NotifyPolicy` / `TtkEngine` 是 `shared/js` 与 `server` 对应模块的同构移植，改口径三端同步，单测用同一份样本对账。
- 明文 `http://IP:8080` 是合法部署形态（未备案 / 内网），`Info.plist` 已放行 `NSAllowsArbitraryLoads`；上 https 后可收紧。
- iOS 没有常驻后台：通知只在 App 前台拉到新快照时判定；7×24 推送在服务端跑 `npm run serve -- --notify`。
