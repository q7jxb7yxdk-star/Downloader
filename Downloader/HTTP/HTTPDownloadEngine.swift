import Foundation

/// HTTP engine 回報下載狀態給 DownloadManager 的介面。
///
/// protocol 讓 engine 不需要直接依賴 SwiftUI 或 DownloadManager 的具體型別。
@MainActor
protocol HTTPDownloadEngineDelegate: AnyObject {
    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64, uploadSpeed: Int64)
    func updateHTTPConnections(id: DownloadItem.ID, connections: [HTTPConnectionDetail])
    func updateStatusText(id: DownloadItem.ID, message: String?)
    func complete(id: DownloadItem.ID, fileURL: URL, received: Int64?, expected: Int64?, averageBytesPerSecond: Int64?, averageUploadBytesPerSecond: Int64?, activeDownloadDuration: TimeInterval?)
    func fail(id: DownloadItem.ID, errorMessage: String?)
}

/// 負責一般 HTTP/HTTPS 下載。
///
/// 這個 engine 支援兩種模式：
/// - 單連線下載：使用 `URLSessionDataTask` 串流寫入 `.part-0.tmp`，所以可以立即開始並保留未完成檔案。
/// - 自動升級分段：背景探測到 server 支援 Range 且檔案夠大時，把未下載部分切成多段。
final class HTTPDownloadEngine: NSObject, @unchecked Sendable {
    /// 用 taskIdentifier 記住每個 URLSession task 是普通下載還是某一段分段下載。
    private enum TaskPurpose {
        case single(DownloadItem.ID)
        case segment(DownloadItem.ID, Int)
    }

    /// 分段下載中其中一段的狀態。
    private struct SegmentState {
        let index: Int
        let range: ClosedRange<Int64>
        let fileURL: URL
        var received: Int64 = 0
        var isFinished = false
    }

    /// 一個完整分段下載任務的狀態。
    private struct SegmentedDownloadState {
        let item: DownloadItem
        let totalBytes: Int64
        let targetURL: URL
        let temporaryFiles: [URL]
        var segments: [Int: SegmentState]
    }

    /// 用實際傳輸中的時間計算平均速度，避免暫停時間拉低完成後的 Avg speed。
    private struct TransferTiming {
        var firstReceived: Int64
        var activeStartedAt: Date?
        var accumulatedActiveTime: TimeInterval = 0
    }

    /// HTTP 分段數。4 條連線通常已經有明顯加速，也不會太容易被 server 視為濫用。
    private static let segmentedThreadCount = 4

    /// 小檔案不分段，因為建立多個連線和合併檔案本身也有成本。
    private static let minimumSegmentedSize: Int64 = 8 * 1024 * 1024

    /// 單連線失敗時最多重試次數。
    private static let maximumRetryCount = 3
    private static let errorDomain = "HTTPDownloadEngine"
    private static let fallbackToSingleErrorCode = 100
    private static let retryableResponseErrorCode = 101
    private static let permanentResponseErrorCode = 102

    /// 背景 Range 探測最多等待時間。
    ///
    /// 下載已經先開始了，所以這裡可以等久一點；server 慢回應時仍有機會升級成多線。
    private static let rangeProbeTimeout: TimeInterval = 15

    private weak var delegate: HTTPDownloadEngineDelegate?
    private var session: URLSession!

    /// 下列 dictionary 都是用 download item id 或 task id，把非同步 callback 對回正確任務。
    private var taskPurposes: [Int: TaskPurpose] = [:]
    /// 單連線模式的 URLSessionDataTask。key 是 DownloadItem.ID。
    private var singleDataTasksByID: [DownloadItem.ID: URLSessionDataTask] = [:]
    /// 分段模式的所有 URLSessionDataTask。每個 item 會有多條連線。
    private var dataTasksByID: [DownloadItem.ID: [URLSessionDataTask]] = [:]
    /// 保存原始 DownloadItem，讓 callback 裡仍然知道檔名和下載資料夾。
    private var itemsByID: [DownloadItem.ID: DownloadItem] = [:]
    /// 記錄重試次數，避免網絡一直失敗時無限重試。
    private var retryCounts: [DownloadItem.ID: Int] = [:]
    /// 分段各自計算重試次數，避免不同分段共用同一個重試額度。
    private var segmentRetryCounts: [DownloadItem.ID: [Int: Int]] = [:]
    /// 等待啟動或重試的分段工作；Pause 或 Cancel 時必須取消。
    private var scheduledSegmentStarts: [DownloadItem.ID: [Int: Task<Void, Never>]] = [:]
    /// 每個下載目前容許的活躍分段數；收到 429 後會由 4 降至 2，再降至 1。
    private var segmentConnectionLimits: [DownloadItem.ID: Int] = [:]
    /// 已 resume、尚未完成 callback 的分段 task identifiers。
    private var activeSegmentTaskIDs: [DownloadItem.ID: Set<Int>] = [:]
    /// 記錄分段 task 實際啟動時的連線級別，避免同一批 429 重複降級。
    private var segmentConnectionLimitByTaskID: [Int: Int] = [:]
    /// 上一次速度取樣。用來計算「這 0.5 秒下載了多少 byte」。
    private var lastSamples: [DownloadItem.ID: (date: Date, bytes: Int64)] = [:]
    /// 顯示給 UI 的平滑速度，避免數字跳得太誇張。
    private var displayedSpeeds: [DownloadItem.ID: Int64] = [:]
    /// 各 HTTP 連線獨立速度取樣，不影響整體速度計算。
    private var connectionLastSamples: [DownloadItem.ID: [Int: (date: Date, bytes: Int64)]] = [:]
    private var connectionDisplayedSpeeds: [DownloadItem.ID: [Int: Int64]] = [:]
    /// 分段下載中的完整狀態，包括每段 range、暫存檔和最終檔案位置。
    private var segmentedDownloads: [DownloadItem.ID: SegmentedDownloadState] = [:]
    /// 單連線模式的 `.part-0.tmp` 檔案位置。
    private var incompleteFilesByID: [DownloadItem.ID: URL] = [:]
    /// 單連線最終目標檔案位置。預留給需要直接定位 target 的流程。
    private var singleTargetURLsByID: [DownloadItem.ID: URL] = [:]
    /// 單連線目前預期總大小。server 不提供 Content-Length 時可能是 0。
    private var singleExpectedBytesByID: [DownloadItem.ID: Int64] = [:]
    /// 單連線目前已收到 byte 數。暫停續傳時會由本地檔案大小開始。
    private var singleReceivedBytesByID: [DownloadItem.ID: Int64] = [:]
    /// 記錄 HTTP 下載實際有在傳輸的時間；暫停期間不會計入平均速度。
    private var transferTimingsByID: [DownloadItem.ID: TransferTiming] = [:]
    /// 每個單線 task 的起始 offset，用來判斷 response 應該 append 還是重寫。
    private var singleStartOffsetsByTaskID: [Int: Int64] = [:]
    /// 每個分段 task 實際要求的起始 offset，用來驗證 server 的 Content-Range。
    private var segmentStartOffsetsByTaskID: [Int: Int64] = [:]
    /// response 驗證失敗時保存具體錯誤，避免 URLSession 的 cancelled 錯誤被忽略。
    private var segmentResponseErrorsByTaskID: [Int: Error] = [:]
    /// 正在由單線切換到分段的 item。取消舊 task 時不要誤判為真正失敗。
    private var switchingToSegmentedIDs: Set<DownloadItem.ID> = []
    /// 每個 task 對應的檔案寫入 stream。收到 data callback 時直接寫入磁碟。
    private var outputStreams: [Int: OutputStream] = [:]

