import fs from 'node:fs'
import { diagnosticsFile } from './paths'

/** 诊断日志：每行 [ISO8601] 内容，追加写（与 macOS 版同格式）。 */
export function appendDiagnostic(line: string): void {
  try {
    fs.appendFileSync(diagnosticsFile(), `[${new Date().toISOString()}] ${line}\n`, 'utf-8')
  } catch {
    // 诊断写不进去不能影响录制
  }
}
