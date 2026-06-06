# Downloader Technical Documentation

這份文件是 `Downloader` 的深入技術說明，重點是幫你理解「功能在哪裡」、「代碼為什麼這樣拆」、「如果要修改，應該搜尋什麼」。

如果只是想快速知道專案怎樣 build、怎樣用，先看 `README.md`。

## Architecture

Downloader 採用 SwiftUI + manager + engine 的分層方式：

```text
SwiftUI UI
  -> DownloadManager
      -> HTTPDownloadEngine
      -> TorrentDownloadEngine
          -> TorrentSessionBridge
              -> libtorrent
```

UI 不直接操作 `URLSession` 或 libtorrent。畫面只呼叫 `DownloadManager`，由 manager 決定任務交給 HTTP engine 還是 BT engine。

| Layer | Main Files | Responsibility |
| --- | --- | --- |
| App | `Downloader/App/DownloaderApp.swift` | App entry, window, menu commands, lifecycle save |
| UI | `Downloader/UI/*.swift` | SwiftUI screens, toolbar, table, sheets |
| Core | `Downloader/Core/DownloadManager.swift` | Central app state and command routing |
| Model | `Downloader/Core/DownloadItem.swift` | Codable download task model |
| HTTP | `Downloader/HTTP/HTTPDownloadEngine.swift` | HTTP download, Range probing, segmented download |
| Torrent | `Downloader/Torrent/TorrentDownloadEngine.swift` | Swift-side BT flow and polling |
| Bridge | `Downloader/Torrent/TorrentSessionBridge.h/.mm` | Objective-C++ wrapper around C++ libtorrent |
| Persistence | `Downloader/Persistence/*.swift` | JSON task storage and security-scoped folder bookmarks |
| Notifications | `Downloader/Notifications/NotificationManager.swift` | Completion notification and sound |
| Safari Extension | `Downloader Safari Extension/*` | Automatic direct-download capture and context menu handoff |
| Browser Fallback | `Downloader/BrowserIntegration/URLSchemeHandler.swift` | Custom URL scheme parsing |

## DownloadItem

Location:

```text
Downloader/Core/DownloadItem.swift
```

`DownloadItem` is the saved model for each task.

Important fields:

- `id`: stable UUID used by table selection and engines.
- `name`: display name and output filename.
- `source`: HTTP URL, magnet link, or local `.torrent` URL.
- `destination`: selected download folder.
- `localFileURL`: completed file path, or BT output folder for multi-file torrents.
- `kind`: `.http` or `.torrent`.
- `status`: queued, downloading, paused, completed, failed, unavailable.
- `progress`: `0...1`.
- `bytesReceived` / `bytesExpected`: downloaded and total byte count.
- `bytesPerSecond`: live download speed.
- `uploadBytesPerSecond`: live BT upload speed.
- `averageBytesPerSecond`: final average download speed.
- `averageUploadBytesPerSecond`: final average BT upload speed.
- `activeDownloadDuration`: accumulated active download time after completion.
- `selectedTorrentFileIndexes`: saved BT file selection for resume after app restart.
- `selectedTorrentFilePaths`: saved BT relative file paths used by Delete with Files and display naming.
- `isTrashed`: soft-delete flag.
- `statusBeforeTrash`: original status used when restoring from Trash.
- `errorMessage`: error text, also reused for status details such as seeds/peers.

`DownloadItem` has a custom `Codable` decoder so older `downloads.json` files can still load after new fields are added.

## DownloadManager

Location:

```text
Downloader/Core/DownloadManager.swift
```

`DownloadManager` is the central controller.

It handles:

- `@Published var items`: the list displayed by SwiftUI.
- `selectedItemIDs`: current table selection.
- Adding new tasks.
- Pause / resume / delete / delete with files / restore.
- Routing tasks to HTTP or BT engines.
- Receiving engine progress callbacks.
- Completing tasks and calculating average speed.
- Showing BT file selection sheets.
- Saving task state to disk.

Task type is detected with:

```swift
let kind: DownloadKind = url.absoluteString.hasPrefix("magnet:")
    || url.pathExtension.lowercased() == "torrent"
    ? .torrent
    : .http
```

Meaning:

- `magnet:?xt=...` uses BT.
- `.torrent` uses BT.
- Everything else uses HTTP.

For a remote HTTP/HTTPS URL ending in `.torrent`, `DownloadManager` first
downloads the metadata to:

```text
~/Library/Application Support/Downloader/TorrentMetadata/<item-id>.torrent
```

The item's source is then replaced with that local file URL before
`TorrentDownloadEngine.start(item:)` calls libtorrent. This avoids passing an
HTTP URL to `startMagnet`.

### Progress Save Throttling

Download progress and speed can update many times per second. Saving `downloads.json` on every callback would cause unnecessary disk I/O.

Downloader uses two save styles:

- Important state changes save immediately: add, pause, complete, fail, delete, restore.
- High-frequency progress changes are merged by `scheduleSave()`.

Important methods:

```swift
private func scheduleSave()
func flushScheduledSave()
```

`scheduleSave()` waits about 750ms before writing JSON. Continuous progress updates cancel and reschedule the pending save.

`flushScheduledSave()` forces a save when the app becomes inactive/background or the main view disappears, so the last bit of progress is not lost when quitting.

### Delete with Files

`deleteSelectedWithFiles()` removes selected tasks from the list and moves related local files to macOS Trash.

The file candidates are inferred from the task type:

- HTTP: the completed file, `folder/item.name`, and matching `item.name.part-N.tmp` files.
- BT: selected torrent file paths, matching `.tmp` files, and the local output URL when available.

Before moving files, Downloader pauses the active engine while preserving incomplete files. After files are moved to Trash successfully, it cancels the engine state and removes the task from the list.

The trash operation prefers Finder automation:

```swift
delete POSIX file "<path>"
delay 0.15
```

Downloader sends each path to Finder one at a time and inserts a short delay between paths. This is closest to a normal Finder trash action and avoids several delete sounds playing on top of each other. If Finder automation fails, Downloader falls back to:

```swift
NSWorkspace.shared.recycle(...)
```

Because the file move is asynchronous, folder access uses the async `FolderBookmarkStore.withAccess(to:)` overload so security-scoped access remains active until the operation finishes.

## HTTP Download Flow

Location:

```text
Downloader/HTTP/HTTPDownloadEngine.swift
```

The HTTP engine supports immediate single-connection download and automatic segmented upgrade.

### Single Connection Start

When a HTTP task starts:

1. Create `filename.part-0.tmp` in the selected folder.
2. Start a `URLSessionDataTask`.
3. Stream incoming data directly to disk.
4. In parallel, probe Range support.

The app does not wait for Range probing before starting the download. This makes normal downloads begin faster.

### Range Probe

The probe sends:

```text
Range: bytes=0-0
```

If the response is `206 Partial Content`, the server supports byte ranges.

If the server supports Range and the file is large enough, Downloader can upgrade to segmented download.

### Segmented Download

Default setting:

```swift
private static let segmentedThreadCount = 4
private static let minimumSegmentedSize: Int64 = 8 * 1024 * 1024
```

If the single connection already downloaded bytes `0...A`, that file becomes part 0. The remaining bytes are split across the other connections:

```text
Part 0: bytes 0 ... A
Part 1: bytes A+1 ... B
Part 2: bytes B+1 ... C
Part 3: bytes C+1 ... end
```

Temporary files:

```text
filename.part-0.tmp
filename.part-1.tmp
filename.part-2.tmp
filename.part-3.tmp
```

When all segments finish, `mergeSegmentedDownload` joins them in index order and writes the final file.

The merge reads 1 MB chunks at a time so large files are not fully loaded into memory.

### Pause and Resume

Single connection resume:

- Check local `.part-0.tmp` file size.
- Send `Range: bytes=<existingBytes>-`.
- Append new data if the server returns `206`.
- Reset and restart if the server returns `200`.

Segmented resume:

- Each part knows its original byte range.
- Each part resumes from `range.lowerBound + received`.
- Only unfinished parts create new requests.

### Speed Calculation

The raw callback speed is noisy. Downloader samples roughly every 0.5 seconds and smooths it:

```swift
speed = oldSpeed * 0.7 + instantSpeed * 0.3
```

This keeps the speed column more readable.

Average speed and completed download time are based on active transfer time. Paused time is not counted. For HTTP downloads, active time is accumulated while the transfer request is running. For BT downloads, active payload timing starts after metadata is available and the user has selected files, so metadata discovery and file-selection waiting time are not counted as payload download time.

## Torrent Download Flow

Swift engine:

```text
Downloader/Torrent/TorrentDownloadEngine.swift
```