    init(delegate: HTTPDownloadEngineDelegate) {
        self.delegate = delegate
        super.init()

        let configuration = URLSessionConfiguration.default
        // 網絡暫時不可用時等一等，而不是立刻失敗。
        configuration.waitsForConnectivity = true
        // 配合分段下載數，避免 URLSession 自己限制同 host 連線太少。
        configuration.httpMaximumConnectionsPerHost = Self.segmentedThreadCount
        // delegateQueue 用 main，是因為這個 engine 大多被 MainActor 管理；簡化同步問題。
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    /// 開始下載前先探測 server 是否支援 Range。
    func start(item: DownloadItem) {
        itemsByID[item.id] = item
        notifyStatus(id: item.id, message: "Starting")
        startSingleDownload(item: item)

        Task { [weak self] in
            await self?.upgradeToSegmentedIfPossible(item: item)
        }
    }

    /// 暫停下載。
    ///
    /// 單連線和分段下載都會保留已寫入的 `.part-N.tmp`，之後用 Range 接續。
    func pause(id: DownloadItem.ID) {
        suspendTransferTiming(id: id)
        publishHTTPConnectionDetails(id: id, resetSpeeds: true)

        if let dataTasks = dataTasksByID[id] {
            dataTasks.forEach { $0.cancel() }
            dataTasksByID[id] = nil
            cancelScheduledSegmentRetries(id: id)
            closeSegmentStreams(for: id)
            activeSegmentTaskIDs[id] = nil
            return
        }

        singleDataTasksByID[id]?.cancel()
        singleDataTasksByID[id] = nil
        closeSingleStream(for: id)
    }

    /// 取消下載並清理 engine 內部狀態。
    func cancel(id: DownloadItem.ID) {
        singleDataTasksByID[id]?.cancel()
        singleDataTasksByID[id] = nil
        closeSingleStream(for: id)
        cleanupSegmentedDownload(id: id)
        removeIncompleteFile(id: id)
        retryCounts[id] = nil
        segmentRetryCounts[id] = nil
        itemsByID[id] = nil
        lastSamples[id] = nil
        displayedSpeeds[id] = nil
        connectionLastSamples[id] = nil
        connectionDisplayedSpeeds[id] = nil
        singleTargetURLsByID[id] = nil
        singleExpectedBytesByID[id] = nil
        singleReceivedBytesByID[id] = nil
        transferTimingsByID[id] = nil
        switchingToSegmentedIDs.remove(id)
    }

    /// 從暫停狀態繼續下載。
    func resume(item: DownloadItem) {
        if segmentedDownloads[item.id] != nil {
            resumeSegmentedDownload(id: item.id)
            return
        }

        startSingleDownload(item: item)
    }

    /// 背景 Range 探測完成後，如可行就把單線任務升級成分段下載。
    @MainActor
    private func upgradeToSegmentedIfPossible(item: DownloadItem) async {
        do {
            let probe = try await probeRangeSupport(for: item.source)
            guard probe.supportsRange,
                  probe.contentLength >= Self.minimumSegmentedSize,
                  singleDataTasksByID[item.id] != nil,
                  segmentedDownloads[item.id] == nil
            else {
                return
            }

            try switchSingleDownloadToSegmented(item: item, totalBytes: probe.contentLength)
        } catch {
            return
        }
    }

    /// 用 `Range: bytes=0-0` 探測 server 是否支援 byte-range。
    ///
    /// 如果回傳 HTTP 206 Partial Content，代表 server 支援分段下載。
    private func probeRangeSupport(for url: URL) async throws -> (supportsRange: Bool, contentLength: Int64) {
        var request = downloadRequest(for: url)
        request.httpMethod = "GET"
        setByteRange("bytes=0-0", on: &request)
        request.timeoutInterval = Self.rangeProbeTimeout

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        let probeSession = URLSession(configuration: configuration)
        defer { probeSession.invalidateAndCancel() }

        let (_, response) = try await probeSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return (false, 0)
        }

        if httpResponse.statusCode == 206,
           let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range"),
           let totalBytes = totalBytes(fromContentRange: contentRange) {
            return (true, totalBytes)
        }

        let acceptsRanges = (httpResponse.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
        let contentLength = Int64(httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "") ?? httpResponse.expectedContentLength
        return (acceptsRanges && contentLength > 0, contentLength)
    }

    /// 啟動單連線串流下載。
    private func startSingleDownload(item: DownloadItem) {
        let incompleteURL = createIncompleteFile(for: item)
        let existingBytes = fileSize(at: incompleteURL)

        var request = downloadRequest(for: item.source)
        if existingBytes > 0 {
            setByteRange("bytes=\(existingBytes)-", on: &request)
        }

        let task = session.dataTask(with: request)
        taskPurposes[task.taskIdentifier] = .single(item.id)
        singleDataTasksByID[item.id] = task
        itemsByID[item.id] = item
        singleReceivedBytesByID[item.id] = existingBytes
        singleStartOffsetsByTaskID[task.taskIdentifier] = existingBytes
        beginTransferTiming(id: item.id, received: existingBytes)
        notifyStatus(id: item.id, message: "Single connection")
        task.resume()
        publishHTTPConnectionDetails(id: item.id)
    }

    /// 建立多段 byte range，並為每段建立獨立 `.tmp` 檔案。
    private func startSegmentedDownload(item: DownloadItem, totalBytes: Int64) throws {
        let folder = item.destination ?? FolderBookmarkStore.fallbackFolder
        let targetURL = uniqueFileURL(in: folder, filename: item.name)

        try FolderBookmarkStore.withAccess(to: folder) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let ranges = byteRanges(totalBytes: totalBytes, count: Self.segmentedThreadCount)
        var segments: [Int: SegmentState] = [:]
        var tasks: [URLSessionDataTask] = []
        var temporaryFiles: [URL] = []

        for (index, range) in ranges.enumerated() {
            // 分段檔案直接放在使用者選擇資料夾，讓未完成檔案可見。
            let fileURL = uniqueFileURL(in: folder, filename: partFilename(for: item.name, index: index))
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            temporaryFiles.append(fileURL)

            var request = downloadRequest(for: item.source)
            setByteRange("bytes=\(range.lowerBound)-\(range.upperBound)", on: &request)

            let task = session.dataTask(with: request)
            taskPurposes[task.taskIdentifier] = .segment(item.id, index)
            segmentStartOffsetsByTaskID[task.taskIdentifier] = range.lowerBound
            segments[index] = SegmentState(index: index, range: range, fileURL: fileURL)
            tasks.append(task)
        }

        segmentedDownloads[item.id] = SegmentedDownloadState(
            item: item,
            totalBytes: totalBytes,
            targetURL: targetURL,
            temporaryFiles: temporaryFiles,
            segments: segments
        )
        dataTasksByID[item.id] = tasks
        segmentConnectionLimits[item.id] = Self.segmentedThreadCount
        itemsByID[item.id] = item
        beginTransferTiming(id: item.id, received: 0)
        notifyStatus(id: item.id, message: "\(Self.segmentedThreadCount) connections")
        connectionLastSamples[item.id] = nil
        connectionDisplayedSpeeds[item.id] = nil
        publishHTTPConnectionDetails(id: item.id)

        enqueueSegmentTasks(tasks, id: item.id)
    }

    /// 把正在跑的單線下載升級成分段下載。
    ///
    /// 已經寫入的 `.part-0.tmp` 會成為第一段；未下載的尾段再切成多段並行下載。
    private func switchSingleDownloadToSegmented(item: DownloadItem, totalBytes: Int64) throws {
        guard let singleTask = singleDataTasksByID[item.id],
              let firstPartURL = incompleteFilesByID[item.id]
        else { return }

        let downloadedBytes = min(fileSize(at: firstPartURL), totalBytes)
        guard downloadedBytes < totalBytes else { return }

        switchingToSegmentedIDs.insert(item.id)
        singleTask.cancel()
        singleDataTasksByID[item.id] = nil
        closeSingleStream(for: item.id)

        guard downloadedBytes > 0 else {
            removeIncompleteFile(id: item.id)
            try startSegmentedDownload(item: item, totalBytes: totalBytes)
            return
        }

        let folder = item.destination ?? FolderBookmarkStore.fallbackFolder
        let targetURL = uniqueFileURL(in: folder, filename: item.name)
        let remainingRanges = byteRanges(
            lowerBound: downloadedBytes,
            upperBound: totalBytes - 1,
            count: max(1, Self.segmentedThreadCount - 1)
        )

        var segments: [Int: SegmentState] = [
            0: SegmentState(
                index: 0,
                range: 0...(downloadedBytes - 1),
                fileURL: firstPartURL,
                received: downloadedBytes,
                isFinished: true
            )
        ]
        var tasks: [URLSessionDataTask] = []
        var temporaryFiles: [URL] = [firstPartURL]

        for (offset, range) in remainingRanges.enumerated() {
            let index = offset + 1
            let fileURL = uniqueFileURL(in: folder, filename: partFilename(for: item.name, index: index))
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            temporaryFiles.append(fileURL)

            var request = downloadRequest(for: item.source)
            setByteRange("bytes=\(range.lowerBound)-\(range.upperBound)", on: &request)

            let task = session.dataTask(with: request)
            taskPurposes[task.taskIdentifier] = .segment(item.id, index)
            segmentStartOffsetsByTaskID[task.taskIdentifier] = range.lowerBound
            segments[index] = SegmentState(index: index, range: range, fileURL: fileURL)
            tasks.append(task)
        }

        segmentedDownloads[item.id] = SegmentedDownloadState(
            item: item,
            totalBytes: totalBytes,
            targetURL: targetURL,
            temporaryFiles: temporaryFiles,
            segments: segments
        )
        dataTasksByID[item.id] = tasks
        segmentConnectionLimits[item.id] = Self.segmentedThreadCount
        itemsByID[item.id] = item
        singleExpectedBytesByID[item.id] = nil
        singleReceivedBytesByID[item.id] = nil
        singleTargetURLsByID[item.id] = nil
        notifyStatus(id: item.id, message: "\(tasks.count + 1) connections")
        updateProgress(id: item.id, received: downloadedBytes, expected: totalBytes)
        connectionLastSamples[item.id] = nil
        connectionDisplayedSpeeds[item.id] = nil
        publishHTTPConnectionDetails(id: item.id)

        enqueueSegmentTasks(tasks, id: item.id)
    }

    /// 把檔案大小切成多個連續 byte range。
    private func byteRanges(totalBytes: Int64, count: Int) -> [ClosedRange<Int64>] {
        byteRanges(lowerBound: 0, upperBound: totalBytes - 1, count: count)
    }

    private func byteRanges(lowerBound: Int64, upperBound: Int64, count: Int) -> [ClosedRange<Int64>] {
        guard lowerBound <= upperBound else { return [] }
        let totalBytes = upperBound - lowerBound + 1
        let segmentSize = totalBytes / Int64(count)
        return (0..<count).map { index in
            let start = lowerBound + Int64(index) * segmentSize
            let end = index == count - 1 ? upperBound : (start + segmentSize - 1)
            return start...end
        }
    }
}

extension HTTPDownloadEngine: URLSessionDownloadDelegate, URLSessionDataDelegate {
    /// 單連線下載進度 callback。
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard case let .single(id)? = taskPurposes[downloadTask.taskIdentifier], totalBytesExpectedToWrite > 0 else { return }

