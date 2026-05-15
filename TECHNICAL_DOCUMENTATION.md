# Downloader 技術文件

這份文件用來解釋 `Downloader` App 的功能、架構和主要程式碼。目標是讓你不只知道「哪個檔案做甚麼」，也理解為甚麼要這樣拆。

## 功能介紹

`Downloader` 是一個 macOS SwiftUI 下載器，方向類似 Folx：

- 支援一般 HTTP/HTTPS 下載。
- 支援 HTTP Range 分段下載，大檔案可用 4 條連線同時下載。
- 支援暫停、繼續、刪除下載任務。
- 支援 magnet / BT 下載，透過內嵌 `libtorrent-rasterbar.xcframework`，使用者不需要另外安裝 libtorrent。
- BT 找到 metadata 後，可以選擇 torrent 內要下載的檔案。
- 未完成檔案會直接顯示在使用者選擇的資料夾，並使用 `.tmp` 或 `.part-N.tmp` 名稱。
- 下載完成後會顯示平均下載速度，並發送 macOS 系統通知。
- 下載資料夾會被記住，下次新增下載時自動使用上次選擇的位置。

## 整體架構

App 分成幾層：

| 層級 | 主要檔案 | 職責 |
| --- | --- | --- |
| App 入口 | `DownloaderApp.swift` | 建立主視窗、注入 `DownloadManager`、設定選單 |
| UI | `ContentView.swift`, `DownloadsListView.swift`, `AddDownloadSheet.swift`, `TorrentFileSelectionSheet.swift` | 顯示畫面、處理使用者操作 |
| 狀態管理 | `DownloadManager.swift` | 保存下載列表、分派任務、接收 engine 回報 |
| HTTP engine | `HTTPDownloadEngine.swift` | 一般下載、Range 探測、分段下載、暫停續傳 |
| BT engine | `TorrentDownloadEngine.swift` | Swift 層 BT 流程、metadata 輪詢、選檔案邏輯 |
| libtorrent bridge | `TorrentSessionBridge.h/.mm` | Objective-C++ 包裝 C++ libtorrent API |
| 持久化 | `DownloadStore.swift`, `FolderBookmarkStore.swift` | 保存下載列表、保存 sandbox 資料夾權限 |
| 通知 | `NotificationManager.swift` | 下載完成通知 |

大概流程是：

```text
SwiftUI UI
  -> DownloadManager
      -> HTTPDownloadEngine
      -> TorrentDownloadEngine
          -> TorrentSessionBridge
              -> libtorrent
```

UI 不直接碰 URLSession 或 libtorrent。它只呼叫 `DownloadManager`，這樣畫面會比較乾淨。

## 下載資料模型

核心 model 在 `Downloader/Core/DownloadItem.swift`。

`DownloadItem` 代表一個下載任務，包含：

- `id`：任務唯一識別。
- `name`：列表顯示名稱。
- `source`：下載來源 URL 或 magnet link。
- `destination`：使用者選擇的下載資料夾。
- `kind`：`http` 或 `torrent`。
- `status`：queued、downloading、paused、completed、failed 等。
- `progress`：0 到 1 的進度。
- `bytesReceived` / `bytesExpected`：已下載和總大小。
- `bytesPerSecond`：即時速度。
- `averageBytesPerSecond`：完成後平均速度。
- `errorMessage`：失敗訊息，也會用來顯示 BT peer/seed 狀態。

`DownloadItem` 有自訂 `Codable` 解碼，是為了向下兼容。日後新增欄位時，舊版 `downloads.json` 沒有新欄位也可以正常載入。

## DownloadManager

`Downloader/Core/DownloadManager.swift` 是 App 的中央控制器。

它負責：

- 保存 `items`，讓 SwiftUI 列表自動更新。
- 記住目前選中的下載項目。
- 新增下載時判斷是 HTTP 還是 BT。
- 暫停、繼續、刪除目前選中的任務。
- 接收 HTTP / BT engine 的進度回報。
- 完成後計算平均速度。
- BT metadata 找到後，觸發檔案選擇 sheet。

新增下載的核心判斷：

```swift
let kind: DownloadKind = url.absoluteString.hasPrefix("magnet:") || url.pathExtension == "torrent" ? .torrent : .http
```

這代表：

- `magnet:?xt=...` 交給 BT。
- `.torrent` 檔案預留給 BT。
- 其他 URL 交給 HTTP。

