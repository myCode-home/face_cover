import Foundation

/// 内置脸罩的目录。
///
/// 每款都是 `Resources/Cover-<id>.png`，1024×1024、带透明通道。
/// **所有素材都经过同一套归一化**（见 `Tools/CoverNormalizer/main.swift`）：
/// 锚点统一缩放到同一个宽度、且锚点中心落在画布正中。
///
/// 为什么必须归一化：`Compositor.drawOverlay` 是「按人脸宽度缩放、以人脸中心居中」贴图的。
/// 素材各自的锚点位置和大小差别很大，不归一化的话换一款就得重新调一遍大小和位置，
/// 而且有的款脸根本框不住。
struct HeadCover: Identifiable, Hashable {

    /// 两类素材的用途完全不同，锚点定义也不同。
    enum Kind: String, Hashable {
        /// **头套**：素材中间有透明面孔开口，脸从开口里露出来。锚点 = 开口。
        case hood
        /// **整脸覆盖**：没有开口，角色自己的脸把整张脸盖住。锚点 = 轮廓包围盒。
        case mask

        var label: String {
            switch self {
            case .hood: return "头套（脸从开口露出来）"
            case .mask: return "整脸覆盖（把脸盖住）"
            }
        }
    }

    /// 资源名（不含扩展名），同时作为稳定标识 —— 会被写进 `FaceEffect.cover(_:)`
    let id: String
    /// 面板上显示的名字
    let name: String
    /// 悬停提示
    let tagline: String
    let kind: Kind

    static let all: [HeadCover] = hoods + masks

    static let hoods: [HeadCover] = [
        HeadCover(id: "Cover-Pig", name: "猪头", tagline: "毛绒猪头头套，带鼻套", kind: .hood),
        HeadCover(id: "Cover-Cat", name: "猫", tagline: "灰色虎斑猫，立耳 + 胡须", kind: .hood),
        HeadCover(id: "Cover-Panda", name: "熊猫", tagline: "黑白熊猫，圆耳 + 黑眼圈", kind: .hood),
        HeadCover(id: "Cover-Rabbit", name: "兔子", tagline: "白兔，长耳 + 门牙", kind: .hood),
        HeadCover(id: "Cover-Frog", name: "青蛙", tagline: "卡通青蛙，鼓眼睛 + 咧嘴", kind: .hood),
        HeadCover(id: "Cover-Skull", name: "骷髅", tagline: "暗黑骷髅，深眼窝 + 下颌", kind: .hood),
        HeadCover(id: "Cover-Alien", name: "外星人", tagline: "科幻外星人，触角 + 金属外壳", kind: .hood),
    ]

    static let masks: [HeadCover] = [
        HeadCover(id: "Cover-Teddy", name: "泰迪熊", tagline: "毛绒泰迪整头，完全盖住脸", kind: .mask),
        HeadCover(id: "Cover-Shiba", name: "柴犬", tagline: "毛绒柴犬整头，完全盖住脸", kind: .mask),
        HeadCover(id: "Cover-CatFace", name: "卡通猫", tagline: "大眼卡通猫脸，完全盖住脸", kind: .mask),
        HeadCover(id: "Cover-PandaFace", name: "卡通熊猫", tagline: "卡通熊猫脸，完全盖住脸", kind: .mask),
    ]

    static func named(_ id: String) -> HeadCover? {
        all.first { $0.id == id }
    }
}

/// 换上脸罩时套用的默认参数。
///
/// 三类素材的目标各不相同，所以各有各的默认缩放：
/// - **头套**要「让脸从开口里露出来」→ 由开口宽反推；
/// - **整脸覆盖**和**自定义图片**要「把脸盖住」→ 和开口无关，直接按脸宽给倍数。
/// 之前三者共用同一个 `sizeScale`，导致选自定义图片时被套上内置头套的 2.47，
/// 图片大得离谱（实测录像里用户手动调到了 1.1~1.3）。
enum CoverDefaults {

    // MARK: 头套（锚点 = 面孔开口）

    /// 归一化后的锚点宽（像素）
    static let openingWidth: Double = 336
    /// 归一化用的画布边长（像素）
    static let canvasSize: Double = 1024
    /// 锚点宽占画布的比例（由素材规格保证，`Tests/Cover` 会校验）
    static var openingFraction: Double { openingWidth / canvasSize }
    /// 期望开口盖住人脸宽度的比例 —— 沿用归一化之前猪头 0.448 × 1.8 的观感
    static let openingToFaceWidth: Double = 0.810
    /// 头套的默认缩放
    static var sizeScale: Double { openingToFaceWidth / openingFraction }

    // MARK: 整脸覆盖（锚点 = 轮廓包围盒）

    /// 归一化后的锚点宽（像素）
    static let maskAnchorWidth: Double = 963
    /// 锚点宽占画布的比例
    static var maskAnchorFraction: Double { maskAnchorWidth / canvasSize }
    /// 期望整脸覆盖盖住人脸宽度的比例。
    ///
    /// Vision 的人脸框大约就是「脸」的范围（颧骨到颧骨、眉到下巴），宽高比约 3:4，
    /// 所以框高 ≈ 1.33 倍框宽。要让整张脸（含下巴）都被盖住，脸罩至少得 1.33 倍脸宽；
    /// 再留一圈边，取 1.5。
    static let maskToFaceWidth: Double = 1.50
    static var maskSizeScale: Double { maskToFaceWidth / maskAnchorFraction }

    // MARK: 自定义图片

    /// 自定义图片的默认缩放。自定义图片没有固定构图，可能是任意照片，
    /// 目标和整脸覆盖一样是「把脸盖住」，所以取同一个量级。
    static let customSizeScale: Double = 1.5

    static let offsetX: Double = 0
    static let offsetY: Double = 0

    /// 按素材类型给默认缩放
    static func defaultSizeScale(for kind: HeadCover.Kind) -> Double {
        switch kind {
        case .hood: return sizeScale
        case .mask: return maskSizeScale
        }
    }
}
