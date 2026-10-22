#!/usr/bin/env node
/* ============================================================
   snapshot-balance.mjs — DFTTK 公告静态镜像（一次性快照）
   背景：dfttk.com 的枪械/公告数据全部是无鉴权的静态 JSON
   （/data/announcements.json、/data/v3/**），并非动态接口。
   为避免对它产生持续请求流量（风控顾虑），本脚本只在赛季更新后
   手动跑一次，把「带明细的公告条目」落盘自托管：
     apps/web/public/data/balance-updates.json
   前端运行时只读本地静态文件，零外部请求。
   用法：npm run dfttk:snapshot
   ============================================================ */
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const SRC = 'https://dfttk.com/data/announcements.json'
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const OUT = resolve(ROOT, 'apps/web/public/data/balance-updates.json')
const NL = String.fromCharCode(10)

const res = await fetch(SRC, { headers: { accept: 'application/json' } })
if (!res.ok) throw new Error('fetch ' + SRC + ' -> HTTP ' + res.status)
const data = await res.json()

const entries = (Array.isArray(data.entries) ? data.entries : [])
  .filter((e) => Array.isArray(e.items) && e.items.length > 0)
  .sort((a, b) => (a.date < b.date ? 1 : -1))
  .map((e) => ({
    id: e.id,
    date: e.date,
    title: e.title,
    summary: e.summary || '',
    items: e.items.map((it) => ({ title: it.title || '', text: it.text || '' })),
  }))

const out = {
  // 由 npm run dfttk:snapshot 生成，请勿手改；来源为 DFTTK 公告静态 JSON
  // （其自述数据来自客户端抓包与社区校验，可能与游戏内数值有出入）。
  source: SRC,
  fetchedAt: new Date().toISOString(),
  count: entries.length,
  entries,
}
mkdirSync(dirname(OUT), { recursive: true })
writeFileSync(OUT, JSON.stringify(out, null, 2) + NL)
console.log('OK ' + entries.length + ' entries -> ' + OUT + ' (fetched ' + out.fetchedAt + ')')