        updateProgress(id: id, received: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    /// 單連線下載完成後，URLSession 會先給一個暫存位置，我們再搬到使用者資料夾。
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard case let .single(id)? = taskPurposes[downloadTask.taskIdentifier] else { return }
        let item = itemsByID[id]
        let folder = item?.destination ?? FolderBookmarkStore.fallbackFolder
        let filename = item?.name ?? downloadTask.response?.suggestedFilename ?? UUID().uuidString
        let targetURL = uniqueFileURL(in: folder, filename: filename)

        do {
            try FolderBookmarkStore.withAccess(to: folder) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.moveItem(at: location, to: targetURL)
            }
            Task { @MainActor [weak self] in
                self?.finish(id: id, fileURL: targetURL)
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.fail(id: id, error: error)
            }
        }
    }

    /// 分段下載收到 response 時，打開該段對應的 OutputStream。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        if case let .single(id)? = taskPurposes[dataTask.taskIdentifier] {
            guard let httpResponse = response as? HTTPURLResponse,
                  (httpResponse.statusCode == 200 || httpResponse.statusCode == 206),
                  let fileURL = incompleteFilesByID[id]
            else {
                return .cancel
            }

            let startOffset = singleStartOffsetsByTaskID[dataTask.taskIdentifier] ?? 0
            let shouldAppend = httpResponse.statusCode == 206 && startOffset > 0
            if !shouldAppend {
                // 如果 server 回 200，代表它沒有接續 Range，而是從頭傳。
                // 這時必須清空原本 `.part-0.tmp`，避免新舊資料混在一起。
                try? Data().write(to: fileURL)
                singleStartOffsetsByTaskID[dataTask.taskIdentifier] = 0
                singleReceivedBytesByID[id] = 0
                resetTransferTiming(id: id, received: 0)
            }

