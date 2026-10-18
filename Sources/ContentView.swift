import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - 侧边栏的界面状态

/// 这台机器只有 Command Line Tools，`SwiftUIMacros` 插件不存在，所以 **`@State` 用不了**。
/// 界面上的局部状态统一用 `@StateObject` + `ObservableObject` 承载，
/// 这是传统 property wrapper，不受宏影响。
final class PanelState: ObservableObject {
    /// 鼠标正悬停在哪个瓦片上（"builtin" / "custom" / HeadCover.id）
    @Published var hoveredTile: String?
    /// 二级头套列表是否展开
    @Published var coverPickerOpen = false

    private var thumbnails: [String: CGImage] = [:]

    /// 头套缩略图。头套列表每次重绘都要用到，读盘结果缓存起来，
    /// 不然鼠标一动就重新解码 7 张 1024×1024 的 PNG。
    func thumbnail(_ cover: HeadCover) -> CGImage? {
        if let cached = thumbnails[cover.id] { return cached }
        guard let url = Bundle.main.url(forResource: cover.id, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        thumbnails[cover.id] = image
        return image
    }
}

struct ContentView: View {
    @ObservedObject var engine: CameraEngine
    @ObservedObject var library: RecordingLibrary
    @StateObject private var panel = PanelState()
    @Environment(\.openWindow) private var openWindow

    private let panelWidth: CGFloat = 348

    var body: some View {
        HStack(spacing: 0) {
            previewPane
            Divider()
            sidebar
                .frame(width: panelWidth)
        }
        .frame(minWidth: 1000, minHeight: 660)
        .onAppear { engine.start() }
        // 录完一段，录像库立刻刷新，不用手动点
        .onChange(of: engine.lastRecordingURL) { _, newValue in
            if newValue != nil { library.refresh() }
        }
        // 录完一段弹一次「已保存」。看一眼就消失，不会反复弹。
        .alert(item: $engine.savedAlert) { alert in
            Alert(
                title: Text("录像已保存"),
                message: Text("\(alert.fileName)\n\(alert.sizeText)"),
                primaryButton: .default(Text("查看")) {
                    openRecording(alert.url)
                },
                secondaryButton: .cancel(Text("好"))
            )
        }
    }

    // MARK: - 预览

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
        if engine.overlayImage == nil { return .secondary }
        return engine.faceVisible ? .green : .orange
    }

    private func indicatorText(at now: Date) -> String {
        if engine.isRecording, let startedAt = engine.recordingStartedAt {
            let elapsed = max(0, Int(now.timeIntervalSince(startedAt)))
            let minutes = elapsed / 60
            let seconds = elapsed % 60
            return String(format: "录制中 %02d:%02d", minutes, seconds)
        }
        // 没选脸罩时不写「未选脸罩」—— 那是可选操作，用中性的模式名就行
        if engine.overlayImage == nil { return "原画模式" }
        return engine.faceVisible ? "已准备好了" : "未检测到人脸（可继续录制）"
    }

    // MARK: - 侧边栏

