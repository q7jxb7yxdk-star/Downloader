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

### 4. 速度計算

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

## 之後可以改進的方向

- 實作真正的全域同時下載數限制。
- 實作全域速度限制。
- 支援 `.torrent` 檔案匯入，不只 magnet。
- 加入 Safari extension 或更完整的 URL scheme integration。
- 保存 BT resume data，讓 App 重開後可更完整地續傳。
- 加入下載完成後 reveal in Finder。
- 加入錯誤重試策略和更詳細的錯誤分類。
