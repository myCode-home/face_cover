// YuNet 人脸检测的**解码**部分 —— 模型推理由 onnxruntime-web 负责，这里只做纯数学。
// 逐行移植自 facecore/src/yunet.rs（上一个项目的实现，对真实图片 11/11 验证过），
// 解码公式来自 OpenCV modules/objdetect/src/face_detect.cpp（4.x）：
//
//   score = sqrt(clamp(cls) * clamp(obj))
//   cx = (c + bbox[0]) * stride      cy = (r + bbox[1]) * stride
//   w  = exp(bbox[2]) * stride       h  = exp(bbox[3]) * stride
//   kp = ((kps[2n] + c) * stride, (kps[2n+1] + r) * stride)
//
// 预处理（OpenCV 的 blobFromImage 默认参数）：BGR 通道序、0…255 不归一化、CHW 排布，
// 等比缩放到目标边长后右下补黑边（不缩放留白、不居中）。

export const STRIDES = [8, 16, 32] as const
export const PAD_DIVISOR = 32
export const DEFAULT_SCORE_THRESHOLD = 0.6
export const DEFAULT_NMS_THRESHOLD = 0.3
export const DEFAULT_TOP_K = 5000

/** 一帧的检测结果（像素坐标，左上角原点，相对补边后的输入图） */
export interface Detection {
  x: number
  y: number
  w: number
  h: number
  /** 5 个关键点：右眼、左眼、鼻尖、右嘴角、左嘴角 */
  landmarks: [number, number][]
  score: number
}

/** 歪头角（弧度）。两眼在图上从左到右排列，返回值正负表示往哪边歪。 */
export function rollOf(d: Detection): number {
  const rightEye = d.landmarks[0]!
  const leftEye = d.landmarks[1]!
  return Math.atan2(leftEye[1] - rightEye[1], leftEye[0] - rightEye[0])
}

export function boxIoU(a: Detection, b: Detection): number {
  const x0 = Math.max(a.x, b.x)
  const y0 = Math.max(a.y, b.y)
  const x1 = Math.min(a.x + a.w, b.x + b.w)
  const y1 = Math.min(a.y + a.h, b.y + b.h)
  const inter = Math.max(0, x1 - x0) * Math.max(0, y1 - y0)
  const union = a.w * a.h + b.w * b.h - inter
  return union > 0 ? inter / union : 0
}

/** 缩放回原图坐标（补边只发生在右/下，所以只需要缩放，不需要平移） */
export function scaleDetection(d: Detection, sx: number, sy: number): Detection {
  return {
    x: d.x * sx,
    y: d.y * sy,
    w: d.w * sx,
    h: d.h * sy,
    landmarks: d.landmarks.map((p) => [p[0] * sx, p[1] * sy] as [number, number]),
    score: d.score,
  }
}

export interface StrideOutputs {
  cls: Float32Array
  obj: Float32Array
  bbox: Float32Array
  kps: Float32Array
}

const clamp01 = (v: number): number => Math.min(1, Math.max(0, v))

/** 把 12 个输出张量解成候选框（3 个 stride），再做贪心 NMS */
export function decode(
  padWidth: number,
  padHeight: number,
  outputs: StrideOutputs[],
  scoreThreshold: number,
  nmsThreshold: number,
  topK: number,
): Detection[] {
  const candidates: Detection[] = []
  for (let i = 0; i < STRIDES.length; i++) {
    const stride = STRIDES[i]!
    const out = outputs[i]
    if (!out) continue
    const cols = padWidth / stride
    const rows = padHeight / stride
    if (out.cls.length < rows * cols || out.bbox.length < rows * cols * 4) continue

    for (let r = 0; r < rows; r++) {
      for (let c = 0; c < cols; c++) {
        const idx = r * cols + c
        const score = Math.sqrt(clamp01(out.cls[idx]!) * clamp01(out.obj[idx]!))
        if (score < scoreThreshold) continue
        const cx = (c + out.bbox[idx * 4]!) * stride
        const cy = (r + out.bbox[idx * 4 + 1]!) * stride
        const w = Math.exp(out.bbox[idx * 4 + 2]!) * stride
        const h = Math.exp(out.bbox[idx * 4 + 3]!) * stride
        const landmarks: [number, number][] = []
        for (let n = 0; n < 5; n++) {
          landmarks.push([
            (out.kps[idx * 10 + 2 * n]! + c) * stride,
            (out.kps[idx * 10 + 2 * n + 1]! + r) * stride,
          ])
        }
        candidates.push({ x: cx - w / 2, y: cy - h / 2, w, h, landmarks, score })
      }
    }
  }
  return nms(candidates, nmsThreshold, topK)
}