## HTTP 下載流程

HTTP engine 在 `Downloader/HTTP/HTTPDownloadEngine.swift`。

### 1. 立即開始並背景探測 Range

建立 HTTP 任務後，App 會立即用單連線串流下載到 `filename.tmp`，不再先等 Range 探測完成。

同時，App 會在背景送出：

```text
Range: bytes=0-0
```

如果 server 回傳 `206 Partial Content`，代表支援 Range。App 就可以把大檔案切成多段。

如果 server 不支援 Range，或檔案小於 8 MB，就保持單連線下載。

### 2. 單連線下載

單連線使用 `URLSessionDataTask`。

優點：

- 可以一建立任務就立即開始下載。
- App 可以直接把資料寫入使用者資料夾內的 `.tmp`。
- 暫停後可根據 `.tmp` 檔案大小，用 HTTP Range 接續下載。
- 完成後再把 `.tmp` 改成正式檔名。

App 也會先建立一個 `filename.tmp` placeholder，讓使用者在 Finder 中看到未完成下載。

### 3. 分段下載

大檔案且支援 Range 時，App 會把「已經下載好的前段」當成第一段，然後把未下載的尾段切成多條連線：

```text
Part 0: bytes 0 ... A
Part 1: bytes A+1 ... B
Part 2: bytes B+1 ... C
Part 3: bytes C+1 ... end
```

每段會寫入：

```text
filename.part-0.tmp
filename.part-1.tmp
filename.part-2.tmp
filename.part-3.tmp
```

全部完成後，`mergeSegmentedDownload` 會依 index 順序合併成正式檔案，然後刪除分段 `.tmp`。

### 4. HTTP threads / connections 設定位置

HTTP 分段下載的連線數在這個檔案設定：

```text
Downloader/HTTP/HTTPDownloadEngine.swift
```

搜尋關鍵字：

```swift
segmentedThreadCount
```

目前會看到類似：

```swift
private static let segmentedThreadCount = 4
```

這個 `4` 就是一般 HTTP 分段下載最多使用的 threads / connections 數量。

如果改成：

```swift
private static let segmentedThreadCount = 8
```

代表支援 Range 的大檔案最多會切成 8 段下載。

不過，不是越多 threads 越快。一般建議：

| Connections | 建議 |
| ---: | --- |
| 1 | 最穩定，但不能加速 |
| 4 | 建議預設值，速度和穩定性較平衡 |
| 8 | 大檔案可能更快，但較容易波動 |
| 16 或以上 | 通常不建議，可能被 server 限速或連線失敗 |

是否真的可以多線下載，仍然取決於 server 是否支援 HTTP `Range`。如果 server 不支援 Range，即使 `segmentedThreadCount` 設成 8，Downloader 也只能用 1 條 connection 下載。

### 5. 速度計算

下載速度不是每次 callback 都直接顯示，因為會跳得很亂。App 每 0.5 秒取樣一次，並用簡單加權平均平滑：

```swift
speed = oldSpeed * 0.7 + instantSpeed * 0.3
```

## BT 下載流程

BT Swift engine 在 `Downloader/Torrent/TorrentDownloadEngine.swift`，libtorrent bridge 在 `Downloader/Torrent/TorrentSessionBridge.mm`。

### 1. 為甚麼需要 Objective-C++ bridge

Swift 一般 `.swift` 檔不能直接呼叫 C++ libtorrent API，所以用 `.mm` Objective-C++ 檔案包一層：

```text
Swift -> Objective-C header -> Objective-C++ implementation -> C++ libtorrent
```

Swift 只看到 `TorrentSessionBridge` 的 Objective-C 方法，不需要知道 C++ 型別。

### 2. Magnet 開始時

`startMagnet` 會：

- 解析 magnet URI。
- 設定保存資料夾。
- 啟用 DHT、LSD、UPnP、NAT-PMP。
- 加入一些公開 tracker。
- 使用 `upload_mode`，讓 libtorrent 可以找 metadata/peer，但盡量不下載真正檔案 payload。
- 立即 reannounce tracker / DHT / LSD。

### 3. 找到 metadata 後選檔案

magnet 一開始不知道 torrent 內有哪些檔案，必須先找到 metadata。

`TorrentDownloadEngine` 每 0.25 秒 poll 一次狀態：

