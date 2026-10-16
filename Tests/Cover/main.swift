import CoreGraphics
import Foundation

// 无头自检：内置脸罩素材的目录一致性与几何规格。
//
// 为什么必须有这一条：素材是**手工换的**（生成 → 归一化 → 丢进 Resources）。
// 换素材的人很容易忘了跑归一化，或者在 `HeadCover.all` 里漏加一行。
// 那时候 App 不会报错，只是「脸框不住」—— 而这件事靠眼睛看很容易漏。
// 这里把规格写成断言，换错图直接红。
//
// 运行: ./test.sh

var failures = 0

func check(_ ok: Bool, _ label: String) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

let resources = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()      // Tests/Cover
    .deletingLastPathComponent()      // Tests
    .deletingLastPathComponent()      // 仓库根
    .appendingPathComponent("Resources")

// MARK: [1] 目录一致性

print("\n[1] HeadCover.all 和 Resources/Cover-*.png 必须一一对应")
do {
    let ids = HeadCover.all.map(\.id)
    check(Set(ids).count == ids.count, "id 没有重复（\(ids.count) 款）")

    var missing: [String] = []
    for cover in HeadCover.all {
        let url = resources.appendingPathComponent("\(cover.id).png")
        if !FileManager.default.fileExists(atPath: url.path) { missing.append(cover.id) }
    }
    check(missing.isEmpty, "每款都有对应素材文件" + (missing.isEmpty ? "" : "（缺 \(missing.joined(separator: ", "))）"))

    // 反向：Resources 里不该有目录里没登记的 Cover-*.png
    let onDisk = (try? FileManager.default.contentsOfDirectory(atPath: resources.path))?
        .filter { $0.hasPrefix("Cover-") && $0.hasSuffix(".png") }
        .map { String($0.dropLast(4)) } ?? []
    let orphans = Set(onDisk).subtracting(ids)
    check(orphans.isEmpty, "Resources 里没有未登记的素材" + (orphans.isEmpty ? "" : "（多出 \(orphans.sorted().joined(separator: ", "))）"))

    check(HeadCover.hoods.allSatisfy { $0.kind == .hood }, "hoods 分组里都是 .hood")
    check(HeadCover.masks.allSatisfy { $0.kind == .mask }, "masks 分组里都是 .mask")
    check(HeadCover.hoods.count >= 1 && HeadCover.masks.count >= 1, "两类素材都不为空")
}

// MARK: [2] 几何规格

print("\n[2] 每款素材的锚点必须归一化过（占比一致、不被裁切）")
do {
    // 容差：素材边缘是羽化的，重采样之后 bbox 会有几 px 漂移，别卡太死。
    let fractionTolerance = 0.006

    for cover in HeadCover.all {
        let path = resources.appendingPathComponent("\(cover.id).png").path
        let measured: CoverGeometry.Opening?
        let expectedFraction: Double
        switch cover.kind {
        case .hood:
            measured = CoverGeometry.measure(path: path)
            expectedFraction = CoverDefaults.openingFraction
        case .mask:
            measured = CoverGeometry.measureMask(path: path)
            expectedFraction = CoverDefaults.maskAnchorFraction
        }

        guard let g = measured else {
            check(false, "\(cover.name)：量不出锚点（素材坏了？或者脸洞没包含画布中心？）")
            continue
        }

        let canvas = CGFloat(g.canvasSize)
        check(g.canvasSize == 1024, "\(cover.name)：画布 1024（实测 \(g.canvasSize)）")

        let drift = abs(Double(g.openingFraction) - expectedFraction)
        check(drift <= fractionTolerance,
              String(format: "%@：锚点占比 %.4f，符合规格 %.4f（偏差 %.4f）",
                     cover.name as NSString, g.openingFraction, expectedFraction, drift))

        // 归一化后不该有内容顶出画布
        let half = canvas / 2
        check(g.reach.width <= half + 2 && g.reach.height <= half + 2,
              String(format: "%@：内容没有超出画布（横 %.0f 纵 %.0f ≤ %.0f）",
                     cover.name as NSString, g.reach.width, g.reach.height, half))

        // 注意：**不要**拿「锚点中心相对画布中心的偏移」当判据。
        // 那个数字看着像没居中（实测有几款能到 160px），但它是测量假象 ——
        // 洪水填充的外接矩形会被鼻子 / 牙齿这类凸进洞里的部件挤偏，
        // 而**实际贴图位置是对的**。
        // 真正的判据在 Tests/Compositor 的 [H] 段：
        // 逐款比对「guide 算出的锚点」和「脸实际露出来 / 被盖住的像素」，11 款全部对上。
    }
}

// MARK: [3] 默认缩放要合理

print("\n[3] 按素材类型推出来的默认缩放要落在合理区间")
do {
    for kind in [HeadCover.Kind.hood, HeadCover.Kind.mask] {
        let scale = CoverDefaults.defaultSizeScale(for: kind)
        check(scale > 1.0 && scale < 4.0,
              String(format: "%@ 默认缩放 %.2f 在 1.0~4.0 之间", kind.label as NSString, scale))
    }
    // 头套靠开口反推，整脸覆盖靠轮廓反推，两者不该差太多 —— 差太多说明有一边算错了
    let hood = CoverDefaults.sizeScale
    let mask = CoverDefaults.maskSizeScale
    check(abs(hood - mask) < 1.5,
          String(format: "两类默认缩放量级接近（头套 %.2f vs 整脸 %.2f）", hood, mask))
}

print("")
if failures == 0 {
    print("全部通过 ✅")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
