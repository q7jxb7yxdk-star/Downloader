import Foundation

/// HTTP engine 回報下載狀態給 DownloadManager 的介面。
///
/// protocol 讓 engine 不需要直接依賴 SwiftUI 或 DownloadManager 的具體型別。
@MainActor
protocol HTTPDownloadEngineDelegate: AnyObject {
    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64)
    func updateStatusText(id: DownloadItem.ID, message: String?)
    func complete(id: DownloadItem.ID, fileURL: URL)
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

    /// HTTP 分段數。4 條連線通常已經有明顯加速，也不會太容易被 server 視為濫用。
    private static let segmentedThreadCount = 4

    /// 小檔案不分段，因為建立多個連線和合併檔案本身也有成本。
    private static let minimumSegmentedSize: Int64 = 8 * 1024 * 1024

    /// 單連線失敗時最多重試次數。
    private static let maximumRetryCount = 3

    /// 背景 Range 探測最多等待時間。
    ///
    /// 下載已經先開始了，所以這裡可以等久一點；server 慢回應時仍有機會升級成多線。
    private static let rangeProbeTimeout: TimeInterval = 15

    private weak var delegate: HTTPDownloadEngineDelegate?
    private var session: URLSession!

    /// 下列 dictionary 都是用 download item id 或 task id，把非同步 callback 對回正確任務。
    private var taskPurposes: [Int: TaskPurpose] = [:]
    private var singleDataTasksByID: [DownloadItem.ID: URLSessionDataTask] = [:]
    private var dataTasksByID: [DownloadItem.ID: [URLSessionDataTask]] = [:]
    private var itemsByID: [DownloadItem.ID: DownloadItem] = [:]
    private var retryCounts: [DownloadItem.ID: Int] = [:]
    private var lastSamples: [DownloadItem.ID: (date: Date, bytes: Int64)] = [:]
    private var displayedSpeeds: [DownloadItem.ID: Int64] = [:]
    private var segmentedDownloads: [DownloadItem.ID: SegmentedDownloadState] = [:]
    private var incompleteFilesByID: [DownloadItem.ID: URL] = [:]
    private var singleTargetURLsByID: [DownloadItem.ID: URL] = [:]
    private var singleExpectedBytesByID: [DownloadItem.ID: Int64] = [:]
    private var singleReceivedBytesByID: [DownloadItem.ID: Int64] = [:]
    private var singleStartOffsetsByTaskID: [Int: Int64] = [:]
    private var switchingToSegmentedIDs: Set<DownloadItem.ID> = []
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
        if let dataTasks = dataTasksByID[id] {
            dataTasks.forEach { $0.cancel() }
            dataTasksByID[id] = nil
            closeSegmentStreams(for: id)
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
        itemsByID[id] = nil
        lastSamples[id] = nil
        displayedSpeeds[id] = nil
        singleTargetURLsByID[id] = nil
        singleExpectedBytesByID[id] = nil
        singleReceivedBytesByID[id] = nil
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
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        request.timeoutInterval = Self.rangeProbeTimeout

        let (_, response) = try await URLSession.shared.data(for: request)
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
            request.setValue("bytes=\(existingBytes)-", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        taskPurposes[task.taskIdentifier] = .single(item.id)
        singleDataTasksByID[item.id] = task
        itemsByID[item.id] = item
        singleReceivedBytesByID[item.id] = existingBytes
        singleStartOffsetsByTaskID[task.taskIdentifier] = existingBytes
        notifyStatus(id: item.id, message: "Single connection")
        task.resume()
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
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")

            let task = session.dataTask(with: request)
            taskPurposes[task.taskIdentifier] = .segment(item.id, index)
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
        itemsByID[item.id] = item
        notifyStatus(id: item.id, message: "\(Self.segmentedThreadCount) connections")

        tasks.forEach { $0.resume() }
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
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")

            let task = session.dataTask(with: request)
            taskPurposes[task.taskIdentifier] = .segment(item.id, index)
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
        itemsByID[item.id] = item
        singleExpectedBytesByID[item.id] = nil
        singleReceivedBytesByID[item.id] = nil
        singleTargetURLsByID[item.id] = nil
        notifyStatus(id: item.id, message: "\(tasks.count + 1) connections")
        updateProgress(id: item.id, received: downloadedBytes, expected: totalBytes)

        tasks.forEach { $0.resume() }
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
                try? Data().write(to: fileURL)
                singleStartOffsetsByTaskID[dataTask.taskIdentifier] = 0
                singleReceivedBytesByID[id] = 0
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
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 206,
              let state = segmentedDownloads[id],
              let segment = state.segments[index],
              let stream = OutputStream(url: segment.fileURL, append: segment.received > 0)
        else {
            return .cancel
        }

        stream.open()
        outputStreams[dataTask.taskIdentifier] = stream
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
            updateProgress(id: id, received: received, expected: singleExpectedBytesByID[id] ?? 0)
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

        let received = state.segments.values.reduce(Int64(0)) { $0 + $1.received }
        updateProgress(id: id, received: received, expected: state.totalBytes)
    }

    /// 任務完成或失敗 callback。
    ///
    /// 分段全部完成後會合併檔案；單連線失敗會重試；分段失敗只重試該段。
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            taskPurposes[task.taskIdentifier] = nil
            outputStreams.removeValue(forKey: task.taskIdentifier)?.close()
        }

        if let error {
            let nsError = error as NSError
            guard nsError.code != NSURLErrorCancelled else { return }

            switch taskPurposes[task.taskIdentifier] {
            case let .single(id):
                if switchingToSegmentedIDs.remove(id) != nil {
                    return
                }
                retrySingleDownload(id: id, error: error)
            case let .segment(id, index):
                retrySegmentDownload(id: id, index: index, error: error)
            case nil:
                break
            }
            return
        }

        if case let .single(id)? = taskPurposes[task.taskIdentifier] {
            completeSingleDownload(id: id)
            return
        }

        guard case let .segment(id, index)? = taskPurposes[task.taskIdentifier],
              var state = segmentedDownloads[id],
              var segment = state.segments[index]
        else { return }

        segment.isFinished = true
        state.segments[index] = segment
        segmentedDownloads[id] = state

        if state.segments.values.allSatisfy(\.isFinished) {
            do {
                try mergeSegmentedDownload(id: id)
            } catch {
                cleanupSegmentedDownload(id: id)
                fail(id: id, error: error)
            }
        }
    }
}

