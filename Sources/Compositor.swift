import CoreGraphics
import CoreVideo
import Foundation

/// 画面处理。坐标系说明（这是整个项目最容易搞错的地方，改动前请先看测试）：
///
/// - Vision 检测出的人脸框是「归一化 + 左下角为原点」。
/// - CGBitmapContext 直接架在 CVPixelBuffer 的内存上时，坐标原点也在左下角，
///   而 buffer 的第 0 行内存对应画面顶部 —— 两者天然对齐，所以 **不需要** 做 Y 轴翻转。
/// - **镜像和贴图必须是两步，而且镜像必须在人脸检测之前。**
///   人脸的「反向移动」几乎总是因为整帧被翻了两次（采集连接自己镜像过一次，
///   这里又翻一次）。所以采集连接被强制设成不镜像，翻转只在这里发生一次。
enum Compositor {

    /// 用 sRGB 而不是 CGColorSpaceCreateDeviceRGB()。
    /// 摄像头画面和普通 PNG 素材都是 sRGB，用设备色彩空间会多做一次色彩转换，
    /// 导致贴到视频上的图片颜色发灰偏色（实测纯洋红 (1,0,1) 会变成 (255,64,255)）。
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()

    /// 需要镜像时，就地按行左右翻转整帧。
    ///
    /// 必须画脸罩 **之前** 调用，这样人脸检测和贴图都发生在最终方向的画面上，
    /// 两者不可能算出不同的位置。
    static func mirrorIfNeeded(_ pixelBuffer: CVPixelBuffer, mirror: Bool) {
        guard mirror else { return }
        flipHorizontally(pixelBuffer)
    }

    /// 把脸罩图片画到画面上。
    ///
    /// `faceNormalized` 必须是 **在这一帧最终方向下** 检测出来的人脸框。
    static func drawOverlay(overlay: CGImage,
                            into pixelBuffer: CVPixelBuffer,
                            faceNormalized: CGRect,
                            sizeScale: Double,
                            offsetX: Double,
                            offsetY: Double) {

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(data: base,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        let frameWidth = CGFloat(width)
        let frameHeight = CGFloat(height)

        let face = CGRect(x: faceNormalized.minX * frameWidth,
                          y: faceNormalized.minY * frameHeight,
                          width: faceNormalized.width * frameWidth,
                          height: faceNormalized.height * frameHeight)

        let targetWidth = face.width * CGFloat(sizeScale)
        let targetHeight = targetWidth * CGFloat(overlay.height) / CGFloat(max(overlay.width, 1))

        // offsetY 为正值时图片向下移
        let target = CGRect(x: face.midX - targetWidth / 2 + CGFloat(offsetX) * face.width,
                            y: face.midY - targetHeight / 2 - CGFloat(offsetY) * face.height,
                            width: targetWidth,
                            height: targetHeight)

        // CTM 没有翻转，图片会正着画上去，不会被左右镜像
        ctx.draw(overlay, in: target)
    }

    /// 只在预览上画的调试框：把人脸框描出来。
    /// 用来一眼判断「遮罩有没有落在脸上」。**绝不能画进录制的画面**，
    /// 所以调用点必须在写文件之后。
    static func drawDebugBox(into pixelBuffer: CVPixelBuffer, faceNormalized: CGRect) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(data: base,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                            | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }

        let frameWidth = CGFloat(width)
        let frameHeight = CGFloat(height)
        let rect = CGRect(x: faceNormalized.minX * frameWidth,
                          y: faceNormalized.minY * frameHeight,
                          width: faceNormalized.width * frameWidth,
                          height: faceNormalized.height * frameHeight)
        let lineWidth = max(2, frameWidth / 320)

        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0, 1, 0.4, 1])!)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(rect)

        // 十字准星标出中心，方便判断有没有整体偏移
        ctx.setLineWidth(lineWidth)
        ctx.move(to: CGPoint(x: rect.midX - lineWidth * 4, y: rect.midY))
        ctx.addLine(to: CGPoint(x: rect.midX + lineWidth * 4, y: rect.midY))
        ctx.move(to: CGPoint(x: rect.midX, y: rect.midY - lineWidth * 4))
        ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY + lineWidth * 4))
        ctx.strokePath()
    }

    /// 就地按行左右翻转像素。整帧一次性翻转，而不是只翻后画上去的图片。
    private static func flipHorizontally(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 1 else { return }

        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt32.self)
            var left = 0
            var right = width - 1
            while left < right {
                let tmp = row[left]
                row[left] = row[right]
                row[right] = tmp
                left += 1
                right -= 1
            }
        }
    }
}
