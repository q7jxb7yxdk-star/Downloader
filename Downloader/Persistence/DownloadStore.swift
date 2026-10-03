import Foundation

/// Versioned download-list persistence. Live engine sessions are never restored.
final class DownloadStore {
    struct LoadResult {
        let items: [DownloadItem]
        let notice: String?
    }

    private struct Envelope: Codable {
        let schemaVersion: Int
        let items: [DownloadItem]
    }

    private struct Header: Decodable {
        let schemaVersion: Int
    }

    private enum StoreError: LocalizedError {
        case unsupportedVersion(Int)
        case blocked(String)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                return "Download data uses unsupported schema version \(version). Open it with a compatible app version. Saving is disabled to protect the original data."
            case .blocked(let message):
                return message
            }
        }
    }

    private static let schemaVersion = 1
    private let fileURL: URL
    private let backupURL: URL
    private var lastGoodData: Data?
    private var blockedReason: String?
    private var didLoad = false

    /// The optional location allows isolated persistence diagnostics without touching user data.
    init(fileURL: URL? = nil) {
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Downloader", directoryHint: .isDirectory)
        self.fileURL = fileURL ?? supportDirectory.appending(path: "downloads.json")
        backupURL = self.fileURL.appendingPathExtension("backup")
    }

    func load() -> LoadResult {
        didLoad = true
        blockedReason = nil
        lastGoodData = nil
        let manager = FileManager.default
        guard manager.fileExists(atPath: fileURL.path) else {
            guard manager.fileExists(atPath: backupURL.path) else {
                return LoadResult(items: [], notice: nil)
            }
            return recoverFromBackup(preservedURL: nil)
        }

        do {
            let data = try Data(contentsOf: fileURL)
            do {
                let items = try decode(data)
                lastGoodData = data
                return LoadResult(items: restored(items), notice: nil)
            } catch StoreError.unsupportedVersion(let version) {
                return blocked(StoreError.unsupportedVersion(version).localizedDescription)
            } catch {
                // Keep the exact original bytes before allowing any replacement of corrupt data.
                let preservedURL = fileURL.deletingLastPathComponent()
                    .appendingPathComponent("downloads.corrupt-\(UUID().uuidString).json")
                do {
                    try data.write(to: preservedURL, options: .atomic)
                } catch {
                    return blocked("Download data could not be decoded or preserved: \(error.localizedDescription). Saving is disabled. Original data: \(fileURL.path)")
                }
                return recoverFromBackup(preservedURL: preservedURL)
            }
        } catch {
            return blocked("Download data could not be read: \(error.localizedDescription). Saving is disabled. Original data: \(fileURL.path)")
        }
    }

    /// Save the previous validated snapshot first; replace the primary only after that succeeds.
    func save(_ items: [DownloadItem]) throws {
        guard didLoad else {
            throw StoreError.blocked("Download data must be loaded before saving.")
        }
        if let blockedReason { throw StoreError.blocked(blockedReason) }
        let data = try JSONEncoder().encode(Envelope(schemaVersion: Self.schemaVersion, items: items))
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (lastGoodData ?? data).write(to: backupURL, options: .atomic)
        try data.write(to: fileURL, options: .atomic)
        lastGoodData = data
    }

    private func decode(_ data: Data) throws -> [DownloadItem] {
        let decoder = JSONDecoder()
        // Legacy releases wrote a bare array. Only arrays use that migration path.
        if let first = data.first(where: { ![UInt8(32), 9, 10, 13].contains($0) }), first == 91 {
            return try decoder.decode([DownloadItem].self, from: data)
        }
        let header = try decoder.decode(Header.self, from: data)
        guard header.schemaVersion == Self.schemaVersion else {
            throw StoreError.unsupportedVersion(header.schemaVersion)
        }
        return try decoder.decode(Envelope.self, from: data).items
    }

    private func recoverFromBackup(preservedURL: URL?) -> LoadResult {
        let preservation = preservedURL.map { " Original data preserved at \($0.path)." } ?? ""
        do {
            let data = try Data(contentsOf: backupURL)
            let items = try decode(data)
            lastGoodData = data
            return LoadResult(items: restored(items), notice: "Recovered the download list from the last good backup. Recent changes may be missing.\(preservation)")
        } catch {
            return blocked("Download data could not be recovered from the backup: \(error.localizedDescription). Saving is disabled.\(preservation) Data location: \(fileURL.path)")
        }
    }

    private func blocked(_ message: String) -> LoadResult {
        blockedReason = message
        return LoadResult(items: [], notice: message)
    }

    private func restored(_ items: [DownloadItem]) -> [DownloadItem] {
        items.map { item in
            var restored = item
            if restored.status == .downloading {
                restored.status = .paused
            }
            restored.bytesPerSecond = 0
            restored.uploadBytesPerSecond = 0
            restored.isTorrentSeeding = false
            return restored
        }
    }
}
