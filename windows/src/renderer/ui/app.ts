// 主窗口控制器：面板状态、摄像头、录制全流程、诊断。
// 交互对齐 macOS 版 ContentView/PanelState；持久化只存分辨率/帧率/画质三项
//（与 macOS 版 UserDefaults 同键名）。

import { CompositionEngine, EngineStats } from '../media/engine.js'
import { AudioGraph, AudioSourceId, AUDIO_SOURCES, audioErrorMessage } from '../media/audio.js'
import { pickRecordingFormat, startRecording as startMediaRecorder, RecorderHandle } from '../media/recorder.js'
import {
  ALL_COVERS,
  CoverDef,
  COVER_ANCHORS,
  defaultsForCover,
} from '../core/covers.js'
import {
  DEFAULT_FRAME_RATE,
  DEFAULT_QUALITY,
  DEFAULT_RESOLUTION,
  FrameRateId,
  RESOLUTION_TIERS,
  ResolutionTierId,
  QUALITY_TIERS,
  QualityId,
  averageBitRate,
  cameraConstraints,
  estimateMBPerMinute,
  outputSize,
  qualityTier,
  resolutionTier,
} from '../core/presets.js'
import { elapsedText, makeRecordingFileName, offsetText, scaleText, sizeText } from '../core/format.js'
import { api } from '../api.js'

// ---------- 状态 ----------

interface Defaults {
  size: number
  x: number
  y: number
}

const state = {
  cover: null as CoverDef | null,
  coverImage: null as HTMLImageElement | null,
  builtinOpen: false,
  trackingEnabled: true,
  mirror: true,
  showDebugBox: false,
  sizeScale: 1.5,
  offsetX: 0,
  offsetY: 0,
  defaults: { size: 1.5, x: 0, y: 0 } as Defaults,
  resolution: DEFAULT_RESOLUTION as ResolutionTierId,
  fps: DEFAULT_FRAME_RATE as FrameRateId,
  quality: DEFAULT_QUALITY as QualityId,
  audioSource: 'microphone' as AudioSourceId,
  cameraDeviceId: '' as string,
  recording: false,
  paused: false,
}

const audioGraph = new AudioGraph()
let stream: MediaStream | null = null
let engine: CompositionEngine
let recorder: RecorderHandle | null = null
let writingPath: string | null = null
let writeChain: Promise<void> = Promise.resolve()
let recordingStartedAt = 0
let pausedAccumMs = 0
let pausedAt: number | null = null

const $ = <T extends HTMLElement>(id: string): T => document.getElementById(id) as T

window.addEventListener('error', (e) => console.error('[boot] uncaught:', e.message))
window.addEventListener('unhandledrejection', (e) => console.error('[boot] rejection:', String(e.reason)))

// ---------- 启动 ----------

void bootstrap()

async function bootstrap(): Promise<void> {
  loadPrefs()
  console.log('[init] 偏好已加载')
  engine = new CompositionEngine(
    $('camera') as HTMLVideoElement,
    $('record-canvas') as HTMLCanvasElement,
    $('debug-canvas') as HTMLCanvasElement,
  )
  engine.onStats = onEngineStats
  wireTitlebar()
  wireControls()
  console.log('[init] 控件已接线')
  await buildCoverGrids()
  console.log('[init] 素材网格完成')
  await engine.initDetector()
  if (engine.lastStats()?.detectorError) {
    console.error('[init] 人脸检测不可用：', engine.lastStats()!.detectorError)
  } else {
    console.log('[init] YuNet 检测器就绪')
  }
  await startCamera()
  engine.start()
  console.log('[init] 管线已启动')
  void loadFixWebm()
  setInterval(writeDiagnosticLine, 1000)
  setInterval(updateBadge, 250)
  if (new URLSearchParams(location.search).has('smoke')) void runSmoke()
}

function loadPrefs(): void {
  const res = localStorage.getItem('recordingResolution') as ResolutionTierId | null
  const fps = Number(localStorage.getItem('recordingFrameRate'))
  const q = localStorage.getItem('recordingQuality') as QualityId | null
  if (res && RESOLUTION_TIERS.some((t) => t.id === res)) state.resolution = res
  if ([15, 24, 30].includes(fps)) state.fps = fps as FrameRateId
  if (q && QUALITY_TIERS.some((t) => t.id === q)) state.quality = q
  ;($('sel-resolution') as HTMLSelectElement).value = state.resolution
  ;($('sel-fps') as HTMLSelectElement).value = String(state.fps)
  ;($('sel-quality') as HTMLSelectElement).value = state.quality
  updateQualityHint()
}

