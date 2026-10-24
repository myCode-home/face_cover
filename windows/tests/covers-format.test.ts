import { describe, expect, it } from 'vitest'
import {
  ALL_COVERS,
  COVER_ANCHORS,
  COVER_DEFAULTS,
  coverById,
  defaultsForCover,
  HOODS,
  MASKS,
  type CoverDef,
} from '../src/renderer/core/covers'
import { durationText, makeRecordingFileName, offsetText, scaleText, sizeText, createdAtText, elapsedText, diagnosticTimestamp } from '../src/renderer/core/format'

describe('脸罩目录（对齐 Tests/Cover：目录与素材一一对应的守卫）', () => {
  it('11 款 = 7 头套 + 4 整脸覆盖，id 唯一', () => {
    expect(HOODS).toHaveLength(7)
    expect(MASKS).toHaveLength(4)
    expect(ALL_COVERS).toHaveLength(11)
    expect(new Set(ALL_COVERS.map((c) => c.id)).size).toBe(11)
  })

  it('每款都有锚点规格，占比在合理范围', () => {
    for (const cover of ALL_COVERS) {
      const anchor = COVER_ANCHORS[cover.id]
      expect(anchor, cover.id).toBeTruthy()
      if (cover.kind === 'hood') {
        // 归一化规格：开口宽 336/1024、开口正居中
        expect(anchor!.widthFraction).toBeCloseTo(336 / 1024, 4)
        expect(anchor!.offsetX).toBeCloseTo(0, 4)
        expect(anchor!.offsetY).toBeCloseTo(0, 4)
        expect(anchor!.heightFraction).toBeGreaterThan(0.2)
        expect(anchor!.heightFraction).toBeLessThan(0.4)
      } else {
        // 轮廓包围盒 ~963/1024，中心接近画布中心
        expect(anchor!.widthFraction).toBeGreaterThan(0.9)
        expect(anchor!.widthFraction).toBeLessThan(1.0)
        expect(Math.abs(anchor!.offsetX)).toBeLessThan(0.01)
        // 实测最大是泰迪熊 0.5-0.471 = 0.029（轮廓重心略偏下）
        expect(Math.abs(anchor!.offsetY)).toBeLessThan(0.05)
      }
    }
  })

  it('默认参数：头套 2.47 / mask 1.59 / 自定义 1.5，内置上移 0.20', () => {
    expect(COVER_DEFAULTS.hoodSizeScale).toBeCloseTo(2.4686, 3)
    expect(COVER_DEFAULTS.maskSizeScale).toBeCloseTo(1.5949, 3)
    const hood: CoverDef = HOODS[0]!
    const mask: CoverDef = MASKS[0]!
    expect(defaultsForCover(hood).offsetY).toBeCloseTo(-0.2, 5)
    expect(defaultsForCover(mask).offsetY).toBeCloseTo(-0.2, 5)
    expect(defaultsForCover(null).offsetY).toBe(0)
    expect(defaultsForCover(hood).sizeScale).toBeCloseTo(2.4686, 3)
    expect(defaultsForCover(mask).sizeScale).toBeCloseTo(1.5949, 3)
    expect(coverById('Cover-Teddy')?.kind).toBe('mask')
  })
})

describe('格式化', () => {
  it('时长文本', () => {
    expect(durationText(undefined)).toBe('时长未知')
    expect(durationText(0)).toBe('时长未知')
    expect(durationText(45)).toBe('45 秒')
    expect(durationText(61)).toBe('1 分 1 秒')
    expect(durationText(3725)).toBe('1 时 2 分')
  })
  it('大小文本（3 位有效数字）', () => {
    expect(sizeText(512)).toBe('512 字节')
    expect(sizeText(456_789)).toBe('457 KB')
    expect(sizeText(1_234_567)).toBe('1.23 MB')
    expect(sizeText(45_678_912)).toBe('45.7 MB')
  })
  it('文件名与时间戳', () => {
    const d = new Date(2026, 9, 24, 9, 5, 3)
    expect(makeRecordingFileName(d)).toBe('FaceCover-20261024-090503.mp4')
    expect(createdAtText(d)).toBe('2026-10-24 09:05:03')
    expect(diagnosticTimestamp(d)).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/)
  })
  it('滑块文本', () => {
    expect(offsetText(-0.2)).toBe('-0.20')
    expect(offsetText(0)).toBe('+0.00')
    expect(offsetText(-0.001)).toBe('+0.00')
    expect(offsetText(1.255)).toBe('+1.25')
    expect(scaleText(2.4686)).toBe('2.47×')
    expect(elapsedText(75)).toBe('01:15')
  })
})
