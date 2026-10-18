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

print("\n[4] 两类内置素材的默认纵向偏移：对齐的是「头」，不是「脸」")
do {
    // 单位说明：缩放按**脸框宽**给，偏移按**脸框高**给。诊断日志里脸框 ≈ 0.17×0.30（归一化），
    // 在 16:9 画面里换算成像素后宽高几乎相等（0.30×9/16 ÷ 0.17 = 0.998），
    // 所以这里按「脸框高 = 脸框宽 = 1」算，换真实摄像头也差不到 1%。
    let faceW: Double = 1
    let faceH: Double = 1

    // 一颗头的纵向范围（相对脸框中心，向上为正）：
    // 下巴 ≈ 脸框底 = -0.5；发际线以上还有头发，头顶 ≈ 眉线（+0.5）再往上 0.4 → +0.9。
    let headTop: Double = 0.9
    let chin: Double = -0.5
    // 眼睛：眉线往下约 0.20 个脸高 → +0.30
    let eyeLine: Double = 0.30

    for kind in [HeadCover.Kind.hood, HeadCover.Kind.mask] {
        let offset = CoverDefaults.defaultOffsetY(for: kind)
        check(offset < 0,
              String(format: "%@ 默认向上移（offsetY = %.2f，负值 = 上移）", kind.label as NSString, offset))
        check(abs(offset + CoverDefaults.headLift) < 0.0001,
              String(format: "%@ 上移量就是 headLift（%.2f 个脸框高）",
                     kind.label as NSString, CoverDefaults.headLift))
        check(abs(offset) <= 0.5, "\(kind.label) 上移量没有夸张到离谱（|offsetY| ≤ 0.5）")
    }
    check(CoverDefaults.customOffsetY == 0,
          "自定义图片不预设偏移 —— 用户给什么图都有可能，没有可假定的构图")

    // 整脸覆盖：默认参数下整颗头都要盖住
    for cover in HeadCover.masks {
        let path = resources.appendingPathComponent("\(cover.id).png").path
        guard let g = CoverGeometry.measureMask(path: path) else {
            check(false, "\(cover.name)：量不出轮廓"); continue
        }
        let canvas = Double(g.canvasSize)
        let scale = CoverDefaults.defaultSizeScale(for: .mask)
        // 轮廓高，换算成「脸框高」的倍数
        let bboxH = Double(g.openingHeight) / canvas * scale * faceW / faceH

        let lift = -CoverDefaults.defaultOffsetY(for: .mask)
        let top = lift + bboxH / 2
        let bottom = lift - bboxH / 2

        // 头顶不能露出来（留 0.10 的余量，素材羽化 / 测量漂移都算在内）
        check(top >= headTop - 0.10,
              String(format: "%@：头顶盖住了（上沿 %+.2f，头到 %+.2f）",
                     cover.name as NSString, top, headTop))
        // 下巴不能露出来
        check(bottom <= chin + 0.10,
              String(format: "%@：下巴盖住了（下沿 %+.2f，下巴在 %+.2f）",
                     cover.name as NSString, bottom, chin))
        // 反向：不挪的话头顶会露 —— 这条保证「默认上移」不是可有可无的
        check(bboxH / 2 < headTop - 0.10,
              String(format: "%@：不上移时头顶确实露出来（上沿只有 %+.2f）",
                     cover.name as NSString, bboxH / 2))
    }

    // 头套：开口要盖住眼睛，而且不能只擦着边 —— 擦边时头套的额头会压住眉毛
    var tightest = Double.greatestFiniteMagnitude
    var tightestWithoutLift = Double.greatestFiniteMagnitude
    for cover in HeadCover.hoods {
        let path = resources.appendingPathComponent("\(cover.id).png").path
        guard let g = CoverGeometry.measure(path: path) else {
            check(false, "\(cover.name)：量不出开口"); continue
        }
        let canvas = Double(g.canvasSize)
        let scale = CoverDefaults.defaultSizeScale(for: .hood)
        let openH = Double(g.openingHeight) / canvas * scale * faceW / faceH

        let lift = -CoverDefaults.defaultOffsetY(for: .hood)
        let margin = lift + openH / 2 - eyeLine      // 眼睛到开口顶边还剩多少
        tightest = min(tightest, margin)
        tightestWithoutLift = min(tightestWithoutLift, openH / 2 - eyeLine)

        check(margin >= 0.15,
              String(format: "%@：眼睛离开口顶边 %.2f 个脸高（开口上沿 %+.2f，眼睛在 %+.2f）",
                     cover.name as NSString, margin, lift + openH / 2, eyeLine))
    }
    check(tightestWithoutLift < 0.10,
          String(format: "不上移时最紧的一款只剩 %.2f —— 眼睛擦着开口顶边，头套的额头会压住眉毛",
                 tightestWithoutLift))
}

print("")
if failures == 0 {
    print("全部通过 ✅")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
