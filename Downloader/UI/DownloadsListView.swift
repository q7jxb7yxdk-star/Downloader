import AppKit
import SwiftUI

/// 右側下載列表。
///
/// 使用 macOS 原生 `Table`，所以可以有多欄、選取列、欄寬等桌面 App 常見行為。
struct DownloadsListView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    @FocusState private var tableIsFocused: Bool
    let filter: DownloadFilter

    /// 根據 sidebar 選項篩選任務。
    private var items: [DownloadItem] {
        downloadManager.items.filter { item in
            switch filter {
            case .all: !item.isTrashed
            case .active: !item.isTrashed && item.status == .downloading
            case .paused: !item.isTrashed && item.status == .paused
            case .completed: !item.isTrashed && item.status == .completed
            case .trash: item.isTrashed
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                // Table 的 selection 綁定到 DownloadManager，toolbar 才知道目前操作哪些項目。
                // 綁定 Set<ID> 後，macOS 可用 Command-click / Shift-click 多選。
                Table(items, selection: $downloadManager.selectedItemIDs) {
                    TableColumn("Name") { item in
                        HStack(spacing: 10) {
                            Image(systemName: item.kind.icon)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                if item.kind == .torrent, !item.torrentFileDetails.isEmpty {
                                    TorrentFileProgressView(files: item.torrentFileDetails)
                                } else if item.kind != .torrent {
                                    AdaptiveTooltipText(item.name)
                                } else if !item.selectedTorrentFilePaths.isEmpty {
                                    ForEach(Array(item.selectedTorrentFilePaths.enumerated()), id: \.offset) { _, path in
                                        AdaptiveTooltipText(
                                            path,
                                            tooltipWidth: 1240,
                                            tooltipLineLimit: 2
                                        )
                                    }
                                } else {
                                    Text("No files selected")
                                        .foregroundStyle(.secondary)
                                }
                                if (item.kind != .torrent || item.torrentFileDetails.isEmpty)
                                    && !(item.kind == .http
                                         && item.status != .completed
                                         && !item.httpConnectionDetails.isEmpty) {
                                    ProgressSummaryView(item: item)
                                }
                                if item.kind == .http,
                                   item.status != .completed,
                                   !item.httpConnectionDetails.isEmpty {
                                    HTTPConnectionProgressView(connections: item.httpConnectionDetails)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .rowInteraction(for: item, visibleIDs: items.map(\.id), downloadManager: downloadManager, focusTable: focusTable)
                    }
                    .width(min: 520, ideal: 720)

                    TableColumn("Speed") { item in
                        HTTPDownloadSpeedView(item: item)
                            .rowInteraction(for: item, visibleIDs: items.map(\.id), downloadManager: downloadManager, focusTable: focusTable)
                    }
                    .width(min: 53, ideal: 99)

                    TableColumn("ETA") { item in
                        Text(item.downloadTimeText)
                            .monospacedDigit()
                            .lineLimit(1)
                            .help(item.downloadTimeText)
                            .rowInteraction(for: item, visibleIDs: items.map(\.id), downloadManager: downloadManager, focusTable: focusTable)
                    }
                    .width(min: 25, ideal: 30)

                    TableColumn("Status") { item in
                        Text(item.statusText)
                            .foregroundStyle(item.status.color)
                            .lineLimit(1)
                            .help(item.statusText)
                            .rowInteraction(for: item, visibleIDs: items.map(\.id), downloadManager: downloadManager, focusTable: focusTable)
                    }
                    .width(min: 150, ideal: 260)
                }
                .frame(width: max(geometry.size.width, minimumTableWidth))
                .focusable()
                .focused($tableIsFocused)
                .focusEffectDisabled()
            }
        }
        .overlay {
            if items.isEmpty {
                // macOS 內建空狀態元件，比手寫 placeholder 更像系統 App。
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Add a URL, torrent file, or magnet link to begin.")
                )
            }
        }
        .onAppear(perform: keepSelectionVisible)
        .onChange(of: filter) { _, _ in
            keepSelectionVisible()
        }
        .onChange(of: items.map(\.id)) { _, _ in
            keepSelectionVisible()
        }
        .navigationTitle(filter.rawValue)
    }

    /// 切換 All / Trash 等分頁後，清走目前分頁看不到的選取項目。
    ///
    /// 如果保留了其他分頁的 selection，macOS `Table` 容易看似「灰色選取」，
    /// toolbar 也可能對著畫面上看不到的任務操作。
    private func keepSelectionVisible() {
        let visibleIDs = Set(items.map(\.id))
        downloadManager.selectedItemIDs.formIntersection(visibleIDs)
    }

    /// Table 欄位加總後需要的最小寬度。
    ///
    /// 視窗少於這個寬度時使用水平 scrollbar；大於這個寬度時只填滿視窗，
    /// 不額外製造右側空白。
    private var minimumTableWidth: CGFloat { 1100 }

    /// 讓列表重新取得鍵盤焦點，selection 才會用藍色顯示。
    private func focusTable() {
        tableIsFocused = true
    }
}

