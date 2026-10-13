import AudioToolbox
import CoreMedia
import Foundation

// 无头自检：验证 PCM 格式归一化和麦克风/系统声音混音。
// 这部分完全不碰设备，所以不需要任何权限。
// 运行: ./test.sh

var failures = 0

func check(_ ok: Bool, _ label: String) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

let RATE = AudioMixer.sampleRate
let CH = AudioMixer.channels
let CHUNK = AudioMixer.chunkFrames

// MARK: 造测试用的 CMSampleBuffer

func buildSampleBuffer<T>(_ values: [T],
                          channels: Int,
                          format: CMAudioFormatDescription,
                          frames: Int,
                          at time: Double) -> CMSampleBuffer? {
    let byteCount = values.count * MemoryLayout<T>.stride
    var block: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(
        allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
        blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
        offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
    ) == kCMBlockBufferNoErr, let block else { return nil }

    let status = values.withUnsafeBytes { raw -> OSStatus in
        guard let base = raw.baseAddress else { return -1 }
        return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block,
                                             offsetIntoDestination: 0, dataLength: byteCount)
    }
    guard status == kCMBlockBufferNoErr else { return nil }

    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: CMTimeScale(RATE)),
        presentationTimeStamp: CMTime(seconds: time, preferredTimescale: 600),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
        makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
    ) == noErr else { return nil }
    return sampleBuffer
}

func float32Format(channels: Int) -> CMAudioFormatDescription {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: RATE, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels),
        mBitsPerChannel: 32, mReserved: 0
    )
    var description: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
                                   layoutSize: 0, layout: nil, magicCookieSize: 0,
                                   magicCookie: nil, extensions: nil,
                                   formatDescriptionOut: &description)
    return description!
}

/// 模拟麦克风：单声道 Int16
func microphoneBuffer(value: Int16, frames: Int, at time: Double) -> CMSampleBuffer {
    let format = PCMConverter.makeFormatDescription(sampleRate: RATE, channels: 1)!
    return buildSampleBuffer([Int16](repeating: value, count: frames),
                             channels: 1, format: format, frames: frames, at: time)!
}

/// 模拟系统声音：立体声 Float32
func systemBuffer(value: Float, frames: Int, at time: Double) -> CMSampleBuffer {
    let format = float32Format(channels: 2)
    return buildSampleBuffer([Float](repeating: value, count: frames * 2),
                             channels: 2, format: format, frames: frames, at: time)!
}

// MARK: 跑

print("\n[1] 格式归一化")
do {
    let mono = PCMConverter.toStereoInt16(microphoneBuffer(value: 1234, frames: 4, at: 0))
    check(mono?.count == 8, "单声道 → 立体声，样本数翻倍")
    check(mono?[0] == 1234 && mono?[1] == 1234, "左右声道都填上原值")

    let stereo = PCMConverter.toStereoInt16(systemBuffer(value: 0.5, frames: 2, at: 0))
    check(stereo?.count == 4, "系统声音立体声保持立体声")
    check(abs(Int(stereo?[0] ?? 0) - 16383) <= 1, "Float 0.5 → Int16 16383（实测 \(stereo?[0] ?? 0)）")

    let clipped = PCMConverter.toStereoInt16(systemBuffer(value: 3.0, frames: 1, at: 0))
    check(clipped?[0] == 32767, "超过 1.0 的浮点被钳位到 32767（不爆音）")
}

print("\n[2] 两路混音相加")
do {
    let mixer = AudioMixer()
    mixer.configure(useMicrophone: true, useSystem: true)
    var chunks: [(samples: [Int16], offset: Int)] = []
    mixer.onChunk = { samples, offset in chunks.append((samples, offset)) }

    // 麦克风 100，系统声音 0.5 → 16383，期望相加得 16483
    mixer.appendMicrophone(microphoneBuffer(value: 100, frames: CHUNK, at: 0), at: 0)
    mixer.appendSystem(systemBuffer(value: 0.5, frames: CHUNK, at: 0), at: 0)

    check(chunks.count == 1, "凑满一块就吐出来（实际 \(chunks.count) 块）")
    if let first = chunks.first {
        check(first.samples.count == CHUNK * CH, "块大小 = \(CHUNK) 帧 × \(CH) 声道")
        check(abs(Int(first.samples[0]) - 16483) <= 2,
              "两路相加正确（实测 \(first.samples[0])，期望 16483）")
        check(first.offset == 0, "第一块的帧偏移是 0")
    }
}

