// 内置脸罩目录 + 归一化后的默认参数。与 macOS 版 HeadCover.swift 一致。
//
// 素材是 1024×1024 带透明通道 PNG，已经过归一化：
//   hood：面孔开口统一 336px 宽、开口中心落在画布正中（开口宽/画布 = 0.328125）
//   mask：轮廓包围盒统一 ~963px 宽
// 所以同类素材共用同一组默认参数；锚点高度/位置每款略有差异，逐款写死在
// COVER_ANCHORS（由 Tools/CoverNormalizer analyze 的输出转录，见文件末尾注释）。
//
// 坐标约定（本文件全部用屏幕坐标系，左上原点、y 向下为正，和画布一致）：
//   sizeScale：贴图宽 = 脸宽 × sizeScale
//   offsetY 正值 = 向下。内置素材默认 -0.20（headLift）：Vision/YuNet 框住的是
//   「脸」（眉线到下巴），整颗头的中心比脸框中心高约 0.20 个脸框高。

export type CoverKind = 'hood' | 'mask'

export interface CoverDef {
  id: string
  name: string
  tagline: string
  kind: CoverKind
}

export const HOODS: CoverDef[] = [
  { id: 'Cover-Pig', name: '猪头', tagline: '毛绒猪头头套，带鼻套', kind: 'hood' },
  { id: 'Cover-Cat', name: '猫', tagline: '灰色虎斑猫，立耳 + 胡须', kind: 'hood' },
  { id: 'Cover-Panda', name: '熊猫', tagline: '黑白熊猫，圆耳 + 黑眼圈', kind: 'hood' },
  { id: 'Cover-Rabbit', name: '兔子', tagline: '白兔，长耳 + 门牙', kind: 'hood' },
  { id: 'Cover-Frog', name: '青蛙', tagline: '卡通青蛙，鼓眼睛 + 咧嘴', kind: 'hood' },
  { id: 'Cover-Skull', name: '骷髅', tagline: '暗黑骷髅，深眼窝 + 下颌', kind: 'hood' },
  { id: 'Cover-Alien', name: '外星人', tagline: '科幻外星人，触角 + 金属外壳', kind: 'hood' },
]

export const MASKS: CoverDef[] = [
  { id: 'Cover-Teddy', name: '泰迪熊', tagline: '毛绒泰迪整头，完全盖住脸', kind: 'mask' },
  { id: 'Cover-Shiba', name: '柴犬', tagline: '毛绒柴犬整头，完全盖住脸', kind: 'mask' },
  { id: 'Cover-CatFace', name: '卡通猫', tagline: '大眼卡通猫脸，完全盖住脸', kind: 'mask' },
  { id: 'Cover-PandaFace', name: '卡通熊猫', tagline: '卡通熊猫脸，完全盖住脸', kind: 'mask' },
]

export const ALL_COVERS: CoverDef[] = [...HOODS, ...MASKS]

export function coverById(id: string): CoverDef | undefined {
  return ALL_COVERS.find((c) => c.id === id)
}

export const COVER_DEFAULTS = {
  /** 头套默认缩放 = openingToFaceWidth / 开口占比（由面孔开口宽反推） */
  hoodSizeScale: 0.81 / (336 / 1024),
  /** 整脸覆盖默认缩放 = maskToFaceWidth / 轮廓占比 */
  maskSizeScale: 1.5 / (963 / 1024),
  customSizeScale: 1.5,
  offsetX: 0,
  /** 内置素材默认上移 0.20 个脸框高（负 = 向上） */
  headLift: 0.2,
  customOffsetY: 0,
} as const

/** 单款素材的锚点规格（用于调试框的青色「开口/轮廓」框，只画在预览上） */
export interface AnchorSpec {
  /** 锚点宽 / 画布 */
  widthFraction: number
  /** 锚点高 / 画布 */
  heightFraction: number
  /** 锚点中心相对画布中心的偏移（画布宽/高的比例） */
  offsetX: number
  offsetY: number
}

const f = (px: number): number => px / 1024

// 由 `.build/covertool analyze`（头套）与 `COVERS_KIND=mask .build/covertool analyze`
// 的输出转录。头套锚点 = 面孔开口外接矩形；mask 锚点 = 轮廓包围盒。
// 工具输出是「CG 左下原点」坐标，这里已换算成屏幕（左上原点）：offsetY = 0.5 - 心y。
export const COVER_ANCHORS: Record<string, AnchorSpec> = {
  'Cover-Pig': { widthFraction: f(336), heightFraction: f(272), offsetX: 0, offsetY: 0 },
  'Cover-Cat': { widthFraction: f(336), heightFraction: f(292), offsetX: 0, offsetY: 0 },
  'Cover-Panda': { widthFraction: f(336), heightFraction: f(296), offsetX: 0, offsetY: 0 },
  'Cover-Rabbit': { widthFraction: f(336), heightFraction: f(278), offsetX: 0, offsetY: 0 },
  'Cover-Frog': { widthFraction: f(336), heightFraction: f(336), offsetX: 0, offsetY: 0 },
  'Cover-Skull': { widthFraction: f(336), heightFraction: f(320), offsetX: 0, offsetY: 0 },
  'Cover-Alien': { widthFraction: f(336), heightFraction: f(357), offsetX: 0, offsetY: 0 },
  'Cover-Teddy': { widthFraction: f(963), heightFraction: f(838), offsetX: 0, offsetY: 0.5 - 0.471 },
  'Cover-Shiba': { widthFraction: f(962), heightFraction: f(951), offsetX: 0, offsetY: 0.5 - 0.496 },
  'Cover-CatFace': { widthFraction: f(964), heightFraction: f(924), offsetX: 0, offsetY: 0.5 - 0.514 },
  'Cover-PandaFace': { widthFraction: f(964), heightFraction: f(923), offsetX: 0, offsetY: 0.5 - 0.498 },
}

/** 换到某款素材时的默认参数（macOS CameraEngine.useCover 的行为） */
export function defaultsForCover(cover: CoverDef | null): { sizeScale: number; offsetX: number; offsetY: number } {
  if (!cover) return { sizeScale: COVER_DEFAULTS.customSizeScale, offsetX: 0, offsetY: COVER_DEFAULTS.customOffsetY }
  if (cover.kind === 'hood') return { sizeScale: COVER_DEFAULTS.hoodSizeScale, offsetX: 0, offsetY: -COVER_DEFAULTS.headLift }
  return { sizeScale: COVER_DEFAULTS.maskSizeScale, offsetX: 0, offsetY: -COVER_DEFAULTS.headLift }
}