Objective-C++ bridge:

```text
Downloader/Torrent/TorrentSessionBridge.h
Downloader/Torrent/TorrentSessionBridge.mm
```

### Why Objective-C++ Bridge Is Needed

Normal Swift files cannot directly call C++ libtorrent APIs. The bridge exposes a small Objective-C API that Swift can import:

```text
Swift -> Objective-C header -> Objective-C++ .mm -> C++ libtorrent
```

### Magnet Start

When starting a magnet:

- Parse magnet URI.
- Set save path.
- Enable DHT, LSD, UPnP, NAT-PMP.
- Add public trackers.
- Start in `upload_mode`.
- Force tracker / DHT / LSD announce.

`upload_mode` lets libtorrent find metadata and peers while avoiding real payload download before the user selects files.

### Metadata and File Selection

Magnet links do not initially contain the file list. Downloader polls libtorrent every 0.25 seconds:

- No metadata: show `Finding metadata`.
- Metadata found: read file list.
- Apply `.tmp` names to incomplete BT files.
- Show `TorrentFileSelectionSheet`.
- Set all file priorities to `dont_download` while waiting for user choice.

After the user clicks `Start Selected Files`:

- Selected files get `default_priority`.
- Unselected files stay `dont_download`.
- `upload_mode` is cleared.
- The torrent resumes and reannounces.

### BT Speed Display

libtorrent exposes:

- `download_rate`: includes metadata, DHT, handshakes, and protocol traffic.
- `download_payload_rate`: real file payload speed.

Downloader displays `download_payload_rate`, so metadata discovery traffic does not look like real file download speed.

For active BT downloads, the Speed column shows download speed and upload speed on two lines:

```text
↓ 12.4 MiB/s
↑ 512 KiB/s
```

After completion, the same column shows average download and upload speeds:

```text
Avg ↓ 12.4 MiB/s
Avg ↑ 512 KiB/s
```

The completed torrent remains in the libtorrent session and continues seeding.
While seeding, the Speed column adds the current upload speed:

```text
Avg ↓ 12.4 MiB/s
Avg ↑ 512 KiB/s
Now ↑ 128 KiB/s
```

The Status column shows:

```text
Completed | Seeding
```

Pause keeps the item in the Completed category, stops the torrent session, and
removes the current upload-speed line. Resume starts seeding again. The original
average speeds and active download duration are not recalculated, and the
completion notification is not sent again.

`DownloadItem.isTorrentSeeding` records whether the completed BT item currently
has an enabled seeding session. It does not mean payload is currently being
uploaded. The Status column reflects the current libtorrent state:

```text
Starting
Checking - peers 0, candidates 4
Finding metadata - peers 2, candidates 6
Completed | Waiting for peers - peers 0, candidates 3
Completed | Seeding
```

`Completed | Seeding` is shown only when `upload_payload_rate` is greater than
zero. A ready torrent with no requesting peer shows
`Completed | Waiting for peers` instead.

When a completed torrent resumes, Downloader reapplies the saved file
priorities. Older tasks without saved indexes use all torrent files. Polling
also checks libtorrent's paused flag and wakes the handle again when necessary.
While waiting for peers, Downloader reannounces to trackers, DHT, and LSD every
10 seconds.

Because a libtorrent handle cannot survive an app process restart, completed BT
items load as non-seeding and can be restarted with Resume.

## File Naming

HTTP incomplete:

```text
filename.part-0.tmp
filename.part-1.tmp
filename.part-2.tmp
filename.part-3.tmp
```

HTTP completed:

```text
filename
```

BT incomplete:

```text
originalName.tmp
```

BT completed:

```text
originalName
```

## Sandbox and Folder Access

Location:

```text
Downloader/Persistence/FolderBookmarkStore.swift
```

macOS sandbox apps cannot freely write to arbitrary user folders. When the user chooses a folder with `NSOpenPanel`, Downloader stores a security-scoped bookmark.

Later file operations are wrapped with:

```swift
FolderBookmarkStore.withAccess(to: folder) {
    // file operations
}
```

`startAccessingSecurityScopedResource()` and `stopAccessingSecurityScopedResource()` must be balanced. The code uses `defer` so access is released even if file operations throw an error.

Fallback folder:

```text
~/Downloads
```

## Persistence

Location:

```text
Downloader/Persistence/DownloadStore.swift
```

