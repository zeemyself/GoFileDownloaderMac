import AppKit
import Foundation
import Observation

public enum DownloadItemStatus: Equatable, Sendable {
    case queued
    case downloading(resumed: Bool)
    case retrying(attempt: Int, max: Int)
    case completed(resumed: Bool)
    case skipped
    case failed(String)
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .completed, .skipped, .failed, .cancelled:
            return true
        case .queued, .downloading, .retrying:
            return false
        }
    }

    public var label: String {
        switch self {
        case .queued:
            return "Queued"
        case .downloading(let resumed):
            return resumed ? "Resuming" : "Downloading"
        case .retrying(let attempt, let max):
            return "Retry \(attempt)/\(max)"
        case .completed(let resumed):
            return resumed ? "Done (Resumed)" : "Completed"
        case .skipped:
            return "Skipped"
        case .failed:
            return "Failed"
        case .cancelled:
            return "Cancelled"
        }
    }
}

@Observable
@MainActor
public final class DownloadItem: Identifiable {
    public let id: String
    public let remoteFile: RemoteFile
    public let destinationURL: URL

    public var bytesReceived: Int64 = 0
    public var totalBytes: Int64?
    public var speedBytesPerSec: Double = 0
    public var status: DownloadItemStatus = .queued

    private var lastSampleTime: ContinuousClock.Instant?
    private var lastSampleBytes: Int64 = 0

    public init(remoteFile: RemoteFile, baseDirectory: URL) {
        self.id = remoteFile.id
        self.remoteFile = remoteFile
        self.destinationURL = FileDownloader.destinationURL(baseDirectory: baseDirectory, file: remoteFile)
        self.totalBytes = remoteFile.expectedSize
    }

    public var filename: String { remoteFile.filename }
    public var relativePath: String { remoteFile.relativePath }

    public var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1.0, max(0.0, Double(bytesReceived) / Double(totalBytes)))
    }

    public var etaString: String {
        guard case .downloading = status,
              let totalBytes, totalBytes > bytesReceived else {
            return "—"
        }
        return Formatters.eta(remainingBytes: totalBytes - bytesReceived, bytesPerSecond: speedBytesPerSec)
    }

    public func recordProgress(bytesReceived: Int64, totalBytes: Int64?) {
        let now = ContinuousClock.now
        if let lastTime = lastSampleTime {
            let elapsed = now - lastTime
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            if seconds >= 0.05 {
                let delta = max(0, bytesReceived - lastSampleBytes)
                let instantSpeed = Double(delta) / seconds
                if speedBytesPerSec == 0 {
                    speedBytesPerSec = instantSpeed
                } else {
                    speedBytesPerSec = 0.35 * instantSpeed + 0.65 * speedBytesPerSec
                }
                lastSampleTime = now
                lastSampleBytes = bytesReceived
            }
        } else {
            lastSampleTime = now
            lastSampleBytes = bytesReceived
        }

        self.bytesReceived = bytesReceived
        if let totalBytes {
            self.totalBytes = totalBytes
        }
    }

    public func resetSpeed() {
        speedBytesPerSec = 0
        lastSampleTime = nil
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let event: String
    public let details: String

    public init(timestamp: Date = .now, event: String, details: String) {
        self.timestamp = timestamp
        self.event = event
        self.details = details
    }
}

public enum SessionState: Equatable {
    case idle
    case resolving
    case downloading
    case finished
    case cancelled
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .resolving, .downloading:
            return true
        default:
            return false
        }
    }
}

@Observable
@MainActor
public final class DownloadStore {
    public static let downloadFolderKey = "downloadFolderPath"
    public static let maxConcurrentKey = "maxConcurrentDownloads"
    public static let maxRetriesKey = "maxDownloadRetries"

    public var urlInput: String = "" {
        didSet {
            if hasInvalidURL, urlInput != oldValue {
                hasInvalidURL = false
            }
        }
    }
    public var passwordInput: String = ""
    public var needsPasswordPrompt: Bool = false
    public var hasInvalidURL: Bool = false

    public var downloadFolder: URL {
        didSet {
            userDefaults.set(downloadFolder.path, forKey: Self.downloadFolderKey)
        }
    }

    public var maxConcurrent: Int {
        didSet {
            userDefaults.set(maxConcurrent, forKey: Self.maxConcurrentKey)
        }
    }

    public var maxRetries: Int {
        didSet {
            userDefaults.set(maxRetries, forKey: Self.maxRetriesKey)
        }
    }

