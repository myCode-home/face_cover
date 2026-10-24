// 逐帧管线：镜像整帧 → 人脸检测 → 贴图合成 → 调试框（仅预览）。
// 顺序对齐 macOS 版 CameraEngine.handleVideo：镜像必须发生在检测之前，
// 调试框必须发生在「要写文件的那帧」之后 —— 这里录制流直接取 recordCanvas，
// 调试框画在独立的 debugCanvas 上，物理上进不了视频。
//
// 与 macOS 版的差异（平台特性，行为等价）：
//  1. 检测用 YuNet（主线程同步，见 detector.ts），耗时计入检测节奏迟滞；
//  2. 时间基用 performance.now()/1000（单调时钟），不需要 RecordingTimeline：
//     MediaRecorder.pause() 已把暂停时长排除出文件时间线。

import { FaceObservation, MultiFaceTracker, TrackedFace } from '../core/tracker.js'
import { AnchorSpec, CoverDef } from '../core/covers.js'
import { YuNetDetector } from './detector.js'
import { api } from '../api.js'

export interface EngineSettings {
  coverImage: HTMLImageElement | null
  cover: CoverDef | null
  anchor: AnchorSpec | null
  trackingEnabled: boolean
  sizeScale: number
  offsetX: number
  offsetY: number
  mirror: boolean
  showDebugBox: boolean
}

export interface FaceSnapshot {
  id: number
  cx: number
  cy: number
  w: number
  h: number
}

export interface EngineStats {
  /** 本帧贴图用的所有人脸（归一化，屏幕坐标） */
  faces: FaceSnapshot[]
  /** 主脸（第一条轨迹）的贴图中心，供诊断行 */
  primaryOverlayCenter: { x: number; y: number } | null
  sizeScale: number
  detectEvery: number
  detectorReady: boolean
  detectorError: string | null
}

const DETECT_WIDTH = 320
const MAX_FACES = 12
// 检测节奏迟滞（照抄 CameraEngine）：EMA >20ms 连续 20 帧降为隔帧，<10ms 连续 60 帧恢复
const SLOW_COST = 0.02
const FAST_COST = 0.01
const SLOW_STREAK_LIMIT = 20
const FAST_STREAK_LIMIT = 60
// macOS 版关闭跟随时的固定贴图位（归一化 BL 0.375,0.52,0.25,0.25 → TL）
const FALLBACK_FACE = { cx: 0.5, cy: 0.355, w: 0.25, h: 0.25 }

export class CompositionEngine {
  settings: EngineSettings

  private readonly video: HTMLVideoElement
  private readonly recordCanvas: HTMLCanvasElement
  private readonly debugCanvas: HTMLCanvasElement
  private readonly workCanvas: HTMLCanvasElement
  private readonly detCanvas: HTMLCanvasElement
  private readonly recordCtx: CanvasRenderingContext2D
  private readonly debugCtx: CanvasRenderingContext2D
  private readonly workCtx: CanvasRenderingContext2D
  private readonly detCtx: CanvasRenderingContext2D

  private readonly detector = new YuNetDetector()
  private readonly multi = new MultiFaceTracker()

  private detectInFlight = false
  private pending: { faces: FaceObservation[]; sentAt: number } | null = null
  private detectSentAt = 0

  private frameCounter = 0
  private detectEvery = 1
  private visionCost = 0
  private slowStreak = 0
  private fastStreak = 0
  private lastAppliedMirror: boolean | null = null
  private running = false
  private latestStats: EngineStats | null = null

  onStats: ((stats: EngineStats) => void) | null = null

  constructor(video: HTMLVideoElement, recordCanvas: HTMLCanvasElement, debugCanvas: HTMLCanvasElement) {
    this.video = video
    this.recordCanvas = recordCanvas
    this.debugCanvas = debugCanvas
    this.settings = {
      coverImage: null,
      cover: null,
      anchor: null,
      trackingEnabled: true,
      sizeScale: 1.5,
      offsetX: 0,
      offsetY: 0,
      mirror: true,
      showDebugBox: false,
    }
    this.recordCanvas.width = 2
    this.recordCanvas.height = 2
    this.debugCanvas.width = 2
    this.debugCanvas.height = 2
    this.workCanvas = document.createElement('canvas')
    this.detCanvas = document.createElement('canvas')
    this.recordCtx = recordCanvas.getContext('2d')!
    this.debugCtx = debugCanvas.getContext('2d')!
    this.workCtx = this.workCanvas.getContext('2d')!
    this.detCtx = this.detCanvas.getContext('2d', { willReadFrequently: true })!
  }