// ---------- 标题栏 ----------

function wireTitlebar(): void {
  $('tl-close').addEventListener('click', () => api.closeWindow())
  $('tl-min').addEventListener('click', () => api.minimize())
  $('tl-max').addEventListener('click', () => api.maximizeToggle())
}

// ---------- 控件 ----------

function wireControls(): void {
  // 脸罩
  $('tile-builtin').addEventListener('click', () => toggleBuiltinList())
  $('tile-custom').addEventListener('click', () => $('file-input').click())
  $('btn-collapse').addEventListener('click', () => toggleBuiltinList(false))
  $('btn-clear-cover').addEventListener('click', () => void clearCover())
  $('file-input').addEventListener('change', () => {
    const file = ($('file-input') as HTMLInputElement).files?.[0]
    if (file) void loadCustomImage(file)
    ;($('file-input') as HTMLInputElement).value = ''
  })
  wireDragDrop()

  // 位置与大小
  $('sw-tracking').addEventListener('change', () => {
    state.trackingEnabled = ($('sw-tracking') as HTMLInputElement).checked
    if (!state.trackingEnabled) engine.resetTracking()
  })
  wireSlider($('sl-size') as HTMLInputElement, $('rs-size'), 'size')
  wireSlider($('sl-x') as HTMLInputElement, $('rs-x'), 'x')
  wireSlider($('sl-y') as HTMLInputElement, $('rs-y'), 'y')
  $('btn-reset-all').addEventListener('click', () => {
    applySlider('size', state.defaults.size)
    applySlider('x', state.defaults.x)
    applySlider('y', state.defaults.y)
  })

  // 画面
  $('sw-mirror').addEventListener('change', () => {
    state.mirror = ($('sw-mirror') as HTMLInputElement).checked
  })
  $('sw-debug').addEventListener('change', () => {
    state.showDebugBox = ($('sw-debug') as HTMLInputElement).checked
  })

  // 录制质量（录制中不可改：AVCaptureSession 的预设中途改不了，改了画面会跳）
  for (const [id, apply] of [
    ['sel-resolution', () => applyResolution()],
    ['sel-fps', () => applyFrameRate()],
    ['sel-quality', () => applyQuality()],
  ] as const) {
    $(id).addEventListener('change', () => {
      if (state.recording) {
        syncQualitySelectors()
        return
      }
      apply()
    })
  }

  // 声音
  ;($('sel-audio') as HTMLSelectElement).value = state.audioSource
  $('sel-audio').addEventListener('change', () => {
    state.audioSource = ($('sel-audio') as HTMLSelectElement).value as AudioSourceId
    hideAudioWarning()
  })

  // 摄像头
  $('sel-camera').addEventListener('change', () => {
    state.cameraDeviceId = ($('sel-camera') as HTMLSelectElement).value
    if (!state.recording) void startCamera(state.cameraDeviceId || undefined)
  })

  // 文件
  $('btn-library').addEventListener('click', () => void api.openLibraryWithHighlight(''))
  $('btn-open-dir').addEventListener('click', () => void api.openRecordingsDir())

  // 录制
  $('btn-record').addEventListener('click', () => void toggleRecording())
  $('btn-pause').addEventListener('click', () => togglePause())
  window.addEventListener('keydown', (e) => {
    if (e.target instanceof HTMLInputElement || e.target instanceof HTMLSelectElement) return
    if (e.key === 'Enter' && (e.ctrlKey || e.metaKey)) {
      e.preventDefault()
      void toggleRecording()
    } else if (e.key.toLowerCase() === 'p' && e.shiftKey && (e.ctrlKey || e.metaKey)) {
      e.preventDefault()
      togglePause()
    }
  })

  // 已保存弹窗
  $('saved-view').addEventListener('click', () => {
    const name = $('saved-dialog').dataset.fileName ?? ''
    ;($('saved-dialog') as HTMLDialogElement).close()
    void api.openLibraryWithHighlight(name)
  })
  $('saved-ok').addEventListener('click', () => ($('saved-dialog') as HTMLDialogElement).close())
}

