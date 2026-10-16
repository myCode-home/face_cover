import SwiftUI
import AppKit

/// 录像库窗口：把 `~/Movies/FaceCover/` 里的录像列出来，能播放、定位、复制路径、删除。
///
/// 注意：这台机器只有 Command Line Tools，`SwiftUIMacros` 插件不存在，所以 **`@State` 用不了**。
/// 删除确认因此走 AppKit 的 `NSAlert`（见 `RecordingLibrary.confirmAndTrash`），不使用 `.alert` 修饰符。
struct LibraryView: View {
    @ObservedObject var library: RecordingLibrary

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 660, minHeight: 440)
        .onAppear { library.refresh() }
        // 关掉窗口就把「刚录完」的高亮撤掉 —— 否则下次打开会看到一条没来由的高亮
        .onDisappear { library.clearHighlight() }
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("录像库").font(.headline)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if library.isScanning {
                ProgressView().controlSize(.small)
            }
            Button {
                library.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(library.isScanning)

            Button {
                library.openFolder()
            } label: {
                Label("打开文件夹", systemImage: "folder")
            }
        }
        .padding(14)
    }

    private var summary: String {
        if library.entries.isEmpty { return "还没有录像" }
        return "共 \(library.entries.count) 个 · \(library.totalSizeText)"
    }

    // MARK: 列表

    @ViewBuilder
    private var content: some View {
        if let message = library.errorMessage {
            errorBanner(message)
        }
        if library.entries.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(library.entries) { entry in
                            RecordingRow(
                                entry: entry,
                                highlighted: entry.url == library.highlightURL,
                                settled: library.highlightSettled,
                                onPlay: { library.play(entry) },
                                onReveal: { library.reveal(entry) },
                                onCopyPath: { library.copyPath(entry) },
                                onDelete: { library.confirmAndTrash(entry) }
                            )
                            Divider().padding(.leading, 14)
                        }
                    }
                }
                .onAppear { scrollToHighlight(proxy) }
                // 高亮目标换了，或者列表刚扫描完（元数据在后台队列读，可能还没这一段）—— 两种都要再试一次
                .onChange(of: library.highlightURL) { _, _ in scrollToHighlight(proxy) }
                .onChange(of: library.entries) { _, _ in scrollToHighlight(proxy) }
            }
        }
    }

    private func scrollToHighlight(_ proxy: ScrollViewProxy) {
        guard let url = library.highlightURL else { return }
        withAnimation(.easeOut(duration: 0.35)) {
            proxy.scrollTo(url, anchor: .center)
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).font(.caption)
            Spacer()
            Button("知道了") { library.errorMessage = nil }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(10)
        .background(Color.orange.opacity(0.15))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("还没有录像").font(.callout)
            Text("录完第一段之后，它会出现在这里。\n文件都存在 ~/Movies/FaceCover/")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: 单行

private struct RecordingRow: View {
    let entry: RecordingEntry
    /// 是不是「刚录完、要定位」的那一段
    let highlighted: Bool
    /// 高亮是否已经落定（刚到位时亮一下，随后收成低调底色）
    let settled: Bool
    let onPlay: () -> Void
    let onReveal: () -> Void
    let onCopyPath: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            thumbnail
                .frame(width: 112, height: 63)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
                .contentShape(Rectangle())
                .onTapGesture(perform: onPlay)
                .help("点一下播放")

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.fileName)
                HStack(spacing: 6) {
                    Label(entry.durationText, systemImage: "clock")
                    Text("·")
                    Label(entry.sizeText, systemImage: "internaldrive")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(entry.createdAtText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button(action: onPlay) {
                Label("播放", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)

            Menu {
                Button("在访达中显示", action: onReveal)
                Button("复制文件路径", action: onCopyPath)
                Divider()
                Button("删除（移到废纸篓）", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 30)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(highlightBackground)
        // 用一个数值当驱动：到位时 0 → 0.20，1.4 秒后 0.20 → 0.07，两次都自动过渡。
        // 这台机器没有 SwiftUIMacros，`@State` 用不了，所以不能自己写动画状态。
        .animation(.easeOut(duration: 0.45), value: highlightTint)
        .contextMenu {
            Button("播放", action: onPlay)
            Button("在访达中显示", action: onReveal)
            Button("复制文件路径", action: onCopyPath)
            Divider()
            Button("删除（移到废纸篓）", role: .destructive, action: onDelete)
        }
    }

    /// 0 = 没有高亮。刚到位时亮一点吸引视线，随后收成几乎看不出的底色 —— 用户本来就盯着刚录完的那段，不需要一直强提示。
    private var highlightTint: Double {
        guard highlighted else { return 0 }
        return settled ? 0.07 : 0.20
    }

    @ViewBuilder
    private var highlightBackground: some View {
        HStack(spacing: 0) {
            // 左侧一根细条，配合底色一起用「定位到这一行」更明确
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(highlightTint * 2.2))
                .frame(width: 3)
                .padding(.vertical, 6)
            Color.accentColor.opacity(highlightTint)
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = entry.thumbnail {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                Color.black.opacity(0.22)
                ProgressView().controlSize(.small)
            }
        }
    }
}