Downloaded task state is stored here:

```text
~/Library/Application Support/Downloader/downloads.json
```

On app restart, old `.downloading` tasks are restored as `.paused`, because URLSession tasks and libtorrent handles from the previous process no longer exist.

## Notifications

Location:

```text
Downloader/Notifications/NotificationManager.swift
```

When a download finishes:

- `NSSound.beep()` plays a system sound.
- A local notification is posted:

```text
Download Complete
<filename>
```

The app also implements notification delegate methods so foreground notifications can still show a banner and so clicking a notification brings the existing window forward.

If macOS Focus / Do Not Disturb is enabled, the system may suppress banners or sounds. That is system behavior.

## UI Code Guide

### App Entry

Location:

```text
Downloader/App/DownloaderApp.swift
```

Creates the main window:

```swift
Window("Downloader", id: "main") {
    ContentView()
        .environmentObject(downloadManager)
        .frame(minWidth: 980, minHeight: 620)
}
```

Important points:

- `@StateObject private var downloadManager`: one manager for the whole app.
- `.environmentObject(downloadManager)`: passes it to child views.
- `@Environment(\.scenePhase)`: detects active/inactive/background state.
- `.commands`: adds menu commands and keyboard shortcuts.

### Main Screen and Toolbar

Location:

```text
Downloader/UI/ContentView.swift
```

Toolbar buttons call:

```swift
downloadManager.resumeSelected()
downloadManager.pauseSelected()
downloadManager.deleteSelected()
downloadManager.restoreSelectedFromTrash()
```

Tooltips use:

```swift
.help("Resume")
```

### Sidebar

Location:

```text
Downloader/UI/SidebarView.swift
```

Categories are defined in `DownloadFilter`:

```swift
case all = "All"
case active = "Active"
case paused = "Paused"
case completed = "Completed"
case trash = "Trash"
```

### Downloads Table

Location:

```text
Downloader/UI/DownloadsListView.swift
```

Table columns:

```swift
TableColumn("Name")
TableColumn("Speed")
TableColumn("ETA")
TableColumn("Status")
```

Column widths use:

```swift
.width(min: 380, ideal: 560)
```

Meaning:

- `min`: minimum width.
- `ideal`: preferred width when there is enough room.

Current column widths:

```swift
Name:   .width(min: 380, ideal: 560)
Speed:  .width(min: 30, ideal: 60)
ETA:    .width(min: 25, ideal: 30)
Status: .width(min: 150, ideal: 260)
```

`Status` receives more horizontal space so BT peer details such as seeds, peers,
and connection candidates remain visible. `Speed` and `ETA` are narrower
because their values use compact, predictable formats.

`File Size` is displayed by `DownloadItem.fileSizeText`:

- `bytesExpected > 0`: downloaded size / total expected size.
- `bytesReceived > 0`: downloaded size / `-` when total size is not known yet.
- Otherwise: `-`.

`ETA` is displayed by `DownloadItem.downloadTimeText`:

- Downloading: estimated remaining time from remaining bytes and current speed.
- Completed: accumulated active download time.
- Paused, queued, failed, or unavailable: `-`.

The table is wrapped in a horizontal `ScrollView`:

```swift
ScrollView(.horizontal) {
    Table(...)
        .frame(width: max(geometry.size.width, minimumTableWidth))
}
```

If the window is too narrow, a horizontal scrollbar appears.

### Name Column Progress Summary

Progress UI:

```swift
HStack(spacing: 6) {
    ProgressView(value: item.progress)
        .frame(maxWidth: .infinity)

    Text(item.percentText)
        .frame(width: 35, alignment: .trailing)

    Text(item.fileSizeText)
}
```

`item.progress` is `0...1`.

`percentText` converts it to:

```text
0%
50%
100%
```

### Single Click, Multi-Select, Double Click

Row behavior is centralized in:

```text
rowInteraction(for:downloadManager:focusTable:)
```

Behavior:

- Normal click: select one item.
- Command-click: keep native macOS multi-select.
- Shift-click: keep native range selection.
- Double-click: show in Finder.
- Right-click: context menu.

Selection rules are implemented in `DownloadManager.selectForRowClick(_:visibleIDs:)`, which reads current modifier flags and applies normal, Command-click, and Shift-click selection behavior.

The table is focusable so selected rows use the active selection color. The visible focus ring is disabled with `.focusEffectDisabled()` to avoid the blue focus outline around the table.

