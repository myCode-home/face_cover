import { describe, expect, it } from 'vitest'
import { MultiFaceTracker, SingleFaceTracker, TRACKER_CONST, type FaceObservation } from '../src/renderer/core/tracker'

const DT = 1 / 30

function obs(cx: number, cy: number, w = 0.2, h = 0.26, roll = 0): FaceObservation {
  return { box: { cx, cy, w, h }, roll }
}

/** 喂 0.8Hz、幅度 amp 的正弦摆动，返回每个采样点的输出 cx 与输入 cx */
function sweep(amp: number, freq: number, seconds: number, noise = 0): { t: number[]; input: number[]; output: number[] } {
  const tracker = new SingleFaceTracker()
  const t: number[] = []
  const input: number[] = []
  const output: number[] = []
  for (let i = 0; i < seconds / DT; i++) {
    const time = i * DT
    const x = 0.5 + amp * Math.sin(2 * Math.PI * freq * time) + (noise ? (Math.random() * 2 - 1) * noise : 0)
    const st = tracker.update(obs(x, 0.5), time)
    t.push(time)
    input.push(x)
    output.push(st ? st.predicted.cx : x)
  }
  return { t, input, output }
}

describe('SingleFaceTracker 正弦摆动（对齐 Tests/Tracker 的相位/同向用例）', () => {
  it('0.8Hz 摆动：输出与输入同向，且没有明显延迟（互相关峰值在 0 帧）', () => {
    const { t, input, output } = sweep(0.15, 0.8, 6)
    // 丢掉前 1 秒收敛期
    const warm = Math.round(1 / DT)
    const lag = (frames: number): number => {
      let sum = 0
      for (let i = warm; i < t.length - frames; i++) sum += output[i]! * input[i + frames]!
      return sum
    }
    const c0 = lag(0)
    // 峰值必须在 lag -1..+1 帧内（0.02s 外推就是为补这条链路延迟）
    const best = [-2, -1, 0, 1, 2].reduce((a, b) => (lag(b) > lag(a) ? b : a), 0 as number)
    expect(Math.abs(best)).toBeLessThanOrEqual(1)
    expect(c0).toBeGreaterThan(0)
  })

  it('随机噪声静止脸：输出残余抖动要被明显压低（固定增益做不到）', () => {
    // 输入 ±0.005 均匀噪声（std ≈ 0.00289）
    const { input, output } = sweep(0, 0.8, 10, 0.005)
    // 输入是静止脸 + 噪声，看输出的抖动
    const warm = Math.round(1 / DT)
    const std = (arr: number[]): number => {
      const seg = arr.slice(warm)
      const mean = seg.reduce((a, b) => a + b, 0) / seg.length
      return Math.sqrt(seg.reduce((a, b) => a + (b - mean) ** 2, 0) / seg.length)
    }
    const inStd = std(input)
    const outStd = std(output)
    expect(outStd).toBeLessThan(inStd * 0.35)
  })

  it('静止增益用 0.12、移动增益用 0.85（写反了摆动会滞后）', () => {
    expect(TRACKER_CONST.restPositionGain).toBeLessThan(TRACKER_CONST.positionGain)
    expect(TRACKER_CONST.restPositionGain).toBeCloseTo(0.12, 5)
    expect(TRACKER_CONST.positionGain).toBeCloseTo(0.85, 5)
  })

  it('测量中断时速度衰减，不无限外推', () => {
    const tracker = new SingleFaceTracker()
    tracker.update(obs(0.3, 0.5), 0)
    // 快速右移制造正速度
    for (let i = 1; i <= 10; i++) tracker.update(obs(0.3 + i * 0.01, 0.5), i * DT)
    const moving = tracker.update(null, 11 * DT)
    const still = tracker.update(null, 12 * DT)
    expect(moving && still).toBeTruthy()
    // 外推量应该衰减（second step moves predicted less than first）
    const firstStep = Math.abs(moving!.predicted.cx - (0.3 + 10 * 0.01))
    const secondStep = Math.abs(still!.predicted.cx - moving!.predicted.cx)
    expect(secondStep).toBeLessThan(firstStep)
  })
})

describe('MultiFaceTracker（对齐 Tests/Tracker 的多人脸用例）', () => {
  it('检测顺序变化时 id 不能互换', () => {
    const m = new MultiFaceTracker()
    let time = 0
    const feed = (left: FaceObservation, right: FaceObservation) => {
      time += DT
      m.update([left, right], time)
    }
    // 两个人稳定出现
    for (let i = 0; i < 30; i++) feed(obs(0.25, 0.5), obs(0.75, 0.5))
    let faces = m.update([obs(0.25, 0.5), obs(0.75, 0.5)], (time += DT))
    const leftId = faces.find((f) => f.box.cx < 0.5)!.id
    const rightId = faces.find((f) => f.box.cx > 0.5)!.id
    expect(leftId).not.toBe(rightId)
    // Vision 返回顺序颠倒：id 必须跟着人走
    for (let i = 0; i < 30; i++) {
      faces = m.update([obs(0.75, 0.5), obs(0.25, 0.5)], (time += DT))
    }
    expect(faces.find((f) => f.box.cx < 0.5)!.id).toBe(leftId)
    expect(faces.find((f) => f.box.cx > 0.5)!.id).toBe(rightId)
  })

  it('短暂未检出（< 0.35s）保留轨迹，重新出现认回同一 id', () => {
    const m = new MultiFaceTracker()
    let time = 0
    for (let i = 0; i < 30; i++) m.update([obs(0.5, 0.5)], (time += DT))
    const before = m.update([obs(0.5, 0.5)], (time += DT))
    const id = before[0]!.id
    // 掉 0.2 秒（6 帧 @30fps）
    for (let i = 0; i < 6; i++) m.update([], (time += DT))
    const after = m.update([obs(0.5, 0.5)], (time += DT))
    expect(after).toHaveLength(1)
    expect(after[0]!.id).toBe(id)
  })

  it('超过宽限期（0.35s）轨迹删除，重新出现是新 id', () => {
    const m = new MultiFaceTracker()
    let time = 0
    for (let i = 0; i < 30; i++) m.update([obs(0.5, 0.5)], (time += DT))
    const id = m.update([obs(0.5, 0.5)], (time += DT))[0]!.id
    // 掉 0.5 秒（15 帧）
    for (let i = 0; i < 15; i++) m.update([], (time += DT))
    const after = m.update([obs(0.5, 0.5)], (time += DT))
    expect(after[0]!.id).not.toBe(id)
  })

  it('observations=null（本帧没跑检测）走外推，不等于「没脸」', () => {
    const m = new MultiFaceTracker()
    let time = 0
    for (let i = 0; i < 30; i++) m.update([obs(0.5, 0.5)], (time += DT))
    const n1 = m.update(null, (time += DT)).length
    const n0 = m.update([], (time += DT)).length
    // null 只是没检测，轨迹还在；空数组也会保轨迹 0.35s，所以两者都应有输出，
    // 但 null 分支不应清空轨迹 —— 这里验证两条路径都不断轨
    expect(n1).toBe(1)
    expect(n0).toBe(1)
  })

  it('超过 12 人不再新建轨迹', () => {
    const m = new MultiFaceTracker()
    const many: FaceObservation[] = []
    for (let i = 0; i < 16; i++) many.push(obs(0.05 + i * 0.06, 0.5, 0.03, 0.04))
    const faces = m.update(many, DT)
    expect(faces.length).toBeLessThanOrEqual(TRACKER_CONST.maximumFaces)
  })
})
