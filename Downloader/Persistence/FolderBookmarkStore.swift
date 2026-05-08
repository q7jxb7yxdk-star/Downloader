import Foundation

enum FolderBookmarkStore {
    private static let bookmarkKey = "lastDownloadFolderBookmark"

    static var fallbackFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    static func lastFolder() -> URL {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else {
            return fallbackFolder
        }

        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                save(folder: url)
            }

            return url
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
            return fallbackFolder
        }
    }

    static func save(folder: URL) {
        do {
            let data = try folder.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } catch {
            UserDefaults.standard.removeObject(forKey: bookmarkKey)
        }
    }

    static func withAccess<T>(to folder: URL, perform work: () throws -> T) rethrows -> T {
        let didStartAccessing = folder.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                folder.stopAccessingSecurityScopedResource()
            }
        }
        return try work()
    }
}
