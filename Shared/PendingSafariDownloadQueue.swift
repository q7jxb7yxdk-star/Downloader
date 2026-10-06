import Foundation
import Darwin

// Use a distinct Swift name to avoid Darwin's struct flock/function name collision.
@_silgen_name("flock")
private func pendingSafariQueueFlock(_ descriptor: Int32, _ operation: Int32) -> Int32

/// Shared by the app and native extension. The separate lock file survives atomic queue replacement.
struct PendingSafariDownloadQueue {
    struct Entry: Codable {
        let id: UUID
        let url: String
        let kind: String?
        let name: String?
        fileprivate(set) var needsMigration = false

        private enum CodingKeys: String, CodingKey { case id, url, kind, name }

        init(url: String, kind: String?, name: String?) {
            id = UUID()
            self.url = url
            self.kind = kind
            self.name = name
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            if let savedID = try values.decodeIfPresent(UUID.self, forKey: .id) {
                id = savedID
            } else {
                id = UUID()
                needsMigration = true
            }
            url = try values.decode(String.self, forKey: .url)
            kind = try values.decodeIfPresent(String.self, forKey: .kind)
            name = try values.decodeIfPresent(String.self, forKey: .name)
        }
    }

    enum QueueError: Error { case unavailableContainer, lockUnavailable, invalidQueue }
    let queueURL: URL

    init(queueURL: URL) { self.queueURL = queueURL }

    static func appGroupQueue() throws -> Self {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.sunny.Downloader"
        ) else { throw QueueError.unavailableContainer }
        return Self(queueURL: container.appendingPathComponent("pending-safari-downloads.json"))
    }

    func append(url: String, kind: String?, name: String?) throws {
        try withLock {
            var entries = try read()
            entries.append(Entry(url: url, kind: kind, name: name))
            try write(entries)
        }
    }

    /// Persist legacy IDs before exposing them so a crash cannot assign new IDs on retry.
    func snapshot() throws -> [Entry] {
        try withLock {
            let entries = try read()
            if entries.contains(where: \.needsMigration) { try write(entries) }
            return entries
        }
    }

    /// Re-read under the lock so entries appended since snapshot are preserved.
    func acknowledge(ids: Set<UUID>) throws {
        guard !ids.isEmpty else { return }
        try withLock {
            let remaining = try read().filter { !ids.contains($0.id) }
            try write(remaining)
        }
    }

    private func read() throws -> [Entry] {
        guard FileManager.default.fileExists(atPath: queueURL.path) else { return [] }
        let data = try Data(contentsOf: queueURL)
        if let entries = try? JSONDecoder().decode([Entry].self, from: data) { return entries }
        if let links = try? JSONDecoder().decode([String].self, from: data) {
            return links.map { link in
                var entry = Entry(url: link, kind: nil, name: nil)
                entry.needsMigration = true
                return entry
            }
        }
        // Never overwrite undecodable bytes with an empty queue.
        throw QueueError.invalidQueue
    }

    private func write(_ entries: [Entry]) throws {
        try JSONEncoder().encode(entries).write(to: queueURL, options: .atomic)
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let lockURL = queueURL.appendingPathExtension("lock")
        let descriptor = lockURL.path.withCString { Darwin.open($0, O_CREAT | O_RDWR, mode_t(0o600)) }
        guard descriptor >= 0 else { throw QueueError.lockUnavailable }
        defer { Darwin.close(descriptor) }
        // Brief contention is retried by the app timer / extension caller, without blocking the UI.
        guard pendingSafariQueueFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw QueueError.lockUnavailable }
        defer { _ = pendingSafariQueueFlock(descriptor, LOCK_UN) }
        return try operation()
    }
}
