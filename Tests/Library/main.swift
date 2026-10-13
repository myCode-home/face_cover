import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation

// 无头自检：录像库的扫描、排序、时长/大小读取、缩略图、删除。
// 会真的录出几段小视频放进临时目录，再让录像库去扫。
// 运行: ./test.sh

var failures = 0

func check(_ ok: Bool, _ label: String) {
    print(ok ? "  ✅ \(label)" : "  ❌ \(label)")
    if !ok { failures += 1 }
}

/// CLI 里没有 runloop 在跑，主队列的 block 需要手动泵一下才会执行
func pump(_ seconds: Double) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
let workDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("facecover-library-\(UUID().uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDirectory) }

// MARK: 录一段小视频

@discardableResult
func record(frames: Int, name: String, createdAt: Date) throws -> URL {
    let url = workDirectory.appendingPathComponent(name)
    let firstPTS = CMTime(seconds: 1000, preferredTimescale: 600)

    let components = try Recorder.makeComponents(url: url, width: 320, height: 180,
                                                 audioChannels: nil, startPTS: firstPTS)
    guard let pool = components.adaptor.pixelBufferPool else {
        throw Recorder.failure("拿不到 pixelBufferPool")
    }

    for frame in 0..<frames {
        var waited = 0
        while !components.videoInput.isReadyForMoreMediaData && waited < 1000 {
            usleep(2000); waited += 1
        }
        guard components.videoInput.isReadyForMoreMediaData else { break }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let pixelBuffer = buffer else { continue }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer),
           let ctx = CGContext(data: base,
                               width: 320, height: 180, bitsPerComponent: 8,
                               bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                               space: srgb,
                               bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                         | CGBitmapInfo.byteOrder32Little.rawValue) {
            // 每段用不同颜色，缩略图能区分开
            let hue = CGFloat(frame) / CGFloat(max(frames, 1))
            ctx.setFillColor(CGColor(colorSpace: srgb, components: [hue, 0.4, 1 - hue, 1])!)
            ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let pts = CMTimeAdd(firstPTS, CMTime(value: CMTimeValue(frame), timescale: 30))
        _ = components.adaptor.append(pixelBuffer, withPresentationTime: pts)
    }

    components.videoInput.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    components.writer.finishWriting { semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 30)
    guard components.writer.status == .completed else {
        throw Recorder.failure("录制失败：\(String(describing: components.writer.error))")
    }

    // 明确设定创建时间，否则同一秒内录完的几段排序会打平
    try? FileManager.default.setAttributes([.creationDate: createdAt],
                                           ofItemAtPath: url.path)
    return url
}

// MARK: 准备素材

print("\n[1] 先录三段不同长度的小视频")
let now = Date()
let oldURL = try record(frames: 30, name: "FaceCover-20260101-100000.mov",
                        createdAt: now.addingTimeInterval(-3600))
let midURL = try record(frames: 60, name: "FaceCover-20260101-110000.mov",
                        createdAt: now.addingTimeInterval(-1800))
let newURL = try record(frames: 90, name: "FaceCover-20260101-120000.mov",
                        createdAt: now)
check(FileManager.default.fileExists(atPath: oldURL.path), "三段都写出来了")

// 放一个非 mov 文件，确认会被忽略
try? "not a movie".write(to: workDirectory.appendingPathComponent("笔记.txt"),
                         atomically: true, encoding: .utf8)

// MARK: 扫描

let library = RecordingLibrary(directory: workDirectory)
library.refresh()
pump(1.5)

print("\n[2] 扫描结果")
check(library.entries.count == 3, "只认出 3 个 .mov，忽略其他文件（实际 \(library.entries.count)）")
check(library.entries.first?.url.lastPathComponent == newURL.lastPathComponent,
      "最新的排最前面（\(library.entries.first?.fileName ?? "?")）")
check(library.entries.last?.url.lastPathComponent == oldURL.lastPathComponent,
      "最旧的排最后面（\(library.entries.last?.fileName ?? "?")）")

print("\n[3] 时长和大小")
do {
    let durations = library.entries.map { $0.duration ?? -1 }
    // 30/60/90 帧 @30fps → 1 / 2 / 3 秒
    let expected: [Double] = [3.0, 2.0, 1.0]
    let ok = zip(durations, expected).allSatisfy { abs($0 - $1) < 0.25 }
    check(ok, "时长读取正确（\(durations.map { String(format: "%.2f", $0) }.joined(separator: ", ")) 秒，期望 3/2/1）")
    check(library.entries.allSatisfy { ($0.fileSize ?? 0) > 0 }, "文件大小都读到了")
    check(library.entries.allSatisfy { $0.sizeText != "大小未知" }, "大小能格式化显示")
    check(library.entries.allSatisfy { $0.durationText.contains("秒") }, "时长能格式化显示")
}

print("\n[4] 缩略图")
do {
    pump(2.0)
    let withThumbnails = library.entries.filter { $0.thumbnail != nil }.count
    check(withThumbnails == 3, "三段都生成了缩略图（\(withThumbnails)/3）")
    if let image = library.entries.first?.thumbnail {
        check(image.width > 0 && image.height > 0, "缩略图尺寸有效（\(image.width)×\(image.height)）")
        check(image.width <= 480 && image.height <= 270, "缩略图被限制在 480×270 以内，没有占内存")
    }
}

print("\n[5] 汇总信息")
do {
    let summary = library.totalSizeText
    check(!summary.isEmpty && summary != "零 KB", "总大小能显示（\(summary)）")
}

print("\n[6] 刷新时不该重复加载已有缩略图")
do {
    let before = library.entries.compactMap(\.thumbnail).count
    library.refresh()
    pump(1.0)
    let after = library.entries.compactMap(\.thumbnail).count
    check(after == before, "刷新后缩略图还在（\(after)/\(before)），没有丢")
}

print("\n[7] 删除是移到废纸篓")
do {
    let target = library.entries.first!
    library.moveToTrash(target)
    pump(0.3)
    check(library.entries.count == 2, "列表里少了一条（剩 \(library.entries.count)）")
    check(!FileManager.default.fileExists(atPath: target.url.path), "文件已经从原位置移走")
    check(library.errorMessage == nil, "没有报错")
}

print("")
if failures == 0 {
    print("全部通过 ✅")
    exit(0)
} else {
    print("有 \(failures) 项失败 ❌")
    exit(1)
}
