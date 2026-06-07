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
                                AdaptiveTooltipText(item.name)
                                ProgressSummaryView(item: item)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .rowInteraction(for: item, visibleIDs: items.map(\.id), downloadManager: downloadManager, focusTable: focusTable)
                    }
                    .width(min: 380, ideal: 560)

                    TableColumn("Speed") { item in
                        // monospacedDigit 讓速度數字跳動時欄位比較穩定。
                        Text(item.speedText)
                            .monospacedDigit()
                            .lineLimit(item.kind == .torrent && item.status == .completed && item.isTorrentSeeding && item.uploadBytesPerSecond > 0 ? 3 : (item.kind == .torrent && (item.status == .downloading || item.status == .completed) ? 2 : 1))
                            .frame(minHeight: item.kind == .torrent && item.status == .completed && item.isTorrentSeeding && item.uploadBytesPerSecond > 0 ? 48 : 0, alignment: .leading)
                            .rowInteraction(for: item, visibleIDs: items.map(\.id), downloadManager: downloadManager, focusTable: focusTable)
                    }
                    .width(min: 30, ideal: 60)

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
    private var minimumTableWidth: CGFloat { 800 }

    /// 讓列表重新取得鍵盤焦點，selection 才會用藍色顯示。
    private func focusTable() {
        tableIsFocused = true
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
    }
}

/// 一行會截斷的文字，但滑鼠移上去時會顯示完整內容。
///
/// SwiftUI 內建 `.help(...)` 由 macOS 系統控制，寬度不能細調。
/// 這個自訂 popover 會按照內容自動調整寬度，並用 maxWidth 避免太長的 URL 撐出螢幕。
private struct AdaptiveTooltipText: View {
    let text: String
    let font: Font
    let color: Color

    @State private var isPointerInside = false
    @State private var isHovering = false
    @State private var hoverTask: Task<Void, Never>?

    init(_ text: String, font: Font = .body, color: Color = .primary) {
        self.text = text
        self.font = font
        self.color = color
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
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 1024, alignment: .leading)
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
