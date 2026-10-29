<script setup>
/* ============================================================
   MarketClock — 全市场日内节律（/ammo 页倒卖手册区块上方）
   ------------------------------------------------------------
   回答「现在几点，该扫货还是该出货」：把全市场每条 7 天曲线逐弹归一
   （相对自身均价的价格比值，消除 162~6140 的单价量纲差）后按小时跨弹
   取中位，得到 24 小时相对水位色带 + 数据时刻指针 + 三档判读。
   算法在 @shared/js/sellEta.js marketClock（iOS SellEta.swift 同构对拍）；
   「数据时刻」取快照曲线末点的墙钟小时，不用设备本地时间——海外设备不错位。
   历史统计不代表未来——脚注必带。
   ============================================================ */
import { computed, ref } from 'vue'
import { marketClock, fmtPeak } from '@shared/js/sellEta.js'

const props = defineProps({
  /** market.json items（快照原样传入，纯函数内部自行过滤曲线不足者） */
  items: { type: Array, default: () => [] },
})

const clock = computed(() => marketClock(props.items))

/* 判读三档（语义对齐倒卖手册 WINDOWS 的扫货 / 出货窗）： */
const VERDICT_META = {
  buy: { label: '扫货', cls: 'buy', note: '全市场处日内相对低位，适合进货' },
  wait: { label: '观望', cls: 'wait', note: '处日内中段，等窗口再动手' },
  sell: { label: '出货', cls: 'sell', note: '全市场处日内相对高位，适合挂卖' },
}
const vMeta = computed(() => (clock.value?.verdict ? VERDICT_META[clock.value.verdict] : null))

/* 全天水位区间（供色带高度与三档配色统一取位；区间平坦时全部居中） */
const span = computed(() => {
  const valid = (clock.value?.levels || []).filter((v) => v != null)
  if (!valid.length) return null
  return { low: Math.min(...valid), high: Math.max(...valid) }
})
function posOf(v) {
  const s = span.value
  if (!s || v == null) return null
  if (!(s.high - s.low > 1e-9)) return 0.5
  return (v - s.low) / (s.high - s.low)
}

/* 24 格色带：高度 = 水位位置（12% 保底），配色按三档（低=ok / 中=faint / 高=danger） */
const cells = computed(() => {
  const c = clock.value
  if (!c) return []
  return c.levels.map((v, h) => {
    const pos = posOf(v)
    return {
      hour: h,
      pos,
      // 无样本小时显一条 2px 灰点线（占位但不冒充水位）
      heightPct: pos == null ? null : 12 + 88 * pos,
      tone: pos == null ? 'none' : pos <= 1 / 3 ? 'low' : pos >= 2 / 3 ? 'high' : 'mid',
      now: c.dataHour === h,
    }
  })
})

const pad2 = (n) => String(n).padStart(2, '0')
const dataClockLabel = computed(() => (clock.value?.dataHour != null ? `${pad2(clock.value.dataHour)}:00` : ''))

/* 高位窗口与最低小时（读数行；窗口缺失时整行不渲染） */
const peakLabel = computed(() =>
  clock.value && clock.value.peakStart != null ? fmtPeak(clock.value.peakStart, clock.value.peakEnd) : null)
const lowHour = computed(() => {
  const s = span.value
  if (!s || !clock.value) return null
  const idx = clock.value.levels.findIndex((v) => v != null && v === s.low)
  return idx >= 0 ? idx : null
})
const pct = (n) => (Number.isFinite(n) ? `${n >= 0 ? '+' : ''}${(n * 100).toFixed(1)}%` : '—')

/* 点击查值（触屏等价物）：格子的 hover title 只活在鼠标下；触屏点格子把读数
   放到色带下方固定位置（通用原则：移动端查值读数放固定位置、不做贴指针浮层，
   避免被手指遮挡）；再点同格收起。桌面 title 保留（就地提示更轻） */
const pickedHour = ref(null)
const picked = computed(() => cells.value.find((c) => c.hour === pickedHour.value) || null)

const bandLabel = computed(() => {
  const c = clock.value
  if (!c) return '全市场日内节律'
  const v = vMeta.value ? `，判读${vMeta.value.label}` : ''
  const p = peakLabel.value ? `，高位窗口${peakLabel.value}` : ''
  return `全市场 24 小时相对水位色带：数据时刻 ${dataClockLabel.value}${v}${p}`
})
</script>

