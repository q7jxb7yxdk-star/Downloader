import Foundation

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    @Published var items: [DownloadItem] = []
    @Published var selectedItemID: DownloadItem.ID?

    private let store = DownloadStore()
    private lazy var httpEngine = HTTPDownloadEngine(delegate: self)
    private lazy var torrentEngine = TorrentDownloadEngine(delegate: self)

    override init() {
        super.init()
        items = store.load()
    }

    func add(url: URL, destination: URL?) {
        let kind: DownloadKind = url.absoluteString.hasPrefix("magnet:") || url.pathExtension == "torrent" ? .torrent : .http
        let item = DownloadItem(
            name: Self.displayName(for: url),
            source: url,
            destination: destination,
            kind: kind
        )
        items.insert(item, at: 0)
        selectedItemID = item.id
        store.save(items)

        switch kind {
        case .http:
            httpEngine.start(item: item)
        case .torrent:
            torrentEngine.start(item: item)
        }
    }

    func pauseSelected() {
        guard let selectedItemID, let item = items.first(where: { $0.id == selectedItemID }) else { return }
        switch item.kind {
        case .http:
            httpEngine.pause(id: selectedItemID)
        case .torrent:
            torrentEngine.pause(id: selectedItemID)
        }
        mark(id: selectedItemID, status: .paused)
    }

    func resumeSelected() {
        guard let selectedItemID, let item = items.first(where: { $0.id == selectedItemID }) else { return }
        mark(id: selectedItemID, status: .queued)

        switch item.kind {
        case .http:
            httpEngine.resume(item: item)
        case .torrent:
            torrentEngine.resume(item: item)
        }
    }

    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status != .paused else { return }
        items[index].progress = progress
        items[index].bytesReceived = received
        items[index].bytesExpected = expected
        items[index].bytesPerSecond = speed
        items[index].status = .downloading
        items[index].errorMessage = nil
        store.save(items)
    }

    func updateStatusText(id: DownloadItem.ID, message: String?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        guard items[index].status != .paused else { return }
        items[index].status = .downloading
        items[index].errorMessage = message
        store.save(items)
    }

    func complete(id: DownloadItem.ID, fileURL: URL) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].progress = 1
        items[index].status = .completed
        items[index].errorMessage = nil
        NotificationManager.shared.downloadDidFinish(name: items[index].name)
        store.save(items)
    }

    func fail(id: DownloadItem.ID, errorMessage: String?) {
        mark(id: id, status: .failed, errorMessage: errorMessage)
    }

    private func mark(id: DownloadItem.ID, status: DownloadStatus, errorMessage: String? = nil) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].status = status
        items[index].errorMessage = errorMessage
        store.save(items)
    }

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

extension DownloadManager: HTTPDownloadEngineDelegate, TorrentDownloadEngineDelegate {}

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