    /// 上面是可滚动的设置卡片，下面是**固定不滚动**的录制栏。
    /// 录制是这个 App 唯一的「主动作」，不该因为窗口矮一点就要先滚动才点得到。
    private var sidebar: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    effectCard
                    placementCard
                    viewCard
                    qualityCard
                    audioCard
                    cameraCard
                    fileCard
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 16)
            }

            Divider()

            recordBar
        }
    }

    // MARK: - 脸罩（两级）

    private var selectedCover: HeadCover? {
        engine.selectedEffect.coverID.flatMap { HeadCover.named($0) }
    }

    /// 当前脸罩对应的默认缩放。
    /// 头套 / 整脸覆盖 / 自定义图片是三套不同的默认值，滑块的「复位」要跟着当前这款走。
    private var defaultSizeScale: Double {
        if let cover = selectedCover {
            return CoverDefaults.defaultSizeScale(for: cover.kind)
        }
        if engine.selectedEffect == .custom {
            return CoverDefaults.customSizeScale
        }
        return CoverDefaults.sizeScale
    }

    /// 当前脸罩对应的默认纵向偏移。
    /// 整脸覆盖要盖的是「头」，默认上移 0.20 个脸框高；头套的锚点就是面孔开口，不用挪。
    /// 「全部复位」和滑块的 `↺` 都必须用这个值 —— 用 0 会把整脸覆盖复位回偏下的位置。
    private var defaultOffsetY: Double {
        if let cover = selectedCover {
            return CoverDefaults.defaultOffsetY(for: cover.kind)
        }
        if engine.selectedEffect == .custom {
            return CoverDefaults.customOffsetY
        }
        return 0
    }

    private var effectCard: some View {
        card("脸罩", systemImage: "theatermasks",
             trailing: engine.overlayImage == nil ? nil : AnyView(
                Button {
                    engine.clearOverlay()
                } label: {
                    Text("清除").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("移除脸罩，恢复原始画面")
             )) {
            HStack(spacing: 8) {
                builtInTile
                customTile
            }

            if panel.coverPickerOpen {
                coverPicker
            }

            Text("也可以直接把图片拖到左边的预览画面上。不选脸罩也能直接录制原画。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// 一级：内置脸罩。点一下展开二级列表。
    private var builtInTile: some View {
        let cover = selectedCover
        let open = panel.coverPickerOpen

        return Button {
            panel.coverPickerOpen.toggle()
        } label: {
            tileLabel(
                title: "内置脸罩",
                badge: cover?.name ?? "\(HeadCover.all.count) 款",
                image: cover == nil ? nil : engine.overlayImage,
                placeholderIcon: "theatermasks.fill",
                selected: cover != nil,
                hovering: panel.hoveredTile == "builtin",
                trailing: AnyView(
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.secondary)
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            setHover("builtin", hovering)
        }
        .help(open
              ? "收起脸罩列表"
              : "展开 \(HeadCover.all.count) 款内置脸罩：\(HeadCover.hoods.count) 款头套 + \(HeadCover.masks.count) 款整脸覆盖")
    }

    /// 一级：自定义图片。
    private var customTile: some View {
        let selected = engine.selectedEffect == .custom

        return Button {
            chooseImage()
        } label: {
            tileLabel(
                title: "自定义图片",
                badge: selected ? "已启用" : "PNG / 拖拽",
                image: selected ? engine.overlayImage : nil,
                placeholderIcon: "photo.badge.plus",
                selected: selected,
                hovering: panel.hoveredTile == "custom",
                trailing: nil
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            setHover("custom", hovering)
        }
        .help(selected ? "换一张图片" : "选一张自己的正方形透明 PNG（表情包 / 卡通头像 / 贴纸）")
    }

    /// 二级：脸罩列表。两类素材的用途不同，分组显示，别混在一起。
    private var coverPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            HStack(spacing: 5) {
                Text("选择脸罩")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    panel.coverPickerOpen = false
                } label: {
                    Text("收起").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            }

            coverGroup(HeadCover.Kind.hood.label, HeadCover.hoods)
            coverGroup(HeadCover.Kind.mask.label, HeadCover.masks)

            Text("换脸罩会自动把大小和位置复位成该款的默认值。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func coverGroup(_ title: String, _ covers: [HeadCover]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
                      spacing: 8) {
                ForEach(covers) { cover in
                    coverTile(cover)
                }
            }
        }
    }

    private func coverTile(_ cover: HeadCover) -> some View {
        let selected = engine.selectedEffect.coverID == cover.id

        return Button {
            engine.useCover(cover)
        } label: {
            VStack(spacing: 0) {
                ZStack {
                    Rectangle().fill(Color.primary.opacity(0.05))
                    if let image = panel.thumbnail(cover) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(4)
                    } else {
                        // 素材读不到时给个占位，别让格子空着
                        Image(systemName: "theatermasks")
                            .font(.system(size: 22))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 56)
                .frame(maxWidth: .infinity)
                .clipped()

                HStack(spacing: 3) {
                    Text(cover.name)
                        .font(.system(size: 11))
                        .fontWeight(selected ? .semibold : .regular)
                        .lineLimit(1)
                    Spacer(minLength: 1)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
            }
            .background(tileBackground(selected: selected,
                                       hovering: panel.hoveredTile == cover.id))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10),
                                  lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            setHover(cover.id, hovering)
        }
        .help(cover.tagline)
    }

    /// 一级瓦片的公共版式：预览图 + 名字 + 一行说明 + 右侧配件。
    private func tileLabel(title: String,
                           badge: String,
                           image: CGImage?,
                           placeholderIcon: String,
                           selected: Bool,
                           hovering: Bool,
                           trailing: AnyView?) -> some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(Color.primary.opacity(0.05))

                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(6)
                } else {
                    Image(systemName: placeholderIcon)
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(height: 64)
            .frame(maxWidth: .infinity)
            .clipped()

            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if let trailing { trailing }
            }
            .padding(.horizontal, 8)
            .padding(.top, 5)

            HStack(spacing: 4) {
                Text(badge)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
        .background(tileBackground(selected: selected, hovering: hovering))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10),
                              lineWidth: selected ? 1.5 : 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func tileBackground(selected: Bool, hovering: Bool) -> Color {
        if selected { return Color.accentColor.opacity(0.10) }
        return hovering ? Color.primary.opacity(0.07) : Color.primary.opacity(0.03)
    }

    private func setHover(_ key: String, _ inside: Bool) {
        if inside {
            panel.hoveredTile = key
        } else if panel.hoveredTile == key {
            panel.hoveredTile = nil
        }
    }

    // MARK: - 位置与大小

    private var placementCard: some View {
        card("位置与大小", systemImage: "move.3d",
             trailing: isPlacementDefault ? nil : AnyView(
                Button {
                    resetPlacement()
                } label: {
                    Text("全部复位").font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
             )) {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("自动跟随人脸", isOn: $engine.trackingEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 8) {
                sliderRow("大小",
                          value: $engine.sizeScale,
                          range: 0.4...6.0,
                          defaultValue: defaultSizeScale) { String(format: "%.2f×", $0) }

                sliderRow("左右",
                          value: $engine.offsetX,
                          range: -2.0...2.0,
                          defaultValue: CoverDefaults.offsetX) { Self.signed($0) }

                sliderRow("上下",
                          value: $engine.offsetY,
                          range: -2.0...2.0,
                          defaultValue: defaultOffsetY) { Self.signed($0) }
            }
        }
    }

    private var isPlacementDefault: Bool {
        abs(engine.sizeScale - defaultSizeScale) < 0.0001
            && abs(engine.offsetX - CoverDefaults.offsetX) < 0.0001
            && abs(engine.offsetY - defaultOffsetY) < 0.0001
    }

    private func resetPlacement() {
        engine.sizeScale = defaultSizeScale
        engine.offsetX = CoverDefaults.offsetX
        engine.offsetY = defaultOffsetY
    }

    /// `+0.20` / `0.00`，避免出现「-0.00」这种看着像坏了的写法。
    private static func signed(_ value: Double) -> String {
        if abs(value) < 0.005 { return "0.00" }
        return String(format: "%+.2f", value)
    }

    // MARK: - 画面

    private var viewCard: some View {
        card("画面", systemImage: "rectangle.on.rectangle") {
            toggleRow("画面镜像", isOn: $engine.mirror)

            toggleRow("显示人脸检测框",
                      subtitle: "在预览上画出检测到的人脸位置，只画在预览里，不会进视频。",
                      isOn: $engine.showDebugBox)
        }
    }

    private func toggleRow(_ title: String,
                           subtitle: String? = nil,
                           isOn: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
            if let subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 录制质量

    /// 分辨率 / 帧率 / 画质。三项都存进 UserDefaults，重启后还是上次选的；
    /// 录制中锁定 —— 摄像头预设和帧率中途改不了，强行改会让画面跳一下。
    private var qualityCard: some View {
        card("录制质量", systemImage: "slider.horizontal.3") {
            Picker("分辨率", selection: $engine.recordingResolution) {
                ForEach(RecordingResolution.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .disabled(engine.isRecording)

            Picker("帧率", selection: $engine.recordingFrameRate) {
                ForEach(RecordingFrameRate.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .disabled(engine.isRecording)

            Picker("画质", selection: $engine.recordingQuality) {
                ForEach(RecordingQuality.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .disabled(engine.isRecording)

            Text("约 \(estimatedStorageText) MB/分钟（估算）· 设置会记住，录制中不可修改")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var estimatedStorageText: String {
        let size = engine.recordingResolution.nominalOutputSize
        let bitsPerSecond = engine.recordingQuality.averageBitRate(
            width: size.width,
            height: size.height,
            frameRate: engine.recordingFrameRate.rawValue
        )
        // 视频码率折算到每分钟 MB，音频额外占用约 1 MB/分钟。
        let megabytes = Double(bitsPerSecond) * 60 / 8 / 1_000_000 + 1
        return String(format: "%.0f", megabytes)
    }

    // MARK: - 声音

    private var audioCard: some View {
        card("声音", systemImage: "waveform") {
            Picker("录制时录什么声音", selection: $engine.audioSource) {
                ForEach(AudioSource.allCases) { source in
                    Label(source.label, systemImage: Self.audioIcon(source)).tag(source)
                }
            }
            .pickerStyle(.menu)

            if engine.audioSource.needsMicrophone && !engine.micAvailable {
                warningRow("麦克风没有授权，录不到声音。到「系统设置 → 隐私与安全性 → 麦克风」里打开。")
            }

            if engine.audioSource.needsSystemAudio {
                warningRow("录系统声音需要「屏幕录制」权限 —— macOS 只给了这一个入口。授权后要重启 App 才生效。",
                           actionLabel: "打开屏幕录制权限设置") {
                    engine.openScreenRecordingSettings()
                }
            }
        }
    }

    private static func audioIcon(_ source: AudioSource) -> String {
        switch source {
        case .none: return "speaker.slash"
        case .microphone: return "mic"
        case .system: return "speaker.wave.2"
        case .both: return "waveform"
        }
    }

    // MARK: - 摄像头

    private var cameraCard: some View {
        card("摄像头", systemImage: "video") {
            if engine.cameras.isEmpty {
                Text("还没有检测到摄像头。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $engine.selectedCameraID) {
                    ForEach(engine.cameras, id: \.uniqueID) { device in
                        Text(device.localizedName).tag(device.uniqueID)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - 文件

    private var fileCard: some View {
        card("文件", systemImage: "folder") {
            HStack(spacing: 8) {
                Button {
                    openWindow(id: "library")
                } label: {
                    Label("录像库", systemImage: "film.stack")
                        .frame(maxWidth: .infinity)
                }

                Button {
                    engine.openOutputFolder()
                } label: {
                    Label("打开文件夹", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: - 录制栏（固定）

    private var recordBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                engine.toggleRecording()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: engine.isRecording ? "stop.circle.fill" : "record.circle")
                        .font(.system(size: 14))
                    Text(engine.isRecording ? "停止录制" : "开始录制").bold()
                    Spacer(minLength: 6)
                    Text("⌘↩")
                        .font(.caption.monospacedDigit())
                        .opacity(0.65)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(engine.isRecording ? .red : .accentColor)
            .keyboardShortcut(.return, modifiers: [.command])

            HStack(alignment: .top, spacing: 6) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 6, height: 6)
                    .padding(.top, 5)
                Text(engine.statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(.regularMaterial)
    }

    private var statusTint: Color {
        if engine.isRecording { return .red }
        if engine.statusMessage.hasPrefix("❌") { return .orange }
        if engine.statusMessage.hasPrefix("✅") { return .green }
        return .secondary
    }

    // MARK: - 小组件

    private func card<Content: View>(_ title: String,
                                     systemImage: String,
                                     trailing: AnyView? = nil,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer(minLength: 4)
                if let trailing { trailing }
            }
            .foregroundStyle(.secondary)

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }

    private func sliderRow(_ title: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           defaultValue: Double,
                           format: @escaping (Double) -> String) -> some View {
        let atDefault = abs(value.wrappedValue - defaultValue) < 0.0001

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Text(title).font(.caption)
                Spacer(minLength: 4)
                Text(format(value.wrappedValue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(atDefault ? Color.secondary.opacity(0.55) : Color.secondary)
                    .frame(minWidth: 52, alignment: .trailing)
                Button {
                    value.wrappedValue = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(atDefault ? Color.secondary.opacity(0.35) : Color.accentColor)
                .disabled(atDefault)
                .help("恢复默认")
            }

            Slider(value: value, in: range)
                .controlSize(.small)
        }
    }

    private func warningRow(_ text: String,
                            actionLabel: String? = nil,
                            action: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionLabel, let action {
                    Button(actionLabel, action: action)
                        .buttonStyle(.link)
                        .font(.caption2)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.orange.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    // MARK: - 动作

    /// 弹框里点「查看」：打开录像库，滚动到刚录完的那一段并高亮。
    ///
    /// 顺序有讲究：先刷新（确保新文件已经在列表里），再设高亮，最后开窗口。
    /// 窗口已经开着也没关系 —— `highlightURL` 一变，列表会通过 `onChange` 再滚一次。
    private func openRecording(_ url: URL) {
        library.refresh()
        library.highlight(url)
        openWindow(id: "library")
    }

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
