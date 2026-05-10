import SwiftUI

/// App 主畫面。
///
/// 左邊是分類 sidebar，右邊是下載列表，上方 toolbar 提供新增、開始、暫停和刪除。
struct ContentView: View {
    /// 由 `DownloaderApp` 注入的全域下載狀態。
    @EnvironmentObject private var downloadManager: DownloadManager

    /// 目前 sidebar 選中的分類。
    @State private var selection: DownloadFilter = .all

    /// 控制新增下載 sheet 是否顯示。
    @State private var showingAddDownload = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
        } detail: {
            DownloadsListView(filter: selection)
                .toolbar {
                    ToolbarItemGroup {
                        // `.help` 是 macOS tooltip，滑鼠停在按鈕上會顯示英文名稱。
                        if selection == .trash {
                            Button {
                                downloadManager.restoreSelectedFromTrash()
                            } label: {
                                Label("Restore", systemImage: "arrow.uturn.backward")
                            }
                            .help("Restore")
                        } else {
                            Button {
                                showingAddDownload = true
                            } label: {
                                Label("Add Download", systemImage: "plus")
                            }
                            .help("Add Download")

                            Button {
                                downloadManager.resumeSelected()
                            } label: {
                                Label("Resume", systemImage: "play.fill")
                            }
                            .help("Resume")

                            Button {
                                downloadManager.pauseSelected()
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            .help("Pause")
                        }

                        Button(role: .destructive) {
                            downloadManager.deleteSelected()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Delete")
                    }
                }
        }
        .sheet(isPresented: $showingAddDownload) {
            AddDownloadSheet()
        }
        // `torrentFileSelection` 是 optional Identifiable，非 nil 時 SwiftUI 自動彈 sheet。
        .sheet(item: $downloadManager.torrentFileSelection) { selection in
            TorrentFileSelectionSheet(selection: selection)
        }
        // 接收 App menu 的 Add Download command。
        .onReceive(NotificationCenter.default.publisher(for: .showAddDownload)) { _ in
            showingAddDownload = true
        }
        // 接收 Safari Extension 送來的 `downloader://add?url=...`。
        //
        // Safari 右鍵選單按下 Download with Downloader 時，background.js 會打開這個 URL scheme。
        // 這裡解析出真正下載 URL，並用上次選擇的資料夾直接建立下載任務。
        .onOpenURL { incomingURL in
            guard let downloadURL = URLSchemeHandler.downloadURL(from: incomingURL) else { return }
            let destination = FolderBookmarkStore.lastFolder()
            downloadManager.add(url: downloadURL, destination: destination)
        }
    }
}
