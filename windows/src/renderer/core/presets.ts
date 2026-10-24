// 录制质量档位。数值与 macOS 版 Recorder.swift 一致。
// 分辨率是「上限」语义：输出保持摄像头宽高比，达不到所选尺寸不放大。

export type ResolutionTierId = 'p480' | 'p720' | 'p1080'
export type FrameRateId = 15 | 24 | 30
export type QualityId = 'compact' | 'standard' | 'high'

export interface ResolutionTier {
  id: ResolutionTierId
  label: string
  /** 短边上限（像素） */
  maxShortEdge: number
  /** getUserMedia 请求高度（横屏摄像头短边=高度） */
  requestHeight: number
}

export const RESOLUTION_TIERS: ResolutionTier[] = [
  { id: 'p480', label: '480p', maxShortEdge: 480, requestHeight: 480 },
  { id: 'p720', label: '720p', maxShortEdge: 720, requestHeight: 720 },
  { id: 'p1080', label: '1080p', maxShortEdge: 1080, requestHeight: 1080 },
]

export const DEFAULT_RESOLUTION: ResolutionTierId = 'p720'
export const FRAME_RATES: FrameRateId[] = [15, 24, 30]
export const DEFAULT_FRAME_RATE: FrameRateId = 24

export interface QualityTier {
  id: QualityId
  label: string
  /** 720p/30fps 基准码率（bit/s） */
  baseBitRate: number
}

export const QUALITY_TIERS: QualityTier[] = [
  { id: 'compact', label: '省空间', baseBitRate: 1_200_000 },
  { id: 'standard', label: '标准', baseBitRate: 2_500_000 },
  { id: 'high', label: '高画质', baseBitRate: 4_500_000 },
]

export const DEFAULT_QUALITY: QualityId = 'standard'

export function resolutionTier(id: ResolutionTierId): ResolutionTier {
  return RESOLUTION_TIERS.find((t) => t.id === id) ?? RESOLUTION_TIERS[1]!
}

export function qualityTier(id: QualityId): QualityTier {
  return QUALITY_TIERS.find((t) => t.id === id) ?? QUALITY_TIERS[1]!
}

/**
 * 输出尺寸：保持源宽高比、不放大、H.264 要求宽高为偶数（四舍五入到最近偶数）。
 * 与 macOS Recorder.outputSize 一致。
 */
export function outputSize(srcW: number, srcH: number, tierId: ResolutionTierId): { width: number; height: number } {
  const tier = resolutionTier(tierId)
  const scale = Math.min(1, tier.maxShortEdge / Math.min(srcW, srcH))
  const even = (v: number): number => Math.max(2, Math.round((v * scale) / 2) * 2)
  return { width: even(srcW), height: even(srcH) }
}

/** 码率：基准（720p/30）按像素数与帧率线性缩放，clamp 0.5–20M 后取整到 10 万。 */
export function averageBitRate(width: number, height: number, fps: FrameRateId, qualityId: QualityId): number {
  const base = qualityTier(qualityId).baseBitRate
  const scaled = (base * (width * height)) / (1280 * 720) * (fps / 30)
  const clamped = Math.min(20_000_000, Math.max(500_000, scaled))
  return Math.round(clamped / 100_000) * 100_000
}

/** 界面上的「约 X MB/分钟」估算：视频码率折算 + 音频按 1MB/分钟。 */
export function estimateMBPerMinute(width: number, height: number, fps: FrameRateId, qualityId: QualityId): number {
  return (averageBitRate(width, height, fps, qualityId) * 60) / 8 / 1_000_000 + 1
}

/** 摄像头约束：目标档位高度 + 帧率上限（达不到时浏览器自行取最近档，不放大）。 */
export function cameraConstraints(tierId: ResolutionTierId, fps: FrameRateId): MediaStreamConstraints {
  const tier = resolutionTier(tierId)
  return {
    audio: false,
    video: {
      width: { ideal: tier.requestHeight * (16 / 9) },
      height: { ideal: tier.requestHeight },
      frameRate: { ideal: fps, max: fps },
    },
  }
}
