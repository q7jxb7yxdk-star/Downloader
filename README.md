# Downloader

A macOS downloader prototype inspired by Folx.

## What is included

- SwiftUI macOS app shell
- Download sidebar and task table
- Add URL sheet
- HTTP download engine using `URLSessionDownloadTask`
- Pause/resume plumbing
- Persistent download list
- Notification hook for completed downloads
- Torrent model and Objective-C++ bridge placeholders
- Safari Web Extension source files for sending links to the app

## Next steps

1. Add a proper file mover so completed downloads land in the selected folder.
2. Replace the basic HTTP engine with a segmented Range downloader.
3. Add the Safari Web Extension target in Xcode and enable the `downloader://` URL scheme.
4. Build and embed `Vendor/Libtorrent/libtorrent-rasterbar.xcframework`, then connect it through `TorrentSessionBridge.mm`.
