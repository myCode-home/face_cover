import AudioToolbox
import CoreMedia
import Foundation

/// 把各种 PCM 采样缓冲统一成「Int16 交错立体声 44100Hz」，再合成一路混音。
///
/// 麦克风（AVCaptureAudioDataOutput，单声道 Int16）和系统声音
/// （ScreenCaptureKit，通常是立体声 Float32）格式不一样、到达节奏也不一样，
/// 所以要先把两者都归一化成同一个格式，再按 FIFO 对齐相加。
///
/// 这个文件是纯逻辑，不碰设备，`Tests/Mixer` 会直接喂合成数据验证它。
final class AudioMixer {

    static let sampleRate: Double = 44100
    static let channels: Int = 2
    /// 每次吐出的帧数
    static let chunkFrames = 1024
    /// 某个源超过这么久没数据，就当它静音，不再等它
    static let silenceTimeout: Double = 0.3

    /// 吐出一块混好的音频。`frameOffset` 是这块在整段录音里的起始帧号。
    var onChunk: ((_ samples: [Int16], _ frameOffset: Int) -> Void)?

    private let lock = NSLock()
    private var microphoneFIFO: [Int16] = []
    private var systemFIFO: [Int16] = []
    private var lastMicrophoneTime: Double = -.infinity
    private var lastSystemTime: Double = -.infinity
    private var firstAppendTime: Double?
    private var emittedFrames = 0
    private var useMicrophone = false
    private var useSystem = false

    func configure(useMicrophone: Bool, useSystem: Bool) {
        lock.lock()
        self.useMicrophone = useMicrophone
        self.useSystem = useSystem
        microphoneFIFO.removeAll()
        systemFIFO.removeAll()
        lastMicrophoneTime = -.infinity
        lastSystemTime = -.infinity
        firstAppendTime = nil
        emittedFrames = 0
        lock.unlock()
    }

    /// 喂一个麦克风采样缓冲。格式不认就直接忽略，不会崩。
    func appendMicrophone(_ sampleBuffer: CMSampleBuffer, at time: Double) {
        guard let samples = PCMConverter.toStereoInt16(sampleBuffer) else { return }
        lock.lock()
        if firstAppendTime == nil { firstAppendTime = time }
        microphoneFIFO.append(contentsOf: samples)
        lastMicrophoneTime = time
        drainLocked(now: time)
        lock.unlock()
    }

    /// 喂一个系统声音采样缓冲。
    func appendSystem(_ sampleBuffer: CMSampleBuffer, at time: Double) {
        guard let samples = PCMConverter.toStereoInt16(sampleBuffer) else { return }
        lock.lock()
        if firstAppendTime == nil { firstAppendTime = time }
        systemFIFO.append(contentsOf: samples)
        lastSystemTime = time
        drainLocked(now: time)
        lock.unlock()
    }

    /// 暂停结束、继续喂数据之前调用。
    ///
    /// `drainLocked` 用「距上次收到数据多久」判断某一路是不是哑了。暂停期间
    /// 一个样本都没进来，这个差值会被拉得很大，恢复后第一块就会误判成
    /// 「另一路已经哑了」，于是只拿先到的那一路混音，丢掉另一路同一时间段的
    /// 样本。把三个时间基准拨到恢复时刻，判定就回到正常节奏。
    ///
    /// FIFO 里的残留不清 —— 那是暂停之前录到的有效声音。
    func markResumed(at time: Double) {
        lock.lock()
        defer { lock.unlock() }
        if lastMicrophoneTime.isFinite { lastMicrophoneTime = time }
        if lastSystemTime.isFinite { lastSystemTime = time }
        if firstAppendTime != nil { firstAppendTime = time }
    }

    /// 录音结束时把 FIFO 里剩下的凑不满一整块的也吐出去，免得结尾丢音。
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        while !microphoneFIFO.isEmpty || !systemFIFO.isEmpty {
            emitLocked(frames: min(pendingFramesLocked(), Self.chunkFrames))
            if pendingFramesLocked() == 0 { break }
        }
    }

    // MARK: 内部（调用方必须已经持锁）

    private func drainLocked(now: Double) {
        let need = Self.chunkFrames * Self.channels

        while true {
            let microphoneReady = microphoneFIFO.count >= need
            let systemReady = systemFIFO.count >= need

            // 一个源「放弃等待」的条件：它没攒够一块，而且已经 silenceTimeout 没有数据了。
            // 还没收到过任何数据的源，从第一块数据的时间开始计时。
            let microphoneGivingUp = useMicrophone && !microphoneReady
                && elapsed(since: lastMicrophoneTime, now: now) >= Self.silenceTimeout
            let systemGivingUp = useSystem && !systemReady
                && elapsed(since: lastSystemTime, now: now) >= Self.silenceTimeout

            // 只要还有启用的源「既不够、又没哑」，就必须继续等 ——
            // 否则会只用先到的那一路发出一块，把另一路同一时间段的样本整段丢掉。
            if useMicrophone && !microphoneReady && !microphoneGivingUp { return }
            if useSystem && !systemReady && !systemGivingUp { return }

            if microphoneFIFO.isEmpty && systemFIFO.isEmpty { return }
            emitLocked(frames: Self.chunkFrames)
        }
    }

    private func elapsed(since time: Double, now: Double) -> Double {
        let reference = time.isFinite ? time : (firstAppendTime ?? now)
        return now - reference
    }

    private func pendingFramesLocked() -> Int {
        max(microphoneFIFO.count, systemFIFO.count) / Self.channels
    }

    private func emitLocked(frames: Int) {
        guard frames > 0 else { return }
        let wanted = frames * Self.channels

        var mixed = [Int16](repeating: 0, count: wanted)
        if !microphoneFIFO.isEmpty {
            let take = min(wanted, microphoneFIFO.count)
            add(&mixed, microphoneFIFO, take)
            microphoneFIFO.removeFirst(take)
        }
        if !systemFIFO.isEmpty {
            let take = min(wanted, systemFIFO.count)
            add(&mixed, systemFIFO, take)
            systemFIFO.removeFirst(take)
        }

        let offset = emittedFrames
        emittedFrames += frames
        onChunk?(mixed, offset)
    }

    /// 相加并做饱和处理，避免两个满幅信号叠加后爆音
    private func add(_ destination: inout [Int16], _ source: [Int16], _ count: Int) {
        for i in 0..<count {
            let sum = Int(destination[i]) + Int(source[i])
            destination[i] = Int16(max(-32768, min(32767, sum)))
        }
    }
}

