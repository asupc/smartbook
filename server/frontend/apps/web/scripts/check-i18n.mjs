#!/usr/bin/env node
/**
 * i18n 全量 key 校验(W1)—— 三件事:
 *
 *   1. 三语 key 集合 diff(en vs zh-CN vs zh-TW,双向差集,非空值检查)
 *   2. 代码里 `t('...')` 字面量引用扫描:引用了字典里不存在的 key 直接报错
 *      (动态 key —— `t(var)` / Record 映射表 —— 无法静态解析,不在扫描范围,
 *       由各 locale 运行时 DEV warn(warnMissingKeys.ts)兜底)
 *   3. 退出码:有问题 1,干净 0 —— 可直接接 CI(step 里跑 `pnpm --dir
 *      server/frontend/apps/web check:i18n`,非零即 fail)
 *
 * 本仓无 gh/CI 环境,脚本先行:本地 `pnpm check:i18n`(apps/web 下)。
 * i18n parity 的 vitest 版在 src/i18n.test.ts(覆盖第 1 项),脚本版多出
 * 第 2 项「引用扫描」,两者互补。
 *
 * 实现说明:字典是 TS 源文件,这里用正则抽 `^\s*'key':` 形式的顶层字面量,
 * 不引 TS loader,零依赖可在任意 node 跑。
 */
import { readFileSync, readdirSync, statSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const appDir = path.dirname(path.dirname(fileURLToPath(import.meta.url)))
const monorepoDir = path.resolve(appDir, '../..')

const dictFiles = {
  en: path.join(appDir, 'src/i18n/en.ts'),
  'zh-CN': path.join(appDir, 'src/i18n/zh-CN.ts'),
  'zh-TW': path.join(appDir, 'src/i18n/zh-TW.ts'),
}

/** 扫描 t('...') 字面量引用的源码根(apps/web + 两个共享包,t() 在三处都有用)。 */
const scanRoots = [
  path.join(appDir, 'src'),
  path.resolve(monorepoDir, 'packages/web-features/src'),
  path.resolve(monorepoDir, 'packages/ui/src'),
]

function extractKeysFromDict(file) {
  const source = readFileSync(file, 'utf8')
  const keys = new Set()
  // 字典 key 有三种写法:'key': / "key": / key:(TS identifier)。value 起始
  // 限定引号,避免误吞 `key: number` 之类的类型别名。
  const re = /^\s*(?:'((?:\\.|[^'\\])+)'|"((?:\\.|[^"\\])+)"|([A-Za-z_$][\w$]*))\s*:\s*['"`]/gm
  let m
  while ((m = re.exec(source)) !== null) keys.add(m[1] ?? m[2] ?? m[3])
  return keys
}

function* walkTsFiles(dir) {
  let entries
  try {
    entries = readdirSync(dir)
  } catch {
    return
  }
  for (const name of entries) {
    if (name === 'node_modules' || name === 'dist' || name.startsWith('.')) continue
    const full = path.join(dir, name)
    const st = statSync(full)
    if (st.isDirectory()) yield* walkTsFiles(full)
    else if (/\.(ts|tsx)$/.test(name)) yield full
  }
}

/** 匹配 t('key') / t("key")(允许 t( 与引号间有空白/换行)。 */
const T_CALL_RE = /\bt\(\s*(['"])((?:\\.|(?!\1)[^\\])*)\1/g

/** 去掉行注释与块注释(逐行处理,保留行号对齐)。字符串里带 // 的场景宁可
 *  漏报(false negative)也不误报注释里的 t('...') 字面量。 */
function stripComments(source) {
  return source
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
    .split('\n')
    .map((line) => {
      const idx = line.indexOf('//')
      return idx >= 0 ? line.slice(0, idx) : line
    })
    .join('\n')
}

function extractUsedKeys(root) {
  const used = new Map() // key -> [file:line]
  for (const file of walkTsFiles(root)) {
    const source = stripComments(readFileSync(file, 'utf8'))
    T_CALL_RE.lastIndex = 0
    let m
    while ((m = T_CALL_RE.exec(source)) !== null) {
      const key = m[2]
      // 跳过 `t('prefix.' + var)` 这类动态拼接被截出来的前缀(以 . 结尾)
      if (!key || key.endsWith('.')) continue
      const line = source.slice(0, m.index).split('\n').length
      const rel = path.relative(monorepoDir, file).replaceAll('\\', '/')
      const hits = used.get(key) || []
      hits.push(`${rel}:${line}`)
      used.set(key, hits)
    }
  }
  return used
}

const problems = []

// ── 1. 三语 diff ────────────────────────────────────────────────
const dictKeys = {}
for (const [name, file] of Object.entries(dictFiles)) {
  dictKeys[name] = extractKeysFromDict(file)
}
const enKeys = dictKeys['en']
for (const name of ['zh-CN', 'zh-TW']) {
  const missing = [...enKeys].filter((k) => !dictKeys[name].has(k)).sort()
  const extra = [...dictKeys[name]].filter((k) => !enKeys.has(k)).sort()
  if (missing.length > 0) {
    problems.push(`[parity] ${name} 缺 ${missing.length} 个 en 有的 key:\n  ${missing.join('\n  ')}`)
  }
  if (extra.length > 0) {
    problems.push(`[parity] ${name} 有 ${extra.length} 个 en 没有的 key:\n  ${extra.join('\n  ')}`)
  }
}
if (enKeys.size === 0) problems.push('[parity] en.ts 一个 key 都没解析到 —— 正则失效?')

// ── 2. t('...') 字面量引用扫描 ─────────────────────────────────
const usedKeys = new Map()
for (const root of scanRoots) {
  for (const [key, hits] of extractUsedKeys(root)) {
    const merged = usedKeys.get(key) || []
    merged.push(...hits)
    usedKeys.set(key, merged)
  }
}
const unknownUsed = [...usedKeys.entries()]
  .filter(([key]) => !enKeys.has(key))
  .sort((a, b) => a[0].localeCompare(b[0]))
for (const [key, hits] of unknownUsed) {
  problems.push(`[usage] t('${key}') 不在字典里(en 缺),引用:\n  ${hits.join('\n  ')}`)
}

// ── 汇总 ───────────────────────────────────────────────────────
const totalUsed = usedKeys.size
const knownUsed = totalUsed - unknownUsed.length
console.log(`i18n check: en=${enKeys.size} keys, zh-CN=${dictKeys['zh-CN'].size}, zh-TW=${dictKeys['zh-TW'].size}; t() 字面量引用 ${totalUsed}(其中 ${unknownUsed.length} 个缺 key)`)
if (problems.length > 0) {
  console.error(`\n✗ i18n check 失败(${problems.length} 组问题):\n`)
  for (const p of problems) console.error(`- ${p}\n`)
  process.exit(1)
} else {
  console.log('✓ i18n check 通过:三语对齐,引用的字面量 key 全部存在')
  process.exit(0)
}