            let expected = httpResponse.expectedContentLength > 0
                ? (singleStartOffsetsByTaskID[dataTask.taskIdentifier] ?? 0) + httpResponse.expectedContentLength
                : 0
            singleExpectedBytesByID[id] = expected

            guard let stream = OutputStream(url: fileURL, append: shouldAppend) else {
                return .cancel
            }
            stream.open()
            outputStreams[dataTask.taskIdentifier] = stream
            return .allow
        }

        guard case let .segment(id, index)? = taskPurposes[dataTask.taskIdentifier],
              let state = segmentedDownloads[id],
              let segment = state.segments[index]
        else {
            return .cancel
        }

        let taskID = dataTask.taskIdentifier
        let expectedStart = segmentStartOffsetsByTaskID[taskID]
            ?? segment.range.lowerBound + segment.received
        guard let httpResponse = response as? HTTPURLResponse else {
            segmentResponseErrorsByTaskID[taskID] = NSError(
                domain: Self.errorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Server returned a non-HTTP response for a byte-range request."]
            )
            return .cancel
        }

        let contentRange = httpResponse.value(forHTTPHeaderField: "Content-Range")
        guard httpResponse.statusCode == 206 else {
            let statusCode = httpResponse.statusCode
            let isRetryable = statusCode == 408
                || statusCode == 429
                || (500...599).contains(statusCode)

            if isRetryable {
                segmentResponseErrorsByTaskID[taskID] = NSError(
                    domain: Self.errorDomain,
                    code: Self.retryableResponseErrorCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Server returned HTTP \(statusCode).",
                        "HTTPStatus": statusCode,
                        "RetryAfter": retryDelay(from: httpResponse)
                    ]
                )
                return .cancel
            }

            if statusCode != 200 {
                segmentResponseErrorsByTaskID[taskID] = NSError(
                    domain: Self.errorDomain,
                    code: Self.permanentResponseErrorCode,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Server returned HTTP \(statusCode) for a byte-range request.",
                        "HTTPStatus": statusCode
                    ]
                )
                return .cancel
            }

            segmentResponseErrorsByTaskID[taskID] = NSError(
                domain: Self.errorDomain,
                code: Self.fallbackToSingleErrorCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "Server does not support reliable byte-range downloads. Falling back to a single connection.",
                    "HTTPStatus": httpResponse.statusCode,
                    "ContentRange": contentRange ?? "<missing>"
                ]
            )
            return .cancel
        }

        guard let contentRange,
              let responseRange = byteRange(fromContentRange: contentRange)
        else {
            segmentResponseErrorsByTaskID[taskID] = NSError(
                domain: Self.errorDomain,
                code: Self.fallbackToSingleErrorCode,
                userInfo: [
                    NSLocalizedDescriptionKey: "Server omitted a usable Content-Range. Falling back to a single connection.",
                    "HTTPStatus": httpResponse.statusCode,
                    "ContentRange": contentRange ?? "<missing>"
                ]
            )
            return .cancel
        }

        guard responseRange.start == expectedStart,
              responseRange.end >= responseRange.start,
              responseRange.end <= segment.range.upperBound,
              responseRange.total == state.totalBytes
        else {
            segmentResponseErrorsByTaskID[taskID] = NSError(
                domain: Self.errorDomain,
                code: 2,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid byte-range response: requested \(expectedStart)-\(segment.range.upperBound)/\(state.totalBytes), received \(contentRange)."
                ]
            )
            return .cancel
        }

        guard let stream = OutputStream(url: segment.fileURL, append: segment.received > 0) else {
            segmentResponseErrorsByTaskID[taskID] = NSError(
                domain: Self.errorDomain,
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Unable to open the temporary segment file."]
            )
            return .cancel
        }

        stream.open()
        outputStreams[taskID] = stream
        return .allow
    }

    /// 分段下載收到資料時，直接寫入對應 `.part-N.tmp`。
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if case let .single(id)? = taskPurposes[dataTask.taskIdentifier],
           let stream = outputStreams[dataTask.taskIdentifier] {
            data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
                _ = stream.write(baseAddress, maxLength: data.count)
            }

            let received = (singleReceivedBytesByID[id] ?? 0) + Int64(data.count)
            singleReceivedBytesByID[id] = received
            updateConnectionSpeed(id: id, index: 0, received: received)
            updateProgress(id: id, received: received, expected: singleExpectedBytesByID[id] ?? 0)
            publishHTTPConnectionDetails(id: id)
            return
        }

        guard case let .segment(id, index)? = taskPurposes[dataTask.taskIdentifier],
              var state = segmentedDownloads[id],
              var segment = state.segments[index],
              let stream = outputStreams[dataTask.taskIdentifier]
        else { return }

        data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = stream.write(baseAddress, maxLength: data.count)
        }

        segment.received += Int64(data.count)
        state.segments[index] = segment
        segmentedDownloads[id] = state
        updateConnectionSpeed(id: id, index: index, received: segment.received)

        let received = state.segments.values.reduce(Int64(0)) { $0 + $1.received }
        updateProgress(id: id, received: received, expected: state.totalBytes)
        publishHTTPConnectionDetails(id: id)
    }

    /// 任務完成或失敗 callback。
    ///
    /// 分段全部完成後會合併檔案；單連線失敗會重試；分段失敗只重試該段。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let taskID = task.taskIdentifier
        let launchedSegmentConnectionLimit = segmentConnectionLimitByTaskID.removeValue(forKey: taskID)
        let responseError = segmentResponseErrorsByTaskID.removeValue(forKey: taskID)
        let effectiveError = responseError ?? error

        if case let .segment(id, index)? = taskPurposes[taskID] {
            activeSegmentTaskIDs[id]?.remove(taskID)
            connectionDisplayedSpeeds[id, default: [:]][index] = 0
            publishHTTPConnectionDetails(id: id)
        }

        defer {
            taskPurposes[taskID] = nil
            segmentStartOffsetsByTaskID[taskID] = nil
            outputStreams.removeValue(forKey: taskID)?.close()
        }

        if let effectiveError {
            let nsError = effectiveError as NSError
            guard nsError.code != NSURLErrorCancelled || responseError != nil else { return }

            switch taskPurposes[taskID] {
            case let .single(id):
                if switchingToSegmentedIDs.remove(id) != nil {
                    return
                }
                retrySingleDownload(id: id, error: effectiveError)
            case let .segment(id, index):
                if nsError.domain == Self.errorDomain,
                   nsError.code == Self.fallbackToSingleErrorCode {
                    fallbackSegmentedDownloadToSingle(id: id)
                } else if nsError.domain == Self.errorDomain,
                          nsError.code == Self.retryableResponseErrorCode {
                    if (nsError.userInfo["HTTPStatus"] as? Int) == 429 {
                        let requestLimit = launchedSegmentConnectionLimit
                            ?? segmentConnectionLimits[id]
                            ?? Self.segmentedThreadCount
                        let downgradedLimit = requestLimit >= Self.segmentedThreadCount ? 2 : 1
                        let currentLimit = segmentConnectionLimits[id] ?? Self.segmentedThreadCount
                        segmentConnectionLimits[id] = min(currentLimit, downgradedLimit)
                        publishHTTPConnectionDetails(id: id)
                    }
                    scheduleSegmentRetry(id: id, index: index, error: effectiveError)
                } else if nsError.domain == Self.errorDomain,
                          nsError.code == Self.permanentResponseErrorCode {
                    cleanupSegmentedDownload(id: id)
                    fail(id: id, error: effectiveError)
                } else {
                    handleSegmentCompletion(id: id, index: index, error: effectiveError)
                }
            case nil:
                break
            }
            return
        }

        if case let .single(id)? = taskPurposes[taskID] {
            completeSingleDownload(id: id)
            return
        }

        if case let .segment(id, index)? = taskPurposes[taskID] {
            handleSegmentCompletion(id: id, index: index, error: nil)
        }
    }
}

