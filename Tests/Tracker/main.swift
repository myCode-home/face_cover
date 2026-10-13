import CoreGraphics
import Foundation

// 无头自检：验证人脸跟踪器的相位延迟与抗抖。
//
// 用户报的现象是「开镜像后遮罩跟脸反向移动」。遮罩位置是从人脸位置推导的，
// 所以不可能是算错位置 —— 真正的嫌疑是 **延迟**：头来回摆动时，
// 滞后半个周期的输出看起来就是反相摆动。
//
// 运行: ./test.sh

var failures = 0

func check(_ ok: Bool, _ label: String) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

let FPS = 30.0
let FRAMES = 150          // 5 秒
let SKIP = 45             // 前 1.5 秒当作启动过渡，不参与统计
let AMPLITUDE = 0.15      // 归一化横向摆动幅度
let FREQUENCY = 0.8       // Hz，头左右摆动的速度

func faceX(atFrame frame: Int) -> Double {
    let t = Double(frame) / FPS
    return 0.5 + AMPLITUDE * sin(2 * Double.pi * FREQUENCY * t)
}

func faceRect(atFrame frame: Int) -> CGRect {
    CGRect(x: faceX(atFrame: frame) - 0.1, y: 0.4, width: 0.2, height: 0.2)
}

/// 互相关求等效延迟。必须先去掉直流分量，否则 0.5 的均值会淹没一切。
func bestLagFrames(input: [Double], output: [Double], maxLag: Int) -> Int {
    var bestLag = 0
    var bestScore = -Double.infinity
    for lag in 0...maxLag {
        var sum = 0.0
        var count = 0
        for i in SKIP..<input.count where i - lag >= SKIP {
            sum += (input[i] - 0.5) * (output[i - lag] - 0.5)
            count += 1
        }
        guard count > 0 else { continue }
        let score = sum / Double(count)
        if score > bestScore {
            bestScore = score
            bestLag = lag
        }
    }
    return bestLag
}

/// 输出和输入同号的帧占比：反相的话会接近 0
func inPhaseRatio(input: [Double], output: [Double]) -> Double {
    var same = 0
    var total = 0
    for i in SKIP..<input.count {
        let a = input[i] - 0.5
        let b = output[i] - 0.5
        if abs(a) < 0.01 || abs(b) < 0.01 { continue }
        if a * b > 0 { same += 1 }
        total += 1
    }
    return total > 0 ? Double(same) / Double(total) : 0
}

func swing(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    return (values.max() ?? 0) - (values.min() ?? 0)
}

// MARK: 旧做法：每 2 帧检测一次，但 **每一帧** 都朝最新结果插值 0.4
// （第一版代码就是这样：检测每 2 帧一次，而 lerp 每帧都跑）

func runOldApproach() -> [Double] {
    var smoothed: CGRect?
    var target: CGRect?
    var output: [Double] = []
    for frame in 0..<FRAMES {
        if frame % 2 == 0 { target = faceRect(atFrame: frame) }
        if let t = target {
            if let s = smoothed {
                smoothed = CGRect(x: s.minX + (t.minX - s.minX) * 0.4,
                                  y: s.minY + (t.minY - s.minY) * 0.4,
                                  width: s.width + (t.width - s.width) * 0.4,
                                  height: s.height + (t.height - s.height) * 0.4)
            } else {
                smoothed = t
            }
        }
        output.append(Double(smoothed?.midX ?? 0.5))
    }
    return output
}

// MARK: 新做法：FaceTracker（参数可调，方便扫参）

func runTracker(config: FaceTracker, detectEvery: Int = 1) -> [Double] {
    var tracker = config
    var output: [Double] = []
    for frame in 0..<FRAMES {
        let measurement = (frame % detectEvery == 0) ? faceRect(atFrame: frame) : nil
        tracker.update(measurement: measurement, at: Double(frame) / FPS)
        output.append(Double(tracker.predicted?.midX ?? 0.5))
    }
    return output
}

/// 人脸静止、检测带噪声时，输出的残余抖动
func staticJitter(config: FaceTracker, detectEvery: Int = 1) -> Double {
    var tracker = config
    var output: [Double] = []
    for frame in 0..<90 {
        let noise = (frame % 2 == 0) ? 0.002 : -0.002
        let measurement = (frame % detectEvery == 0)
            ? CGRect(x: 0.4 + noise, y: 0.4, width: 0.2, height: 0.2)
            : nil
        tracker.update(measurement: measurement, at: Double(frame) / FPS)
        output.append(Double(tracker.predicted?.midX ?? 0.5))
    }
    return swing(Array(output[30...]))
}

