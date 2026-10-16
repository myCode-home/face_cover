import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 脸罩素材的测量 / 归一化 / 合成验收工具。
//
//   covers analyze   <png...>                        量出每张的锚点、尺寸和包围盒
//   covers fit       <画布边长> <png...>              算「所有素材都不被裁切」时能用的最大锚点宽
//   covers sheet     <out.png> <png...>              拼对照图，把锚点框和轮廓框出来
//   covers normalize <outDir> <画布边长> <锚点宽> <png...>   按给定锚点宽归一化后写出
//   covers verify    <png...>                        复查：锚点占比是否一致、是否居中
//   covers preview   <out.png> <sizeScale> <png...>  照 Compositor 的逻辑合成到一张合成脸上，肉眼验收
//
// 两种素材类型，用环境变量切换：
//   COVERS_KIND=hood（默认）  头套：有透明面孔开口，锚点 = 开口
//   COVERS_KIND=mask          整脸覆盖：没有开口，锚点 = 轮廓包围盒
//
// 编译（要带上 Sources/CoverGeometry.swift，几何逻辑是共用的）:
//   swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
//     Sources/CoverGeometry.swift Tools/CoverNormalizer/main.swift -o .build/covers

let kindIsMask = (ProcessInfo.processInfo.environment["COVERS_KIND"] ?? "hood") == "mask"
let alphaCut = UInt8(ProcessInfo.processInfo.environment["COVERS_ALPHA"] ?? "")
    ?? CoverGeometry.defaultAlphaCut

let cs = CGColorSpace(name: CGColorSpace.sRGB)!

/// 按素材类型选测量方式。两者都返回 `CoverGeometry.Opening`，下游代码不用分叉。
func measure(_ path: String) -> CoverGeometry.Opening? {
    kindIsMask
        ? CoverGeometry.measureMask(path: path, alphaCut: alphaCut)
        : CoverGeometry.measure(path: path, alphaCut: alphaCut)
}

func makeContext(_ w: Int, _ h: Int) -> CGContext {
    CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func write(_ image: CGImage, to path: String) {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        FileHandle.standardError.write(Data("无法写 \(path)\n".utf8)); exit(1)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        FileHandle.standardError.write(Data("写失败 \(path)\n".utf8)); exit(1)
    }
}

func shortName(_ path: String) -> String {
    URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        .replacingOccurrences(of: "src-", with: "")
}

// MARK: - 子命令

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print("用法: covers analyze|fit|sheet|normalize|verify|preview ..."); exit(1)
}
func paths(_ from: Int) -> [String] { Array(args.dropFirst(from)) }

print("# 素材类型: \(kindIsMask ? "整脸覆盖（锚点=轮廓）" : "头套（锚点=面孔开口）")   alpha 阈值: \(alphaCut)\n")