- 還沒有 metadata：顯示 Finding metadata，定期 reannounce。
- 有 metadata：讀出檔案列表，彈出 `TorrentFileSelectionSheet`。
- 等待選檔案時：所有檔案 priority 設為 `dont_download`。

這樣使用者未選檔案前，不應該正式下載檔案內容。

### 4. 真正開始下載

使用者按 `Start Selected Files` 後：

- 選中的檔案 priority 設為 `default_priority`。
- 未選中的檔案 priority 設為 `dont_download`。
- 解除 `upload_mode`。
- 手動 resume torrent。
- 重新 announce tracker / DHT / LSD。

### 5. BT 速度顯示

libtorrent 有兩種速度：

- `download_rate`：包含 protocol chatter，例如 metadata、DHT、peer handshake。
- `download_payload_rate`：真正檔案 payload 速度。

App 使用 `download_payload_rate` 顯示速度，所以未選檔案前找 metadata 的少量網絡流量不會被顯示成下載速度。

## 檔案命名策略

HTTP 單連線：

```text
filename.tmp
filename
```

HTTP 分段：

```text
filename.part-0.tmp
filename.part-1.tmp
filename.part-2.tmp
filename.part-3.tmp
filename
```

BT：

```text
originalName.tmp
originalName
```

BT 完成後會透過 libtorrent `rename_file` 還原原本檔名。

## Sandbox 與資料夾權限

macOS sandbox app 不能任意寫入使用者資料夾。

當使用者按 `Choose Folder` 時，App 用 `NSOpenPanel` 讓使用者選資料夾，然後 `FolderBookmarkStore` 保存 security-scoped bookmark。

之後下載時，檔案操作都包在：

```swift
FolderBookmarkStore.withAccess(to: folder) {
    // file operations
}
```

這樣 App 才有權限在該資料夾建立和移動檔案。

## UI 檔案解說

`ContentView.swift`

- 主畫面。
- 建立 `NavigationSplitView`。
- 左邊是 `SidebarView`。
- 右邊是 `DownloadsListView`。
- toolbar 提供新增、開始、暫停、刪除。
- 負責彈出新增下載 sheet 和 BT 檔案選擇 sheet。

`DownloadsListView.swift`

- 使用 macOS `Table` 顯示任務。
- 顯示名稱、進度、狀態、速度。
- 根據 sidebar filter 篩選項目。

`AddDownloadSheet.swift`

- 輸入 URL 或 magnet link。
- 選擇下載資料夾。
- 儲存最後選擇的資料夾。
- 呼叫 `downloadManager.add(...)`。

`TorrentFileSelectionSheet.swift`

- 顯示 BT 檔案列表。
- 支援全選、取消全選。
- 用 checkbox 決定要下載哪些檔案。

## 常見 UI 代碼位置導覽

這一段是給初學者用的「地圖」。如果你想改某個按鈕、欄位或畫面，先看這裡，再去對應檔案搜尋關鍵字。

### 主視窗入口

位置：`Downloader/App/DownloaderApp.swift`

這個檔案負責建立 App 主視窗：

```swift
Window("Downloader", id: "main") {
    ContentView()
        .environmentObject(downloadManager)
        .frame(minWidth: 980, minHeight: 620)
}
```

重點：

- `Window("Downloader", id: "main")`：建立 macOS 視窗，標題是 `Downloader`。
- `ContentView()`：主畫面從這裡開始。
- `.environmentObject(downloadManager)`：把同一個 `DownloadManager` 傳給所有子畫面使用。
- `.frame(minWidth:minHeight:)`：設定 App 視窗最小大小。

如果想改 App 最小視窗大小，就改 `.frame(minWidth: 980, minHeight: 620)`。

### 上方工具列按鈕

位置：`Downloader/UI/ContentView.swift`

搜尋關鍵字：`toolbar`

工具列按鈕在這段：

```swift
.toolbar {
    ToolbarItemGroup {
        Button {
            showingAddDownload = true
        } label: {
            Label("Add Download", systemImage: "plus")
        }
        .help("Add Download")
    }
}
```

一個 SwiftUI button 通常分兩部分：

```swift
Button {
    // 按下去後做甚麼
} label: {
    // 按鈕外觀顯示甚麼
}
```

例子：

- `showingAddDownload = true`：打開新增下載視窗。
- `downloadManager.resumeSelected()`：繼續目前選中的下載。
- `downloadManager.pauseSelected()`：暫停目前選中的下載。
- `downloadManager.deleteSelected()`：刪除目前選中的下載。
- `.help("Resume")`：滑鼠停在按鈕上時顯示 tooltip。
- `.disabled(...)`：條件成立時按鈕變灰，不能按。