private struct HTTPConnectionProgressView: View {
    let connections: [HTTPConnectionDetail]

    var body: some View {
        VStack(alignment: .leading, spacing: HTTPDetailLayout.rowSpacing) {
            ForEach(connections) { connection in
                HStack(spacing: 6) {
                    Text(connection.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)

                    ProgressView(value: connection.progress)
                        .frame(maxWidth: .infinity)

                    Text("\(Int((connection.progress * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 35, alignment: .trailing)

                    Text(connection.fileSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 132, alignment: .trailing)
                }
                .frame(height: HTTPDetailLayout.rowHeight)
            }
        }
    }
}

private struct HTTPDownloadSpeedView: View {
    let item: DownloadItem

    var body: some View {
        Group {
            if item.kind == .http,
               item.status != .completed,
               !item.httpConnectionDetails.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Color.clear
                        .frame(height: HTTPDetailLayout.nameRowHeight)

                    VStack(alignment: .leading, spacing: HTTPDetailLayout.rowSpacing) {
                        ForEach(item.httpConnectionDetails) { connection in
                            Text(connection.speedText)
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.caption)
                                .frame(height: HTTPDetailLayout.rowHeight)
                        }
                    }
                }
            } else if item.kind == .torrent,
                      item.status != .completed,
                      !item.torrentFileDetails.isEmpty {
                VStack(alignment: .leading, spacing: HTTPDetailLayout.torrentFileSpacing) {
                    ForEach(item.torrentFileDetails) { file in
                        VStack(alignment: .leading, spacing: HTTPDetailLayout.torrentLineSpacing) {
                            Color.clear
                                .frame(height: HTTPDetailLayout.torrentFileNameHeight)

                            Text(file.speedText)
                                .monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.caption)
                                .frame(height: HTTPDetailLayout.torrentProgressHeight)
                        }
                    }
                }
            } else {
                Text(item.speedText)
                    .monospacedDigit()
                    .lineLimit(item.kind == .torrent && item.status == .completed && item.isTorrentSeeding && item.uploadBytesPerSecond > 0 ? 3 : (item.kind == .torrent && (item.status == .downloading || item.status == .completed) ? 2 : 1))
                    .frame(minHeight: item.kind == .torrent && item.status == .completed && item.isTorrentSeeding && item.uploadBytesPerSecond > 0 ? 48 : 0, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum HTTPDetailLayout {
    static let nameRowHeight: CGFloat = 17
    static let rowHeight: CGFloat = 16
    static let torrentSummaryHeight: CGFloat = 32
    static let rowSpacing: CGFloat = 3
    static let torrentFileNameHeight: CGFloat = 32
    static let torrentProgressHeight: CGFloat = 16
    static let torrentLineSpacing: CGFloat = 2
    static let torrentFileSpacing: CGFloat = 5
}

private struct TorrentFileProgressView: View {
    let files: [TorrentFileDetail]

    var body: some View {
        VStack(alignment: .leading, spacing: HTTPDetailLayout.torrentFileSpacing) {
            ForEach(files) { file in
                VStack(alignment: .leading, spacing: HTTPDetailLayout.torrentLineSpacing) {
                    AdaptiveTooltipText(
                        file.path,
                        tooltipWidth: 1240,
                        tooltipLineLimit: 2
                    )
                    .frame(height: HTTPDetailLayout.torrentFileNameHeight, alignment: .leading)

                    HStack(spacing: 6) {
                        ProgressView(value: file.progress)
                            .frame(maxWidth: .infinity)

                        Text("\(Int((file.progress * 100).rounded()))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(width: 35, alignment: .trailing)

                        Text(file.fileSizeText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .frame(width: 132, alignment: .trailing)
                    }
                    .frame(height: HTTPDetailLayout.torrentProgressHeight)
                }
            }
        }
    }
}

/// 檔名下方的輕量進度摘要。
private struct ProgressSummaryView: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 6) {
            ProgressView(value: item.progress)
                .frame(maxWidth: .infinity)

            Text(item.percentText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 35, alignment: .trailing)

            Text(item.fileSizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .help(item.fileSizeText)
        }
        .frame(
            height: item.kind == .torrent && !item.torrentFileDetails.isEmpty
                ? HTTPDetailLayout.torrentSummaryHeight
                : HTTPDetailLayout.rowHeight
        )
    }
}

/// 一行截斷文字，滑鼠停留後以可調整大小的 popover 顯示完整內容。
struct AdaptiveTooltipText: View {
    let text: String
    let font: Font
    let color: Color
    let tooltipWidth: CGFloat?
    let tooltipLineLimit: Int?

    @State private var isPointerInside = false
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?

    init(
        _ text: String,
        font: Font = .body,
        color: Color = .primary,
        tooltipWidth: CGFloat? = nil,
        tooltipLineLimit: Int? = nil
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.tooltipWidth = tooltipWidth
        self.tooltipLineLimit = tooltipLineLimit
    }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .lineLimit(1)
            .onHover { hovering in
                isPointerInside = hovering
                hoverTask?.cancel()

                if hovering {
                    hoverTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled, isPointerInside else { return }
                        isHovering = true
                    }
                } else {
                    isHovering = false
                }
            }
            .popover(isPresented: $isHovering, arrowEdge: .top) {
                Text(text)
                    .font(font)
                    .foregroundStyle(.primary)
                    .lineLimit(tooltipLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        minWidth: tooltipWidth,
                        maxWidth: tooltipWidth ?? 1024,
                        alignment: .leading
                    )
                    .padding(10)
            }
            .onDisappear {
                hoverTask?.cancel()
            }
    }
}