switch command {

case "analyze":
    print("素材            锚点宽  锚点高  占画布  心x    心y    横余量 纵余量 轮廓宽×高")
    for p in paths(1) {
        guard let g = measure(p) else { print("\(p): 读不到"); continue }
        print(String(format: "%-14@ %7.1f %7.1f %7.4f %6.3f %6.3f %7.1f %7.1f  %.0f×%.0f",
                     shortName(p) as NSString,
                     g.openingWidth, g.openingHeight, g.openingFraction,
                     g.center.x / CGFloat(g.canvasSize), g.center.y / CGFloat(g.canvasSize),
                     g.reach.width, g.reach.height,
                     g.silhouetteBox.width, g.silhouetteBox.height))
    }

case "fit":
    // 归一化到锚点宽 W 后，包围盒相对锚点中心的距离会放大 W/锚点宽 倍。
    // 要保证 ≤ 画布半宽，于是 W ≤ half * 锚点宽 / reach。取所有素材的下界。
    guard args.count >= 3, let canvas = Int(args[1]) else {
        print("用法: covers fit <画布边长> <png...>"); exit(1)
    }
    let half = CGFloat(canvas) / 2
    var limit = CGFloat.greatestFiniteMagnitude
    var binding = ""
    for p in paths(2) {
        guard let g = measure(p) else { continue }
        let byW = half * g.openingWidth / g.reach.width
        let byH = half * g.openingWidth / g.reach.height
        let v = min(byW, byH)
        print(String(format: "  %-14@ 允许锚点宽 ≤ %7.1f  (%@向受限)",
                     shortName(p) as NSString, v, (byW < byH ? "横" : "纵") as NSString))
        if v < limit { limit = v; binding = shortName(p) }
    }
    print(String(format: "\n所有素材都不被裁切的最大锚点宽: %.1f px  (受限于 %@)", limit, binding as NSString))
    print(String(format: "对应 锚点占画布 = %.4f", limit / CGFloat(canvas)))

case "sheet":
    guard args.count >= 3 else { print("用法: covers sheet <out.png> <png...>"); exit(1) }
    let out = args[1]
    let list = paths(2)
    let cell = 300, label: CGFloat = 30, cols = 4
    let rows = (list.count + cols - 1) / cols
    let W = cell * cols, H = (cell + Int(label)) * rows
    let ctx = makeContext(W, H)
    ctx.setFillColor(CGColor(colorSpace: cs, components: [0.88, 0.88, 0.90, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    for (i, p) in list.enumerated() {
        let col = i % cols, row = i / cols
        let cellBottom = CGFloat(H - (row + 1) * (cell + Int(label)))
        let cellRect = CGRect(x: CGFloat(col * cell), y: cellBottom,
                              width: CGFloat(cell), height: CGFloat(cell))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.76, 0.76, 0.80, 1])!)
        ctx.fill(cellRect.insetBy(dx: 4, dy: 4))

        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        let scale = (CGFloat(cell) - 16) / CGFloat(img.width)
        let dw = CGFloat(img.width) * scale, dh = CGFloat(img.height) * scale
        let origin = CGPoint(x: cellRect.midX - dw / 2, y: cellRect.midY - dh / 2)
        ctx.draw(img, in: CGRect(x: origin.x, y: origin.y, width: dw, height: dh))

        var caption = shortName(p)
        if let g = measure(p) {
            func stroke(_ box: CGRect, _ r: CGFloat, _ gg: CGFloat, _ b: CGFloat, _ w: CGFloat) {
                ctx.setStrokeColor(CGColor(colorSpace: cs, components: [r, gg, b, 0.95])!)
                ctx.setLineWidth(w)
                ctx.stroke(CGRect(x: origin.x + box.minX * scale,
                                  y: origin.y + box.minY * scale,
                                  width: box.width * scale, height: box.height * scale))
            }
            stroke(g.silhouetteBox, 0.15, 0.45, 0.90, 1)      // 轮廓：蓝
            stroke(g.openingBox, 0.85, 0.20, 0.20, 1.5)        // 锚点：红
            let c = CGPoint(x: origin.x + g.center.x * scale, y: origin.y + g.center.y * scale)
            ctx.setStrokeColor(CGColor(colorSpace: cs, components: [0.10, 0.45, 0.90, 1])!)
            ctx.setLineWidth(1.5)
            ctx.move(to: CGPoint(x: c.x - 9, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 9, y: c.y))
            ctx.move(to: CGPoint(x: c.x, y: c.y - 9)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 9))
            ctx.strokePath()
            caption += "  锚点 \(Int(g.openingWidth))×\(Int(g.openingHeight))"
        }

        let line = CTLineCreateWithAttributedString(NSAttributedString(string: caption, attributes: [
            .font: CTFontCreateWithName("Helvetica" as CFString, 13, nil),
            .foregroundColor: CGColor(colorSpace: cs, components: [0.15, 0.15, 0.18, 1])!
        ]))
        ctx.textPosition = CGPoint(x: cellRect.minX + 8, y: cellBottom - 22)
        CTLineDraw(line, ctx)
    }
    write(ctx.makeImage()!, to: out)
    print("已生成 \(out)")

case "normalize":
    guard args.count >= 5 else {
        print("用法: covers normalize <outDir> <画布边长> <锚点宽> <png...>"); exit(1)
    }
    let outDir = args[1]
    guard let canvas = Int(args[2]), let tw = Double(args[3]) else {
        print("画布边长和锚点宽都要是数"); exit(1)
    }
    let TW = CGFloat(tw)
    let half = CGFloat(canvas) / 2
    try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    var worst = CGFloat(0)
    for p in paths(4) {
        guard let g = measure(p),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("跳过 \(p)"); continue
        }
        let s = TW / g.openingWidth
        let overflowW = g.reach.width * s - half
        let overflowH = g.reach.height * s - half
        worst = max(worst, max(overflowW, overflowH))

        let ctx = makeContext(canvas, canvas)
        ctx.interpolationQuality = .high
        ctx.translateBy(x: half, y: half)
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -g.center.x, y: -g.center.y)
        ctx.draw(img, in: CGRect(x: 0, y: 0,
                                 width: CGFloat(g.canvasSize), height: CGFloat(g.canvasSize)))

        // 不做任何挖洞：开口本来就是透明的，缩放产生的半透明边缘是正确的抗锯齿，
        // 强行挖一个椭圆会把凸进洞里的鼻子 / 牙齿一起抹掉。

        let name = shortName(p)
        let out = (outDir as NSString).appendingPathComponent("\(name).png")
        write(ctx.makeImage()!, to: out)
        print(String(format: "已写出 %-14@ 缩放 %.3f×  溢出 横%+.0f 纵%+.0f",
                     name as NSString, s, overflowW, overflowH))
    }
    print(worst <= 0
          ? "\n✅ 没有任何素材被裁切（最紧的一边还差 \(String(format: "%.1f", -worst))px）"
          : "\n⚠️ 有素材被裁切，最多超出画布 \(String(format: "%.1f", worst))px —— 需要调小锚点宽")