/** 贪心 NMS：按分数从高到低保留，IoU 超过阈值的丢掉 */
export function nms(detections: Detection[], nmsThreshold: number, topK: number): Detection[] {
  const sorted = [...detections].sort((a, b) => b.score - a.score)
  const kept: Detection[] = []
  for (const candidate of sorted) {
    if (kept.length >= topK) break
    if (kept.some((k) => boxIoU(k, candidate) > nmsThreshold)) continue
    kept.push(candidate)
  }
  return kept
}

/** 输入图补边后的尺寸（右下补到 32 的整数倍） */
export function paddedSize(width: number, height: number): [number, number] {
  const padW = Math.ceil(width / PAD_DIVISOR) * PAD_DIVISOR
  const padH = Math.ceil(height / PAD_DIVISOR) * PAD_DIVISOR
  return [padW, padH]
}

export interface PreparedInput {
  rgba: Uint8ClampedArray
  width: number
  height: number
  padWidth: number
  padHeight: number
  /** 原图 → 缩放图的缩放系数（坐标回乘它） */
  scaleX: number
  scaleY: number
}

/** 固定边长输入：等比缩放 → 右下补到 side×side（模型吃方输入时用） */
export function prepareInputFixed(rgba: Uint8ClampedArray, width: number, height: number, side: number): PreparedInput {
  const ratio = Math.min(side / Math.max(width, 1), side / Math.max(height, 1))
  const sw = Math.min(side, Math.max(1, Math.round(width * ratio)))
  const sh = Math.min(side, Math.max(1, Math.round(height * ratio)))
  const resized = resizeBilinear(rgba, width, height, sw, sh)
  return {
    rgba: resized,
    width: sw,
    height: sh,
    padWidth: side,
    padHeight: side,
    scaleX: width / sw,
    scaleY: height / sh,
  }
}

/** 双线性缩放，输入/输出都是 RGBA8（半像素中心约定） */
export function resizeBilinear(src: Uint8ClampedArray, sw: number, sh: number, dw: number, dh: number): Uint8ClampedArray {
  if (sw === dw && sh === dh) return new Uint8ClampedArray(src)
  const out = new Uint8ClampedArray(dw * dh * 4)
  const sxRatio = sw / dw
  const syRatio = sh / dh
  for (let y = 0; y < dh; y++) {
    const fy = Math.max(0, (y + 0.5) * syRatio - 0.5)
    const y0 = Math.floor(fy)
    const y1 = Math.min(sh - 1, y0 + 1)
    const wy = fy - y0
    for (let x = 0; x < dw; x++) {
      const fx = Math.max(0, (x + 0.5) * sxRatio - 0.5)
      const x0 = Math.floor(fx)
      const x1 = Math.min(sw - 1, x0 + 1)
      const wx = fx - x0
      const i00 = (y0 * sw + x0) * 4
      const i10 = (y0 * sw + x1) * 4
      const i01 = (y1 * sw + x0) * 4
      const i11 = (y1 * sw + x1) * 4
      const o = (y * dw + x) * 4
      for (let k = 0; k < 4; k++) {
        const top = src[i00 + k]! * (1 - wx) + src[i10 + k]! * wx
        const bottom = src[i01 + k]! * (1 - wx) + src[i11 + k]! * wx
        out[o + k] = top * (1 - wy) + bottom * wy
      }
    }
  }
  return out
}

/** 把 RGBA 图补边并转成模型输入：BGR、0…255、CHW，右下补 0（黑） */
export function toInputTensor(
  rgba: Uint8ClampedArray,
  width: number,
  height: number,
  padWidth: number,
  padHeight: number,
): Float32Array {
  const plane = padWidth * padHeight
  const out = new Float32Array(plane * 3)
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4
      out[y * padWidth + x] = rgba[i + 2]! // B
      out[plane + y * padWidth + x] = rgba[i + 1]! // G
      out[plane * 2 + y * padWidth + x] = rgba[i]! // R
    }
  }
  return out
}