function wireSlider(input: HTMLInputElement, resetBtn: HTMLElement, key: 'size' | 'x' | 'y'): void {
  input.addEventListener('input', () => applySlider(key, Number(input.value)))
  resetBtn.addEventListener('click', () =>
    applySlider(key, key === 'size' ? state.defaults.size : key === 'x' ? state.defaults.x : state.defaults.y),
  )
}

function applySlider(key: 'size' | 'x' | 'y', value: number): void {
  if (key === 'size') {
    state.sizeScale = value
    ;($('sl-size') as HTMLInputElement).value = String(value)
  } else if (key === 'x') {
    state.offsetX = value
    ;($('sl-x') as HTMLInputElement).value = String(value)
  } else {
    state.offsetY = value
    ;($('sl-y') as HTMLInputElement).value = String(value)
  }
  refreshSliderDisplays()
}

function refreshSliderDisplays(): void {
  const sizeEl = $('sl-size-value')
  const xEl = $('sl-x-value')
  const yEl = $('sl-y-value')
  sizeEl.textContent = scaleText(state.sizeScale)
  xEl.textContent = offsetText(state.offsetX)
  yEl.textContent = offsetText(state.offsetY)
  sizeEl.classList.toggle('default', Math.abs(state.sizeScale - state.defaults.size) < 1e-4)
  xEl.classList.toggle('default', Math.abs(state.offsetX - state.defaults.x) < 1e-4)
  yEl.classList.toggle('default', Math.abs(state.offsetY - state.defaults.y) < 1e-4)
  const rs = (id: string, atDefault: boolean): void => {
    ;($(id) as HTMLButtonElement).disabled = atDefault
  }
  rs('rs-size', Math.abs(state.sizeScale - state.defaults.size) < 1e-4)
  rs('rs-x', Math.abs(state.offsetX - state.defaults.x) < 1e-4)
  rs('rs-y', Math.abs(state.offsetY - state.defaults.y) < 1e-4)
  const allDefault =
    Math.abs(state.sizeScale - state.defaults.size) < 1e-4 &&
    Math.abs(state.offsetX - state.defaults.x) < 1e-4 &&
    Math.abs(state.offsetY - state.defaults.y) < 1e-4
  $('btn-reset-all').classList.toggle('hidden', allDefault)
}

function syncEngineSettings(): void {
  if (!engine) return
  engine.settings.coverImage = state.coverImage
  engine.settings.cover = state.cover
  engine.settings.anchor = state.cover ? (COVER_ANCHORS[state.cover.id] ?? null) : null
  engine.settings.trackingEnabled = state.trackingEnabled
  engine.settings.sizeScale = state.sizeScale
  engine.settings.offsetX = state.offsetX
  engine.settings.offsetY = state.offsetY
  engine.settings.mirror = state.mirror
  engine.settings.showDebugBox = state.showDebugBox
}

// ---------- 脸罩 ----------

async function buildCoverGrids(): Promise<void> {
  const hoods = ALL_COVERS.filter((c) => c.kind === 'hood')
  const masks = ALL_COVERS.filter((c) => c.kind === 'mask')
  for (const [gridId, covers] of [
    ['grid-hoods', hoods],
    ['grid-masks', masks],
  ] as const) {
    const grid = $(gridId)
    for (const cover of covers) {
      const cell = document.createElement('button')
      cell.className = 'cover-cell'
      cell.dataset.id = cover.id
      cell.title = cover.tagline
      const buf = await api.coverPng(cover.id)
      let imgHtml = '<div class="cell-img"><span style="opacity:.3">🖼️</span></div>'
      if (buf) {
        const url = URL.createObjectURL(new Blob([buf], { type: 'image/png' }))
        imgHtml = `<div class="cell-img"><img src="${url}" alt="${cover.name}" /></div>`
      }
      cell.innerHTML = `${imgHtml}<div class="cell-name"><span>${cover.name}</span><span class="check">✔</span></div>`
      cell.addEventListener('click', () => void selectCover(cover))
      grid.appendChild(cell)
    }
  }
  refreshCoverSelection()
}

