// extract-data.mjs — 一次性抽取脚本（工程师A，跑完即弃）
// 从 legacy/index.html（11MB，单行巨型 JSON 位于 L334）流式抽出地图数据：
//   - src/data/maps/<slug>.json     { map, mode, slug, loot, guide, source, caveat }
//   - src/data/hotspots/<slug>.json hs 数组原样透传（含 gs / gl 字段）
// 全程 readline 流式处理，绝不整读文件。
import { createInterface } from 'node:readline';
import { createReadStream, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
const LEGACY = path.join(ROOT, 'legacy', 'index.html');
const OUT_MAPS = path.join(ROOT, 'src', 'data', 'maps');
const OUT_HS = path.join(ROOT, 'src', 'data', 'hotspots');

const PREFIX = '<script id="map-data" type="application/json">';
const SUFFIX = '</script>';

let raw = null;
let lineNo = 0;
const rl = createInterface({ input: createReadStream(LEGACY, 'utf8') });
for await (const line of rl) {
  lineNo++;
  if (line.startsWith(PREFIX)) {
    raw = line.slice(PREFIX.length);
    if (raw.endsWith(SUFFIX)) raw = raw.slice(0, raw.length - SUFFIX.length);
    break;
  }
}
rl.close();
if (raw == null) throw new Error(`map-data script tag not found (scanned ${lineNo} lines)`);
console.log(`map-data found at line ${lineNo}, json ${raw.length} bytes`);

const DATA = JSON.parse(raw);

/* ---------- 断言 ---------- */
function assert(cond, msg) {
  if (!cond) throw new Error('ASSERT FAIL: ' + msg);
}
assert(Array.isArray(DATA), 'top level is array');
assert(DATA.length === 6, `exactly 6 maps, got ${DATA.length}`);

const EXPECT_MAP_KEYS = ['map', 'mode', 'slug', 'loot', 'guide', 'source', 'caveat', 'fig', 'hs'];
const EXPECT_GUIDE_KEYS = ['intro', 'spawns', 'extractions', 'lootRoutes', 'tips', 'boss'];
const slugs = new Set();
let hsTotal = 0;
const gsStats = { nullByType: {}, withGs: 0 };

for (const m of DATA) {
  const keys = Object.keys(m);
  assert(
    EXPECT_MAP_KEYS.every((k) => keys.includes(k)),
    `map ${m.slug}: missing keys [${EXPECT_MAP_KEYS.filter((k) => !keys.includes(k))}] (got ${keys})`,
  );
  assert(slugs.has(m.slug) === false, `duplicate slug ${m.slug}`);
  slugs.add(m.slug);

  assert(Array.isArray(m.loot) && m.loot.length === 8, `${m.slug}: loot length ${m.loot?.length} !== 8`);
  for (const l of m.loot) assert(typeof l.spot === 'string' && typeof l.items === 'string' && typeof l.rate === 'string', `${m.slug}: loot entry keys ${Object.keys(l)}`);

  assert(m.fig && m.fig.length === 2, `${m.slug}: fig length ${m.fig?.length} !== 2`);
  for (const f of m.fig) {
    assert(typeof f.label === 'string' && typeof f.cap === 'string' && 'hs' in f && typeof f.src === 'string' && f.src.startsWith('data:image/jpeg;base64,'), `${m.slug}: fig entry shape ${Object.keys(f)}`);
  }

  const g = m.guide;
  assert(g && EXPECT_GUIDE_KEYS.every((k) => k in g), `${m.slug}: guide keys ${g && Object.keys(g)}`);
  assert(Array.isArray(g.spawns) && g.spawns.length > 0, `${m.slug}: spawns empty`);
  for (const s of g.spawns) assert(typeof s.name === 'string' && typeof s.plan === 'string' && typeof s.watchOut === 'string' && typeof s.angles === 'string' && typeof s.smoke === 'string', `${m.slug}: spawn keys ${Object.keys(s)}`);
  for (const k of ['extractions', 'lootRoutes', 'tips']) assert(Array.isArray(g[k]), `${m.slug}: guide.${k} not array`);
  assert(typeof g.boss === 'string' && typeof g.intro === 'string', `${m.slug}: intro/boss not string`);

  assert(Array.isArray(m.hs) && m.hs.length > 0, `${m.slug}: hs empty`);
  for (const h of m.hs) {
    hsTotal++;
    assert(typeof h.name === 'string' && typeof h.type === 'string' && typeof h.x === 'number' && typeof h.y === 'number' && typeof h.note === 'string', `${m.slug}: hs entry keys ${Object.keys(h)}`);
    assert(['spawn', 'extract', 'boss', 'loot'].includes(h.type), `${m.slug}: hs type ${h.type}`);
    if (h.gs != null) {
      gsStats.withGs++;
      assert(h.type === 'spawn', `${m.slug}: hs "${h.name}" has gs=${h.gs} but type=${h.type}（规则：gs!=null ⇒ type==='spawn'）`);
      assert(Number.isInteger(h.gs) && h.gs >= 0 && h.gs < g.spawns.length, `${m.slug}: hs "${h.name}" gs=${h.gs} out of range (spawns ${g.spawns.length})`);
    } else {
      gsStats.nullByType[h.type] = (gsStats.nullByType[h.type] || 0) + 1;
    }
    if (h.gl != null) {
      assert(h.type === 'loot', `${m.slug}: hs "${h.name}" has gl=${h.gl} but type=${h.type}`);
      assert(Number.isInteger(h.gl) && h.gl >= 0 && h.gl < m.loot.length, `${m.slug}: hs "${h.name}" gl=${h.gl} out of range (loot ${m.loot.length})`);
    }
  }
}
assert(hsTotal === 169, `total hs ${hsTotal} !== 169`);

/* ---------- 落盘 ---------- */
mkdirSync(OUT_MAPS, { recursive: true });
mkdirSync(OUT_HS, { recursive: true });
for (const m of DATA) {
  const meta = { map: m.map, mode: m.mode, slug: m.slug, loot: m.loot, guide: m.guide, source: m.source, caveat: m.caveat };
  writeFileSync(path.join(OUT_MAPS, `${m.slug}.json`), JSON.stringify(meta, null, 2) + '\n');
  writeFileSync(path.join(OUT_HS, `${m.slug}.json`), JSON.stringify(m.hs, null, 1) + '\n');
  console.log(`${m.slug.padEnd(14)} map=${m.map} mode=${m.mode} loot=${m.loot.length} fig=${m.fig.length} hs=${m.hs.length} spawns=${m.guide.spawns.length} figBytes=${m.fig.map((f) => Math.round((f.src.length * 3) / 4)).join('/')}`);
}
console.log(`OK: 6 maps written, hs total=${hsTotal}, withGs=${gsStats.withGs}, gs-null by type=${JSON.stringify(gsStats.nullByType)}`);