### Right-Click Menu

Right-click menu uses:

```swift
.contextMenu {
    Button { downloadManager.resumeSelected() } label: { ... }
    Button { downloadManager.pauseSelected() } label: { ... }
    Button { downloadManager.deleteSelected() } label: { ... }
    Button { downloadManager.deleteSelectedWithFiles() } label: { ... }
}
```

Before actions, it calls:

```swift
downloadManager.selectForContextMenu(item)
```

Meaning:

- If the right-clicked row is already selected, keep the full multi-selection.
- If it is not selected, select only that row.

### Add Download Sheet

Location:

```text
Downloader/UI/AddDownloadSheet.swift
```

Important UI:

```swift
TextField("URL or magnet link", text: $urlText)
Button("Add") { addDownload() }
Button { chooseTorrentFile() } label: { ... }
Button { chooseDestination() } label: { ... }
```

The final action calls:

```swift
downloadManager.add(url: url, destination: destination)
```

### Torrent File Selection Sheet

Location:

```text
Downloader/UI/TorrentFileSelectionSheet.swift
```

It stores selected file indexes in:

```swift
@State private var selectedIndexes: Set<Int>
```

The checkbox uses `Binding<Bool>` because each toggle needs true/false, while the app stores a set of selected file indexes.

## Safari Extension and URL Handoff

Downloader uses a native Safari App Extension for automatic direct-download
capture and right-click downloads.

```text
Downloader Safari Extension/Info.plist
Downloader Safari Extension/Resources/content.js
Downloader Safari Extension/SafariWebExtensionHandler.swift
Downloader/UI/ContentView.swift
```

### Automatic Capture

`SettingsView` stores `automaticallyCaptureSafariDownloads` in the shared App
Group `UserDefaults`. It defaults to enabled.

When a page loads, `content.js` uses
`safari.extension.dispatchMessage(...)` to ask the native extension handler for
the setting. If enabled, the capture-phase click listener recognizes:

- Links with a `download` attribute.
- `magnet:` links.
- HTTP/HTTPS links ending in common downloadable file extensions, including
  `.torrent`.
- Torrent links and buttons identified by `application/x-bittorrent`, a
  `.torrent` filename, torrent labels, or torrent-related data attributes.

Eligible clicks are cancelled before Safari starts its own navigation, then sent
to `SafariWebExtensionHandler` with the `auto-capture-download` message through
the same injected-script messaging API. The message includes an explicit
`torrent` kind when the page identifies a torrent whose endpoint URL has no
`.torrent` suffix.

Ambiguous HTTP/HTTPS endpoints whose path contains `/file/` or `/download` use
the `probe-download` message. The native extension sends a GET request with:

```http
Range: bytes=0-0
```

It checks `Content-Type` and `Content-Disposition` without downloading the
whole file. A `.torrent` filename or `application/x-bittorrent` response is
queued as BT and opens Downloader. Otherwise `download-probe-result` tells the
injected script to continue the original Safari navigation. The probe has a
10-second timeout.

Because the probe runs inside the sandboxed Safari App Extension, the extension
entitlements include `com.apple.security.network.client`. Probe failures and
response status/header details are logged through `os_log` for diagnosis.

This deliberately does not intercept every link. Downloads generated through
JavaScript, forms, authenticated POST requests, or `blob:` URLs cannot be
reconstructed safely from a normal anchor URL and should use Safari or the
right-click fallback.

### Native Context Menu Flow

`Info.plist` declares:

- `NSExtensionPointIdentifier`: `com.apple.Safari.extension`
- `SFSafariContextMenu`: command `download-link`
- `SFSafariContentScript`: `content.js`
- `SFSafariWebsiteAccess`: all websites

`content.js` runs on page context menu events:

```javascript
document.addEventListener("contextmenu", (event) => {
  const link = event.target.closest("a[href]");
  safari.extension.setContextMenuEventUserInfo(event, {
    url: link ? link.href : ""
  });
}, false);
```

Automatic capture and `Download with Downloader` both call the same queue
method. Queue entries contain the URL and an optional download kind; the reader
also accepts the previous string-only queue format. `SafariWebExtensionHandler`:

1. Reads `userInfo["url"]`.
2. Appends the link to the App Group file:

```text
group.com.sunnyyu.Downloader/pending-safari-downloads.json
```

