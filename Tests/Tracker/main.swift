import CoreGraphics
import Foundation

// 无头自检：验证人脸跟踪器的相位延迟与抗抖。
//
// 历史：用户报「开镜像后遮罩跟脸反向移动」，查明是延迟问题（不是算错位置），
// 于是引入「轻平滑 + 速度外推」。
//
// 后来又报「人不动的时候也特别慌」。这次查明是 **平滑增益对随机噪声几乎无效**：
// 增益 α 的指数平滑只把标准差降到 √(α/(2−α)) 倍，α = 0.85 时是 0.86 倍，等于没压。
// 于是改成按速度自适应（静止用低增益、移动用高增益）。
//
// 教训记在这里：**原来的静止抖动测试用的是「±0.002 完美交替」方波**，
// 那对低通滤波器是最容易压的信号，所以一路绿灯却没反映真实情况。
// 现在改用固定种子的**随机**噪声，这才是 Vision 逐帧检测的真实形态。
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

/// 固定种子的伪随机，保证自检结果可复现
struct SeededRandom {
    var state: UInt64
    mutating func next() -> Double {          // [-1, 1)
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0x800000) - 1.0
    }
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

// MARK: FaceTracker

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

/// 把静止增益设成和移动增益一样，就等价于改造前的「固定增益」行为
func fixedGainConfig() -> FaceTracker {
    var config = FaceTracker()
    config.restPositionGain = config.positionGain
    config.restSizeGain = config.sizeGain
    return config
}

/// 人脸静止、检测带**随机**噪声时，输出中心的峰峰值。
///
/// 噪声量级：位置 ±0.002（1280 宽画面上约 ±2.6px）、大小 ±1%。
/// 这是 Vision 逐帧人脸框的真实形态 —— 随机的，不是交替方波。
func staticJitter(config: FaceTracker, detectEvery: Int = 1) -> Double {
    var tracker = config
    var random = SeededRandom(state: 0x9E3779B9)
    var output: [Double] = []

    for frame in 0..<150 {
        let noiseX = random.next() * 0.002
        let noiseY = random.next() * 0.002
        let sizeFactor = 1 + random.next() * 0.01
        let measurement = (frame % detectEvery == 0)
            ? CGRect(x: 0.4 + noiseX, y: 0.4 + noiseY,
                     width: 0.2 * sizeFactor, height: 0.2 * sizeFactor)
            : nil
        tracker.update(measurement: measurement, at: Double(frame) / FPS)
        output.append(Double(tracker.predicted?.midX ?? 0.5))
    }
    return swing(Array(output[60...]))
}

// MARK: 跑

let input = (0..<FRAMES).map { faceX(atFrame: $0) }

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

print("\n[2] 扫参数（每帧检测，随机噪声）")
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

print("\n[3] 自适应 vs 固定增益：静止时该更稳，移动时不该变差")
do {
    let adaptive = FaceTracker()
    let fixed = fixedGainConfig()

    let adaptiveJitter = staticJitter(config: adaptive)
    let fixedJitter = staticJitter(config: fixed)

    let adaptiveOut = runTracker(config: adaptive)
    let fixedOut = runTracker(config: fixed)
    let adaptiveLag = bestLagFrames(input: input, output: adaptiveOut, maxLag: 20)
    let fixedLag = bestLagFrames(input: input, output: fixedOut, maxLag: 20)
    let adaptiveRatio = inPhaseRatio(input: input, output: adaptiveOut)
    let fixedRatio = inPhaseRatio(input: input, output: fixedOut)
    let adaptiveAmp = swing(adaptiveOut) / swing(input)
    let fixedAmp = swing(fixedOut) / swing(input)

    print(String(format: "     固定增益 0.85:    静止抖动 %.5f  延迟 %d 帧  同向 %.0f%%  幅度 %.0f%%",
                 fixedJitter, fixedLag, fixedRatio * 100, fixedAmp * 100))
    print(String(format: "     自适应   0.85/%.2f: 静止抖动 %.5f  延迟 %d 帧  同向 %.0f%%  幅度 %.0f%%",
                 adaptive.restPositionGain, adaptiveJitter,
                 adaptiveLag, adaptiveRatio * 100, adaptiveAmp * 100))

    check(adaptiveJitter < fixedJitter * 0.5,
          "静止抖动至少压掉一半（\(String(format: "%.5f", adaptiveJitter)) vs \(String(format: "%.5f", fixedJitter))）")
    check(adaptiveLag <= fixedLag, "自适应没有引入额外延迟")
    check(adaptiveRatio > 0.9, "移动时仍然同向（\(Int(adaptiveRatio * 100))%）")
    check(adaptiveAmp > 0.85, "移动时幅度基本保留（\(Int(adaptiveAmp * 100))%）")
}

