import AVFoundation
import AppKit
import Combine
import CoreImage
import CoreMedia
import QuartzCore
import Vision

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
    var sizeScale: Double = 1.8
    var offsetX: Double = 0
    var offsetY: Double = 0
    var mirror = true
    var recordAudio = true
    var audioSource: AudioSource = .microphone
    var showDebugBox = false
}

// MARK: - 引擎

final class CameraEngine: NSObject, ObservableObject {

    // MARK: 对外状态

    let preview = PreviewSink()

    @Published private(set) var isRunning = false
    @Published private(set) var isRecording = false
    @Published private(set) var faceVisible = false
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var micAvailable = false
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
    @Published var sizeScale: Double = 1.8 { didSet { syncSettings() } }
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

    /// 从没检测到脸时，图片默认盖在画面中间偏上的位置。
    private static let fallbackFace = CGRect(x: 0.375, y: 0.52, width: 0.25, height: 0.25)
    private var faceTracker = FaceTracker()
    private var missedFrames = 0
    private var lastFaceVisible = false
    private var lastAppliedMirror = true
    private var frameCounter = 0
    /// 默认每帧都检测；实测 Vision 太慢时自动降到每 2 帧一次
    private var detectEvery = 1
    private var visionCost: Double?
    private var lastFaceLogTime: Double = 0

    // MARK: 录制

    private let writerLock = NSLock()
    private var recordRequested = false
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStarted = false

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
            if self.overlayImage == nil {
                self.statusMessage = "请先选择一张图片作为「脸罩」"
            } else if self.micAvailable {
                self.statusMessage = "准备就绪（画面 + 声音）"
            } else {
                self.statusMessage = "准备就绪（麦克风未授权，只录画面）"
            }
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

    // MARK: - 会话配置

    private func configureSession() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
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
        overlayImage = image
        if isRunning {
            statusMessage = "已选择「\(url.lastPathComponent)」，可以开始录制了"
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
        guard overlayImage != nil else {
            statusMessage = "先选一张图片当「脸罩」，不然挡住的是什么？"
            return
        }
        guard !recordRequested else { return }
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
            self.writerLock.unlock()

            guard let w else {
                DispatchQueue.main.async {
                    self.isRecording = false
                    self.statusMessage = "已取消录制"
                }
                return
            }

            w.finishWriting {
                let ok = w.status == .completed
                DispatchQueue.main.async {
                    self.isRecording = false
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

        do {
            let components = try Recorder.makeComponents(
                url: url,
                width: width,
                height: height,
                audioChannels: s.audioSource == .none ? nil : s.audioSource.outputChannels,
                startPTS: startPTS
            )

            writerLock.lock()
            writer = components.writer
            videoInput = components.videoInput
            audioInput = components.audioInput
            videoAdaptor = components.adaptor
            audioSessionStart = startPTS
            sessionStarted = true
            writerLock.unlock()

            DispatchQueue.main.async { [weak self] in
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

    private func appendFrame(_ source: CVPixelBuffer, at pts: CMTime) {
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

        copyPixelBuffer(from: source, to: destination)
        adaptor.append(destination, withPresentationTime: pts)
    }

    // MARK: - 人脸检测

    private func detectLargestFace(in pixelBuffer: CVPixelBuffer) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        return (request.results ?? []).max { a, b in
            a.boundingBox.width * a.boundingBox.height < b.boundingBox.width * b.boundingBox.height
        }?.boundingBox
    }

    private func updateFace(in pixelBuffer: CVPixelBuffer,
                            settings s: SettingsSnapshot,
                            at time: Double) {
        guard s.trackingEnabled else {
            // 关掉跟随时固定用兜底位置，让滑块手动挪
            faceTracker.reset()
            missedFrames = 0
            if lastFaceVisible {
                lastFaceVisible = false
                DispatchQueue.main.async { [weak self] in self?.faceVisible = false }
            }
            return
        }

        // 逐帧检测。Vision 在 720p 上大约 5~10ms，33ms 的帧预算完全够。
        // 万一某台机器吃力，下面会根据实测耗时自动降到每 2 帧一次。
        var measurement: CGRect?
        if frameCounter % detectEvery == 0 {
            let started = CACurrentMediaTime()
            measurement = detectLargestFace(in: pixelBuffer)
            let cost = CACurrentMediaTime() - started
            visionCost = visionCost.map { $0 * 0.9 + cost * 0.1 } ?? cost
            if let cost = visionCost {
                detectEvery = cost > 0.015 ? 2 : 1
            }
            if measurement != nil {
                missedFrames = 0
            } else {
                missedFrames += 1
            }
        }

        faceTracker.update(measurement: measurement, at: time)

        // 只有真正「新鲜」的检测结果才算可见
        let fresh = measurement != nil || (missedFrames > 0 && missedFrames < 3)
        if fresh != lastFaceVisible {
            lastFaceVisible = fresh
            DispatchQueue.main.async { [weak self] in
                self?.faceVisible = fresh
            }
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

        // 换了镜像方向的话，上一帧的人脸坐标就不在同一个空间里了，丢掉重新跟
        if s.mirror != lastAppliedMirror {
            lastAppliedMirror = s.mirror
            faceTracker.reset()
            missedFrames = 0
        }

        // 顺序很重要：先定画面方向 → 再在这个画面上检测人脸 → 再把脸罩贴上去。
        // 检测和贴图在同一个坐标空间里，遮罩不可能跟脸走反。
        Compositor.mirrorIfNeeded(pixelBuffer, mirror: s.mirror)
        let time = CMTimeGetSeconds(pts)
        updateFace(in: pixelBuffer, settings: s, at: time)

        let face = s.trackingEnabled
            ? (faceTracker.predicted ?? Self.fallbackFace)
            : Self.fallbackFace
        logFaceDiagnostic(face: face, time: time)

        if let overlay = s.image {
            Compositor.drawOverlay(overlay: overlay,
                                   into: pixelBuffer,
                                   faceNormalized: face,
                                   sizeScale: s.sizeScale,
                                   offsetX: s.offsetX,
                                   offsetY: s.offsetY)
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
            appendFrame(pixelBuffer, at: pts)
        }

        // 调试框只画在预览上，不参与录制
        if s.showDebugBox {
            Compositor.drawDebugBox(into: pixelBuffer, faceNormalized: face)
        }

        publishPreview(from: pixelBuffer)
    }

    /// 每秒往诊断文件记一行：检测到的人脸框 vs 实际贴图用的框。
    /// 用来判断「遮罩和脸反向」到底是跟踪问题还是镜像语义问题。
    private func logFaceDiagnostic(face: CGRect, time: Double) {
        guard time - lastFaceLogTime >= 1.0 else { return }
        lastFaceLogTime = time
        let s = currentSettings()
        writeDiagnostic(String(
            format: "人脸中心x=%.3f | 贴图中心x=%.3f | 镜像=%@ | 逐帧检测=%@ | 已追踪=%@",
            face.midX,
            face.midX + CGFloat(s.offsetX) * face.width,
            s.mirror ? "开" : "关",
            detectEvery == 1 ? "是" : "否",
            faceTracker.predicted == nil ? "否" : "是"
        ))
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
