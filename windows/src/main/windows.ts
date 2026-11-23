import { app, BrowserWindow } from 'electron'
import path from 'node:path'

const PRELOAD = path.join(__dirname, '../preload/preload.js')

function rendererFile(name: string): string {
  // tsc 把 src/renderer/** 编译到 dist/renderer/**（剥掉 src/renderer 前缀）
  return path.join(__dirname, '../renderer', name)
}

let mainWindow: BrowserWindow | null = null
let libraryWindow: BrowserWindow | null = null

export function createMainWindow(smokeMode = false): BrowserWindow {
  mainWindow = new BrowserWindow({
    title: '脸罩 FaceCover',
    width: 1080,
    height: 680,
    minWidth: 1000,
    minHeight: 660,
    frame: false,
    backgroundColor: '#f2f1ef',
    show: false,
    webPreferences: { preload: PRELOAD },
  })
  mainWindow.once('ready-to-show', () => mainWindow?.show())
  forwardRendererConsole(mainWindow, '主窗')
  // 无框窗口最大化状态发给前端，红绿灯按钮要切换图形
  const sendMaximized = (): void => mainWindow?.webContents.send('window:maximized', mainWindow.isMaximized())
  mainWindow.on('maximize', sendMaximized)
  mainWindow.on('unmaximize', sendMaximized)
  mainWindow.on('closed', () => {
    mainWindow = null
  })
  void mainWindow.loadFile(rendererFile('ui/index.html'), smokeMode ? { query: { smoke: '1' } } : undefined)
  return mainWindow
}

/** 把渲染进程的输出转出来；打包版只在 --smoke 自检时转（平时别往 stdout 塞东西） */
function forwardRendererConsole(win: BrowserWindow, label: string): void {
  if (app.isPackaged && !process.argv.includes('--smoke')) return
  win.webContents.on('did-finish-load', () => console.log(`[${label}] 渲染进程加载完成`))
  win.webContents.on('console-message', (_e, _level, message, _line, _sourceId) => {
    console.log(`[${label}] ${message}`)
  })
}

export function getMainWindow(): BrowserWindow | null {
  return mainWindow
}

export function getOrCreateLibraryWindow(): BrowserWindow {
  if (libraryWindow && !libraryWindow.isDestroyed()) return libraryWindow
  libraryWindow = new BrowserWindow({
    title: '录像库',
    width: 760,
    height: 560,
    minWidth: 660,
    minHeight: 440,
    frame: false,
    backgroundColor: '#f2f1ef',
    show: false,
    webPreferences: { preload: PRELOAD },
  })
  libraryWindow.once('ready-to-show', () => libraryWindow?.show())
  forwardRendererConsole(libraryWindow, '录像库')
  libraryWindow.on('closed', () => {
    libraryWindow = null
  })
  void libraryWindow.loadFile(rendererFile('ui/library.html'))
  return libraryWindow
}
