import CoreGraphics
import Foundation
import ImageIO

/// 内置头套素材的几何规格 —— **这里是唯一的事实来源**。
/// 归一化工具（`Tools/CoverNormalizer`）和无头自检（`Tests/Cover`）都用它，
/// 免得规格在几个地方各写一遍然后慢慢漂移。
///
/// 规格：素材是正方形、带透明通道的 PNG。中间那个透明连通域是「脸洞开口」，
/// 开口宽必须占画布固定比例，且开口中心必须落在画布正中。
/// 为什么必须这样，见 README 的「内置头套素材」一节 —— 简单说：
/// `Compositor.drawOverlay` 是按目标宽度缩放、以目标中心居中贴图的。
enum CoverGeometry {

    /// 测量时判定「这块被挡住了」的 alpha 阈值。
    ///
    /// 取 128（遮挡 50%）而不是 0：素材边缘是羽化的，阈值太小会把柔软的毛边也算成实体，
    /// 连通域在真正开口边界之前就被拦住；而且鼻子 / 牙齿那侧羽化更重，会把量出的区域挤得偏上。
    static let defaultAlphaCut: UInt8 = 128

    /// 轮廓判定用的低阈值。用来算「不透明包围盒」—— 宁可保守，
    /// 它只服务于「归一化后会不会被裁切」这个判断。
    static let silhouetteAlphaCut: UInt8 = 8

    // MARK: 像素缓冲

    struct Raster {
        let width: Int
        let height: Int
        var pixels: [UInt8]                 // RGBA, premultipliedLast

        /// y 和 `CGContext` 一样**自底部数**（y = 0 是图像底部）。
        ///
        /// 坑：bitmap 内存的第 0 行其实对应图像**顶部**，所以这里必须换算一次。
        /// 早期版本直接按 `y * width + x` 取，量出来的 y 全是上下颠倒的 —— 后果是
        /// 调试框里的青色「开口框」画到了镜像位置，而 [H] 段的取样又把 CG 的 y 当成了
        /// 自上而下的行号，两个错互相抵消，自检一路绿灯。
        @inline(__always) func alpha(_ x: Int, _ y: Int) -> UInt8 {
            pixels[((height - 1 - y) * width + x) * 4 + 3]
        }
        @inline(__always) func isSolid(_ x: Int, _ y: Int, cut: UInt8) -> Bool {
            alpha(x, y) >= cut
        }
        @inline(__always) func isSilhouette(_ x: Int, _ y: Int) -> Bool {
            alpha(x, y) > silhouetteAlphaCut
        }
    }