// MARK: 跑

let input = (0..<FRAMES).map { faceX(atFrame: $0) }

// 说明：最初怀疑「遮罩反向移动」是延迟导致的。实测下来这个假设 **不成立** ——
// 旧做法在 0.8Hz 下延迟就是 0 帧。这里如实记录对比，不硬套结论。
print("\n[1] 新旧做法对比（诚实版：旧做法并没有明显延迟）")
do {
    let oldOutput = runOldApproach()
    let newOutput = runTracker(config: FaceTracker())
    let oldLag = bestLagFrames(input: input, output: oldOutput, maxLag: 20)
    let newLag = bestLagFrames(input: input, output: newOutput, maxLag: 20)
    let oldRatio = inPhaseRatio(input: input, output: oldOutput)
    let newRatio = inPhaseRatio(input: input, output: newOutput)
    print(String(format: "     旧做法: 延迟 %d 帧  同向 %.0f%%  摆动 %.3f",
                 oldLag, oldRatio * 100, swing(oldOutput)))
    print(String(format: "     新做法: 延迟 %d 帧  同向 %.0f%%  摆动 %.3f",
                 newLag, newRatio * 100, swing(newOutput)))
    check(newLag <= oldLag, "新做法延迟不差于旧做法")
    check(newRatio >= oldRatio, "新做法同向性不差于旧做法（\(Int(newRatio * 100))% vs \(Int(oldRatio * 100))%）")
}

print("\n[2] 扫参数（每帧检测）")
print("     positionGain  velocityGain  leadTime   延迟(帧)  同向%   摆动    静止抖动")
do {
    let candidates: [(Double, Double, Double)] = [
        (0.80, 0.45, 0.05),   // 最初的想法：速度外推比较激进
        (0.80, 0.25, 0.03),
        (0.85, 0.20, 0.02),
        (0.90, 0.15, 0.02),
        (1.00, 0.00, 0.00),   // 完全不平滑
    ]
    for (pg, vg, lead) in candidates {
        var config = FaceTracker()
        config.positionGain = pg
        config.velocityGain = vg
        config.leadTime = lead
        let output = runTracker(config: config)
        print(String(format: "     %12.2f  %12.2f  %8.3f  %8d  %5.0f%%  %6.3f  %8.5f",
                     pg, vg, lead,
                     bestLagFrames(input: input, output: output, maxLag: 20),
                     inPhaseRatio(input: input, output: output) * 100,
                     swing(output),
                     staticJitter(config: config)))
    }
}

print("\n[3] 源码里的默认配置是否达标")
do {
    let config = FaceTracker()
    let output = runTracker(config: config)
    let lag = bestLagFrames(input: input, output: output, maxLag: 20)
    let ratio = inPhaseRatio(input: input, output: output)
    let amplitudeRatio = swing(output) / swing(input)
    let jitter = staticJitter(config: config)

    print(String(format: "     默认: positionGain=%.2f velocityGain=%.2f sizeGain=%.2f leadTime=%.3f",
                 config.positionGain, config.velocityGain, config.sizeGain, config.leadTime))
    print(String(format: "     延迟 %d 帧 (%.0fms)   同向 %.0f%%   摆动保留 %.0f%%   静止抖动 %.5f",
                 lag, Double(lag) / FPS * 1000, ratio * 100, amplitudeRatio * 100, jitter))

    check(lag <= 2, "延迟 ≤ 2 帧（实测 \(lag) 帧 / \(Int(Double(lag) / FPS * 1000))ms）")
    check(ratio > 0.9, "绝大多数时间与脸同向（\(Int(ratio * 100))%）—— 不会再看起来反向")
    check(amplitudeRatio > 0.85, "摆动幅度基本保留（\(Int(amplitudeRatio * 100))%）")
    check(jitter <= 0.004, "静止时抖动不超过输入噪声（\(String(format: "%.5f", jitter)) ≤ 0.004）")
}

print("")
if failures == 0 {
    print("全部通过 ✅")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
