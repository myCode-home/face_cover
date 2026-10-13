import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Foundation

/// 录像库里的一条。
struct RecordingEntry: Identifiable, Equatable {
    let url: URL
    var createdAt: Date
    var duration: Double?
    var fileSize: Int64?
    var thumbnail: CGImage?

    var id: URL { url }

    static func == (lhs: RecordingEntry, rhs: RecordingEntry) -> Bool {
        lhs.url == rhs.url
            && lhs.duration == rhs.duration
            && lhs.fileSize == rhs.fileSize
            && (lhs.thumbnail == nil) == (rhs.thumbnail == nil)
    }

    var fileName: String { url.lastPathComponent }

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }

    var durationText: String {
        guard let duration, duration > 0, duration.isFinite else { return "时长未知" }
        let total = Int(duration.rounded())
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        let seconds = total % 60
        if minutes < 60 { return "\(minutes) 分 \(seconds) 秒" }
        return "\(minutes / 60) 时 \(minutes % 60) 分"
    }

    var sizeText: String {
        guard let fileSize else { return "大小未知" }
        return ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }

    var createdAtText: String {
        RecordingLibrary.dateFormatter.string(from: createdAt)
    }
}

/// 扫描 `~/Movies/FaceCover/` 下的录像，读取时长、大小和首帧缩略图。
///
/// 所有对外状态只在主线程改；后台队列只做 AVFoundation 的读取，不碰共享状态。
final class RecordingLibrary: ObservableObject {

    @Published private(set) var entries: [RecordingEntry] = []
    @Published private(set) var isScanning = false
    @Published var errorMessage: String?

    /// 缩略图缓存，按文件修改时间失效
    private var thumbnailCache: [URL: (modified: Date, image: CGImage)] = [:]
    private var metadataQueue = DispatchQueue(label: "com.local.facecover.library", qos: .utility)

    /// 录像所在的文件夹。做成可注入的，自检才能指向临时目录。
    let directory: URL

    init(directory: URL = AppPaths.recordingsDirectory) {
        self.directory = directory
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var totalSizeText: String {
        let total = entries.compactMap(\.fileSize).reduce(Int64(0), +)
        return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
    }

    // MARK: 扫描

    func refresh() {
        guard !isScanning else { return }
        isScanning = true

        let directory = self.directory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            )) ?? []

            var found: [RecordingEntry] = []
            for url in contents where url.pathExtension.lowercased() == "mov" {
                let values = try? url.resourceValues(forKeys: Set(keys))
                let created = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
                found.append(RecordingEntry(
                    url: url,
                    createdAt: created,
                    duration: nil,
                    fileSize: values?.fileSize.map(Int64.init),
                    thumbnail: nil
                ))
            }
            found.sort { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.url.lastPathComponent > rhs.url.lastPathComponent
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.entries = found
                self.isScanning = false
                self.loadMetadata()
            }
        }
    }

    // MARK: 时长与缩略图

    private func loadMetadata() {
        // 只处理还没有缩略图（或文件被改过）的条目，避免每次刷新全部重算
        let pending = entries.filter { entry in
            guard let cached = thumbnailCache[entry.url] else { return true }
            let modified = (try? entry.url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            return modified != cached.modified
        }

        guard !pending.isEmpty else {
            // 缩略图都有缓存了，但时长可能还没填
            for entry in entries where entry.duration == nil {
                apply(url: entry.url, duration: cachedDuration(entry.url), thumbnail: thumbnailCache[entry.url]?.image)
            }
            return
        }

        let queue = metadataQueue
        queue.async { [weak self] in
            for entry in pending {
                let result = Self.probe(entry.url)
                DispatchQueue.main.async {
                    self?.apply(url: entry.url, duration: result.duration, thumbnail: result.thumbnail)
                }
            }
        }
    }

    private var durationCache: [URL: Double] = [:]

    private func cachedDuration(_ url: URL) -> Double? { durationCache[url] }

    private struct ProbeResult {
        var duration: Double?
        var thumbnail: CGImage?
    }

    private static func probe(_ url: URL) -> ProbeResult {
        let asset = AVURLAsset(url: url)
        // 用同步的 asset.duration：它虽然被标记为 deprecated，但这里本来就在后台串行队列上，
        // 读一下完全没问题。之前为了消掉这个警告改成「信号量 + Task 回填变量」，
        // 结果在 CI 的 Swift 5.10 下报 "mutation of captured var in concurrently-executing code"。
        // 为了一个警告引入一个真 bug 不划算，所以保持同步写法。
        let seconds = CMTimeGetSeconds(asset.duration)
        let duration = (seconds.isFinite && seconds > 0) ? seconds : nil

        var thumbnail: CGImage?
        if let duration, duration > 0.05 {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 480, height: 270)
            let time = CMTime(seconds: min(1.0, duration * 0.25), preferredTimescale: 600)
            thumbnail = try? generator.copyCGImage(at: time, actualTime: nil)
        }
        return ProbeResult(duration: duration, thumbnail: thumbnail)
    }

    private func apply(url: URL, duration: Double?, thumbnail: CGImage?) {
        guard let index = entries.firstIndex(where: { $0.url == url }) else { return }
        if let duration {
            entries[index].duration = duration
            durationCache[url] = duration
        }
        if let thumbnail {
            entries[index].thumbnail = thumbnail
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()
            thumbnailCache[url] = (modified, thumbnail)
        }
    }

    // MARK: 操作

    func play(_ entry: RecordingEntry) {
        NSWorkspace.shared.open(entry.url)
    }

    func reveal(_ entry: RecordingEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.url])
    }

    func copyPath(_ entry: RecordingEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url.path, forType: .string)
    }

    /// 删到废纸篓，不是永久删除 —— 误删还能捞回来
    func moveToTrash(_ entry: RecordingEntry) {
        do {
            try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil)
            entries.removeAll { $0.url == entry.url }
            thumbnailCache[entry.url] = nil
            durationCache[entry.url] = nil
        } catch {
            errorMessage = "删不掉「\(entry.fileName)」：\(error.localizedDescription)"
        }
    }

    /// 用 NSAlert 做确认。这里不用 SwiftUI 的 `.alert`，因为它需要 `@State`，而本机缺 SwiftUIMacros。
    func confirmAndTrash(_ entry: RecordingEntry) {
        let alert = NSAlert()
        alert.messageText = "把这段录像移到废纸篓？"
        alert.informativeText = "\(entry.fileName)\n\n会放进废纸篓，需要的话还能捞回来。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            moveToTrash(entry)
        }
    }

    func openFolder() {
        NSWorkspace.shared.open(directory)
    }
}