private extension HTTPDownloadEngine {
    /// 更新進度並計算平滑後速度。
    ///
    /// 即時速度會跳得很厲害，所以這裡每 0.5 秒取樣一次，並用 70/30 權重平滑顯示。
    func updateProgress(id: DownloadItem.ID, received: Int64, expected: Int64) {
        beginTransferTiming(id: id, received: received)

        let now = Date()
        let speed: Int64

        if let previous = lastSamples[id] {
            let elapsed = now.timeIntervalSince(previous.date)

            if elapsed >= 0.5 {
                let instantSpeed = max(0, Int64(Double(received - previous.bytes) / elapsed))
                let previousDisplayedSpeed = displayedSpeeds[id] ?? instantSpeed
                speed = Int64(Double(previousDisplayedSpeed) * 0.7 + Double(instantSpeed) * 0.3)
                lastSamples[id] = (now, received)
                displayedSpeeds[id] = speed
            } else {
                speed = displayedSpeeds[id] ?? 0
            }
        } else {
            speed = 0
            lastSamples[id] = (now, received)
            displayedSpeeds[id] = speed
        }

        Task { @MainActor [weak self] in
            self?.delegate?.update(
                id: id,
                progress: expected > 0 ? Double(received) / Double(expected) : 0,
                received: received,
                expected: expected,
                speed: speed,
                uploadSpeed: 0
            )
        }
    }

    func updateConnectionSpeed(id: DownloadItem.ID, index: Int, received: Int64) {
        let now = Date()
        if let previous = connectionLastSamples[id]?[index] {
            let elapsed = now.timeIntervalSince(previous.date)
            guard elapsed >= 0.5 else { return }

            let instantSpeed = max(0, Int64(Double(received - previous.bytes) / elapsed))
            let previousSpeed = connectionDisplayedSpeeds[id]?[index] ?? instantSpeed
            connectionDisplayedSpeeds[id, default: [:]][index] =
                Int64(Double(previousSpeed) * 0.7 + Double(instantSpeed) * 0.3)
        } else {
            connectionDisplayedSpeeds[id, default: [:]][index] = 0
        }
        connectionLastSamples[id, default: [:]][index] = (now, received)
    }

    func publishHTTPConnectionDetails(id: DownloadItem.ID, resetSpeeds: Bool = false) {
        if resetSpeeds {
            connectionDisplayedSpeeds[id] = connectionDisplayedSpeeds[id]?.mapValues { _ in 0 }
        }

        let details: [HTTPConnectionDetail]
        if let state = segmentedDownloads[id] {
            let connectionLimit = max(
                1,
                min(segmentConnectionLimits[id] ?? Self.segmentedThreadCount, state.segments.count)
            )
            let activeIndexes = Set(
                activeSegmentTaskIDs[id, default: []].compactMap { taskID -> Int? in
                    guard case let .segment(_, index)? = taskPurposes[taskID] else { return nil }
                    return index
                }
            )
            let unfinishedSegments = state.segments
                .filter { !$0.value.isFinished }
                .sorted { lhs, rhs in
                    let lhsIsActive = activeIndexes.contains(lhs.key)
                    let rhsIsActive = activeIndexes.contains(rhs.key)
                    if lhsIsActive != rhsIsActive {
                        return lhsIsActive
                    }
                    return lhs.key < rhs.key
                }
            let visibleSegments = Array(unfinishedSegments.prefix(connectionLimit))

            details = visibleSegments
                .enumerated()
                .map { displayIndex, entry in
                    let (segmentIndex, segment) = entry
                    return HTTPConnectionDetail(
                        id: segmentIndex,
                        title: "Thread \(displayIndex + 1)",
                        bytesReceived: segment.received,
                        bytesExpected: segment.range.upperBound - segment.range.lowerBound + 1,
                        bytesPerSecond: connectionDisplayedSpeeds[id]?[segmentIndex] ?? 0
                    )
                }
        } else if singleDataTasksByID[id] != nil || incompleteFilesByID[id] != nil {
            details = [
                HTTPConnectionDetail(
                    id: 0,
                    title: "Connection 1",
                    bytesReceived: singleReceivedBytesByID[id] ?? 0,
                    bytesExpected: singleExpectedBytesByID[id] ?? 0,
                    bytesPerSecond: connectionDisplayedSpeeds[id]?[0] ?? 0
                )
            ]
        } else {
            details = []
        }

        Task { @MainActor [weak self] in
            self?.delegate?.updateHTTPConnections(id: id, connections: details)
        }
    }

    /// 開始或恢復計算實際傳輸時間。
    func beginTransferTiming(id: DownloadItem.ID, received: Int64) {
        if var timing = transferTimingsByID[id] {
            guard timing.activeStartedAt == nil else { return }
            timing.activeStartedAt = Date()
            transferTimingsByID[id] = timing
            return
        }

        transferTimingsByID[id] = TransferTiming(firstReceived: received, activeStartedAt: Date())
    }

    /// 暫停時計入本次 active 時間，之後 resume 再繼續累加。
    func suspendTransferTiming(id: DownloadItem.ID) {
        guard var timing = transferTimingsByID[id],
              let activeStartedAt = timing.activeStartedAt
        else { return }

        timing.accumulatedActiveTime += Date().timeIntervalSince(activeStartedAt)
        timing.activeStartedAt = nil
        transferTimingsByID[id] = timing
    }

    /// 從頭重傳時重設基準，避免把已被 server 忽略的舊 byte 算進平均。
    func resetTransferTiming(id: DownloadItem.ID, received: Int64) {
        transferTimingsByID[id] = TransferTiming(firstReceived: received, activeStartedAt: Date())
    }

