// 人脸跟踪：单脸速度自适应平滑 + 多脸轨迹关联。
// 全部常量与 macOS 版 FaceTracker.swift 一致（规格来源：仓库 README「实现上的坑」与源码）。
// 坐标系：归一化（0..1），中心 + 宽高表示，y 向下为正（屏幕坐标系）。
// 本文件零 DOM 依赖，renderer 与 vitest 共用。

export interface Vec2 {
  x: number
  y: number
}

/** 归一化人脸框：中心 + 宽高 */
export interface FaceBox {
  cx: number
  cy: number
  w: number
  h: number
}

export interface FaceObservation {
  box: FaceBox
  /** 歪头角（弧度）。检测器没给角度时填 0。 */
  roll: number
}

/** 跟踪输出：current 无外推，predicted 加速度外推（下游一律用 predicted） */
export interface TrackedFace {
  id: number
  box: FaceBox
  roll: number
}

export const TRACKER_CONST = {
  positionGain: 0.85,
  restPositionGain: 0.12,
  sizeGain: 0.35,
  restSizeGain: 0.1,
  /** 速度 EMA 增益：压狠点，防噪声被 leadTime 放大 */
  velocityGain: 0.2,
  /** 速度外推提前量（秒） */
  leadTime: 0.02,
  /** 低于此速度按静止（归一化单位/秒） */
  restSpeed: 0.06,
  movingSpeed: 0.35,
  rollRestGain: 0.12,
  rollMovingGain: 0.35,
  /** 轨迹丢失宽限（秒）：0.35 秒内重新出现认回同一条轨迹 */
  lostFaceGracePeriod: 0.35,
  maximumFaces: 12,
  /** 轨迹-观测关联距离上限 */
  associationRadius: 2.5,
} as const

const clamp = (v: number, lo: number, hi: number): number => Math.min(hi, Math.max(lo, v))

interface SingleState {
  current: FaceBox
  predicted: FaceBox
  motion: number
}

/**
 * 单脸平滑。固定增益解决不了「静止抖」和「移动延迟」这对矛盾：
 * 增益高则跟手但抖，低则稳但延迟。按速度自适应插值增益，
 * 再加轻量速度外推（增益必须压得很低，否则逐帧检测噪声被 leadTime 放大）。
 */
export class SingleFaceTracker {
  private lastTime: number | null = null
  private center: Vec2 | null = null
  private size: Vec2 | null = null
  private velocity: Vec2 = { x: 0, y: 0 }
  private motion = 0
  private lastMeasCenter: Vec2 | null = null
  private lastMeasTime: number | null = null

  state(): SingleState | null {
    if (!this.center || !this.size) return null
    return {
      current: { cx: this.center.x, cy: this.center.y, w: this.size.x, h: this.size.y },
      predicted: {
        cx: this.center.x + this.velocity.x * TRACKER_CONST.leadTime,
        cy: this.center.y + this.velocity.y * TRACKER_CONST.leadTime,
        w: this.size.x,
        h: this.size.y,
      },
      motion: this.motion,
    }
  }

  reset(): void {
    this.lastTime = null
    this.center = null
    this.size = null
    this.velocity = { x: 0, y: 0 }
    this.motion = 0
    this.lastMeasCenter = null
    this.lastMeasTime = null
  }

  update(measurement: FaceObservation | null, time: number): SingleState | null {
    if (this.lastTime === null) {
      // 首帧：有测量就 seed，无测量维持空状态
      this.lastTime = time
      if (measurement) {
        this.center = { x: measurement.box.cx, y: measurement.box.cy }
        this.size = { x: measurement.box.w, y: measurement.box.h }
        this.lastMeasCenter = { ...this.center }
        this.lastMeasTime = time
      }
      return this.state()
    }

    // 防掉帧/恢复后速度爆炸
    const dt = clamp(time - this.lastTime, 1 / 240, 0.25)
    this.lastTime = time

    if (!measurement) {
      // 本帧没有测量：短惯性衰减，不无限外推
      this.velocity.x *= 0.7
      this.velocity.y *= 0.7
      const speed = Math.hypot(this.velocity.x, this.velocity.y)
      this.motion = clamp((speed - TRACKER_CONST.restSpeed) / (TRACKER_CONST.movingSpeed - TRACKER_CONST.restSpeed), 0, 1)
      return this.state()
    }

    const m = measurement.box
    // 观测速度用「两次测量」的时间差，不用帧间隔
    if (this.lastMeasCenter && this.lastMeasTime !== null && time > this.lastMeasTime) {
      const obsVx = (m.cx - this.lastMeasCenter.x) / (time - this.lastMeasTime)
      const obsVy = (m.cy - this.lastMeasCenter.y) / (time - this.lastMeasTime)
      this.velocity.x += (obsVx - this.velocity.x) * TRACKER_CONST.velocityGain
      this.velocity.y += (obsVy - this.velocity.y) * TRACKER_CONST.velocityGain
    }
    this.lastMeasCenter = { x: m.cx, y: m.cy }
    this.lastMeasTime = time

    const speed = Math.hypot(this.velocity.x, this.velocity.y)
    this.motion = clamp((speed - TRACKER_CONST.restSpeed) / (TRACKER_CONST.movingSpeed - TRACKER_CONST.restSpeed), 0, 1)

    if (this.center && this.size) {
      const pg = TRACKER_CONST.restPositionGain + (TRACKER_CONST.positionGain - TRACKER_CONST.restPositionGain) * this.motion
      const sg = TRACKER_CONST.restSizeGain + (TRACKER_CONST.sizeGain - TRACKER_CONST.restSizeGain) * this.motion
      this.center.x += (m.cx - this.center.x) * pg
      this.center.y += (m.cy - this.center.y) * pg
      this.size.x += (m.w - this.size.x) * sg
      this.size.y += (m.h - this.size.y) * sg
    } else {
      this.center = { x: m.cx, y: m.cy }
      this.size = { x: m.w, y: m.h }
    }
    return this.state()
  }
}

