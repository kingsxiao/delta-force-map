#!/usr/bin/env node
/**
 * 契约校验门禁 — shared/fixtures/*.json 与 apps/web/public/ 三份静态快照
 * 逐份对照 shared/schema/ 的 JSON Schema 校验；任一失败即非零退出。
 *
 * 零依赖：自带最小 JSON Schema（draft 2020-12 子集）校验器，支持
 *   $ref（内部 #/$defs 指针 + 同目录 schema 文件交叉引用，如 radar → market）、
 *   $defs、type（含类型数组与 null）、enum / const、required / properties /
 *   additionalProperties、items / prefixItems、minItems / maxItems、
 *   minLength / maxLength / pattern、minimum / maximum / exclusiveMinimum /
 *   exclusiveMaximum / multipleOf、allOf / anyOf / oneOf、if / then / else、
 *   format（date-time）。
 * 断言关键字不在支持集内时直接判失败（而不是静默跳过），防止防线漏风；
 * 两个简化：$id 不参与引用解析（跨文件引用一律按同目录文件名解析），
 * format 仅实现 date-time（其余 format 值视为不支持）。
 *
 * 用法：node server/contract-check.mjs（npm run contract:check；CI 门禁步）
 */
import { readFileSync, readdirSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const rel = (p) => join(ROOT, p)

/* ---------- 契约清单：fixtures 全量 + 线上三份静态快照 ---------- */

const CONTRACTS = [
  { doc: 'shared/fixtures/market-sample.json', schema: 'shared/schema/market-snapshot.schema.json' },
  { doc: 'shared/fixtures/radar-sample.json', schema: 'shared/schema/radar-snapshot.schema.json' },
  { doc: 'shared/fixtures/craft-sample.json', schema: 'shared/schema/craft-snapshot.schema.json' },
  { doc: 'apps/web/public/ammo/market.json', schema: 'shared/schema/market-snapshot.schema.json' },
  { doc: 'apps/web/public/market/radar.json', schema: 'shared/schema/radar-snapshot.schema.json' },
  { doc: 'apps/web/public/craft/craft.json', schema: 'shared/schema/craft-snapshot.schema.json' },
]

const FIXTURE_DIR = rel('shared/fixtures')

/* ---------- schema 加载与 $ref 解析 ---------- */

const schemaCache = new Map()

function loadSchema(absPath) {
  if (schemaCache.has(absPath)) return schemaCache.get(absPath)
  let schema
  try {
    schema = JSON.parse(readFileSync(absPath, 'utf8'))
  } catch (e) {
    throw new Error(`schema 无法加载/解析 ${absPath}：${e.message}`)
  }
  schemaCache.set(absPath, schema)
  return schema
}

/** JSON Pointer（RFC 6901）取值；根指针 '#' 返回整文档 */
function pointerLookup(doc, pointer) {
  if (pointer === '' || pointer === '/') return doc
  let node = doc
  for (const raw of pointer.split('/').slice(1)) {
    const seg = raw.replaceAll('~1', '/').replaceAll('~0', '~')
    if (node == null || !(seg in Object(node))) {
      throw new Error(`JSON Pointer「${pointer}」在 schema 中不存在（段「${seg}」落空）`)
    }
    node = node[seg]
  }
  return node
}

/**
 * 解析 $ref：'#…' 指当前 schema 文档内指针；
 * 'xxx.schema.json#…' 按当前 schema 同目录文件解析（本仓库跨 schema 引用形态）。
 * 返回 { node, docPath }——跨文件引用后，目标内部再出现的 '#…' 应按目标文档
 * 解析（$ref 的基准是子 schema 物理所在的文档，radar→market 交叉引用即此形态）。
 */
function resolveRef(ref, fromAbsPath) {
  const hashIdx = ref.indexOf('#')
  const filePart = hashIdx === -1 ? ref : ref.slice(0, hashIdx)
  const pointer = hashIdx === -1 ? '' : ref.slice(hashIdx + 1)
  if (filePart === '') return { node: pointerLookup(loadSchema(fromAbsPath), pointer), docPath: fromAbsPath }
  const docPath = join(dirname(fromAbsPath), filePart)
  return { node: pointerLookup(loadSchema(docPath), pointer), docPath }
}

/* ---------- 最小校验器 ---------- */

const ANNOTATION_KEYS = new Set([
  '$schema', '$id', '$comment', 'title', 'description', 'default', 'examples',
  'deprecated', 'readOnly', 'writeOnly',
])
const SUPPORTED_KEYS = new Set([
  '$ref', '$defs', 'type', 'enum', 'const', 'required', 'properties',
  'additionalProperties', 'items', 'prefixItems', 'minItems', 'maxItems',
  'minLength', 'maxLength', 'pattern', 'minimum', 'maximum',
  'exclusiveMinimum', 'exclusiveMaximum', 'multipleOf',
  'allOf', 'anyOf', 'oneOf', 'if', 'then', 'else', 'format',
  ...ANNOTATION_KEYS,
])

const TYPE_NAMES = ['object', 'array', 'string', 'number', 'integer', 'boolean', 'null']

const typeOf = (v) => {
  if (v === null) return 'null'
  if (Array.isArray(v)) return 'array'
  if (Number.isInteger(v)) return 'integer'
  return typeof v
}

function matchesType(v, type) {
  if (type === 'integer') return typeof v === 'number' && Number.isInteger(v)
  if (type === 'number') return typeof v === 'number'
  if (type === 'null') return v === null
  if (type === 'array') return Array.isArray(v)
  if (type === 'object') return typeof v === 'object' && v !== null && !Array.isArray(v)
  return typeof v === type // string / boolean
}

function deepEqual(a, b) {
  if (a === b) return true
  if (typeof a !== typeof b || a === null || b === null) return false
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
    return a.every((x, i) => deepEqual(x, b[i]))
  }
  if (typeof a !== 'object') return false
  const ka = Object.keys(a)
  const kb = Object.keys(b)
  if (ka.length !== kb.length) return false
  return ka.every((k) => deepEqual(a[k], b[k]))
}

