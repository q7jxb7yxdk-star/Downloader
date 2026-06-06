import Foundation

/// BT engine 回報狀態給 DownloadManager 的介面。
@MainActor
protocol TorrentDownloadEngineDelegate: AnyObject {
    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64, uploadSpeed: Int64)
    func updateTorrentSeeding(id: DownloadItem.ID, uploadSpeed: Int64, statusMessage: String)
    func updateStatusText(id: DownloadItem.ID, message: String?)
    func torrentFilesReady(id: DownloadItem.ID, title: String, files: [TorrentFileEntry])
    func complete(id: DownloadItem.ID, fileURL: URL, received: Int64?, expected: Int64?, averageBytesPerSecond: Int64?, averageUploadBytesPerSecond: Int64?, activeDownloadDuration: TimeInterval?)
    func fail(id: DownloadItem.ID, errorMessage: String?)
}

/// Swift 層的 BT 下載 engine。
///
/// 這一層負責把 libtorrent bridge 的 dictionary 狀態轉成 App model，
/// 同時處理 macOS sandbox folder access、檔案選擇 sheet、暫停/繼續等 App 邏輯。
@MainActor
final class TorrentDownloadEngine {
    private struct PayloadTiming {
        let firstReceived: Int64
        let firstUploaded: Int64
        var activeStartedAt: Date?
        var accumulatedActiveTime: TimeInterval = 0
    }

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

    /// 已完成下載並保留在 session 內提供上載的項目。
    private var completedItemIDs: Set<DownloadItem.ID> = []
    private var completedPollCountsByTorrentID: [String: Int] = [:]

    /// App 重開後 resume 時，從持久化資料帶回之前選過的檔案 index。
    private var selectedFileIndexesByItemID: [DownloadItem.ID: Set<Int>] = [:]

    /// 找 metadata 時定期 reannounce，提升找到 peer/metadata 的機會。
    private var metadataPollCountsByTorrentID: [String: Int] = [:]
    /// BT 平均速度只計算實際 payload 下載時間，不包括 metadata、等待選檔和暫停。
    private var payloadTimingsByTorrentID: [String: PayloadTiming] = [:]
    private var timer: Timer?

    init(delegate: TorrentDownloadEngineDelegate) {
        self.delegate = delegate
    }

    /// 開始 magnet 或 `.torrent` 檔案下載。
    @discardableResult
    func start(item: DownloadItem) -> Bool {
        let folder = item.destination ?? FolderBookmarkStore.fallbackFolder
        let hasSecurityScope = folder.startAccessingSecurityScopedResource()

        let torrentID: String
        do {
            // 兩種來源都先用 upload_mode，讓使用者選檔前盡量不下載 payload。
            if item.source.isFileURL {
                torrentID = try bridge.startTorrentFile(item.source.path, savePath: folder.path)
            } else {
                torrentID = try bridge.startMagnet(item.source.absoluteString, savePath: folder.path)
            }
        } catch {
            if hasSecurityScope {
                folder.stopAccessingSecurityScopedResource()
            }
            delegate?.fail(id: item.id, errorMessage: error.localizedDescription)
            return false
        }

        itemIDsByTorrentID[torrentID] = item.id
        saveFoldersByTorrentID[torrentID] = folder
        if !item.selectedTorrentFileIndexes.isEmpty {
            selectedFileIndexesByItemID[item.id] = item.selectedTorrentFileIndexes
        }
        if item.status == .completed {
            completedItemIDs.insert(item.id)
        }
        if hasSecurityScope {
            securityScopedFoldersByTorrentID[torrentID] = folder
        }
        startTimerIfNeeded()
        return true
    }

    /// 暫停 torrent。
    func pause(id: DownloadItem.ID) {
        guard let torrentID = torrentID(for: id) else { return }
        pausedItemIDs.insert(id)
        suspendPayloadTiming(for: torrentID)
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
        completedItemIDs.remove(id)
        completedPollCountsByTorrentID[torrentID] = nil
        selectedFileIndexesByItemID[id] = nil
        metadataPollCountsByTorrentID[torrentID] = nil
        payloadTimingsByTorrentID[torrentID] = nil
        securityScopedFoldersByTorrentID.removeValue(forKey: torrentID)?.stopAccessingSecurityScopedResource()
    }