  /** 加载检测器（失败不致命：退化为「不跟随」，界面照常预览/录制） */
  async initDetector(): Promise<void> {
    const [ortWasm, ortMjs, model] = await Promise.all([api.ortWasm(), api.ortMjs(), api.modelOnnx()])
    if (!ortWasm || !ortMjs) throw new Error('找不到 onnxruntime-web 的运行时文件')
    if (!model) throw new Error('找不到 YuNet 模型文件')
    await this.detector.init(ortWasm, ortMjs, model)
  }

  start(): void {
    if (this.running) return
    this.running = true
    const loop = (): void => {
      if (!this.running) return
      this.processFrame()
      this.video.requestVideoFrameCallback(loop)
    }
    this.video.requestVideoFrameCallback(loop)
  }

  stop(): void {
    this.running = false
  }

  resetTracking(): void {
    this.multi.reset()
  }

  private processFrame(): void {
    const video = this.video
    const w = video.videoWidth
    const h = video.videoHeight
    if (!w || !h) return
    const s = this.settings
    const t = performance.now() / 1000
    this.frameCounter++

    // 方向变了先断轨迹：检测和贴图必须发生在最终方向的画面上
    if (this.lastAppliedMirror !== s.mirror) {
      this.multi.reset()
      this.lastAppliedMirror = s.mirror
    }

    // 1. 镜像整帧（只翻这一次）
    this.ensureSize(this.workCanvas, w, h)
    this.workCtx.save()
    if (s.mirror) {
      this.workCtx.translate(w, 0)
      this.workCtx.scale(-1, 1)
    }
    this.workCtx.drawImage(video, 0, 0, w, h)
    this.workCtx.restore()

    // 2. 检测：上一帧的结果若已回来，先当本帧测量；然后按节奏派发新一轮
    const detectEnabled = !!s.coverImage && s.trackingEnabled && this.detector.ready
    let observations: FaceObservation[] | null = null
    if (this.pending) {
      const { faces, sentAt } = this.pending
      this.pending = null
      this.detectInFlight = false
      // 节奏迟滞只看纯推理耗时（lastMs），排队/一帧延迟不算进去
      this.updateCadence(this.detector.lastMs / 1000)
      observations = faces
    }
    if (detectEnabled && !this.detectInFlight && this.frameCounter % this.detectEvery === 0) {
      const dw = Math.min(DETECT_WIDTH, w)
      const dh = Math.max(1, Math.round((dw * h) / w))
      this.ensureSize(this.detCanvas, dw, dh)
      this.detCtx.drawImage(this.workCanvas, 0, 0, dw, dh)
      const pixels = this.detCtx.getImageData(0, 0, dw, dh)
      this.detectInFlight = true
      this.detectSentAt = t
      this.detector
        .detect(pixels)
        .then((faces) => {
          this.pending = {
            faces: faces.slice(0, MAX_FACES).map((f) => ({ box: { cx: f.cx, cy: f.cy, w: f.w, h: f.h }, roll: f.roll })),
            sentAt: this.detectSentAt,
          }
        })
        .catch(() => {
          this.pending = { faces: [], sentAt: this.detectSentAt }
        })
    }

    // 3. 跟踪
    let tracked: TrackedFace[] = []
    if (s.coverImage && s.trackingEnabled) {
      tracked = this.multi.update(observations, t)
    } else {
      this.multi.reset()
    }

    // 4. 合成进 recordCanvas（这层进录制流）
    this.ensureSize(this.recordCanvas, w, h)
    this.recordCtx.drawImage(this.workCanvas, 0, 0)
    const stats: EngineStats = {
      faces: [],
      primaryOverlayCenter: null,
      sizeScale: s.sizeScale,
      detectEvery: this.detectEvery,
      detectorReady: this.detector.ready,
      detectorError: this.detector.error,
    }
    if (s.coverImage) {
      if (s.trackingEnabled && tracked.length > 0) {
        for (const face of tracked) {
          const px = { cx: face.box.cx * w, cy: face.box.cy * h, w: face.box.w * w, h: face.box.h * h }
          this.drawOverlay(this.recordCtx, s.coverImage, px, face.roll, s.sizeScale, s.offsetX, s.offsetY)
          stats.faces.push({ id: face.id, cx: face.box.cx, cy: face.box.cy, w: face.box.w, h: face.box.h })
        }
        const p = tracked[0]!
        // 诊断行用的「贴图中心」，公式与合成一致：x + offsetX×脸宽、y + offsetY×脸高（屏幕坐标正=向下）
        stats.primaryOverlayCenter = {
          x: p.box.cx + s.offsetX * p.box.w,
          y: p.box.cy + s.offsetY * p.box.h,
        }
      } else if (!s.trackingEnabled) {
        // 关跟随：固定位置贴一张，不旋转
        this.drawOverlay(
          this.recordCtx,
          s.coverImage,
          { cx: FALLBACK_FACE.cx * w, cy: FALLBACK_FACE.cy * h, w: FALLBACK_FACE.w * w, h: FALLBACK_FACE.h * h },
          0,
          s.sizeScale,
          s.offsetX,
          s.offsetY,
        )
        stats.primaryOverlayCenter = {
          x: FALLBACK_FACE.cx + s.offsetX * FALLBACK_FACE.w,
          y: FALLBACK_FACE.cy + s.offsetY * FALLBACK_FACE.h,
        }
      }
      // 开跟随但这帧没脸：什么都不贴 —— macOS 版是贴在最后识别的位置悬空，
      // 这里轨迹已经自带 0.35s 宽限 + 外推，宽限过后自然停贴
    }

    // 5. 调试框：独立 canvas，绝不进录制流
    this.drawDebugBoxes(w, h, tracked)

    if ((this.frameCounter & 0xff) === 1) {
      console.log(`[engine] 帧 ${this.frameCounter}：画布 ${w}×${h}，脸 ${tracked.length} 张，检测间隔 ${this.detectEvery}`)
    }

    this.latestStats = stats
    this.onStats?.(stats)
  }

