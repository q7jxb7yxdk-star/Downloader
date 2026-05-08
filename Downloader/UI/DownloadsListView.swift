import SwiftUI

struct DownloadsListView: View {
    @EnvironmentObject private var downloadManager: DownloadManager
    let filter: DownloadFilter

    private var items: [DownloadItem] {
        downloadManager.items.filter { item in
            switch filter {
            case .all: true
            case .active: item.status == .downloading
            case .paused: item.status == .paused
            case .completed: item.status == .completed
            case .torrent: item.kind == .torrent
            }
        }
    }

    var body: some View {
        Table(items, selection: $downloadManager.selectedItemID) {
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
            }

            TableColumn("Progress") { item in
                ProgressView(value: item.progress)
                    .frame(minWidth: 120)
            }
            .width(min: 130, ideal: 170)

            TableColumn("Status") { item in
                Text(item.statusText)
                    .foregroundStyle(item.status.color)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 220)

            TableColumn("Speed") { item in
                Text(item.speedText)
                    .monospacedDigit()
            }
            .width(90)
        }
        .overlay {
            if items.isEmpty {
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
