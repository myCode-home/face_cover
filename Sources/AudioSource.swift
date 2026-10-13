import Foundation

/// 录制时用哪路声音。
enum AudioSource: String, CaseIterable, Identifiable {
    case none
    case microphone
    case system
    case both

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "不录声音"
        case .microphone: return "只录麦克风"
        case .system: return "只录系统声音"
        case .both: return "麦克风 + 系统声音"
        }
    }

    var needsMicrophone: Bool { self == .microphone || self == .both }
    /// 系统声音只能通过 ScreenCaptureKit 抓，需要「屏幕录制」权限
    var needsSystemAudio: Bool { self == .system || self == .both }

    /// 写进文件的声音轨道声道数。混音和系统声音都用立体声，麦克风单独用时保持单声道。
    var outputChannels: Int { self == .microphone ? 1 : 2 }
}
