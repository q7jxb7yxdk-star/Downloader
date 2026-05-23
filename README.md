# Downloader README

Downloader is a macOS SwiftUI download manager inspired by Folx. It supports normal HTTP/HTTPS downloads, HTTP Range segmented downloads, magnet links, and `.torrent` imports with a bundled `libtorrent-rasterbar.xcframework`.

## Features

- HTTP/HTTPS downloads.
- HTTP Range segmented downloads with 4 concurrent connections for supported large files.
- Pause, resume, delete, trash, and restore download tasks.
- Magnet and BT downloads through bundled libtorrent.
- `.torrent` file import.
- Torrent file selection after metadata is available.
- Incomplete files are written directly to the selected download folder.
- HTTP incomplete files use `.part-N.tmp`; BT incomplete files use `.tmp`.
- Completed downloads show average download speed. BT downloads also show upload speed.
- Double-click a completed item to reveal it in Finder.
- Downloads table shows name, progress, percentage, downloaded size / total size, speed, ETA, and status.
- While downloading, ETA shows the estimated remaining time. After completion, it shows the accumulated active download time, excluding paused time.
- Right-click actions: Resume, Pause, Show in Finder, Delete, Delete with Files.
- Download completion notification and system sound.
- Native Safari App Extension with a `Download with Downloader` link context menu.

## Requirements

- macOS 14 or later.
- Xcode 16 or later recommended.
- Swift 6 project settings.
- Apple Development signing team for running the main app and Safari extension.
- App Groups capability configured as `group.com.sunnyyu.Downloader`.
- Bundled libtorrent framework in `Vendor/Libtorrent/`.

Users of the built app do not need to install `libtorrent-rasterbar` separately because it is embedded in the project.

## Project Structure

```text
Downloader/
  Downloader/                    Main macOS app source
  Downloader Safari Extension/   Safari extension target
  Vendor/Libtorrent/             Bundled libtorrent xcframework
  Scripts/                       Helper scripts
  README.md                      Quick project overview
  TECHNICAL_DOCUMENTATION.md     Detailed architecture and code notes
```

Important source folders:

```text
Downloader/App/                  App entry and lifecycle
Downloader/Core/                 DownloadItem and DownloadManager
Downloader/HTTP/                 HTTP and segmented download engine
Downloader/Torrent/              BT engine and libtorrent bridge
Downloader/UI/                   SwiftUI views
Downloader/Persistence/          JSON storage and folder bookmarks
Downloader/Notifications/        Download-complete notifications
Downloader/BrowserIntegration/   Custom URL scheme fallback handling
```

## Build and Run

1. Open `Downloader.xcodeproj` in Xcode.
2. Select the `Downloader` scheme.
3. Open the `Downloader` target settings.
4. In `Signing & Capabilities`, choose your Team.
5. Confirm App Groups contains:

```text
group.com.sunnyyu.Downloader
```

6. Repeat the same signing setup for `Downloader Safari Extension`.
7. Run the app with `Product > Run`.

## Usage

### Add a Normal Download

1. Click the plus button.
2. Paste an HTTP/HTTPS URL.
3. Choose a folder.
4. Click Add.

For example:

```text
https://ash-speed.hetzner.com/100MB.bin
```

### Add a Magnet Link

1. Click the plus button.
2. Paste a magnet link.
3. Choose a folder.
4. Click Add.
5. Wait for metadata.
6. Select torrent files when the selection window appears.

### Import a `.torrent` File

1. Click the plus button.
2. Click `Choose .torrent File`.
3. Select a `.torrent` file.
4. Choose which files to download.

### List Actions

- Single-click: select one item.
- Command-click: multi-select.
- Shift-click: range-select.
- Double-click: show downloaded location in Finder.
- Right-click: Resume, Pause, Show in Finder, Delete, Delete with Files.

### Trash

The Trash sidebar keeps deleted tasks temporarily.

- Delete outside Trash: move selected tasks to Trash.
- Restore inside Trash: move tasks back to their original list state.
- Delete inside Trash: permanently remove tasks from the list.

### Delete with Files

`Delete with Files` removes selected tasks from the list and moves their local files, folders, or incomplete temporary files to the macOS Trash.

Downloader first asks Finder to move the files to Trash, so macOS may ask for permission to control Finder. Files are sent to Finder one path at a time with a short delay, which keeps the trash action closer to normal Finder behavior and avoids overlapping delete sounds. If Finder automation is not available, Downloader falls back to the system workspace trash API.

## HTTP Segmented Downloads

Downloader starts normal HTTP downloads immediately with one connection. In the background, it probes whether the server supports HTTP Range requests.

If the server supports Range and the file is large enough, Downloader upgrades the task to segmented downloading.

Default HTTP segmented connections:

```swift
private static let segmentedThreadCount = 4
```

Location:

```text
Downloader/HTTP/HTTPDownloadEngine.swift
```

## Incomplete File Names

HTTP:

```text
filename.part-0.tmp
filename.part-1.tmp
filename.part-2.tmp
filename.part-3.tmp
filename
```

BT:

```text
originalName.tmp
originalName
```

Completed files are renamed back to their final names.

## Safari Extension

The project includes a native Safari App Extension target. It adds `Download with Downloader` to Safari's link context menu.

To use it:

1. Build and run the app once from Xcode.
2. Open Safari.
3. Open `Safari > Settings > Extensions`.
4. Enable the Downloader extension.
5. Open a web page, right-click a download link, then choose `Download with Downloader`.

The Safari context menu path uses the extension and an App Group queue. It does not depend on the `downloader://` URL scheme, so Safari should not repeatedly ask each website for permission to open Downloader.

If the context menu does not appear after changing the extension, restart Safari or disable and re-enable the extension, then reload the page.

If old duplicate extensions appear, clean Xcode DerivedData only when necessary:

```zsh
rm -rf ~/Documents/Xcode/Downloader/Build/DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/Downloader-fkmjpusihrlgzaeuymdzbrsrgavk
```

Then build again.

## Test URLs

Hetzner speed test:

```text
https://ash-speed.hetzner.com/
https://ash-speed.hetzner.com/100MB.bin
```

httpbin byte downloads:

```text
https://httpbin.org/bytes/1024
https://httpbin.org/bytes/1048576
https://httpbin.org/bytes/10485760
https://httpbin.org/bytes/104857600
```

httpbin streaming:

```text
https://httpbin.org/stream-bytes/1048576
```

## Documentation

For architecture, code explanations, UI column notes, sandbox details, BT flow, and common Xcode Debug Area messages, see:

```text
TECHNICAL_DOCUMENTATION.md
```
