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

    /// BT 找到 metadata 後用來彈出「選擇檔案」sheet。
    @Published var torrentFileSelection: TorrentFileSelection?

    /// 負責把列表保存到 Application Support。
    private let store = DownloadStore()

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
        for item in selectedItems where !item.isTrashed {
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
        items[index].selectedTorrentFileIndexes = indexes
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
        store.save(items)
    }

    /// Engine 回報補充狀態文字，例如「Checking range support」或 peer 數量。
    func updateStatusText(id: DownloadItem.ID, message: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard !items[index].isTrashed else { return }
        guard items[index].status != .paused else { return }
        items[index].status = .downloading
        items[index].errorMessage = message
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
        NSWorkspace.shared.activateFileViewerSelecting([url])
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

    /// 找出 Finder 應該顯示的位置。
    private func finderURL(for item: DownloadItem) -> URL? {
        let fileManager = FileManager.default

        if let localFileURL = item.localFileURL {
            if fileManager.fileExists(atPath: localFileURL.path) {
                return localFileURL
            }
            let containingFolder = localFileURL.deletingLastPathComponent()
            if fileManager.fileExists(atPath: containingFolder.path) {
                return containingFolder
            }
        }

        if let destination = item.destination {
            let guessedFileURL = destination.appending(path: item.name)
            if fileManager.fileExists(atPath: guessedFileURL.path) {
                return guessedFileURL
            }
            if fileManager.fileExists(atPath: destination.path) {
                return destination
            }
        }

        return nil
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