    /// 以實際傳輸時間計算平均速度；沒有足夠資料時交回 nil 讓上層 fallback。
    func averageTransferSpeed(id: DownloadItem.ID, received: Int64) -> Int64? {
        guard let activeTime = activeTransferDuration(id: id),
              let timing = transferTimingsByID[id]
        else { return nil }
        let transferredBytes = max(0, received - timing.firstReceived)
        guard activeTime > 0, transferredBytes > 0 else { return nil }
        return Int64(Double(transferredBytes) / activeTime)
    }

    func activeTransferDuration(id: DownloadItem.ID) -> TimeInterval? {
        guard let timing = transferTimingsByID[id] else { return nil }

        var activeTime = timing.accumulatedActiveTime
        if let activeStartedAt = timing.activeStartedAt {
            activeTime += Date().timeIntervalSince(activeStartedAt)
        }

        return max(activeTime, 0)
    }

    /// 把所有分段暫存檔按 index 合併成最終檔案。
    func mergeSegmentedDownload(id: DownloadItem.ID) throws {
        guard let state = segmentedDownloads[id] else { return }
        let folder = state.targetURL.deletingLastPathComponent()

        try FolderBookmarkStore.withAccess(to: folder) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: state.targetURL.path, contents: nil)

            let output = try FileHandle(forWritingTo: state.targetURL)
            defer { try? output.close() }

