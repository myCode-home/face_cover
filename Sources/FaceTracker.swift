import CoreGraphics
import Foundation

/// 人脸框平滑 + 速度补偿。
///
/// 这个类型要同时满足两个互相矛盾的需求：
/// 1. **头在动的时候不能有延迟** —— 「每 2 帧检测一次 + 每帧 0.4 插值」这类做法会累积大约 150ms 延迟，
///    头来回摆动时遮罩会滞后接近半个周期，看上去就像 **遮罩在跟脸反向移动**。
/// 2. **头不动的时候不能抖** —— Vision 的逐帧人脸框本身有噪声，如果一直用高增益插值，
///    静止时遮罩会持续抖动。
///
/// 固定增益解决不了这一对矛盾：增益高则跟手但抖，增益低则稳但延迟。
/// 所以这里按**速度自适应**：
/// - 用估计出来的速度判断当前是「静止」还是「在动」；
/// - 静止 → 增益压到 `restXxxGain`（噪声被压死，此时也不需要跟手）；
/// - 在动 → 增益提到 `xxxGain`（跟手优先，反正信号本身远大于噪声）；
/// - 中间线性过渡，避免门限附近跳变。
///
/// 再叠加一点速度外推（`leadTime`）补掉「检测 → 合成 → 显示」的链路延迟。
///
/// 所有坐标都是 Vision 的归一化坐标（左下角原点），速度单位是「归一化单位 / 秒」。
struct FaceTracker {

    // MARK: 位置

    /// 移动时的位置增益。越接近 1 越跟手。
    var positionGain: Double = 0.85
    /// 静止时的位置增益。**这个值决定「人不动时脸罩抖不抖」**。
    ///
    /// 为什么必须压这么低：随机噪声下，增益 α 的指数平滑只把标准差降到 √(α/(2−α)) 倍。
    /// α = 0.85 时是 0.86 倍 —— 等于没压。实测静止时脸罩外缘逐帧位移 5.1px（1280 宽画面），
    /// 已经在「肉眼明显在晃」的区间。压到 0.12 后降到 1px 以内。
    var restPositionGain: Double = 0.12

    // MARK: 大小

    /// 移动时的人脸框大小增益（比位置更慢，免得大小一直闪）。
    var sizeGain: Double = 0.35
    /// 静止时的大小增益。脸罩是按 `face.width` 缩放的，大小噪声会让脸罩整体缩放，
    /// 看上去就是「呼吸」。而且脸罩比脸大（`sizeScale` 约 2.5 倍），外缘位移被进一步放大。
    var restSizeGain: Double = 0.10

    // MARK: 速度

    /// 速度平滑增益。速度是用来外推的，必须压得比较狠，
    /// 否则逐帧检测噪声会被 `leadTime` 放大，静止时遮罩反而更抖。
    var velocityGain: Double = 0.20
    /// 速度外推提前量（秒）。自适应增益已经保证了跟手，这里只做一点点补偿。
    var leadTime: Double = 0.02

    // MARK: 静止判定

    /// 速度低于这个值就按「静止」处理（归一化单位/秒）。
    /// 参考量级：头以 0.8Hz、幅度 0.15 摆动时峰值速度约 0.75/s；噪声引起的假速度约 0.02/s。
    var restSpeed: Double = 0.06
    /// 速度高于这个值就完全按「移动」处理。
    var movingSpeed: Double = 0.35

    // MARK: 状态

    private(set) var center: CGPoint?
    private(set) var size: CGSize?
    private(set) var velocity: CGVector = .zero
    /// 0 = 静止，1 = 在动。也给别人用（比如 CameraEngine 的歪头角度平滑）。
    private(set) var motion: Double = 0

    private var previousMeasurement: CGRect?
    private var previousMeasurementTime: Double?
    private var lastTime: Double?

    /// 平滑后的当前位置（没有外推）
    var current: CGRect? {
        guard let center, let size else { return nil }
        return CGRect(x: center.x - size.width / 2,
                      y: center.y - size.height / 2,
                      width: size.width,
                      height: size.height)
    }

    /// 贴图实际用的位置：平滑结果 + 速度外推，抵消链路延迟。
    var predicted: CGRect? {
        guard let current else { return nil }
        return current.offsetBy(dx: velocity.dx * leadTime, dy: velocity.dy * leadTime)
    }

    mutating func reset() {
        center = nil
        size = nil
        velocity = .zero
        motion = 0
        previousMeasurement = nil
        previousMeasurementTime = nil
        lastTime = nil
    }

    /// 每个视频帧调用一次。`measurement` 为 nil 表示这一帧没跑检测。
    mutating func update(measurement: CGRect?, at time: Double) {
        guard let lastTime else {
            self.lastTime = time
            if let measurement { seed(measurement) }
            return
        }
        // 时间差做钳制：掉帧或暂停恢复时不要算出爆炸的速度
        let dt = min(max(time - lastTime, 1.0 / 240.0), 0.25)
        self.lastTime = time

        guard let measurement else {
            // 这一帧没测到：让速度自然衰减，只做很短距离的惯性，不无限外推
            velocity = CGVector(dx: velocity.dx * 0.7, dy: velocity.dy * 0.7)
            updateMotion()
            _ = dt
            return
        }

        if let previous = previousMeasurement, let previousTime = previousMeasurementTime {
            let measurementDt = time - previousTime
            if measurementDt > 0 {
                let observed = CGVector(dx: (measurement.midX - previous.midX) / measurementDt,
                                        dy: (measurement.midY - previous.midY) / measurementDt)
                velocity = CGVector(dx: velocity.dx + (observed.dx - velocity.dx) * velocityGain,
                                    dy: velocity.dy + (observed.dy - velocity.dy) * velocityGain)
            }
        }
        previousMeasurement = measurement
        previousMeasurementTime = time

        updateMotion()

        guard let currentCenter = center, let currentSize = size else {
            seed(measurement)
            return
        }

        let pg = lerp(restPositionGain, positionGain, motion)
        let sg = lerp(restSizeGain, sizeGain, motion)

        center = CGPoint(x: currentCenter.x + (measurement.midX - currentCenter.x) * pg,
                         y: currentCenter.y + (measurement.midY - currentCenter.y) * pg)
        size = CGSize(width: currentSize.width + (measurement.width - currentSize.width) * sg,
                      height: currentSize.height + (measurement.height - currentSize.height) * sg)
    }

    /// 按当前速度大小算出「有多动」，0…1
    private mutating func updateMotion() {
        let speed = (velocity.dx * velocity.dx + velocity.dy * velocity.dy).squareRoot()
        let span = max(movingSpeed - restSpeed, 0.0001)
        motion = min(max((speed - restSpeed) / span, 0), 1)
    }

    private func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private mutating func seed(_ measurement: CGRect) {
        center = CGPoint(x: measurement.midX, y: measurement.midY)
        size = measurement.size
    }
}