function toggleBuiltinList(force?: boolean): void {
  state.builtinOpen = force ?? !state.builtinOpen
  $('cover-list').classList.toggle('hidden', !state.builtinOpen)
  $('builtin-badge').textContent = state.builtinOpen ? '收起列表' : state.cover?.name ?? '11 款'
}

async function selectCover(cover: CoverDef): Promise<void> {
  const buf = await api.coverPng(cover.id)
  if (!buf) {
    setStatus(`❌ 找不到素材文件 ${cover.id}.png`, 'orange')
    return
  }
  const img = new Image()
  img.src = URL.createObjectURL(new Blob([buf], { type: 'image/png' }))
  await img.decode()
  state.cover = cover
  state.coverImage = img
  applyDefaults(defaultsForCover(cover))
  syncEngineSettings()
  refreshCoverSelection()
  setStatus(`已选「${cover.name}」`, 'gray')
}

async function loadCustomImage(file: File): Promise<void> {
  const img = new Image()
  img.src = URL.createObjectURL(file)
  try {
    await img.decode()
  } catch {
    setStatus('❌ 这张图片读不出来', 'orange')
    return
  }
  state.cover = null
  state.coverImage = img
  applyDefaults(defaultsForCover(null))
  syncEngineSettings()
  refreshCoverSelection()
  setStatus('已用自定义图片做脸罩', 'gray')
}

async function clearCover(): Promise<void> {
  state.cover = null
  state.coverImage = null
  syncEngineSettings()
  refreshCoverSelection()
  setStatus('已关闭遮挡，可继续录制原画', 'gray')
}

function applyDefaults(d: { sizeScale: number; offsetX: number; offsetY: number }): void {
  state.defaults = { size: d.sizeScale, x: d.offsetX, y: d.offsetY }
  applySlider('size', d.sizeScale)
  applySlider('x', d.offsetX)
  applySlider('y', d.offsetY)
}

function refreshCoverSelection(): void {
  document.querySelectorAll('.cover-cell').forEach((el) => {
    el.classList.toggle('selected', state.cover !== null && (el as HTMLElement).dataset.id === state.cover.id)
  })
  $('tile-builtin').classList.toggle('selected', state.cover !== null)
  $('tile-custom').classList.toggle('selected', state.cover === null && state.coverImage !== null)
  $('builtin-badge').textContent = state.builtinOpen ? '收起列表' : state.cover?.name ?? '11 款'
  $('custom-badge').textContent = state.cover === null && state.coverImage !== null ? '已启用' : 'PNG / 拖拽'
  $('btn-clear-cover').classList.toggle('hidden', state.coverImage === null)
}

function wireDragDrop(): void {
  const area = $('preview-area')
  area.addEventListener('dragover', (e) => {
    e.preventDefault()
    area.classList.add('dragover')
  })
  area.addEventListener('dragleave', () => area.classList.remove('dragover'))
  area.addEventListener('drop', (e) => {
    e.preventDefault()
    area.classList.remove('dragover')
    const file = e.dataTransfer?.files?.[0]
    if (file && file.type.startsWith('image/')) void loadCustomImage(file)
  })
}

// ---------- 摄像头 ----------

async function startCamera(deviceId?: string): Promise<void> {
  stream?.getTracks().forEach((t) => t.stop())
  const tier = resolutionTier(state.resolution)
  const video: MediaTrackConstraints = cameraConstraints(tier.id, state.fps)
  if (deviceId) video.deviceId = { exact: deviceId }
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: false, video })
    const videoEl = $('camera') as HTMLVideoElement
    videoEl.srcObject = stream
    await videoEl.play()
    await fillCameraList()
    setStatus(state.coverImage ? '已准备好了' : '选个脸罩，或直接开始录制原画', 'gray')
  } catch (err) {
    stream = null
    if (err instanceof DOMException && err.name === 'NotAllowedError') {
      setStatus('❌ 摄像头没有授权。到「系统设置 → 隐私和安全性 → 摄像头」里允许本应用。', 'orange')
    } else if (err instanceof DOMException && err.name === 'NotFoundError') {
      setStatus('还没有检测到摄像头。', 'orange')
    } else {
      setStatus(`❌ 摄像头打开失败：${String(err)}`, 'orange')
    }
  }
}