case "verify":
    var fractions: [CGFloat] = []
    var maxOffCenter = CGFloat(0)
    print("素材            锚点宽  占画布   中心偏移(px)")
    for p in paths(1) {
        guard let g = measure(p) else { continue }
        fractions.append(g.openingFraction)
        maxOffCenter = max(maxOffCenter, g.centerOffset)
        print(String(format: "%-14@ %7.1f %7.4f %10.1f",
                     shortName(p) as NSString, g.openingWidth, g.openingFraction, g.centerOffset))
    }
    if let lo = fractions.min(), let hi = fractions.max() {
        print(String(format: "\n锚点占比 %.4f … %.4f  (极差 %.4f)", lo, hi, hi - lo))
    }
    print(String(format: "最大中心偏移 %.1f px", maxOffCenter))

case "preview":
    guard args.count >= 4 else { print("用法: covers preview <out.png> <sizeScale> <png...>"); exit(1) }
    let out = args[1]
    guard let scaleFactor = Double(args[2]) else { print("sizeScale 要是个数"); exit(1) }
    let list = paths(3)

    let cellW = 300, cellH = 380, label: CGFloat = 34, cols = 4
    let rows = (list.count + cols - 1) / cols
    let W = cellW * cols, H = (cellH + Int(label)) * rows
    let ctx = makeContext(W, H)
    ctx.setFillColor(CGColor(colorSpace: cs, components: [0.30, 0.31, 0.34, 1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    for (i, p) in list.enumerated() {
        let col = i % cols, row = i / cols
        let cellBottom = CGFloat(H - (row + 1) * (cellH + Int(label)))
        let cellRect = CGRect(x: CGFloat(col * cellW), y: cellBottom,
                              width: CGFloat(cellW), height: CGFloat(cellH))

        // Vision 人脸框大致「宽:高 = 3:4」，取脸宽 = 画布宽的 1/3
        let faceW = cellRect.width * 0.33
        let faceH = faceW / 0.75
        let faceCenter = CGPoint(x: cellRect.midX, y: cellRect.midY)

        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.92, 0.76, 0.66, 1])!)
        ctx.fillEllipse(in: CGRect(x: faceCenter.x - faceW / 2, y: faceCenter.y - faceH / 2,
                                   width: faceW, height: faceH))
        ctx.setFillColor(CGColor(colorSpace: cs, components: [0.15, 0.15, 0.20, 1])!)
        for sx in [-0.22, 0.22] as [CGFloat] {
            let eye = CGPoint(x: faceCenter.x + faceW * sx, y: faceCenter.y + faceH * 0.12)
            ctx.fillEllipse(in: CGRect(x: eye.x - faceW * 0.055, y: eye.y - faceW * 0.055,
                                       width: faceW * 0.11, height: faceW * 0.11))
        }
        ctx.setStrokeColor(CGColor(colorSpace: cs, components: [0.55, 0.30, 0.30, 1])!)
        ctx.setLineWidth(max(1.5, faceW * 0.02))
        ctx.addArc(center: CGPoint(x: faceCenter.x, y: faceCenter.y - faceH * 0.10),
                   radius: faceW * 0.20, startAngle: .pi * 1.15, endAngle: .pi * 1.85,
                   clockwise: false)
        ctx.strokePath()

        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
        let targetW = faceW * CGFloat(scaleFactor)
        let targetH = targetW * CGFloat(img.height) / CGFloat(img.width)
        ctx.draw(img, in: CGRect(x: faceCenter.x - targetW / 2, y: faceCenter.y - targetH / 2,
                                 width: targetW, height: targetH))

        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: "\(shortName(p))  \(String(format: "%.2f", scaleFactor))×",
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil),
                         .foregroundColor: CGColor(colorSpace: cs,
                                                   components: [0.92, 0.92, 0.95, 1])!]))
        ctx.textPosition = CGPoint(x: cellRect.minX + 8, y: cellBottom - 22)
        CTLineDraw(line, ctx)
    }
    write(ctx.makeImage()!, to: out)
    print("已生成 \(out)")

default:
    print("未知子命令 \(command)")
}
