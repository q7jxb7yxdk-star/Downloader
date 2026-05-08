import Foundation

@MainActor
protocol HTTPDownloadEngineDelegate: AnyObject {
    func update(id: DownloadItem.ID, progress: Double, received: Int64, expected: Int64, speed: Int64)
    func updateStatusText(id: DownloadItem.ID, message: String?)
    func complete(id: DownloadItem.ID, fileURL: URL)
    func fail(id: DownloadItem.ID, errorMessage: String?)
}

final class HTTPDownloadEngine: NSObject, @unchecked Sendable {
    private enum TaskPurpose {
        case single(DownloadItem.ID)
        case segment(DownloadItem.ID, Int)
    }

    private struct SegmentState {
        let index: Int
        let range: ClosedRange<Int64>
        let fileURL: URL
        var received: Int64 = 0
        var isFinished = false
    }

    private struct SegmentedDownloadState {
        let item: DownloadItem
        let totalBytes: Int64
        let targetURL: URL
        let tempDirectory: URL
        var segments: [Int: SegmentState]
    }

    private static let segmentedThreadCount = 4
    private static let minimumSegmentedSize: Int64 = 8 * 1024 * 1024

    private weak var delegate: HTTPDownloadEngineDelegate?
    private var session: URLSession!
    private var taskPurposes: [Int: TaskPurpose] = [:]
    private var downloadTasksByID: [DownloadItem.ID: URLSessionDownloadTask] = [:]
    private var dataTasksByID: [DownloadItem.ID: [URLSessionDataTask]] = [:]
    private var itemsByID: [DownloadItem.ID: DownloadItem] = [:]
    private var resumeData: [DownloadItem.ID: Data] = [:]
    private var lastSamples: [DownloadItem.ID: (date: Date, bytes: Int64)] = [:]
    private var segmentedDownloads: [DownloadItem.ID: SegmentedDownloadState] = [:]
    private var outputStreams: [Int: OutputStream] = [:]

    init(delegate: HTTPDownloadEngineDelegate) {
        self.delegate = delegate
        super.init()

        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = Self.segmentedThreadCount
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }

    func start(item: DownloadItem) {
        itemsByID[item.id] = item
        notifyStatus(id: item.id, message: "Checking range support")

        Task { [weak self] in
            await self?.startAfterProbe(item: item)
        }
    }

    func pause(id: DownloadItem.ID) {
        if let dataTasks = dataTasksByID[id] {
            dataTasks.forEach { $0.cancel() }
            dataTasksByID[id] = nil
            closeSegmentStreams(for: id)
            return
        }

        guard let task = downloadTasksByID[id] else { return }
        task.cancel { [weak self] data in
            Task { @MainActor in
                if let data {
                    self?.resumeData[id] = data
                }
                self?.downloadTasksByID[id] = nil
            }
        }
    }

    func resume(item: DownloadItem) {
        if segmentedDownloads[item.id] != nil {
            cleanupSegmentedDownload(id: item.id)
            start(item: item)
            return
        }

        let task: URLSessionDownloadTask
        if let data = resumeData[item.id] {
            task = session.downloadTask(withResumeData: data)
            resumeData[item.id] = nil
        } else {
            task = session.downloadTask(with: item.source)
        }
        startSingleTask(task, item: item)
    }

    @MainActor
    private func startAfterProbe(item: DownloadItem) async {
        do {
            let probe = try await probeRangeSupport(for: item.source)
            guard probe.supportsRange, probe.contentLength >= Self.minimumSegmentedSize else {
                delegate?.updateStatusText(id: item.id, message: "Single connection")
                startSingleTask(session.downloadTask(with: item.source), item: item)
                return
            }

            try startSegmentedDownload(item: item, totalBytes: probe.contentLength)
        } catch {
            delegate?.updateStatusText(id: item.id, message: "Single connection")
            startSingleTask(session.downloadTask(with: item.source), item: item)
        }
    }

