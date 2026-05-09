import SwiftUI

/// Sidebar 的分類。
///
/// `CaseIterable` 讓 Sidebar 可以用 `DownloadFilter.allCases` 自動列出所有分類。
enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"
    case completed = "Completed"
    case trash = "Trash"

    var id: String { rawValue }

    /// 每個分類對應一個 SF Symbol。
    var icon: String {
        switch self {
        case .all: "tray.full"
        case .active: "arrow.down.circle"
        case .paused: "pause.circle"
        case .completed: "checkmark.circle"
        case .trash: "trash"
        }
    }
}

/// 左側分類列表。
struct SidebarView: View {
    /// 用 Binding 讓 ContentView 可以持有實際狀態，Sidebar 只負責改變它。
    @Binding var selection: DownloadFilter

    var body: some View {
        List(DownloadFilter.allCases, selection: $selection) { filter in
            Label(filter.rawValue, systemImage: filter.icon)
                .tag(filter)
        }
        .navigationTitle("Downloads")
    }
}