    public var state: SessionState = .idle
    public var contentID: String?
    public var items: [DownloadItem] = []
    public var logs: [LogEntry] = []

    private var itemByID: [String: DownloadItem] = [:]
    public private(set) var sessionID = UUID()
    private var sessionToken = UUID()
    private var sessionBaseDirectory: URL?
    private var resolveTask: Task<Void, Never>?
    private var tokenFetchTask: Task<String, Error>?
    private var pendingQueue: [String] = []
    private var runningWorkerTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var lastAccountToken: String?
    private let api: GoFileAPI
    private let engine: DownloadEngine
    private let userDefaults: UserDefaults

    public init(
        api: GoFileAPI = GoFileAPI(),
        engine: DownloadEngine = DownloadEngine(),
        userDefaults: UserDefaults = .standard
    ) {
        self.api = api
        self.engine = engine
        self.userDefaults = userDefaults

        if let savedPath = userDefaults.string(forKey: Self.downloadFolderKey), !savedPath.isEmpty {
            self.downloadFolder = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            self.downloadFolder = downloads.appendingPathComponent("GoFile", isDirectory: true)
        }

        let savedConcurrent = userDefaults.integer(forKey: Self.maxConcurrentKey)
        self.maxConcurrent = savedConcurrent > 0 ? min(8, savedConcurrent) : GoFileConfig.defaultMaxWorkers

        if userDefaults.object(forKey: Self.maxRetriesKey) != nil {
            self.maxRetries = max(0, min(10, userDefaults.integer(forKey: Self.maxRetriesKey)))
        } else {
            self.maxRetries = GoFileConfig.defaultMaxRetries
        }
    }

    // MARK: - Computed metrics

    public var parsedContentID: String? {
        GoFileAPI.contentID(from: urlInput)
    }

    public var canStart: Bool {
        !state.isActive && !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var completedFilesCount: Int {
        items.filter {
            switch $0.status {
            case .completed, .skipped: return true
            default: return false
            }
        }.count
    }

    public var failedFilesCount: Int {
        items.filter {
            if case .failed = $0.status { return true }
            return false
        }.count
    }

    public var totalBytesReceived: Int64 {
        items.reduce(0) { $0 + $1.bytesReceived }
    }

    public var totalBytesExpected: Int64 {
        items.reduce(0) { $0 + ($1.totalBytes ?? $1.bytesReceived) }
    }

    public var aggregateSpeed: Double {
        items.reduce(0) { acc, item in
            if case .downloading = item.status {
                return acc + item.speedBytesPerSec
            }
            return acc
        }
    }

    public var overallFraction: Double {
        guard !items.isEmpty else { return 0 }
        let expected = totalBytesExpected
        if expected > 0 {
            return min(1.0, Double(totalBytesReceived) / Double(expected))
        }
        return Double(completedFilesCount) / Double(items.count)
    }

    public var overallETAString: String {
        guard state == .downloading else { return "—" }
        let remaining = max(0, totalBytesExpected - totalBytesReceived)
        return Formatters.eta(remainingBytes: remaining, bytesPerSecond: aggregateSpeed)
    }

    // MARK: - Actions

    public func chooseDownloadFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = downloadFolder

        if panel.runModal() == .OK, let url = panel.url {
            downloadFolder = url
        }
    }

    public func revealDownloadFolder() {
        try? FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(downloadFolder)
    }

