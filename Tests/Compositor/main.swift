import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 无头自检：验证「脸罩合成」的坐标、缩放、偏移、镜像行为。
// 运行: ./test.sh

var failures = 0

func check(_ ok: Bool, _ label: String) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

let W = 200
let H = 200

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

/// 在目标色彩空间里直接构造颜色，避免测试自己引入色彩转换
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, 1])!
}

// MARK: 测试素材

/// 左半红、右半绿的不对称图片 —— 用来验证「镜像时图片本身不能被翻过来」
func makeOverlay() -> CGImage {
    let ctx = CGContext(data: nil, width: 100, height: 100,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color(1, 0, 0))
    ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
    ctx.setFillColor(color(0, 1, 0))
    ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
    return ctx.makeImage()!
}

/// 蓝色背景；marker 为 true 时在画面最左边 0..20 画一条洋红色竖条，
/// 用来验证整帧到底有没有被真正左右翻转。
/// face 传「模拟人脸」在画面里的归一化位置（左下角原点），会画成白色方块。
func makeBuffer(marker: Bool = false, face: CGRect? = nil) -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let attrs: [String: Any] = [
        kCVPixelBufferCGImageCompatibilityKey as String: true,
        kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, W, H, kCVPixelFormatType_32BGRA,
                              attrs as CFDictionary, &pixelBuffer) == kCVReturnSuccess,
          let buffer = pixelBuffer else {
        fatalError("无法创建 pixel buffer")
    }

    CVPixelBufferLockBaseAddress(buffer, [])
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    memset(CVPixelBufferGetBaseAddress(buffer), 0, bytesPerRow * H)

    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
                        width: W, height: H,
                        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                        space: srgb,
                        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                  | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(color(0, 0, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    if marker {
        ctx.setFillColor(color(1, 0, 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 20, height: H))
    }

    if let face {
        ctx.setFillColor(color(1, 1, 1))
        ctx.fill(CGRect(x: face.minX * CGFloat(W),
                        y: face.minY * CGFloat(H),
                        width: face.width * CGFloat(W),
                        height: face.height * CGFloat(H)))
    }

    CVPixelBufferUnlockBaseAddress(buffer, [])
    return buffer
}

// MARK: 取样（x 从左边数，yTopDown 从画面顶部往下数）

func pixel(_ buffer: CVPixelBuffer, _ x: Int, _ yTopDown: Int) -> (r: Int, g: Int, b: Int) {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let offset = yTopDown * CVPixelBufferGetBytesPerRow(buffer) + x * 4
    // 32BGRA 在内存里的顺序是 B, G, R, A
    return (Int(base[offset + 2]), Int(base[offset + 1]), Int(base[offset]))
}

func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 200 && p.g < 60 && p.b < 60 }
func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 200 && p.r < 60 && p.b < 60 }
func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 200 && p.r < 60 && p.g < 60 }
func isMagenta(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 200 && p.b > 200 && p.g < 60 }

/// 扫全图，返回满足条件的像素的横向中心（找不到返回 nil）
func horizontalCenter(_ buffer: CVPixelBuffer,
                      where matches: ((r: Int, g: Int, b: Int)) -> Bool) -> Double? {
    var sum = 0
    var count = 0
    for y in stride(from: 0, to: H, by: 2) {
        for x in 0..<W {
            if matches(pixel(buffer, x, y)) {
                sum += x
                count += 1
            }
        }
    }
    guard count > 0 else { return nil }
    return Double(sum) / Double(count)
}

// MARK: 跑测试

let overlay = makeOverlay()

/// 脸在正中：归一化 (0.4, 0.4, 0.2, 0.2) → 像素 x 80..120、y(顶部往下) 80..120
let centeredFace = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)

print("\n[A] 不镜像 · 脸在正中 → 图片盖在正中，左红右绿")
do {
    let buf = makeBuffer(marker: true)
    Compositor.mirrorIfNeeded(buf, mirror: false)
    Compositor.drawOverlay(overlay: overlay, into: buf, faceNormalized: centeredFace,
                           sizeScale: 1.0, offsetX: 0, offsetY: 0)
    check(isRed(pixel(buf, 85, 100)), "脸罩左半是红 (85,100)")
    check(isGreen(pixel(buf, 115, 100)), "脸罩右半是绿 (115,100)")
    check(isRed(pixel(buf, 88, 90)), "脸罩左上仍是红，竖直方向没有翻转")
    check(isBlue(pixel(buf, 150, 10)), "画面右上角保持背景色")
    check(isMagenta(pixel(buf, 10, 100)), "不镜像时洋红标记留在左边 x=10")
    check(isBlue(pixel(buf, 190, 100)), "不镜像时右边没有标记 x=190")
}

