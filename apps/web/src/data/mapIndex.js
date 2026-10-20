// mapIndex.js — 六图元信息装配（工程师A）
// 数据源：src/data/maps/<slug>.json（玩法与物资档位数据，extract-data.mjs 产物）
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

/** fig 元信息（label/cap/hs 来自 legacy map-data 的 fig 字段；src 指向 public/figs 抽取产物；
 *  w/h 为 <slug>-{0,1}.jpg 实测固有像素（sips 量得），供 .fig-frame 预置 aspect-ratio 免 CLS） */
const FIG_META = {
  linghaodaba: [
    { label: '标注图', cap: '官方工具全量点位标注：出生点 14 处 · 打法卡详写 5 类主要出生点 / 撤离点 8 处 / 赛伊德 / 约 360 个物资点', hs: true, w: 1238, h: 1093 },
    { label: '原始底图', cap: '官方瓦片拼接原始底图（已裁剪至地图主体范围）', hs: true, w: 1238, h: 1093 },
  ],
  changgongxigu: [
    { label: '全点位标注', cap: '社区交互地图底图 + 335 个点位合成标注：出生点 22 处 · 打法卡详写 5 类主要出生点 / 撤离点 7 处 / 钥匙房 21 处 / 保险箱 / 服务器 / 鸟窝', hs: true, w: 2048, h: 2048 },
    { label: '纯净底图', cap: 'deltaforce-maps 瓦片拼接纯净底图（同一图幅）', hs: true, w: 1792, h: 1792 },
  ],
  bakeshi: [
    { label: '全图底图', cap: '官方暗色底图瓦片拼接（已裁剪至地图主体，可点标注基于官方点位数据）', hs: true, w: 858, h: 1073 },
    { label: '撤离点标注', cap: '官方地图工具撤离点截图拼合（静态拼图，无交互标注）', hs: false, w: 1792, h: 865 },
  ],
  hangtianjidi: [
    { label: '标注图', cap: '官方瓦片底图 + 程序化标注：13 个区域 / 出生点 / 撤离点 / 保险柜', hs: true, w: 1400, h: 1542 },
    { label: '纯净底图', cap: '官方瓦片拼接提亮版（已裁剪至地图主体范围）', hs: true, w: 943, h: 1040 },
  ],
  chaoxijianyu: [
    { label: '标注图', cap: '官方点位数据渲染标注：出生点 14 处 · 打法卡详写 5 类主要出生点 / 撤离点 5 处 / 16 个区域 / 443 个容器', hs: true, w: 1332, h: 1128 },
    { label: '一层平面图', cap: '官方 1F 楼层瓦片拼接提亮版（静态拼图，无交互标注）', hs: false, w: 2048, h: 1978 },
  ],
  hedianzhan: [
    { label: '标注图', cap: '官方点位数据自绘标注：出生点 / 撤离点 / 区域', hs: true, w: 1415, h: 1070 },
    { label: '纯净底图', cap: '官方瓦片拼接提亮版（已裁剪至地图主体范围）', hs: true, w: 1238, h: 937 },
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