private extension HTTPDownloadEngine {
    /// 更新進度並計算平滑後速度。
    ///
    /// 即時速度會跳得很厲害，所以這裡每 0.5 秒取樣一次，並用 70/30 權重平滑顯示。
    func updateProgress(id: DownloadItem.ID, received: Int64, expected: Int64) {
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
                speed: speed
            )
        }
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
                    let data = try input.read(upToCount: 1024 * 1024) ?? Data()
                    if data.isEmpty { break }
                    try output.write(contentsOf: data)
                }
            }
        }

        cleanupSegmentedDownload(id: id)
        finish(id: id, fileURL: state.targetURL)
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
            incompleteFilesByID[id] = nil
            finish(id: id, fileURL: targetURL)
        } catch {
            fail(id: id, error: error)
        }
    }

    /// 分段下載的續傳。
    ///
    /// 每段根據已寫入 byte 數重新設定 Range，例如原本 0-999，已收 300，就請求 300-999。
    func resumeSegmentedDownload(id: DownloadItem.ID) {
        guard var state = segmentedDownloads[id] else { return }

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
            request.setValue("bytes=\(nextByte)-\(segment.range.upperBound)", forHTTPHeaderField: "Range")

            let task = session.dataTask(with: request)
            taskPurposes[task.taskIdentifier] = .segment(id, index)
            tasks.append(task)
        }

        segmentedDownloads[id] = state
        dataTasksByID[id] = tasks
        itemsByID[id] = state.item

        let received = state.segments.values.reduce(Int64(0)) { $0 + $1.received }
        lastSamples[id] = (Date(), received)
        displayedSpeeds[id] = 0

        if state.segments.values.allSatisfy(\.isFinished) {
            do {
                try mergeSegmentedDownload(id: id)
            } catch {
                cleanupSegmentedDownload(id: id)
                fail(id: id, error: error)
            }
            return
        }

        notifyStatus(id: id, message: "\(Self.segmentedThreadCount) connections")
        updateProgress(id: id, received: received, expected: state.totalBytes)
        tasks.forEach { $0.resume() }
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
        dataTasksByID[id]?.forEach { $0.cancel() }
        dataTasksByID[id] = nil
        closeSegmentStreams(for: id)

        if let state = segmentedDownloads[id] {
            for fileURL in state.temporaryFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
        segmentedDownloads[id] = nil
    }

    /// 完成後清理 engine 狀態並回報 delegate。
    func finish(id: DownloadItem.ID, fileURL: URL) {
        singleDataTasksByID[id] = nil
        dataTasksByID[id] = nil
        removeIncompleteFile(id: id)
        itemsByID[id] = nil
        retryCounts[id] = nil
        lastSamples[id] = nil
        displayedSpeeds[id] = nil
        singleTargetURLsByID[id] = nil
        singleExpectedBytesByID[id] = nil
        singleReceivedBytesByID[id] = nil
        switchingToSegmentedIDs.remove(id)
        Task { @MainActor [weak self] in
            self?.delegate?.complete(id: id, fileURL: fileURL)
        }
    }

    /// 失敗後清理 engine 狀態並回報 delegate。
    func fail(id: DownloadItem.ID, error: Error) {
        singleDataTasksByID[id] = nil
        dataTasksByID[id] = nil
        itemsByID[id] = nil
        retryCounts[id] = nil
        lastSamples[id] = nil
        displayedSpeeds[id] = nil
        singleTargetURLsByID[id] = nil
        singleExpectedBytesByID[id] = nil
        singleReceivedBytesByID[id] = nil
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

    /// 分段下載其中一段失敗時，只重試該段。
    ///
    /// 這樣下載一旦成功升級成 4 connections，就會保持分段模式；
    /// 不會因為某一段短暫斷線而整個退回 1 connection。
    func retrySegmentDownload(id: DownloadItem.ID, index: Int, error: Error) {
        guard var state = segmentedDownloads[id],
              var segment = state.segments[index]
        else {
            fail(id: id, error: error)
            return
        }

        let nextRetry = (retryCounts[id] ?? 0) + 1
        guard nextRetry <= Self.maximumRetryCount else {
            fail(id: id, error: error)
            return
        }

        retryCounts[id] = nextRetry

        let nextByte = segment.range.lowerBound + segment.received
        guard nextByte <= segment.range.upperBound else {
            segment.isFinished = true
            state.segments[index] = segment
            segmentedDownloads[id] = state
            return
        }

        var request = downloadRequest(for: state.item.source)
        request.setValue("bytes=\(nextByte)-\(segment.range.upperBound)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        taskPurposes[task.taskIdentifier] = .segment(id, index)
        dataTasksByID[id, default: []].append(task)
        notifyStatus(id: id, message: "\(Self.segmentedThreadCount) connections")
        task.resume()
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

    /// 從 Content-Range 解析總大小，例如 `bytes 0-0/104857600`。
    func totalBytes(fromContentRange contentRange: String) -> Int64? {
        guard let slashIndex = contentRange.lastIndex(of: "/") else { return nil }
        let total = contentRange[contentRange.index(after: slashIndex)...]
        return Int64(total)
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