print("\n[B] 镜像 · 脸在正中 → 整帧翻转，但图片本身不能左右反过来")
do {
    let buf = makeBuffer(marker: true)
    Compositor.mirrorIfNeeded(buf, mirror: true)
    Compositor.drawOverlay(overlay: overlay, into: buf, faceNormalized: centeredFace,
                           sizeScale: 1.0, offsetX: 0, offsetY: 0)
    check(isMagenta(pixel(buf, 190, 100)), "洋红标记被翻到了右边 x=190")
    check(isBlue(pixel(buf, 10, 100)), "左边原来的标记位置变成背景 x=10")
    check(isRed(pixel(buf, 85, 100)), "正中脸罩左半依然是红（图片没被镜像）")
    check(isGreen(pixel(buf, 115, 100)), "正中脸罩右半依然是绿")
}

print("\n[C] 镜像 · 脸偏左 → 图片必须跟到翻转后的位置")
do {
    let buf = makeBuffer()
    Compositor.mirrorIfNeeded(buf, mirror: true)
    // 未镜像时脸在 x 10..50，翻转后应该出现在 x 150..190。
    // 人脸检测跑在翻转之后，所以检测出来的就是这个位置。
    let detected = CGRect(x: 0.75, y: 0.4, width: 0.2, height: 0.2)
    Compositor.drawOverlay(overlay: overlay, into: buf, faceNormalized: detected,
                           sizeScale: 1.0, offsetX: 0, offsetY: 0)
    check(isRed(pixel(buf, 160, 100)), "翻转后脸罩左半在 x=160")
    check(isGreen(pixel(buf, 180, 100)), "翻转后脸罩右半在 x=180")
    check(isBlue(pixel(buf, 30, 100)), "脸原来的位置已空出来 x=30")
}

// 用户报的问题：开镜像后遮罩和脸反向移动。
// 真实管线是「先翻转整帧 → 再在翻转后的画面上检测人脸 → 再贴图」，
// 所以这里完整模拟这条链路：白色方块 = 模拟的脸，检测结果 = 白色方块翻转后的位置。
print("\n[D] 回归：人脸横向移动时，遮罩必须和人脸同向、且位置重合")
do {
    func runFrame(faceRawX: Double, mirror: Bool) -> (faceCenter: Double, overlayCenter: Double) {
        let size = 0.2
        let rawFace = CGRect(x: faceRawX, y: 0.4, width: size, height: size)
        let buf = makeBuffer(face: rawFace)

        // 第一步：定画面方向
        Compositor.mirrorIfNeeded(buf, mirror: mirror)

        // 第二步：人脸检测（这里用几何推算代替 Vision —— 翻转后脸的位置）
        let detected = mirror
            ? CGRect(x: 1.0 - rawFace.maxX, y: rawFace.minY, width: size, height: size)
            : rawFace

        // 第三步：贴图
        Compositor.drawOverlay(overlay: overlay, into: buf, faceNormalized: detected,
                               sizeScale: 1.0, offsetX: 0, offsetY: 0)

        let faceCenter = (detected.minX + detected.width / 2) * Double(W)
        // 遮罩的位置：扫红/绿像素求横向中心
        let overlayCenter = horizontalCenter(buf) { isRed($0) || isGreen($0) } ?? -1
        return (faceCenter, overlayCenter)
    }

    for mirror in [false, true] {
        let label = mirror ? "开镜像" : "关镜像"
        var previousFace: Double?
        var previousOverlay: Double?
        var allCoincide = true
        var allSameDirection = true

        for rawX in [0.10, 0.25, 0.40, 0.55] {
            let (faceCenter, overlayCenter) = runFrame(faceRawX: rawX, mirror: mirror)

            if abs(faceCenter - overlayCenter) > 3 { allCoincide = false }
            if let pf = previousFace, let po = previousOverlay {
                // 两者位移必须同号（都往左或都往右）
                if (faceCenter - pf) * (overlayCenter - po) < 0 { allSameDirection = false }
            }
            previousFace = faceCenter
            previousOverlay = overlayCenter
        }

        check(allCoincide, "\(label)：每个位置遮罩都落在脸上（误差 <3px）")
        check(allSameDirection, "\(label)：脸往哪边动，遮罩就往哪边动，不反向")
    }

    // 顺带确认镜像确实把画面翻过去了
    let (noMirrorFace, _) = runFrame(faceRawX: 0.10, mirror: false)
    let (mirroredFace, _) = runFrame(faceRawX: 0.10, mirror: true)
    check(noMirrorFace < Double(W) / 2 && mirroredFace > Double(W) / 2,
          "开镜像后脸确实翻到了另一边（\(Int(noMirrorFace)) → \(Int(mirroredFace))）")
}