print("\n[4] 源码里的默认配置是否达标")
do {
    let config = FaceTracker()
    let output = runTracker(config: config)
    let lag = bestLagFrames(input: input, output: output, maxLag: 20)
    let ratio = inPhaseRatio(input: input, output: output)
    let amplitudeRatio = swing(output) / swing(input)
    let jitter = staticJitter(config: config)
    let jitterEveryOther = staticJitter(config: config, detectEvery: 2)

    print(String(format: "     默认: positionGain=%.2f restPositionGain=%.2f sizeGain=%.2f restSizeGain=%.2f leadTime=%.3f",
                 config.positionGain, config.restPositionGain,
                 config.sizeGain, config.restSizeGain, config.leadTime))
    print(String(format: "     延迟 %d 帧 (%.0fms)   同向 %.0f%%   摆动保留 %.0f%%",
                 lag, Double(lag) / FPS * 1000, ratio * 100, amplitudeRatio * 100))
    print(String(format: "     静止抖动: 每帧检测 %.5f   每 2 帧检测 %.5f", jitter, jitterEveryOther))

    check(lag <= 2, "延迟 ≤ 2 帧（实测 \(lag) 帧 / \(Int(Double(lag) / FPS * 1000))ms）")
    check(ratio > 0.9, "绝大多数时间与脸同向（\(Int(ratio * 100))%）—— 不会再看起来反向")
    check(amplitudeRatio > 0.85, "摆动幅度基本保留（\(Int(amplitudeRatio * 100))%）")
    // 阈值 0.003 ≈ 1280 宽画面上的 3.8px。改造前是 0.0055 左右（约 7px），肉眼明显在晃。
    check(jitter <= 0.003, "静止时抖动受控（\(String(format: "%.5f", jitter)) ≤ 0.003）")
    check(jitterEveryOther <= 0.003,
          "Vision 变慢降到每 2 帧检测后依然受控（\(String(format: "%.5f", jitterEveryOther))）")
}

print("\n[5] 多人脸轨迹匹配")
do {
    var tracker = MultiFaceTracker()
    let left0 = FaceObservation(boundingBox: CGRect(x: 0.12, y: 0.35, width: 0.18, height: 0.24), roll: 0)
    let right0 = FaceObservation(boundingBox: CGRect(x: 0.68, y: 0.35, width: 0.18, height: 0.24), roll: 0)
    let initial = tracker.update(observations: [left0, right0], at: 0.0)
    check(initial.count == 2, "首次同时建立两个人脸轨迹")

    let leftID = initial.min(by: { $0.boundingBox.midX < $1.boundingBox.midX })?.id
    let rightID = initial.max(by: { $0.boundingBox.midX < $1.boundingBox.midX })?.id
    let left1 = FaceObservation(boundingBox: CGRect(x: 0.18, y: 0.35, width: 0.18, height: 0.24), roll: 0.02)
    let right1 = FaceObservation(boundingBox: CGRect(x: 0.62, y: 0.35, width: 0.18, height: 0.24), roll: -0.02)
    let shuffled = tracker.update(observations: [right1, left1], at: 1.0 / FPS)
    let matchedLeft = shuffled.min(by: { $0.boundingBox.midX < $1.boundingBox.midX })
    let matchedRight = shuffled.max(by: { $0.boundingBox.midX < $1.boundingBox.midX })
    check(matchedLeft?.id == leftID && matchedRight?.id == rightID,
          "Vision 返回顺序变化时仍按位置匹配原有身份")

    let oneMissing = tracker.update(observations: [
        FaceObservation(boundingBox: CGRect(x: 0.20, y: 0.35, width: 0.18, height: 0.24), roll: 0)
    ], at: 2.0 / FPS)
    check(oneMissing.count == 2, "短暂未检出其中一人时保留短暂轨迹缓冲")
    let recovered = tracker.update(observations: [
        FaceObservation(boundingBox: CGRect(x: 0.23, y: 0.35, width: 0.18, height: 0.24), roll: 0),
        right1
    ], at: 3.0 / FPS)
    let recoveredLeft = recovered.min(by: { $0.boundingBox.midX < $1.boundingBox.midX })
    check(recoveredLeft?.id == leftID, "短暂遮挡后重新识别回同一轨迹")
}

print("")
if failures == 0 {
    print("全部通过 ✅")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
