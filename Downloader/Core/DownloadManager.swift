import AppKit
import Foundation

/// App 的中央狀態管理器。
///
/// SwiftUI 畫面只跟 `DownloadManager` 溝通；它再把真正下載工作分派給
/// `HTTPDownloadEngine` 或 `TorrentDownloadEngine`。這樣 UI 不需要知道
/// HTTP 分段下載、BT metadata、libtorrent bridge 等細節。
@MainActor
final class DownloadManager: NSObject, ObservableObject {
    struct PersistenceNotice: Identifiable {
        let id = UUID()
        let message: String
    }

    /// One alert per distinct persistence failure/recovery, rather than one per progress tick.
    @Published var persistenceNotice: PersistenceNotice?
    @Published private(set) var persistenceWarning: String?
    private var reportedPersistenceMessages: Set<String> = []

    /// 所有下載項目。`@Published` 會讓 SwiftUI 在資料改變時自動重畫列表。
    @Published var items: [DownloadItem] = []

    /// 目前 Table 選中的任務 id 集合，工具列的開始/暫停/刪除按鈕會使用它。
    ///
    /// `Table` 綁定 `Set<ID>` 時，macOS 就能用 Command-click / Shift-click 多選。
    @Published var selectedItemIDs: Set<DownloadItem.ID> = []

    // Shift-click 範圍選取的起點。普通 click 或 Command-click 都會更新它。
    private var selectionAnchorID: DownloadItem.ID?

    /// BT 找到 metadata 後用來彈出「選擇檔案」sheet。
    @Published var torrentFileSelection: TorrentFileSelection?

    /// 目前選取項目中是否有可以繼續下載的任務。
    var canResumeSelected: Bool {
        selectedItems.contains { item in
            guard !item.isTrashed else { return false }
            if item.kind == .torrent, item.status == .completed {
                return !item.isTorrentSeeding
            }
            return item.status != .downloading && item.status != .completed && item.localFileURL == nil
        }
    }

    /// 目前選取項目中是否有可以暫停的任務。
    var canPauseSelected: Bool {
        selectedItems.contains { item in
            guard !item.isTrashed else { return false }
            return item.status == .downloading
                || item.status == .queued
                || (item.kind == .torrent && item.status == .completed && item.isTorrentSeeding)
        }
    }

    /// 負責把列表保存到 Application Support。
    private let store = DownloadStore()
    private var scheduledSaveTask: Task<Void, Never>?

    /// `lazy` 可以避免在 `self` 尚未初始化完成前就把 delegate 指向 self。
    private lazy var httpEngine = HTTPDownloadEngine(delegate: self)
    private lazy var torrentEngine = TorrentDownloadEngine(delegate: self)

    override init() {
        super.init()
        // App 啟動時先載入上次保存的任務列表。
        let loaded = store.load()
        items = loaded.items
        if let notice = loaded.notice { reportPersistenceIssue(notice) }
        // libtorrent session 不會跨 App process 保存；重開 App 後由使用者按 Resume 重新開始 seeding。
        for index in items.indices where items[index].kind == .torrent && items[index].status == .completed {
            items[index].isTorrentSeeding = false
            items[index].uploadBytesPerSecond = 0
        }
    }

    /// 新增一個下載任務，並立即開始下載。
    func add(
        url: URL,
        destination: URL?,
        kind requestedKind: DownloadKind? = nil,
        name requestedName: String? = nil
    ) {
        _ = insertDownload(id: UUID(), url: url, destination: destination, kind: requestedKind, name: requestedName)
    }

    /// Acknowledge Safari requests only after their stable ID is durably saved.
    /// Retries for existing IDs never restart engines or change the existing item.
    func importSafariDownload(
        id: UUID,
        url: URL,
        destination: URL?,
        kind: DownloadKind?,
        name: String?
    ) -> Bool {
        if items.contains(where: { $0.id == id }) { return persistItems() }
        return insertDownload(id: id, url: url, destination: destination, kind: kind, name: name)
    }

