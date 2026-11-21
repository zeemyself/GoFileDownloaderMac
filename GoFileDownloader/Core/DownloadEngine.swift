import Foundation

public enum DownloadEngineEvent: Sendable {
    case fileStarted(fileID: String, resumedFrom: Int64)
    case fileProgress(fileID: String, bytesReceived: Int64, totalBytes: Int64?)
    case fileRetrying(fileID: String, attempt: Int, maxRetries: Int, delayMillis: Int, reason: String)
    case fileSkipped(fileID: String, filename: String, totalBytes: Int64)
    case fileCompleted(fileID: String, filename: String, totalBytes: Int64, resumed: Bool)
    case fileFailed(fileID: String, filename: String, errorDetails: String)
    case fileCancelled(fileID: String)
}

public struct DownloadEngine: Sendable {
    private let fileDownloader: FileDownloader

    public init(fileDownloader: FileDownloader = FileDownloader()) {
        self.fileDownloader = fileDownloader
    }

    public func runAll(
        files: [RemoteFile],
        baseDirectory: URL,
        accountToken: String,
        maxConcurrent: Int,
        maxRetries: Int,
        onEvent: @escaping @Sendable (DownloadEngineEvent) async -> Void
    ) async {
        let concurrency = max(1, maxConcurrent)
        let retries = max(0, maxRetries)

        await withTaskGroup(of: Void.self) { group in
            var iterator = files.makeIterator()
            var active = 0

            while active < concurrency, let next = iterator.next() {
                active += 1
                group.addTask {
                    await self.downloadFileWithRetries(
                        file: next,
                        baseDirectory: baseDirectory,
                        accountToken: accountToken,
                        maxRetries: retries,
                        onEvent: onEvent
                    )
                }
            }

            while await group.next() != nil {
                active -= 1
                if Task.isCancelled {
                    group.cancelAll()
                    while let remaining = iterator.next() {
                        await onEvent(.fileCancelled(fileID: remaining.id))
                    }
                    break
                }
                if let next = iterator.next() {
                    active += 1
                    group.addTask {
                        await self.downloadFileWithRetries(
                            file: next,
                            baseDirectory: baseDirectory,
                            accountToken: accountToken,
                            maxRetries: retries,
                            onEvent: onEvent
                        )
                    }
                }
            }
        }
    }

    public func downloadFileWithRetries(
        file: RemoteFile,
        baseDirectory: URL,
        accountToken: String,
        maxRetries: Int,
        onEvent: @escaping @Sendable (DownloadEngineEvent) async -> Void
    ) async {
        let retries = max(0, maxRetries)
        let totalAttempts = 1 + retries

        for attempt in 1...totalAttempts {
            if Task.isCancelled {
                await onEvent(.fileCancelled(fileID: file.id))
                return
            }

            do {
                let outcome = try await fileDownloader.download(
                    file: file,
                    to: baseDirectory,
                    accountToken: accountToken
                ) { progress in
                    if progress.isFirstReport {
                        await onEvent(.fileStarted(fileID: file.id, resumedFrom: progress.resumedFromOffset))
                    }
                    await onEvent(
                        .fileProgress(
                            fileID: file.id,
                            bytesReceived: progress.bytesReceived,
                            totalBytes: progress.totalBytes
                        )
                    )
                }

                switch outcome {
                case .skippedAlreadyExists(let bytes):
                    await onEvent(.fileSkipped(fileID: file.id, filename: file.filename, totalBytes: bytes))
                case .downloaded(let bytes, let resumed):
                    await onEvent(.fileCompleted(fileID: file.id, filename: file.filename, totalBytes: bytes, resumed: resumed))
                }
                return
            } catch is CancellationError {
                await onEvent(.fileCancelled(fileID: file.id))
                return
            } catch let urlError as URLError where urlError.code == .cancelled {
                await onEvent(.fileCancelled(fileID: file.id))
                return
            } catch {
                if Task.isCancelled {
                    await onEvent(.fileCancelled(fileID: file.id))
                    return
                }
                let details = formatErrorDetails(filename: file.filename, error: error)
                if attempt <= retries && Self.isRetryableError(error) {
                    let backoffMillis = Self.retryDelayMilliseconds(attempt: attempt, error: error)
                    await onEvent(
                        .fileRetrying(
                            fileID: file.id,
                            attempt: attempt,
                            maxRetries: retries,
                            delayMillis: backoffMillis,
                            reason: details
                        )
                    )
                    do {
                        try await Task.sleep(for: .milliseconds(backoffMillis))
                    } catch {
                        await onEvent(.fileCancelled(fileID: file.id))
                        return
                    }
                } else {
                    await onEvent(.fileFailed(fileID: file.id, filename: file.filename, errorDetails: details))
                    return
                }
            }
        }
    }

    private static func isRetryableError(_ error: Error) -> Bool {
        if let goFileError = error as? GoFileError {
            switch goFileError {
            case .unsafePath, .invalidURL:
                return false
            default:
                return true
            }
        }
        return true
    }

    /// Computes exponential backoff with random jitter in milliseconds.
    /// Uses a longer cooldown when the server returns HTTP 421 (Misdirected / connection limit) or 429 (Rate limit).
    public static func retryDelayMilliseconds(attempt: Int, error: Error) -> Int {
        let clampedAttempt = max(1, min(attempt, 6))
        let expFactor = 1 << (clampedAttempt - 1) // 1, 2, 4, 8, ...

        let isRateOrConnectionLimit: Bool = {
            if case let GoFileError.httpError(code) = error {
                return code == 421 || code == 429 || code == 503
            }
            return false
        }()

        let baseMillis = isRateOrConnectionLimit
            ? min(20_000, 2_500 * expFactor) // 2.5s, 5s, 10s, 20s...
            : min(12_000, 1_200 * expFactor) // 1.2s, 2.4s, 4.8s, 9.6s...

        let jitterRange = isRateOrConnectionLimit ? (500...2_000) : (250...1_250)
        return baseMillis + Int.random(in: jitterRange)
    }

    private func formatErrorDetails(filename: String, error: Error) -> String {
        if let gofileError = error as? GoFileError {
            switch gofileError {
            case .httpError(let code):
                return "Failed to download \(filename) (status code: \(code))."
            default:
                return "Failed to download \(filename): \(gofileError.localizedDescription)"
            }
        }
        return "Failed to download \(filename): \(error.localizedDescription)"
    }
}
