import Foundation
import os
import Testing
@testable import GoFileDownloader

@Suite("DownloadEngine Tests")
struct DownloadEngineTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("runAll enforces maxConcurrent cap and completes all files")
    func runAllEnforcesMaxConcurrent() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let inFlight = OSAllocatedUnfairLock<Int>(initialState: 0)
        let peak = OSAllocatedUnfairLock<Int>(initialState: 0)

        let mock = MockSessionScope { request in
            let current = inFlight.withLock { count in count += 1; return count }
            peak.withLock { p in p = max(p, current) }
            defer { inFlight.withLock { $0 -= 1 } }
            Thread.sleep(forTimeInterval: 0.03)
            let data = Data("hello".utf8)
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(data.count)"]
            )!
            return (resp, data)
        }
        defer { mock.invalidate() }

        let files = (1...6).map { idx in
            RemoteFile(
                id: "f-\(idx)",
                filename: "file\(idx).txt",
                downloadLink: "https://example.com/file\(idx).txt",
                relativeDirectory: [],
                expectedSize: 5
            )
        }

        let completedIDs = OSAllocatedUnfairLock<Set<String>>(initialState: [])
        let engine = DownloadEngine(fileDownloader: FileDownloader(session: mock.session))
        await engine.runAll(
            files: files,
            baseDirectory: tempDir,
            accountToken: "tok",
            maxConcurrent: 2,
            maxRetries: 0
        ) { event in
            if case .fileCompleted(let id, _, _, _) = event {
                _ = completedIDs.withLock { $0.insert(id) }
            }
        }

        #expect(completedIDs.withLock { $0.count } == 6)
        #expect(peak.withLock { $0 } <= 2)
    }

    @Test("Retries transient failures, succeeds on recovery, and fails after exhausting retries")
    func retryRecoveryAndExhaustion() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let attempts = OSAllocatedUnfairLock<Int>(initialState: 0)
        let mock = MockSessionScope { request in
            let n = attempts.withLock { c in c += 1; return c }
            if request.url?.lastPathComponent == "recover.bin" && n >= 2 {
                let data = Data("ok".utf8)
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "2"])!, data)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { mock.invalidate() }

        let engine = DownloadEngine(fileDownloader: FileDownloader(session: mock.session))

        // Recovery on 2nd attempt
        let retryEvents = OSAllocatedUnfairLock<Int>(initialState: 0)
        let didComplete = OSAllocatedUnfairLock<Bool>(initialState: false)
        let recoverFile = RemoteFile(id: "rec", filename: "recover.bin", downloadLink: "https://example.com/recover.bin", relativeDirectory: [], expectedSize: 2)
        await engine.downloadFileWithRetries(file: recoverFile, baseDirectory: tempDir, accountToken: "tok", maxRetries: 1) { event in
            switch event {
            case .fileRetrying:
                retryEvents.withLock { $0 += 1 }
            case .fileCompleted:
                didComplete.withLock { $0 = true }
            default:
                break
            }
        }
        #expect(retryEvents.withLock { $0 } == 1)
        #expect(didComplete.withLock { $0 } == true)

        // Non-retryable unsafePath fails immediately without retrying
        let unsafeRetries = OSAllocatedUnfairLock<Int>(initialState: 0)
        let unsafeFailed = OSAllocatedUnfairLock<Bool>(initialState: false)
        let unsafeFile = RemoteFile(id: "badpath", filename: "evil.plist", downloadLink: "https://example.com/x", relativeDirectory: [".."])
        await engine.downloadFileWithRetries(file: unsafeFile, baseDirectory: tempDir, accountToken: "tok", maxRetries: 3) { event in
            switch event {
            case .fileRetrying:
                unsafeRetries.withLock { $0 += 1 }
            case .fileFailed:
                unsafeFailed.withLock { $0 = true }
            default:
                break
            }
        }
        #expect(unsafeRetries.withLock { $0 } == 0)
        #expect(unsafeFailed.withLock { $0 } == true)

        // Exhausting retries emits fileFailed
        let exhaustFailed = OSAllocatedUnfairLock<Bool>(initialState: false)
        let failFile = RemoteFile(id: "fail", filename: "alwaysfail.bin", downloadLink: "https://example.com/alwaysfail.bin", relativeDirectory: [])
        await engine.downloadFileWithRetries(file: failFile, baseDirectory: tempDir, accountToken: "tok", maxRetries: 0) { event in
            if case .fileFailed = event {
                exhaustFailed.withLock { $0 = true }
            }
        }
        #expect(exhaustFailed.withLock { $0 } == true)
    }

    @Test("Cancellation during retry sleep emits fileCancelled immediately")
    func cancellationDuringRetrySleepEmitsFileCancelled() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mock = MockSessionScope { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { mock.invalidate() }

        let engine = DownloadEngine(fileDownloader: FileDownloader(session: mock.session))
        let file = RemoteFile(id: "cancel-me", filename: "retry.bin", downloadLink: "https://example.com/retry.bin", relativeDirectory: [])

        let sawRetrying = OSAllocatedUnfairLock<Bool>(initialState: false)
        let sawCancelled = OSAllocatedUnfairLock<Bool>(initialState: false)

        let task = Task {
            await engine.downloadFileWithRetries(file: file, baseDirectory: tempDir, accountToken: "tok", maxRetries: 3) { event in
                switch event {
                case .fileRetrying:
                    sawRetrying.withLock { $0 = true }
                case .fileCancelled(let id) where id == file.id:
                    sawCancelled.withLock { $0 = true }
                default:
                    break
                }
            }
        }

        for _ in 0..<100 {
            if sawRetrying.withLock({ $0 }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        await task.value

        #expect(sawRetrying.withLock { $0 } == true)
        #expect(sawCancelled.withLock { $0 } == true)
    }

    @Test("retryDelayMilliseconds scales exponentially, respects caps, and applies rate-limit cooldowns")
    func retryJitterBackoffBounds() {
        for _ in 0..<25 {
            // Normal errors & non-GoFileError
            #expect((1_450...2_450).contains(DownloadEngine.retryDelayMilliseconds(attempt: 0, error: GoFileError.httpError(500))))
            #expect((1_450...2_450).contains(DownloadEngine.retryDelayMilliseconds(attempt: 1, error: GoFileError.httpError(500))))
            #expect((2_650...3_650).contains(DownloadEngine.retryDelayMilliseconds(attempt: 2, error: URLError(.timedOut))))
            #expect((12_250...13_250).contains(DownloadEngine.retryDelayMilliseconds(attempt: 10, error: GoFileError.httpError(500))))

            // Rate/connection limit status codes (421, 429, 503)
            for code in [421, 429, 503] {
                #expect((3_000...4_500).contains(DownloadEngine.retryDelayMilliseconds(attempt: 1, error: GoFileError.httpError(code))))
                #expect((5_500...7_000).contains(DownloadEngine.retryDelayMilliseconds(attempt: 2, error: GoFileError.httpError(code))))
                #expect((20_500...22_000).contains(DownloadEngine.retryDelayMilliseconds(attempt: 8, error: GoFileError.httpError(code))))
            }
        }
    }
}
