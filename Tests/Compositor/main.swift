import CoreGraphics
import CoreVideo
import Foundation

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

print("")
if failures == 0 {
    print("全部通过 ✅")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