### 左側分類 Sidebar

位置：`Downloader/UI/SidebarView.swift`

搜尋關鍵字：`DownloadFilter`

左邊 `All`、`Active`、`Paused`、`Completed`、`Trash` 是由 enum 定義：

```swift
enum DownloadFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case active = "Active"
    case paused = "Paused"
    case completed = "Completed"
    case trash = "Trash"
}
```

如果想改左側分類名稱，例如把 `Trash` 改成其他文字，就改 `case trash = "Trash"`。

每個分類的圖示在 `systemImage`：

```swift
case .trash: "trash"
```

這裡使用的是 Apple SF Symbols 名稱。

### Table 和 Column

位置：`Downloader/UI/DownloadsListView.swift`

搜尋關鍵字：`TableColumn`

下載列表是這段：

```swift
Table(items, selection: $downloadManager.selectedItemIDs) {
    TableColumn("Name") { item in
        ...
    }

    TableColumn("Progress") { item in
        ...
    }

    TableColumn("Status") { item in
        ...
    }

    TableColumn("Speed") { item in
        ...
    }
}
```

重點：

- `Table(...)`：macOS 表格。
- `items`：目前要顯示的下載項目。
- `selection`：目前選中的項目。
- `TableColumn("Name")`：建立一個欄位，欄位標題是 `Name`。
- `{ item in ... }`：每一行都會拿到一個 `DownloadItem`，然後決定這一格顯示甚麼。

目前有四個欄：

| 欄位 | 代碼位置 | 顯示內容 |
| --- | --- | --- |
| Name | `TableColumn("Name")` | 檔名、來源 URL、HTTP/BT 圖示 |
| Progress | `TableColumn("Progress")` | 進度條和百分比 |
| Status | `TableColumn("Status")` | 下載狀態、錯誤、BT seeds/peers |
| Speed | `TableColumn("Speed")` | 即時速度或平均速度 |

### Table 欄位闊度

位置：`Downloader/UI/DownloadsListView.swift`

搜尋關鍵字：`.width`

每個欄位後面都有 `.width(...)`：

```swift
.width(min: 260, ideal: 420)
```

意思：

- `min`：最小闊度，視窗很窄時盡量不要低過這個值。
- `ideal`：理想闊度，空間足夠時 SwiftUI 會偏向這個闊度。

例子：

```swift
TableColumn("Status") { item in
    Text(item.statusText)
}
.width(min: 350, ideal: 410)
```

如果想讓 `Status` 欄更闊，就增加 `min` 或 `ideal`。

### Status 和 Speed 可能較長的文字

調整 `Status` 和 `Speed` 欄寬時，可以用下面文字作參考。

Status 可能較長的顯示文字：

```text
Downloading - seeds 123, peers 456, candidates 789（用 macOS 系統字體約 13pt 量度，文字本身闊度大約是 322.7 pt）
Finding metadata - peers 123, candidates 456
Preparing selected files - seeds 123, peers 456, candidates 789
Waiting for file selection
Unable to create incomplete file
single connection （用 macOS 系統字體約 13pt 量度，文字本身闊度大約是 106.75 pt）
Retrying connection 3/3
Complete （用 macOS 系統字體約 13pt 量度，文字本身闊度大約是 58.39 pt）
Failed: <錯誤訊息>
Not Available: <錯誤訊息>
```

注意：`Failed: <錯誤訊息>` 和 `Not Available: <錯誤訊息>` 後面的錯誤訊息沒有固定長度，實際可能超過欄位闊度。這類文字適合截斷，再用 tooltip 顯示完整內容。

Speed 可能較長的顯示文字：

```text
Avg 999.9 MiB/s（用 macOS 系統字體約 13pt 量度，文字本身闊度大約是 98.89 pt）
Avg 1.0 GiB/s
999.9 MiB/s
1.0 GiB/s（用 macOS 系統字體約 13pt 量度，文字本身闊度大約是 52.45 pt）
-
```

Speed 文字由 `ByteCountFormatter` 產生，實際單位可能是 `KiB/s`、`MiB/s` 或 `GiB/s`。

### 水平捲動條

位置：`Downloader/UI/DownloadsListView.swift`