    public func revealItem(_ item: DownloadItem) {
        let fm = FileManager.default
        let baseDir = sessionBaseDirectory ?? downloadFolder
        let partURL = FileDownloader.partURL(for: item.remoteFile, in: baseDir)
        if fm.fileExists(atPath: item.destinationURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL])
        } else if fm.fileExists(atPath: partURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([partURL])
        } else {
            let folder = item.destinationURL.deletingLastPathComponent()
            NSWorkspace.shared.open(fm.fileExists(atPath: folder.path) ? folder : baseDir)
        }
    }

    public func openDownloadedFile(_ item: DownloadItem) {
        guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return }
        NSWorkspace.shared.open(item.destinationURL)
    }

    public func retryItems(withIDs ids: Set<DownloadItem.ID>, forceRestart: Bool = false) {
        let orderedItems = items.filter { ids.contains($0.id) }
        var queuedAny = false
        for item in orderedItems {
            if prepareForRetry(item, forceRestart: forceRestart) {
                queuedAny = true
            }
        }
        if queuedAny {
            startQueuedRetriesIfNeeded()
        } else {
            finalizeSessionStateIfIdle()
        }
    }

    public func retryItem(_ item: DownloadItem, forceRestart: Bool = false) {
        if prepareForRetry(item, forceRestart: forceRestart) {
            startQueuedRetriesIfNeeded()
        } else {
            finalizeSessionStateIfIdle()
        }
    }

    private func prepareForRetry(_ item: DownloadItem, forceRestart: Bool) -> Bool {
        guard item.status.isTerminal else { return false }
        guard runningWorkerTasks[item.id] == nil, !pendingQueue.contains(item.id) else {
            return false
        }

        if forceRestart {
            let fm = FileManager.default
            let baseDir = sessionBaseDirectory ?? downloadFolder
            let partURL = FileDownloader.partURL(for: item.remoteFile, in: baseDir)
            let metaURL = FileDownloader.resumeMetaURL(for: partURL)
            do {
                if fm.fileExists(atPath: item.destinationURL.path) {
                    try fm.removeItem(at: item.destinationURL)
                }
                if fm.fileExists(atPath: partURL.path) {
                    try fm.removeItem(at: partURL)
                }
                if fm.fileExists(atPath: metaURL.path) {
                    try? fm.removeItem(at: metaURL)
                }
                FileDownloader.cleanupStagingDirectoryIfEmpty(in: baseDir)
            } catch {
                let details = "Could not remove existing file for \(item.filename): \(error.localizedDescription)"
                item.resetSpeed()
                item.status = .failed(details)
                appendLog(event: "Failed download", details: details)
                return false
            }
            item.bytesReceived = 0
        }

        item.resetSpeed()
        item.status = .queued
        if !state.isActive {
            state = .downloading
        }
        pendingQueue.append(item.id)

        appendLog(
            event: "Retrying download",
            details: "Manually retrying \(item.filename)\(forceRestart ? " from scratch" : "")..."
        )
        return true
    }

    private func startQueuedRetriesIfNeeded() {
        guard resolveTask == nil else { return }
        if lastAccountToken != nil {
            pumpQueue()
            return
        }
        guard tokenFetchTask == nil else { return }

        let capturedSessionToken = sessionToken
        let fetchTask = Task<String, Error> {
            try await self.api.createAccountToken()
        }
        tokenFetchTask = fetchTask

        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = try await fetchTask.value
                guard self.sessionToken == capturedSessionToken else { return }
                self.lastAccountToken = token
                self.tokenFetchTask = nil
                self.pumpQueue()
            } catch is CancellationError {
                guard self.sessionToken == capturedSessionToken else { return }
                self.tokenFetchTask = nil
                self.cancelPendingItemsAndFinalize()
            } catch let urlError as URLError where urlError.code == .cancelled {
                guard self.sessionToken == capturedSessionToken else { return }
                self.tokenFetchTask = nil
                self.cancelPendingItemsAndFinalize()
            } catch {
                guard self.sessionToken == capturedSessionToken else { return }
                self.tokenFetchTask = nil
                let queuedIDs = self.pendingQueue
                self.pendingQueue.removeAll()
                for id in queuedIDs {
                    if let queuedItem = self.itemByID[id], !queuedItem.status.isTerminal {
                        let details = "Failed to retry \(queuedItem.filename): \(error.localizedDescription)"
                        queuedItem.resetSpeed()
                        queuedItem.status = .failed(details)
                        self.appendLog(event: "Failed download", details: details)
                    }
                }
                self.finalizeSessionStateIfIdle()
            }
        }
    }

    private func cancelPendingItemsAndFinalize() {
        pendingQueue.removeAll()
        for item in items where !item.status.isTerminal {
            item.status = .cancelled
            item.resetSpeed()
        }
        finalizeSessionStateIfIdle()
    }

    private func pumpQueue() {
        guard resolveTask == nil else { return }
        let concurrency = max(1, maxConcurrent)

        if pendingQueue.isEmpty {
            finalizeSessionStateIfIdle()
            return
        }

        guard let token = lastAccountToken else {
            startQueuedRetriesIfNeeded()
            return
        }

        let targetFolder = sessionBaseDirectory ?? downloadFolder
        let retries = maxRetries
        let capturedSessionToken = sessionToken

        while runningWorkerTasks.count < concurrency, !pendingQueue.isEmpty {
            let fileID = pendingQueue.removeFirst()
            guard let item = itemByID[fileID], !item.status.isTerminal else { continue }
            guard runningWorkerTasks[fileID] == nil else { continue }

            let workerToken = UUID()
            let remoteFile = item.remoteFile
            let task = Task { [weak self] in
                guard let self else { return }
                defer {
                    if self.sessionToken == capturedSessionToken,
                       self.runningWorkerTasks[fileID]?.token == workerToken {
                        self.runningWorkerTasks[fileID] = nil
                        self.pumpQueue()
                    }
                }

                await self.engine.downloadFileWithRetries(
                    file: remoteFile,
                    baseDirectory: targetFolder,
                    accountToken: token,
                    maxRetries: retries
                ) { [weak self] event in
                    await self?.handleEngineEvent(event, sessionToken: capturedSessionToken)
                }
            }
            runningWorkerTasks[fileID] = (token: workerToken, task: task)
        }

        finalizeSessionStateIfIdle()
    }

    private func finalizeSessionStateIfIdle() {
        guard resolveTask == nil,
              tokenFetchTask == nil,
              runningWorkerTasks.isEmpty,
              pendingQueue.isEmpty else {
            return
        }
        guard !items.isEmpty else { return }
        let anyRunning = items.contains { !$0.status.isTerminal }
        guard !anyRunning else { return }

        let targetFolder = sessionBaseDirectory ?? downloadFolder
        if failedFilesCount > 0 {
            state = .failed("\(failedFilesCount) file(s) failed.")
            appendLog(
                event: "Finished with errors",
                details: "\(completedFilesCount)/\(items.count) completed, \(failedFilesCount) failed."
            )
        } else if items.contains(where: { $0.status == .cancelled }) {
            state = .cancelled
        } else {
            state = .finished
            appendLog(
                event: "Completed",
                details: "All \(items.count) file(s) processed into \(targetFolder.path)."
            )
        }
    }

    public func clearLog() {
        logs.removeAll()
    }

    public func dismissFeedback() {
        guard !state.isActive else { return }
        needsPasswordPrompt = false
        hasInvalidURL = false
        if items.isEmpty {
            state = .idle
            contentID = nil
        }
    }

    public func startDownload() {
        guard !state.isActive else { return }
        let trimmedURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cid = GoFileAPI.contentID(from: trimmedURL) else {
            hasInvalidURL = true
            let msg = trimmedURL.isEmpty
                ? "Please enter a valid GoFile URL or ID."
                : "\(trimmedURL) is not a valid GoFile URL or ID."
            appendLog(event: "Invalid URL", details: msg)
            state = .failed(msg)
            return
        }

        hasInvalidURL = false
        if trimmedURL == cid {
            urlInput = GoFileAPI.webURL(forContentID: cid)
        }

        cancelInternalTasks(advanceSessionToken: true)
        let capturedSessionToken = sessionToken

        needsPasswordPrompt = false
        sessionID = UUID()
        contentID = cid
        state = .resolving
        items.removeAll()
        itemByID.removeAll()

        let password = passwordInput.isEmpty ? nil : passwordInput
        let targetFolder = downloadFolder
        sessionBaseDirectory = targetFolder
        let workers = maxConcurrent

        appendLog(event: "Starting", details: "Resolving album \(cid)...")

        resolveTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.sessionToken == capturedSessionToken {
                    self.resolveTask = nil
                }
            }
            do {
                try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                let token = try await self.api.createAccountToken()
                try Task.checkCancellation()
                guard self.sessionToken == capturedSessionToken else { return }
                self.lastAccountToken = token

                let remoteFiles = try await self.api.resolveFiles(
                    contentID: cid,
                    plainPassword: password,
                    accountToken: token
                )
                try Task.checkCancellation()
                guard self.sessionToken == capturedSessionToken else { return }

                if remoteFiles.isEmpty {
                    self.appendLog(event: "Empty album", details: "No downloadable files found in \(cid).")
                    self.state = .finished
                    return
                }

                var seen = Set<String>()
                let uniqueFiles = remoteFiles.filter { seen.insert($0.id).inserted }
                let newItems = uniqueFiles.map { DownloadItem(remoteFile: $0, baseDirectory: targetFolder) }
                self.items = newItems
                self.itemByID = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.state = .downloading
                self.appendLog(
                    event: "Queued",
                    details: "Found \(newItems.count) file(s) in \(cid). Downloading with \(workers) worker(s)..."
                )

                self.pendingQueue.append(contentsOf: newItems.map(\.id))
                self.resolveTask = nil
                self.pumpQueue()
            } catch is CancellationError {
                guard self.sessionToken == capturedSessionToken else { return }
                if self.state != .cancelled {
                    self.state = .cancelled
                    self.appendLog(event: "Cancelled", details: "Operation cancelled by user.")
                }
            } catch let urlError as URLError where urlError.code == .cancelled {
                guard self.sessionToken == capturedSessionToken else { return }
                if self.state != .cancelled {
                    self.state = .cancelled
                    self.appendLog(event: "Cancelled", details: "Operation cancelled by user.")
                }
            } catch let error as GoFileError {
                guard self.sessionToken == capturedSessionToken else { return }
                if error == .passwordRequired || error == .wrongPassword {
                    self.needsPasswordPrompt = true
                    self.appendLog(
                        event: error == .wrongPassword ? "Wrong password" : "Missing password",
                        details: error.localizedDescription
                    )
                } else {
                    self.appendLog(event: "Failed request", details: error.localizedDescription)
                }
                self.state = .failed(error.localizedDescription)
            } catch {
                guard self.sessionToken == capturedSessionToken else { return }
                let details = error.localizedDescription
                self.appendLog(event: "Failed request", details: details)
                self.state = .failed(details)
            }
        }
    }

    public func cancelDownload() {
        let wasResolving = resolveTask != nil || state == .resolving
        cancelInternalTasks(advanceSessionToken: true)

        var cancelledAnyItem = false
        for item in items where !item.status.isTerminal {
            item.status = .cancelled
            item.resetSpeed()
            cancelledAnyItem = true
        }

        if wasResolving || cancelledAnyItem || state.isActive {
            state = .cancelled
            let message = wasResolving && items.isEmpty
                ? "Operation cancelled by user."
                : "Download cancelled. Partial (.part) files were kept for resume."
            appendLog(event: "Cancelled", details: message)
        }
    }

    private func cancelInternalTasks(advanceSessionToken: Bool) {
        if advanceSessionToken {
            sessionToken = UUID()
        }
        resolveTask?.cancel()
        resolveTask = nil
        tokenFetchTask?.cancel()
        tokenFetchTask = nil
        pendingQueue.removeAll()
        for (_, entry) in runningWorkerTasks {
            entry.task.cancel()
        }
        runningWorkerTasks.removeAll()
    }

    private func handleEngineEvent(_ event: DownloadEngineEvent, sessionToken: UUID) {
        guard self.sessionToken == sessionToken else { return }

        switch event {
        case .fileStarted(let id, let resumedFrom):
            guard let item = itemByID[id] else { return }
            item.status = .downloading(resumed: resumedFrom > 0)
            if resumedFrom > 0 {
                appendLog(
                    event: "Resuming download",
                    details: "\(item.filename) from \(Formatters.bytes(resumedFrom))."
                )
            }

        case .fileProgress(let id, let received, let total):
            guard let item = itemByID[id] else { return }
            item.recordProgress(bytesReceived: received, totalBytes: total)

        case .fileRetrying(let id, let attempt, let maxRetries, let delayMillis, let reason):
            guard let item = itemByID[id] else { return }
            item.status = .retrying(attempt: attempt, max: maxRetries)
            item.resetSpeed()
            let waitSec = String(format: "%.1fs", Double(delayMillis) / 1000.0)
            appendLog(
                event: "Retrying download",
                details: "\(reason) Waiting \(waitSec) before retry (\(attempt)/\(maxRetries))..."
            )

        case .fileSkipped(let id, let filename, let totalBytes):
            guard let item = itemByID[id] else { return }
            item.bytesReceived = totalBytes
            item.totalBytes = totalBytes
            item.resetSpeed()
            item.status = .skipped
            appendLog(
                event: "Skipped download",
                details: "\(filename) has already been downloaded."
            )

        case .fileCompleted(let id, let filename, let totalBytes, let resumed):
            guard let item = itemByID[id] else { return }
            item.bytesReceived = totalBytes
            item.totalBytes = totalBytes
            item.resetSpeed()
            item.status = .completed(resumed: resumed)
            appendLog(
                event: "Completed download",
                details: "\(filename) (\(Formatters.bytes(totalBytes)))"
            )

        case .fileFailed(let id, _, let errorDetails):
            guard let item = itemByID[id] else { return }
            item.resetSpeed()
            item.status = .failed(errorDetails)
            appendLog(
                event: "Failed download",
                details: errorDetails
            )

        case .fileCancelled(let id):
            guard let item = itemByID[id], !item.status.isTerminal else { return }
            item.resetSpeed()
            item.status = .cancelled
        }
    }

    private func appendLog(event: String, details: String) {
        logs.append(LogEntry(event: event, details: details))
    }
}
