import { app } from 'electron'
import path from 'node:path'
import { registerIpc, configureDisplayMedia } from './ipc'
import { createMainWindow, getMainWindow } from './windows'
import { closeAllStreams } from './recording-writer'

app.setName('脸罩 FaceCover')

/** --smoke：无人值守端到端自检。假摄像头 + 自动授权，渲染进程跑完脚本自己关窗退出。 */
const smokeMode = process.argv.includes('--smoke')

void app.whenReady().then(() => {
  if (smokeMode) {
    app.commandLine.appendSwitch('use-fake-device-for-media-stream')
    app.commandLine.appendSwitch('use-fake-ui-for-media-stream')
  }
  configureDisplayMedia()
  registerIpc()
  createMainWindow(smokeMode)

  app.on('activate', () => {
    // 关窗即退出（与 macOS 版一致），这里只为 dock 复活场景兜底
    if (!getMainWindow()) createMainWindow()
  })
})

app.on('window-all-closed', () => {
  app.quit()
})

app.on('will-quit', () => {
  closeAllStreams()
})

// 渲染进程的 HTML/CSS 资源由编译脚本拷贝；这里确保相对路径在打包后也成立
process.env.ELECTRON_ENABLE_STACK_DUMPING = '1'
void path
