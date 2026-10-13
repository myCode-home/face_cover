import Foundation

/// 录像和诊断文件的存放位置。
/// 单独放一个文件，是为了让「录像库」的逻辑可以脱离采集层单独编译和测试。
enum AppPaths {

    /// `~/Movies/FaceCover/`，不存在就建出来
    static let recordingsDirectory: URL = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies/FaceCover", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }()

    static var diagnosticFile: URL {
        recordingsDirectory.appendingPathComponent("诊断.txt")
    }
}
