import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreMedia
import QuartzCore
import Vision

/// 当前贴的是什么。
/// 内置头套用 `HeadCover.id` 表示，这样加一款新头套不用改这个枚举。
enum FaceEffect: Equatable {
    case none
    case cover(String)
    case custom

    var coverID: String? {
        if case .cover(let id) = self { return id }
        return nil
    }
}

// MARK: - 预览通道

/// 单独一个 ObservableObject 只承载预览帧。
/// 这样 30fps 的刷新只会重绘预览视图，不会让整个界面反复重新布局。
final class PreviewSink: ObservableObject {
    @Published var image: CGImage?
}

// MARK: - 设置快照（视频线程读取用，避免直接跨线程读 @Published）

private struct SettingsSnapshot {
    var image: CGImage?
    var trackingEnabled = true
    var sizeScale: Double = CoverDefaults.sizeScale
    var offsetX: Double = 0
    var offsetY: Double = 0
    var mirror = true
    var recordAudio = true
    var audioSource: AudioSource = .microphone
    var recordingResolution: RecordingResolution = .p720
    var recordingFrameRate: RecordingFrameRate = .fps24
    var recordingQuality: RecordingQuality = .standard
    var showDebugBox = false
}

// MARK: - 引擎

final class CameraEngine: NSObject, ObservableObject {

    // MARK: 对外状态

    let preview = PreviewSink()

    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var faceVisible = false
    @Published private(set) var trackedFaceCount = 0
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var micAvailable = false
    @Published private(set) var selectedEffect: FaceEffect = .none
    @Published var statusMessage = "正在请求摄像头权限…"
    @Published var cameras: [AVCaptureDevice] = []

    @Published var selectedCameraID: String = "" {
        didSet {
            guard !isRefreshingCameras, oldValue != selectedCameraID, isRunning else { return }
            sessionQueue.async { [weak self] in self?.configureSession() }
        }
    }

    // MARK: 用户设置（改动即生效）

    @Published var overlayImage: CGImage? { didSet { syncSettings() } }
    @Published var trackingEnabled = true { didSet { syncSettings() } }
    @Published var sizeScale: Double = CoverDefaults.sizeScale { didSet { syncSettings() } }
    @Published var offsetX: Double = 0 { didSet { syncSettings() } }
    @Published var offsetY: Double = 0 { didSet { syncSettings() } }
    @Published var mirror = true { didSet { syncSettings() } }
    @Published var recordAudio = true { didSet { syncSettings() } }
    @Published var audioSource: AudioSource = .microphone {
        didSet {
            syncSettings()
            applyAudioSource()
        }
    }

    // MARK: 录制质量（分辨率 / 帧率 / 画质）
    //
    // 三项都会存进 UserDefaults，重启后还是上次的选择。
    // 录制中锁定：AVCaptureSession 的预设和摄像头帧率中途改不了，强行改会让画面跳一下。

    @Published var recordingResolution: RecordingResolution = CameraEngine.loadStringPreference(
        key: "recordingResolution", as: RecordingResolution.self, default: .p720
    ) {
        didSet {
            UserDefaults.standard.set(recordingResolution.rawValue, forKey: "recordingResolution")
            syncSettings()
            guard !isRecording else { return }
            applyCapturePreset()
        }
    }

    @Published var recordingFrameRate: RecordingFrameRate = CameraEngine.loadIntPreference(
        key: "recordingFrameRate", as: RecordingFrameRate.self, default: .fps24
    ) {
        didSet {
            UserDefaults.standard.set(recordingFrameRate.rawValue, forKey: "recordingFrameRate")
            let targetFrameRate = recordingFrameRate.rawValue
            syncSettings()
            guard !isRecording else { return }
            sessionQueue.async { [weak self] in
                guard let self, self.isRunning else { return }
                self.applyFrameRateLimit(to: self.currentDevice(), frameRate: targetFrameRate)
            }
        }
    }

    @Published var recordingQuality: RecordingQuality = CameraEngine.loadStringPreference(
        key: "recordingQuality", as: RecordingQuality.self, default: .standard
    ) {
        didSet {
            UserDefaults.standard.set(recordingQuality.rawValue, forKey: "recordingQuality")
            syncSettings()
        }
    }

    private static func loadStringPreference<T: RawRepresentable>(key: String,
                                                                   as type: T.Type,
                                                                   default fallback: T) -> T where T.RawValue == String {
        guard let rawValue = UserDefaults.standard.string(forKey: key) else { return fallback }
        return T(rawValue: rawValue) ?? fallback
    }

