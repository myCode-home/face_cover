import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

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
                               startPTS: CMTime) throws -> Components {

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(width * height * 5, 6_000_000),
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60
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
