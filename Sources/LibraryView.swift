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
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(library.entries) { entry in
                        RecordingRow(
                            entry: entry,
                            onPlay: { library.play(entry) },
                            onReveal: { library.reveal(entry) },
                            onCopyPath: { library.copyPath(entry) },
                            onDelete: { library.confirmAndTrash(entry) }
                        )
                        Divider().padding(.leading, 14)
                    }
                }
            }
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
        .contextMenu {
            Button("播放", action: onPlay)
            Button("在访达中显示", action: onReveal)
            Button("复制文件路径", action: onCopyPath)
            Divider()
            Button("删除（移到废纸篓）", role: .destructive, action: onDelete)
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
