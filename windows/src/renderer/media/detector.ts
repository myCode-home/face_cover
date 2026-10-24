// YuNet 检测器：onnxruntime-web 推理 + yunet.ts 解码。
// 曾尝试 opencv.js 的 FaceDetectorYN：它的 WASM 初始化在这个环境（file:// 页面 +
// 内嵌 data URI 的 wasm）里 fetch 被 CSP 拦截后静默挂死，worker/主线程都不行，
// 弃用。ORT-web 支持把 wasm 二进制直接喂进 env.wasm.wasmBinary，零文件系统依赖。
//
// 模型：face_detection_yunet_2023mar.onnx（OpenCV Zoo，与上个项目同一份文件），
// 输入名 "input"，输出 cls_{8,16,32} / obj_{8,16,32} / bbox_{8,16,32} / kps_{8,16,32}。

// @ts-expect-error 包类型声明指向裸模块名，浏览器里必须用相对路径加载（打包后同构）
import * as ortBundle from '../../../node_modules/onnxruntime-web/dist/ort.all.bundle.min.mjs'

import {
  DEFAULT_NMS_THRESHOLD,
  DEFAULT_SCORE_THRESHOLD,
  DEFAULT_TOP_K,
  STRIDES,
  decode,
  prepareInputFixed,
  scaleDetection,
  rollOf,
  toInputTensor,
  type Detection,
  type StrideOutputs,
} from './yunet.js'

// 只用到 ORT 的一小块 API，手写最小接口（相对路径导入没有官方类型）
interface OrtTensor {
  data: Float32Array
  dims: readonly number[]
}
interface OrtSession {
  inputNames: readonly string[]
  run(feeds: Record<string, unknown>): Promise<Record<string, OrtTensor>>
}
interface OrtApi {
  env: {
    wasm: {
      wasmBinary?: Uint8Array
      numThreads?: number
      wasmPaths?: { mjs?: string }
    }
  }
  InferenceSession: {
    create(model: Uint8Array, options?: Record<string, unknown>): Promise<OrtSession>
  }
  Tensor: new (type: 'float32', data: Float32Array, dims: number[]) => unknown
}

const ort = ortBundle as unknown as OrtApi

export interface RawFace {
  cx: number
  cy: number
  w: number
  h: number
  roll: number
  score: number
}

export class YuNetDetector {
  ready = false
  error: string | null = null
  /** 最近一次纯推理耗时（毫秒），供检测节奏迟滞使用 */
  lastMs = 0

  private session: OrtSession | null = null
  private inputName = 'input'
  private side = 320
  private scoreThreshold = DEFAULT_SCORE_THRESHOLD
  private nmsThreshold = DEFAULT_NMS_THRESHOLD
  private logCounter = 0

  async init(ortWasm: ArrayBuffer, ortMjs: string, model: ArrayBuffer): Promise<void> {
    try {
      const t0 = performance.now()
      // wasm 二进制直接喂给 ORT，绕开一切文件系统/CSP fetch
      ort.env.wasm.wasmBinary = new Uint8Array(ortWasm)
      ort.env.wasm.numThreads = 1
      ort.env.wasm.wasmPaths = { mjs: URL.createObjectURL(new Blob([ortMjs], { type: 'text/javascript' })) }
      this.session = await ort.InferenceSession.create(new Uint8Array(model), {
        executionProviders: ['wasm'],
        graphOptimizationLevel: 'all',
      })
      if (this.session.inputNames.length > 0) this.inputName = this.session.inputNames[0]!
      this.ready = true
      console.log(`[detector] ORT 就绪 @ ${(performance.now() - t0).toFixed(0)}ms，输入名 ${this.inputName}`)
    } catch (err) {
      this.error = err instanceof Error ? err.message : String(err)
      console.error('[detector] 初始化失败：', this.error)
    }
  }

  /** 异步检测一帧 RGBA（ORT run 是 promise）。返回归一化坐标（屏幕坐标系），按分数降序。 */
  async detect(pixels: ImageData): Promise<RawFace[]> {
    if (!this.session) return []
    const t0 = performance.now()
    const prepared = prepareInputFixed(pixels.data, pixels.width, pixels.height, this.side)
    const tensor = toInputTensor(prepared.rgba, prepared.width, prepared.height, prepared.padWidth, prepared.padHeight)
    const input = new ort.Tensor('float32', tensor, [1, 3, prepared.padHeight, prepared.padWidth])
    const results = await this.session.run({ [this.inputName]: input })
    this.lastMs = performance.now() - t0

    const outputs: StrideOutputs[] = STRIDES.map((stride) => ({
      cls: results[`cls_${stride}`]!.data,
      obj: results[`obj_${stride}`]!.data,
      bbox: results[`bbox_${stride}`]!.data,
      kps: results[`kps_${stride}`]!.data,
    }))
    const faces: Detection[] = decode(
      prepared.padWidth,
      prepared.padHeight,
      outputs,
      this.scoreThreshold,
      this.nmsThreshold,
      DEFAULT_TOP_K,
    ).map((d) => scaleDetection(d, prepared.scaleX, prepared.scaleY))

    this.logCounter++
    if (this.logCounter % 100 === 1) {
      console.log(`[detector] 推理 ${this.lastMs.toFixed(1)}ms（输入 ${prepared.padWidth}×${prepared.padHeight}），检出 ${faces.length} 张`)
    }

    return faces.map((d) => ({
      cx: (d.x + d.w / 2) / pixels.width,
      cy: (d.y + d.h / 2) / pixels.height,
      w: d.w / pixels.width,
      h: d.h / pixels.height,
      roll: rollOf(d),
      score: d.score,
    }))
  }
}
