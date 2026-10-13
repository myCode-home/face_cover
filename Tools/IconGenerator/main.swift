import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 生成 App 图标。
//
//   用法: genicon <输出目录>
//   产出: AppIcon.png          1024×1024 主图（给 iconutil 用）
//         AppIcon-preview.png  多尺寸预览图（方便肉眼检查小尺寸下还认不认得出）
//
// 设计思路：一幅图要同时说出「相机」和「盖住脸」。
// 深色镜头 + 一道斜着盖上去的亮色面罩，在 16×16 下也能一眼看出来。
//
// 单独放在 Tools/ 下，不会被 build.sh 的 Sources/*.swift 收进 App。

let canvas = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [r, g, b, a])!
}

// MARK: - 画图标

func makeIcon() -> CGImage {
    let size = CGFloat(canvas)
    let ctx = CGContext(data: nil, width: canvas, height: canvas,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // ---------- 背景圆角方 ----------
    let inset: CGFloat = 80
    let backgroundRect = CGRect(x: inset, y: inset,
                                width: size - inset * 2, height: size - inset * 2)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: backgroundRect, cornerWidth: 224, cornerHeight: 224,
                       transform: nil))
    ctx.clip()
    // 深靛蓝 → 紫罗兰，偏「影像/科技」的色调
    let background = CGGradient(colorsSpace: colorSpace,
                                colors: [color(0.16, 0.20, 0.62),
                                         color(0.42, 0.15, 0.62)] as CFArray,
                                locations: [0, 1])!
    ctx.drawLinearGradient(background,
                           start: CGPoint(x: inset, y: size - inset),
                           end: CGPoint(x: size - inset, y: inset),
                           options: [])
    ctx.restoreGState()

    let center = CGPoint(x: 512, y: 520)

    // ---------- 镜头外圈 ----------
    // 外圈细一点，内圈粗，形成双层镜筒的感觉
    ctx.setStrokeColor(color(1, 1, 1, 0.35))
    ctx.setLineWidth(16)
    ctx.strokeEllipse(in: CGRect(x: center.x - 316, y: center.y - 316,
                                 width: 632, height: 632))

    ctx.setStrokeColor(color(1, 1, 1))
    ctx.setLineWidth(52)
    ctx.strokeEllipse(in: CGRect(x: center.x - 278, y: center.y - 278,
                                 width: 556, height: 556))

    // ---------- 镜片 ----------
    ctx.setFillColor(color(0.07, 0.09, 0.20))
    ctx.fillEllipse(in: CGRect(x: center.x - 246, y: center.y - 246,
                               width: 492, height: 492))

    // 镜片上的玻璃反光：左上角一道弧，给点体积感
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - 246, y: center.y - 246,
                              width: 492, height: 492))
    ctx.clip()
    let glass = CGGradient(colorsSpace: colorSpace,
                           colors: [color(0.55, 0.75, 1.0, 0.55),
                                    color(0.55, 0.75, 1.0, 0.0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawRadialGradient(glass,
                           startCenter: CGPoint(x: center.x - 90, y: center.y + 110),
                           startRadius: 0,
                           endCenter: CGPoint(x: center.x - 90, y: center.y + 110),
                           endRadius: 300,
                           options: [])
    ctx.restoreGState()

    // 光圈叶片：画成正六边形。这是「这是镜头」最直接的视觉信号，
    // 太淡就等于没有，所以透明度给到 0.26。
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: center.x - 246, y: center.y - 246,
                              width: 492, height: 492))
    ctx.clip()
    ctx.setStrokeColor(color(1, 1, 1, 0.26))
    ctx.setLineWidth(16)
    ctx.setLineJoin(.round)
    let irisRadius: CGFloat = 168
    let irisRotation = 18.0 * .pi / 180
    for i in 0..<6 {
        let angle = Double(i) * .pi / 3 + irisRotation
        let point = CGPoint(x: center.x + cos(angle) * irisRadius,
                            y: center.y + sin(angle) * irisRadius)
        if i == 0 { ctx.move(to: point) } else { ctx.addLine(to: point) }
    }
    ctx.closePath()
    ctx.strokePath()
    ctx.restoreGState()

    // ---------- 面罩 ----------
    // 斜着盖在镜头上。这是整个图标最有辨识度的一块，
    // 深色圆 + 一道亮色斜带，缩到 16×16 也还看得出来。
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 40,
                  color: color(0.02, 0.02, 0.12, 0.45))
    ctx.translateBy(x: 512, y: 458)
    ctx.rotate(by: -16 * .pi / 180)

    let maskWidth: CGFloat = 566
    let maskHeight: CGFloat = 236
    let maskPath = CGPath(roundedRect: CGRect(x: -maskWidth / 2, y: -maskHeight / 2,
                                              width: maskWidth, height: maskHeight),
                          cornerWidth: 96, cornerHeight: 96, transform: nil)
    ctx.addPath(maskPath)
    ctx.setFillColor(color(1.0, 0.68, 0.20))
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(maskPath)
    ctx.clip()

    // 上下两道压边，让它更像面罩而不是一块色板
    ctx.setStrokeColor(color(0.85, 0.48, 0.06, 0.65))
    ctx.setLineWidth(16)
    for offset in [-62.0, 62.0] as [CGFloat] {
        ctx.move(to: CGPoint(x: -maskWidth / 2, y: offset))
        ctx.addLine(to: CGPoint(x: maskWidth / 2, y: offset))
    }
    ctx.strokePath()

    // 左上往右下的高光
    let sheen = CGGradient(colorsSpace: colorSpace,
                           colors: [color(1, 1, 1, 0.42), color(1, 1, 1, 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(sheen,
                           start: CGPoint(x: -maskWidth / 2, y: maskHeight / 2),
                           end: CGPoint(x: maskWidth / 6, y: -maskHeight / 2),
                           options: [])
    ctx.restoreGState()

    // 两侧耳带：加上这两笔，才像「面罩」而不是一条随便的色带
    ctx.setStrokeColor(color(1.0, 0.68, 0.20))
    ctx.setLineWidth(26)
    for side in [-1.0, 1.0] as [CGFloat] {
        let radius: CGFloat = 52
        let x = side * (maskWidth / 2 + radius * 0.72)
        ctx.addArc(center: CGPoint(x: x, y: 0), radius: radius,
                   startAngle: 0, endAngle: .pi * 2, clockwise: false)
    }
    ctx.strokePath()
    ctx.restoreGState()

    // ---------- 录制指示红点 ----------
    let dotCenter = CGPoint(x: 800, y: 800)
    ctx.setFillColor(color(0.10, 0.10, 0.18))
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - 68, y: dotCenter.y - 68,
                               width: 136, height: 136))
    ctx.setFillColor(color(1.0, 0.26, 0.32))
    ctx.fillEllipse(in: CGRect(x: dotCenter.x - 48, y: dotCenter.y - 48,
                               width: 96, height: 96))

    return ctx.makeImage()!
}

