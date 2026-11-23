import { app, BrowserWindow, desktopCapturer, ipcMain, clipboard, shell, session } from 'electron'
import fs from 'node:fs'
import path from 'node:path'
import { scanLibrary, SCANNED_EXTENSIONS } from './library'
import { appendDiagnostic } from './diagnostics'
import { beginRecording, writeChunk, endRecording, closeAllStreams, readWhole, writeWhole } from './recording-writer'
import { ensureRecordingsDir, recordingsDir } from './paths'
import { getOrCreateLibraryWindow } from './windows'

const COVER_ID_PATTERN = /^Cover-[A-Za-z0-9]+$/
const MODEL_FILE = 'face_detection_yunet_2023mar.onnx'
const ORT_GLUE = 'onnxruntime-web/dist/ort-wasm-simd-threaded.jsep.mjs'
const ORT_WASM = 'onnxruntime-web/dist/ort-wasm-simd-threaded.jsep.wasm'

/** onnxruntime-web 的文件在 node_modules 里；打包后随依赖进 app.asar，fs 直接读 */
function resolveNodeModulesFile(relative: string): string | null {
  const candidates = [
    path.join(process.resourcesPath, 'app.asar', 'node_modules', relative),
    path.join(app.getAppPath(), 'node_modules', relative),
  ]
  return candidates.find((p) => fs.existsSync(p)) ?? null
}

/** dev 下 app.getAppPath()=windows/，素材在仓库根 Resources/；打包后 extraResources 拷到 resources/covers */
function resolveCoverPath(id: string): string | null {
  if (!COVER_ID_PATTERN.test(id)) return null
  const candidates = [
    path.join(process.resourcesPath, 'covers', `${id}.png`),
    path.join(app.getAppPath(), '..', 'Resources', `${id}.png`),
  ]
  return candidates.find((p) => fs.existsSync(p)) ?? null
}

function resolveModelPath(): string | null {
  const candidates = [
    path.join(process.resourcesPath, 'assets', 'models', MODEL_FILE),
    path.join(app.getAppPath(), 'assets', 'models', MODEL_FILE),
  ]
  return candidates.find((p) => fs.existsSync(p)) ?? null
}

function readFileBuffer(file: string): ArrayBuffer {
  const buf = fs.readFileSync(file)
  const out = new ArrayBuffer(buf.byteLength)
  new Uint8Array(out).set(buf)
  return out
}

export function registerIpc(): void {
  ipcMain.handle('covers:png', (_e, id: string) => {
    const file = resolveCoverPath(id)
    return file ? readFileBuffer(file) : null
  })

  // ORT 运行时：wasm 二进制直接喂 env.wasm.wasmBinary，glue mjs 走 blob（零文件 fetch）
  ipcMain.handle('asset:ortWasm', () => {
    const file = resolveNodeModulesFile(ORT_WASM)
    return file ? readFileBuffer(file) : null
  })

  ipcMain.handle('asset:ortMjs', () => {
    const file = resolveNodeModulesFile(ORT_GLUE)
    return file ? fs.readFileSync(file, 'utf-8') : null
  })

  // fix-webm-duration：MediaRecorder 的 webm 没有时长元数据，停录后用它补上
  ipcMain.handle('asset:fixWebmSource', () => {
    const file = resolveNodeModulesFile('fix-webm-duration/fix-webm-duration.js')
    return file ? fs.readFileSync(file, 'utf-8') : null
  })

  ipcMain.handle('asset:model', () => {
    const file = resolveModelPath()
    return file ? readFileBuffer(file) : null
  })

  ipcMain.handle('recordings:scan', () => scanLibrary())

  ipcMain.handle('recordings:extensions', () => SCANNED_EXTENSIONS)

  ipcMain.handle('recordings:dir', () => {
    ensureRecordingsDir()
    return recordingsDir()
  })

  ipcMain.handle('recording:begin', (_e, fileName: string) => beginRecording(fileName))
  ipcMain.handle('recording:write', (_e, filePath: string, chunk: ArrayBuffer) => writeChunk(filePath, chunk))
  ipcMain.handle('recording:end', (_e, filePath: string) => endRecording(filePath))
  ipcMain.handle('recording:readWhole', (_e, filePath: string) => readWhole(filePath))
  ipcMain.handle('recording:writeWhole', (_e, filePath: string, data: ArrayBuffer) => writeWhole(filePath, data))

  ipcMain.handle('diag', (_e, line: string) => {
    appendDiagnostic(line)
  })

  ipcMain.handle('shell:reveal', (_e, filePath: string) => {
    if (typeof filePath === 'string' && fs.existsSync(filePath)) shell.showItemInFolder(filePath)
  })

  ipcMain.handle('shell:play', async (_e, filePath: string) => {
    if (typeof filePath !== 'string' || !fs.existsSync(filePath)) return '文件不存在'
    const msg = await shell.openPath(filePath)
    return msg || null
  })

  ipcMain.handle('shell:openRecordingsDir', async () => {
    await shell.openPath(ensureRecordingsDir())
  })

  ipcMain.handle('shell:trash', async (_e, filePath: string) => {
    try {
      await shell.trashItem(filePath)
      return { ok: true }
    } catch (err) {
      return { ok: false, error: String(err) }
    }
  })

  ipcMain.handle('clipboard:writeText', (_e, text: string) => {
    clipboard.writeText(text)
  })

  // 无框窗口的自绘标题栏
  ipcMain.on('window:minimize', (e) => BrowserWindow.fromWebContents(e.sender)?.minimize())
  ipcMain.on('window:maximizeToggle', (e) => {
    const win = BrowserWindow.fromWebContents(e.sender)
    if (!win) return
    if (win.isMaximized()) win.unmaximize()
    else win.maximize()
  })
  ipcMain.on('window:close', (e) => BrowserWindow.fromWebContents(e.sender)?.close())

  ipcMain.handle('library:openWithHighlight', (e, entryName: string) => {
    const win = getOrCreateLibraryWindow()
    if (win.isMinimized()) win.restore()
    win.show()
    win.focus()
    if (!win.webContents.id || win.webContents.id !== e.sender.id) win.webContents.send('library:highlight', entryName)
  })
}

/**
 * 系统声音授权：Windows 上 Chromium 原生支持 loopback（录系统输出的声音），
 * 不需要 macOS 版 ScreenCaptureKit 那样的「屏幕录制」权限，也不用装 BlackHole。
 * 视频画面压到 2×2/1fps（和 macOS 版同一招），渲染进程拿到音频轨后立刻停掉视频轨。
 */
export function configureDisplayMedia(): void {
  session.defaultSession.setDisplayMediaRequestHandler((_request, callback) => {
    void desktopCapturer
      .getSources({ types: ['screen'], thumbnailSize: { width: 0, height: 0 } })
      .then((sources) => {
        const video = sources[0]
        if (!video) {
          callback({})
          return
        }
        if (process.platform === 'win32') callback({ video, audio: 'loopback' })
        else callback({ video })
      })
      .catch(() => callback({}))
  })
}
