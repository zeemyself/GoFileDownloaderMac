import Foundation
import os
import Testing
@testable import GoFileDownloader

@Suite("DownloadStore Tests")
struct DownloadStoreTests {
    private func makeIsolatedDefaults() -> (suiteName: String, defaults: UserDefaults) {
        let suite = "gfd.store.test.\(UUID().uuidString)"
        return (suite, UserDefaults(suiteName: suite)!)
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Happy path session resolves album, downloads files, and finishes cleanly")
    @MainActor
    func happyPathSession() async throws {
        let (suite, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let accountJSON = #"{"status":"ok","data":{"token":"tok-happy"}}"#
        let contentsJSON = """
        {
          "status": "ok",
          "data": {
            "id": "alb1",
            "type": "folder",
            "name": "MyAlbum",
            "children": {
              "f1": { "id": "f1", "type": "file", "name": "one.txt", "link": "https://cdn.example.com/one", "size": 5, "createTime": 1 },
              "f2": { "id": "f2", "type": "file", "name": "two.txt", "link": "https://cdn.example.com/two", "size": 5, "createTime": 2 }
            }
          }
        }
        """

        let mock = MockSessionScope { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("/accounts") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(accountJSON.utf8))
            }
            if urlStr.contains("/contents/") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(contentsJSON.utf8))
            }
            let body = Data("12345".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "5"])!, body)
        }
        defer { mock.invalidate() }

        let store = DownloadStore(
            api: GoFileAPI(session: mock.session),
            engine: DownloadEngine(fileDownloader: FileDownloader(session: mock.session)),
            userDefaults: defaults
        )
        store.downloadFolder = tempDir
        store.urlInput = "https://gofile.io/d/alb1?ref=1"
        store.startDownload()

        for _ in 0..<200 {
            if store.state == .finished { break }
            try await Task.sleep(for: .milliseconds(15))
        }

        #expect(store.state == .finished)
        #expect(store.items.count == 2)
        #expect(store.completedFilesCount == 2)
        #expect(store.failedFilesCount == 0)
        #expect(store.totalBytesReceived == 10)
        #expect(store.overallFraction == 1.0)
    }

    @Test("Pre-download resolution errors, password prompts, empty albums, and dismissFeedback work cleanly")
    @MainActor
    func preDownloadErrorsAndDismiss() async throws {
        let (suite, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let accountJSON = #"{"status":"ok","data":{"token":"tok-err"}}"#
        let mock = MockSessionScope { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("/accounts") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(accountJSON.utf8))
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"ok","data":{"type":"folder","name":"secret","password":true,"passwordStatus":"passwordWrong"}}"#.utf8)
            )
        }
        defer { mock.invalidate() }

        let store = DownloadStore(
            api: GoFileAPI(session: mock.session),
            engine: DownloadEngine(fileDownloader: FileDownloader(session: mock.session)),
            userDefaults: defaults
        )
        store.downloadFolder = tempDir

        // Invalid URL does not validate until submit; submit flags hasInvalidURL and fails
        store.urlInput = "https://evil.com/d/abc123"
        #expect(store.canStart == true)
        #expect(store.hasInvalidURL == false)
        store.startDownload()
        #expect(store.hasInvalidURL == true)
        if case .failed = store.state {
            // Expected
        } else {
            Issue.record("Expected failed state for invalid URL")
        }
        store.dismissFeedback()
        #expect(store.state == .idle)
        #expect(store.hasInvalidURL == false)

        // Wrong password triggers needsPasswordPrompt and keeps error visible
        store.urlInput = "https://gofile.io/d/sec1"
        store.passwordInput = "wrong"
        store.startDownload()
        for _ in 0..<100 {
            if !store.state.isActive { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.needsPasswordPrompt == true)
        #expect(store.state == .failed(GoFileError.wrongPassword.localizedDescription))

        store.dismissFeedback()
        #expect(store.state == .idle)
        #expect(store.needsPasswordPrompt == false)

        // Empty album transitions cleanly to .finished with items.isEmpty
        mock.update { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("/accounts") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(accountJSON.utf8))
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"status":"ok","data":{"type":"folder","name":"empty","children":{}}}"#.utf8)
            )
        }
        store.startDownload()
        for _ in 0..<100 {
            if !store.state.isActive { break }
            try await Task.sleep(for: .milliseconds(15))
        }
        #expect(store.state == .finished)
        #expect(store.items.isEmpty)
    }

    @Test("Handles cancel-during-retry without deadlock, enforces maxConcurrent, rejects .queued retry, and surfaces forceRestart errors")
    @MainActor
    func retryDeadlockConcurrencyAndForceRestart() async throws {
        let (suite, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let accountJSON = #"{"status":"ok","data":{"token":"tok-1"}}"#
        let contentsJSON = """
        {
          "status": "ok",
          "data": {
            "id": "album1",
            "type": "folder",
            "name": "album1",
            "children": {
              "f1": { "id": "f1", "type": "file", "name": "a.txt", "link": "https://cdn.example.com/a", "size": 5, "createTime": 1 },
              "f2": { "id": "f2", "type": "file", "name": "b.txt", "link": "https://cdn.example.com/b", "size": 5, "createTime": 2 },
              "f3": { "id": "f3", "type": "file", "name": "c.txt", "link": "https://cdn.example.com/c", "size": 5, "createTime": 3 },
              "f4": { "id": "f4", "type": "file", "name": "d.txt", "link": "https://cdn.example.com/d", "size": 5, "createTime": 4 }
            }
          }
        }
        """

        let inFlight = OSAllocatedUnfairLock<Int>(initialState: 0)
        let peakConcurrent = OSAllocatedUnfairLock<Int>(initialState: 0)

        let mock = MockSessionScope { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("/accounts") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(accountJSON.utf8))
            }
            if urlStr.contains("/contents/") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(contentsJSON.utf8))
            }
            let current = inFlight.withLock { c in c += 1; return c }
            peakConcurrent.withLock { p in p = max(p, current) }
            defer { inFlight.withLock { $0 -= 1 } }
            Thread.sleep(forTimeInterval: 0.04)
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { mock.invalidate() }

        let store = DownloadStore(
            api: GoFileAPI(session: mock.session),
            engine: DownloadEngine(fileDownloader: FileDownloader(session: mock.session)),
            userDefaults: defaults
        )
        store.downloadFolder = tempDir
        store.urlInput = "https://gofile.io/d/album1"
        store.maxConcurrent = 2
        store.maxRetries = 0
        store.startDownload()

        for _ in 0..<200 {
            if case .failed = store.state, store.items.count == 4 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.failedFilesCount == 4)
        #expect(peakConcurrent.withLock { $0 } <= 2)

        // Bulk retry 4 items with maxConcurrent=2 and maxRetries=2, then cancel mid-retry
        peakConcurrent.withLock { $0 = 0 }
        store.maxRetries = 2
        store.retryItems(withIDs: Set(store.items.map(\.id)))

        for _ in 0..<80 {
            let anyActive = store.items.contains {
                if case .downloading = $0.status { return true }
                if case .retrying = $0.status { return true }
                return false
            }
            if anyActive { break }
            try await Task.sleep(for: .milliseconds(15))
        }

        if let queuedItem = store.items.first(where: { $0.status == .queued }) {
            let logCountBefore = store.logs.count
            store.retryItem(queuedItem)
            #expect(store.logs.count == logCountBefore)
        }

        store.cancelDownload()
        #expect(store.state == .cancelled)
        #expect(store.canStart)
        #expect(store.items.allSatisfy { $0.status == .cancelled })
        #expect(peakConcurrent.withLock { $0 } <= 2)

        try await Task.sleep(for: .milliseconds(100))
        #expect(store.state == .cancelled)

        // forceRestart fails explicitly when existing file cannot be deleted
        let item = store.items[0]
        let parentDir = item.destinationURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        try Data("locked".utf8).write(to: item.destinationURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parentDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parentDir.path) }

        store.retryItem(item, forceRestart: true)
        if case .failed = item.status {
            // Expected
        } else {
            Issue.record("Expected failed status when forceRestart cannot delete file, got \(item.status)")
        }

        // Cancel during .resolving transitions to .cancelled, not .failed
        mock.update { request in
            Thread.sleep(forTimeInterval: 0.08)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(accountJSON.utf8))
        }
        store.startDownload()
        #expect(store.state == .resolving)
        store.cancelDownload()
        #expect(store.state == .cancelled)
        try await Task.sleep(for: .milliseconds(120))
        #expect(store.state == .cancelled)
    }

    @Test("DownloadItem progress/EWMA speed/ETA and UserDefaults clamping work as expected")
    @MainActor
    func itemMetricsAndDefaultsClamping() async throws {
        let (suite, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(999, forKey: DownloadStore.maxConcurrentKey)
        defaults.set(999, forKey: DownloadStore.maxRetriesKey)

        let store = DownloadStore(userDefaults: defaults)
        #expect(store.maxConcurrent == 8)
        #expect(store.maxRetries == 10)

        let file = RemoteFile(id: "m1", filename: "video.mp4", downloadLink: "https://example.com/v", relativeDirectory: [], expectedSize: 100_000)
        let item = DownloadItem(remoteFile: file, baseDirectory: URL(fileURLWithPath: "/tmp"))
        item.status = .downloading(resumed: false)
        item.recordProgress(bytesReceived: 10_000, totalBytes: 100_000)
        try await Task.sleep(for: .milliseconds(60))
        item.recordProgress(bytesReceived: 40_000, totalBytes: 100_000)

        #expect(item.fractionCompleted == 0.4)
        #expect(item.speedBytesPerSec > 0)
        #expect(item.etaString != "—")

        item.resetSpeed()
        #expect(item.speedBytesPerSec == 0)
    }

    @Test("Bare content ID auto-expands on download start and URL validation occurs on submit")
    @MainActor
    func bareContentIDAutoExpandsAndValidatesOnSubmit() async throws {
        let (suite, defaults) = makeIsolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let accountJSON = #"{"status":"ok","data":{"token":"tok-bare"}}"#
        let contentsJSON = """
        {
          "status": "ok",
          "data": {
            "id": "clgeTz",
            "type": "folder",
            "name": "BareAlbum",
            "children": {
              "f1": { "id": "f1", "type": "file", "name": "clip.txt", "link": "https://cdn.example.com/clip", "size": 4, "createTime": 1 }
            }
          }
        }
        """

        let mock = MockSessionScope { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("/accounts") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(accountJSON.utf8))
            }
            if urlStr.contains("/contents/clgeTz") {
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(contentsJSON.utf8))
            }
            let body = Data("test".utf8)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "4"])!, body)
        }
        defer { mock.invalidate() }

        let store = DownloadStore(
            api: GoFileAPI(session: mock.session),
            engine: DownloadEngine(fileDownloader: FileDownloader(session: mock.session)),
            userDefaults: defaults
        )
        store.downloadFolder = tempDir

        // Empty or whitespace-only input disables start
        store.urlInput = "   "
        #expect(store.canStart == false)

        // Editing invalid text does not set hasInvalidURL until submit
        store.urlInput = "d/clgeTz"
        #expect(store.canStart == true)
        #expect(store.hasInvalidURL == false)
        store.startDownload()
        #expect(store.hasInvalidURL == true)
        if case .failed = store.state {
            // Expected
        } else {
            Issue.record("Expected failed state for partial path input")
        }

        // Editing urlInput clears hasInvalidURL
        store.urlInput = "  clgeTz  "
        #expect(store.hasInvalidURL == false)
        #expect(store.parsedContentID == "clgeTz")

        // Starting download with bare ID auto-expands urlInput and downloads cleanly
        store.startDownload()
        #expect(store.urlInput == "https://gofile.io/d/clgeTz")
        #expect(store.contentID == "clgeTz")
        #expect(store.hasInvalidURL == false)

        for _ in 0..<200 {
            if store.state == .finished { break }
            try await Task.sleep(for: .milliseconds(15))
        }

        #expect(store.state == .finished)
        #expect(store.completedFilesCount == 1)
        #expect(store.failedFilesCount == 0)
    }
}
