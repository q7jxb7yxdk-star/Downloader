import SwiftUI

/// 右側下載列表。
///
/// 使用 macOS 原生 `Table`，所以可以有多欄、選取列、欄寬等桌面 App 常見行為。
struct DownloadsListView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
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
        // Table 的 selection 綁定到 DownloadManager，toolbar 才知道目前操作哪些項目。
        // 綁定 Set<ID> 後，macOS 可用 Command-click / Shift-click 多選。
        Table(items, selection: $downloadManager.selectedItemIDs) {
            TableColumn("Name") { item in
                HStack(spacing: 10) {
                    Image(systemName: item.kind.icon)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .lineLimit(1)
                        Text(item.source.absoluteString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .rowInteraction(for: item, downloadManager: downloadManager)
            }
            .width(min: 260, ideal: 420)

            TableColumn("Progress") { item in
                // ProgressView 直接吃 0...1 的 Double。
                ProgressView(value: item.progress)
                    .frame(minWidth: 120)
                    .rowInteraction(for: item, downloadManager: downloadManager)
            }
            .width(min: 130, ideal: 170)

            TableColumn("Status") { item in
                Text(item.statusText)
                    .foregroundStyle(item.status.color)
                    .lineLimit(1)
                    .rowInteraction(for: item, downloadManager: downloadManager)
            }
            .width(min: 120, ideal: 220)

            TableColumn("Speed") { item in
                // monospacedDigit 讓速度數字跳動時欄位比較穩定。
                Text(item.speedText)
                    .monospacedDigit()
                    .rowInteraction(for: item, downloadManager: downloadManager)
            }
            .width(90)
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
        .navigationTitle(filter.rawValue)
    }
}

private extension View {
    /// 讓 Table 的每一欄都擁有同一組 row 操作。
    ///
    /// SwiftUI `Table` 目前沒有直接掛在整條 row 的 context menu API，
    /// 所以把相同行為套到每個 cell，使用時就像整條 row 都可以右鍵。
    func rowInteraction(for item: DownloadItem, downloadManager: DownloadManager) -> some View {
        self
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 1).onEnded {
                    if !downloadManager.selectedItemIDs.contains(item.id) {
                        downloadManager.selectedItemIDs = [item.id]
                    }
                }
            )
            .onTapGesture(count: 2) {
                downloadManager.showInFinder(item)
            }
            .contextMenu {
                if !item.isTrashed {
                    Button {
                        downloadManager.selectedItemIDs = [item.id]
                        downloadManager.resumeSelected()
                    } label: {
                        Label("Resume", systemImage: "play.fill")
                    }
                    .disabled(item.status == .downloading || item.status == .completed)

                    Button {
                        downloadManager.selectedItemIDs = [item.id]
                        downloadManager.pauseSelected()
                    } label: {
                        Label("Pause", systemImage: "pause.fill")
                    }
                    .disabled(item.status != .downloading && item.status != .queued)

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
                    downloadManager.selectedItemIDs = [item.id]
                    downloadManager.deleteSelected()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
    }
}
