import SwiftUI

enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"
    case completed = "Completed"
    case torrent = "Torrent"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .torrent: "dot.radiowaves.left.and.right"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: DownloadFilter

    var body: some View {
        List(DownloadFilter.allCases, selection: $selection) { filter in
            Label(filter.rawValue, systemImage: filter.icon)
                .tag(filter)
        }
        .navigationTitle("Downloads")
    }
}