private extension DownloadItem {
    /// 將 0...1 的 progress 轉成列表用百分比文字。
    var percentText: String {
        let percentage = min(max(progress, 0), 1) * 100
        return "\(Int(percentage.rounded()))%"
    }
}

private extension HTTPConnectionDetail {
    var fileSizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .binary)
        guard bytesExpected > 0 else { return received + " / -" }
        let expected = ByteCountFormatter.string(fromByteCount: bytesExpected, countStyle: .binary)
        return received + " / " + expected
    }

    var speedText: String {
        ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary) + "/s"
    }
}

private extension TorrentFileDetail {
    var fileSizeText: String {
        let received = ByteCountFormatter.string(fromByteCount: bytesReceived, countStyle: .binary)
        let expected = ByteCountFormatter.string(fromByteCount: bytesExpected, countStyle: .binary)
        return received + " / " + expected
    }

    var speedText: String {
        ByteCountFormatter.string(fromByteCount: bytesPerSecond, countStyle: .binary) + "/s"
    }

}

private extension View {
    /// 讓 Table 的每一欄都擁有同一組 row 操作。
    ///
    /// SwiftUI `Table` 目前沒有直接掛在整條 row 的 context menu API，
    /// 所以把相同行為套到每個 cell，使用時就像整條 row 都可以右鍵。
    ///
    /// 這裡用自訂單擊 selection，是因為 cell 同時有右鍵、雙擊、tooltip 等互動，
    /// 原生 Table selection 在這種組合下可能收不到 click。
    /// 真正的 Command-click / Shift-click 規則集中在 DownloadManager。
    func rowInteraction(
        for item: DownloadItem,
        visibleIDs: [DownloadItem.ID],
        downloadManager: DownloadManager,
        focusTable: @escaping () -> Void
    ) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: 0).onEnded { _ in
                    focusTable()

                    if NSApp.currentEvent?.clickCount ?? 1 >= 2 {
                        downloadManager.showInFinder(item)
                        return
                    }

                    downloadManager.selectForRowClick(item, visibleIDs: visibleIDs)
                }
            )
            .contextMenu {
                if !item.isTrashed {
                    Button {
                        // 右鍵時先整理 selection，確保多選狀態下會操作整批項目。
                        downloadManager.selectForContextMenu(item)
                        downloadManager.resumeSelected()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .disabled(
                        item.status == .downloading
                            || (item.status == .completed && (item.kind != .torrent || item.isTorrentSeeding))
                    )

                    Button {
                        // 如果右鍵點中的項目已經在 selection 裡，這行會保留原本多選。
                        downloadManager.selectForContextMenu(item)
                        downloadManager.pauseSelected()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .disabled(
                        item.status != .downloading
                            && item.status != .queued
                            && !(item.kind == .torrent && item.status == .completed && item.isTorrentSeeding)
                    )

                    if item.kind == .torrent {
                        Button {
                            downloadManager.reselectTorrentFiles(item)
                        } label: {
                            Label("Select Files…", systemImage: "checklist")
                        }
                    }

                    Divider()
                }

                Button {
                    downloadManager.showInFinder(item)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .disabled(item.destination == nil && item.localFileURL == nil)

                Divider()

                Button(role: .destructive) {
                    // All/Active/Paused/Completed 分頁是移到 Trash；
                    // Trash 分頁內再次 Delete 會同時把本機檔案移到 macOS Trash。
                    downloadManager.selectForContextMenu(item)
                    downloadManager.deleteSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }

                Button(role: .destructive) {
                    // 直接移除列表項目，並把已下載/未完成的檔案移到 macOS Trash。
                    downloadManager.selectForContextMenu(item)
                    downloadManager.deleteSelectedWithFiles()
                } label: {
                    Label("Delete with Files", systemImage: "trash.slash")
                }
            }
    }
}
