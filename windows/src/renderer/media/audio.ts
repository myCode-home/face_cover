// 声音采集与混音。与 macOS 版的对应关系：
//   麦克风 = AVCaptureAudioDataOutput（关掉浏览器 DSP，接近原始输入）
//   系统声音 = ScreenCaptureKit → Chromium getDisplayMedia loopback（Windows 原生支持，
//     视频画面压到 2×2/1fps——和 macOS 版压屏幕采集开销是同一招）
//   混音 = AudioMixer 的「两路相加 + 饱和」→ WebAudio 混合 + 硬限幅 WaveShaper
// 暂停不用管：MediaRecorder.pause() 会把暂停时长整个排除出时间线。

export type AudioSourceId = 'none' | 'microphone' | 'system' | 'both'

export const AUDIO_SOURCES: { id: AudioSourceId; label: string }[] = [
  { id: 'none', label: '不录声音' },
  { id: 'microphone', label: '只录麦克风' },
  { id: 'system', label: '只录系统声音' },
  { id: 'both', label: '麦克风 + 系统声音' },
]

export class AudioGraph {
  private context: AudioContext | null = null
  private micStream: MediaStream | null = null
  private systemStream: MediaStream | null = null
  private destination: MediaStreamAudioDestinationNode | null = null

  /** 当前混音输出的音轨（喂给 MediaRecorder）；不录声音时为空数组 */
  tracks(): MediaStreamTrack[] {
    return this.destination ? [this.destination.stream.getAudioTracks()[0]!] : []
  }

  private static async acquireMicrophone(): Promise<MediaStream> {
    return navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
      video: false,
    })
  }

  private static async acquireSystemAudio(): Promise<MediaStream> {
    // video 请求是必须的（getDisplayMedia 语义），但拿到后立刻停掉视频轨
    const stream = await navigator.mediaDevices.getDisplayMedia({
      video: { width: { ideal: 2 }, height: { ideal: 2 }, frameRate: { ideal: 1 } },
      audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: false },
    })
    for (const track of stream.getVideoTracks()) track.stop()
    if (stream.getAudioTracks().length === 0) throw new Error('没有拿到系统声音（选画面时没有勾选「分享音频」）')
    return stream
  }

  /**
   * 按声音来源搭建音频图。失败时抛错，由界面转成警告条。
   */
  async connect(source: AudioSourceId): Promise<void> {
    await this.disconnect()
    if (source === 'none') return

    this.context = new AudioContext()
    this.destination = this.context.createMediaStreamDestination()

    // 硬限幅：两路相加超过 ±1 按 ±1 输出（对应 AudioMixer 的 Int16 饱和）
    const limiter = this.context.createWaveShaper()
    limiter.curve = AudioGraph.clipCurve()
    limiter.oversample = '2x'
    limiter.connect(this.destination)

    const attach = async (stream: MediaStream): Promise<void> => {
      const src = this.context!.createMediaStreamSource(stream)
      src.connect(limiter)
    }

    if (source === 'microphone' || source === 'both') {
      this.micStream = await AudioGraph.acquireMicrophone()
      await attach(this.micStream)
    }
    if (source === 'system' || source === 'both') {
      this.systemStream = await AudioGraph.acquireSystemAudio()
      await attach(this.systemStream)
    }
    void this.context.resume()
  }

  async disconnect(): Promise<void> {
    for (const stream of [this.micStream, this.systemStream]) {
      if (!stream) continue
      for (const track of stream.getTracks()) track.stop()
    }
    this.micStream = null
    this.systemStream = null
    if (this.context) {
      try {
        await this.context.close()
      } catch {
        /* 已经关了 */
      }
    }
    this.context = null
    this.destination = null
  }

  private static clipCurve(): Float32Array<ArrayBuffer> {
    const n = 8192
    const curve = new Float32Array(n)
    for (let i = 0; i < n; i++) {
      const x = (i / (n - 1)) * 2 - 1
      curve[i] = Math.min(1, Math.max(-1, x))
    }
    return curve
  }
}

/** 把权限/采集失败翻译成界面上的警告文案 */
export function audioErrorMessage(source: AudioSourceId, err: unknown, micPermission: boolean): string {
  const message = String(err instanceof Error ? err.message : err)
  if (source === 'microphone' || source === 'both') {
    if (err instanceof DOMException && (err.name === 'NotAllowedError' || err.name === 'SecurityError')) {
      return '麦克风没有授权，录不到声音。到「系统设置 → 隐私和安全性 → 麦克风」里允许本应用使用麦克风。'
    }
    if (!micPermission && source === 'both') return `麦克风不可用：${message}`
  }
  if (source === 'system' || source === 'both') {
    if (err instanceof DOMException && err.name === 'NotAllowedError') return '没有选择要共享的画面，录不到系统声音。'
  }
  return `声音采集失败：${message}`
}