搜尋關鍵字：`ScrollView(.horizontal)`

Table 外面包了水平 `ScrollView`：

```swift
ScrollView(.horizontal) {
    Table(...)
        .frame(width: max(geometry.size.width, minimumTableWidth))
}
```

意思：

- `ScrollView(.horizontal)`：內容太闊時，可以左右捲動。
- `minimumTableWidth`：Table 最小總闊度。
- `max(geometry.size.width, minimumTableWidth)`：Table 闊度取「目前畫面闊度」和「最小總闊度」中較大的那個。

這樣做的目的：

- 視窗夠闊時：Table 剛好填滿，不留右側空白。
- 視窗太窄時：Table 保持最小闊度，底部出現水平 scrollbar。

### 進度條和百分比

位置：`Downloader/UI/DownloadsListView.swift`

搜尋關鍵字：`ProgressView`

進度條在 `Progress` column 裡：

```swift
ProgressView(value: item.progress)
```

百分比文字在旁邊：

```swift
Text(item.percentText)
```

`item.progress` 是 `0...1`：

```text
0.0 = 0%
0.5 = 50%
1.0 = 100%
```

百分比轉換在同一個檔案底部：

```swift
private extension DownloadItem {
    var percentText: String {
        let percentage = min(max(progress, 0), 1) * 100
        return "\(Int(percentage.rounded()))%"
    }
}
```

### 右鍵選單

位置：`Downloader/UI/DownloadsListView.swift`

搜尋關鍵字：`contextMenu`

右鍵選單在 `rowInteraction(...)` 裡：

```swift
.contextMenu {
    Button {
        downloadManager.resumeSelected()
    } label: {
        Label("Resume", systemImage: "play.fill")
    }

    Button {
        downloadManager.pauseSelected()
    } label: {
        Label("Pause", systemImage: "pause.fill")
    }

    Button(role: .destructive) {
        downloadManager.deleteSelected()
    } label: {
        Label("Delete", systemImage: "trash")
    }
}
```

重點：

- `.contextMenu`：右鍵時彈出的選單。
- `Button(role: .destructive)`：危險操作，例如刪除，系統會用比較警告的樣式。
- `Label("Resume", systemImage: "play.fill")`：文字加圖示。

### 單擊、雙擊和焦點

位置：`Downloader/UI/DownloadsListView.swift`

搜尋關鍵字：`rowInteraction`

每一個 cell 都套用：

```swift
.rowInteraction(for: item, downloadManager: downloadManager, focusTable: focusTable)
```

這個 helper 集中處理：

- 單擊：選中該下載項目。
- 雙擊：用 Finder 顯示下載位置。
- 右鍵：顯示 context menu。
- 焦點：讓 Table selection 變成藍色，而不是灰色。

相關代碼：

```swift
.simultaneousGesture(
    TapGesture(count: 1).onEnded {
        focusTable()
        downloadManager.selectForSingleClick(item)
    }
)
.onTapGesture(count: 2) {
    focusTable()
    downloadManager.showInFinder(item)
}
```

### 新增下載視窗

位置：`Downloader/UI/AddDownloadSheet.swift`

搜尋關鍵字：`AddDownloadSheet`

這個檔案負責「新增下載」彈出視窗。

常見代碼：

```swift
TextField("URL or magnet link", text: $urlText)
```

這是輸入 URL / magnet 的文字框。

```swift
Button("Choose Folder") {
    chooseFolder()
}
```

這是選擇下載資料夾的按鈕。

```swift
Button("Add") {
    addDownload()
}
```

這是建立下載任務的按鈕。

最後會呼叫：

```swift
downloadManager.add(url: url, destination: destination)
```

意思是：把 URL 和下載資料夾交給 `DownloadManager`，由它決定用 HTTP 還是 BT engine。

### BT 選擇檔案視窗

位置：`Downloader/UI/TorrentFileSelectionSheet.swift`

搜尋關鍵字：`TorrentFileSelectionSheet`

這個檔案負責 BT 找到 metadata 後，讓使用者選 torrent 內要下載的檔案。

常見按鈕：

```swift
Button("Select All") {
    selectedIndexes = Set(selection.files.map(\.index))
}
```

全選所有檔案。

```swift
Button("Deselect All") {
    selectedIndexes.removeAll()
}
```

取消全選。

```swift
Button("Start Selected Files") {
    downloadManager.chooseTorrentFiles(itemID: selection.itemID, indexes: selectedIndexes)
}
```

