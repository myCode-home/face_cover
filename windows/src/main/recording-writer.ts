import fs from 'node:fs'
import path from 'node:path'
import { ensureRecordingsDir } from './paths'

// MediaRecorder 产出的 Blob 无法直接从渲染进程写盘（沙箱），分块经 IPC 递给主进程落盘。
// 4MB 一块，主流录像长度下开销可忽略。
const openStreams = new Map<string, fs.WriteStream>()

export function beginRecording(fileName: string): { ok: boolean; path?: string; error?: string } {
  const dir = ensureRecordingsDir()
  if (!/^[^\\/]+\.(mp4|webm|mov)$/.test(fileName)) return { ok: false, error: `不认识的文件名：${fileName}` }
  const full = path.join(dir, fileName)
  if (openStreams.has(full)) return { ok: false, error: '该文件已在写入中' }
  try {
    const stream = fs.createWriteStream(full, { flags: 'w' })
    openStreams.set(full, stream)
    return { ok: true, path: full }
  } catch (err) {
    return { ok: false, error: String(err) }
  }
}

export function writeChunk(filePath: string, chunk: ArrayBuffer): { ok: boolean; error?: string } {
  const stream = openStreams.get(filePath)
  if (!stream) return { ok: false, error: '没有正在写入的文件，先调用 begin' }
  try {
    stream.write(Buffer.from(chunk))
    return { ok: true }
  } catch (err) {
    return { ok: false, error: String(err) }
  }
}

export function endRecording(filePath: string): Promise<{ ok: boolean; sizeBytes?: number; error?: string }> {
  const stream = openStreams.get(filePath)
  if (!stream) return Promise.resolve({ ok: false, error: '没有正在写入的文件' })
  openStreams.delete(filePath)
  return new Promise((resolve) => {
    stream.end(() => {
      try {
        resolve({ ok: true, sizeBytes: fs.statSync(filePath).size })
      } catch (err) {
        resolve({ ok: false, error: String(err) })
      }
    })
    stream.on('error', (err) => resolve({ ok: false, error: String(err) }))
  })
}

/** 应用退出时把没收尾的流都关掉（正常流程不会走到这里） */
export function closeAllStreams(): void {
  for (const [, stream] of openStreams) stream.destroy()
  openStreams.clear()
}

/** 读整个录像文件（修 webm 时长元数据用；调用方负责限制文件大小） */
export function readWhole(filePath: string): { ok: boolean; data?: ArrayBuffer; error?: string } {
  try {
    const buf = fs.readFileSync(filePath)
    const out = new ArrayBuffer(buf.byteLength)
    new Uint8Array(out).set(buf)
    return { ok: true, data: out }
  } catch (err) {
    return { ok: false, error: String(err) }
  }
}

export function writeWhole(filePath: string, data: ArrayBuffer): { ok: boolean; sizeBytes?: number; error?: string } {
  try {
    fs.writeFileSync(filePath, Buffer.from(data))
    return { ok: true, sizeBytes: fs.statSync(filePath).size }
  } catch (err) {
    return { ok: false, error: String(err) }
  }
}
