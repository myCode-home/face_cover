import Foundation
import ScreenCaptureKit
import CoreMedia

/// 抓系统正在播放的声音（音乐、视频、网页……）。
///
/// macOS 上没有别的正规办法：必须用 ScreenCaptureKit，而且必须有「屏幕录制」权限。
/// 即使我们只要声音、不要画面，系统也只给这一个入口。
///
/// 我们只添加 `.audio` 输出，不添加 `.screen` 输出；同时把画面尺寸压到 2×2、
/// 帧率压到 1fps，把屏幕捕获的开销降到最低。
final class SystemAudioCapture: NSObject, SCStreamOutput {

    /// 收到一块系统声音。回调在内部串行队列上。
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    /// 抓取过程中出错（比如权限被撤销）
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.local.facecover.systemaudio")
    private let stateLock = NSLock()
    private var running = false

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    /// 请求权限并开始抓取。`completion` 在主线程回调。
    func start(completion: @escaping (Error?) -> Void) {
        Task {
            do {
                // 这一步就会触发「屏幕录制」权限请求；没授权会直接抛错
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false
                )
                guard let display = content.displays.first else {
                    throw NSError(domain: "com.local.facecover", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "找不到可用的显示器"])
                }

                let configuration = SCStreamConfiguration()
                configuration.capturesAudio = true
                configuration.sampleRate = Int(AudioMixer.sampleRate)
                configuration.channelCount = AudioMixer.channels
                // 不要把我们自己 App 发出的声音又录进去
                configuration.excludesCurrentProcessAudio = true
                // 画面部分压到最小，我们并不用它
                configuration.width = 2
                configuration.height = 2
                configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                configuration.queueDepth = 3
                configuration.showsCursor = false

                let filter = SCContentFilter(display: display, excludingWindows: [])
                let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
                try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)

                try await newStream.startCapture()
                self.markRunning(newStream)

                DispatchQueue.main.async { completion(nil) }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }

    /// 单独抽成一个同步方法：在 async 上下文里直接调 NSLock 会被 Swift 6 判为错误
    private func markRunning(_ newStream: SCStream) {
        stateLock.lock()
        stream = newStream
        running = true
        stateLock.unlock()
    }

    func stop() {
        stateLock.lock()
        let existing = stream
        stream = nil
        running = false
        stateLock.unlock()

        existing?.stopCapture { _ in }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }
        onSampleBuffer?(sampleBuffer)
    }
}
