// 把 src/renderer/ui 的 HTML/CSS 拷到编译输出（tsc 只管 .ts）
import { cpSync, mkdirSync, readdirSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.dirname(fileURLToPath(import.meta.url))
const src = path.join(root, '..', 'src', 'renderer', 'ui')
const out = path.join(root, '..', 'dist', 'renderer', 'ui')

mkdirSync(out, { recursive: true })
for (const name of readdirSync(src)) {
  if (name.endsWith('.html') || name.endsWith('.css')) {
    cpSync(path.join(src, name), path.join(out, name))
    console.log(`copied ${name}`)
  }
}