  private updateCadence(cost: number): void {
    this.visionCost = this.visionCost === 0 ? cost : this.visionCost * 0.9 + cost * 0.1
    if (this.visionCost > SLOW_COST) {
      this.slowStreak++
      this.fastStreak = 0
    } else if (this.visionCost < FAST_COST) {
      this.fastStreak++
      this.slowStreak = 0
    } else {
      this.slowStreak = 0
      this.fastStreak = 0
    }
    if (this.detectEvery === 1 && this.slowStreak >= SLOW_STREAK_LIMIT) this.detectEvery = 2
    else if (this.detectEvery === 2 && this.fastStreak >= FAST_STREAK_LIMIT) this.detectEvery = 1
  }

  private lastTrackedForDebug: TrackedFace[] = []

  private drawDebugBoxes(w: number, h: number, tracked: TrackedFace[]): void {
    const s = this.settings
    if (!s.showDebugBox) {
      if (this.debugCanvas.width !== 2) {
        this.debugCanvas.width = 2
        this.debugCanvas.height = 2
      }
      return
    }
    this.ensureSize(this.debugCanvas, w, h)
    const ctx = this.debugCtx
    ctx.clearRect(0, 0, w, h)
    const lineWidth = Math.max(2, w / 320)

    if (!s.coverImage) {
      // 没贴图只画绿框（macOS 版行为）
      for (const face of tracked) {
        ctx.strokeStyle = 'rgba(0, 255, 102, 1)'
        ctx.lineWidth = lineWidth
        ctx.strokeRect((face.box.cx - face.box.w / 2) * w, (face.box.cy - face.box.h / 2) * h, face.box.w * w, face.box.h * h)
      }
      this.lastTrackedForDebug = tracked
      return
    }
    const faces: TrackedFace[] = tracked.length > 0 ? tracked : this.lastTrackedForDebug
    for (const face of faces) {
      const fx = (face.box.cx - face.box.w / 2) * w
      const fy = (face.box.cy - face.box.h / 2) * h
      const fw = face.box.w * w
      const fh = face.box.h * h

      // 绿框：检测到的人脸框（贴图按它的中心和宽度算）+ 中心十字准星
      ctx.strokeStyle = 'rgba(0, 255, 102, 1)'
      ctx.lineWidth = lineWidth
      ctx.strokeRect(fx, fy, fw, fh)
      ctx.beginPath()
      ctx.moveTo(face.box.cx * w - lineWidth * 4, face.box.cy * h)
      ctx.lineTo(face.box.cx * w + lineWidth * 4, face.box.cy * h)
      ctx.moveTo(face.box.cx * w, face.box.cy * h - lineWidth * 4)
      ctx.lineTo(face.box.cx * w, face.box.cy * h + lineWidth * 4)
      ctx.stroke()

      // 品红框：贴图实际范围
      const target = overlayTargetRect(
        { cx: face.box.cx * w, cy: face.box.cy * h, w: face.box.w * w, h: face.box.h * h },
        s.coverImage,
        s.sizeScale,
        s.offsetX,
        s.offsetY,
      )
      ctx.strokeStyle = 'rgba(255, 64, 217, 1)'
      ctx.strokeRect(target.x, target.y, target.w, target.h)

      // 青框：素材锚点（头套=面孔开口，mask=整颗头轮廓）
      if (s.anchor) {
        const aw = s.anchor.widthFraction * target.w
        const ah = s.anchor.heightFraction * target.w
        const ax = target.x + target.w / 2 + s.anchor.offsetX * target.w - aw / 2
        const ay = target.y + target.h / 2 + s.anchor.offsetY * target.w - ah / 2
        ctx.strokeStyle = 'rgba(64, 217, 255, 1)'
        ctx.strokeRect(ax, ay, aw, ah)
        // 人脸中心 → 锚点中心连线
        ctx.strokeStyle = 'rgba(64, 217, 255, 0.6)'
        ctx.lineWidth = Math.max(1, lineWidth / 2)
        ctx.beginPath()
        ctx.moveTo(face.box.cx * w, face.box.cy * h)
        ctx.lineTo(ax + aw / 2, ay + ah / 2)
        ctx.stroke()
      }
    }
    this.lastTrackedForDebug = tracked
  }