// MARK: - PCM 格式归一化

enum PCMConverter {

    /// 把一个 CMSampleBuffer 转成 Int16 交错立体声。认不出的格式返回 nil。
    static func toStereoInt16(_ sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else {
            return nil
        }
        let source = asbd.pointee
        guard source.mFormatID == kAudioFormatLinearPCM else { return nil }
        guard source.mChannelsPerFrame == 1 || source.mChannelsPerFrame == 2 else { return nil }

        let isFloat = (source.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let bits = Int(source.mBitsPerChannel)
        guard (isFloat && bits == 32) || (!isFloat && bits == 16) else { return nil }

        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        var audioBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: source.mChannelsPerFrame,
                                  mDataByteSize: 0,
                                  mData: nil)
        )

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &audioBufferList,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr,
              let data = audioBufferList.mBuffers.mData else { return nil }

        let sourceChannels = Int(source.mChannelsPerFrame)
        let outputChannels = 2
        var output = [Int16](repeating: 0, count: frames * outputChannels)

        if isFloat {
            let pointer = data.assumingMemoryBound(to: Float.self)
            for frame in 0..<frames {
                for channel in 0..<outputChannels {
                    let sourceChannel = min(channel, sourceChannels - 1)
                    let value = pointer[frame * sourceChannels + sourceChannel]
                    output[frame * outputChannels + channel] = floatToInt16(value)
                }
            }
        } else {
            let pointer = data.assumingMemoryBound(to: Int16.self)
            for frame in 0..<frames {
                for channel in 0..<outputChannels {
                    let sourceChannel = min(channel, sourceChannels - 1)
                    output[frame * outputChannels + channel] = pointer[frame * sourceChannels + sourceChannel]
                }
            }
        }
        return output
    }

    static func floatToInt16(_ value: Float) -> Int16 {
        let clamped = max(-1.0, min(1.0, value))
        return Int16(clamped * 32767.0)
    }

    /// 建一个 Int16 交错立体声的格式描述，用来自己造 CMSampleBuffer
    static func makeFormatDescription(sampleRate: Double, channels: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * 2),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * 2),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 16,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return status == noErr ? description : nil
    }

    /// 把 sampleBuffer 里所有时间戳整体往前挪 `offset`（暂停补偿用）。
    ///
    /// 直通模式下音频是直接把采集回调给的 buffer 交给 writer 的，PTS 是真实采集时刻。
    /// 暂停过后这些时刻整体落后于文件时间线，不挪的话 writer 会当成「时间倒退」拒收。
    /// 平移量是 0 时原样返回，不白拷贝一次。
    static func shiftedTiming(_ sampleBuffer: CMSampleBuffer, by offset: CMTime) -> CMSampleBuffer? {
        guard CMTimeCompare(offset, .zero) != 0 else { return sampleBuffer }

        var entryCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: 0,
                                                     arrayToFill: nil,
                                                     entriesNeededOut: &entryCount) == noErr,
              entryCount > 0 else { return nil }

        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(),
                                           count: Int(entryCount))
        guard CMSampleBufferGetSampleTimingInfoArray(sampleBuffer,
                                                     entryCount: entryCount,
                                                     arrayToFill: &timings,
                                                     entriesNeededOut: nil) == noErr else { return nil }

        for index in timings.indices {
            timings[index].presentationTimeStamp = CMTimeSubtract(
                timings[index].presentationTimeStamp, offset
            )
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeSubtract(
                    timings[index].decodeTimeStamp, offset
                )
            }
        }

        var shifted: CMSampleBuffer?
        let status = timings.withUnsafeBufferPointer { buffer in
            CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                  sampleBuffer: sampleBuffer,
                                                  sampleTimingEntryCount: entryCount,
                                                  sampleTimingArray: buffer.baseAddress,
                                                  sampleBufferOut: &shifted)
        }
        guard status == noErr else { return nil }
        return shifted
    }

    /// 把 Int16 交错样本包成 CMSampleBuffer，才能喂给 AVAssetWriterInput
    static func makeSampleBuffer(samples: [Int16],
                                 format: CMAudioFormatDescription,
                                 sampleRate: Double,
                                 channels: Int,
                                 at presentationTime: CMTime) -> CMSampleBuffer? {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        guard byteCount > 0 else { return nil }

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = samples.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base,
                                                 blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0,
                                                 dataLength: byteCount)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: samples.count / channels,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }
}
