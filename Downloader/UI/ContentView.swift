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

    /// Safari extension 用 distributed notification 把下載連結送回 App。
    @State private var safariDownloadObserver: NSObjectProtocol?

    /// 定期讀取 Safari extension 寫入 App Group 的待加入下載。
    @State private var safariQueueTimer: Timer?

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
                            .disabled(!downloadManager.canResumeSelected)

                            Button {
                                downloadManager.pauseSelected()
                            } label: {
                                Label("Pause", systemImage: "pause.fill")
                            }
                            .help("Pause")
                            .disabled(!downloadManager.canPauseSelected)
                        }

                        Button(role: .destructive) {
                            downloadManager.deleteSelected()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Delete")
                        .disabled(downloadManager.selectedItemIDs.isEmpty)
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
            handleExternalURL(incomingURL)
        }
        .onAppear {
            flushPendingSafariDownloads()

            if safariQueueTimer == nil {
                safariQueueTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    Task { @MainActor in
                        flushPendingSafariDownloads()
                    }
                }
            }

            ExternalDownloadRouter.shared.installHandler { incomingURL in
                handleExternalURL(incomingURL)
            }

            guard safariDownloadObserver == nil else { return }
            safariDownloadObserver = DistributedNotificationCenter.default().addObserver(
                forName: .safariExtensionAddDownload,
                object: nil,
                queue: .main
            ) { notification in
                Task { @MainActor in
                    _ = flushPendingSafariDownloads()
                    bringDownloaderToFront()
                }
            }
        }
        .onDisappear {
            downloadManager.flushScheduledSave()

            safariQueueTimer?.invalidate()
            safariQueueTimer = nil

            ExternalDownloadRouter.shared.removeHandler()

            if let safariDownloadObserver {
                DistributedNotificationCenter.default().removeObserver(safariDownloadObserver)
                self.safariDownloadObserver = nil
            }
        }
    }

    /// 處理 Safari / URL scheme 傳入的外部 URL。
    private func handleExternalURL(_ incomingURL: URL) {
        if incomingURL.isFileURL, incomingURL.pathExtension.lowercased() == "torrent" {
            let destination = FolderBookmarkStore.lastFolder()
            addExternalDownloads([
                (url: incomingURL, kind: nil, name: nil)
            ], destination: destination)
            return
        }

        guard incomingURL.scheme == URLSchemeHandler.scheme else { return }

        // `downloader://authorize` 只用來讓 Safari 完成「允許開啟 Downloader」授權。
        // 收到後把 app 聚焦即可，不建立下載項目。
        if incomingURL.host() == "authorize" {
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let downloadURL = URLSchemeHandler.downloadURL(from: incomingURL) else { return }
        let destination = FolderBookmarkStore.lastFolder()
        addExternalDownloads([
            (url: downloadURL, kind: nil, name: nil)
        ], destination: destination)
    }

    /// 讀取 Safari native extension 寫入 App Group 的下載 queue。
    @discardableResult
    private func flushPendingSafariDownloads() -> Bool {
        struct PendingSafariDownload: Codable {
            let url: String
            let kind: String?
            let name: String?
        }

        let appGroupIdentifier = "group.com.sunnyyu.Downloader"
        let queueFileName = "pending-safari-downloads.json"

        guard let queueURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)?
            .appendingPathComponent(queueFileName),
              let data = try? Data(contentsOf: queueURL)
        else {
            return false
        }

        let downloads: [PendingSafariDownload]
        if let queuedDownloads = try? JSONDecoder().decode([PendingSafariDownload].self, from: data) {
            downloads = queuedDownloads
        } else if let legacyLinks = try? JSONDecoder().decode([String].self, from: data) {
            downloads = legacyLinks.map { PendingSafariDownload(url: $0, kind: nil, name: nil) }
        } else {
            return false
        }

        guard !downloads.isEmpty else { return false }

        if let emptyQueue = try? JSONEncoder().encode([PendingSafariDownload]()) {
            try? emptyQueue.write(to: queueURL, options: .atomic)
        }

        let pendingDownloads = downloads.compactMap { download -> ExternalDownload? in
            guard let url = URL(string: download.url) else { return nil }
            return ExternalDownload(
                url: url,
                kind: download.kind.flatMap(DownloadKind.init(rawValue:)),
                name: download.name
            )
        }
        guard !pendingDownloads.isEmpty else { return false }

        addExternalDownloads(
            pendingDownloads.map { (url: $0.url, kind: $0.kind, name: $0.name) },
            destination: FolderBookmarkStore.lastFolder()
        )
        return true
    }

    /// 外部下載先切到 All，待 Table 完成 filter 更新後才新增並選取項目。
    private func addExternalDownloads(
        _ downloads: [(url: URL, kind: DownloadKind?, name: String?)],
        destination: URL?
    ) {
        selection = .all

        Task { @MainActor in
            await Task.yield()

            for download in downloads {
                downloadManager.add(
                    url: download.url,
                    destination: destination,
                    kind: download.kind,
                    name: download.name
                )
            }

            bringDownloaderToFront()
        }
    }

    /// 把 Downloader 視窗帶到前景，給 Safari native extension 匯入下載後使用。
    private func bringDownloaderToFront() {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async {
            if let window = NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

private struct ExternalDownload {
    let url: URL
    let kind: DownloadKind?
    let name: String?
}

extension Notification.Name {
    /// Safari extension native handler 用這個 distributed notification 發送下載連結。
    static let safariExtensionAddDownload = Notification.Name("com.sunnyyu.Downloader.addDownload")
}
