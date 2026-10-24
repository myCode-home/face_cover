// window.facecover 的类型镜像（preload.ts 是实现方，结构以它为准）

export interface LibraryEntryDTO {
  name: string
  path: string
  sizeBytes: number
  birthMs: number
  mtimeMs: number
}

export interface FaceCoverApi {
  coverPng(id: string): Promise<ArrayBuffer | null>
  ortWasm(): Promise<ArrayBuffer | null>
  ortMjs(): Promise<string | null>
  modelOnnx(): Promise<ArrayBuffer | null>
  scanRecordings(): Promise<LibraryEntryDTO[]>
  recordingsDir(): Promise<string>
  openRecordingsDir(): Promise<void>
  revealItem(filePath: string): Promise<void>
  playItem(filePath: string): Promise<string | null>
  trashItem(filePath: string): Promise<{ ok: boolean; error?: string }>
  copyText(text: string): Promise<void>
  openLibraryWithHighlight(entryName: string): Promise<void>
  onLibraryHighlight(cb: (entryName: string) => void): void
  beginRecording(fileName: string): Promise<{ ok: boolean; path?: string; error?: string }>
  writeChunk(filePath: string, chunk: ArrayBuffer): Promise<{ ok: boolean; error?: string }>
  endRecording(filePath: string): Promise<{ ok: boolean; sizeBytes?: number; error?: string }>
  readRecordingFile(filePath: string): Promise<{ ok: boolean; data?: ArrayBuffer; error?: string }>
  writeRecordingFile(filePath: string, data: ArrayBuffer): Promise<{ ok: boolean; sizeBytes?: number; error?: string }>
  fixWebmSource(): Promise<string | null>
  diag(line: string): Promise<void>
  minimize(): void
  maximizeToggle(): void
  closeWindow(): void
  onMaximizedChanged(cb: (maximized: boolean) => void): void
}

declare global {
  interface Window {
    facecover: FaceCoverApi
  }
}

export const api: FaceCoverApi = window.facecover