<template>
  <section v-if="clock" class="block reveal" aria-label="全市场日内节律">
    <div class="block-h">
      <span class="bht">市场时钟</span><span class="bhline"></span>
      <span class="bhc">全市场日内节律 · {{ clock.counted }} 种弹聚合</span>
    </div>

    <!-- 判读行：数据时刻 + 大字判读 + 高位/低位窗口读数。换挡淡切（swap 全局类，
         MOTION.md §2.1）：数据时刻/判读档随快照推进跳变时淡入淡出而非瞬换——
         必须带 out-in（同四态根/脉搏 .nv 的换挡口径）：swap 的 leave 态不脱流，
         无 out-in 时新旧两卡同时在流内叠放 250ms、判读行高度瞬时翻倍且进场
         带多余 6px 位移。RM 下全局兜底瞬时，低频更新（小时级）不构成噪声 -->
    <div class="mc-read">
      <Transition name="swap" mode="out-in">
        <div :key="`${clock.dataHour ?? 'x'}-${clock.verdict ?? 'x'}`" class="mc-verdict" :class="vMeta?.cls">
          <span class="mc-clock">数据时刻 <b class="mono">{{ dataClockLabel || '—' }}</b></span>
          <template v-if="vMeta">
            <strong class="mc-word">{{ vMeta.label }}</strong>
            <span class="mc-note">{{ vMeta.note }}</span>
          </template>
        </div>
      </Transition>
      <p v-if="peakLabel" class="mc-windows">
        高位窗口 <b class="mono">{{ peakLabel }}</b><template v-if="clock.liftPct != null">（较最低小时 {{ pct(clock.liftPct) }}）</template><template v-if="lowHour != null"> · 最低小时 {{ pad2(lowHour) }}:00 前后</template>
      </p>
    </div>

    <!-- 24 格水位色带：绿=相对低位（买侧）、红=相对高位（卖侧），▼ 指针标数据时刻 -->
    <div class="mc-band" role="img" :aria-label="bandLabel">
      <div
        v-for="cell in cells" :key="cell.hour"
        class="mc-cell" :class="{ now: cell.now, pick: pickedHour === cell.hour }"
        :title="`${pad2(cell.hour)}:00 · 相对水位${cell.pos == null ? '无样本' : ` ${(cell.pos * 100).toFixed(0)}%`}${cell.now ? ' · 数据时刻' : ''}`"
        @click="pickedHour = pickedHour === cell.hour ? null : cell.hour"
      >
        <i class="mc-mark" aria-hidden="true">▼</i>
        <span class="mc-track">
          <i v-if="cell.heightPct != null" class="mc-bar" :class="cell.tone" :style="{ height: `${cell.heightPct}%` }"></i>
        </span>
        <span class="mc-h">{{ [0, 6, 12, 18].includes(cell.hour) ? pad2(cell.hour) : '' }}</span>
      </div>
    </div>

    <!-- 点击查值读数行（固定位置，不跟指针）：所选小时的精确读数；role=status 播报 -->
    <p v-if="picked" class="mc-pick" role="status">
      {{ pad2(picked.hour) }}:00 · 相对水位 <b>{{ picked.pos == null ? '无样本' : `${(picked.pos * 100).toFixed(0)}%` }}</b>{{ picked.now ? ' · 数据时刻' : '' }}<span class="mc-pick-x">（再点该格收起）</span>
    </p>

    <p class="mc-foot">
      按 {{ clock.counted }} 种子弹 7 天小时曲线逐弹归一（相对自身 7 天均价）后跨弹取中位聚合；「数据时刻」为快照曲线末点的墙钟时刻，不用设备本地时间。历史统计不代表未来。
    </p>
  </section>
</template>

