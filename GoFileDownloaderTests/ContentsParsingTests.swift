import CryptoKit
import Foundation
import os
import Testing
@testable import GoFileDownloader

final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

@Suite("Contents Parsing & Resume Tests", .serialized)
struct ContentsParsingTests {
    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    @Test("Resolves folder hierarchy and deduplicates duplicate filenames")
    func resolvesFolderAndDeduplicates() async throws {
        let payload = """
        {
          "status": "ok",
          "data": {
            "type": "folder",
            "name": "album",
            "children": {
              "id-1": { "id": "id-1", "type": "file", "name": "clip.mp4", "link": "https://example.com/1", "createTime": 1 },
              "id-2": { "id": "id-2", "type": "file", "name": "clip.mp4", "link": "https://example.com/2", "createTime": 2 },
              "id-3": { "id": "id-3", "type": "file", "name": "clip.mp4", "link": "https://example.com/3", "createTime": 3 }
            }
          }
        }
        """

        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(payload.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let api = GoFileAPI(session: makeMockSession())
        let files = try await api.resolveFiles(contentID: "abc123", plainPassword: nil, accountToken: "tok")

        #expect(files.count == 3)
        #expect(files[0].relativePath == "album/clip.mp4")
        #expect(files[1].relativePath == "album/clip (1).mp4")
        #expect(files[2].relativePath == "album/clip (2).mp4")
    }

    @Test("Throws passwordRequired when passwordStatus is not passwordOk")
    func throwsPasswordRequired() async {
        let payload = """
        {
          "status": "ok",
          "data": {
            "type": "folder",
            "name": "secret",
            "password": true,
            "passwordStatus": "passwordRequired"
          }
        }
        """

        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(payload.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let api = GoFileAPI(session: makeMockSession())
        await #expect(throws: GoFileError.passwordRequired) {
            _ = try await api.resolveFiles(contentID: "sec1", plainPassword: nil, accountToken: "tok")
        }
    }

    @Test("FileDownloader resumes from existing .part file using HTTP Range")
    func resumesPartialDownload() async throws {
        let fullData = Data("Hello, resumable GoFile world!".utf8)
        let partialPrefix = fullData.prefix(7) // "Hello, "
        let remainingSuffix = fullData.dropFirst(7)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let remoteFile = RemoteFile(
            id: "f1",
            filename: "sample.txt",
            downloadLink: "https://example.com/sample.txt",
            relativeDirectory: ["album"],
            expectedSize: Int64(fullData.count)
        )

        let finalURL = FileDownloader.destinationURL(baseDirectory: tempDir, file: remoteFile)
        let partURL = FileDownloader.partURL(for: finalURL, fileID: remoteFile.id)
        try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try partialPrefix.write(to: partURL)

        let capturedRangeHeader = OSAllocatedUnfairLock<String?>(initialState: nil)
        MockURLProtocol.handler = { request in
            capturedRangeHeader.withLock { $0 = request.value(forHTTPHeaderField: "Range") }
            let headers = [
                "Content-Length": "\(remainingSuffix.count)",
                "Content-Range": "bytes 7-\(fullData.count - 1)/\(fullData.count)",
            ]
            let resp = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!
            return (resp, Data(remainingSuffix))
        }
        defer { MockURLProtocol.handler = nil }

        let downloader = FileDownloader(session: makeMockSession())
        let outcome = try await downloader.download(
            file: remoteFile,
            to: tempDir,
            accountToken: "tok"
        ) { _ in }

        #expect(capturedRangeHeader.withLock { $0 } == "bytes=7-")
        #expect(outcome == .downloaded(totalBytes: Int64(fullData.count), resumed: true))
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
        let saved = try Data(contentsOf: finalURL)
        #expect(saved == fullData)
    }

    // MARK: - P0 Regressions

    @Test("Misaligned 206 Content-Range restarts cleanly from byte 0 without splicing")
    func misaligned206RestartsCleanly() async throws {
        let fullData = Data("0123456789ABCDEF".utf8)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let remoteFile = RemoteFile(
            id: "f-misalign",
            filename: "data.bin",
            downloadLink: "https://example.com/data.bin",
            relativeDirectory: [],
            expectedSize: Int64(fullData.count)
        )
        let finalURL = FileDownloader.destinationURL(baseDirectory: tempDir, file: remoteFile)
        let partURL = FileDownloader.partURL(for: finalURL, fileID: remoteFile.id)
        try Data("STALE!!".utf8).write(to: partURL)

        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.handler = { request in
            let attempt = callCount.withLock { count in
                count += 1
                return count
            }
            if attempt == 1 {
                let headers = [
                    "Content-Length": "\(fullData.count)",
                    "Content-Range": "bytes 0-\(fullData.count - 1)/\(fullData.count)",
                ]
                let resp = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!
                return (resp, fullData)
            }
            let headers = ["Content-Length": "\(fullData.count)"]
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            return (resp, fullData)
        }
        defer { MockURLProtocol.handler = nil }

        let downloader = FileDownloader(session: makeMockSession())
        let outcome = try await downloader.download(file: remoteFile, to: tempDir, accountToken: "tok") { _ in }

        #expect(callCount.withLock { $0 } == 2)
        #expect(outcome == .downloaded(totalBytes: Int64(fullData.count), resumed: false))
        #expect(try Data(contentsOf: finalURL) == fullData)
    }

    @Test("HTTP 416 rescues already-complete .part file and caps retry count at 1")
    func handles416RescueAndRetryCap() async throws {
        let fullData = Data("Already complete part bytes".utf8)
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let completeFile = RemoteFile(
            id: "f-416-rescue",
            filename: "complete.bin",
            downloadLink: "https://example.com/complete.bin",
            relativeDirectory: [],
            expectedSize: Int64(fullData.count)
        )
        let completeFinal = FileDownloader.destinationURL(baseDirectory: tempDir, file: completeFile)
        let completePart = FileDownloader.partURL(for: completeFinal, fileID: completeFile.id)
        try fullData.write(to: completePart)

        let rescueRequests = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.handler = { request in
            rescueRequests.withLock { $0 += 1 }
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 416,
                httpVersion: nil,
                headerFields: ["Content-Range": "bytes */\(fullData.count)"]
            )!
            return (resp, Data())
        }
        defer { MockURLProtocol.handler = nil }

        let downloader = FileDownloader(session: makeMockSession())
        let outcome = try await downloader.download(file: completeFile, to: tempDir, accountToken: "tok") { _ in }

        #expect(rescueRequests.withLock { $0 } == 1)
        #expect(outcome == .downloaded(totalBytes: Int64(fullData.count), resumed: true))
        #expect(try Data(contentsOf: completeFinal) == fullData)

        // Repeated 416 must not infinitely recurse
        let badFile = RemoteFile(
            id: "f-416-loop",
            filename: "broken.bin",
            downloadLink: "https://example.com/broken.bin",
            relativeDirectory: [],
            expectedSize: nil
        )
        let badFinal = FileDownloader.destinationURL(baseDirectory: tempDir, file: badFile)
        let badPart = FileDownloader.partURL(for: badFinal, fileID: badFile.id)
        try Data("stale".utf8).write(to: badPart)

        let loopRequests = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.handler = { request in
            loopRequests.withLock { $0 += 1 }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 416, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }

        await #expect(throws: GoFileError.httpError(416)) {
            _ = try await downloader.download(file: badFile, to: tempDir, accountToken: "tok") { _ in }
        }
        #expect(loopRequests.withLock { $0 } == 2)
    }

    @Test("Rejects soft-200 size mismatch, MD5 mismatch, and accepts matching MD5")
    func rejectsSoft200AndVerifiesMD5() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let htmlError = Data("<html>Rate limited</html>".utf8)
        let largeRemote = RemoteFile(
            id: "f-soft200",
            filename: "movie.mp4",
            downloadLink: "https://example.com/movie.mp4",
            relativeDirectory: [],
            expectedSize: 50_000
        )

        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(htmlError.count)"]
            )!
            return (resp, htmlError)
        }
        defer { MockURLProtocol.handler = nil }

        let downloader = FileDownloader(session: makeMockSession())
        await #expect(throws: GoFileError.integrityMismatch(
            "Size mismatch for movie.mp4: expected 50000 bytes, server reported \(htmlError.count) bytes."
        )) {
            _ = try await downloader.download(file: largeRemote, to: tempDir, accountToken: "tok") { _ in }
        }
        let movieURL = FileDownloader.destinationURL(baseDirectory: tempDir, file: largeRemote)
        #expect(!FileManager.default.fileExists(atPath: movieURL.path))

        // MD5 mismatch vs match
        let payload = Data("Verified payload content".utf8)
        let actualMD5 = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let wrongMD5 = String(repeating: "0", count: 32)

        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(payload.count)"]
            )!
            return (resp, payload)
        }

        let badHashFile = RemoteFile(
            id: "f-badmd5",
            filename: "check.bin",
            downloadLink: "https://example.com/check.bin",
            relativeDirectory: [],
            expectedSize: Int64(payload.count),
            md5: wrongMD5
        )
        await #expect(throws: GoFileError.checksumMismatch(expected: wrongMD5, actual: actualMD5)) {
            _ = try await downloader.download(file: badHashFile, to: tempDir, accountToken: "tok") { _ in }
        }

        let goodHashFile = RemoteFile(
            id: "f-goodmd5",
            filename: "check.bin",
            downloadLink: "https://example.com/check.bin",
            relativeDirectory: [],
            expectedSize: Int64(payload.count),
            md5: actualMD5
        )
        let okOutcome = try await downloader.download(file: goodHashFile, to: tempDir, accountToken: "tok") { _ in }
        #expect(okOutcome == .downloaded(totalBytes: Int64(payload.count), resumed: false))
    }

    @Test("GoFileAPI handles deterministic sorting, APFS folder collisions, cycles, HTTP errors, and password redaction")
    func apiSafetyOrderingAndRedaction() async throws {
        let cyclicPayload = """
        {
          "status": "ok",
          "data": {
            "id": "root",
            "type": "folder",
            "name": "Root",
            "children": {
              "z-id": { "id": "z-id", "type": "file", "name": "dup.jpg", "link": "https://example.com/z", "createTime": 100 },
              "a-id": { "id": "a-id", "type": "file", "name": "dup.jpg", "link": "https://example.com/a", "createTime": 100 },
              "f-1": { "id": "f-1", "type": "folder", "name": "Photos", "createTime": 200 },
              "f-2": { "id": "f-2", "type": "folder", "name": "photos", "createTime": 200 },
              "f-cycle": { "id": "root", "type": "folder", "name": "Cycle", "createTime": 300 }
            }
          }
        }
        """
        let sub1 = """
        {
          "status": "ok",
          "data": {
            "id": "f-1",
            "type": "folder",
            "name": "Photos",
            "children": {
              "p1": { "id": "p1", "type": "file", "name": "a.jpg", "link": "https://example.com/p1", "createTime": 1 }
            }
          }
        }
        """
        let sub2 = """
        {
          "status": "ok",
          "data": {
            "id": "f-2",
            "type": "folder",
            "name": "photos",
            "children": {
              "p2": { "id": "p2", "type": "file", "name": "a.jpg", "link": "https://example.com/p2", "createTime": 1 }
            }
          }
        }
        """

        MockURLProtocol.handler = { request in
            let path = request.url?.path ?? ""
            let json: String
            if path.hasSuffix("/f-1") {
                json = sub1
            } else if path.hasSuffix("/f-2") {
                json = sub2
            } else {
                json = cyclicPayload
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let api = GoFileAPI(session: makeMockSession())
        let files = try await api.resolveFiles(contentID: "root", plainPassword: nil, accountToken: "tok")

        #expect(files.count == 4)
        #expect(files[0].id == "a-id")
        #expect(files[0].relativePath == "Root/dup.jpg")
        #expect(files[1].id == "z-id")
        #expect(files[1].relativePath == "Root/dup (1).jpg")
        #expect(files[2].relativePath == "Root/Photos/a.jpg")
        #expect(files[3].relativePath == "Root/photos (1)/a.jpg")

        // Verify password redaction, HTTP status validation, and CancellationError propagation
        let secret = "SuperSecret123"
        let secretHash = GoFileAPI.sha256Hex(secret)
        MockURLProtocol.handler = { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (resp, Data("Too Many Requests".utf8))
        }
        await #expect(throws: GoFileError.httpError(429)) {
            _ = try await api.resolveFiles(contentID: "root", plainPassword: secret, accountToken: "tok")
        }

        MockURLProtocol.handler = { _ in
            throw URLError(.cannotFindHost)
        }
        do {
            _ = try await api.resolveFiles(contentID: "root", plainPassword: secret, accountToken: "tok")
            Issue.record("Expected networkError")
        } catch let error as GoFileError {
            let desc = error.localizedDescription
            #expect(!desc.contains(secretHash))
            #expect(!desc.contains("password="))
        }

        MockURLProtocol.handler = { _ in
            throw URLError(.cancelled)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await api.resolveFiles(contentID: "root", plainPassword: secret, accountToken: "tok")
        }
    }

    @Test("DownloadStore handles cancel-during-manual-retry, maxConcurrent cap, duplicate IDs, and forceRestart error")
    @MainActor
    func downloadStoreRegressions() async throws {
        let suiteName = "gfd.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
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

        MockURLProtocol.handler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("/accounts") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(accountJSON.utf8))
            }
            if urlStr.contains("/contents/") {
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(contentsJSON.utf8))
            }
            let currentCount = inFlight.withLock { current in
                current += 1
                return current
            }
            peakConcurrent.withLock { peak in
                peak = max(peak, currentCount)
            }
            defer { inFlight.withLock { $0 -= 1 } }
            Thread.sleep(forTimeInterval: 0.04)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        defer { MockURLProtocol.handler = nil }

        let session = makeMockSession()
        let store = DownloadStore(
            api: GoFileAPI(session: session),
            engine: DownloadEngine(fileDownloader: FileDownloader(session: session)),
            userDefaults: defaults
        )
        store.downloadFolder = tempDir
        store.urlInput = "https://gofile.io/d/album1"
        store.maxConcurrent = 2
        store.maxRetries = 0

        store.startDownload()

        // Wait until all 4 items fail cleanly
        for _ in 0..<200 {
            if case .failed = store.state, store.items.count == 4 { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(store.failedFilesCount == 4)
        #expect(peakConcurrent.withLock { $0 } <= 2)

        // Bulk retry 4 failed items with maxConcurrent=2 and maxRetries=2, then cancel mid-retry
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

        // Retrying a still-queued item while queued must be ignored
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

        // Verify forceRestart does not silently become .skipped when deletion fails
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
            Issue.record("Expected failed status when forceRestart cannot remove existing file, got \(item.status)")
        }

        // Verify duplicate IDs do not crash Dictionary(uniqueKeysWithValues:) and cancel-during-resolve sets .cancelled
        MockURLProtocol.handler = { request in
            let urlStr = request.url?.absoluteString ?? ""
            if urlStr.contains("/accounts") {
                Thread.sleep(forTimeInterval: 0.08)
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data(accountJSON.utf8))
            }
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(contentsJSON.utf8))
        }

        store.startDownload()
        #expect(store.state == .resolving)
        store.cancelDownload()
        #expect(store.state == .cancelled)
        try await Task.sleep(for: .milliseconds(120))
        #expect(store.state == .cancelled)
    }

    @Test("Literal .part remote file does not collide with active .part temp file")
    func literalPartFileDoesNotCollide() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let videoData = Data("MP4-VIDEO-BYTES".utf8)
        let partData = Data("LITERAL-PART-FILE".utf8)

        MockURLProtocol.handler = { request in
            let data = request.url?.lastPathComponent == "clip.mp4.part" ? partData : videoData
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(data.count)"]
            )!
            return (resp, data)
        }
        defer { MockURLProtocol.handler = nil }

        let downloader = FileDownloader(session: makeMockSession())
        let videoFile = RemoteFile(
            id: "id-video",
            filename: "clip.mp4",
            downloadLink: "https://example.com/clip.mp4",
            relativeDirectory: [],
            expectedSize: Int64(videoData.count)
        )
        let partNamedFile = RemoteFile(
            id: "id-literal-part",
            filename: "clip.mp4.part",
            downloadLink: "https://example.com/clip.mp4.part",
            relativeDirectory: [],
            expectedSize: Int64(partData.count)
        )

        let out1 = try await downloader.download(file: videoFile, to: tempDir, accountToken: "tok") { _ in }
        let out2 = try await downloader.download(file: partNamedFile, to: tempDir, accountToken: "tok") { _ in }

        #expect(out1 == .downloaded(totalBytes: Int64(videoData.count), resumed: false))
        #expect(out2 == .downloaded(totalBytes: Int64(partData.count), resumed: false))
        #expect(try Data(contentsOf: tempDir.appendingPathComponent("clip.mp4")) == videoData)
        #expect(try Data(contentsOf: tempDir.appendingPathComponent("clip.mp4.part")) == partData)
    }
}