3. Posts distributed notification:

```swift
Notification.Name("com.sunnyyu.Downloader.addDownload")
```

The distributed notification uses `object: nil`. The URL is not passed through the notification object because that previously caused tagged pointer / `count` crashes in Safari extension IPC. The App Group queue is the source of truth.

The main app listens in `ContentView`, then `flushPendingSafariDownloads()`:

1. Opens the App Group queue.
2. Decodes pending links.
3. Clears the queue.
4. Adds each valid URL using the last selected download folder.
5. Brings Downloader to the foreground.

The extension derives the containing `Downloader.app` URL from its `.appex`
bundle path and calls `NSWorkspace.openApplication`. If that fails, it falls
back to `downloader://authorize`. The actual download URL remains in the App
Group queue.

### URL Scheme Fallback

Downloader still contains the custom URL scheme parser:

```text
Downloader/BrowserIntegration/URLSchemeHandler.swift
```

Supported URL format:

```text
downloader://add?url=https%3A%2F%2Fexample.com%2Ffile.zip
```

`URLComponents` parses the query string, extracts `url`, and converts it back to `URL`.

Safari download URLs do not travel through this path. This avoids putting the
source URL in a custom-scheme navigation; only the fixed `authorize` URL is used
to activate Downloader.

### `.torrent` Document Registration

`Downloader/Info.plist` registers `org.bittorrent.torrent`, the `.torrent`
filename extension, and `application/x-bittorrent`. Finder and LaunchServices
can therefore launch Downloader with a local torrent file. `AppDelegate` passes
the file URL to `ContentView`, which starts the normal BT import flow.

Safari must grant the extension website access before `content.js` can run.
After changing the extension or its permission, reload the affected page.

Safari Extension development can leave stale extension builds in DerivedData. Clean only when Safari shows duplicate or old extensions:

```zsh
rm -rf ~/Documents/Xcode/Downloader/Build/DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/Downloader-fkmjpusihrlgzaeuymdzbrsrgavk
```

## Common Xcode Debug Area Messages

Most of these are system logs, not app bugs.

| Message | Meaning | Usually Fix? |
| --- | --- | --- |
| `DetachedSignatures` | macOS signature database lookup | No |
| `Unable to obtain a task name port right` | debugger/system permission limitation | No |
| `nw_endpoint_flow_failed_with_error 127.0.0.1` | local loopback connection log | Only investigate if downloads fail |
| `ViewBridge to RemoteViewService Terminated` | system panel or remote view closed | No |
| `NSXPCDecoder validateAllowedClass` | Apple framework secure coding warning | Usually no |
| `Failed to send CA Event` | CoreAnalytics debug log | No |

## Test URLs

### Hetzner

```text
https://ash-speed.hetzner.com/
https://ash-speed.hetzner.com/100MB.bin
```

### httpbin

```text
https://httpbin.org/bytes/<bytes>
https://httpbin.org/stream-bytes/<bytes>
```

Common sizes:

| Size | Bytes | URL |
| --- | ---: | --- |
| 1 KB | 1,024 | `https://httpbin.org/bytes/1024` |
| 1 MB | 1,048,576 | `https://httpbin.org/bytes/1048576` |
| 10 MB | 10,485,760 | `https://httpbin.org/bytes/10485760` |
| 100 MB | 104,857,600 | `https://httpbin.org/bytes/104857600` |

## Column Width Reference

Long Status examples:

```text
Downloading - seeds 123, peers 456, candidates 789
Finding metadata - peers 123, candidates 456
Preparing selected files - seeds 123, peers 456, candidates 789
Waiting for file selection
Unable to create incomplete file
Retrying connection 3/3
Failed: <error message>
Not Available: <error message>
```

Long Speed examples:

```text
↓ 12.4 MiB/s
↑ 512 KiB/s
Avg ↓ 12.4 MiB/s
Avg ↑ 512 KiB/s
Avg 999.9 MiB/s
Avg 1.0 GiB/s
999.9 MiB/s
1.0 GiB/s
-
```

ETA examples:

```text
12s
3m 20s
1h 5m
-
```

Name progress summary examples:

```text
42% 12.4 MiB / 100 MiB
100% 1.0 GiB / 1.0 GiB
0% -
```

The wider Status column displays more BT peer information before truncation.
Error messages can still exceed the available width, so the full text remains
available through tooltip/help.