    /// 繼續 torrent。如果 App 重開後 bridge 裡沒有 torrent，就重新 start。
    @discardableResult
    func resume(item: DownloadItem) -> Bool {
        guard let torrentID = torrentID(for: item.id) else {
            return start(item: item)
        }
        if !item.selectedTorrentFileIndexes.isEmpty {
            selectedFileIndexesByItemID[item.id] = item.selectedTorrentFileIndexes
        }
        pausedItemIDs.remove(item.id)
        if item.status == .completed {
            let selectedIndexes: Set<Int>
            if !item.selectedTorrentFileIndexes.isEmpty {
                selectedIndexes = item.selectedTorrentFileIndexes
            } else {
                selectedIndexes = Set(
                    bridge.files(forIdentifier: torrentID).compactMap { dictionary in
                        (dictionary["index"] as? NSNumber)?.intValue
                    }
                )
            }

            if selectedIndexes.isEmpty {
                bridge.resume(torrentID)
            } else {
                let indexSet = NSMutableIndexSet()
                for index in selectedIndexes {
                    indexSet.add(index)
                }
                selectedFileIndexesByItemID[item.id] = selectedIndexes
                selectionRequestedItemIDs.insert(item.id)
                waitingForFileSelectionItemIDs.remove(item.id)
                bridge.setSelectedFileIndexes(indexSet as IndexSet, forIdentifier: torrentID)
            }
        } else if waitingForFileSelectionItemIDs.contains(item.id) {
            bridge.resumeDiscoveryOnly(torrentID)
        } else {
            bridge.resume(torrentID)
        }
        startTimerIfNeeded()
        return true
    }

