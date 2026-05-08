import Foundation

@MainActor
final class TorrentManager {
    static let shared = TorrentManager()

    private init() {}

    func noteTorrentSupportIsPending() {
        // The UI and data model already understand torrent tasks. The engine will
        // be backed by libtorrent through an Objective-C++ bridge in the next pass.
    }
}
