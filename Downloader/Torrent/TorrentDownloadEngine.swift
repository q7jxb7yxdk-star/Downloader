import Foundation

/// BT engine 回報狀態給 DownloadManager 的介面。
@MainActor
protocol TorrentDownloadEngineDelegate: AnyObject {
    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64)
    func updateStatusText(id: DownloadItem.ID, message: String?)
    func torrentFilesReady(id: DownloadItem.ID, title: String, files: [TorrentFileEntry])
    func complete(id: DownloadItem.ID, fileURL: URL)
    func fail(id: DownloadItem.ID, errorMessage: String?)
}

/// Swift 層的 BT 下載 engine。
///
/// 這一層負責把 libtorrent bridge 的 dictionary 狀態轉成 App model，
/// 同時處理 macOS sandbox folder access、檔案選擇 sheet、暫停/繼續等 App 邏輯。
@MainActor
final class TorrentDownloadEngine {
    private weak var delegate: TorrentDownloadEngineDelegate?

    /// Objective-C++ bridge，真正和 C++ libtorrent 溝通。
    private let bridge = TorrentSessionBridge()

    /// libtorrent 用 magnet URI 當 identifier；App UI 用 DownloadItem.ID，所以要互相映射。
    private var itemIDsByTorrentID: [String: DownloadItem.ID] = [:]
    private var saveFoldersByTorrentID: [String: URL] = [:]

    /// 有些資料夾需要 security-scoped access，開始後要記住，完成/取消時釋放。
    private var securityScopedFoldersByTorrentID: [String: URL] = [:]
    private var pausedItemIDs: Set<DownloadItem.ID> = []

    /// 防止 metadata 找到後重複彈檔案選擇 sheet。
    private var selectionRequestedItemIDs: Set<DownloadItem.ID> = []

    /// 等待使用者選檔案時，不應該把 torrent 判斷為完成或繼續更新速度。
    private var waitingForFileSelectionItemIDs: Set<DownloadItem.ID> = []

    /// 找 metadata 時定期 reannounce，提升找到 peer/metadata 的機會。
    private var metadataPollCountsByTorrentID: [String: Int] = [:]
    private var timer: Timer?

    init(delegate: TorrentDownloadEngineDelegate) {
        self.delegate = delegate
    }

    /// 開始 magnet 下載。
    func start(item: DownloadItem) {
        let folder = item.destination ?? FolderBookmarkStore.fallbackFolder
        let hasSecurityScope = folder.startAccessingSecurityScopedResource()

        let torrentID: String
        do {
            // startMagnet 會先用 upload_mode，讓 libtorrent 找 metadata/peer，但盡量不下載檔案 payload。
            torrentID = try bridge.startMagnet(item.source.absoluteString, savePath: folder.path)
        } catch {
            if hasSecurityScope {
                folder.stopAccessingSecurityScopedResource()
            }
            delegate?.fail(id: item.id, errorMessage: error.localizedDescription)
            return
        }

        itemIDsByTorrentID[torrentID] = item.id
        saveFoldersByTorrentID[torrentID] = folder
        if hasSecurityScope {
            securityScopedFoldersByTorrentID[torrentID] = folder
        }
        startTimerIfNeeded()
    }

    /// 暫停 torrent。
    func pause(id: DownloadItem.ID) {
        guard let torrentID = torrentID(for: id) else { return }
        pausedItemIDs.insert(id)
        bridge.pause(torrentID)
    }

    /// 取消 torrent 並釋放所有 Swift 層狀態。
    func cancel(id: DownloadItem.ID) {
        guard let torrentID = torrentID(for: id) else { return }
        bridge.remove(torrentID)
        itemIDsByTorrentID[torrentID] = nil
        saveFoldersByTorrentID[torrentID] = nil
        pausedItemIDs.remove(id)
        selectionRequestedItemIDs.remove(id)
        waitingForFileSelectionItemIDs.remove(id)
        metadataPollCountsByTorrentID[torrentID] = nil
        securityScopedFoldersByTorrentID.removeValue(forKey: torrentID)?.stopAccessingSecurityScopedResource()
    }

    /// 繼續 torrent。如果 App 重開後 bridge 裡沒有 torrent，就重新 start。
    func resume(item: DownloadItem) {
        guard let torrentID = torrentID(for: item.id) else {
            start(item: item)
            return
        }
        pausedItemIDs.remove(item.id)
        bridge.resume(torrentID)
        startTimerIfNeeded()
    }

    /// 使用者選好 BT 檔案後，把 selected indexes 交給 libtorrent 設定 priority。
    func selectFiles(for itemID: DownloadItem.ID, indexes: Set<Int>) {
        guard let torrentID = torrentID(for: itemID) else { return }
        let indexSet = NSMutableIndexSet()
        for index in indexes {
            indexSet.add(index)
        }
        bridge.setSelectedFileIndexes(indexSet as IndexSet, forIdentifier: torrentID)
        pausedItemIDs.remove(itemID)
        waitingForFileSelectionItemIDs.remove(itemID)
        startTimerIfNeeded()
    }