/** 轨迹-观测关联距离（macOS FaceTracker.associationDistance 的移植） */
export function associationDistance(a: FaceBox, b: FaceBox): number {
  const scale = Math.max(a.w, a.h, b.w, b.h, 0.04)
  const centerDistance = Math.hypot(a.cx - b.cx, a.cy - b.cy) / scale
  const wa = Math.max(a.w, 0.001)
  const ha = Math.max(a.h, 0.001)
  const wb = Math.max(b.w, 0.001)
  const hb = Math.max(b.h, 0.001)
  const sizeDistance = Math.abs(Math.log(wa / wb)) + Math.abs(Math.log(ha / hb))
  const iou = boxIoU(a, b)
  return centerDistance + sizeDistance * 0.25 - iou * 0.5
}

function boxIoU(a: FaceBox, b: FaceBox): number {
  const ax0 = a.cx - a.w / 2
  const ay0 = a.cy - a.h / 2
  const bx0 = b.cx - b.w / 2
  const by0 = b.cy - b.h / 2
  const ix = Math.max(0, Math.min(ax0 + a.w, bx0 + b.w) - Math.max(ax0, bx0))
  const iy = Math.max(0, Math.min(ay0 + a.h, by0 + b.h) - Math.max(ay0, by0))
  const inter = ix * iy
  const union = a.w * a.h + b.w * b.h - inter
  return union > 0 ? inter / union : 0
}

interface Track {
  id: number
  tracker: SingleFaceTracker
  roll: number
  lastSeen: number
}

/**
 * 多脸关联：每人一条轨迹；Vision/YuNet 返回顺序变化时 id 不能互换、
 * 短暂未检出保留轨迹缓冲、重新出现认回同一条轨迹。
 * observations 为 null 表示本帧没跑检测（全部走外推）；空数组表示跑了但没脸。
 */
export class MultiFaceTracker {
  private tracks: Track[] = []
  private nextId = 1

  reset(): void {
    this.tracks = []
  }

  get count(): number {
    return this.tracks.length
  }

  update(observations: FaceObservation[] | null, time: number): TrackedFace[] {
    // 1. 候选生成：轨迹 predicted × 观测，距离 ≤ 2.5 才算候选
    const candidates: { ti: number; oi: number; d: number }[] = []
    this.tracks.forEach((track, ti) => {
      const predicted = track.tracker.state()?.predicted
      if (!predicted) return
      if (observations) {
        observations.forEach((obs, oi) => {
          const d = associationDistance(predicted, obs.box)
          if (d <= TRACKER_CONST.associationRadius) candidates.push({ ti, oi, d })
        })
      }
    })

    // 2. 按距离升序贪心一对一
    candidates.sort((a, b) => a.d - b.d)
    const matchedTrack = new Set<number>()
    const matchedObs = new Set<number>()
    for (const c of candidates) {
      if (matchedTrack.has(c.ti) || matchedObs.has(c.oi)) continue
      matchedTrack.add(c.ti)
      matchedObs.add(c.oi)
      const track = this.tracks[c.ti]!
      const obs = observations![c.oi]!
      const st = track.tracker.update(obs, time)
      if (st) {
        const gain = TRACKER_CONST.rollRestGain + (TRACKER_CONST.rollMovingGain - TRACKER_CONST.rollRestGain) * st.motion
        track.roll += (obs.roll - track.roll) * gain
      }
      track.lastSeen = time
    }

    // 3. 未匹配的观测：容量允许就新建轨迹（新 ID），立即 seed
    if (observations) {
      observations.forEach((obs, oi) => {
        if (matchedObs.has(oi)) return
        if (this.tracks.length >= TRACKER_CONST.maximumFaces) return
        const tracker = new SingleFaceTracker()
        tracker.update(obs, time)
        this.tracks.push({ id: this.nextId++, tracker, roll: obs.roll, lastSeen: time })
        matchedTrack.add(this.tracks.length - 1)
      })
    }

    // 4. 未匹配的轨迹：速度衰减外推
    this.tracks.forEach((track, ti) => {
      if (!matchedTrack.has(ti)) track.tracker.update(null, time)
    })

    // 5. 删除超过宽限期的轨迹
    this.tracks = this.tracks.filter((t) => time - t.lastSeen <= TRACKER_CONST.lostFaceGracePeriod)

    // 6. 输出
    const out: TrackedFace[] = []
    for (const track of this.tracks) {
      const st = track.tracker.state()
      if (st) out.push({ id: track.id, box: st.predicted, roll: track.roll })
    }
    return out
  }
}
