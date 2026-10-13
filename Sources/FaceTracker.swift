import CoreGraphics
import Foundation

/// 人脸框平滑 + 速度补偿。
///
/// 为什么不能简单地对检测结果做重度平滑：
/// 「每 2 帧检测一次 + 每帧 0.4 插值」这类做法会累积大约 150ms 的延迟。
/// 头来回摆动时，遮罩会滞后接近半个周期 —— 看上去就像 **遮罩在跟脸反向移动**。
///
/// 这里的做法是「轻平滑 + 速度外推」：
/// - 平滑只用来压住 Vision 逐帧的抖动（增益取得比较高，约 1 帧就收敛）；
/// - 再按估计出来的速度往前推 `leadTime` 秒，把「检测 → 合成 → 显示」的链路延迟补掉。
///
/// 所有坐标都是 Vision 的归一化坐标（左下角原点），速度单位是「归一化单位 / 秒」。
struct FaceTracker {

    /// 位置平滑增益。越接近 1 越跟手，越小越稳。
    /// 0.85 是实测出来的：延迟 0 帧、同向 100%、抖动比输入还小。
    var positionGain: Double = 0.85
    /// 人脸框大小的平滑增益（比位置更慢，免得大小一直闪）。
    var sizeGain: Double = 0.35
    /// 速度平滑增益。速度是用来外推的，必须压得比较狠，
    /// 否则逐帧检测噪声会被 `leadTime` 放大，静止时遮罩反而更抖。
    var velocityGain: Double = 0.20
    /// 速度外推提前量（秒）。位置增益已经够跟手了，这里只做一点点补偿。
    var leadTime: Double = 0.02

    private(set) var center: CGPoint?
    private(set) var size: CGSize?
    private(set) var velocity: CGVector = .zero

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

        guard let currentCenter = center, let currentSize = size else {
            seed(measurement)
            return
        }

        center = CGPoint(x: currentCenter.x + (measurement.midX - currentCenter.x) * positionGain,
                         y: currentCenter.y + (measurement.midY - currentCenter.y) * positionGain)
        size = CGSize(width: currentSize.width + (measurement.width - currentSize.width) * sizeGain,
                      height: currentSize.height + (measurement.height - currentSize.height) * sizeGain)
    }

    private mutating func seed(_ measurement: CGRect) {
        center = CGPoint(x: measurement.midX, y: measurement.midY)
        size = measurement.size
    }
}