print("\n[E] 上下偏移 · 正值向下")
do {
    let buf = makeBuffer()
    Compositor.drawOverlay(overlay: overlay, into: buf, faceNormalized: centeredFace,
                           sizeScale: 1.0, offsetX: 0, offsetY: 0.5)
    // 脸高 40px，offsetY 0.5 → 向下移 20px，落到 y(顶部往下) 100..140
    check(isRed(pixel(buf, 90, 120)), "图片下移到 (90,120)")
    check(isBlue(pixel(buf, 90, 90)), "原来上方位置空出来 (90,90)")
}

print("\n[F] 大小缩放")
do {
    let buf = makeBuffer()
    Compositor.drawOverlay(overlay: overlay, into: buf, faceNormalized: centeredFace,
                           sizeScale: 2.0, offsetX: 0, offsetY: 0)
    // 脸宽 40px × 2 = 80px，正中 → x 60..140
    check(isRed(pixel(buf, 70, 100)), "放大后左半红在 x=70")
    check(isGreen(pixel(buf, 130, 100)), "放大后右半绿在 x=130")
}

print("\n[G] 头套旋转 · 歪头时图片要围绕脸中心转动")
do {
    let buf = makeBuffer()
    Compositor.drawOverlay(overlay: overlay, into: buf, faceNormalized: centeredFace,
                           sizeScale: 1.0, offsetX: 0, offsetY: 0,
                           rotationRadians: .pi / 2)

    let upper = pixel(buf, 100, 85)
    let lower = pixel(buf, 100, 115)
    check((isRed(upper) && isGreen(lower)) || (isGreen(upper) && isRed(lower)),
          "旋转 90° 后，原来的左右两半变成上下两半")
    check(isBlue(pixel(buf, 75, 100)) && isBlue(pixel(buf, 125, 100)),
          "旋转只围绕脸中心，不会横向漂移或放大")
}