print("\n[3] 满幅叠加要饱和，不能回绕成噪声")
do {
    let mixer = AudioMixer()
    mixer.configure(useMicrophone: true, useSystem: true)
    var chunks: [Int16] = []
    mixer.onChunk = { samples, _ in chunks.append(contentsOf: samples) }

    mixer.appendMicrophone(microphoneBuffer(value: 30000, frames: CHUNK, at: 0), at: 0)
    mixer.appendSystem(systemBuffer(value: 0.9, frames: CHUNK, at: 0), at: 0)

    // 30000 + 29490 = 59490，超出 Int16 上限，必须钳到 32767 而不是变成负数
    check(chunks.first == 32767, "正向饱和到 32767（实测 \(chunks.first ?? -1)）")
    check((chunks.first ?? 0) > 0, "没有回绕成负数")
}

print("\n[4] 时间轴连续（混音块的帧偏移必须逐块递增）")
do {
    let mixer = AudioMixer()
    mixer.configure(useMicrophone: true, useSystem: true)
    var offsets: [Int] = []
    mixer.onChunk = { _, offset in offsets.append(offset) }

    for index in 0..<4 {
        let time = Double(index) * Double(CHUNK) / RATE
        mixer.appendMicrophone(microphoneBuffer(value: 10, frames: CHUNK, at: time), at: time)
        mixer.appendSystem(systemBuffer(value: 0.1, frames: CHUNK, at: time), at: time)
    }

    check(offsets == [0, CHUNK, CHUNK * 2, CHUNK * 3],
          "帧偏移连续递增（\(offsets.map { $0 / CHUNK }.map(String.init).joined(separator: ",")) 块）")
}

print("\n[5] 一路没声音时不应该卡住另一路")
do {
    let mixer = AudioMixer()
    mixer.configure(useMicrophone: true, useSystem: true)
    var chunkCount = 0
    mixer.onChunk = { _, _ in chunkCount += 1 }

    // 只喂麦克风，系统声音一直没数据。等超过静音超时后，麦克风应该能单独继续吐块。
    var time = 0.0
    let step = Double(CHUNK) / RATE
    // 静音超时是 0.3 秒 ≈ 13 块，所以要喂超过这个长度才能看到「放弃等待」
    for _ in 0..<24 {
        time += step
        mixer.appendMicrophone(microphoneBuffer(value: 500, frames: CHUNK, at: time), at: time)
    }
    check(chunkCount >= 4, "系统声音缺席时麦克风仍能持续输出（\(chunkCount) 块）")
    check(chunkCount >= 8, "超时后不会再卡住，积压的麦克风数据都被吐出来（\(chunkCount) 块）")

    // 反过来：一开始就只有一个源
    let solo = AudioMixer()
    solo.configure(useMicrophone: true, useSystem: false)
    var soloChunks = 0
    solo.onChunk = { _, _ in soloChunks += 1 }
    solo.appendMicrophone(microphoneBuffer(value: 500, frames: CHUNK, at: 0), at: 0)
    check(soloChunks == 1, "只启用一个源时立刻就能出块")
}

print("\n[6] 录音结束 flush 不丢尾巴")
do {
    let mixer = AudioMixer()
    mixer.configure(useMicrophone: true, useSystem: false)
    var totalFrames = 0
    mixer.onChunk = { samples, _ in totalFrames += samples.count / CH }

    // 喂 1500 帧：能凑出 1 个 1024 的整块，剩 476 帧
    mixer.appendMicrophone(microphoneBuffer(value: 1, frames: 1500, at: 0), at: 0)
    let beforeFlush = totalFrames
    mixer.flush()
    check(beforeFlush == CHUNK, "flush 前只吐整块（\(beforeFlush) 帧）")
    check(totalFrames == 1500, "flush 后把剩下的 476 帧也吐出去（总计 \(totalFrames) 帧）")
}

print("\n[7] 自己造的 CMSampleBuffer 能被 writer 认（往返一致）")
do {
    let format = PCMConverter.makeFormatDescription(sampleRate: RATE, channels: CH)!
    let original: [Int16] = [100, -100, 200, -200, 300, -300, 400, -400]
    guard let buffer = PCMConverter.makeSampleBuffer(samples: original, format: format,
                                                     sampleRate: RATE, channels: CH,
                                                     at: CMTime(seconds: 1.5, preferredTimescale: 600)) else {
        print("  ❌ makeSampleBuffer 返回 nil"); exit(1)
    }
    check(CMSampleBufferGetNumSamples(buffer) == 4, "帧数 = 样本数 / 声道数 = 4")
    check(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer)) == 1.5, "时间戳保留")

    let roundTrip = PCMConverter.toStereoInt16(buffer)
    check(roundTrip == original, "写进去再读出来完全一致")
}

print("")
if failures == 0 {
    print("全部通过 ✅")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
