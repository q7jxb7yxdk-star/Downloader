import Foundation

@MainActor
protocol TorrentDownloadEngineDelegate: AnyObject {
    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64)
    func updateStatusText(id: DownloadItem.ID, message: String?)
    func complete(id: DownloadItem.ID, fileURL: URL)
    func fail(id: DownloadItem.ID, errorMessage: String?)
}

@MainActor
final class TorrentDownloadEngine {
    private weak var delegate: TorrentDownloadEngineDelegate?
    private let bridge = TorrentSessionBridge()
    private var itemIDsByTorrentID: [String: DownloadItem.ID] = [:]
    private var saveFoldersByTorrentID: [String: URL] = [:]
    private var securityScopedFoldersByTorrentID: [String: URL] = [:]
    private var pausedItemIDs: Set<DownloadItem.ID> = []
    private var timer: Timer?

    init(delegate: TorrentDownloadEngineDelegate) {
        self.delegate = delegate
    }

    func start(item: DownloadItem) {
        let folder = item.destination ?? FolderBookmarkStore.fallbackFolder
        let hasSecurityScope = folder.startAccessingSecurityScopedResource()

        let torrentID: String
        do {
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

    func pause(id: DownloadItem.ID) {
        guard let torrentID = torrentID(for: id) else { return }
        pausedItemIDs.insert(id)
        bridge.pause(torrentID)
    }

    func resume(item: DownloadItem) {
        guard let torrentID = torrentID(for: item.id) else {
            start(item: item)
            return
        }
        pausedItemIDs.remove(item.id)
        bridge.resume(torrentID)
        startTimerIfNeeded()
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

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
            let speed = (status["downloadRate"] as? NSNumber)?.int64Value ?? 0
            let expected = (status["totalWanted"] as? NSNumber)?.int64Value ?? 0
            let received = (status["totalWantedDone"] as? NSNumber)?.int64Value ?? 0
            let isFinished = (status["isFinished"] as? NSNumber)?.boolValue ?? false
            let hasMetadata = (status["hasMetadata"] as? NSNumber)?.boolValue ?? false
            let seeds = (status["seeds"] as? NSNumber)?.intValue ?? 0
            let peers = (status["peers"] as? NSNumber)?.intValue ?? 0
            let candidates = (status["connectCandidates"] as? NSNumber)?.intValue ?? 0
            let state = status["state"] as? String ?? "Downloading"

            if isFinished {
                delegate?.complete(id: itemID, fileURL: saveFoldersByTorrentID[torrentID] ?? FolderBookmarkStore.fallbackFolder)
                completedTorrentIDs.append(torrentID)
            } else {
                delegate?.update(id: itemID, progress: progress, received: received, expected: expected, speed: speed)
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
            if let completedItemID {
                pausedItemIDs.remove(completedItemID)
            }
            securityScopedFoldersByTorrentID.removeValue(forKey: torrentID)?.stopAccessingSecurityScopedResource()
        }
    }

    private func torrentID(for itemID: DownloadItem.ID) -> String? {
        itemIDsByTorrentID.first { $0.value == itemID }?.key
    }

    private func torrentStatusMessage(state: String, hasMetadata: Bool, seeds: Int, peers: Int, candidates: Int) -> String {
        if !hasMetadata {
            return "\(state) - peers \(peers), candidates \(candidates)"
        }
        return "\(state) - seeds \(seeds), peers \(peers), candidates \(candidates)"
    }
}
