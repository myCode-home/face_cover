import { describe, expect, it } from 'vitest'
import {
  averageBitRate,
  estimateMBPerMinute,
  outputSize,
  resolutionTier,
  RESOLUTION_TIERS,
  qualityTier,
  QUALITY_TIERS,
  DEFAULT_RESOLUTION,
  DEFAULT_FRAME_RATE,
  DEFAULT_QUALITY,
} from '../src/renderer/core/presets'

describe('outputSize（上限语义 + 偶数取整）', () => {
  it('1920×1080 源选 720p → 1280×720', () => {
    expect(outputSize(1920, 1080, 'p720')).toEqual({ width: 1280, height: 720 })
  })
  it('摄像头达不到所选档不放大：640×480 选 720p → 640×480', () => {
    expect(outputSize(640, 480, 'p720')).toEqual({ width: 640, height: 480 })
  })
  it('保持宽高比：1280×960 选 720p → 960×720', () => {
    expect(outputSize(1280, 960, 'p720')).toEqual({ width: 960, height: 720 })
  })
  it('H.264 偶数取整：奇数尺寸落到最近偶数', () => {
    const size = outputSize(1281, 721, 'p1080')
    expect(size.width % 2).toBe(0)
    expect(size.height % 2).toBe(0)
  })
  it('竖屏源保持竖屏：短边不超过上限，长边原样', () => {
    // 720×1280 短边=720，已在 720p 上限内 → 不缩放
    expect(outputSize(720, 1280, 'p720')).toEqual({ width: 720, height: 1280 })
    // 1080×1920 短边=1080 超上限 → 缩到 720×1280
    expect(outputSize(1080, 1920, 'p720')).toEqual({ width: 720, height: 1280 })
  })
})

describe('码率表（基准 × 像素 × fps，clamp 0.5–20M，取整 10 万）', () => {
  it('720p/30 三个画质档', () => {
    expect(averageBitRate(1280, 720, 30, 'compact')).toBe(1_200_000)
    expect(averageBitRate(1280, 720, 30, 'standard')).toBe(2_500_000)
    expect(averageBitRate(1280, 720, 30, 'high')).toBe(4_500_000)
  })
  it('1080p/30 按像素 2.25 倍缩放', () => {
    expect(averageBitRate(1920, 1080, 30, 'compact')).toBe(2_700_000)
    expect(averageBitRate(1920, 1080, 30, 'standard')).toBe(5_600_000)
    expect(averageBitRate(1920, 1080, 30, 'high')).toBe(10_100_000)
  })
  it('24fps 按帧率 0.8 缩放', () => {
    expect(averageBitRate(1280, 720, 24, 'compact')).toBe(1_000_000)
  })
  it('低档位触底 clamp 500k（以 Recorder.swift 公式为准：四舍五入到 10 万）', () => {
    expect(averageBitRate(854, 480, 15, 'compact')).toBe(500_000)
    // 2,500,000 × (854×480)/(1280×720) × 15/30 = 556,086 → 四舍五入 600,000
    expect(averageBitRate(854, 480, 15, 'standard')).toBe(600_000)
  })
  it('估算 MB/分钟 = 码率折算 + 1MB 音频', () => {
    expect(estimateMBPerMinute(1280, 720, 24, 'standard')).toBeCloseTo((2_000_000 * 60) / 8 / 1e6 + 1, 5)
  })
})

describe('档位目录', () => {
  it('分辨率三档、画质三档、帧率三档', () => {
    expect(RESOLUTION_TIERS.map((t) => t.id)).toEqual(['p480', 'p720', 'p1080'])
    expect(QUALITY_TIERS.map((t) => t.id)).toEqual(['compact', 'standard', 'high'])
    expect(resolutionTier(DEFAULT_RESOLUTION).maxShortEdge).toBe(720)
    expect(qualityTier(DEFAULT_QUALITY).baseBitRate).toBe(2_500_000)
    expect(DEFAULT_FRAME_RATE).toBe(24)
  })
})
