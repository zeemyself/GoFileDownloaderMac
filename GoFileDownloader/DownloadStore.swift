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

    public var urlInput: String = ""
    public var passwordInput: String = ""
    public var needsPasswordPrompt: Bool = false

    public var downloadFolder: URL {
        didSet {
            UserDefaults.standard.set(downloadFolder.path, forKey: Self.downloadFolderKey)
        }
    }

    public var maxConcurrent: Int {
        didSet {
            UserDefaults.standard.set(maxConcurrent, forKey: Self.maxConcurrentKey)
        }
    }

    public var maxRetries: Int {
        didSet {
            UserDefaults.standard.set(maxRetries, forKey: Self.maxRetriesKey)
        }
    }

    public var state: SessionState = .idle
    public var contentID: String?
    public var items: [DownloadItem] = []
    public var logs: [LogEntry] = []

    private var itemByID: [String: DownloadItem] = [:]
    private var activeTask: Task<Void, Never>?
    private var singleRetryTasks: [String: Task<Void, Never>] = [:]
    private var lastAccountToken: String?
    private let api: GoFileAPI
    private let engine: DownloadEngine

    public init(api: GoFileAPI = GoFileAPI(), engine: DownloadEngine = DownloadEngine()) {
        self.api = api
        self.engine = engine

        let defaults = UserDefaults.standard
        if let savedPath = defaults.string(forKey: Self.downloadFolderKey), !savedPath.isEmpty {
            self.downloadFolder = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
            self.downloadFolder = downloads.appendingPathComponent("GoFile", isDirectory: true)
        }

        let savedConcurrent = defaults.integer(forKey: Self.maxConcurrentKey)
        self.maxConcurrent = savedConcurrent > 0 ? savedConcurrent : GoFileConfig.defaultMaxWorkers

        if defaults.object(forKey: Self.maxRetriesKey) != nil {
            self.maxRetries = max(0, defaults.integer(forKey: Self.maxRetriesKey))
        } else {
            self.maxRetries = GoFileConfig.defaultMaxRetries
        }
    }

    // MARK: - Computed metrics

    public var parsedContentID: String? {
        GoFileAPI.contentID(from: urlInput)
    }

    public var canStart: Bool {
        !state.isActive && parsedContentID != nil
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
        let partURL = FileDownloader.partURL(for: item.destinationURL)
        if fm.fileExists(atPath: item.destinationURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([item.destinationURL])
        } else if fm.fileExists(atPath: partURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([partURL])
        } else {
            let folder = item.destinationURL.deletingLastPathComponent()
            NSWorkspace.shared.open(fm.fileExists(atPath: folder.path) ? folder : downloadFolder)
        }
    }

    public func openDownloadedFile(_ item: DownloadItem) {
        guard FileManager.default.fileExists(atPath: item.destinationURL.path) else { return }
        NSWorkspace.shared.open(item.destinationURL)
    }

    public func retryItems(withIDs ids: Set<DownloadItem.ID>, forceRestart: Bool = false) {
        for id in ids {
            guard let item = itemByID[id] else { continue }
            retryItem(item, forceRestart: forceRestart)
        }
    }

    public func retryItem(_ item: DownloadItem, forceRestart: Bool = false) {
        switch item.status {
        case .downloading, .retrying:
            return
        default:
            break
        }

        singleRetryTasks[item.id]?.cancel()

        if forceRestart {
            let fm = FileManager.default
            let partURL = FileDownloader.partURL(for: item.destinationURL)
            try? fm.removeItem(at: item.destinationURL)
            try? fm.removeItem(at: partURL)
            item.bytesReceived = 0
        }

        item.resetSpeed()
        item.status = .queued
        if !state.isActive {
            state = .downloading
        }

        let targetFolder = downloadFolder
        let retries = maxRetries
        let remoteFile = item.remoteFile

        appendLog(
            event: "Retrying download",
            details: "Manually retrying \(item.filename)\(forceRestart ? " from scratch" : "")..."
        )

        singleRetryTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.singleRetryTasks[remoteFile.id] = nil
                self.recomputeSessionStateIfIdle()
            }
            do {
                let token: String
                if let cached = self.lastAccountToken {
                    token = cached
                } else {
                    let fresh = try await self.api.createAccountToken()
                    self.lastAccountToken = fresh
                    token = fresh
                }

                await self.engine.runAll(
                    files: [remoteFile],
                    baseDirectory: targetFolder,
                    accountToken: token,
                    maxConcurrent: 1,
                    maxRetries: retries
                ) { [weak self] event in
                    await self?.handleEngineEvent(event)
                }
            } catch {
                let details = "Failed to retry \(remoteFile.filename): \(error.localizedDescription)"
                item.status = .failed(details)
                self.appendLog(event: "Failed download", details: details)
            }
        }
    }

    private func recomputeSessionStateIfIdle() {
        guard activeTask == nil, singleRetryTasks.isEmpty else { return }
        let anyRunning = items.contains {
            switch $0.status {
            case .downloading, .retrying, .queued: return true
            default: return false
            }
        }
        guard !anyRunning else { return }

        if failedFilesCount > 0 {
            state = .failed("\(failedFilesCount) file(s) failed.")
        } else if items.contains(where: { $0.status == .cancelled }) {
            state = .cancelled
        } else if !items.isEmpty {
            state = .finished
        }
    }

    public func clearLog() {
        logs.removeAll()
    }

    public func startDownload() {
        guard !state.isActive else { return }
        let trimmedURL = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cid = GoFileAPI.contentID(from: trimmedURL) else {
            let msg = "\(trimmedURL) is not a valid GoFile URL."
            appendLog(event: "Invalid URL", details: msg)
            state = .failed(msg)
            return
        }

        needsPasswordPrompt = false
        contentID = cid
        state = .resolving
        items.removeAll()
        itemByID.removeAll()

        let password = passwordInput.isEmpty ? nil : passwordInput
        let targetFolder = downloadFolder
        let workers = maxConcurrent
        let retries = maxRetries

        appendLog(event: "Starting", details: "Resolving album \(cid)...")

        activeTask = Task { [weak self] in
            guard let self else { return }
            defer { self.activeTask = nil }
            do {
                try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
                let token = try await self.api.createAccountToken()
                self.lastAccountToken = token
                try Task.checkCancellation()

                let remoteFiles = try await self.api.resolveFiles(
                    contentID: cid,
                    plainPassword: password,
                    accountToken: token
                )
                try Task.checkCancellation()

                if remoteFiles.isEmpty {
                    self.appendLog(event: "Empty album", details: "No downloadable files found in \(cid).")
                    self.state = .finished
                    return
                }

                let newItems = remoteFiles.map { DownloadItem(remoteFile: $0, baseDirectory: targetFolder) }
                self.items = newItems
                self.itemByID = Dictionary(uniqueKeysWithValues: newItems.map { ($0.id, $0) })
                self.state = .downloading
                self.appendLog(
                    event: "Queued",
                    details: "Found \(newItems.count) file(s) in \(cid). Downloading with \(workers) worker(s)..."
                )

                await self.engine.runAll(
                    files: remoteFiles,
                    baseDirectory: targetFolder,
                    accountToken: token,
                    maxConcurrent: workers,
                    maxRetries: retries
                ) { [weak self] event in
                    await self?.handleEngineEvent(event)
                }

                if Task.isCancelled {
                    for item in self.items where !item.status.isTerminal {
                        item.status = .cancelled
                        item.resetSpeed()
                    }
                    self.state = .cancelled
                    self.appendLog(event: "Cancelled", details: "Download cancelled. Partial (.part) files were kept for resume.")
                } else if self.failedFilesCount > 0 {
                    self.state = .failed("\(self.failedFilesCount) file(s) failed.")
                    self.appendLog(
                        event: "Finished with errors",
                        details: "\(self.completedFilesCount)/\(self.items.count) completed, \(self.failedFilesCount) failed."
                    )
                } else {
                    self.state = .finished
                    self.appendLog(
                        event: "Completed",
                        details: "All \(self.items.count) file(s) processed into \(targetFolder.path)."
                    )
                }
            } catch is CancellationError {
                self.state = .cancelled
                self.appendLog(event: "Cancelled", details: "Operation cancelled by user.")
            } catch let error as GoFileError {
                if error == .passwordRequired {
                    self.needsPasswordPrompt = true
                    self.appendLog(event: "Missing password", details: error.localizedDescription)
                } else {
                    self.appendLog(event: "Failed request", details: error.localizedDescription)
                }
                self.state = .failed(error.localizedDescription)
            } catch {
                let details = error.localizedDescription
                self.appendLog(event: "Failed request", details: details)
                self.state = .failed(details)
            }
        }
    }

    public func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        for (_, task) in singleRetryTasks {
            task.cancel()
        }
        singleRetryTasks.removeAll()
    }

    private func handleEngineEvent(_ event: DownloadEngineEvent) {
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
        }
    }

    private func appendLog(event: String, details: String) {
        logs.append(LogEntry(event: event, details: details))
    }
}