<style scoped>
/* ---------- 判读行：左 verdict 卡（大字），右窗口读数 ---------- */
.mc-read {
  display: flex; flex-wrap: wrap; align-items: center; gap: var(--sp-3) var(--sp-6);
  margin-bottom: var(--sp-4);
}
.mc-verdict {
  display: flex; align-items: baseline; gap: 10px 14px; flex-wrap: wrap;
  padding: 10px 16px;
  border: 1px solid var(--line); border-radius: var(--radius);
  background: var(--card);
}
.mc-clock { font-family: var(--mono); font-size: var(--fs-2xs); color: var(--faint); }
.mc-clock b { color: var(--dim); font-variant-numeric: tabular-nums; }
.mc-word { font-size: var(--fs-xl); font-weight: 700; line-height: 1; letter-spacing: .06em; }
.mc-note { font-size: var(--fs-xs); color: var(--faint); }
/* 三档语义色由判读词文字承担（卡片不用左边条装饰） */
.mc-verdict.buy .mc-word { color: var(--ok); }
.mc-verdict.sell .mc-word { color: var(--danger); }
.mc-verdict.wait .mc-word { color: var(--dim); }
.mc-windows { font-size: var(--fs-sm); color: var(--dim); }
.mc-windows b { color: var(--tx-strong); font-variant-numeric: tabular-nums; }

/* ---------- 24 格色带 ---------- */
.mc-band {
  display: grid; grid-template-columns: repeat(24, 1fr); gap: 2px;
  background: var(--card); border: 1px solid var(--line); border-radius: var(--radius);
  padding: 6px 10px 8px;
}
.mc-cell { display: flex; flex-direction: column; align-items: center; gap: 2px; min-width: 0; cursor: pointer; }
/* 点击查值：选中格轨道点亮（与 .now 的 accent-dim 描边区分——实线全亮） */
.mc-cell.pick .mc-track { outline: 1px solid var(--accent); outline-offset: -1px; }
/* 指针槽（固定高度，仅数据时刻那格点亮，避免色带跳动） */
.mc-mark {
  height: 12px; font-style: normal; font-size: 10px; line-height: 12px;
  color: transparent;
}
.mc-cell.now .mc-mark { color: var(--accent); }
/* 水位轨道：等高竖槽，bar 从底部按位置升起 */
.mc-track {
  position: relative; display: flex; align-items: flex-end;
  width: 100%; height: 48px;
  background: var(--line2); border-radius: 2px; overflow: hidden;
}
.mc-bar { display: block; width: 100%; border-radius: 2px; }
.mc-bar.low {
  background: rgba(133, 181, 120, .55);
  background: color-mix(in srgb, var(--ok) 55%, transparent);
}
.mc-bar.mid { background: var(--faint); opacity: .45; }
.mc-bar.high {
  background: rgba(217, 106, 89, .6);
  background: color-mix(in srgb, var(--danger) 60%, transparent);
}
/* 数据时刻那格：轨道描边点亮（与 ▼ 指针同语义色） */
.mc-cell.now .mc-track { outline: 1px solid var(--accent-dim); outline-offset: -1px; }
.mc-h {
  height: 14px;
  font-family: var(--mono); font-size: var(--fs-micro); color: var(--faint);
  font-variant-numeric: tabular-nums;
}

/* 口径脚注与页尾 Playbook .pb-src 同层级同规格（fs-xs / faint / lh1.8 / 上距 sp-3）：
   字阶按 base.css 阶梯注释，fs-2xs 只承载标签类，整段统计口径说明属「辅助说明」
   档 fs-xs——11px 整句低于角色下限且两区块不一致 */
.mc-foot { font-size: var(--fs-xs); color: var(--faint); margin: var(--sp-3) 0 0; line-height: 1.8; }

/* 点击查值读数行（色带正下方固定位置）：mono 等宽防数字跳动，主读数 tx-strong 立权 */
.mc-pick {
  font-family: var(--mono); font-size: var(--fs-xs); color: var(--dim);
  margin: var(--sp-2) 0 0; font-variant-numeric: tabular-nums;
}
.mc-pick b { color: var(--tx-strong); }
.mc-pick-x { color: var(--faint); margin-left: 6px; }

/* 窄屏：格子随宽收缩（24 格在 320px 仍约 9px/格，hour 标注只留 0/12 两处） */
@media (max-width: 480px) {
  .mc-h { visibility: hidden; }
  .mc-cell:nth-child(1) .mc-h, .mc-cell:nth-child(13) .mc-h { visibility: visible; }
}
</style>