            for index in state.segments.keys.sorted() {
                guard let segment = state.segments[index] else { continue }
                let input = try FileHandle(forReadingFrom: segment.fileURL)
                defer { try? input.close() }

                while true {
                    // 分段檔可能很大，所以用 1 MB chunk 逐步合併，
                    // 避免一次把整個檔案讀進記憶體。
                    let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                }
            }
        }

        let received = state.segments.values.reduce(Int64(0)) { $0 + $1.received }
        let expected = state.totalBytes
        cleanupSegmentedDownload(id: id)
        finish(id: id, fileURL: state.targetURL, received: received, expected: expected)
    }

    /// 單連線下載一開始先建立 `filename.part-0.tmp`，讓使用者在資料夾看到未完成項目。
    ///
    /// 如果之後升級成 4 connections，這個檔案會直接當作第 0 段，
    /// 其餘段則接續建立 `filename.part-1.tmp`、`filename.part-2.tmp`。
    @discardableResult
    func createIncompleteFile(for item: DownloadItem) -> URL {
        if let existingURL = incompleteFilesByID[item.id] {
            return existingURL
        }

        let folder = item.destination ?? FolderBookmarkStore.fallbackFolder
        let incompleteURL = uniqueFileURL(in: folder, filename: partFilename(for: item.name, index: 0))

        do {
            try FolderBookmarkStore.withAccess(to: folder) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: incompleteURL.path, contents: nil)
            }
            incompleteFilesByID[item.id] = incompleteURL
        } catch {
            notifyStatus(id: item.id, message: "Unable to create incomplete file")
        }

        return incompleteURL
    }

    /// 下載完成或取消時刪除單連線 placeholder。
    func removeIncompleteFile(id: DownloadItem.ID) {
        guard let incompleteURL = incompleteFilesByID[id] else { return }
        try? FileManager.default.removeItem(at: incompleteURL)
        incompleteFilesByID[id] = nil
    }

    /// 完成單線串流下載，把 `.part-0.tmp` 改成正式檔名。
    func completeSingleDownload(id: DownloadItem.ID) {
        guard let item = itemsByID[id],
              let incompleteURL = incompleteFilesByID[id]
        else { return }

        let folder = item.destination ?? FolderBookmarkStore.fallbackFolder
        let targetURL = uniqueFileURL(in: folder, filename: item.name)

        do {
            try FolderBookmarkStore.withAccess(to: folder) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.moveItem(at: incompleteURL, to: targetURL)
            }
            let received = max(singleReceivedBytesByID[id] ?? 0, fileSize(at: targetURL))
            let expected = max(singleExpectedBytesByID[id] ?? 0, received)
            incompleteFilesByID[id] = nil
            finish(id: id, fileURL: targetURL, received: received, expected: expected)
        } catch {
            fail(id: id, error: error)
        }
    }

    /// 分段下載的續傳。
    ///
    /// 每段根據已寫入 byte 數重新設定 Range，例如原本 0-999，已收 300，就請求 300-999。
    func resumeSegmentedDownload(id: DownloadItem.ID) {
        guard var state = segmentedDownloads[id] else { return }

        activeSegmentTaskIDs[id] = nil
        var tasks: [URLSessionDataTask] = []

        for (index, segment) in state.segments.sorted(by: { $0.key < $1.key }) {
            let nextByte = segment.range.lowerBound + segment.received

            if nextByte > segment.range.upperBound {
                var completedSegment = segment
                completedSegment.isFinished = true
                state.segments[index] = completedSegment
                continue
            }

            var resumedSegment = segment
            resumedSegment.isFinished = false
            state.segments[index] = resumedSegment

            var request = downloadRequest(for: state.item.source)
            setByteRange("bytes=\(nextByte)-\(segment.range.upperBound)", on: &request)

            let task = session.dataTask(with: request)
            taskPurposes[task.taskIdentifier] = .segment(id, index)
            segmentStartOffsetsByTaskID[task.taskIdentifier] = nextByte
            tasks.append(task)
        }

        segmentedDownloads[id] = state
        dataTasksByID[id] = tasks
        itemsByID[id] = state.item

        let received = state.segments.values.reduce(Int64(0)) { $0 + $1.received }
        lastSamples[id] = (Date(), received)
        displayedSpeeds[id] = 0
        connectionLastSamples[id] = nil
        connectionDisplayedSpeeds[id] = nil
        beginTransferTiming(id: id, received: received)

        if state.segments.values.allSatisfy(\.isFinished) {
            do {
                try mergeSegmentedDownload(id: id)
            } catch {
                cleanupSegmentedDownload(id: id)
                fail(id: id, error: error)
            }
            return
        }

        notifyStatus(id: id, message: segmentConnectionStatus(id: id))
        updateProgress(id: id, received: received, expected: state.totalBytes)
        publishHTTPConnectionDetails(id: id)
        enqueueSegmentTasks(tasks, id: id)
    }

    /// 關閉某個 item 相關的分段 output stream。
    func closeSegmentStreams(for id: DownloadItem.ID) {
        let taskIDs = taskPurposes.compactMap { taskID, purpose -> Int? in
            if case let .segment(segmentID, _) = purpose, segmentID == id {
                return taskID
            }
            return nil
        }

        for taskID in taskIDs {
            outputStreams.removeValue(forKey: taskID)?.close()
            taskPurposes[taskID] = nil
            segmentStartOffsetsByTaskID[taskID] = nil
            segmentResponseErrorsByTaskID[taskID] = nil
            segmentConnectionLimitByTaskID[taskID] = nil
        }
    }

    /// 關閉某個 item 的單線串流 OutputStream。
    func closeSingleStream(for id: DownloadItem.ID) {
        let taskIDs = taskPurposes.compactMap { taskID, purpose -> Int? in
            if case let .single(singleID) = purpose, singleID == id {
                return taskID
            }
            return nil
        }

        for taskID in taskIDs {
            outputStreams.removeValue(forKey: taskID)?.close()
            taskPurposes[taskID] = nil
            singleStartOffsetsByTaskID[taskID] = nil
        }
    }

    /// 清理分段下載狀態與 `.part-N.tmp`。
    func cleanupSegmentedDownload(id: DownloadItem.ID) {
        cancelScheduledSegmentRetries(id: id)
        dataTasksByID[id]?.forEach { $0.cancel() }
        dataTasksByID[id] = nil
        activeSegmentTaskIDs[id] = nil
        segmentConnectionLimits[id] = nil
        connectionLastSamples[id] = nil
        connectionDisplayedSpeeds[id] = nil
        closeSegmentStreams(for: id)

        if let state = segmentedDownloads[id] {
            for fileURL in state.temporaryFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        segmentedDownloads[id] = nil
    }

    /// 完成後清理 engine 狀態並回報 delegate。
    func finish(id: DownloadItem.ID, fileURL: URL, received: Int64? = nil, expected: Int64? = nil) {
        let finalReceived = received ?? singleReceivedBytesByID[id] ?? 0
        let finalExpected = expected ?? singleExpectedBytesByID[id] ?? finalReceived
        let averageSpeed = averageTransferSpeed(id: id, received: finalReceived)
        let activeDuration = activeTransferDuration(id: id)
        singleDataTasksByID[id] = nil
        dataTasksByID[id] = nil
        removeIncompleteFile(id: id)
        itemsByID[id] = nil
        retryCounts[id] = nil
        segmentRetryCounts[id] = nil
        activeSegmentTaskIDs[id] = nil
        segmentConnectionLimits[id] = nil
        connectionLastSamples[id] = nil
        connectionDisplayedSpeeds[id] = nil
        lastSamples[id] = nil
        displayedSpeeds[id] = nil
        singleTargetURLsByID[id] = nil
        singleExpectedBytesByID[id] = nil
        singleReceivedBytesByID[id] = nil
        transferTimingsByID[id] = nil
        switchingToSegmentedIDs.remove(id)
        Task { @MainActor [weak self] in
            self?.delegate?.complete(
                id: id,
                fileURL: fileURL,
                received: finalReceived,
                expected: finalExpected,
                averageBytesPerSecond: averageSpeed,
                averageUploadBytesPerSecond: nil,
                activeDownloadDuration: activeDuration
            )
        }
    }

    /// 失敗後清理 engine 狀態並回報 delegate。
    func fail(id: DownloadItem.ID, error: Error) {
        singleDataTasksByID[id] = nil
        dataTasksByID[id] = nil
        itemsByID[id] = nil
        retryCounts[id] = nil
        segmentRetryCounts[id] = nil
        cancelScheduledSegmentRetries(id: id)
        activeSegmentTaskIDs[id] = nil
        segmentConnectionLimits[id] = nil
        connectionLastSamples[id] = nil
        connectionDisplayedSpeeds[id] = nil
        lastSamples[id] = nil
        displayedSpeeds[id] = nil
        singleTargetURLsByID[id] = nil
        singleExpectedBytesByID[id] = nil
        singleReceivedBytesByID[id] = nil
        transferTimingsByID[id] = nil
        switchingToSegmentedIDs.remove(id)
        Task { @MainActor [weak self] in
            self?.delegate?.fail(id: id, errorMessage: error.localizedDescription)
        }
    }

    /// 回報補充狀態文字。
    func notifyStatus(id: DownloadItem.ID, message: String?) {
        Task { @MainActor [weak self] in
            self?.delegate?.updateStatusText(id: id, message: message)
        }
    }

    /// 單連線失敗時重試。
    func retrySingleDownload(id: DownloadItem.ID, error: Error) {
        guard let item = itemsByID[id] else {
            fail(id: id, error: error)
            return
        }

        let nextRetry = (retryCounts[id] ?? 0) + 1
        guard nextRetry <= Self.maximumRetryCount else {
            fail(id: id, error: error)
            return
        }

        retryCounts[id] = nextRetry
        singleDataTasksByID[id] = nil
        notifyStatus(id: id, message: "Retrying connection \(nextRetry)/\(Self.maximumRetryCount)")

        startSingleDownload(item: item)
    }

    /// Server 無法穩定提供 Range 時，清理所有分段並從單線重新開始。
    func fallbackSegmentedDownloadToSingle(id: DownloadItem.ID) {
        guard let item = segmentedDownloads[id]?.item else { return }

        cleanupSegmentedDownload(id: id)
        incompleteFilesByID[id] = nil
        singleExpectedBytesByID[id] = nil
        singleReceivedBytesByID[id] = nil
        segmentRetryCounts[id] = nil
        lastSamples[id] = nil
        displayedSpeeds[id] = nil
        resetTransferTiming(id: id, received: 0)
        switchingToSegmentedIDs.remove(id)
        notifyStatus(id: id, message: "Single connection")
        startSingleDownload(item: item)
    }

    /// 暫時性 HTTP 錯誤保留分段狀態，稍後只重試受影響的分段。
    func scheduleSegmentRetry(id: DownloadItem.ID, index: Int, error: Error) {
        let currentRetry = segmentRetryCounts[id]?[index] ?? 0
        let nextRetry = currentRetry + 1
        guard nextRetry <= Self.maximumRetryCount else {
            fail(id: id, error: error)
            return
        }

        let serverDelay = (error as NSError).userInfo["RetryAfter"] as? TimeInterval ?? 0
        let backoffDelay = pow(2, Double(currentRetry))
        let delay = max(serverDelay, backoffDelay)
        notifyStatus(id: id, message: "Retrying connection \(nextRetry)/\(Self.maximumRetryCount)")

        scheduledSegmentStarts[id]?[index]?.cancel()
        let retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }

            self.scheduledSegmentStarts[id]?[index] = nil
            self.retrySegmentDownload(id: id, index: index, error: error)
        }
        scheduledSegmentStarts[id, default: [:]][index] = retryTask
    }

    func cancelScheduledSegmentRetries(id: DownloadItem.ID) {
        scheduledSegmentStarts[id]?.values.forEach { $0.cancel() }
        scheduledSegmentStarts[id] = nil
    }

    /// 初始分段錯開 0.4 秒啟動；降級後等待現有 task 釋放名額。
    func enqueueSegmentTasks(_ tasks: [URLSessionDataTask], id: DownloadItem.ID) {
        for (offset, task) in tasks.enumerated() {
            guard case let .segment(_, index)? = taskPurposes[task.taskIdentifier] else { continue }
            enqueueSegmentTask(task, id: id, index: index, delay: Double(offset) * 0.4)
        }
    }

    func enqueueSegmentTask(
        _ task: URLSessionDataTask,
        id: DownloadItem.ID,
        index: Int,
        delay: TimeInterval = 0
    ) {
        scheduledSegmentStarts[id]?[index]?.cancel()
        let startTask = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }

            guard !Task.isCancelled, let self else { return }
            while self.activeSegmentTaskIDs[id, default: []].count
                >= (self.segmentConnectionLimits[id] ?? Self.segmentedThreadCount) {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }

            self.scheduledSegmentStarts[id]?[index] = nil
            self.segmentConnectionLimitByTaskID[task.taskIdentifier] =
                self.segmentConnectionLimits[id] ?? Self.segmentedThreadCount
            self.activeSegmentTaskIDs[id, default: []].insert(task.taskIdentifier)
            task.resume()
        }
        scheduledSegmentStarts[id, default: [:]][index] = startTask
    }

    /// 驗證分段是否真的完整；完整後檢查能否合併，否則續傳缺少的 bytes。
    func handleSegmentCompletion(id: DownloadItem.ID, index: Int, error: Error?) {
        guard var state = segmentedDownloads[id],
              var segment = state.segments[index]
        else {
            if let error {
                fail(id: id, error: error)
            }
            return
        }

        let expectedBytes = segment.range.upperBound - segment.range.lowerBound + 1
        if segment.received == expectedBytes {
            segment.isFinished = true
            state.segments[index] = segment
            segmentedDownloads[id] = state
            segmentRetryCounts[id]?[index] = nil
            publishHTTPConnectionDetails(id: id)

            if state.segments.values.allSatisfy(\.isFinished) {
                do {
                    try mergeSegmentedDownload(id: id)
                } catch {
                    cleanupSegmentedDownload(id: id)
                    fail(id: id, error: error)
                }
            }
            return
        }

        let completionError: Error
        if segment.received > expectedBytes {
            completionError = NSError(
                domain: Self.errorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Server returned more bytes than requested."]
            )
            cleanupSegmentedDownload(id: id)
            fail(id: id, error: completionError)
            return
        } else {
            completionError = error ?? NSError(
                domain: Self.errorDomain,
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "The connection ended before the segment was complete."]
            )
        }

        retrySegmentDownload(id: id, index: index, error: completionError)
    }

    /// 分段下載其中一段失敗時，只重試該段。
    ///
    /// 下載會保持分段模式，並只補回該段尚未完成的 byte range；
    /// 即使連線數降至 1，也不會刪除已下載資料或由頭開始。
    func retrySegmentDownload(id: DownloadItem.ID, index: Int, error: Error) {
        guard let state = segmentedDownloads[id],
              let segment = state.segments[index]
        else {
            fail(id: id, error: error)
            return
        }

        let nextRetry = (segmentRetryCounts[id]?[index] ?? 0) + 1
        guard nextRetry <= Self.maximumRetryCount else {
            fail(id: id, error: error)
            return
        }

        segmentRetryCounts[id, default: [:]][index] = nextRetry

        let nextByte = segment.range.lowerBound + segment.received
        guard nextByte <= segment.range.upperBound else {
            handleSegmentCompletion(id: id, index: index, error: nil)
            return
        }

        var request = downloadRequest(for: state.item.source)
        setByteRange("bytes=\(nextByte)-\(segment.range.upperBound)", on: &request)

        let task = session.dataTask(with: request)
        taskPurposes[task.taskIdentifier] = .segment(id, index)
        segmentStartOffsetsByTaskID[task.taskIdentifier] = nextByte
        dataTasksByID[id, default: []].append(task)
        notifyStatus(id: id, message: segmentConnectionStatus(id: id))
        enqueueSegmentTask(task, id: id, index: index)
    }

    func segmentConnectionStatus(id: DownloadItem.ID) -> String {
        let connectionCount = segmentConnectionLimits[id] ?? Self.segmentedThreadCount
        return connectionCount == 1 ? "1 connection" : "\(connectionCount) connections"
    }

    /// 建立下載 request，集中設定 User-Agent、Accept、timeout。
    func downloadRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Downloader/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("keep-alive", forHTTPHeaderField: "Connection")
        request.timeoutInterval = 60
        return request
    }

    /// Range request 不可使用普通 GET 的快取，亦不可接受會改變 byte offsets 的內容壓縮。
    func setByteRange(_ value: String, on request: inout URLRequest) {
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(value, forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    }

    /// `Retry-After` 可以是秒數；沒有或無法解析時由本地 exponential backoff 決定。
    func retryDelay(from response: HTTPURLResponse) -> TimeInterval {
        guard let value = response.value(forHTTPHeaderField: "Retry-After"),
              let delay = TimeInterval(value)
        else { return 0 }
        return max(0, delay)
    }

    /// 從 Content-Range 解析總大小，例如 `bytes 0-0/104857600`。
    func totalBytes(fromContentRange contentRange: String) -> Int64? {
        guard let slashIndex = contentRange.lastIndex(of: "/") else { return nil }
        let total = contentRange[contentRange.index(after: slashIndex)...]
        return Int64(total)
    }

    /// 解析完整 Content-Range，例如 `bytes 26214400-52428799/104857600`。
    func byteRange(fromContentRange contentRange: String) -> (start: Int64, end: Int64, total: Int64)? {
        let value = contentRange.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.lowercased().hasPrefix("bytes ") else { return nil }

        let rangeAndTotal = value.dropFirst(6).split(separator: "/", maxSplits: 1)
        guard rangeAndTotal.count == 2,
              let total = Int64(rangeAndTotal[1])
        else { return nil }

        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1])
        else { return nil }

        return (start, end, total)
    }

    /// 取得檔案大小；檔案不存在時回傳 0。
    func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// 建立 HTTP 分段暫存檔名。
    ///
    /// 用統一 helper 可以確保單線一開始就是第 0 段，
    /// 後續升級多線時才會自然接上第 1、2、3 段。
    func partFilename(for filename: String, index: Int) -> String {
        "\(filename).part-\(index).tmp"
    }

    /// 避免覆蓋同名檔案。如果已存在，就產生 `name 1.ext`、`name 2.ext`。
    func uniqueFileURL(in folder: URL, filename: String) -> URL {
        let baseURL = folder.appending(path: filename)
        guard !FileManager.default.fileExists(atPath: baseURL.path) else {
            let name = baseURL.deletingPathExtension().lastPathComponent
            let ext = baseURL.pathExtension

            for index in 1...999 {
                let candidateName = ext.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(ext)"
                let candidate = folder.appending(path: candidateName)
                if !FileManager.default.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }

            return folder.appending(path: UUID().uuidString + (ext.isEmpty ? "" : ".\(ext)"))
        }

        return baseURL
    }
}
