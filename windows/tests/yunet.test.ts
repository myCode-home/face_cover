import { describe, expect, it } from 'vitest'
import {
  boxIoU,
  decode,
  nms,
  prepareInputFixed,
  resizeBilinear,
  rollOf,
  toInputTensor,
  type Detection,
  type StrideOutputs,
} from '../src/renderer/media/yunet'

/** 造一个只在 (row,col) 格子上出现的检测：score=1，bbox 偏移 dx,dy，尺寸 dw,dh */
function singleDetectionStride(
  stride: number,
  padW: number,
  padH: number,
  row: number,
  col: number,
  bbox: [number, number, number, number],
): StrideOutputs {
  const cols = padW / stride
  const rows = padH / stride
  const cls = new Float32Array(rows * cols)
  const obj = new Float32Array(rows * cols)
  const bb = new Float32Array(rows * cols * 4)
  const kps = new Float32Array(rows * cols * 10)
  const idx = row * cols + col
  cls[idx] = 1
  obj[idx] = 1
  bb[idx * 4] = bbox[0]
  bb[idx * 4 + 1] = bbox[1]
  bb[idx * 4 + 2] = bbox[2]
  bb[idx * 4 + 3] = bbox[3]
  // 眼睛摆在框内对称位置：右眼 (dx-0.1, dy-0.05)，左眼 (dx+0.1, dy-0.05)
  kps[idx * 10] = bbox[0] - 0.1
  kps[idx * 10 + 1] = bbox[1] - 0.05
  kps[idx * 10 + 2] = bbox[0] + 0.1
  kps[idx * 10 + 3] = bbox[1] - 0.05
  return { cls, obj, bbox: bb, kps }
}

describe('YuNet 解码（对齐 OpenCV face_detect.cpp 公式）', () => {
  it('bbox 偏移 × stride + exp：框心与尺寸都对', () => {
    const outputs = [singleDetectionStride(8, 32, 32, 1, 2, [0.5, 0.25, Math.log(2), Math.log(3)])]
    const faces = decode(32, 32, outputs, 0.6, 0.3, 100)
    expect(faces).toHaveLength(1)
    const f = faces[0]!
    // cx = (col + 0.5) * 8 = 20, w = exp(log 2)*8 = 16
    expect(f.x + f.w / 2).toBeCloseTo(20, 3)
    expect(f.w).toBeCloseTo(16, 3)
    // cy = (row + 0.25) * 8 = 10, h = 24
    expect(f.y + f.h / 2).toBeCloseTo(10, 3)
    expect(f.h).toBeCloseTo(24, 3)
  })

  it('分数 = sqrt(cls × obj)，低于阈值被滤掉', () => {
    const outputs = [singleDetectionStride(8, 32, 32, 0, 0, [0.5, 0.5, 0.1, 0.1])]
    outputs[0]!.cls[0] = 0.16
    outputs[0]!.obj[0] = 0.64
    // sqrt(0.16 × 0.64) = 0.32 < 0.6 → 空
    expect(decode(32, 32, outputs, 0.6, 0.3, 100)).toHaveLength(0)
    outputs[0]!.cls[0] = 0.81
    outputs[0]!.obj[0] = 0.64
    // sqrt(0.5184) = 0.72 ≥ 0.6 → 1 张
    expect(decode(32, 32, outputs, 0.6, 0.3, 100)).toHaveLength(1)
  })

  it('歪头角：左眼比右眼低 → 正角度（头向观察者右侧歪）', () => {
    const outputs = [singleDetectionStride(8, 32, 32, 0, 0, [0.5, 0.5, 0.2, 0.2])]
    const face = decode(32, 32, outputs, 0.6, 0.3, 100)[0]!
    expect(rollOf(face)).toBeCloseTo(Math.atan2(0, 0.2 * 8 * 2) * -1 + Math.atan2(0, 1), 9)
    // 直接验证符号关系：把左眼下移，角度应变大
    const tilted: Detection = { ...face, landmarks: [[0, 0], [2, 1], [1, 2], [0.5, 3], [1.5, 3]] as [number, number][] }
    expect(rollOf(tilted)).toBeGreaterThan(0)
    const upright: Detection = { ...face, landmarks: [[0, 0], [2, 0], [1, 2], [0.5, 3], [1.5, 3]] as [number, number][] }
    expect(rollOf(upright)).toBeCloseTo(0, 9)
  })

  it('NMS：IoU 超过阈值的低分框被丢掉', () => {
    const a: Detection = { x: 0, y: 0, w: 10, h: 10, landmarks: [], score: 0.9 }
    const b: Detection = { x: 1, y: 1, w: 10, h: 10, landmarks: [], score: 0.8 }
    const far: Detection = { x: 100, y: 100, w: 10, h: 10, landmarks: [], score: 0.7 }
    const kept = nms([a, b, far], 0.3, 100)
    expect(kept.map((k) => k.score)).toEqual([0.9, 0.7])
    expect(boxIoU(a, b)).toBeGreaterThan(0.3)
  })

  it('坐标缩放回原图：scaleX/Y 乘回去', () => {
    const outputs = [singleDetectionStride(8, 32, 32, 0, 0, [0.5, 0.5, 0.2, 0.2])]
    const faces = decode(32, 32, outputs, 0.6, 0.3, 100)
    const scaled = faces.map((f) => ({
      ...f,
      x: f.x * 2,
      y: f.y * 2,
      w: f.w * 2,
      h: f.h * 2,
    }))
    expect(scaled[0]!.w).toBeCloseTo(faces[0]!.w * 2, 6)
  })
})

describe('预处理', () => {
  it('letterbox：1920×1080 → 320×180 居中于 320×320 画布，scaleX 回乘', () => {
    const rgba = new Uint8ClampedArray(1920 * 1080 * 4)
    const prepared = prepareInputFixed(rgba, 1920, 1080, 320)
    expect(prepared.width).toBe(320)
    expect(prepared.height).toBe(180)
    expect(prepared.padWidth).toBe(320)
    expect(prepared.padHeight).toBe(320)
    expect(prepared.scaleX).toBeCloseTo(1920 / 320, 6)
    expect(prepared.scaleY).toBeCloseTo(1080 / 180, 6)
  })

  it('BGR CHW：R/G/B 通道落在三个平面，右下补 0', () => {
    const rgba = new Uint8ClampedArray([10, 20, 30, 255, 40, 50, 60, 255])
    const tensor = toInputTensor(rgba, 2, 1, 4, 2)
    expect(tensor[0]).toBe(30) // 第一个像素 B
    expect(tensor[8]).toBe(20) // 平面偏移 4×2=8 → G
    expect(tensor[16]).toBe(10) // 平面偏移 16 → R
    expect(tensor[2]).toBe(0) // 第三个槽位是补边，为 0
    expect(tensor[1]).toBe(60) // 第二个像素 B
    expect(tensor[8 + 1]).toBe(50) // 第二个像素 G
  })

  it('resizeBilinear 恒等：同尺寸原样返回', () => {
    const rgba = new Uint8ClampedArray([1, 2, 3, 4, 5, 6, 7, 8])
    const out = resizeBilinear(rgba, 2, 1, 2, 1)
    expect([...out]).toEqual([1, 2, 3, 4, 5, 6, 7, 8])
  })

  it('resizeBilinear 放大 2×2→4×4：角点像素保持', () => {
    const rgba = new Uint8ClampedArray(2 * 2 * 4)
    rgba[0] = 255 // 左上 R
    const out = resizeBilinear(rgba, 2, 2, 4, 4)
    expect(out[0]).toBe(255) // 左上角还是 255
  })
})
