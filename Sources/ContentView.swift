import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var library: RecordingLibrary
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            previewPane
            Divider()
            controlPane
                .frame(width: 330)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .onAppear { engine.start() }
        // 录完一段，录像库立刻刷新，不用手动点
        .onChange(of: engine.lastRecordingURL) { _, newValue in
            if newValue != nil { library.refresh() }
        }
    }

    // MARK: 预览

    private var previewPane: some View {
        ZStack {
            Color.black

            PreviewView(sink: engine.preview) { url in
                engine.loadOverlayImage(from: url)
            }

            VStack {
                HStack {
                    statusBadge
                    Spacer()
                }
                Spacer()
            }
            .padding(12)
        }
        .frame(minWidth: 620)
    }

    private var statusBadge: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 8, height: 8)
                Text(indicatorText(at: context.date))
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }

    private var indicatorColor: Color {
        if engine.isRecording { return .red }
        if engine.overlayImage == nil { return .gray }
        return engine.faceVisible ? .green : .orange
    }

    private func indicatorText(at now: Date) -> String {
        if engine.isRecording, let startedAt = engine.recordingStartedAt {
            let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            return String(format: "录制中 %02d:%02d", minutes, seconds)
        }
        if engine.overlayImage == nil { return "还没有脸罩" }
        return engine.faceVisible ? "已锁定人脸" : "未检测到人脸"
    }

    // MARK: 控制面板

    private var controlPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("脸罩 FaceCover").font(.title3).bold()
                    Text("选择内置头套或自己的图片，特效会自动跟脸并录进视频。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                imageSection

                Divider()

                trackingSection

                Divider()

                recordSection

                Divider()

                cameraSection
            }
            .padding(16)
        }
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("脸罩 / 头套特效")

            Button {
                engine.usePigHeadEffect()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "theatermasks.fill")
                        .font(.title3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("猪头头套").bold()
                        Text("毛绒穿戴效果 · 跟随位置和歪头角度")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if engine.selectedEffect == .pigHead {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(
                engine.selectedEffect == .pigHead
                    ? Color.accentColor.opacity(0.16)
                    : Color.secondary.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(engine.selectedEffect == .pigHead
                            ? Color.accentColor : Color.clear, lineWidth: 1)
            }

            HStack(spacing: 12) {
                Group {
                    if let image = engine.overlayImage {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "questionmark")
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 68, height: 68)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 8) {
                    Button("选择自定义图片…") { chooseImage() }
                    if engine.overlayImage != nil {
                        Button("关闭特效") { engine.clearOverlay() }
                            .buttonStyle(.link)
                    }
                }
                Spacer()
            }

            Text("也可以用自己的正方形透明 PNG（比如表情包、卡通头像、贴纸）。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var trackingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("遮挡方式")

            Toggle("自动跟随人脸", isOn: $engine.trackingEnabled)
                .toggleStyle(.switch)

            Text(engine.trackingEnabled
                 ? "Vision 会实时检测你的脸，图片自动贴上去。"
                 : "已关闭跟随，用下面的滑块手动把图片挪到脸上。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            sliderRow("大小", value: $engine.sizeScale, range: 0.4...6.0)
            sliderRow("左右", value: $engine.offsetX, range: -2.0...2.0)
            sliderRow("上下（正值向下）", value: $engine.offsetY, range: -2.0...2.0)

            HStack {
                Button("复位") {
                    engine.sizeScale = 1.8
                    engine.offsetX = 0
                    engine.offsetY = 0
                }
                .buttonStyle(.link)
                Spacer()
            }

            Toggle("画面镜像（像照镜子）", isOn: $engine.mirror)
                .toggleStyle(.switch)

            Toggle("显示人脸检测框（只看预览，不进视频）", isOn: $engine.showDebugBox)
                .toggleStyle(.switch)
        }
    }

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("录制")

            Picker("声音来源", selection: $engine.audioSource) {
                ForEach(AudioSource.allCases) { source in
                    Text(source.label).tag(source)
                }
            }

            if engine.audioSource.needsMicrophone && !engine.micAvailable {
                Text("麦克风没有授权。到「系统设置 → 隐私与安全性 → 麦克风」里打开。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if engine.audioSource.needsSystemAudio {
                Text("录系统声音需要「屏幕录制」权限（macOS 只给这一个入口），第一次会弹窗询问。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开屏幕录制权限设置") { engine.openScreenRecordingSettings() }
                    .buttonStyle(.link)
                    .font(.caption2)
            }

            Button {
                engine.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: engine.isRecording ? "stop.circle.fill" : "record.circle")
                    Text(engine.isRecording ? "停止录制" : "开始录制").bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(engine.isRecording ? .red : .accentColor)
            .keyboardShortcut(.return, modifiers: [.command])

            Text(engine.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let url = engine.lastRecordingURL {
                Button {
                    engine.revealLastRecording()
                } label: {
                    Label(url.lastPathComponent, systemImage: "film")
                        .font(.caption)
                }
                .buttonStyle(.link)
            }

            HStack(spacing: 12) {
                Button {
                    openWindow(id: "library")
                } label: {
                    Label("录像库", systemImage: "film.stack")
                }
                Button("打开文件夹") { engine.openOutputFolder() }
            }
            .font(.caption)
        }
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("摄像头")
            Picker("", selection: $engine.selectedCameraID) {
                ForEach(engine.cameras, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            .labelsHidden()
            .disabled(engine.cameras.isEmpty)
        }
    }

    // MARK: 小组件

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.subheadline).bold()
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    // MARK: 动作

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "选一张图片用来盖住你的脸"
        if panel.runModal() == .OK, let url = panel.url {
            engine.loadOverlayImage(from: url)
        }
    }
}
