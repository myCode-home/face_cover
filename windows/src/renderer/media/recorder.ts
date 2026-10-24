// 录制器：canvas.captureStream + MediaRecorder。
// 格式用 webm（VP8/VP9 + Opus）。为什么不用 mp4：isTypeSupported 说支持 mp4，
// 但实测（Electron 33 / Chromium 130）MP4 封装器一旦 pause() 就**间歇性产出 0 字节**
// ——完整录制（含暂停）下来文件是空的，且无任何 onerror。探针验证也救不了：
// 这个失败本身就是间歇的，探测通过不代表录制安全。暂停是核心功能，所以确定性地
// 用 webm；等将来验证 Chromium 修复了 mp4+pause，再把 mp4 放回候选列表首位。
// 暂停/恢复用 MediaRecorder 原生 pause/resume：Chromium 会把暂停时长整个排除出
// 时间线，等效于 macOS 版 RecordingTimeline 的时间戳补偿（webm 实测正确）。

export interface RecordingFormat {
  mimeType: string
  ext: 'mp4' | 'webm'
  label: string
}

const FORMAT_CANDIDATES: RecordingFormat[] = [
  { mimeType: 'video/webm;codecs=vp8,opus', ext: 'webm', label: 'WebM (VP8 + Opus)' },
  { mimeType: 'video/webm;codecs=vp9,opus', ext: 'webm', label: 'WebM (VP9 + Opus)' },
  { mimeType: 'video/webm', ext: 'webm', label: 'WebM' },
]

export class RecordingError extends Error {}

/** 选录制格式：按候选顺序取第一个 isTypeSupported 通过的。 */
export function pickRecordingFormat(): RecordingFormat | null {
  for (const candidate of FORMAT_CANDIDATES) {
    if (typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(candidate.mimeType)) return candidate
  }
  return null
}

export interface RecorderHandle {
  pause(): void
  resume(): void
  stop(): Promise<void>
}

/** 开录。onChunk 在数据可用时回调（约每秒一次），落盘交给调用方分块写。 */
export function startRecording(options: {
  canvas: HTMLCanvasElement
  fps: number
  videoBitsPerSecond: number
  audioTracks: MediaStreamTrack[]
  format: RecordingFormat
  onChunk: (chunk: Blob) => void
}): RecorderHandle {
  const videoStream = options.canvas.captureStream(options.fps)
  const stream = new MediaStream([...videoStream.getVideoTracks(), ...options.audioTracks])

  let recorder: MediaRecorder
  try {
    recorder = new MediaRecorder(stream, {
      mimeType: options.format.mimeType,
      videoBitsPerSecond: options.videoBitsPerSecond,
      audioBitsPerSecond: 192_000,
    })
  } catch (err) {
    for (const track of videoStream.getTracks()) track.stop()
    throw new RecordingError(`起不来录制器：${String(err)}`)
  }

  recorder.ondataavailable = (e) => {
    if (e.data && e.data.size > 0) options.onChunk(e.data)
  }

  // timeslice 定期吐数据：录制中的数据实时落盘，不攒内存
  recorder.start(1000)
  // 静默失败的地方：编码器出错只会走 onerror，不接的话就是「录了个寂寞」
  recorder.onerror = (e) => {
    const detail = (e as unknown as { error?: { name?: string; message?: string } }).error
    console.error(`[record] MediaRecorder 错误：${detail?.name ?? 'unknown'} ${detail?.message ?? ''}`)
  }

  return {
    pause: () => recorder.state === 'recording' && recorder.pause(),
    resume: () => recorder.state === 'paused' && recorder.resume(),
    stop: () =>
      new Promise<void>((resolve) => {
        recorder.onstop = () => {
          for (const track of videoStream.getTracks()) track.stop()
          resolve()
        }
        if (recorder.state !== 'inactive') recorder.stop()
        else resolve()
      }),
  }
}