  private drawOverlay(
    ctx: CanvasRenderingContext2D,
    img: HTMLImageElement,
    face: { cx: number; cy: number; w: number; h: number },
    roll: number,
    sizeScale: number,
    offsetX: number,
    offsetY: number,
  ): void {
    const target = overlayTargetRect(face, img, sizeScale, offsetX, offsetY)
    ctx.save()
    ctx.translate(target.x + target.w / 2, target.y + target.h / 2)
    ctx.rotate(roll)
    ctx.drawImage(img, -target.w / 2, -target.h / 2, target.w, target.h)
    ctx.restore()
  }

  private ensureSize(canvas: HTMLCanvasElement, w: number, h: number): void {
    if (canvas.width !== w || canvas.height !== h) {
      canvas.width = w
      canvas.height = h
    }
  }

  lastStats(): EngineStats | null {
    return this.latestStats
  }
}

/** 贴图目标矩形（屏幕坐标）。offsetX 正=右，offsetY 正=下。 */
export function overlayTargetRect(
  face: { cx: number; cy: number; w: number; h: number },
  img: { naturalWidth: number; naturalHeight: number },
  sizeScale: number,
  offsetX: number,
  offsetY: number,
): { x: number; y: number; w: number; h: number } {
  const targetW = face.w * sizeScale
  const targetH = (targetW * img.naturalHeight) / img.naturalWidth
  const cx = face.cx + offsetX * face.w
  const cy = face.cy + offsetY * face.h
  return { x: cx - targetW / 2, y: cy - targetH / 2, w: targetW, h: targetH }
}
