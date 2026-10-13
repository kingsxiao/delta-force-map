# 三角洲行动 · 高清地图与打法详解

Vite + Vue 3 工程（JavaScript）：烽火地带六张地图（零号大坝 / 长弓溪谷 / 巴克什 / 航天基地 / 潮汐监狱 / AZ3核电站）的高清标注大图 + 实战打法 + 物资爆率参考、**枪械 TTK 击杀时间排行**页（全枪械 7 兵种 × 各级弹药与护甲），以及**子弹行情实时监控**页（88 种交易行子弹的买卖点与税后利润）。`legacy/` 旧单文件页已整体完成组件化迁移：四个路由页面（地图 / 打法 / TTK 排行 / 子弹行情）均为完整实现，`legacy/` 仅作只读留档。

## 开发

```bash
npm install        # 安装依赖
npm run dev        # 启动开发服务器（默认 http://localhost:5173/）
npm run build      # 构建产物到 dist/
npm run preview    # 本地预览构建产物
```

- 路由为 **hash 模式**（`/#/`、`/#/tactics`、`/#/ttk`、`/#/ammo`），静态托管零配置；页内锚点一律 `scrollIntoView`，禁止向 hash 写入裸锚点。
- 旧单文件页（`index.html`、`ttk.html`、`shaders.iife.js`）已挪到 **`legacy/`** 留档（只读，不再维护）；特效库的运行时副本在 `src/vendor/shaders.iife.js`，由特效组件动态 import。
- 静态目录为默认的 **`public/`**（dev 于 `/` 下访问、build 原样拷入 dist 根）；`assets/` 原图不走 public，一律模块 import，仅被引用的文件进 dist。

## 特效层验证

`scripts/verify-effects.mjs` 自包含、零 npm 依赖，只 spawn headless Chrome，**不拉起 dev server**。使用流程：

```bash
npm run dev                                                # 终端 1
node scripts/verify-effects.mjs http://localhost:5173/ shots   # 终端 2（reduced 模式加 --reduced）
```

verify 依赖的 DOM 契约（页面迁移时必须保持，判据已冻结）：

- `.map-section` 恰 6 个、`.hs` 恰 169 个
- `button[data-act="full"]`（地图卡「全屏查看」按钮）
- `#fxHero`、`#fxLb`（特效画布）、`#lbClose`（灯箱关闭按钮）
- `document.documentElement` 的 `locked` 类随灯箱开关加 / 删
- `<html data-fx>` ∈ { on, off, fallback, unsupported, reduced }

## 功能

- **页内交互地图查看器**：拖拽平移、滚轮以光标为中心缩放（1–7x）、双击放大、+/−/复位按钮、触屏单指拖动与双指捏合、键盘操作
- **169 个可点击标注**：出生点 / 撤离点 / Boss / 高价值物资点，四类分层可开关，点击弹出要点信息卡
- **逐出生点打法卡**：每个出生点四块——打法思路 / 需要注意 / 能抽过点的位置 / 哪里要封烟
- 撤离点条件、资源搜刮路线、Boss 情报、实战建议
- 每图物资点爆率表（社区统计口径）

## TTK 排行页

- **68 把武器 × 20 种口径 × 93 种弹药**的 TTK / BTK 排行（步枪 / 冲锋枪 / 射手步枪 / 狙击枪 / 轻机枪 / 霰弹枪 / 手枪），可切目标部位（胸 / 腹 / 头）、护甲等级（无甲 ~ 6 级）与子弹筛选（每枪最佳 / 全部组合 / 按穿透等级 0-7 级），每枪可展开全部弹药的逐发模拟对比
- **穿透 × 护甲判定矩阵**（0% / 50% / 75% / 100% 国服社区实测口径）与弹药库全表
- 计算口径：100 血单血池、部位倍率、碎甲 k 值规则、TTK = (BTK−1)×60000/RPM，全部假设与来源在页内注明

## 子弹行情监控页（/#/ammo）

88 种交易行子弹的实时价格、买卖点与**税后利润测算**（能赚多少），并在本机后台监控时弹出 macOS 系统通知——具体到哪种子弹、什么价格买入、挂多少钱卖出、每发预赚多少。

```bash
npm run ammo:fetch     # 单次抓取 + 分析，落盘 public/ammo/market.json（页面数据源）
npm run ammo:monitor   # 后台监控循环（默认 30 分钟一次；--interval N 可调，--no-notify 静默）
```

- **数据源**：KK三角洲一图流（kkrb.net）交易行子弹盈亏接口，约每小时更新；抓取脚本零 npm 依赖（会话三步引导：首页 PHPSESSID → getMenu 签发 csrf_token → getAmmoPLData）
- **买卖口径**：近 7 天每小时价格曲线分位数回归——当前价 ≤ P25 且税后收益率 ≥ 8% 判「买入」，≥ P80 判「卖出」；目标挂卖价取 P75，税率按上游税后价实测反推（约 15%，逐弹计算）
- **通知去重**：同一信号 6 小时冷却，价格再跌 5% 或信号切换（买入 ↔ 卖出）立即再报
- 页面含：买入信号卡（买入价 / 挂卖价 / 税后到手 / 预赚每发与收益率）、卖出高位简表、全表筛选排序、每行 7 天走势 sparkline、点击行展开大图（P25/P75 参考线）
- `data/ammo/`（历史快照与监控状态）已 gitignore，不入库

## 数据说明

- 点位坐标来自官方地图工具公开数据；打法与爆率整理自社区公开资料（官方工具、wiki、图文与视频攻略），**未在游戏内逐条实测**
- 爆率为社区统计口径（S/A/B 分级 + 定性排名），官方从未公布精确百分比，可能与实际掉落有出入
- 数据基线 2026-08 ~ 2026-10，版本更新后以游戏内战术地图为准

## 目录

- `index.html` / `vite.config.js` / `package.json` — Vite + Vue 3 工程入口与配置
- `src/` — Vue 视图、组件、样式设计令牌与数据（自 `legacy/` 迁移完成）
- `public/` — 构建时原样拷入 dist 的静态资源（如抽取出的图片、`ammo/market.json` 行情快照）
- `scripts/ammo/` — 子弹行情抓取 / 分析 / 监控脚本（零 npm 依赖：kkrb-client / analyze / notify / fetch-once / monitor）
- `legacy/` — 旧单文件页留档：`index.html`（含全部数据与图片）、`ttk.html`（TTK 排行）、`shaders.iife.js`（WebGPU 特效库；只读，运行时以 `src/vendor/` 副本为准）
- `scripts/verify-effects.mjs` — 特效层自动化验证脚本（零 npm 依赖，用法见上）
- `assets/<地图>/hotspots.json` — 各图点位标定数据留档
- `assets/` 其余 — 各图原始高清底图留档

## 版权

游戏素材（底图瓦片等）版权归腾讯/天美所有。本项目仅供个人学习参考，请勿用于商业用途。