開始下載選中的 BT 檔案。

### Settings 視窗

位置：`Downloader/UI/SettingsView.swift`

搜尋關鍵字：`SettingsView`

這裡放 App 設定，例如速度限制：

```swift
Stepper("Speed limit: ...", value: $speedLimitKBps, in: 0...100_000, step: 100)
```

`Stepper` 是可以按加減的數值控制。

### App menu 快捷鍵

位置：`Downloader/App/DownloaderApp.swift`

搜尋關鍵字：`commands`

menu command 例如：

```swift
Button("Add Download...") {
    NotificationCenter.default.post(name: .showAddDownload, object: nil)
}
.keyboardShortcut("n", modifiers: [.command])
```

意思：

- menu 裡有 `Add Download...`
- 快捷鍵是 `Command + N`
- 按下後發出 `.showAddDownload` 通知，叫 `ContentView` 打開新增下載視窗。

刪除快捷鍵：

```swift
Button("Delete Download") {
    downloadManager.deleteSelected()
}
.keyboardShortcut(.delete, modifiers: [])
```

意思是按鍵盤 `Delete` 就刪除目前選中的下載項目。

## 持久化

`DownloadStore.swift`

- 把 `DownloadItem` 陣列保存到：

```text
~/Library/Application Support/Downloader/downloads.json
```

- App 重開時把舊的 `downloading` 任務改成 `paused`，避免顯示錯誤狀態。

`FolderBookmarkStore.swift`

- 保存最後選擇的下載資料夾。
- 保存 security-scoped bookmark。
- 提供 `withAccess` 包裝 sandbox 權限。

## 通知

`NotificationManager.swift` 使用 `UserNotifications`。

目前下載完成後會發送：

```text
Download Complete
<檔案名稱>
```

第一次使用時會請求通知權限。使用者拒絕通知不會影響下載。

## Debug Area 常見訊息

以下多數是 macOS / Xcode 系統 log，不一定是 App bug：

| 訊息 | 說明 | 是否需要修 |
| --- | --- | --- |
| `DetachedSignatures` | macOS 簽章資料庫讀取 log | 通常不用 |
| `Unable to obtain a task name port right` | debugger 或系統服務權限限制 | 通常不用 |
| `nw_endpoint_flow_failed_with_error 127.0.0.1` | 本機 loopback 連線失敗 log | 只有下載失敗同時出現才查 |
| `ViewBridge to RemoteViewService Terminated` | NSOpenPanel 等系統視窗關閉 | 通常不用 |

## 下載測試 URL

### httpbin

可自訂位元組數的下載端點：

```text
https://httpbin.org/bytes/<bytes>
```

可串流下載測試：

```text
https://httpbin.org/stream-bytes/<bytes>
```

常用測試大小：

| 大小 | 位元組 | 測試 URL |
| --- | ---: | --- |
| 1 KB | 1,024 B | `https://httpbin.org/bytes/1024` |
| 1 MB | 1,048,576 B | `https://httpbin.org/bytes/1048576` |
| 10 MB | 10,485,760 B | `https://httpbin.org/bytes/10485760` |
| 100 MB | 104,857,600 B | `https://httpbin.org/bytes/104857600` |
| 1 GB | 1,073,741,824 B | `https://httpbin.org/bytes/1073741824` |

容量換算：

```text
1 KB = 1024 B
1 MB = 1024 x 1024 = 1,048,576 B
10 MB = 10 x 1024 x 1024 = 10,485,760 B
100 MB = 100 x 1024 x 1024 = 104,857,600 B
1 GB = 1024 x 1024 x 1024 = 1,073,741,824 B
```

### Hetzner

網頁文件下載測試：

[https://ash-speed.hetzner.com/](https://ash-speed.hetzner.com/)

## Safari Extension 清理

如果 Safari Extension 曾經出現同名、舊版本或冇用的 `Downloader Extension`，可以先刪除 Xcode 產生的 DerivedData。Xcode 按 Run / Build 後會重新產生這些資料夾。

```zsh
rm -rf ~/Documents/Xcode/Downloader/Build/DerivedData
rm -rf ~/Library/Developer/Xcode/DerivedData/Downloader-fkmjpusihrlgzaeuymdzbrsrgavk
```

刪除後重新 Run / Build，Safari Extension 列表會較容易只留下目前 project 產生的版本。