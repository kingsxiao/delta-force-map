// mapIndex.js — 六图元信息装配（工程师A）
// 数据源：src/data/maps/<slug>.json（玩法与爆率数据，extract-data.mjs 产物）
//        src/data/hotspots/<slug>.json（hs 点位原样透传，含 gs/gl 字段）
// 图片：public/figs/<slug>-{0,1}.jpg（extract-images.mjs 从 legacy base64 抽出的运行时图，
//       dev 于 /figs/... 可访问、build 原样拷入 dist——与 legacy 所显示像素完全一致）。
// 注：assets/ 目录为制作期留档（legacy 运行时不引用其任何文件），此处不 import。
import linghaodaba from './maps/linghaodaba.json'
import changgongxigu from './maps/changgongxigu.json'
import bakeshi from './maps/bakeshi.json'
import hangtianjidi from './maps/hangtianjidi.json'
import chaoxijianyu from './maps/chaoxijianyu.json'
import hedianzhan from './maps/hedianzhan.json'

import linghaodabaHs from './hotspots/linghaodaba.json'
import changgongxiguHs from './hotspots/changgongxigu.json'
import bakeshiHs from './hotspots/bakeshi.json'
import hangtianjidiHs from './hotspots/hangtianjidi.json'
import chaoxijianyuHs from './hotspots/chaoxijianyu.json'
import hedianzhanHs from './hotspots/hedianzhan.json'

/** fig 元信息（label/cap/hs 来自 legacy map-data 的 fig 字段；src 指向 public/figs 抽取产物） */
const FIG_META = {
  linghaodaba: [
    { label: '标注图', cap: '官方工具全量点位标注：14 出生点 / 8 撤离点 / 赛伊德 / 约 360 个物资点', hs: true },
    { label: '原始底图', cap: '官方 z4 瓦片拼接原始底图（4096×4096，同一图幅范围）', hs: true },
  ],
  changgongxigu: [
    { label: '全点位标注', cap: '社区交互地图底图 + 335 个点位合成标注（22 出生 / 7 撤离 / 21 钥匙房 / 保险箱 / 服务器 / 鸟窝）', hs: true },
    { label: '纯净底图', cap: 'deltaforce-maps 瓦片拼接纯净底图（同一图幅范围）', hs: true },
  ],
  bakeshi: [
    { label: '全图底图', cap: '官方暗色底图瓦片拼接全图（可点标注基于官方 map_bks.js 点位数据）', hs: true },
    { label: '撤离点标注', cap: '官方地图工具撤离点截图拼合（非整图坐标，不显示交互标注）', hs: false },
  ],
  hangtianjidi: [
    { label: '标注图', cap: '官方区域坐标仿射对齐后自绘标注：13 区域 / 出生点 / 撤离点 / 保险柜', hs: true },
    { label: '纯净底图', cap: '官方 z4 瓦片拼接提亮版（同一图幅范围）', hs: true },
  ],
  chaoxijianyu: [
    { label: '标注图', cap: '官方点位数据渲染标注：14 出生点 / 5 撤离点 / 16 区域 / 443 个容器', hs: true },
    { label: '一层平面图', cap: '官方 1F 楼层瓦片拼接提亮版（不同图幅，不显示交互标注）', hs: false },
  ],
  hedianzhan: [
    { label: '标注图', cap: '官方 marker 数据自绘标注：出生点 / 撤离点 / 区域', hs: true },
    { label: '纯净底图', cap: '官方瓦片拼接提亮版（同一图幅范围）', hs: true },
  ],
}

const RAW = [
  { meta: linghaodaba, hs: linghaodabaHs },
  { meta: changgongxigu, hs: changgongxiguHs },
  { meta: bakeshi, hs: bakeshiHs },
  { meta: hangtianjidi, hs: hangtianjidiHs },
  { meta: chaoxijianyu, hs: chaoxijianyuHs },
  { meta: hedianzhan, hs: hedianzhanHs },
]

/** 六图完整视图模型：{ map, mode, slug, loot, guide, source, caveat, hs, fig } */
export const MAPS = RAW.map(({ meta, hs }) => ({
  ...meta,
  hs,
  fig: FIG_META[meta.slug].map((f, i) => ({
    ...f,
    src: `/figs/${meta.slug}-${i}.jpg`,
  })),
}))

export default MAPS
