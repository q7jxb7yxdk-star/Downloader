import Foundation

final class DownloadStore {
    private let fileURL: URL

    init() {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Downloader", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        fileURL = supportDirectory.appending(path: "downloads.json")
    }

    func load() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let items = (try? JSONDecoder().decode([DownloadItem].self, from: data)) ?? []
        return items.map { item in
            var restored = item
            if restored.status == .downloading {
                restored.status = .paused
                restored.bytesPerSecond = 0
            }
            return restored
        }
    }

    func save(_ items: [DownloadItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