    private static func loadIntPreference<T: RawRepresentable>(key: String,
                                                               as type: T.Type,
                                                               default fallback: T) -> T where T.RawValue == Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return fallback }
        return T(rawValue: UserDefaults.standard.integer(forKey: key)) ?? fallback
    }

    @Published var showDebugBox = false { didSet { syncSettings() } }

    // MARK: 会话管线

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.local.facecover.session")
    private let videoQueue = DispatchQueue(label: "com.local.facecover.video")
    private let audioQueue = DispatchQueue(label: "com.local.facecover.audio")
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private let settingsLock = NSLock()
    private var settings = SettingsSnapshot()

    private var isRefreshingCameras = false
    private var outputsWired = false

    // MARK: 人脸追踪

    /// 图片层模式下未检测到人脸时仍贴在画面中间偏上的位置；无图片时不绘制。
    private static let fallbackFace = CGRect(x: 0.375, y: 0.52, width: 0.25, height: 0.25)
    private var faceTracker = MultiFaceTracker()
    private var lastFaceVisible = false
    private var lastPublishedFaceCount = 0
    private var lastAppliedMirror = true
    /// 当前脸罩素材的面孔开口几何，载入时量一次。自定义图片没有开口，这里是 nil。
    /// 只用于预览上的调试框 —— 让「脸有没有落在开口里」一眼可见。
    private var overlayOpening: Compositor.OpeningGuide?
    private var frameCounter = 0
    /// 默认每帧都检测；实测 Vision 太慢时自动降到每 2 帧一次
    private var detectEvery = 1
    private var visionCost: Double?
    /// 迟滞用的连续计数，见 `updateDetectionCadence()`
    private var slowStreak = 0
    private var fastStreak = 0
    private var lastFaceLogTime: Double = 0

    /// 单帧检测耗时超过这个值就考虑降到每 2 帧一次
    private static let slowCostThreshold = 0.020
    /// 低于这个值才考虑恢复逐帧。和上面留出间隔，避免在阈值附近来回翻
    private static let fastCostThreshold = 0.010
    private static let slowStreakFrames = 20
    private static let fastStreakFrames = 60

    // MARK: 录制

    private let writerLock = NSLock()
    private var recordRequested = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false
    /// 上一帧真正写进文件的时间戳。抽帧（按目标帧率丢掉多余帧）要用它算间隔
    private var lastAppendedVideoPTS: CMTime?

    // 音频
    private let mixer = AudioMixer()
    private let systemAudio = SystemAudioCapture()
    private var mixedAudioFormat: CMAudioFormatDescription?
    private var audioSessionStart: CMTime?
    private var lastMicrophoneNeeded = true

    static var outputDirectory: URL { AppPaths.recordingsDirectory }

    // MARK: - 初始化

    override init() {
        super.init()
        // 先把三个录制质量属性的初始值写进快照。它们是带 didSet 的 @Published，
        // 初始化时不会触发 didSet，不主动同步一次的话第一段录像是默认档而不是用户上次选的。
        syncSettings()
        mixedAudioFormat = PCMConverter.makeFormatDescription(
            sampleRate: AudioMixer.sampleRate, channels: AudioMixer.channels
        )
        mixer.onChunk = { [weak self] samples, offset in
            self?.handleMixedChunk(samples, frameOffset: offset)
        }
        systemAudio.onSampleBuffer = { [weak self] buffer in
            self?.handleSystemAudio(buffer)
        }
        systemAudio.onError = { [weak self] message in
            DispatchQueue.main.async { self?.statusMessage = "❌ 系统声音出错：\(message)" }
        }
    }

    // MARK: - 设置快照

    private func syncSettings() {
        var s = SettingsSnapshot()
        s.image = overlayImage
        s.trackingEnabled = trackingEnabled
        s.sizeScale = sizeScale
        s.offsetX = offsetX
        s.offsetY = offsetY
        s.mirror = mirror
        s.recordAudio = recordAudio
        s.audioSource = audioSource
        s.recordingResolution = recordingResolution
        s.recordingFrameRate = recordingFrameRate
        s.recordingQuality = recordingQuality
        s.showDebugBox = showDebugBox
        settingsLock.lock()
        settings = s
        settingsLock.unlock()
    }

    private func currentSettings() -> SettingsSnapshot {
        settingsLock.lock()
        defer { settingsLock.unlock() }
        return settings
    }

    // MARK: - 生命周期

    func start() {
        refreshCameras()
        AVCaptureDevice.requestAccess(for: .video) { [weak self] cameraOK in
            guard let self else { return }
            guard cameraOK else {
                DispatchQueue.main.async {
                    self.statusMessage = "❌ 摄像头权限被拒绝。请到「系统设置 → 隐私与安全性 → 摄像头」里勾选「脸罩 FaceCover」，然后重新打开 App。"
                }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micOK in
                DispatchQueue.main.async {
                    self.micAvailable = micOK
                    self.sessionQueue.async {
                        self.configureSession()
                        self.startRunning()
                    }
                }
            }
        }
    }

    private func startRunning() {
        if !session.isRunning { session.startRunning() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            // 就一句「准备就绪」。
            // 没选脸罩是可选操作、不是待办事项，挂在底部像在催；
            // 麦克风没授权在「声音」卡片里有专门的警告行，不需要在这里重复。
            self.statusMessage = "准备就绪"
        }
    }

    /// 把每次运行的采集参数追加到 `~/Movies/FaceCover/诊断.txt`。
    /// 排查「方向不对」「追踪不准」这类问题时，第一件事就是看这个文件。
    private func writeDiagnostic(_ line: String) {
        let url = AppPaths.diagnosticFile
        let stamp = ISO8601DateFormatter().string(from: Date())
        let text = "[\(stamp)] \(line)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    func shutdown() {
        recordRequested = false
        systemAudio.stop()
        if session.isRunning {
            sessionQueue.sync { self.session.stopRunning() }
        }

        writerLock.lock()
        let w = writer
        writer = nil
        videoInput = nil
        audioInput = nil
        videoAdaptor = nil
        sessionStarted = false
        writerLock.unlock()

        if let w, w.status == .writing {
            let sem = DispatchSemaphore(value: 0)
            w.finishWriting { sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
        }
    }

    // MARK: - 摄像头枚举

    func refreshCameras() {
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera, .external, .continuityCamera, .deskViewCamera
        ]
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified
        ).devices

        isRefreshingCameras = true
        cameras = discovered
        if selectedCameraID.isEmpty || !discovered.contains(where: { $0.uniqueID == selectedCameraID }) {
            selectedCameraID = discovered.first?.uniqueID ?? ""
        }
        isRefreshingCameras = false

        if discovered.isEmpty {
            statusMessage = "❌ 没有找到任何摄像头。"
        }
    }

    private func currentDevice() -> AVCaptureDevice? {
        if let id = cameras.first(where: { $0.uniqueID == selectedCameraID })?.uniqueID,
           let device = AVCaptureDevice(uniqueID: id) {
            return device
        }
        return AVCaptureDevice.default(for: .video)
    }

    /// 换分辨率时重建会话。摄像头达不到所选尺寸时不会放大 —— 只保证不高于所选。
    private func applyCapturePreset() {
        guard isRunning else { return }
        sessionQueue.async { [weak self] in self?.configureSession() }
    }

    /// 把摄像头的帧率锁到目标值。摄像头不支持该帧率时写一条诊断并保持默认。
    private func applyFrameRateLimit(to device: AVCaptureDevice?, frameRate: Int? = nil) {
        guard let device else { return }
        let targetFPS = frameRate ?? currentSettings().recordingFrameRate.rawValue
        let targetRate = Double(targetFPS)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            let format = device.activeFormat
            guard format.videoSupportedFrameRateRanges.contains(where: {
                      $0.minFrameRate <= targetRate && $0.maxFrameRate >= targetRate
                  }) else {
                writeDiagnostic("所选帧率 \(Int(targetRate))fps 不受当前摄像头/分辨率支持，使用摄像头默认帧率")
                return
            }
            let duration = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration
        } catch {
            writeDiagnostic("无法设置摄像头帧率：\(error.localizedDescription)")
        }
    }

    // MARK: - 会话配置

    private func configureSession() {
        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            // 帧率必须等预设生效之后再设 —— 换分辨率会改变可选帧率范围，
            // 提前设可能被摄像头忽略。
            applyFrameRateLimit(to: currentDevice(),
                                frameRate: currentSettings().recordingFrameRate.rawValue)
        }

        let current = currentSettings()
        let requestedPreset = current.recordingResolution.capturePreset
        let fallbackPresets: [AVCaptureSession.Preset] = [
            requestedPreset,
            .hd1920x1080,
            .hd1280x720,
            .vga640x480,
            .high
        ]
        if let supportedPreset = fallbackPresets.first(where: { session.canSetSessionPreset($0) }) {
            session.sessionPreset = supportedPreset
        }

        for input in session.inputs { session.removeInput(input) }

        if let device = currentDevice(),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        if !outputsWired {
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
            if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

            // 关键：采集连接自己默认可能会镜像（automaticallyAdjustsVideoMirroring 默认 true）。
            // 如果不关掉，我们后面再翻一次就等于没翻 —— 表现就是「开了镜像之后，
            // 遮罩跟着人往反方向跑」。这里强制关掉，让方向只由 Compositor 决定。
            if let connection = videoOutput.connection(with: .video) {
                let originalMirror = connection.isVideoMirrored
                let wasSupported = connection.isVideoMirroringSupported
                if connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                writeDiagnostic("""
                采集连接 isVideoMirrored 原本=\(originalMirror) 支持镜像=\(wasSupported) \
                强制关闭后=\(connection.isVideoMirrored)
                """)
            }

            audioOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 44100.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

            outputsWired = true
        }

        // 只在真的需要麦克风时才把它接进来（否则状态栏会一直亮着录音指示灯）
        if micAvailable,
           currentSettings().audioSource.needsMicrophone,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }
    }

    // MARK: - 声音来源

    /// 根据当前选择，开关麦克风输入和系统声音抓取。
    private func applyAudioSource() {
        let source = audioSource

        // 麦克风输入需要重配采集会话
        if source.needsMicrophone != lastMicrophoneNeeded {
            lastMicrophoneNeeded = source.needsMicrophone
            if isRunning {
                sessionQueue.async { [weak self] in self?.configureSession() }
            }
        }

        // 系统声音：ScreenCaptureKit，需要「屏幕录制」权限
        if source.needsSystemAudio {
            guard !systemAudio.isRunning else { return }
            statusMessage = "正在请求「屏幕录制」权限（录系统声音只能走这条路）…"
            systemAudio.start { [weak self] error in
                guard let self else { return }
                if let error {
                    self.statusMessage = "❌ 拿不到系统声音：\(error.localizedDescription)。请到「系统设置 → 隐私与安全性 → 屏幕录制」里勾上「脸罩 FaceCover」，然后重开 App。"
                } else if self.audioSource.needsSystemAudio {
                    self.statusMessage = "系统声音已就绪"
                }
            }
        } else if systemAudio.isRunning {
            systemAudio.stop()
        }
    }

    /// 在没有屏幕录制权限时，引导用户去系统设置
    func openScreenRecordingSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 图片载入

    func loadOverlayImage(from url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            statusMessage = "❌ 打不开这个图片文件：\(url.lastPathComponent)"
            return
        }
        selectedEffect = .custom
        overlayImage = image
        // 自定义图片没有「面孔开口」这个概念，调试框就不画开口了。
        overlayOpening = nil
        // 自定义图片和内置头套的目标不同（盖住脸 vs 让脸从开口露出来），
        // 所以套用的是另一套默认参数，不能沿用内置头套那套。
        sizeScale = CoverDefaults.customSizeScale
        offsetX = CoverDefaults.offsetX
        offsetY = CoverDefaults.offsetY
        if isRunning {
            statusMessage = "已选择「\(url.lastPathComponent)」，可以开始录制了"
        }
    }

    /// 使用随 App 打包的内置头套。素材保留透明通道，会跟普通脸罩一样
    /// 自动跟随人脸，并直接合成进录制的视频。
    ///
    /// 所有内置素材都归一化过（脸洞开口等宽、居中），所以换款式时套用同一组默认参数；
    /// 同时把上一款的微调清掉 —— 各款几何不同，留着上一款的位置只会更难对准。
    func useCover(_ cover: HeadCover) {
        guard let url = Bundle.main.url(forResource: cover.id, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            statusMessage = "❌ 找不到内置头套素材「\(cover.name)」，请重新编译或安装 App"
            return
        }

        selectedEffect = .cover(cover.id)
        overlayImage = image
        overlayOpening = Self.measureOpening(of: url, kind: cover.kind)
        sizeScale = CoverDefaults.defaultSizeScale(for: cover.kind)
        offsetX = CoverDefaults.offsetX
        offsetY = CoverDefaults.offsetY

        if isRunning {
            statusMessage = "已换上「\(cover.name)」头套，可以开始录制了"
        }
    }

    /// 量一次素材的锚点，转成相对画布的比例。
    ///
    /// 头套量的是面孔开口，整脸覆盖量的是轮廓包围盒 —— 两者的锚点定义不同，
    /// 但都归一到同一个 `OpeningGuide`，下游（归一化、调试框）不用分两条路。
    /// 素材是 1024×1024，全图扫描大约 10ms，只在换脸罩时跑一次，不影响帧率。
    private static func measureOpening(of url: URL,
                                       kind: HeadCover.Kind) -> Compositor.OpeningGuide? {
        let measured: CoverGeometry.Opening?
        switch kind {
        case .hood: measured = CoverGeometry.measure(path: url.path)
        case .mask: measured = CoverGeometry.measureMask(path: url.path)
        }
        guard let measured, measured.canvasSize > 0 else { return nil }
        let canvas = Double(measured.canvasSize)
        return Compositor.OpeningGuide(
            widthFraction: Double(measured.openingWidth) / canvas,
            heightFraction: Double(measured.openingHeight) / canvas,
            offsetX: (Double(measured.center.x) - canvas / 2) / canvas,
            offsetY: (Double(measured.center.y) - canvas / 2) / canvas
        )
    }

    func clearOverlay() {
        selectedEffect = .none
        overlayImage = nil
        overlayOpening = nil
        if isRunning {
            statusMessage = "已关闭遮挡，可继续录制原画"
        }
    }

    // MARK: - 录制控制

    func toggleRecording() {
        if recordRequested || isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func startRecording() {
        guard isRunning else {
            statusMessage = "摄像头还没准备好，稍等一下再试"
            return
        }
        guard !recordRequested, !isRecording else { return }
        let source = audioSource
        mixer.configure(useMicrophone: source == .both, useSystem: source == .both)
        recordRequested = true
        statusMessage = "正在开始录制…"
    }

    func stopRecording() {
        guard recordRequested || writer != nil else { return }
        recordRequested = false

        // 排到视频队列末尾，保证没有正在处理中的帧还在往 writer 里写
        videoQueue.async { [weak self] in
            self?.mixer.flush()
            guard let self else { return }

            self.writerLock.lock()
            let w = self.writer
            let url = w?.outputURL
            self.writer = nil
            self.videoInput = nil
            self.audioInput = nil
            self.videoAdaptor = nil
            self.sessionStarted = false
            self.lastAppendedVideoPTS = nil
            self.writerLock.unlock()

            guard let w else {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingStartedAt = nil
                    self.statusMessage = "已取消录制"
                }
                return
            }

            w.finishWriting {
                let ok = w.status == .completed
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.recordingStartedAt = nil
                    if ok {
                        self.lastRecordingURL = url
                        self.statusMessage = "✅ 已保存 \(url?.lastPathComponent ?? "")"
                    } else {
                        self.statusMessage = "❌ 保存失败：\(w.error?.localizedDescription ?? "未知错误")"
                    }
                }
            }
        }
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: Self.outputDirectory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.outputDirectory)
    }

    func revealLastRecording() {
        guard let url = lastRecordingURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: - 写文件

    private static func makeOutputURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "FaceCover-\(formatter.string(from: Date())).mov"
        return outputDirectory.appendingPathComponent(name)
    }

    /// 在收到录制开始后的第一帧时才真正建 writer —— 这时才知道确切的画面尺寸，
    /// 也才能用这一帧的时间戳调用 startSession，避免视频开头出现一大段空白。
    private func beginWriter(width: Int, height: Int, at startPTS: CMTime) {
        let url = Self.makeOutputURL()
        let s = currentSettings()
        // 采集尺寸和输出尺寸可以不同：摄像头可能给得比用户选的档位更高，
        // 这时候在写文件之前降采样，而不是放大。
        let outputSize = s.recordingResolution.outputSize(sourceWidth: width, sourceHeight: height)

        do {
            let components = try Recorder.makeComponents(
                url: url,
                width: outputSize.width,
                height: outputSize.height,
                audioChannels: s.audioSource == .none ? nil : s.audioSource.outputChannels,
                startPTS: startPTS,
                frameRate: s.recordingFrameRate.rawValue,
                quality: s.recordingQuality
            )

            writerLock.lock()
            writer = components.writer
            videoInput = components.videoInput
            audioInput = components.audioInput
            videoAdaptor = components.adaptor
            audioSessionStart = startPTS
            lastAppendedVideoPTS = nil
            sessionStarted = true
            writerLock.unlock()

            DispatchQueue.main.async { [weak self] in
                self?.recordingStartedAt = Date()
                self?.isRecording = true
                self?.statusMessage = "● 正在录制…"
            }
        } catch {
            recordRequested = false
            DispatchQueue.main.async { [weak self] in
                self?.isRecording = false
                self?.statusMessage = "❌ 无法开始录制：\(error.localizedDescription)"
            }
        }
    }

    private func copyPixelBuffer(from src: CVPixelBuffer, to dst: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(src, .readOnly)
        CVPixelBufferLockBaseAddress(dst, [])
        defer {
            CVPixelBufferUnlockBaseAddress(dst, [])
            CVPixelBufferUnlockBaseAddress(src, .readOnly)
        }
        guard let s = CVPixelBufferGetBaseAddress(src),
              let d = CVPixelBufferGetBaseAddress(dst) else { return }

        let rows = min(CVPixelBufferGetHeight(src), CVPixelBufferGetHeight(dst))
        let srcRow = CVPixelBufferGetBytesPerRow(src)
        let dstRow = CVPixelBufferGetBytesPerRow(dst)
        let bytes = min(srcRow, dstRow)
        for y in 0..<rows {
            memcpy(d.advanced(by: y * dstRow), s.advanced(by: y * srcRow), bytes)
        }
    }

    /// 把一帧写进文件。
    ///
    /// 做两件事：
    /// 1. **抽帧** —— 摄像头可能跑在 30fps，用户选了 24fps，这时候丢掉间隔不够的帧，
    ///    否则实际录出来的 fps 还是摄像头的（摄像头帧率也会被设成目标值，
    ///    但两者不一致时兜底靠这里）。
    /// 2. **缩放** —— 采集尺寸和输出尺寸不同时，先按目标宽高比居中裁剪再缩放。
    ///    不裁剪直接缩放会拉伸画面。
    private func appendFrame(_ source: CVPixelBuffer, at pts: CMTime, frameRate: Int) {
        let minimumInterval = 1.0 / Double(max(frameRate, 1))
        if let lastPTS = lastAppendedVideoPTS,
           CMTimeGetSeconds(CMTimeSubtract(pts, lastPTS)) + 0.000_001 < minimumInterval {
            return
        }

        writerLock.lock()
        let input = videoInput
        let adaptor = videoAdaptor
        writerLock.unlock()

        guard let input, let adaptor,
              input.isReadyForMoreMediaData,
              let pool = adaptor.pixelBufferPool else { return }

        var destination: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &destination) == kCVReturnSuccess,
              let destination else { return }

        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let outputWidth = CVPixelBufferGetWidth(destination)
        let outputHeight = CVPixelBufferGetHeight(destination)

        if sourceWidth == outputWidth && sourceHeight == outputHeight {
            copyPixelBuffer(from: source, to: destination)
        } else {
            CVPixelBufferLockBaseAddress(destination, [])
            defer { CVPixelBufferUnlockBaseAddress(destination, []) }

            let image = CIImage(cvPixelBuffer: source)
            let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
            let outputAspect = Double(outputWidth) / Double(outputHeight)
            let cropped: CIImage
            if sourceAspect > outputAspect {
                let cropWidth = CGFloat(sourceHeight) * CGFloat(outputAspect)
                cropped = image.cropped(to: CGRect(x: image.extent.midX - cropWidth / 2,
                                                   y: image.extent.minY,
                                                   width: cropWidth,
                                                   height: image.extent.height))
            } else {
                let cropHeight = CGFloat(sourceWidth) / CGFloat(outputAspect)
                cropped = image.cropped(to: CGRect(x: image.extent.minX,
                                                   y: image.extent.midY - cropHeight / 2,
                                                   width: image.extent.width,
                                                   height: cropHeight))
            }
            let sx = CGFloat(outputWidth) / cropped.extent.width
            let sy = CGFloat(outputHeight) / cropped.extent.height
            let scaled = cropped
                .transformed(by: CGAffineTransform(translationX: -cropped.extent.minX,
                                                   y: -cropped.extent.minY))
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy))
            let bounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
            ciContext.render(scaled, to: destination, bounds: bounds,
                             colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }

        if adaptor.append(destination, withPresentationTime: pts) {
            lastAppendedVideoPTS = pts
        }
    }

    // MARK: - 人脸检测

    private func detectFaces(in pixelBuffer: CVPixelBuffer) -> [FaceObservation]? {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        return Array((request.results ?? []).prefix(12)).map {
            FaceObservation(boundingBox: $0.boundingBox, roll: $0.roll?.doubleValue ?? 0)
        }
    }

    /// 按实测耗时决定「每几帧检测一次」。
    ///
    /// **必须带迟滞。** 单个阈值（原来写的是 `cost > 0.015 ? 2 : 1`）在耗时贴着阈值抖动时，
    /// 会让 `detectEvery` 每帧翻转：一会儿每帧有检测、一会儿隔帧才有。
    /// 隔帧那一帧只能靠速度外推，遮罩的运动节奏于是变得不匀 —— 看起来就是「慌」。
    /// 所以降级和恢复用两个不同阈值，并且要连续若干帧确认才切换。
    /// 多人脸检测耗时随人数增加，更容易撞上阈值，迟滞在这里更必要。
    private func updateDetectionCadence() {
        guard let cost = visionCost else { return }

        if cost > Self.slowCostThreshold {
            slowStreak += 1
            fastStreak = 0
        } else if cost < Self.fastCostThreshold {
            fastStreak += 1
            slowStreak = 0
        } else {
            // 中间地带：保持现状，不来回切
            slowStreak = 0
            fastStreak = 0
        }

        if detectEvery == 1 && slowStreak >= Self.slowStreakFrames {
            detectEvery = 2
        } else if detectEvery == 2 && fastStreak >= Self.fastStreakFrames {
            detectEvery = 1
        }
    }

    private func updateFaces(in pixelBuffer: CVPixelBuffer,
                             settings s: SettingsSnapshot,
                             at time: Double) -> [TrackedFace] {
        guard s.image != nil, s.trackingEnabled else {
            // 关闭跟随时不需要检测。使用自定义图片时保留单个居中手动位置。
            faceTracker.reset()
            setFaceVisible(false, count: 0)
            return []
        }

        var observations: [FaceObservation]?
        if frameCounter % detectEvery == 0 {
            let started = CACurrentMediaTime()
            observations = detectFaces(in: pixelBuffer)
            let cost = CACurrentMediaTime() - started
            visionCost = visionCost.map { $0 * 0.9 + cost * 0.1 } ?? cost
            updateDetectionCadence()
        }

        let faces = faceTracker.update(observations: observations, at: time)
        setFaceVisible(!faces.isEmpty, count: faces.count)
        return faces
    }

    private func setFaceVisible(_ visible: Bool, count: Int) {
        guard visible != lastFaceVisible || count != lastPublishedFaceCount else { return }
        lastFaceVisible = visible
        lastPublishedFaceCount = count
        DispatchQueue.main.async { [weak self] in
            self?.faceVisible = visible
            self?.trackedFaceCount = count
        }
    }

    // MARK: - 合成

    private func publishPreview(from pixelBuffer: CVPixelBuffer) {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let sink = preview
        DispatchQueue.main.async { sink.image = cgImage }
    }

    // MARK: - 每帧处理

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let s = currentSettings()

        frameCounter &+= 1

        // 换镜像方向后所有脸都要重新关联，避免旧坐标对应到错误的人。
        if s.mirror != lastAppliedMirror {
            lastAppliedMirror = s.mirror
            faceTracker.reset()
        }

        // 顺序很重要：先定画面方向 → 再检测并匹配多人脸 → 再逐脸贴图。
        Compositor.mirrorIfNeeded(pixelBuffer, mirror: s.mirror)
        let time = CMTimeGetSeconds(pts)
        let faces = updateFaces(in: pixelBuffer, settings: s, at: time)
        logFaceDiagnostic(faces: faces, time: time)

        if let overlay = s.image {
            if s.trackingEnabled {
                for face in faces {
                    Compositor.drawOverlay(overlay: overlay,
                                           into: pixelBuffer,
                                           faceNormalized: face.boundingBox,
                                           sizeScale: s.sizeScale,
                                           offsetX: s.offsetX,
                                           offsetY: s.offsetY,
                                           rotationRadians: face.roll)
                }
            } else {
                Compositor.drawOverlay(overlay: overlay,
                                       into: pixelBuffer,
                                       faceNormalized: Self.fallbackFace,
                                       sizeScale: s.sizeScale,
                                       offsetX: s.offsetX,
                                       offsetY: s.offsetY)
            }
        }

        // 录制必须在画调试框之前 —— 调试框只能出现在预览里，绝不能进视频文件
        if recordRequested {
            writerLock.lock()
            let started = sessionStarted
            writerLock.unlock()

            if !started {
                beginWriter(width: CVPixelBufferGetWidth(pixelBuffer),
                            height: CVPixelBufferGetHeight(pixelBuffer),
                            at: pts)
            }
            appendFrame(pixelBuffer, at: pts, frameRate: s.recordingFrameRate.rawValue)
        }

        // 调试框只画在预览上，不参与录制
        if s.showDebugBox {
            for face in faces {
                Compositor.drawDebugBox(into: pixelBuffer,
                                        faceNormalized: face.boundingBox,
                                        overlay: s.image,
                                        opening: overlayOpening,
                                        sizeScale: s.sizeScale,
                                        offsetX: s.offsetX,
                                        offsetY: s.offsetY)
            }
        }

        publishPreview(from: pixelBuffer)
    }

    /// 每秒往诊断文件记一行：检测到的人脸框 vs 实际贴图用的框。
    ///
    /// 原来只记了 x，所以「位置不对」这类问题只能靠猜。现在把 y、脸框尺寸、
    /// 贴图缩放都记下来 —— 出问题时对着这行数字就能算出贴图到底落在哪。
    /// 多人脸时先记总人数和每个人的横向位置，再记「主脸」（第一张）的完整信息，
    /// 单人场景下这一行就是全部。
    private func logFaceDiagnostic(faces: [TrackedFace], time: Double) {
        guard time - lastFaceLogTime >= 1.0 else { return }
        lastFaceLogTime = time
        let s = currentSettings()
        let centers = faces.map { String(format: "#%d:x=%.3f", $0.id, $0.boundingBox.midX) }
            .joined(separator: ",")

        var primary = ""
        if let face = faces.first?.boundingBox {
            // 贴图中心 = 人脸中心 + 偏移（偏移量的单位是脸宽 / 脸高）
            let overlayX = face.midX + CGFloat(s.offsetX) * face.width
            let overlayY = face.midY - CGFloat(s.offsetY) * face.height
            primary = String(format: " | 主脸中心=(%.3f,%.3f) 脸框=%.3f×%.3f 贴图中心=(%.3f,%.3f) 缩放=%.2f×脸宽",
                             face.midX, face.midY, face.width, face.height,
                             overlayX, overlayY, s.sizeScale)
        }

        writeDiagnostic("多人脸=\(faces.count) [\(centers)]\(primary)"
                        + " | 镜像=\(s.mirror ? "开" : "关") | 检测间隔=\(detectEvery)帧")
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        let s = currentSettings()
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        switch s.audioSource {
        case .none:
            return
        case .microphone:
            // 直通：麦克风本来就是单声道 LPCM，直接给 writer
            appendAudio(sampleBuffer)
        case .system:
            // 系统声音走 SystemAudioCapture，不从这里进
            return
        case .both:
            mixer.appendMicrophone(sampleBuffer, at: time)
        }
    }

    /// 系统声音回调（ScreenCaptureKit 的队列）
    private func handleSystemAudio(_ sampleBuffer: CMSampleBuffer) {
        let s = currentSettings()
        let time = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        switch s.audioSource {
        case .system:
            appendAudio(sampleBuffer)
        case .both:
            mixer.appendSystem(sampleBuffer, at: time)
        default:
            return
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        writerLock.lock()
        let input = audioInput
        let started = sessionStarted
        writerLock.unlock()

        guard started, let input, input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    /// 混音器吐出来的块，自己包成 CMSampleBuffer 再写进文件
    private func handleMixedChunk(_ samples: [Int16], frameOffset: Int) {
        writerLock.lock()
        let input = audioInput
        let started = sessionStarted
        let sessionStart = audioSessionStart
        writerLock.unlock()

        guard started, let input, input.isReadyForMoreMediaData,
              let format = mixedAudioFormat, let sessionStart else { return }

        let pts = CMTimeAdd(sessionStart,
                            CMTime(value: CMTimeValue(frameOffset),
                                   timescale: CMTimeScale(AudioMixer.sampleRate)))
        guard let buffer = PCMConverter.makeSampleBuffer(samples: samples,
                                                         format: format,
                                                         sampleRate: AudioMixer.sampleRate,
                                                         channels: AudioMixer.channels,
                                                         at: pts) else { return }
        input.append(buffer)
    }
}

// MARK: - 采集回调

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
                       AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else if output === audioOutput {
            handleAudio(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 掉帧是可以接受的：writer 用真实时间戳写文件，画面不会变形，只是帧率略降
    }
}
