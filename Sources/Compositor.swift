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

    /// 算出脸罩应该画在哪（像素坐标，左下角原点）。
    ///
    /// `drawOverlay` 和调试框都走这一个函数 —— 否则「画出来的框」和「实际贴的图」
    /// 可能因为两边各算一遍而慢慢分岔，调试框就失去意义了。
    static func overlayTargetRect(overlay: CGImage,
                                  faceNormalized: CGRect,
                                  frameWidth: CGFloat,
                                  frameHeight: CGFloat,
                                  sizeScale: Double,
                                  offsetX: Double,
                                  offsetY: Double) -> CGRect {
        let face = CGRect(x: faceNormalized.minX * frameWidth,
                          y: faceNormalized.minY * frameHeight,
                          width: faceNormalized.width * frameWidth,
                          height: faceNormalized.height * frameHeight)

        let targetWidth = face.width * CGFloat(sizeScale)
        let targetHeight = targetWidth * CGFloat(overlay.height) / CGFloat(max(overlay.width, 1))

        // offsetY 为正值时图片向下移
        return CGRect(x: face.midX - targetWidth / 2 + CGFloat(offsetX) * face.width,
                      y: face.midY - targetHeight / 2 - CGFloat(offsetY) * face.height,
                      width: targetWidth,
                      height: targetHeight)
    }

    /// 把脸罩图片画到画面上。
    ///
    /// `faceNormalized` 必须是 **在这一帧最终方向下** 检测出来的人脸框。
    static func drawOverlay(overlay: CGImage,
                            into pixelBuffer: CVPixelBuffer,
                            faceNormalized: CGRect,
                            sizeScale: Double,
                            offsetX: Double,
                            offsetY: Double,
                            rotationRadians: Double = 0) {

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

        let target = overlayTargetRect(overlay: overlay,
                                       faceNormalized: faceNormalized,
                                       frameWidth: CGFloat(width),
                                       frameHeight: CGFloat(height),
                                       sizeScale: sizeScale,
                                       offsetX: offsetX,
                                       offsetY: offsetY)

        // 围绕脸中心旋转，让头套能跟着歪头；图片本身仍不会被左右镜像。
        // 不直接旋转整帧，否则摄像头背景也会跟着倾斜。
        ctx.saveGState()
        ctx.translateBy(x: target.midX, y: target.midY)
        ctx.rotate(by: CGFloat(rotationRadians))
        ctx.draw(overlay, in: CGRect(x: -target.width / 2,
                                    y: -target.height / 2,
                                    width: target.width,
                                    height: target.height))
        ctx.restoreGState()
    }

    /// 脸罩素材里「脸应该露出来的那块」相对素材画布的比例。
    ///
    /// 由 `CoverGeometry.measure` 在素材载入时量一次得到。
    /// 有了它，预览上就能把开口画出来 —— 「脸有没有落在开口里」一眼可见，
    /// 不用再靠感觉判断是没对准、还是本来就该这样。
    ///
    /// 注意 y 的方向：这里用的是 `CoverGeometry` 量出来的坐标系，**自素材顶部向下**，
    /// 和直觉相反。不要按「向上为正」去理解它 —— `rect(in:)` 会把它正确映射到画面，
    /// `Tests/Compositor` 的 [H] 段有像素级断言专门盯着这个方向没搞反。
    struct OpeningGuide: Equatable {
        /// 开口宽 / 素材画布宽
        let widthFraction: Double
        /// 开口高 / 素材画布**宽**（用宽做基准，这样和贴图的宽度缩放是同一个尺度）
        let heightFraction: Double
        /// 开口中心相对素材画布中心的偏移，按画布宽归一化
        let offsetX: Double
        let offsetY: Double

        /// 开口落在画面上的实际矩形
        func rect(in target: CGRect) -> CGRect {
            let w = CGFloat(widthFraction) * target.width
            let h = CGFloat(heightFraction) * target.width
            let cx = target.midX + CGFloat(offsetX) * target.width
            let cy = target.midY + CGFloat(offsetY) * target.width
            return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        }
    }

    /// 只在预览上画的调试框。
    ///
    /// 画三样东西：
    /// - **绿框**：Vision 检测到的人脸框（贴图就是按它的中心和宽度算的）
    /// - **品红框**：脸罩实际占的画面范围
    /// - **青框**：脸罩素材里的面孔开口 —— 脸应该正好落在这里面
    ///
    /// **绝不能画进录制的画面**，所以调用点必须在写文件之后。
    static func drawDebugBox(into pixelBuffer: CVPixelBuffer,
                             faceNormalized: CGRect,
                             overlay: CGImage?,
                             opening: OpeningGuide?,
                             sizeScale: Double,
                             offsetX: Double,
                             offsetY: Double) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let frameWidth = CGFloat(width)
        let frameHeight = CGFloat(height)

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

        let lineWidth = max(2, frameWidth / 320)

        // 1. 人脸框
        let rect = CGRect(x: faceNormalized.minX * frameWidth,
                          y: faceNormalized.minY * frameHeight,
                          width: faceNormalized.width * frameWidth,
                          height: faceNormalized.height * frameHeight)

        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0, 1, 0.4, 1])!)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(rect)

        // 十字准星标出中心，方便判断有没有整体偏移
        ctx.move(to: CGPoint(x: rect.midX - lineWidth * 4, y: rect.midY))
        ctx.addLine(to: CGPoint(x: rect.midX + lineWidth * 4, y: rect.midY))
        ctx.move(to: CGPoint(x: rect.midX, y: rect.midY - lineWidth * 4))
        ctx.addLine(to: CGPoint(x: rect.midX, y: rect.midY + lineWidth * 4))
        ctx.strokePath()

        guard let overlay else { return }

        // 2. 脸罩实际范围
        let target = overlayTargetRect(overlay: overlay,
                                       faceNormalized: faceNormalized,
                                       frameWidth: frameWidth,
                                       frameHeight: frameHeight,
                                       sizeScale: sizeScale,
                                       offsetX: offsetX,
                                       offsetY: offsetY)
        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [1, 0.25, 0.85, 1])!)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(target)

        // 3. 面孔开口 —— 脸应该正好露在这块里面
        guard let opening else { return }
        let openingRect = opening.rect(in: target)
        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.25, 0.85, 1, 1])!)
        ctx.setLineWidth(lineWidth)
        ctx.stroke(openingRect)

        // 开口中心到人脸中心的连线，一眼看出差多少
        ctx.setStrokeColor(CGColor(colorSpace: colorSpace, components: [0.25, 0.85, 1, 0.6])!)
        ctx.setLineWidth(max(1, lineWidth / 2))
        ctx.move(to: CGPoint(x: rect.midX, y: rect.midY))
        ctx.addLine(to: CGPoint(x: openingRect.midX, y: openingRect.midY))
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
