import SwiftUI
import AppKit
import Combine

/// 预览视图：直接把 CGImage 塞进 CALayer.contents，不走 SwiftUI 的 diff，30fps 也没有额外开销。
/// 拖拽放下图片也在这里处理（纯 AppKit），这样界面层不需要 @State。
struct PreviewView: NSViewRepresentable {
    let sink: PreviewSink
    let onDropImage: (URL) -> Void

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView(sink: sink)
        view.onDropImage = onDropImage
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        nsView.attach(sink: sink)
        nsView.onDropImage = onDropImage
    }
}

final class PreviewNSView: NSView {
    var onDropImage: ((URL) -> Void)?

    private var cancellable: AnyCancellable?
    private weak var currentSink: PreviewSink?
    private let highlightLayer = CALayer()

    init(sink: PreviewSink) {
        super.init(frame: .zero)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
        layer?.minificationFilter = .linear
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        layer?.masksToBounds = true

        highlightLayer.borderColor = NSColor.controlAccentColor.cgColor
        highlightLayer.borderWidth = 3
        highlightLayer.cornerRadius = 6
        highlightLayer.isHidden = true
        layer?.addSublayer(highlightLayer)

        registerForDraggedTypes([.fileURL])
        attach(sink: sink)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: 预览帧

    func attach(sink: PreviewSink) {
        guard currentSink !== sink else { return }
        currentSink = sink
        cancellable = sink.$image.sink { [weak self] image in
            self?.layer?.contents = image
        }
    }

    override func layout() {
        super.layout()
        withoutAnimation { highlightLayer.frame = bounds }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2.0
    }

    // MARK: 拖拽放入图片

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard imageURL(from: sender) != nil else { return [] }
        withoutAnimation { highlightLayer.isHidden = false }
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        withoutAnimation { highlightLayer.isHidden = true }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        withoutAnimation { highlightLayer.isHidden = true }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        withoutAnimation { highlightLayer.isHidden = true }
        guard let url = imageURL(from: sender) else { return false }
        onDropImage?(url)
        return true
    }

    private func imageURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self], options: options
        ) as? [URL]
        return urls?.first
    }

    private func withoutAnimation(_ block: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        block()
        CATransaction.commit()
    }
}