    /// 啟動輪詢 timer。
    ///
    /// libtorrent 狀態不是用 Swift callback 推送，所以這裡每 0.25 秒讀一次狀態。
    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    /// 讀取每個 torrent 的狀態，並回報給 DownloadManager。
    private func poll() {
        guard !itemIDsByTorrentID.isEmpty else {
            timer?.invalidate()
            timer = nil
            return
        }

        var completedTorrentIDs: [String] = []

        for (torrentID, itemID) in itemIDsByTorrentID {
            guard !pausedItemIDs.contains(itemID) else { continue }

            let status = bridge.status(forIdentifier: torrentID)
            let progress = (status["progress"] as? NSNumber)?.doubleValue ?? 0
            let payloadSpeed = (status["downloadPayloadRate"] as? NSNumber)?.int64Value ?? 0
            let expected = (status["totalWanted"] as? NSNumber)?.int64Value ?? 0
            let received = (status["totalWantedDone"] as? NSNumber)?.int64Value ?? 0
            let isFinished = (status["isFinished"] as? NSNumber)?.boolValue ?? false
            let hasMetadata = (status["hasMetadata"] as? NSNumber)?.boolValue ?? false
            let seeds = (status["seeds"] as? NSNumber)?.intValue ?? 0
            let peers = (status["peers"] as? NSNumber)?.intValue ?? 0
            let candidates = (status["connectCandidates"] as? NSNumber)?.intValue ?? 0
            let state = status["state"] as? String ?? "Downloading"

            if !hasMetadata {
                let pollCount = (metadataPollCountsByTorrentID[torrentID] ?? 0) + 1
                metadataPollCountsByTorrentID[torrentID] = pollCount
                // 找 metadata 初期和之後每幾次輪詢都 reannounce，加快找到可用 peer。
                if pollCount == 1 || pollCount.isMultiple(of: 10) {
                    bridge.reannounce(torrentID)
                }
            } else {
                metadataPollCountsByTorrentID[torrentID] = nil
            }

            if hasMetadata && !selectionRequestedItemIDs.contains(itemID) {
                // metadata 有了才知道 torrent 內有哪些檔案，這時才可以改成 `.tmp` 名稱。
                bridge.applyTemporaryFileNames(torrentID)
                let files = bridge.files(forIdentifier: torrentID).compactMap { dictionary -> TorrentFileEntry? in
                    guard let index = (dictionary["index"] as? NSNumber)?.intValue,
                          let path = dictionary["path"] as? String,
                          let size = (dictionary["size"] as? NSNumber)?.int64Value
                    else {
                        return nil
                    }
                    return TorrentFileEntry(index: index, path: path, size: size)
                }

                if !files.isEmpty {
                    selectionRequestedItemIDs.insert(itemID)
                    waitingForFileSelectionItemIDs.insert(itemID)
                    // 等使用者選檔案前，把所有檔案 priority 設成 dont_download。
                    bridge.pauseAllFiles(torrentID)
                    bridge.reannounce(torrentID)
                    delegate?.torrentFilesReady(id: itemID, title: status["name"] as? String ?? "Torrent", files: files)
                    delegate?.updateStatusText(id: itemID, message: "Waiting for file selection")
                    continue
                }
            }

            if waitingForFileSelectionItemIDs.contains(itemID) {
                // 這段很重要：所有檔案都是 dont_download 時，libtorrent 可能看起來像完成。
                // 所以等待選檔期間不要走完成判斷。
                delegate?.updateStatusText(id: itemID, message: "Waiting for file selection")
                continue
            }

            if isFinished {
                let saveFolder = saveFoldersByTorrentID[torrentID] ?? FolderBookmarkStore.fallbackFolder
                // 完成後把 `.tmp` 檔名還原成原本檔名。
                bridge.restoreOriginalFileNames(torrentID)
                delegate?.complete(id: itemID, fileURL: saveFolder)
                completedTorrentIDs.append(torrentID)
            } else {
                // 使用 payload speed，而不是總 download_rate，避免 metadata/DHT 流量顯示成下載速度。
                delegate?.update(id: itemID, progress: progress, received: received, expected: expected, speed: hasMetadata ? payloadSpeed : 0)
                delegate?.updateStatusText(
                    id: itemID,
                    message: torrentStatusMessage(state: state, hasMetadata: hasMetadata, seeds: seeds, peers: peers, candidates: candidates)
                )
            }
        }

        for torrentID in completedTorrentIDs {
            let completedItemID = itemIDsByTorrentID[torrentID]
            itemIDsByTorrentID[torrentID] = nil
            saveFoldersByTorrentID[torrentID] = nil
            metadataPollCountsByTorrentID[torrentID] = nil
            if let completedItemID {
                pausedItemIDs.remove(completedItemID)
                selectionRequestedItemIDs.remove(completedItemID)
                waitingForFileSelectionItemIDs.remove(completedItemID)
            }
            securityScopedFoldersByTorrentID.removeValue(forKey: torrentID)?.stopAccessingSecurityScopedResource()
        }
    }

    /// 從 App item id 找回 libtorrent identifier。
    private func torrentID(for itemID: DownloadItem.ID) -> String? {
        itemIDsByTorrentID.first { $0.value == itemID }?.key
    }

    /// 組合列表狀態欄文字。
    private func torrentStatusMessage(state: String, hasMetadata: Bool, seeds: Int, peers: Int, candidates: Int) -> String {
        if !hasMetadata {
            return "\(state) - peers \(peers), candidates \(candidates)"
        }

        let displayState = state == "Finding metadata" ? "Preparing selected files" : state
        return "\(displayState) - seeds \(seeds), peers \(peers), candidates \(candidates)"
    }
}