async function fillCameraList(): Promise<void> {
  const devices = await navigator.mediaDevices.enumerateDevices()
  const cameras = devices.filter((d) => d.kind === 'videoinput')
  const select = $('sel-camera') as HTMLSelectElement
  select.innerHTML = ''
  if (cameras.length === 0) {
    select.innerHTML = '<option value="">还没有检测到摄像头。</option>'
    return
  }
  cameras.forEach((cam, index) => {
    const option = document.createElement('option')
    option.value = cam.deviceId
    option.textContent = cam.label || `摄像头 ${index + 1}`
    select.appendChild(option)
  })
  if (state.cameraDeviceId && cameras.some((c) => c.deviceId === state.cameraDeviceId)) {
    select.value = state.cameraDeviceId
  } else {
    state.cameraDeviceId = cameras[0]!.deviceId
    select.value = state.cameraDeviceId
  }
}

// ---------- 录制质量 ----------

function applyResolution(): void {
  state.resolution = ($('sel-resolution') as HTMLSelectElement).value as ResolutionTierId
  localStorage.setItem('recordingResolution', state.resolution)
  void startCamera(state.cameraDeviceId || undefined)
  updateQualityHint()
}

function applyFrameRate(): void {
  state.fps = Number(($('sel-fps') as HTMLSelectElement).value) as FrameRateId
  localStorage.setItem('recordingFrameRate', String(state.fps))
  void startCamera(state.cameraDeviceId || undefined)
  updateQualityHint()
}

function applyQuality(): void {
  state.quality = ($('sel-quality') as HTMLSelectElement).value as QualityId
  localStorage.setItem('recordingQuality', state.quality)
  updateQualityHint()
}

function syncQualitySelectors(): void {
  ;($('sel-resolution') as HTMLSelectElement).value = state.resolution
  ;($('sel-fps') as HTMLSelectElement).value = String(state.fps)
  ;($('sel-quality') as HTMLSelectElement).value = state.quality
}

function updateQualityHint(): void {
  const tier = resolutionTier(state.resolution)
  const out = outputSize(1920, 1080, state.resolution)
  const mb = estimateMBPerMinute(out.width, out.height, state.fps, state.quality)
  $('quality-hint').textContent = `约 ${mb.toFixed(1)} MB/分钟（估算 · ${tier.label}/${state.fps}fps/${qualityTier(state.quality).label}）· 设置会记住，录制中不可修改`
}

// ---------- 录制 ----------

async function toggleRecording(): Promise<void> {
  if (state.recording) await stopRecording()
  else await startRecording()
}

async function startRecording(): Promise<void> {
  if (!stream || ($('camera') as HTMLVideoElement).readyState < 2) {
    setStatus('摄像头还没准备好，稍等一下再试', 'orange')
    return
  }
  const canvas = $('record-canvas') as HTMLCanvasElement
  // 格式确定性选 webm（mp4 封装器 + 暂停有间歇性 0 字节的坑，见 recorder.ts 注释）
  const format = pickRecordingFormat()
  if (!format) {
    setStatus('❌ 这个环境不支持 MediaRecorder，录不了像', 'orange')
    return
  }

  let audioTracks: MediaStreamTrack[] = []
  if (state.audioSource !== 'none') {
    try {
      await audioGraph.connect(state.audioSource)
      audioTracks = audioGraph.tracks()
    } catch (err) {
      showAudioWarning(audioErrorMessage(state.audioSource, err, true))
    }
  }

  const fileName = makeRecordingFileName(new Date(), format.ext)
  const begin = await api.beginRecording(fileName)
  if (!begin.ok || !begin.path) {
    setStatus(`❌ ${begin.error ?? '建不了录像文件'}`, 'orange')
    await audioGraph.disconnect()
    return
  }
  writingPath = begin.path

  const bitrate = averageBitRate(canvas.width, canvas.height, state.fps, state.quality)
  console.log(`[record] 开录 ${format.mimeType} @ ${canvas.width}×${canvas.height} ${state.fps}fps ${(bitrate / 1e6).toFixed(1)}Mbps，音频轨 ${audioTracks.length} 条`)
  try {
    recorder = startMediaRecorder({
      canvas,
      fps: state.fps,
      videoBitsPerSecond: bitrate,
      audioTracks,
      format,
      onChunk: queueChunk,
    })
  } catch (err) {
    writingPath = null
    void api.endRecording(begin.path)
    await audioGraph.disconnect()
    setStatus(`❌ ${err instanceof Error ? err.message : String(err)}`, 'orange')
    return
  }

  state.recording = true
  state.paused = false
  recordingStartedAt = performance.now()
  pausedAccumMs = 0
  pausedAt = null
  syncEngineSettings()
  updateRecordUI()
  setQualityEnabled(false)
  setStatus(`正在录制（${format.label}）`, 'red')
}

