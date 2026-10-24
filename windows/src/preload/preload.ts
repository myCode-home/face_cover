import { contextBridge, ipcRenderer } from 'electron'

export interface LibraryEntryDTO {
  name: string
  path: string
  sizeBytes: number
  birthMs: number
  mtimeMs: number
}

const api = {
  // 素材
  coverPng: (id: string): Promise<ArrayBuffer | null> => ipcRenderer.invoke('covers:png', id),
  ortWasm: (): Promise<ArrayBuffer | null> => ipcRenderer.invoke('asset:ortWasm'),
  ortMjs: (): Promise<string | null> => ipcRenderer.invoke('asset:ortMjs'),
  modelOnnx: (): Promise<ArrayBuffer | null> => ipcRenderer.invoke('asset:model'),

  // 录像库
  scanRecordings: (): Promise<LibraryEntryDTO[]> => ipcRenderer.invoke('recordings:scan'),
  recordingsDir: (): Promise<string> => ipcRenderer.invoke('recordings:dir'),
  openRecordingsDir: (): Promise<void> => ipcRenderer.invoke('shell:openRecordingsDir'),
  revealItem: (filePath: string): Promise<void> => ipcRenderer.invoke('shell:reveal', filePath),
  playItem: (filePath: string): Promise<string | null> => ipcRenderer.invoke('shell:play', filePath),
  trashItem: (filePath: string): Promise<{ ok: boolean; error?: string }> => ipcRenderer.invoke('shell:trash', filePath),
  copyText: (text: string): Promise<void> => ipcRenderer.invoke('clipboard:writeText', text),
  openLibraryWithHighlight: (entryName: string): Promise<void> => ipcRenderer.invoke('library:openWithHighlight', entryName),
  onLibraryHighlight: (cb: (entryName: string) => void): void => {
    ipcRenderer.on('library:highlight', (_e, name: string) => cb(name))
  },

  // 录制落盘（分块）
  beginRecording: (fileName: string): Promise<{ ok: boolean; path?: string; error?: string }> =>
    ipcRenderer.invoke('recording:begin', fileName),
  writeChunk: (filePath: string, chunk: ArrayBuffer): Promise<{ ok: boolean; error?: string }> =>
    ipcRenderer.invoke('recording:write', filePath, chunk),
  endRecording: (filePath: string): Promise<{ ok: boolean; sizeBytes?: number; error?: string }> =>
    ipcRenderer.invoke('recording:end', filePath),
  readRecordingFile: (filePath: string): Promise<{ ok: boolean; data?: ArrayBuffer; error?: string }> =>
    ipcRenderer.invoke('recording:readWhole', filePath),
  writeRecordingFile: (filePath: string, data: ArrayBuffer): Promise<{ ok: boolean; sizeBytes?: number; error?: string }> =>
    ipcRenderer.invoke('recording:writeWhole', filePath, data),
  fixWebmSource: (): Promise<string | null> => ipcRenderer.invoke('asset:fixWebmSource'),

  // 诊断
  diag: (line: string): Promise<void> => ipcRenderer.invoke('diag', line),

  // 无框窗口标题栏
  minimize: (): void => ipcRenderer.send('window:minimize'),
  maximizeToggle: (): void => ipcRenderer.send('window:maximizeToggle'),
  closeWindow: (): void => ipcRenderer.send('window:close'),
  onMaximizedChanged: (cb: (maximized: boolean) => void): void => {
    ipcRenderer.on('window:maximized', (_e, maximized: boolean) => cb(maximized))
  },
}

export type FaceCoverApi = typeof api

contextBridge.exposeInMainWorld('facecover', api)