    private func probeRangeSupport(for url: URL) async throws -> (supportsRange: Bool, contentLength: Int64) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return (false, 0)
        }

        let acceptsRanges = (httpResponse.value(forHTTPHeaderField: "Accept-Ranges") ?? "").lowercased().contains("bytes")
        let contentLength = Int64(httpResponse.value(forHTTPHeaderField: "Content-Length") ?? "") ?? httpResponse.expectedContentLength
        return (acceptsRanges && contentLength > 0, contentLength)
    }

    private func startSingleTask(_ task: URLSessionDownloadTask, item: DownloadItem) {
        taskPurposes[task.taskIdentifier] = .single(item.id)
        downloadTasksByID[item.id] = task
        itemsByID[item.id] = item
        task.resume()
    }

    private func startSegmentedDownload(item: DownloadItem, totalBytes: Int64) throws {
        let folder = item.destination ?? FolderBookmarkStore.fallbackFolder
        let targetURL = uniqueFileURL(in: folder, filename: item.name)
        let tempDirectory = FileManager.default.temporaryDirectory
            .appending(path: "Downloader-\(item.id.uuidString)", directoryHint: .isDirectory)

        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        let ranges = byteRanges(totalBytes: totalBytes, count: Self.segmentedThreadCount)
        var segments: [Int: SegmentState] = [:]
        var tasks: [URLSessionDataTask] = []

        for (index, range) in ranges.enumerated() {
            let fileURL = tempDirectory.appending(path: "part-\(index)")
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)

            var request = URLRequest(url: item.source)
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
            tempDirectory: tempDirectory,
            segments: segments
        )
        dataTasksByID[item.id] = tasks
        itemsByID[item.id] = item
        notifyStatus(id: item.id, message: "\(Self.segmentedThreadCount) connections")

        tasks.forEach { $0.resume() }
    }

    private func byteRanges(totalBytes: Int64, count: Int) -> [ClosedRange<Int64>] {
        let segmentSize = totalBytes / Int64(count)
        return (0..<count).map { index in
            let start = Int64(index) * segmentSize
            let end = index == count - 1 ? totalBytes - 1 : (start + segmentSize - 1)
            return start...end
        }
    }
}

extension HTTPDownloadEngine: URLSessionDownloadDelegate, URLSessionDataDelegate {
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

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
        guard case let .segment(id, index)? = taskPurposes[dataTask.taskIdentifier],
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 206,
              let state = segmentedDownloads[id],
              let segment = state.segments[index],
              let stream = OutputStream(url: segment.fileURL, append: false)
        else {
            return .cancel
        }

        stream.open()
        outputStreams[dataTask.taskIdentifier] = stream
        return .allow
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
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
                fail(id: id, error: error)
            case let .segment(id, _):
                cleanupSegmentedDownload(id: id)
                fail(id: id, error: error)
            case nil:
                break
            }
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
    func updateProgress(id: DownloadItem.ID, received: Int64, expected: Int64) {
        let now = Date()
        let previous = lastSamples[id] ?? (now, received)
        let elapsed = now.timeIntervalSince(previous.date)
        let speed = elapsed > 0 ? Int64(Double(received - previous.bytes) / elapsed) : 0
        lastSamples[id] = (now, received)

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

    func cleanupSegmentedDownload(id: DownloadItem.ID) {
        dataTasksByID[id]?.forEach { $0.cancel() }
        dataTasksByID[id] = nil
        closeSegmentStreams(for: id)

        if let state = segmentedDownloads[id] {
            try? FileManager.default.removeItem(at: state.tempDirectory)
        }
        segmentedDownloads[id] = nil
    }

    func finish(id: DownloadItem.ID, fileURL: URL) {
        downloadTasksByID[id] = nil
        dataTasksByID[id] = nil
        itemsByID[id] = nil
        lastSamples[id] = nil
        Task { @MainActor [weak self] in
            self?.delegate?.complete(id: id, fileURL: fileURL)
        }
    }

    func fail(id: DownloadItem.ID, error: Error) {
        downloadTasksByID[id] = nil
        dataTasksByID[id] = nil
        itemsByID[id] = nil
        lastSamples[id] = nil
        Task { @MainActor [weak self] in
            self?.delegate?.fail(id: id, errorMessage: error.localizedDescription)
        }
    }

    func notifyStatus(id: DownloadItem.ID, message: String?) {
        Task { @MainActor [weak self] in
            self?.delegate?.updateStatusText(id: id, message: message)
        }
    }

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