function queueChunk(chunk: Blob): void {
  writeChain = writeChain.then(async () => {
    if (!writingPath) return
    const buffer = await chunk.arrayBuffer()
    chunkBytes += buffer.byteLength
    chunkCount++
    if (chunkCount === 1) console.log(`[record] 第一块 ${buffer.byteLength} 字节落盘`)
    const result = await api.writeChunk(writingPath, buffer)
    if (!result.ok) {
      console.error(`[record] 写盘失败：${result.error}`)
      setStatus(`❌ 写盘失败：${result.error}`, 'orange')
    }
  })
  writeChain.catch((err) => {
    console.error(`[record] 写盘失败：${String(err)}`)
    setStatus(`❌ 写盘失败：${String(err)}`, 'orange')
  })
}

let chunkBytes = 0
let chunkCount = 0

function togglePause(): void {
  if (!state.recording || !recorder) return
  if (state.paused) {
    recorder.resume()
    pausedAccumMs += performance.now() - (pausedAt ?? performance.now())
    pausedAt = null
    state.paused = false
    setStatus('正在录制', 'red')
  } else {
    recorder.pause()
    pausedAt = performance.now()
    state.paused = true
    setStatus('已暂停', 'orange')
  }
  updateRecordUI()
}

async function stopRecording(): Promise<void> {
  const handle = recorder
  const path = writingPath
  recorder = null
  writingPath = null
  // 时长要在清状态前取（UI 计时 = 排除暂停的文件时间线，正好是元数据该写的数）
  const durationMs = recordedSeconds() * 1000
  state.recording = false
  state.paused = false

  if (handle && path) {
    await handle.stop()
    await writeChain
    writeChain = Promise.resolve()
    console.log(`[record] 录制结束：${chunkCount} 块，共 ${chunkBytes} 字节`)
    chunkBytes = 0
    chunkCount = 0
    const end = await api.endRecording(path)
    await audioGraph.disconnect()
    setQualityEnabled(true)
    updateRecordUI()
    const fileName = path.split(/[\\/]/).pop() ?? path
    if (end.ok) {
      // webm 直播写入没有时长元数据（播放器进度条会坏），补上
      await fixWebmMetadata(path, durationMs)
      setStatus(`✅ 已保存 ${fileName}`, 'green')
      showSavedDialog(fileName, end.sizeBytes ?? 0)
    } else {
      setStatus(`❌ 保存失败：${end.error}`, 'orange')
    }
  } else {
    await audioGraph.disconnect()
    setQualityEnabled(true)
    updateRecordUI()
  }
}

// ---------- webm 时长元数据修复 ----------

let fixWebmFn: ((blob: Blob, durationMs: number) => Promise<Blob>) | null = null

async function loadFixWebm(): Promise<void> {
  try {
    const source = await api.fixWebmSource()
    if (!source) return
    const script = document.createElement('script')
    script.src = URL.createObjectURL(new Blob([source], { type: 'text/javascript' }))
    document.head.appendChild(script)
    await new Promise<void>((resolve) => {
      script.onload = () => resolve()
      script.onerror = () => resolve()
    })
    fixWebmFn = (window as unknown as { ysFixWebmDuration?: (blob: Blob, durationMs: number) => Promise<Blob> }).ysFixWebmDuration ?? null
  } catch {
    /* 修不了时长也能用，只是进度条不显示 */
  }
}

const MAX_FIX_SIZE = 500_000_000

async function fixWebmMetadata(filePath: string, durationMs: number): Promise<void> {
  try {
    if (!fixWebmFn) return
    const read = await api.readRecordingFile(filePath)
    if (!read.ok || !read.data) {
      console.error('[record] 读不回录像文件，跳过时长修复：', read.error)
      return
    }
    if (read.data.byteLength > MAX_FIX_SIZE) {
      console.log('[record] 文件太大，跳过时长修复')
      return
    }
    const fixed = await fixWebmFn(new Blob([read.data], { type: 'video/webm' }), durationMs)
    const buffer = await fixed.arrayBuffer()
    const write = await api.writeRecordingFile(filePath, buffer)
    if (write.ok) console.log(`[record] 时长元数据已修复：${(durationMs / 1000).toFixed(1)}s`)
    else console.error('[record] 时长修复写回失败：', write.error)
  } catch (err) {
    console.error('[record] 时长修复失败（文件本身不受影响）：', String(err))
  }
}