    /// 使用者選好 BT 檔案後，把 selected indexes 交給 libtorrent 設定 priority。
    func selectFiles(for itemID: DownloadItem.ID, indexes: Set<Int>) {
        guard let torrentID = torrentID(for: itemID) else { return }
        let indexSet = NSMutableIndexSet()
        for index in indexes {
            indexSet.add(index)
        }
        bridge.setSelectedFileIndexes(indexSet as IndexSet, forIdentifier: torrentID)
        selectedFileIndexesByItemID[itemID] = indexes
        selectionRequestedItemIDs.insert(itemID)
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

        for (torrentID, itemID) in itemIDsByTorrentID {
            guard !pausedItemIDs.contains(itemID) else { continue }

            let status = bridge.status(forIdentifier: torrentID)
            // Objective-C++ bridge 回傳 NSDictionary，Swift 這邊逐個欄位轉回強型別。
            // 如果某個欄位缺失，就用安全預設值，避免 UI 因為 bridge 回傳異常而 crash。
            let progress = (status["progress"] as? NSNumber)?.doubleValue ?? 0
            let payloadSpeed = (status["downloadPayloadRate"] as? NSNumber)?.int64Value ?? 0
            let uploadPayloadSpeed = (status["uploadPayloadRate"] as? NSNumber)?.int64Value ?? 0
            let uploaded = (status["totalPayloadUpload"] as? NSNumber)?.int64Value ?? 0
            let expected = (status["totalWanted"] as? NSNumber)?.int64Value ?? 0
            let received = (status["totalWantedDone"] as? NSNumber)?.int64Value ?? 0
            let isFinished = (status["isFinished"] as? NSNumber)?.boolValue ?? false
            let hasMetadata = (status["hasMetadata"] as? NSNumber)?.boolValue ?? false
            let seeds = (status["seeds"] as? NSNumber)?.intValue ?? 0
            let peers = (status["peers"] as? NSNumber)?.intValue ?? 0
            let candidates = (status["connectCandidates"] as? NSNumber)?.intValue ?? 0
            let state = status["state"] as? String ?? "Downloading"
            let isPaused = (status["isPaused"] as? NSNumber)?.boolValue ?? false

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
                    let savedIndexes = selectedFileIndexesByItemID[itemID]
                    if let savedIndexes, !savedIndexes.isEmpty {
                        // App 重開後，如果列表裡已經保存了使用者之前選過的檔案，
                        // 就直接套用 selection，不再彈一次選檔視窗。
                        let indexSet = NSMutableIndexSet()
                        for index in savedIndexes {
                            indexSet.add(index)
                        }
                        selectionRequestedItemIDs.insert(itemID)
                        waitingForFileSelectionItemIDs.remove(itemID)
                        bridge.setSelectedFileIndexes(indexSet as IndexSet, forIdentifier: torrentID)
                        bridge.reannounce(torrentID)
                        continue
                    }

                    if completedItemIDs.contains(itemID) {
                        // 舊資料可能沒有保存 file indexes；完成項目重新 seeding 時使用全部檔案。
                        let allIndexes = IndexSet(files.map(\.index))
                        selectionRequestedItemIDs.insert(itemID)
                        bridge.setSelectedFileIndexes(allIndexes, forIdentifier: torrentID)
                        bridge.reannounce(torrentID)
                        continue
                    }

                    // 新下載在 metadata 準備好後才加 `.tmp`，已完成項目不會改名。
                    bridge.applyTemporaryFileNames(torrentID)
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

            if completedItemIDs.contains(itemID) {
                let pollCount = (completedPollCountsByTorrentID[torrentID] ?? 0) + 1
                completedPollCountsByTorrentID[torrentID] = pollCount

                // 完成項目 Resume 後若 libtorrent 仍處於 paused，主動再次喚醒。
                if isPaused {
                    bridge.resume(torrentID)
                }
                // 沒有下載者時定期重新 announce，讓 tracker、DHT 和 LSD 更新可連線狀態。
                if pollCount == 1 || pollCount.isMultiple(of: 40) {
                    bridge.reannounce(torrentID)
                }

                delegate?.updateTorrentSeeding(
                    id: itemID,
                    uploadSpeed: uploadPayloadSpeed,
                    statusMessage: completedTorrentStatusMessage(
                        state: state,
                        hasMetadata: hasMetadata,
                        peers: peers,
                        candidates: candidates
                    )
                )
                continue
            }

            if hasMetadata
                && selectionRequestedItemIDs.contains(itemID)
            {
                beginPayloadTiming(for: torrentID, received: received, uploaded: uploaded)
            }

            if isFinished {
                let saveFolder = saveFoldersByTorrentID[torrentID] ?? FolderBookmarkStore.fallbackFolder
                let averageSpeeds = averagePayloadSpeeds(for: torrentID, received: received, uploaded: uploaded)
                // 完成後把 `.tmp` 檔名還原成原本檔名。
                bridge.restoreOriginalFileNames(torrentID)
                // BT 可能包含多個檔案，所以這裡回報的是保存資料夾，
                // Finder 打開時會讓使用者看到整個下載位置。
                delegate?.complete(
                    id: itemID,
                    fileURL: saveFolder,
                    received: received,
                    expected: expected,
                    averageBytesPerSecond: averageSpeeds.download,
                    averageUploadBytesPerSecond: averageSpeeds.upload,
                    activeDownloadDuration: averageSpeeds.duration
                )
                completedItemIDs.insert(itemID)
                completedPollCountsByTorrentID[torrentID] = 0
                delegate?.updateTorrentSeeding(
                    id: itemID,
                    uploadSpeed: uploadPayloadSpeed,
                    statusMessage: completedTorrentStatusMessage(
                        state: state,
                        hasMetadata: hasMetadata,
                        peers: peers,
                        candidates: candidates
                    )
                )
            } else {
                // 使用 payload speed，而不是總 download_rate，避免 metadata/DHT 流量顯示成下載速度。
                delegate?.update(
                    id: itemID,
                    progress: progress,
                    received: received,
                    expected: expected,
                    speed: hasMetadata ? payloadSpeed : 0,
                    uploadSpeed: hasMetadata ? uploadPayloadSpeed : 0
                )
                delegate?.updateStatusText(
                    id: itemID,
                    message: torrentStatusMessage(state: state, hasMetadata: hasMetadata, seeds: seeds, peers: peers, candidates: candidates)
                )
            }
        }
    }

