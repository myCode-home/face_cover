import fs from 'node:fs'
import path from 'node:path'
import { ensureRecordingsDir } from './paths'

export interface LibraryEntry {
  name: string
  path: string
  sizeBytes: number
  /** 创建时间（缺省退化为修改时间），用于排序与展示 */
  birthMs: number
  mtimeMs: number
}

const VIDEO_EXTENSIONS = new Set(['.mov', '.mp4', '.webm'])
// Windows 版录 mp4/webm；保留 .mov 是为了 mac 版放进同一目录的文件也能列出
export const SCANNED_EXTENSIONS = [...VIDEO_EXTENSIONS]

/**
 * 扫描录像目录。与 macOS 版一致：只看顶层、按创建时间降序、平局按文件名降序。
 */
export function scanLibrary(): LibraryEntry[] {
  const dir = ensureRecordingsDir()
  let names: string[]
  try {
    names = fs.readdirSync(dir)
  } catch {
    return []
  }
  const entries: LibraryEntry[] = []
  for (const name of names) {
    if (!VIDEO_EXTENSIONS.has(path.extname(name).toLowerCase())) continue
    const full = path.join(dir, name)
    let st: fs.Stats
    try {
      st = fs.statSync(full)
    } catch {
      continue
    }
    if (!st.isFile()) continue
    const birth = st.birthtimeMs > 0 ? st.birthtimeMs : st.mtimeMs
    entries.push({ name, path: full, sizeBytes: st.size, birthMs: birth, mtimeMs: st.mtimeMs })
  }
  entries.sort((a, b) => (b.birthMs !== a.birthMs ? b.birthMs - a.birthMs : b.name.localeCompare(a.name)))
  return entries
}