function showSavedDialog(fileName: string, sizeBytes: number): void {
  const dialog = $('saved-dialog') as HTMLDialogElement
  dialog.dataset.fileName = fileName
  $('saved-content').textContent = `${fileName}\n${sizeText(sizeBytes)}`
  dialog.showModal()
}

function setQualityEnabled(enabled: boolean): void {
  for (const id of ['sel-resolution', 'sel-fps', 'sel-quality']) {
    ($(id) as HTMLSelectElement).disabled = !enabled
  }
}

function updateRecordUI(): void {
  const btn = $('btn-record')
  btn.classList.toggle('recording', state.recording)
  $('record-label').textContent = state.recording ? '停止录制' : '开始录制'
  $('record-icon').textContent = state.recording ? '⏹' : '⏺'
  $('btn-pause').classList.toggle('hidden', !state.recording)
  const pauseBtn = $('btn-pause')
  pauseBtn.textContent = state.paused ? '▶' : '⏸'
  pauseBtn.classList.toggle('paused', state.paused)
  pauseBtn.title = state.paused ? '继续录制（Shift+Ctrl+P）' : '暂停录制（Shift+Ctrl+P）'
}

// ---------- 状态显示 ----------

function setStatus(message: string, dot: 'gray' | 'red' | 'orange' | 'green'): void {
  $('status-message').textContent = message
  const dotEl = $('status-dot')
  dotEl.className = 'dot'
  if (message.startsWith('❌')) dotEl.classList.add('orange')
  else if (message.startsWith('✅')) dotEl.classList.add('green')
  else dotEl.classList.add(dot)
}

function showAudioWarning(text: string): void {
  $('audio-warning-text').textContent = text
  $('audio-warning').classList.add('show')
}

function hideAudioWarning(): void {
  $('audio-warning').classList.remove('show')
}

function recordedSeconds(): number {
  if (!state.recording) return 0
  const now = performance.now()
  return Math.max(0, ((state.paused ? pausedAt ?? now : now) - recordingStartedAt - pausedAccumMs) / 1000)
}

function updateBadge(): void {
  const badge = $('status-badge')
  const textEl = badge.querySelector('.badge-text') as HTMLElement
  const dotEl = badge.querySelector('.dot') as HTMLElement
  const set = (cls: string, text: string): void => {
    badge.className = `badge ${cls}`
    void dotEl
    textEl.textContent = text
  }
  if (state.recording && state.paused) set('orange', `已暂停 ${elapsedText(recordedSeconds())}`)
  else if (state.recording) set('red', `录制中 ${elapsedText(recordedSeconds())}`)
  else if (!state.coverImage) set('gray', '原画模式')
  else if ((engine?.lastStats()?.faces.length ?? 0) > 0) set('green', '已准备好了')
  else set('orange', '未检测到人脸（可继续录制）')
}

function onEngineStats(_stats: EngineStats): void {
  // 徽章由 250ms 定时器刷新；这里留作逐帧扩展点
}

// ---------- 诊断 ----------

function writeDiagnosticLine(): void {
  if (!stream || !engine) return
  const stats = engine.lastStats()
  if (!stats) return
  const s = engine.settings
  const stateText = !s.coverImage
    ? '未检测（未选脸罩）'
    : !s.trackingEnabled
      ? '未检测（已关闭跟随）'
      : `${stats.faces.length} 张`
  const list = stats.faces.map((f) => `#${f.id}:x=${f.cx.toFixed(3)}`).join(',')
  let line = `人脸=${stateText} [${list}]`
  const primary = stats.faces[0]
  if (primary && stats.primaryOverlayCenter) {
    line +=
      ` | 主脸中心=(${primary.cx.toFixed(3)},${primary.cy.toFixed(3)})` +
      ` 脸框=${primary.w.toFixed(3)}×${primary.h.toFixed(3)}` +
      ` 贴图中心=(${stats.primaryOverlayCenter.x.toFixed(3)},${stats.primaryOverlayCenter.y.toFixed(3)})` +
      ` 缩放=${s.sizeScale.toFixed(2)}×脸宽`
  }
  line += ` | 镜像=${s.mirror ? '开' : '关'} | 检测间隔=${stats.detectEvery}帧`
  void api.diag(line)
}

