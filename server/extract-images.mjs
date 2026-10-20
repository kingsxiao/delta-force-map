// extract-images.mjs — 一次性抽取脚本（工程师A，跑完即弃）
// 遍历 legacy/index.html map-data 的 fig[].src（base64 JPEG），落盘 public/figs/<slug>-{0,1}.jpg，
// 解析 JPEG 尺寸，并与 assets/<slug>/ 顶层 jpg 做 sha1 对照（assets 只读，仅对照不引用）。
import { createInterface } from 'node:readline';
import { createReadStream, mkdirSync, writeFileSync, readdirSync, readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';

const ROOT = path.resolve(import.meta.dirname, '..');
const LEGACY = path.join(ROOT, 'legacy', 'index.html');
const OUT = path.join(ROOT, 'apps', 'web', 'public', 'figs');
const ASSETS = path.join(ROOT, 'assets');

const PREFIX = '<script id="map-data" type="application/json">';
const SUFFIX = '</script>';

let raw = null;
const rl = createInterface({ input: createReadStream(LEGACY, 'utf8') });
for await (const line of rl) {
  if (line.startsWith(PREFIX)) {
    raw = line.slice(PREFIX.length);
    if (raw.endsWith(SUFFIX)) raw = raw.slice(0, raw.length - SUFFIX.length);
    break;
  }
}
rl.close();
if (raw == null) throw new Error('map-data script tag not found');

function jpegSize(buf) {
  if (buf[0] !== 0xff || buf[1] !== 0xd8) return null;
  let o = 2;
  while (o < buf.length - 9) {
    if (buf[o] !== 0xff) { o++; continue; }
    const marker = buf[o + 1];
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { o += 2; continue; }
    if (marker === 0xda) break; // start of scan
    const len = buf.readUInt16BE(o + 2);
    if (marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc) {
      return { h: buf.readUInt16BE(o + 5), w: buf.readUInt16BE(o + 7) };
    }
    o += 2 + len;
  }
  return null;
}

const DATA = JSON.parse(raw);
mkdirSync(OUT, { recursive: true });

// assets/<slug>/ 顶层 jpg 的 sha1 索引（不动 assets，仅读）
const assetHashes = new Map(); // hash -> relative path
for (const slug of DATA.map((m) => m.slug)) {
  const dir = path.join(ASSETS, slug);
  let files = [];
  try { files = readdirSync(dir).filter((f) => f.endsWith('.jpg')); } catch { /* 无目录 */ }
  for (const f of files) {
    const buf = readFileSync(path.join(dir, f));
    assetHashes.set(createHash('sha1').update(buf).digest('hex'), `assets/${slug}/${f}`);
  }
}

let totalBytes = 0;
const rows = [];
for (const m of DATA) {
  m.fig.forEach((f, i) => {
    const b64 = f.src.slice(f.src.indexOf(',') + 1);
    const buf = Buffer.from(b64, 'base64');
    const file = `${m.slug}-${i}.jpg`;
    writeFileSync(path.join(OUT, file), buf);
    totalBytes += buf.length;
    const dim = jpegSize(buf);
    const hash = createHash('sha1').update(buf).digest('hex');
    const match = assetHashes.get(hash) || '—（无字节级一致的 assets 原图）';
    rows.push(`${file.padEnd(26)} ${(buf.length / 1024).toFixed(0).padStart(6)}KB  ${dim ? dim.w + 'x' + dim.h : '?'}  ↔ ${match}`);
  });
}
console.log(rows.join('\n'));
console.log(`OK: 12 figs -> public/figs/, total ${(totalBytes / 1048576).toFixed(2)}MB`);
