<script setup>
// GuideBlocks.vue — 六个折叠列（工程师A）：legacy renderMap L769-777 的 blocks 区块，
// 内含 listBody（L399-413）/ bossBody（L414-423）/ srcBody（L418-423 工厂改名 src 段）的
// 声明式版本。折叠壳为全站统一的 CollapseCol（grid-template-rows 0fr→1fr，同构 legacy）。
// 地图页与打法页共用。
import { reactive } from 'vue'
import CollapseCol from '../../components/CollapseCol.vue'

const props = defineProps({
  map: { type: Object, required: true },
})

/* §6.2 默认展开策略：「简介」与「撤离点」两列默认 open，其余点击切换（互不联动） */
const openState = reactive({ intro: true, extractions: true, routes: false, boss: false, tips: false, source: false })
const toggle = (k) => { openState[k] = !openState[k] }

/* legacy splitLead（L392-397）：「：」前 ≤20 字时前缀加粗 */
function splitLead(t) {
  const i = t.indexOf('：')
  if (i > 0 && i <= 20) return { lead: t.slice(0, i + 1), rest: t.slice(i + 1) }
  return { lead: null, rest: t }
}

/* legacy bossBody（L414-423）：命中「危险区(提示)?：」且不在开头时拆出 danger 段 */
const bossSplit = (() => {
  const text = props.map.guide.boss || ''
  const m = text.match(/危险区(提示)?：/)
  if (m && m.index > 0) {
    return { before: text.slice(0, m.index), after: text.slice(m.index + m[0].length) }
  }
  return null
})()
</script>

<template>
  <div class="reveal guide-blocks">
    <CollapseCol :open="openState.intro" label="简介" @toggle="toggle('intro')">
      <div class="col-pad"><p class="intro-p">{{ map.guide.intro }}</p></div>
    </CollapseCol>

    <CollapseCol :open="openState.extractions" label="撤离点" :note="map.guide.extractions.length + ' 处'" @toggle="toggle('extractions')">
      <div class="col-pad">
        <div class="rows">
          <div v-for="(t, i) in map.guide.extractions" :key="i" class="row">
            <span class="row-dia"></span>
            <div class="row-body">
              <strong v-if="splitLead(t).lead" class="row-lead">{{ splitLead(t).lead }}</strong>{{ splitLead(t).rest }}
            </div>
          </div>
        </div>
      </div>
    </CollapseCol>

    <CollapseCol :open="openState.routes" label="资源路线" :note="map.guide.lootRoutes.length + ' 条'" @toggle="toggle('routes')">
      <div class="col-pad">
        <div class="rows">
          <div v-for="(t, i) in map.guide.lootRoutes" :key="i" class="row">
            <span class="row-num">{{ String(i + 1).padStart(2, '0') }}</span>
            <div class="row-body">
              <strong v-if="splitLead(t).lead" class="row-lead">{{ splitLead(t).lead }}</strong>{{ splitLead(t).rest }}
            </div>
          </div>
        </div>
      </div>
    </CollapseCol>

    <CollapseCol :open="openState.boss" label="Boss 情报" @toggle="toggle('boss')">
      <div class="col-pad boss-wrap">
        <template v-if="bossSplit">
          <p class="boss-p">{{ bossSplit.before }}</p>
          <div class="danger">
            <span class="danger-label">危险区</span>
            <p>{{ bossSplit.after }}</p>
          </div>
        </template>
        <p v-else class="boss-p">{{ map.guide.boss }}</p>
      </div>
    </CollapseCol>

    <CollapseCol :open="openState.tips" label="实战建议" :note="map.guide.tips.length + ' 条'" @toggle="toggle('tips')">
      <div class="col-pad">
        <div class="rows">
          <div v-for="(t, i) in map.guide.tips" :key="i" class="row">
            <span class="row-num">{{ String(i + 1).padStart(2, '0') }}</span>
            <div class="row-body">
              <strong v-if="splitLead(t).lead" class="row-lead">{{ splitLead(t).lead }}</strong>{{ splitLead(t).rest }}
            </div>
          </div>
        </div>
      </div>
    </CollapseCol>

    <CollapseCol :open="openState.source" label="资料来源与说明" note="来源 · 限制" @toggle="toggle('source')">
      <div class="col-pad src-body">
        <div class="kv-label">来源依据</div>
        <p class="src-p">{{ map.source || '—' }}</p>
        <div class="kv-label">已知限制</div>
        <p class="src-p">{{ map.caveat || '—' }}</p>
      </div>
    </CollapseCol>
  </div>
</template>

<style scoped>
/* legacy CSS L153-170（intro / rows / boss / source）+ col-pad，取值令牌化；.reveal 走全局 */
/* 折叠壳内容统一：左右 16px（--sp-4）、纵向 12px（--sp-3）（§4.1） */
.col-pad { padding: var(--sp-3) var(--sp-4); }
.intro-p { font-size: var(--fs-md); color: var(--dim); line-height: 1.9; padding-top: 4px; }
.rows { padding: 2px 8px 10px; }
.row { display: flex; gap: var(--sp-3); padding: 9px 9px; border-radius: var(--radius); transition: background var(--t-fast) var(--ease); }
.row:hover { background: var(--row-hover); }
.row + .row { border-top: 1px solid var(--line2); }
.row-num { flex: none; font-family: var(--mono); font-size: var(--fs-2xs); color: var(--accent); opacity: 0.85; padding-top: 4px; min-width: 20px; }
.row-dia { flex: none; width: 5px; height: 5px; background: var(--accent); transform: rotate(45deg); opacity: 0.7; margin-top: 9px; }
.row-body { font-size: var(--fs-sm); color: var(--dim); line-height: 1.8; min-width: 0; }
.row-lead { color: var(--tx-strong); font-weight: 600; }
.boss-wrap { padding: var(--sp-3) var(--sp-4); }
.boss-p { font-size: var(--fs-sm); color: var(--dim); line-height: 1.9; padding-top: 4px; }
/* 危险语义全站唯一色 --danger（§2.3）：左边条 + 8% 派生底（color-mix，rgba 行兜底），不再用主色表达危险 */
.danger {
  margin-top: 14px;
  padding: 11px 14px;
  border-left: 2px solid var(--danger);
  background: rgba(217, 106, 89, .08); /* 兜底：不支持 color-mix 的旧引擎（真值同 --lv6） */
  background: color-mix(in srgb, var(--danger) 8%, transparent);
  border-radius: 0 var(--radius) var(--radius) 0;
}
.danger-label { display: block; font-family: var(--mono); font-size: var(--fs-micro); letter-spacing: .28em; color: var(--danger); margin-bottom: 6px; }
.danger p { font-size: var(--fs-sm); color: var(--dim); line-height: 1.8; }
.src-body { padding: var(--sp-3) var(--sp-4); }
.src-p { font-size: var(--fs-xs); color: var(--faint); line-height: 1.85; margin-bottom: 14px; }
.src-p:last-child { margin-bottom: 0; }
.kv-label {
  font-family: var(--mono);
  font-size: var(--fs-micro);
  letter-spacing: .24em;
  color: var(--accent);
  margin-bottom: 8px;
}
@media (prefers-reduced-motion: reduce) {
  .row { transition: none; }
}
</style>
