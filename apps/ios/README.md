# apps/ios — 三角洲行动助手（iOS 原生端）

SwiftUI 原生 App，与网页端共用同一个自托管后端（`server/`），不自带任何抓取逻辑：
读 `/ammo/market.json`、`/market/radar.json`、`/craft/craft.json` 快照，连 `/events` SSE
实时通道（契约见 [shared/API.md](../../shared/API.md)）。

## 技术栈

| 项 | 选择 | 说明 |
| --- | --- | --- |
| 语言 | Swift 6（`SWIFT_STRICT_CONCURRENCY=complete`） | 全量严格并发，零数据竞争警告 |
| UI | SwiftUI + Observation（`@Observable`） | iOS 17+，iPhone / iPad 通用 |
| 图表 | Swift Charts | 7 天曲线 + P25/P75 参考线、行内 sparkline |
| 网络 | URLSession async/await；`URLSession.bytes` 做 SSE | 零第三方依赖 |
| 逻辑内核 | 本地 Swift Package `Packages/DeltaForceCore`（Foundation-only） | `swift test` 在 macOS 上直接跑，不依赖模拟器 |
| 测试 | Swift Testing | 52 个用例 / 8 个测试文件，含与网页端 JS 模型逐发对账的 TTK 参数化用例 |
| 工程 | [xcodegen](https://github.com/yonaskolb/XcodeGen) `project.yml` → `DeltaForce.xcodeproj` | 工程文件已提交；改 `project.yml` 后 `xcodegen generate` |
| 通知 | UserNotifications 本地通知 | 去抖口径同后端 notify-policy |

后端地址固定为 `https://xiaofating.cc`（`APIClient.productionBaseURL`，全 App 唯一
实例化点），无自配服务器 / 演示模式；ATS 不放行任何明文例外。

## 功能（五个 Tab）

- **行情**：买入信号卡（买入价 / 挂卖价 / 到手 / 预赚 / 预计到价）、全表筛选排序搜索、
  自选置顶（左滑星标）、行内 sparkline、详情大图（P25 / P75 参考线）、预计卖出时间、
  囤货台账与成本试算、倒卖手册
- **雷达**：涨幅榜 Top10、品类 / 信号 / 双源偏差、「只看双源异常」、详情含交叉验证卡
- **制造**：特勤处四大制造台利润榜（时利最佳推荐、制造台筛选、价格完整口径、缺价降级「—」）、
  配方详情（利润拆解 + 材料清单 + 参照区间）
- **TTK**：68 枪 × 20 口径 × 93 弹药，兵种 / 部位 / 护甲 / 弹药筛选，逐枪全弹药对比（完全离线）
- **设置**：连接状态 / 版本 / 立即刷新全部快照、信号通知、账号与云同步入口

- **账号**（设置 → 账号与云同步）：注册 / 登录 / 登出（token 存 Keychain），自选星标 +
  囤货台账云同步——登录后云端与本地合并（星标并集 / 台账按弹名合并·本机优先）、改动防抖
  上云（契约 `shared/API.md` §6，与网页端 `/#/account` 同一套账号）

实时链路与网页端一致：首拉快照 → SSE ping（`version` 前进）→ 重拉；SSE 不在线退 60s
轮询，实时在线时轮询放宽到 5 分钟兜底。

## 目录

```
apps/ios/
├── project.yml                      xcodegen 工程描述（资源以文件引用指向 shared/ 与 apps/web，不复制）
├── DESIGN.md                        iOS 端设计契约（字阶 / 色令牌 / 交互规范）
├── DeltaForce.xcodeproj             生成产物（已提交，可直接打开）
├── DeltaForce/
│   ├── App/        入口 / 五 Tab 根 / 设计令牌（对齐网页端 base.css）
│   ├── State/      AppModel（编排）/ FeedModel（三路快照源）/ LiveChannel（SSE）/ Stores / AuthStore（账号 + 云同步）/ NotificationManager
│   ├── Features/   Account / Ammo / Craft / Radar / Settings / Shared（组件、图表）/ TTK
│   └── Resources/  Assets.xcassets
└── Packages/DeltaForceCore/         纯逻辑内核 + 单测
    ├── Sources/DeltaForceCore/      Models / APIClient / SSEClient / MarketMeta / SellEta / NotifyPolicy / TtkEngine / AccountData / CraftModels
    └── Tests/DeltaForceCoreTests/   固定样本来自仓库 shared/fixtures、shared/data
```

捆绑资源（由 `project.yml` 引用）：`shared/data/ttk.json` 与 `shared/data/ammo-alias.json`
（`npm run export:ios` 产出）、`apps/web/public/guns/`（枪械渲染图，文件夹引用）。
`shared/fixtures/*.json` 仅用于内核单测，不捆绑进 App。

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

# 4. 打包（Release 归档 / IPA 导出 / 体积报告；Release 已配 -Osize + Thin LTO + 符号剥离，
#    在仓库根执行）
npm run ios:archive                                  # 未签名 Release 构建 + 体积报告（本地体积检查）
bash deploy/ios-archive.sh --ipa --team <团队ID>      # 真机归档并导出 IPA；TestFlight 加 --method app-store-connect
#    可选 --refresh-data：打包前先 npm run export:ios 重导 TTK 数据

真机 / TestFlight：签名 Team 在 `project.yml` 的 `DEVELOPMENT_TEAM`（当前已写入
`S4R9UW3RSD`，如换自己的团队改这里后重新 `xcodegen generate`）。
`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD=YES` 已打开，Apple Silicon Mac 也能装（需开发者签名）。

## 与契约对齐的约定

- 字段 / 口径以 `shared/API.md` + `shared/schema/*.json` 为准；`DeltaForceCore` 里 `MarketMeta` / `SellEta` /
  `NotifyPolicy` / `TtkEngine` / `AccountData` 是 `shared/js` 与 `server` 对应模块的同构移植，
  改口径三端同步，单测用同一份样本对账。
- 后端固定 https（nginx 443 反代），`Info.plist` 不含 ATS 明文例外；如日后更换后端形态再按需加按域例外。
- iOS 没有常驻后台：通知只在 App 前台拉到新快照时判定；7×24 推送在服务端跑 `npm run serve -- --notify`。
