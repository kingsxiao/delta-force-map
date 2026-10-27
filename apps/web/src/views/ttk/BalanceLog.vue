<script setup>
/* ============================================================
   BalanceLog — 版本平衡调整时间线
   数据：public/data/balance-updates.json（npm run dfttk:snapshot 一次性
   镜像 DFTTK 公告静态 JSON 后自托管；前端零外部请求）。
   ============================================================ */
import { onMounted, ref } from 'vue'
import CollapseCol from '../../components/CollapseCol.vue'

const entries = ref(null)
const failed = ref(false)
const open = ref(false)
const note = ref('镜像快照')

onMounted(async () => {
  try {
    // BASE_URL 前缀与 TtkView 行情快照同口径：子路径静态托管（BASE_URL 非 '/'）下不再 404
    const res = await fetch(`${import.meta.env.BASE_URL}data/balance-updates.json`)
    if (!res.ok) throw new Error('HTTP ' + res.status)
    const data = await res.json()
    entries.value = Array.isArray(data.entries) ? data.entries : []
    note.value = '镜像 ' + String(data.fetchedAt || '').slice(0, 10) + ' · ' + entries.value.length + ' 条'
  } catch (e) {
    failed.value = true
    note.value = '快照缺失'
  }
})
</script>

<template>
  <div class="balog">
    <CollapseCol :open="open" label="烽火地带更新记录" :note="note" @toggle="open = !open">
      <!-- 四态互切（MOTION §4 / §3-H）：mode out-in 先收旧态再进新态，全部走全局 swap 淡入淡出。
           loading 骨架贴近期刊真实布局：行壳直接复用 .bal-list/.bal-item 栅格（日期列同宽对位），
           右列 标题条 + 两行摘要条；failed/empty 保留原 .bal-empty 文案（口径说明不动） -->
      <Transition name="swap" mode="out-in">
        <p v-if="failed" key="failed" class="bal-empty">
          本地快照缺失：在仓库根目录运行 <code>npm run dfttk:snapshot</code> 生成
          <code>apps/web/public/data/balance-updates.json</code>（一次性抓取后自托管，前端不再请求外部站点）。
        </p>
        <div v-else-if="!entries" key="loading" class="bal-list" role="status" aria-label="正在加载">
          <div v-for="n in 3" :key="n" class="bal-item" aria-hidden="true">
            <i class="sk sk-line" style="--w: 66px"></i>
            <div class="bal-sk-body">
              <i class="sk sk-line" style="--w: 44%"></i>
              <i class="sk sk-line" style="--w: 78%"></i>
              <i class="sk sk-line" style="--w: 60%"></i>
            </div>
          </div>
        </div>
        <!-- 加载中与空快照分开（原口径保留）：fetch 未返回前若落在「快照为空 · 稍后重跑」上，会误导用户去重跑脚本 -->
        <ol v-else-if="entries.length" key="list" class="bal-list">
          <li v-for="e in entries" :key="e.id" class="bal-item">
            <span class="bal-date">{{ e.date }}</span>
            <div class="bal-body">
              <h4 class="bal-title">{{ e.title }}</h4>
              <p v-if="e.summary" class="bal-sum">{{ e.summary }}</p>
              <ul class="bal-points">
                <li v-for="(it, i) in e.items" :key="i">
                  <strong v-if="it.title">{{ it.title }}</strong><span v-if="it.text">{{ it.title ? ' — ' : '' }}{{ it.text }}</span>
                </li>
              </ul>
            </div>
          </li>
        </ol>
        <p v-else key="empty" class="bal-empty">快照为空：暂无带明细的公告条目，稍后重跑 <code>npm run dfttk:snapshot</code>。</p>
      </Transition>
    </CollapseCol>
  </div>
</template>

<style scoped>
.balog { margin-bottom: 14px; }
.bal-list {
  list-style: none;
  margin: 0;
  padding: var(--sp-2) var(--sp-4) var(--sp-3);
}
.bal-item {
  display: grid;
  grid-template-columns: 92px minmax(0, 1fr);
  gap: var(--sp-4);
  padding: 12px 0;
  border-bottom: 1px solid var(--line2);
}
.bal-item:last-child { border-bottom: 0; }
/* 骨架行右列：标题条 + 两行摘要条的纵向排布（行壳复用 .bal-item 栅格，见模板注释）；
   条块底色与扫光全在全局 .sk 基块上，这里只管几何 */
.bal-sk-body {
  display: flex;
  flex-direction: column;
  gap: 8px;
  min-width: 0;
}
.bal-date {
  font-family: var(--mono);
  font-size: var(--fs-xs);
  color: var(--accent);
  letter-spacing: .06em;
  padding-top: 2px;
  font-variant-numeric: tabular-nums;
}
.bal-title {
  font-size: var(--fs-sm);
  font-weight: 700;
  color: var(--tx-strong);
}
.bal-sum {
  margin-top: 2px;
  font-size: var(--fs-xs);
  color: var(--dim);
  line-height: 1.7;
}
.bal-points {
  list-style: none;
  margin: 6px 0 0;
  display: flex;
  flex-direction: column;
  gap: 4px;
}
.bal-points li {
  position: relative;
  padding-left: 13px;
  font-size: var(--fs-xs);
  color: var(--dim);
  line-height: 1.7;
}
.bal-points li::before {
  content: "";
  position: absolute;
  left: 0;
  top: 9px;
  width: 4px;
  height: 4px;
  background: var(--accent-dim);
  transform: rotate(45deg);
}
.bal-points strong { color: var(--tx); font-weight: 600; }
.bal-empty {
  padding: var(--sp-2) var(--sp-4);
  font-size: var(--fs-xs);
  color: var(--faint);
  line-height: 1.8;
}
.bal-empty code {
  font-family: var(--mono);
  color: var(--dim);
  background: var(--bg2);
  border: 1px solid var(--line2);
  border-radius: var(--radius-sm);
  padding: 1px 5px;
}
@media (max-width: 680px) {
  .bal-item {
    grid-template-columns: 1fr;
    gap: 4px;
  }
  .bal-date { padding-top: 0; }
}
</style>
