import AppKit
import Foundation

/// App 的中央狀態管理器。
///
/// SwiftUI 畫面只跟 `DownloadManager` 溝通；它再把真正下載工作分派給
/// `HTTPDownloadEngine` 或 `TorrentDownloadEngine`。這樣 UI 不需要知道
/// HTTP 分段下載、BT metadata、libtorrent bridge 等細節。
@MainActor
final class DownloadManager: NSObject, ObservableObject {
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
    ///
    /// 已完成、正在下載、Trash 內的任務都不應該由 Resume 重新開始。
    var canResumeSelected: Bool {
        selectedItems.contains { item in
            !item.isTrashed && item.status != .downloading && item.status != .completed
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
        items = store.load()
    }

    /// 新增一個下載任務，並立即開始下載。
    func add(url: URL, destination: URL?) {
        // 用 URL 形式判斷下載類型：magnet 和 .torrent 交給 BT engine，其他交給 HTTP。
        let kind: DownloadKind = url.absoluteString.hasPrefix("magnet:") || url.pathExtension.lowercased() == "torrent" ? .torrent : .http
        let item = DownloadItem(
            name: Self.displayName(for: url),
            source: url,
            destination: destination,
            kind: kind
        )
        items.insert(item, at: 0)
        selectedItemIDs = [item.id]
        store.save(items)

        // DownloadManager 只決定「交給誰」，真正下載細節留給各 engine。
        switch kind {
        case .http:
            httpEngine.start(item: item)
        case .torrent:
            torrentEngine.start(item: item)
        }
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
        for item in selectedItems where !item.isTrashed && item.status != .completed && item.status != .downloading {
            mark(id: item.id, status: .queued)

            switch item.kind {
            case .http:
                httpEngine.resume(item: item)
            case .torrent:
                torrentEngine.resume(item: item)
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
            permanentlyDeleteSelected()
            return
        }

        for item in itemsToDelete where !item.isTrashed {
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { continue }

            if item.status == .downloading || item.status == .queued {
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
            if item.status == .downloading || item.status == .queued {
                items[index].status = .paused
            }
            items[index].errorMessage = nil
        }

        selectedItemIDs = Set(itemsToDelete.map(\.id))
        store.save(items)
    }

    /// 真正刪除 Trash 內的項目。
    ///
    /// 只有 item 已經在 Trash 時才會走到這裡；正常列表的 Delete 仍然只是軟刪除。
    private func permanentlyDeleteSelected() {
        let ids = selectedItemIDs
        guard !ids.isEmpty else { return }

        for item in items where ids.contains(item.id) {
            switch item.kind {
            case .http:
                httpEngine.cancel(id: item.id)
            case .torrent:
                torrentEngine.cancel(id: item.id)
            }
        }

        items.removeAll { ids.contains($0.id) }
        selectedItemIDs = Set(items.filter(\.isTrashed).prefix(1).map(\.id))
        store.save(items)
    }

    /// 使用者在 BT 檔案選擇 sheet 按下開始後呼叫。
    func chooseTorrentFiles(itemID: DownloadItem.ID, indexes: Set<Int>) {
        guard let index = items.firstIndex(where: { $0.id == itemID }), items[index].kind == .torrent else { return }
        let selectedPaths = torrentFileSelection?.itemID == itemID
            ? torrentFileSelection?.files.filter { indexes.contains($0.index) }.map(\.path) ?? []
            : []
        items[index].selectedTorrentFileIndexes = indexes
        items[index].selectedTorrentFilePaths = selectedPaths
        torrentFileSelection = nil
        torrentEngine.selectFiles(for: itemID, indexes: indexes)
        mark(id: itemID, status: .queued)
    }

    /// 使用者取消 BT 檔案選擇時，只有全新任務會被移除。
    ///
    /// 如果任務之前已經下載過，重開 App 後意外再出現選檔 sheet 時，
    /// Cancel 只會停止這次 engine，保留列表項目和既有進度。
    func cancelTorrentFileSelection(itemID: DownloadItem.ID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        torrentEngine.cancel(id: itemID)
        if items[index].progress > 0 || items[index].bytesReceived > 0 || !items[index].selectedTorrentFileIndexes.isEmpty {
            torrentFileSelection = nil
            items[index].status = .paused
            items[index].bytesPerSecond = 0
            items[index].errorMessage = nil
            store.save(items)
            return
        }

        items.remove(at: index)
        selectedItemIDs = Set(items.prefix(1).map(\.id))
        torrentFileSelection = nil
        store.save(items)
    }

    /// Engine 回報進度時呼叫。所有 UI 進度更新都集中在這裡。
    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed else { return }
        guard items[index].status != .paused else { return }
        items[index].progress = progress
        items[index].bytesReceived = received
        items[index].bytesExpected = expected
        items[index].bytesPerSecond = speed
        items[index].status = .downloading
        scheduleSave()
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
        store.save(items)
    }

    /// Engine 回報下載完成。
    ///
    /// 這裡同時計算平均速度，並觸發 macOS 系統通知。
    func complete(id: DownloadItem.ID, fileURL: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed else { return }
        let elapsed = max(Date().timeIntervalSince(items[index].createdAt), 1)
        let completedBytes = max(items[index].bytesReceived, items[index].bytesExpected)

        items[index].progress = 1
        items[index].status = .completed
        items[index].bytesPerSecond = 0
        items[index].averageBytesPerSecond = completedBytes > 0 ? Int64(Double(completedBytes) / elapsed) : 0
        items[index].localFileURL = fileURL
        items[index].errorMessage = nil
        NotificationManager.shared.downloadDidFinish(name: items[index].name)
        store.save(items)
    }

    /// 在 Finder 顯示下載項目。
    ///
    /// 完成的任務優先選中實際檔案；如果檔案不存在，就打開下載資料夾。
    func showInFinder(_ item: DownloadItem) {
        guard let url = finderURL(for: item) else { return }

        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)

        if isDirectory.boolValue {
            openFolderInFinder(url, maximizeWindow: item.kind == .torrent)
        } else {
            NSWorkspace.shared.selectFile(
                url.path(percentEncoded: false),
                inFileViewerRootedAtPath: url.deletingLastPathComponent().path(percentEncoded: false)
            )
        }
    }

    /// Engine 回報失敗。
    func fail(id: DownloadItem.ID, errorMessage: String?) {
        mark(id: id, status: .failed, errorMessage: errorMessage)
    }

    /// BT engine 找到 metadata 後，要求 UI 顯示可選檔案列表。
    func torrentFilesReady(id: DownloadItem.ID, title: String, files: [TorrentFileEntry]) {
        torrentFileSelection = TorrentFileSelection(itemID: id, title: title.isEmpty ? "Torrent" : title, files: files)
        mark(id: id, status: .paused, errorMessage: "Waiting for file selection")
    }

    /// 修改任務狀態的小工具方法。
    private func mark(id: DownloadItem.ID, status: DownloadStatus, errorMessage: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        if status != .downloading {
            items[index].bytesPerSecond = 0
        }
        items[index].errorMessage = errorMessage
        store.save(items)
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
            store.save(items)
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
        store.save(items)
    }

    /// 依照目前 Table selection 取出完整項目，並保持列表原本排序。
    private var selectedItems: [DownloadItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    /// 打開 Finder 資料夾。
    ///
    /// `NSWorkspace.shared.open` 只能打開資料夾，不能控制 Finder 視窗大小。
    /// BT 資料夾通常內容較多，所以這裡可以在打開後透過 Apple Events
    /// 把 Finder 最前面的視窗拉到螢幕可用範圍。
    private func openFolderInFinder(_ url: URL, maximizeWindow: Bool) {
        NSWorkspace.shared.open(url)
        guard maximizeWindow else { return }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            maximizeFrontFinderWindow()
        }
    }

    /// 用 AppleScript 調整 Finder 最前面的視窗大小。
    ///
    /// macOS 會保護其他 App，所以第一次使用時可能會要求允許 Downloader 控制 Finder。
    /// 如果使用者拒絕授權，資料夾仍會正常打開，只是不會自動放大。
    private func maximizeFrontFinderWindow() {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        let left = Int(visibleFrame.minX)
        let top = Int(screenFrame.maxY - visibleFrame.maxY)
        let right = Int(visibleFrame.maxX)
        let bottom = Int(screenFrame.maxY - visibleFrame.minY)

        let source = """
        tell application "Finder"
            activate
            try
                set bounds of front window to {\(left), \(top), \(right), \(bottom)}
            end try
        end tell
        """

        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
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
