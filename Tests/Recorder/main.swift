import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

// 端到端自检：不接摄像头，直接喂合成的画面给录制管线，
// 录成一个真的 .mov，再把帧解码回来逐像素检查。
//
// 重点验证两件事：
//   1. 脸真的被盖住了（不是只在预览里盖住）
//   2. 开镜像时，整帧确实翻了，而且脸罩仍然落在脸上
//
// 运行: ./test.sh

var failures = 0

func check(_ ok: Bool, _ label: String) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

/// 加锁的盒子，用来把 Task 里的结果传出来。
///
/// 不能图省事写成 `var result: T?` 然后在 Task 里回填：
/// 本机 Swift 6.4 能过，但 CI 上的 Swift 5.10 会直接报错
///   error: mutation of captured var 'result' in concurrently-executing code
/// 所以用引用类型 + 锁，跨编译器版本都安全。
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T?

    var value: T? {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// 把 async 的 AVFoundation API 拉回同步，方便顶层脚本直接写
func awaitValue<T>(_ operation: @escaping () async throws -> T) -> T? {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task {
        box.value = try? await operation()
        semaphore.signal()
    }
    semaphore.wait()
    return box.value
}

let W = 1280
let H = 720
let FPS = 30
let FRAME_COUNT = 60

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

print("\n[0] 录制质量选项")
let size480 = RecordingResolution.p480.outputSize(sourceWidth: 1280, sourceHeight: 720)
let size720 = RecordingResolution.p720.outputSize(sourceWidth: 1280, sourceHeight: 720)
let size1080 = RecordingResolution.p1080.outputSize(sourceWidth: 1280, sourceHeight: 720)
check(size480.width == 854 && size480.height == 480, "480p 保持 16:9（\(size480.width)×\(size480.height)）")
check(size720.width == 1280 && size720.height == 720, "720p 保留原始采集尺寸")
check(size1080.width == 1280 && size1080.height == 720, "摄像头低于 1080p 时不做无意义放大")
let portrait480 = RecordingResolution.p480.outputSize(sourceWidth: 720, sourceHeight: 1280)
check(portrait480.width == 480 && portrait480.height == 854, "竖屏 480p 按短边目标并保持方向")
let fourThree480 = RecordingResolution.p480.outputSize(sourceWidth: 640, sourceHeight: 480)
check(fourThree480.width == 640 && fourThree480.height == 480, "4:3 源画面低于目标时不放大")
check(RecordingResolution.p480.nominalOutputSize.width == 854 && RecordingResolution.p480.nominalOutputSize.height == 480,
      "480p 标准输出尺寸为 854×480")
check(RecordingResolution.p1080.nominalOutputSize.width == 1920 && RecordingResolution.p1080.nominalOutputSize.height == 1080,
      "1080p 标准输出尺寸为 1920×1080")
let compactRate = RecordingQuality.compact.averageBitRate(width: 1280, height: 720, frameRate: 30)
let standardRate = RecordingQuality.standard.averageBitRate(width: 1280, height: 720, frameRate: 30)
let highRate = RecordingQuality.high.averageBitRate(width: 1280, height: 720, frameRate: 30)
check(compactRate < standardRate && standardRate < highRate,
      "码率随画质档递增（\(compactRate / 1_000_000)/\(standardRate / 1_000_000)/\(highRate / 1_000_000) Mbps）")
let lowFPSRate = RecordingQuality.standard.averageBitRate(width: 1280, height: 720, frameRate: 15)
check(lowFPSRate < standardRate, "15fps 的目标码率低于 30fps")

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    CGColor(colorSpace: srgb, components: [r, g, b, 1])!
}

/// 左半红、右半绿，用来确认合成结果真的进了文件
func makeOverlay() -> CGImage {
    let ctx = CGContext(data: nil, width: 100, height: 100,
                        bitsPerComponent: 8, bytesPerRow: 0,
                        space: srgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color(1, 0, 0))
    ctx.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
    ctx.setFillColor(color(0, 1, 0))
    ctx.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
    return ctx.makeImage()!
}