    /// 從 App item id 找回 libtorrent identifier。
    private func torrentID(for itemID: DownloadItem.ID) -> String? {
        itemIDsByTorrentID.first { $0.value == itemID }?.key
    }

    /// 記錄開始傳輸 payload 的時間點。metadata 尋找和等待使用者選檔不計入平均速度。
    private func beginPayloadTiming(for torrentID: String, received: Int64, uploaded: Int64) {
        if payloadTimingsByTorrentID[torrentID] == nil {
            payloadTimingsByTorrentID[torrentID] = PayloadTiming(firstReceived: received, firstUploaded: uploaded, activeStartedAt: Date())
            return
        }

        guard var timing = payloadTimingsByTorrentID[torrentID], timing.activeStartedAt == nil else { return }
        timing.activeStartedAt = Date()
        payloadTimingsByTorrentID[torrentID] = timing
    }

    /// 暫停時結算已累積的有效下載時間。
    private func suspendPayloadTiming(for torrentID: String) {
        guard var timing = payloadTimingsByTorrentID[torrentID],
              let activeStartedAt = timing.activeStartedAt
        else {
            return
        }

        timing.accumulatedActiveTime += Date().timeIntervalSince(activeStartedAt)
        timing.activeStartedAt = nil
        payloadTimingsByTorrentID[torrentID] = timing
    }

    /// 以實際 payload 傳輸期間和新增 payload bytes 計算 BT 平均下載/上載速度。
    private func averagePayloadSpeeds(for torrentID: String, received: Int64, uploaded: Int64) -> (download: Int64?, upload: Int64?, duration: TimeInterval?) {
        guard var timing = payloadTimingsByTorrentID[torrentID] else { return (nil, nil, nil) }

        if let activeStartedAt = timing.activeStartedAt {
            timing.accumulatedActiveTime += Date().timeIntervalSince(activeStartedAt)
            timing.activeStartedAt = nil
            payloadTimingsByTorrentID[torrentID] = timing
        }

        let elapsed = max(timing.accumulatedActiveTime, 1)
        let downloadedBytes = max(0, received - timing.firstReceived)
        let uploadedBytes = max(0, uploaded - timing.firstUploaded)
        let averageDownload = downloadedBytes > 0 ? Int64(Double(downloadedBytes) / elapsed) : nil
        let averageUpload = uploadedBytes > 0 ? Int64(Double(uploadedBytes) / elapsed) : 0
        return (averageDownload, averageUpload, elapsed)
    }

    /// 組合列表狀態欄文字。
    private func torrentStatusMessage(state: String, hasMetadata: Bool, seeds: Int, peers: Int, candidates: Int) -> String {
        if !hasMetadata {
            return "\(state) - peers \(peers), candidates \(candidates)"
        }

        let displayState = state == "Finding metadata" ? "Preparing selected files" : state
        return "\(displayState) - seeds \(seeds), peers \(peers), candidates \(candidates)"
    }

    /// 已完成 BT Resume 後的狀態；真正有上載流量時 UI 會改顯示 Seeding。
    private func completedTorrentStatusMessage(state: String, hasMetadata: Bool, peers: Int, candidates: Int) -> String {
        if !hasMetadata {
            return "\(state) - peers \(peers), candidates \(candidates)"
        }

        switch state {
        case "Checking", "Starting", "Allocating", "Downloading":
            return "\(state) - peers \(peers), candidates \(candidates)"
        default:
            return "Completed | Waiting for peers - peers \(peers), candidates \(candidates)"
        }
    }
}
