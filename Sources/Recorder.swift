import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// 用户可选的录制分辨率上限。输出保持摄像头画面的宽高比，不会拉伸。
enum RecordingResolution: String, CaseIterable, Identifiable, Hashable {
    case p480
    case p720
    case p1080

    var id: String { rawValue }

    var title: String {
        switch self {
        case .p480: return "480p"
        case .p720: return "720p"
        case .p1080: return "1080p"
        }
    }

    var maxShortEdge: Int {
        switch self {
        case .p480: return 480
        case .p720: return 720
        case .p1080: return 1080
        }
    }

    var capturePreset: AVCaptureSession.Preset {
        switch self {
        case .p480: return .hd1280x720
        case .p720: return .hd1280x720
        case .p1080: return .hd1920x1080
        }
    }

    var nominalOutputSize: (width: Int, height: Int) {
        switch self {
        case .p480: return (854, 480)
        case .p720: return (1280, 720)
        case .p1080: return (1920, 1080)
        }
    }

    /// 降采样时保持源画面的宽高比；H.264 编码尺寸取偶数。
    func outputSize(sourceWidth: Int, sourceHeight: Int) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else { return (2, 2) }
        let shortEdge = min(sourceWidth, sourceHeight)
        let scale = min(1.0, Double(maxShortEdge) / Double(shortEdge))
        let width = max(2, Int((Double(sourceWidth) * scale / 2).rounded()) * 2)
        let height = max(2, Int((Double(sourceHeight) * scale / 2).rounded()) * 2)
        return (width, height)
    }
}

enum RecordingFrameRate: Int, CaseIterable, Identifiable, Hashable {
    case fps15 = 15
    case fps24 = 24
    case fps30 = 30

    var id: Int { rawValue }

    var title: String { "\(rawValue) fps" }
}

enum RecordingQuality: String, CaseIterable, Identifiable, Hashable {
    case compact
    case standard
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "省空间"
        case .standard: return "标准"
        case .high: return "高画质"
        }
    }

    /// 基准码率对应 720p/30fps，再按像素数和帧率线性缩放。
    func averageBitRate(width: Int, height: Int, frameRate: Int) -> Int {
        let base: Double
        switch self {
        case .compact: base = 1_200_000
        case .standard: base = 2_500_000
        case .high: base = 4_500_000
        }
        let pixels = Double(max(width, 2) * max(height, 2))
        let scaled = base * pixels / (1280.0 * 720.0) * Double(max(frameRate, 1)) / 30.0
        // 限制极低码率和超高分辨率下的文件膨胀。
        return min(20_000_000, max(500_000, Int((scaled / 100_000).rounded()) * 100_000))
    }
}

/// 录制时间线：把「采集时间戳」映射成「文件里的时间戳」。
///
/// 暂停期间采集照常跑，但一帧都不写文件。如果恢复后继续拿采集时间戳写文件，
/// 新帧和暂停前最后一帧之间会隔着一大段空白 —— 视频时长里就凭空多出这段
/// 「画面不动」的时间。所以暂停/恢复各记一个时刻，把累计暂停时长从采集
/// 时间戳里扣掉，文件时间线才是连续的。
///
/// 时刻统一用 `CMClockGetHostTimeClock()`：摄像头帧和音频的 PTS 都在这个
/// 时钟域里，一条时间线就能同时管两路，音画不会因为暂停而错位。
struct RecordingTimeline {

    /// 累计被扣掉的时长
    private(set) var pausedDuration: CMTime = .zero
    /// 暂停开始的时刻；非 nil 表示正处在暂停中
    private(set) var pauseBeganAt: CMTime?

    var isPaused: Bool { pauseBeganAt != nil }

    /// 每段录像开始时清空，上一段的暂停不能带到下一段
    mutating func reset() {
        pausedDuration = .zero
        pauseBeganAt = nil
    }

    mutating func pause(at now: CMTime) {
        // 重复调用不叠加：只有第一次记的时刻算数
        guard pauseBeganAt == nil else { return }
        pauseBeganAt = now
    }

    /// 结束暂停，返回这一次暂停了多久（已经计入累计值）。
    @discardableResult
    mutating func resume(at now: CMTime) -> CMTime {
        guard let began = pauseBeganAt else { return .zero }
        pauseBeganAt = nil
        let span = CMTimeSubtract(now, began)
        // 时钟回绕或者同一时刻就恢复，都当作没暂停
        guard CMTimeCompare(span, .zero) > 0 else { return .zero }
        pausedDuration = CMTimeAdd(pausedDuration, span)
        return span
    }

    /// 采集时间戳 → 文件时间戳
    func map(_ pts: CMTime) -> CMTime {
        guard CMTimeCompare(pausedDuration, .zero) != 0 else { return pts }
        return CMTimeSubtract(pts, pausedDuration)
    }
}

/// 录制文件（.mov）的创建逻辑。
///
/// 单独抽出来是为了能在没有摄像头的情况下做端到端自检 —— 见 `Tests/Recorder/main.swift`，
/// 它会真的录一段合成的画面、再用 AVAssetImageGenerator 把帧解回来逐像素检查。
enum Recorder {

    struct Components {
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioInput: AVAssetWriterInput?
    }

    /// 建立 writer 并立刻 `startSession`。
    ///
    /// `startPTS` 必须传「录制开始后第一帧」的时间戳：摄像头给的时间戳是开机以来的大数值，
    /// 直接拿它当起点会让视频开头多出一大段空白。
    static func makeComponents(url: URL,
                               width: Int,
                               height: Int,
                               audioChannels: Int?,
                               startPTS: CMTime,
                               frameRate: Int = 30,
                               quality: RecordingQuality = .high) throws -> Components {

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let safeFrameRate = max(1, frameRate)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: quality.averageBitRate(
                    width: width, height: height, frameRate: safeFrameRate
                ),
                AVVideoExpectedSourceFrameRateKey: safeFrameRate,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoMaxKeyFrameIntervalKey: safeFrameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any]()
            ]
        )

        guard writer.canAdd(videoInput) else {
            throw failure("这个画面尺寸无法用 H.264 编码（\(width)×\(height)）")
        }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioChannels {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: audioChannels,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: audioChannels > 1 ? 192_000 : 128_000
            ]
            let candidate = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            candidate.expectsMediaDataInRealTime = true
            if writer.canAdd(candidate) {
                writer.add(candidate)
                audioInput = candidate
            }
        }

        guard writer.startWriting() else {
            throw writer.error ?? failure("AVAssetWriter 启动失败")
        }
        writer.startSession(atSourceTime: startPTS)

        return Components(writer: writer,
                          videoInput: videoInput,
                          adaptor: adaptor,
                          audioInput: audioInput)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "com.local.facecover", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