    static func load(_ path: String) -> Raster? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Raster(width: width, height: height, pixels: pixels)
    }

    // MARK: 测量结果

    struct Opening {
        let name: String
        let canvasSize: Int
        /// 脸洞开口的外接矩形
        let openingBox: CGRect
        /// 不透明包围盒（轮廓阈值）
        let silhouetteBox: CGRect
        /// 最大内切圆半径。**仅供参考，不要拿它当锚点** ——
        /// 鼻子 / 牙齿从下方凸进洞里会把内切圆挤得远小于真实开口（实测猪头 155px vs 真实 457px）。
        let inscribedRadius: CGFloat

        var openingWidth: CGFloat { openingBox.width }
        var openingHeight: CGFloat { openingBox.height }
        var center: CGPoint { CGPoint(x: openingBox.midX, y: openingBox.midY) }

        /// 开口中心到轮廓包围盒四边的最远距离。归一化后会不会被裁切就看它。
        var reach: CGSize {
            let c = center
            return CGSize(width: max(c.x - silhouetteBox.minX, silhouetteBox.maxX - c.x),
                          height: max(c.y - silhouetteBox.minY, silhouetteBox.maxY - c.y))
        }

        /// 开口宽占画布宽的比例 —— 归一化的核心指标，必须对所有素材一致
        var openingFraction: CGFloat { openingWidth / CGFloat(canvasSize) }

        /// 开口中心相对画布正中的偏移（像素）
        var centerOffset: CGFloat {
            max(abs(center.x - CGFloat(canvasSize) / 2),
                abs(center.y - CGFloat(canvasSize) / 2))
        }
    }

    /// 整脸覆盖型素材（玩偶头 / 卡通脸）的测量。
    ///
    /// 这类素材**没有面孔开口** —— 角色自己的脸就是你要看到的东西，整张脸会被盖住。
    /// 所以锚点不是开口，而是**轮廓包围盒的中心**，「尺寸」也直接用轮廓包围盒。
    /// 返回的 `Opening` 把 `openingBox` 填成轮廓包围盒，这样归一化、调试框这些下游代码
    /// 可以和头套共用同一套逻辑，不用分两条路。
    static func measureMask(path: String, alphaCut: UInt8 = defaultAlphaCut) -> Opening? {
        guard let raster = load(path) else { return nil }
        let width = raster.width, height = raster.height
        let name = URL(fileURLWithPath: path).lastPathComponent

        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where raster.isSilhouette(x, y) {
                if x < minX { minX = x }; if x > maxX { maxX = x }
                if y < minY { minY = y }; if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }

        let box = CGRect(x: CGFloat(minX), y: CGFloat(minY),
                         width: CGFloat(maxX - minX + 1),
                         height: CGFloat(maxY - minY + 1))
        return Opening(name: name, canvasSize: width, openingBox: box,
                       silhouetteBox: box, inscribedRadius: 0)
    }

    // MARK: 测量

    /// 量出一张素材的开口和轮廓。
    ///
    /// 返回 nil 的两种情况：图读不出来，或者**画布正中不是透明**（说明这张图根本没有脸洞）。
    static func measure(path: String,
                        alphaCut: UInt8 = defaultAlphaCut,
                        includeInscribedRadius: Bool = false) -> Opening? {
        guard let raster = load(path) else { return nil }
        let width = raster.width, height = raster.height
        let name = URL(fileURLWithPath: path).lastPathComponent

        // 1. 轮廓包围盒
        var sMinX = width, sMaxX = -1, sMinY = height, sMaxY = -1
        for y in 0..<height {
            for x in 0..<width where raster.isSilhouette(x, y) {
                if x < sMinX { sMinX = x }; if x > sMaxX { sMaxX = x }
                if y < sMinY { sMinY = y }; if y > sMaxY { sMaxY = y }
            }
        }
        guard sMaxX >= 0 else { return nil }
        let silhouetteBox = CGRect(x: CGFloat(sMinX), y: CGFloat(sMinY),
                                   width: CGFloat(sMaxX - sMinX + 1),
                                   height: CGFloat(sMaxY - sMinY + 1))

        let cx = width / 2, cy = height / 2

        // 2. 找起点：画布正中通常是透明的。但**不能**要求它一定透明 ——
        //    实测兔子那款归一化时开口恰好压在画布正中（差 1px 就量不出来），
        //    差这几个像素不该让整张图变成「量不出锚点」。从正中向外找最近的透明像素，
        //    绝大多数素材第一次就命中。
        var start: (x: Int, y: Int)?
        var radius = 0
        while start == nil && radius <= max(width, height) / 4 {
            for dy in -radius...radius {
                for dx in -radius...radius where max(abs(dx), abs(dy)) == radius {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    if !raster.isSolid(x, y, cut: alphaCut) { start = (x, y); break }
                }
                if start != nil { break }
            }
            radius += 1
        }
        guard let start else { return nil }

        // 3. 从起点洪水填充，拿到「中间那个洞」这一连通域。
        //    必须从洞里起填：素材外面的背景也是透明的，不区分出来的话会把背景一起算进来。
        //    （下面还有一道保险：开口不能碰到画布边缘，碰到了就说明填到外面去了。）
        var inOpening = [Bool](repeating: false, count: width * height)
        var stack = [start.y * width + start.x]
        inOpening[start.y * width + start.x] = true
        var oMinX = start.x, oMaxX = start.x, oMinY = start.y, oMaxY = start.y

        while let index = stack.popLast() {
            let x = index % width, y = index / width
            if x < oMinX { oMinX = x }; if x > oMaxX { oMaxX = x }
            if y < oMinY { oMinY = y }; if y > oMaxY { oMaxY = y }

            @inline(__always) func push(_ nx: Int, _ ny: Int) {
                guard nx >= 0, nx < width, ny >= 0, ny < height else { return }
                let i = ny * width + nx
                if !inOpening[i] && !raster.isSolid(nx, ny, cut: alphaCut) {
                    inOpening[i] = true
                    stack.append(i)
                }
            }
            push(x - 1, y); push(x + 1, y); push(x, y - 1); push(x, y + 1)
        }

        // 开口必须是**内部**的透明区域。碰到画布边缘 = 填到了外面的背景
        // （整脸覆盖素材就是这样），说明这张图没有面孔开口。
        guard oMinX > 0, oMinY > 0, oMaxX < width - 1, oMaxY < height - 1 else { return nil }

        let openingBox = CGRect(x: CGFloat(oMinX), y: CGFloat(oMinY),
                                width: CGFloat(oMaxX - oMinX + 1),
                                height: CGFloat(oMaxY - oMinY + 1))

        // 3. 最大内切圆（倒角距离变换），只作为参考值
        var inscribed: CGFloat = 0
        if includeInscribedRadius {
            let infinity: Float = 1e9
            var distance = [Float](repeating: 0, count: width * height)
            for i in 0..<(width * height) where inOpening[i] { distance[i] = infinity }
            let d1: Float = 1, d2: Float = 1.41421356

            for y in 0..<height {
                for x in 0..<width {
                    let i = y * width + x
                    guard distance[i] > 0 else { continue }
                    var best = distance[i]
                    if x > 0 { best = min(best, distance[i - 1] + d1) }
                    if y > 0 { best = min(best, distance[i - width] + d1) }
                    if x > 0 && y > 0 { best = min(best, distance[i - width - 1] + d2) }
                    if x + 1 < width && y > 0 { best = min(best, distance[i - width + 1] + d2) }
                    distance[i] = best
                }
            }
            for y in stride(from: height - 1, through: 0, by: -1) {
                for x in stride(from: width - 1, through: 0, by: -1) {
                    let i = y * width + x
                    guard distance[i] > 0 else { continue }
                    var best = distance[i]
                    if x + 1 < width { best = min(best, distance[i + 1] + d1) }
                    if y + 1 < height { best = min(best, distance[i + width] + d1) }
                    if x + 1 < width && y + 1 < height { best = min(best, distance[i + width + 1] + d2) }
                    if x > 0 && y + 1 < height { best = min(best, distance[i + width - 1] + d2) }
                    distance[i] = best
                }
            }
            var best: Float = 0
            for i in 0..<(width * height) where distance[i] > best { best = distance[i] }
            inscribed = CGFloat(best)
        }

        return Opening(name: name, canvasSize: width, openingBox: openingBox,
                       silhouetteBox: silhouetteBox, inscribedRadius: inscribed)
    }
}