const JSON_STR = (v) => JSON.stringify(v)

/** format 断言（仅对 string 实例生效；draft 2020-12 里 format 默认是注解，这里主动升格为断言） */
function checkFormat(value, format) {
  if (typeof value !== 'string') return null // 非字符串不归 format 管
  if (format === 'date-time') {
    // ISO-8601 日期时间：日期 + [Tt] + 时分秒（可带小数）+ 时区（Z 或 ±hh:mm）
    const ok = /^\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})$/.test(value)
      && !Number.isNaN(Date.parse(value))
    return ok ? null : `应为 ISO-8601 日期时间（date-time），实为 ${JSON_STR(value)}`
  }
  return `校验器不支持 format「${format}」（防静默漏检，视为失败）`
}

/**
 * 校验 value 符合 schema；错误 push 进 errors，元素形如 { path, message }。
 * @param {object} schema 当前（子）schema
 * @param {unknown} value 待校验值
 * @param {string} path JSON Pointer 路径（根为空串）
 * @param {Array} errors 累积错误列表
 * @param {string} schemaAbsPath 当前 schema 所在文件（供跨文件 $ref 解析）
 */
function validate(schema, value, path, errors, schemaAbsPath) {
  if (schema === false) { errors.push({ path, message: 'schema 为 false：任何值都不允许' }); return }
  if (schema === true || schema == null) return // 恒真
  if (typeof schema !== 'object' || Array.isArray(schema)) {
    errors.push({ path, message: `schema 节点非法（应为对象）：${JSON_STR(schema).slice(0, 60)}` })
    return
  }

  // 未知断言关键字 → 直接失败（防线不许有静默盲区）
  for (const key of Object.keys(schema)) {
    if (!SUPPORTED_KEYS.has(key)) {
      errors.push({ path, message: `schema 用了校验器不支持的关键字「${key}」（防静默漏检，视为失败）` })
    }
  }

  if ('$ref' in schema) {
    let resolved
    try {
      resolved = resolveRef(schema.$ref, schemaAbsPath)
    } catch (e) {
      errors.push({ path, message: `$ref「${schema.$ref}」解析失败：${e.message}` })
      return
    }
    validate(resolved.node, value, path, errors, resolved.docPath)
    // $ref 兄弟关键字按 2020-12 应一并生效，本仓库 schema 未用到，继续走完即可
  }

  // type
  if ('type' in schema) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type]
    for (const t of types) {
      if (!TYPE_NAMES.includes(t)) errors.push({ path, message: `schema type 非法：「${t}」` })
    }
    if (!types.some((t) => matchesType(value, t))) {
      errors.push({
        path,
        message: `应为 ${types.length > 1 ? `${types.join(' | ')}` : types[0]}，实为 ${typeOf(value)}（${JSON_STR(value)?.slice(0, 60) ?? 'undefined'}）`,
      })
    }
  }

  // enum / const
  if ('enum' in schema && !schema.enum.some((e) => deepEqual(e, value))) {
    errors.push({ path, message: `不在 enum 内：${JSON_STR(schema.enum).slice(0, 80)}` })
  }
  if ('const' in schema && !deepEqual(schema.const, value)) {
    errors.push({ path, message: `应为 const ${JSON_STR(schema.const)}，实为 ${JSON_STR(value)?.slice(0, 60)}` })
  }

  const isObject = typeof value === 'object' && value !== null && !Array.isArray(value)
  const isArray = Array.isArray(value)

  // 数值
  if (typeof value === 'number') {
    if ('minimum' in schema && value < schema.minimum) {
      errors.push({ path, message: `${value} < minimum ${schema.minimum}` })
    }
    if ('maximum' in schema && value > schema.maximum) {
      errors.push({ path, message: `${value} > maximum ${schema.maximum}` })
    }
    if ('exclusiveMinimum' in schema && value <= schema.exclusiveMinimum) {
      errors.push({ path, message: `${value} ≤ exclusiveMinimum ${schema.exclusiveMinimum}` })
    }
    if ('exclusiveMaximum' in schema && value >= schema.exclusiveMaximum) {
      errors.push({ path, message: `${value} ≥ exclusiveMaximum ${schema.exclusiveMaximum}` })
    }
    if ('multipleOf' in schema) {
      const q = value / schema.multipleOf
      if (!Number.isInteger(q) && Math.abs(q - Math.round(q)) > 1e-9) {
        errors.push({ path, message: `${value} 不是 ${schema.multipleOf} 的倍数` })
      }
    }
  }

  // 字符串
  if (typeof value === 'string') {
    const len = [...value].length
    if ('minLength' in schema && len < schema.minLength) {
      errors.push({ path, message: `长度 ${len} < minLength ${schema.minLength}` })
    }
    if ('maxLength' in schema && len > schema.maxLength) {
      errors.push({ path, message: `长度 ${len} > maxLength ${schema.maxLength}` })
    }
    if ('pattern' in schema && !new RegExp(schema.pattern, 'u').test(value)) {
      errors.push({ path, message: `不匹配 pattern ${schema.pattern}：${JSON_STR(value).slice(0, 60)}` })
    }
    if ('format' in schema) {
      const msg = checkFormat(value, schema.format)
      if (msg) errors.push({ path, message: msg })
    }
  } else if ('format' in schema && value !== null) {
    // 非字符串类型带 format：date-time 等只对 string 定义，其余类型记录为不支持
    errors.push({ path, message: `校验器不支持对 ${typeOf(value)} 断言 format「${schema.format}」` })
  }

  // 数组
  if (isArray) {
    const prefix = schema.prefixItems ?? []
    if ('minItems' in schema && value.length < schema.minItems) {
      errors.push({ path, message: `元素数 ${value.length} < minItems ${schema.minItems}` })
    }
    if ('maxItems' in schema && value.length > schema.maxItems) {
      errors.push({ path, message: `元素数 ${value.length} > maxItems ${schema.maxItems}` })
    }
    value.forEach((el, i) => {
      let sub = null
      if (i < prefix.length) sub = prefix[i]
      else if ('items' in schema) sub = schema.items
      if (sub === false) errors.push({ path: `${path}/${i}`, message: 'prefixItems 之外不允许再有多余元素（items: false）' })
      else if (sub != null) validate(sub, el, `${path}/${i}`, errors, schemaAbsPath)
    })
  }

  // 对象
  if (isObject) {
    for (const key of schema.required ?? []) {
      if (!(key in value)) errors.push({ path, message: `缺少必填字段「${key}」` })
    }
    const props = schema.properties ?? {}
    for (const [key, sub] of Object.entries(props)) {
      if (key in value) validate(sub, value[key], `${path}/${key}`, errors, schemaAbsPath)
    }
    if ('additionalProperties' in schema) {
      const extra = Object.keys(value).filter((k) => !(k in props))
      if (schema.additionalProperties === false) {
        for (const k of extra) errors.push({ path: `${path}/${k}`, message: '多余字段（additionalProperties: false）' })
      } else if (schema.additionalProperties && typeof schema.additionalProperties === 'object') {
        for (const k of extra) validate(schema.additionalProperties, value[k], `${path}/${k}`, errors, schemaAbsPath)
      }
    }
  }

  // 组合 / 条件
  for (const sub of schema.allOf ?? []) validate(sub, value, path, errors, schemaAbsPath)
  if (schema.anyOf) {
    let matched = false
    let firstFailure = null
    for (const sub of schema.anyOf) {
      const tmp = []
      validate(sub, value, path, tmp, schemaAbsPath)
      if (!tmp.length) { matched = true; break }
      firstFailure ??= tmp[0]
    }
    if (!matched) {
      errors.push({ path, message: `anyOf 全部分支不满足（首条：${firstFailure?.message}）` })
    }
  }
  if (schema.oneOf) {
    const passed = schema.oneOf.filter((sub) => {
      const tmp = []
      validate(sub, value, path, tmp, schemaAbsPath)
      return tmp.length === 0
    })
    if (passed.length !== 1) {
      errors.push({ path, message: `oneOf 应恰好命中 1 个分支，实命中 ${passed.length} 个` })
    }
  }
  if ('if' in schema) {
    const tmp = []
    validate(schema.if, value, path, tmp, schemaAbsPath)
    const branch = tmp.length === 0 ? schema.then : schema.else
    if (branch != null) validate(branch, value, path, errors, schemaAbsPath)
  }
}

