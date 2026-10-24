// 展示格式化。与 macOS 版 RecordingLibrary 的展示字段对齐。

/** 「N 秒 / M 分 S 秒 / H 时 M 分 / 时长未知」 */
export function durationText(seconds: number | undefined | null): string {
  if (seconds === undefined || seconds === null || !Number.isFinite(seconds) || seconds <= 0) return '时长未知'
  const s = Math.round(seconds)
  if (s < 60) return `${s} 秒`
  if (s < 3600) return `${Math.floor(s / 60)} 分 ${s % 60} 秒`
  return `${Math.floor(s / 3600)} 时 ${Math.floor((s % 3600) / 60)} 分`
}

const SIZE_UNITS = ['KB', 'MB', 'GB', 'TB'] as const

/** 文件大小，3 位有效数字（对齐 ByteCountFormatter .file 的观感） */
export function sizeText(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes < 0) return '—'
  if (bytes < 1000) return `${Math.round(bytes)} 字节`
  let value = bytes
  let unit = -1
  while (value >= 1000 && unit < SIZE_UNITS.length - 1) {
    value /= 1000
    unit++
  }
  let text: string
  if (value >= 100) text = value.toFixed(0)
  else if (value >= 10) text = value.toFixed(1)
  else text = value.toFixed(2)
  return `${text} ${SIZE_UNITS[unit]}`
}

const pad2 = (v: number): string => String(v).padStart(2, '0')

/** "yyyy-MM-dd HH:mm:ss"（本地时区） */
export function createdAtText(date: Date): string {
  return (
    `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ` +
    `${pad2(date.getHours())}:${pad2(date.getMinutes())}:${pad2(date.getSeconds())}`
  )
}

/** FaceCover-yyyyMMdd-HHmmss.mp4 */
export function makeRecordingFileName(date: Date, ext = 'mp4'): string {
  const p = (v: number): string => String(v).padStart(2, '0')
  const stamp =
    `${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}-` +
    `${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`
  return `FaceCover-${stamp}.${ext}`
}

/** 诊断行时间戳：ISO8601（与 macOS 版一致） */
export function diagnosticTimestamp(date = new Date()): string {
  return date.toISOString()
}

/** 滑块数值展示：±0.20 格式，|v| < 0.005 显示 0.00 防「-0.00」 */
export function offsetText(v: number): string {
  const shown = Math.abs(v) < 0.005 ? 0 : v
  const sign = shown < 0 ? '-' : '+'
  return `${sign}${Math.abs(shown).toFixed(2)}`
}

/** 大小滑块展示：%.2f× */
export function scaleText(v: number): string {
  return `${v.toFixed(2)}×`
}

/** mm:ss 计时 */
export function elapsedText(totalSeconds: number): string {
  const s = Math.max(0, Math.floor(totalSeconds))
  return `${pad2(Math.floor(s / 60))}:${pad2(s % 60)}`
}