// MARK: - 写 PNG

func write(_ image: CGImage, to path: String) {
    let url = URL(fileURLWithPath: path)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else {
        FileHandle.standardError.write(Data("无法写入 \(path)\n".utf8))
        exit(1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("写入失败 \(path)\n".utf8))
        exit(1)
    }
    print("已生成 \(path)")
}

// MARK: - 多尺寸预览图

func makePreview(icon: CGImage) -> CGImage {
    let width = 1040, height = 660
    let ctx = CGContext(data: nil, width: width, height: height,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    let splitY: CGFloat = 330
    // 上半浅色（模拟浅色模式访达），下半深色
    ctx.setFillColor(color(0.95, 0.95, 0.96))
    ctx.fill(CGRect(x: 0, y: splitY, width: CGFloat(width), height: CGFloat(height) - splitY))
    ctx.setFillColor(color(0.12, 0.12, 0.14))
    ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: splitY))

    func label(_ text: String, at point: CGPoint, size: CGFloat, light: Bool) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: light ? color(0.30, 0.30, 0.35) : color(0.72, 0.72, 0.78)
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes)
        )
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }

    label("浅色背景", at: CGPoint(x: 40, y: 612), size: 20, light: true)
    label("深色背景", at: CGPoint(x: 40, y: 292), size: 20, light: false)

    // 大图
    ctx.draw(icon, in: CGRect(x: 40, y: 348, width: 250, height: 250))

    // 一排小尺寸，顶部对齐，数字标在下面
    let rowTop: CGFloat = 596
    var x: CGFloat = 340
    for size in [128, 96, 64, 48, 32, 24, 16] {
        let side = CGFloat(size)
        ctx.draw(icon, in: CGRect(x: x, y: rowTop - side, width: side, height: side))
        label("\(size)", at: CGPoint(x: x, y: rowTop - side - 26), size: 15, light: true)
        x += side + 26
    }

    // 深色底上再放一排
    x = 340
    for size in [128, 64, 32] {
        let side = CGFloat(size)
        ctx.draw(icon, in: CGRect(x: x, y: 150, width: side, height: side))
        label("\(size)", at: CGPoint(x: x, y: 122), size: 15, light: false)
        x += side + 34
    }

    return ctx.makeImage()!
}

// MARK: - 入口

let outputDirectory = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let icon = makeIcon()
write(icon, to: (outputDirectory as NSString).appendingPathComponent("AppIcon.png"))
write(makePreview(icon: icon),
      to: (outputDirectory as NSString).appendingPathComponent("AppIcon-preview.png"))