/// 模拟「摄像头画面」：蓝色背景 + 最左边一条洋红标记（用来判断整帧有没有被翻转）
func fillCameraFrame(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
          let ctx = CGContext(data: base,
                              width: CVPixelBufferGetWidth(buffer),
                              height: CVPixelBufferGetHeight(buffer),
                              bitsPerComponent: 8,
                              bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                              space: srgb,
                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
    ctx.setFillColor(color(0, 0, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.setFillColor(color(1, 0, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 40, height: H))
}

/// 把 CGImage 画进缓冲区再取样（x 从左边数，y 从顶部往下数）
func sample(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int) {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var data = [UInt8](repeating: 0, count: bytesPerRow * height)
    data.withUnsafeMutableBytes { raw in
        let ctx = CGContext(data: raw.baseAddress,
                            width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: srgb,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let offset = y * bytesPerRow + x * 4
    return (Int(data[offset + 2]), Int(data[offset + 1]), Int(data[offset]))
}

// H.264 是有损的，阈值放宽一点
func isRed(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 150 && p.g < 110 && p.b < 110 }
func isGreen(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.g > 150 && p.r < 110 && p.b < 110 }
func isBlue(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.b > 150 && p.r < 110 && p.g < 110 }
func isMagenta(_ p: (r: Int, g: Int, b: Int)) -> Bool { p.r > 150 && p.b > 150 && p.g < 110 }

// MARK: 录一段

let overlay = makeOverlay()

// 模拟人脸在「摄像头原始画面」里的位置：横向 0.15..0.35
let rawFace = CGRect(x: 0.15, y: 0.4, width: 0.2, height: 0.2)

/// 完整走一遍真实管线：定方向 → 检测 → 贴图 → 写文件
func record(mirror: Bool) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("facecover-selftest-\(UUID().uuidString).mov")

    // 故意用一个「开机以来的大时间戳」当起点，验证 startSession 的处理是对的
    let firstPTS = CMTime(seconds: 98765.4321, preferredTimescale: 600)

    let components = try Recorder.makeComponents(url: url, width: W, height: H,
                                                 audioChannels: nil, startPTS: firstPTS)
    guard let pool = components.adaptor.pixelBufferPool else {
        fatalError("拿不到 pixelBufferPool")
    }

    for frame in 0..<FRAME_COUNT {
        let pts = CMTimeAdd(firstPTS, CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(FPS)))

        // 编码器有背压：不 ready 的时候硬塞会直接抛异常。
        // 真实采集是实时节奏，这里手动等它消化完。
        var waited = 0
        while !components.videoInput.isReadyForMoreMediaData && waited < 1000 {
            usleep(2000)
            waited += 1
        }
        guard components.videoInput.isReadyForMoreMediaData else { break }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { continue }

        fillCameraFrame(pixelBuffer)

        // ---- 真实顺序：先定方向 ----
        Compositor.mirrorIfNeeded(pixelBuffer, mirror: mirror)

        // ---- 再检测人脸（翻转后脸的位置）----
        let detected = mirror
            ? CGRect(x: 1.0 - rawFace.maxX, y: rawFace.minY, width: rawFace.width, height: rawFace.height)
            : rawFace

        // ---- 再贴图 ----
        Compositor.drawOverlay(overlay: overlay, into: pixelBuffer,
                               faceNormalized: detected,
                               sizeScale: 1.0, offsetX: 0, offsetY: 0)

        _ = components.adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    components.videoInput.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    components.writer.finishWriting { semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 30)

    guard components.writer.status == .completed else {
        throw Recorder.failure("writer 收尾失败：\(String(describing: components.writer.error))")
    }
    return url
}

func decodeFrame(_ url: URL, atSeconds seconds: Double) -> CGImage? {
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero
    generator.requestedTimeToleranceAfter = .zero
    return awaitValue {
        try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }
}

// MARK: 场景一：关镜像

print("\n[1] 关镜像：录一段并检查")
do {
    let url = try record(mirror: false)
    defer { try? FileManager.default.removeItem(at: url) }

    let asset = AVURLAsset(url: url)
    guard let track = awaitValue({ try await asset.loadTracks(withMediaType: .video) })?.first else {
        print("  ❌ 文件里没有视频轨道"); exit(1)
    }
    let durationSeconds = awaitValue { try await asset.load(.duration) }.map(CMTimeGetSeconds) ?? 0
    let naturalSize = awaitValue { try await track.load(.naturalSize) } ?? .zero

    check(abs(durationSeconds - Double(FRAME_COUNT) / Double(FPS)) < 0.25,
          "时长 \(String(format: "%.2f", durationSeconds)) 秒（期望约 \(FRAME_COUNT / FPS) 秒，开头没多出空白）")
    check(Int(naturalSize.width) == W && Int(naturalSize.height) == H,
          "分辨率 \(Int(naturalSize.width))×\(Int(naturalSize.height))")

    guard let frame = decodeFrame(url, atSeconds: 1.0) else {
        print("  ❌ 解不出画面"); exit(1)
    }

    // 脸在 0.15..0.35 → 像素 x 192..448；图片左半红、右半绿
    check(isRed(sample(frame, 230, 360)), "脸的左半被红色图片盖住 (230,360)")
    check(isGreen(sample(frame, 410, 360)), "脸的右半被绿色图片盖住 (410,360)")
    check(isBlue(sample(frame, 700, 360)), "脸右边的画面保持背景色 (700,360)")
    check(isMagenta(sample(frame, 20, 100)), "洋红标记还在左边 x=20（没被翻转）")
    check(isBlue(sample(frame, 1260, 100)), "右边没有标记 x=1260")
}

// MARK: 场景二：开镜像

print("\n[2] 开镜像：整帧必须翻转，且脸罩仍然落在脸上")
do {
    let url = try record(mirror: true)
    defer { try? FileManager.default.removeItem(at: url) }

    guard let frame = decodeFrame(url, atSeconds: 1.0) else {
        print("  ❌ 解不出画面"); exit(1)
    }

    // 原始画面里脸在 0.15..0.35，翻转后落到 0.65..0.85 → 像素 x 832..1088
    check(isRed(sample(frame, 870, 360)), "翻转后脸的左半被红色图片盖住 (870,360)")
    check(isGreen(sample(frame, 1050, 360)), "翻转后脸的右半被绿色图片盖住 (1050,360)")
    check(isBlue(sample(frame, 400, 360)), "脸原来的位置换成背景色 (400,360)")
    check(isMagenta(sample(frame, 1260, 100)), "洋红标记被翻到了右边 x=1260")
    check(isBlue(sample(frame, 20, 100)), "左边原来的标记位置变成背景 x=20")
}

print("")
if failures == 0 {
    print("全部通过 ✅  —— 导出的视频里脸确实被盖住了，镜像方向也对")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