// ---------- 无人值守端到端自检（--smoke 启动时跑，假摄像头，无需真人操作） ----------
//
// 链路：选脸罩 → 开录 → 2s → 暂停 3s → 恢复 2s → 停止 →
// 校验落盘（endRecording ok、大小 > 0、文件出现在录像库扫描里）。
// 全程 console 输出 [smoke]，失败立即 FAIL 并关窗退出（主进程 window-all-closed → quit）。

const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms))

function fileUrl(path: string): string {
  return 'file://' + path.replace(/\\/g, '/').split('/').map(encodeURIComponent).join('/')
}

function probeFileDuration(path: string): Promise<number> {
  return new Promise((resolve) => {
    const video = document.createElement('video')
    video.preload = 'metadata'
    video.muted = true
    let settled = false
    const finish = (v: number): void => {
      if (settled) return
      settled = true
      video.removeAttribute('src')
      video.load()
      resolve(v)
    }
    setTimeout(() => finish(-1), 6000)
    video.addEventListener('loadedmetadata', () => finish(Number.isFinite(video.duration) ? video.duration : -1))
    video.addEventListener('error', () => finish(-1))
    video.src = fileUrl(path)
  })
}

async function runSmoke(): Promise<void> {
  const results: string[] = []
  const check = (name: string, ok: boolean, detail = ''): void => {
    results.push(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`)
    console.log(`[smoke] ${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`)
  }

  try {
    // 1. 等摄像头出帧
    const video = $('camera') as HTMLVideoElement
    let ready = false
    for (let i = 0; i < 30; i++) {
      if (stream && video.readyState >= 2 && video.videoWidth > 0) {
        ready = true
        break
      }
      await sleep(500)
    }
    check('摄像头出帧', ready, ready ? `${video.videoWidth}×${video.videoHeight}` : '超时 15s')

    // 2. 选一款头套（假摄像头没有真脸，跟踪链路照样跑）
    await selectCover(ALL_COVERS[0]!)
    await sleep(1500)
    check('脸罩已加载', state.coverImage !== null, state.cover?.id ?? '')

    // 3. 录制：2s → 暂停 3s → 恢复 2s → 停止
    await startRecording()
    check('开始录制', state.recording)
    await sleep(2000)
    togglePause()
    check('已暂停', state.paused)
    await sleep(3000)
    togglePause()
    check('已恢复', state.recording && !state.paused)
    await sleep(2000)
    await stopRecording()
    check('停止录制', !state.recording)

    // 4. 校验落盘
    const scan = await api.scanRecordings()
    const names = scan.map((e) => e.name)
    const saved = names.find((n) => n.startsWith('FaceCover-'))
    check('文件出现在录像库', !!saved, saved ?? '目录为空')
    if (saved) {
      const entry = scan.find((e) => e.name === saved)!
      check('文件非空', entry.sizeBytes > 1000, `${sizeText(entry.sizeBytes)}（含 5s 有效画面 + 暂停被扣除）`)
    }

    // 5. 录像库窗口：打开 + 定位高亮（窗口自己的扫描结果看 [library] 日志）
    if (saved) {
      // 5.1 时长断言：2s 开头 + 2s 结尾，暂停 3s 必须被排除 → 约 4s
      const entry = scan.find((e) => e.name === saved)!
      const duration = await probeFileDuration(entry.path)
      check('时长≈4s（暂停已排除）', duration > 3 && duration < 6.5, duration > 0 ? `${duration.toFixed(1)}s` : '读不到时长')

      // 5.2 打开录像库并定位
      await api.openLibraryWithHighlight(saved)
      await sleep(2500)
    }

    console.log(`[smoke] ===== 汇总：${results.filter((r) => r.startsWith('PASS')).length}/${results.length} 通过 =====`)
  } catch (err) {
    console.log(`[smoke] FAIL 异常 — ${String(err)}`)
  } finally {
    window.close()
  }
}
