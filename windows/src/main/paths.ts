import { app } from 'electron'
import path from 'node:path'
import fs from 'node:fs'

let cachedDir: string | null = null

/**
 * 录像目录：Windows 用系统的「视频」库，mac/linux 沿用 macOS 版的
 * ~/Movies/FaceCover（在 mac 上开发时两个版本看同一个目录）。
 */
export function recordingsDir(): string {
  if (cachedDir) return cachedDir
  const home = app.getPath('home')
  const base = process.platform === 'win32' ? app.getPath('videos') : path.join(home, 'Movies')
  cachedDir = path.join(base, 'FaceCover')
  return cachedDir
}

export function ensureRecordingsDir(): string {
  const dir = recordingsDir()
  fs.mkdirSync(dir, { recursive: true })
  return dir
}

export function diagnosticsFile(): string {
  return path.join(recordingsDir(), '诊断.txt')
}