print("\n[H] 调试框画出的「开口」必须就是脸露出来的位置")
do {
    // H1. 造一张「透明洞故意偏离中心」的素材。
    // 洞偏上 → offsetY 必须为正，而且画出来的开口框要真的落在洞上。
    // 这一条专门防「开口画反了」—— 画反的调试框比没有调试框更害人。
    let canvas = 400
    // 洞必须**包含画布中心**（CoverGeometry 从中心起洪水填充），所以半径给大一点、
    // 中心只往上偏 50px —— 这样既能被量出来，offsetY 又明显不为 0。
    let holeCenter = CGPoint(x: 200.0, y: 250.0)
    let holeRadius: CGFloat = 90
    let art = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8,
                        bytesPerRow: 0, space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    art.setFillColor(color(1, 0, 0))
    art.fill(CGRect(x: 0, y: 0, width: CGFloat(canvas), height: CGFloat(canvas)))
    art.setBlendMode(.clear)
    art.fillEllipse(in: CGRect(x: holeCenter.x - holeRadius, y: holeCenter.y - holeRadius,
                               width: holeRadius * 2, height: holeRadius * 2))
    art.setBlendMode(.normal)
    let artImage = art.makeImage()!

    // CoverGeometry 按文件路径工作，所以先落盘
    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("facecover-opening-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: temp) }
    if let dest = CGImageDestinationCreateWithURL(temp as CFURL,
                                                  UTType.png.identifier as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, artImage, nil)
        CGImageDestinationFinalize(dest)
    }

    if let measured = CoverGeometry.measure(path: temp.path) {
        let size = Double(measured.canvasSize)
        let guide = Compositor.OpeningGuide(
            widthFraction: Double(measured.openingWidth) / size,
            heightFraction: Double(measured.openingHeight) / size,
            offsetX: (Double(measured.center.x) - size / 2) / size,
            offsetY: (Double(measured.center.y) - size / 2) / size)

        // 只断言「明显偏离中心」；方向对不对由下面两条像素断言负责，
        // 那才是真正的判据 —— 符号约定本身不值得写死。
        check(abs(guide.offsetY) > 0.1,
              "洞偏离中心 → offsetY 明显不为 0（实测 \(String(format: "%.3f", guide.offsetY))）")

        let face = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let buf = makeBuffer()
        Compositor.drawOverlay(overlay: artImage, into: buf, faceNormalized: face,
                               sizeScale: 1.0, offsetX: 0, offsetY: 0)
        let target = Compositor.overlayTargetRect(overlay: artImage, faceNormalized: face,
                                                  frameWidth: CGFloat(W), frameHeight: CGFloat(H),
                                                  sizeScale: 1.0, offsetX: 0, offsetY: 0)
        let openingRect = guide.rect(in: target)

        check(isBlue(pixel(buf, Int(openingRect.midX), Int(openingRect.midY))),
              "开口框中心确实是透的（透出背景）")
        check(!isBlue(pixel(buf, Int(openingRect.midX), Int(openingRect.minY - 5))),
              "开口框正下方是实心 —— 洞确实偏上，没有画反")
    } else {
        check(false, "量不出合成素材的开口")
    }

    // H2. 逐款真实素材：guide 算出来的锚点，必须就是「脸露出来 / 被盖住」的那块。
    // 这一条比任何坐标推导都硬 —— 它同时验证了归一化、measure、rect() 和 drawOverlay 四处的方向约定。
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    for cover in HeadCover.all {
        let path = root.appendingPathComponent("Resources/\(cover.id).png").path
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            check(false, "\(cover.name)：读不到素材"); continue
        }

        let measured = cover.kind == .hood
            ? CoverGeometry.measure(path: path)
            : CoverGeometry.measureMask(path: path)
        guard let measured, measured.canvasSize > 0 else {
            check(false, "\(cover.name)：量不出锚点"); continue
        }
        let size = Double(measured.canvasSize)
        let guide = Compositor.OpeningGuide(
            widthFraction: Double(measured.openingWidth) / size,
            heightFraction: Double(measured.openingHeight) / size,
            offsetX: (Double(measured.center.x) - size / 2) / size,
            offsetY: (Double(measured.center.y) - size / 2) / size)

        // 人脸框只占画面中间一小块，否则 sizeScale 2.47 会把脸罩推出缓冲区
        let face = CGRect(x: 0.375, y: 0.375, width: 0.25, height: 0.25)
        let scale = CoverDefaults.defaultSizeScale(for: cover.kind)
        let buf = makeBuffer()
        Compositor.drawOverlay(overlay: img, into: buf, faceNormalized: face,
                               sizeScale: scale, offsetX: 0, offsetY: 0)
        let target = Compositor.overlayTargetRect(overlay: img, faceNormalized: face,
                                                  frameWidth: CGFloat(W), frameHeight: CGFloat(H),
                                                  sizeScale: scale, offsetX: 0, offsetY: 0)
        let anchor = guide.rect(in: target)

        switch cover.kind {
        case .hood:
            // 头套：锚点中心应该透出背景（脸从开口里露出来）
            check(isBlue(pixel(buf, Int(anchor.midX), Int(anchor.midY))),
                  "\(cover.name)：开口中心透出背景")
            // 锚点外侧一点应该是实心的（环有厚度）
            check(!isBlue(pixel(buf, Int(anchor.minX - 6), Int(target.midY))),
                  "\(cover.name)：开口左侧是实心")
        case .mask:
            // 整脸覆盖：锚点（= 整个头）中心应该被盖住，外侧才是背景
            check(!isBlue(pixel(buf, Int(anchor.midX), Int(anchor.midY))),
                  "\(cover.name)：锚点中心被盖住")
            check(isBlue(pixel(buf, Int(target.minX - 12), Int(target.midY))),
                  "\(cover.name)：脸罩范围之外是背景")
        }
    }
}

print("")
if failures == 0 {
    print("全部通过 ✅")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