/* ---------- 主流程 ---------- */

let failed = 0
const report = []

for (const { doc, schema } of CONTRACTS) {
  const errors = []
  try {
    const document = JSON.parse(readFileSync(rel(doc), 'utf8'))
    validate(loadSchema(rel(schema)), document, '', errors, rel(schema))
  } catch (e) {
    errors.push({ path: '', message: e.message })
  }
  if (errors.length) {
    failed++
    report.push(`✗ ${doc}（对照 ${schema}）`)
    const MAX_SHOW = 20 // 长数组逐元素同类报错只展示前 20 条，防 CI 日志爆炸
    for (const { path, message } of errors.slice(0, MAX_SHOW)) {
      report.push(`    ${path === '' ? '(根)' : path}：${message}`)
    }
    if (errors.length > MAX_SHOW) {
      report.push(`    …另有 ${errors.length - MAX_SHOW} 条同类错误未展示`)
    }
  } else {
    report.push(`✓ ${doc}（对照 ${schema}）`)
  }
}

// 防线自查：fixtures 目录里新增的样本必须登记进契约清单，否则门禁报红
const mapped = new Set(CONTRACTS.map((c) => c.doc))
for (const name of readdirSync(FIXTURE_DIR).filter((n) => n.endsWith('.json'))) {
  const p = `shared/fixtures/${name}`
  if (!mapped.has(p)) {
    failed++
    report.push(`✗ ${p}：未在 server/contract-check.mjs 契约清单登记对应 schema（新增 fixture 必须接上防线）`)
  }
}

console.log(report.join('\n'))
if (failed) {
  console.log(`\n契约校验失败：${failed} 份`)
  process.exit(1)
}
console.log('\n契约校验通过：fixtures + 静态快照 共 6 份全部符合 schema')