    private func insertDownload(
        id: UUID,
        url: URL,
        destination: URL?,
        kind requestedKind: DownloadKind?,
        name requestedName: String?
    ) -> Bool {
        // 用 URL 形式判斷下載類型：magnet 和 .torrent 交給 BT engine，其他交給 HTTP。
        let kind: DownloadKind = requestedKind
            ?? (url.absoluteString.hasPrefix("magnet:") || url.pathExtension.lowercased() == "torrent" ? .torrent : .http)
        let displayName = requestedName
            .map { URL(fileURLWithPath: $0).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? Self.displayName(for: url)
        var item = DownloadItem(
            name: displayName,
            source: url,
            destination: destination,
            kind: kind
        )
        item.id = id
        if kind == .torrent, !url.isFileURL, !url.absoluteString.hasPrefix("magnet:") {
            item.status = .downloading
            item.errorMessage = "Downloading torrent metadata"
        }
        items.insert(item, at: 0)
        guard persistItems() else {
            items.removeAll { $0.id == id }
            return false
        }
        selectedItemIDs = [item.id]

        if kind == .torrent, !url.isFileURL, !url.absoluteString.hasPrefix("magnet:") {
            downloadRemoteTorrentMetadata(for: item.id, from: url)
            return true
        }

        // DownloadManager 只決定「交給誰」，真正下載細節留給各 engine。
        switch kind {
        case .http:
            httpEngine.start(item: item)
        case .torrent:
            torrentEngine.start(item: item)
        }
        return true
    }

    @discardableResult
    private func persistItems() -> Bool {
        do {
            try store.save(items)
            return true
        } catch {
            reportPersistenceIssue(error.localizedDescription)
            return false
        }
    }

    private func reportPersistenceIssue(_ message: String) {
        persistenceWarning = message
        guard reportedPersistenceMessages.insert(message).inserted else { return }
        persistenceNotice = PersistenceNotice(message: message)
    }

    /// Table row 被點擊時整理 selection。
    ///
    /// 因為 row 上有右鍵、雙擊、tooltip 等互動，SwiftUI `Table` 原生 selection
    /// 有時會被 cell gesture 擋住，所以這裡自己實作 macOS 常見選取行為。
    func selectForRowClick(_ item: DownloadItem, visibleIDs: [DownloadItem.ID]) {
        guard visibleIDs.contains(item.id) else { return }

        let modifiers = NSEvent.modifierFlags
        let isCommandClick = modifiers.contains(.command)
        let isShiftClick = modifiers.contains(.shift)

        if isShiftClick,
           let anchorID = selectionAnchorID,
           let anchorIndex = visibleIDs.firstIndex(of: anchorID),
           let clickedIndex = visibleIDs.firstIndex(of: item.id) {
            let bounds = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            let rangeIDs = Set(visibleIDs[bounds])

            if isCommandClick {
                selectedItemIDs.formUnion(rangeIDs)
            } else {
                selectedItemIDs = rangeIDs
            }
            return
        }

        if isCommandClick {
            if selectedItemIDs.contains(item.id) {
                selectedItemIDs.remove(item.id)
            } else {
                selectedItemIDs.insert(item.id)
            }
            selectionAnchorID = item.id
            return
        }

        selectedItemIDs = [item.id]
        selectionAnchorID = item.id
    }

    /// 右鍵選單打開前整理 selection。
    ///
    /// 如果右鍵點中的項目已經在多選範圍內，就保留原本多選；
    /// 如果不是，才改成只選中這一個項目。
    func selectForContextMenu(_ item: DownloadItem) {
        guard items.contains(where: { $0.id == item.id }) else { return }
        if !selectedItemIDs.contains(item.id) {
            selectedItemIDs = [item.id]
        }
    }

    /// 暫停目前選中的任務。
    func pauseSelected() {
        for item in selectedItems where !item.isTrashed {
            if item.kind == .torrent, item.status == .completed, item.isTorrentSeeding {
                torrentEngine.pause(id: item.id)
                setTorrentSeeding(id: item.id, isSeeding: false)
                continue
            }

            guard item.status == .downloading || item.status == .queued else { continue }
            switch item.kind {
            case .http:
                httpEngine.pause(id: item.id)
            case .torrent:
                torrentEngine.pause(id: item.id)
            }
            mark(id: item.id, status: .paused)
        }
    }

    /// 繼續目前選中的任務。
    func resumeSelected() {
        for item in selectedItems where !item.isTrashed {
            if item.kind == .torrent, item.status == .completed, !item.isTorrentSeeding {
                if torrentEngine.resume(item: item) {
                    setTorrentSeeding(id: item.id, isSeeding: true)
                }
                continue
            }

            guard item.status != .completed && item.status != .downloading && item.localFileURL == nil else { continue }
            mark(id: item.id, status: .queued)

            switch item.kind {
            case .http:
                httpEngine.resume(item: item)
            case .torrent:
                if !item.source.isFileURL,
                   !item.source.absoluteString.hasPrefix("magnet:"),
                   item.source.pathExtension.lowercased() == "torrent" {
                    mark(id: item.id, status: .downloading, errorMessage: "Downloading torrent metadata")
                    downloadRemoteTorrentMetadata(for: item.id, from: item.source)
                } else {
                    torrentEngine.resume(item: item)
                }
            }
        }
    }

    /// 下載遠端 `.torrent` metadata，保存到 Application Support 後再交給 libtorrent。
    private func downloadRemoteTorrentMetadata(for itemID: DownloadItem.ID, from remoteURL: URL) {
        Task {
            do {
                let (data, response) = try await URLSession.shared.data(from: remoteURL)
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    throw NSError(
                        domain: "Downloader.TorrentMetadata",
                        code: httpResponse.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(httpResponse.statusCode)."]
                    )
                }
                guard !data.isEmpty else {
                    throw NSError(
                        domain: "Downloader.TorrentMetadata",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "The torrent metadata file is empty."]
                    )
                }

                let supportDirectory = FileManager.default.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0]
                    .appending(path: "Downloader/TorrentMetadata", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(
                    at: supportDirectory,
                    withIntermediateDirectories: true
                )
                let localURL = supportDirectory.appending(
                    path: "\(itemID.uuidString).torrent",
                    directoryHint: .notDirectory
                )
                try data.write(to: localURL, options: .atomic)

                guard let index = items.firstIndex(where: { $0.id == itemID }),
                      !items[index].isTrashed
                else { return }

                items[index].source = localURL
                items[index].status = .queued
                items[index].errorMessage = nil
                persistItems()
                torrentEngine.start(item: items[index])
            } catch {
                fail(id: itemID, errorMessage: error.localizedDescription)
            }
        }
    }

    /// 從 Trash 還原目前選中的項目。
    ///
    /// 還原只負責回到原本分類，不會自動開始下載。
    func restoreSelectedFromTrash() {
        for item in selectedItems where item.isTrashed {
            restoreFromTrash(item: item)
        }
    }

    /// 刪除目前選中的任務。
    ///
    /// 這裡採用「軟刪除」：停止正在跑的任務，然後移到 Trash 分類。
    /// 使用者之後可以在 Trash 選中項目再按 Resume 復原。
    func deleteSelected() {
        let itemsToDelete = selectedItems
        guard !itemsToDelete.isEmpty else { return }

        if itemsToDelete.allSatisfy(\.isTrashed) {
            guard confirmDeleteWithFiles(count: itemsToDelete.count) else { return }
            Task { @MainActor in
                await deleteItemsWithFiles(itemsToDelete)
            }
            return
        }

        for item in itemsToDelete where !item.isTrashed {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }

            if item.status == .downloading
                || item.status == .queued
                || (item.kind == .torrent && item.status == .completed && item.isTorrentSeeding) {
                switch item.kind {
                case .http:
                    httpEngine.pause(id: item.id)
                case .torrent:
                    torrentEngine.pause(id: item.id)
                }
            }

            items[index].statusBeforeTrash = item.status
            items[index].isTrashed = true
            items[index].bytesPerSecond = 0
            items[index].uploadBytesPerSecond = 0
            items[index].isTorrentSeeding = false
            if item.status == .downloading || item.status == .queued {
                items[index].status = .paused
            }
            items[index].errorMessage = nil
        }

        selectedItemIDs = Set(itemsToDelete.map(\.id))
        persistItems()
    }

    /// 刪除目前選中的任務，並把相關本機檔案移到 macOS Trash。
    ///
    /// 與普通 Delete 不同，這個動作不會先移到 App 內的 Trash 分類；
    /// 成功刪除檔案後會直接從列表移除項目。
    func deleteSelectedWithFiles() {
        let itemsToDelete = selectedItems
        guard !itemsToDelete.isEmpty else { return }
        guard confirmDeleteWithFiles(count: itemsToDelete.count) else { return }

        Task { @MainActor in
            await deleteItemsWithFiles(itemsToDelete)
        }
    }

    private func deleteItemsWithFiles(_ itemsToDelete: [DownloadItem]) async {
        var failedIDs: Set<DownloadItem.ID> = []

        for item in itemsToDelete {
            pauseDownloadPreservingFiles(for: item)

            do {
                try await moveDownloadedFilesToTrash(for: item)
                cancelDownload(for: item)
            } catch {
                failedIDs.insert(item.id)
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].status = .failed
                    items[index].bytesPerSecond = 0
                    items[index].uploadBytesPerSecond = 0
                    items[index].errorMessage = "Unable to delete files: \(error.localizedDescription)"
                }
            }
        }

        let deletedIDs = Set(itemsToDelete.map(\.id)).subtracting(failedIDs)
        items.removeAll { deletedIDs.contains($0.id) }
        selectedItemIDs.subtract(deletedIDs)

        if selectedItemIDs.isEmpty {
            selectedItemIDs = Set(items.prefix(1).map(\.id))
        }

        persistItems()
    }

    /// 使用者在 BT 檔案選擇 sheet 按下開始後呼叫。
    func chooseTorrentFiles(itemID: DownloadItem.ID, indexes: Set<Int>) {
        guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].kind == .torrent else { return }
        let previousIndexes = items[index].selectedTorrentFileIndexes
        let isReselection = torrentFileSelection?.isReselection == true
        let selectedPaths = torrentFileSelection?.itemID == itemID
            ? torrentFileSelection?.files.filter { indexes.contains($0.index) }.map(\.path) ?? []
            : []
        torrentFileSelection = nil
        guard indexes != previousIndexes else { return }
        items[index].selectedTorrentFileIndexes = indexes
        items[index].selectedTorrentFilePaths = selectedPaths
        torrentEngine.selectFiles(for: itemID, indexes: indexes, isReselection: isReselection)
        mark(id: itemID, status: .queued)
    }

    /// 顯示現有 BT metadata，讓使用者重新選擇下載檔案。
    func reselectTorrentFiles(_ item: DownloadItem) {
        guard item.kind == .torrent, !item.isTrashed else { return }
        torrentEngine.requestFileReselection(for: item)
    }

    /// 使用者取消 BT 檔案選擇時，只有全新任務會被移除。
    ///
    /// 如果任務之前已經下載過，重開 App 後意外再出現選檔 sheet 時，
    /// Cancel 只會停止這次 engine，保留列表項目和既有進度。
    func cancelTorrentFileSelection(itemID: DownloadItem.ID, isReselection: Bool = false) {
        if isReselection {
            torrentFileSelection = nil
            return
        }
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        torrentEngine.cancel(id: itemID)
        if items[index].progress > 0 || items[index].bytesReceived > 0 || !items[index].selectedTorrentFileIndexes.isEmpty {
            torrentFileSelection = nil
            items[index].status = .paused
            items[index].bytesPerSecond = 0
            items[index].uploadBytesPerSecond = 0
            items[index].errorMessage = nil
            persistItems()
            return
        }

        items.remove(at: index)
        selectedItemIDs = Set(items.prefix(1).map(\.id))
        torrentFileSelection = nil
        persistItems()
    }

    /// Engine 回報進度時呼叫。所有 UI 進度更新都集中在這裡。
    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64, uploadSpeed: Int64 = 0) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed else { return }
        guard items[index].status != .paused else { return }
        items[index].progress = progress
        items[index].bytesReceived = received
        items[index].bytesExpected = expected
        items[index].bytesPerSecond = speed
        items[index].uploadBytesPerSecond = uploadSpeed
        items[index].status = .downloading
        scheduleSave()
    }

    /// HTTP engine 回報單線或各分段連線的即時資料。
    func updateHTTPConnections(id: DownloadItem.ID, connections: [HTTPConnectionDetail]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed, items[index].kind == .http else { return }
        items[index].httpConnectionDetails = connections
    }

    /// BT engine 回報已選檔案的即時進度與速度。
    func updateTorrentFiles(id: DownloadItem.ID, files: [TorrentFileDetail]) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed, items[index].kind == .torrent else { return }
        items[index].torrentFileDetails = files
    }

    /// Engine 回報補充狀態文字，例如「Checking range support」或 peer 數量。
    func updateStatusText(id: DownloadItem.ID, message: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed else { return }
        guard items[index].status != .paused else { return }
        items[index].status = .downloading
        items[index].errorMessage = message
        scheduleSave()
    }

    /// App 即將關閉、隱藏或進入背景時，立刻寫入等待中的進度。
    ///
    /// `scheduleSave()` 會延遲保存以減少磁碟寫入；這個方法則補上生命週期邊界，
    /// 避免使用者剛好在延遲保存前 Quit App 時，最後一小段進度沒有落盤。
    func flushScheduledSave() {
        scheduledSaveTask?.cancel()
        scheduledSaveTask = nil
        persistItems()
    }

    /// Engine 回報下載完成。
    ///
    /// 這裡同時計算平均速度，並觸發 macOS 系統通知。
    func complete(
        id: DownloadItem.ID,
        fileURL: URL,
        received: Int64? = nil,
        expected: Int64? = nil,
        averageBytesPerSecond: Int64? = nil,
        averageUploadBytesPerSecond: Int64? = nil,
        activeDownloadDuration: TimeInterval? = nil
    ) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed else { return }
        let wasAlreadyCompleted = items[index].status == .completed
        let finalReceived = received ?? items[index].bytesReceived
        let finalExpected = expected ?? items[index].bytesExpected
        let elapsed = max(Date().timeIntervalSince(items[index].createdAt), 1)
        let completedBytes = max(finalReceived, finalExpected)

        items[index].progress = 1
        items[index].status = .completed
        items[index].bytesReceived = max(items[index].bytesReceived, finalReceived, completedBytes)
        items[index].bytesExpected = max(items[index].bytesExpected, finalExpected, completedBytes)
        items[index].bytesPerSecond = 0
        items[index].uploadBytesPerSecond = 0
        items[index].httpConnectionDetails = []
        items[index].torrentFileDetails = []
        if !wasAlreadyCompleted {
            items[index].averageBytesPerSecond = averageBytesPerSecond ?? (completedBytes > 0 ? Int64(Double(completedBytes) / elapsed) : 0)
            items[index].averageUploadBytesPerSecond = averageUploadBytesPerSecond ?? 0
            items[index].activeDownloadDuration = activeDownloadDuration ?? elapsed
        }
        items[index].isTorrentSeeding = items[index].kind == .torrent
        items[index].localFileURL = fileURL
        items[index].errorMessage = nil
        if !wasAlreadyCompleted {
            NotificationManager.shared.downloadDidFinish(name: items[index].name)
        }
        persistItems()
    }

    /// 已完成 BT 的 libtorrent session 回報目前上載速度。
    func updateTorrentSeeding(id: DownloadItem.ID, uploadSpeed: Int64, statusMessage: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed,
              items[index].kind == .torrent,
              items[index].status == .completed,
              items[index].isTorrentSeeding
        else { return }

        items[index].bytesPerSecond = 0
        items[index].uploadBytesPerSecond = uploadSpeed
        items[index].errorMessage = uploadSpeed > 0 ? nil : statusMessage
        scheduleSave()
    }

    /// 在 Finder 顯示下載項目。
    ///
    /// 完成的任務優先選中實際檔案；如果檔案不存在，就打開下載資料夾。
    func showInFinder(_ item: DownloadItem) {
        guard let url = finderURL(for: item) else { return }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.selectFile(
                url.path(percentEncoded: false),
                inFileViewerRootedAtPath: url.deletingLastPathComponent().path(percentEncoded: false)
            )
        }
    }

    /// Engine 回報失敗。
    func fail(id: DownloadItem.ID, errorMessage: String?) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].httpConnectionDetails = []
            items[index].torrentFileDetails = []
        }
        mark(id: id, status: .failed, errorMessage: errorMessage)
    }

    /// BT engine 找到 metadata 後，要求 UI 顯示可選檔案列表。
    func torrentFilesReady(
        id: DownloadItem.ID,
        title: String,
        files: [TorrentFileEntry],
        selectedIndexes: Set<Int>,
        isReselection: Bool
    ) {
        let displayTitle = title.isEmpty ? "Torrent" : title
        if !isReselection,
           let index = items.firstIndex(where: { $0.id == id }),
           items[index].name.isEmpty || items[index].name == "Magnet Download" {
            items[index].name = displayTitle
        }
        torrentFileSelection = TorrentFileSelection(
            itemID: id,
            title: displayTitle,
            files: files,
            selectedIndexes: selectedIndexes,
            isReselection: isReselection
        )
        if !isReselection {
            mark(id: id, status: .paused, errorMessage: "Waiting for file selection")
        }
    }

    /// 修改任務狀態的小工具方法。
    private func mark(id: DownloadItem.ID, status: DownloadStatus, errorMessage: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        if status != .downloading {
            items[index].bytesPerSecond = 0
            items[index].uploadBytesPerSecond = 0
        }
        items[index].errorMessage = errorMessage
        persistItems()
    }

    /// 合併高頻進度更新的保存工作。
    ///
    /// 下載中速度和進度可能一秒更新多次；UI 可以即時重畫，
    /// 但 JSON 不需要每次都寫入磁碟。這裡把短時間內的更新合併，
    /// 減少磁碟 I/O 和主執行緒壓力。
    private func scheduleSave() {
        scheduledSaveTask?.cancel()
        scheduledSaveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            persistItems()
            scheduledSaveTask = nil
        }
    }

    /// 從 Trash 復原目前選中的項目。
    private func restoreFromTrash(item: DownloadItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isTrashed = false
        items[index].status = item.statusBeforeTrash ?? item.status
        if items[index].status == .downloading || items[index].status == .queued {
            items[index].status = .paused
        }
        items[index].statusBeforeTrash = nil
        items[index].errorMessage = nil
        items[index].bytesPerSecond = 0
        items[index].uploadBytesPerSecond = 0
        items[index].isTorrentSeeding = false
        persistItems()
    }

    private func setTorrentSeeding(id: DownloadItem.ID, isSeeding: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              items[index].kind == .torrent,
              items[index].status == .completed
        else { return }

        items[index].isTorrentSeeding = isSeeding
        if !isSeeding {
            items[index].uploadBytesPerSecond = 0
        }
        items[index].errorMessage = isSeeding ? "Starting" : nil
        persistItems()
    }

    /// 停止 engine 內正在跑的下載並清理 engine 狀態。
    private func cancelDownload(for item: DownloadItem) {
        switch item.kind {
        case .http:
            httpEngine.cancel(id: item.id)
        case .torrent:
            torrentEngine.cancel(id: item.id)
        }
    }

    /// 停止網路活動但保留已寫入的未完成檔，讓 Delete with Files 可以把它們移到 Trash。
    private func pauseDownloadPreservingFiles(for item: DownloadItem) {
        switch item.kind {
        case .http:
            httpEngine.pause(id: item.id)
        case .torrent:
            torrentEngine.pause(id: item.id)
        }
    }

    /// 讓使用者確認會連同本機檔案一起刪除。
    private func confirmDeleteWithFiles(count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Delete Download with Files?" : "Delete Downloads with Files?"
        alert.informativeText = count == 1
            ? "The selected download will be removed from the list, and its local file or folder will be moved to the macOS Trash."
            : "\(count) selected downloads will be removed from the list, and their local files or folders will be moved to the macOS Trash."
        alert.addButton(withTitle: "Delete with Files")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// 把這個 item 可推斷出的下載檔案、資料夾或暫存檔移到 macOS Trash。
    private func moveDownloadedFilesToTrash(for item: DownloadItem) async throws {
        let folder = item.destination ?? item.localFileURL?.deletingLastPathComponent() ?? FolderBookmarkStore.fallbackFolder

        try await FolderBookmarkStore.withAccess(to: folder) {
            let candidates = fileDeletionCandidates(for: item, in: folder)
            try await trashExistingItems(candidates)

            if item.kind == .torrent {
                try await removeEmptyTorrentFolders(for: item, in: folder)
            }
        }
    }

    /// 建立要刪除的檔案候選清單。不存在的路徑之後會被忽略。
    private func fileDeletionCandidates(for item: DownloadItem, in folder: URL) -> [URL] {
        switch item.kind {
        case .http:
            return httpFileDeletionCandidates(for: item, in: folder)
        case .torrent:
            return torrentFileDeletionCandidates(for: item, in: folder)
        }
    }

    /// HTTP 下載包含正式檔名和 `.part-N.tmp` 暫存檔。
    private func httpFileDeletionCandidates(for item: DownloadItem, in folder: URL) -> [URL] {
        var candidates: [URL] = []

        if let localFileURL = item.localFileURL {
            candidates.append(localFileURL)
        }

        candidates.append(folder.appending(path: item.name))

        let fileManager = FileManager.default
        let partPrefix = "\(item.name).part-"
        if let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: contents.filter { url in
                let filename = url.lastPathComponent
                return filename.hasPrefix(partPrefix) && filename.hasSuffix(".tmp")
            })
        }

        return candidates
    }

    /// BT 下載優先刪除使用者選中的 torrent 內部檔案，以及 incomplete `.tmp` 檔。
    private func torrentFileDeletionCandidates(for item: DownloadItem, in folder: URL) -> [URL] {
        var candidates: [URL] = []

        for path in item.selectedTorrentFilePaths where !path.isEmpty {
            let fileURL = folder.appending(path: path)
            candidates.append(fileURL)
            candidates.append(folder.appending(path: path + ".tmp"))
        }

        if let localFileURL = item.localFileURL, localFileURL != folder {
            candidates.append(localFileURL)
        }

        return candidates
    }

    /// 將存在的候選路徑移到 macOS Trash，同一路徑只處理一次。
    private func trashExistingItems(_ candidates: [URL]) async throws {
        let fileManager = FileManager.default
        var seenPaths: Set<String> = []
        var urlsToTrash: [URL] = []

        for url in candidates {
            let path = url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else { continue }
            guard fileManager.fileExists(atPath: path) else { continue }
            urlsToTrash.append(url)
        }

        guard !urlsToTrash.isEmpty else { return }
        try await recycleItemsUsingWorkspace(urlsToTrash)
    }

    /// 使用公開的 NSWorkspace API，把檔案以 Finder 相同方式移到 macOS Trash。
    private func recycleItemsUsingWorkspace(_ urlsToRecycle: [URL]) async throws {
        let expectedRecycleCount = urlsToRecycle.count

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.recycle(urlsToRecycle) { recycledURLs, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                if recycledURLs.count != expectedRecycleCount {
                    continuation.resume(throwing: CocoaError(.fileWriteUnknown))
                    return
                }

                continuation.resume()
            }
        }
    }

    /// BT 選中檔案刪除後，順手清掉空的父資料夾，但絕不刪使用者選的下載根目錄。
    private func removeEmptyTorrentFolders(for item: DownloadItem, in folder: URL) async throws {
        let fileManager = FileManager.default
        let rootPath = folder.standardizedFileURL.path
        var parentFolders: Set<URL> = []

        for path in item.selectedTorrentFilePaths where path.contains("/") {
            parentFolders.insert(folder.appending(path: path).deletingLastPathComponent())
        }

        for folderURL in parentFolders.sorted(by: { $0.path.count > $1.path.count }) {
            var currentURL = folderURL

            while currentURL.standardizedFileURL.path != rootPath {
                guard fileManager.fileExists(atPath: currentURL.path) else {
                    currentURL = currentURL.deletingLastPathComponent()
                    continue
                }

                let contents = try fileManager.contentsOfDirectory(atPath: currentURL.path)
                guard contents.isEmpty else { break }

                try await trashExistingItems([currentURL])
                currentURL = currentURL.deletingLastPathComponent()
            }
        }
    }

    /// 依照目前 Table selection 取出完整項目，並保持列表原本排序。
    private var selectedItems: [DownloadItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    /// 找出 Finder 應該顯示的位置。
    private func finderURL(for item: DownloadItem) -> URL? {
        let fileManager = FileManager.default

        // BT 任務要先處理，避免 item.name 是 `.torrent` 檔名時誤選 torrent 檔，
        // 也避免完成後 localFileURL 是總下載資料夾時直接停在 Downloads。
        if item.kind == .torrent {
            if let destination = item.destination, fileManager.fileExists(atPath: destination.path) {
                return torrentContentFolder(for: item, destination: destination) ?? destination
            }

            if let localFileURL = item.localFileURL, fileManager.fileExists(atPath: localFileURL.path) {
                var isDirectory: ObjCBool = false
                fileManager.fileExists(atPath: localFileURL.path, isDirectory: &isDirectory)
                if isDirectory.boolValue {
                    return torrentContentFolder(for: item, destination: localFileURL) ?? localFileURL
                }
                return localFileURL.deletingLastPathComponent()
            }
        }

        if let localFileURL = item.localFileURL {
            if fileManager.fileExists(atPath: localFileURL.path) {
                return localFileURL
            }
            let containingFolder = localFileURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: containingFolder.path) {
                return containingFolder
            }
        }

        if let destination = item.destination, fileManager.fileExists(atPath: destination.path) {
            let guessedFileURL = destination.appending(path: item.name)
            if fileManager.fileExists(atPath: guessedFileURL.path) {
                return guessedFileURL
            }
            return destination
        }

        return nil
    }

    /// 找出 BT 內容檔案所在的資料夾。
    ///
    /// torrent 內部路徑可能是 `Movie/Movie.mkv` 或單一檔案 `Movie.mkv`：
    /// - 多層路徑：打開第一個選中檔案的上一層資料夾。
    /// - 單一檔案在根目錄：打開使用者選擇的下載資料夾。
    private func torrentContentFolder(for item: DownloadItem, destination: URL) -> URL? {
        guard let firstPath = item.selectedTorrentFilePaths.sorted().first, !firstPath.isEmpty else {
            return destination
        }

        let contentURL = destination.appending(path: firstPath)
        let folderURL = contentURL.deletingLastPathComponent()

        if FileManager.default.fileExists(atPath: folderURL.path) {
            return folderURL
        }

        let temporaryFolderURL = destination.appending(path: firstPath + ".tmp").deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: temporaryFolderURL.path) {
            return temporaryFolderURL
        }

        return destination
    }

    /// 從 URL 產生列表上顯示的檔名。
    private static func displayName(for url: URL) -> String {
        if url.absoluteString.hasPrefix("magnet:") {
            return "Magnet Download"
        }
        let lastPathComponent = url.lastPathComponent
        if lastPathComponent.isEmpty || lastPathComponent == "/" {
            return url.host() ?? "Download"
        }
        return lastPathComponent
    }
}

/// 讓兩個 engine 都可以透過同一批 delegate 方法回報進度。
extension DownloadManager: HTTPDownloadEngineDelegate, TorrentDownloadEngineDelegate {}

/// SwiftUI Preview 用的假資料。
extension DownloadManager {
    static var preview: DownloadManager {
        let manager = DownloadManager()
        manager.items = [
            DownloadItem(name: "Example.dmg", source: URL(string: "https://example.com/Example.dmg")!, destination: nil, kind: .http, status: .downloading, progress: 0.42, bytesPerSecond: 1_250_000),
            DownloadItem(name: "Ubuntu.torrent", source: URL(string: "magnet:?xt=urn:btih:example")!, destination: nil, kind: .torrent, status: .queued, progress: 0.0)
        ]
        return manager
    }
}
