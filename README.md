# Downloader README

Downloader is a macOS SwiftUI download manager inspired by Folx. It supports normal HTTP/HTTPS downloads, HTTP Range segmented downloads, magnet links, and `.torrent` imports with a bundled `libtorrent-rasterbar.xcframework`.

## Features

- HTTP/HTTPS downloads.
- HTTP Range segmented downloads with up to 4 concurrent connections for supported large files.
- Pause, resume, delete, trash, and restore download tasks.
- Magnet and BT downloads through bundled libtorrent.
- Local and remote `.torrent` file import.
- Torrent file selection after metadata is available.
- Incomplete files are written directly to the selected download folder.
- HTTP incomplete files use `.part-N.tmp`; BT incomplete files use `.tmp`.
- Completed BT downloads continue seeding until paused or removed.
- Completed BT downloads show average download/upload speeds and the current seeding upload speed.
- Double-click a completed item to reveal it in Finder.
- Downloads table shows name, progress, percentage, downloaded size / total size, speed, ETA, and status.
- Active HTTP downloads show per-connection progress, transferred size, and speed.
- While downloading, ETA shows the estimated remaining time. After completion, it shows the accumulated active download time, excluding paused time.
- Right-click actions: Resume, Pause, Show in Finder, Delete, Delete with Files.
- Download completion notification and system sound.
- Safari Web Extension with automatic direct-download capture and a `Download with Downloader` link context menu.

## Requirements

- macOS 14 or later.
- Xcode 16 or later recommended.
- Swift 6 project settings.
- Apple Development signing team for running the main app and Safari extension.
- App Groups capability configured as `group.com.sunny.Downloader`.
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
group.com.sunny.Downloader
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

A direct web link ending in `.torrent` can also be added from Safari. Downloader
first saves the torrent metadata locally, then opens the BT file-selection flow.

### List Actions

- Single-click: select one item.
- Command-click: multi-select.
- Shift-click: range-select.
- Double-click: show downloaded location in Finder.
- Right-click: Resume, Pause, Show in Finder, Delete, Delete with Files.

For a completed BT download:

- Pause stops seeding while keeping the task completed.
- Resume starts seeding again without repeating the completion notification.
- Resume may briefly show `Starting`, `Checking`, or `Finding metadata`.
- Status shows `Completed | Waiting for peers` while the torrent is ready but no payload is being uploaded.
- Status shows `Completed | Seeding` only while payload is actively being uploaded, and `Completed` while paused.

During an active BT download, `Select Files` can be used again to add or remove
selected torrent files. Downloader reapplies file priorities and nudges the
selected files' pieces so newly added files can start downloading without
waiting for the original file to finish.

### Trash

The Trash sidebar keeps deleted tasks temporarily.

- Delete outside Trash: move selected tasks to Trash.
- Restore inside Trash: move tasks back to their original list state.
- Delete inside Trash: move associated HTTP or BT files to the macOS Trash,
  then permanently remove successful tasks from the list.

### Delete with Files

`Delete with Files` removes selected tasks from the list and moves their local files, folders, or incomplete temporary files to the macOS Trash.

Downloader uses the system workspace API to move the files to Trash in the same manner as Finder, without requesting permission to control Finder.

## HTTP Segmented Downloads

Downloader starts normal HTTP downloads immediately with one connection. In the background, it probes whether the server supports HTTP Range requests.

If the server supports Range and the file is large enough, Downloader upgrades the task to segmented downloading.

Segmented downloads start with up to four connections. If the server limits
parallel Range requests, Downloader progressively reduces the active limit from
4 to 2 to 1 without discarding downloaded segments. If the server only allows
one connection, Downloader continues with one active thread. The table shows
only the currently usable connections and prioritizes active or unfinished
segments.

During active segmented downloads, the table shows one progress row and one
speed row per visible connection. It does not show a separate overall progress
bar or total download speed row.

Pausing keeps the `.part-N.tmp` files. Resuming requests only the missing byte
ranges and clears stale cancelled-task slots before restarting the connections.

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

The project includes a Safari Web Extension target. It automatically captures
explicit download links and also adds `Download with Downloader` to Safari's
link context menu.
Safari Settings and the extension's toolbar button use icons derived from the
Downloader app icon. The toolbar button currently has no click action;
automatic capture and the link context menu handle downloads.

To use it:

1. Build and run the app once from Xcode.
2. Open Safari.
3. Open `Safari > Settings > Extensions`.
4. Enable the Downloader extension.
5. Allow the extension access to all websites.
6. Reload the web page, then click a direct file, magnet, or `.torrent` link.

Automatic capture is enabled by default and can be changed in Downloader
Settings. It recognizes links with a `download` attribute, magnet links, and
common file extensions. Torrent buttons and links can also be recognized from
their MIME type, filename, label, or torrent-related data attributes, even when
the endpoint URL does not end in `.torrent`. Ambiguous `/file/` and `/download`
links are checked with a one-byte Range request; Downloader captures the link
when its response headers identify a Torrent file or a normal downloadable file
such as a `.dmg`, `.iso`, or `.zip`. Dynamic downloads created entirely by
JavaScript, authenticated POST requests, or `blob:` URLs may still require
Safari's own download flow.

Direct file URLs opened in Safari by another app, such as Telegram, are also
captured when they end in a known downloadable extension. Redirected signed
asset URLs, such as GitHub release downloads whose filename is stored in
`response-content-disposition` or `rscd`, are also recognized. Downloader opens
in the foreground and Safari closes the temporary download tab. Duplicate
navigation events for the same URL are ignored for a short period.

The Safari extension sends download URLs through native messaging and an App
Group queue. The extension launches its containing Downloader app directly. The
`downloader://authorize` URL is retained only as a fallback and does not carry
the download URL.

Downloader accepts both HTTPS and plain HTTP download URLs. Plain HTTP support
is required for download servers that do not offer TLS, but HTTPS should be
preferred because HTTP traffic is not encrypted or authenticated.

Downloader also registers the `.torrent` document type with macOS. Opening a
downloaded torrent file from Finder therefore launches Downloader and begins
the BT file-selection flow.

If automatic capture or the context menu does not work after changing the
extension, confirm that website access is allowed, restart Safari or disable
and re-enable the extension, then reload the page.

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
