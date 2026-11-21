import CryptoKit
import Foundation
import os
import Testing
@testable import GoFileDownloader

@Suite("FileDownloader Tests")
struct FileDownloaderTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Fresh 200 OK multi-chunk download writes full file, reports progress, and sends Accept-Encoding identity")
    func freshMultiChunkDownload() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 24 KB payload across three 8 KB chunks (> 8 KB flush threshold for <1 MB files)
        let chunk1 = Data(repeating: 0x41, count: 8 * 1024)
        let chunk2 = Data(repeating: 0x42, count: 8 * 1024)
        let chunk3 = Data(repeating: 0x43, count: 8 * 1024)
        let fullData = chunk1 + chunk2 + chunk3
        let expectedMD5 = Insecure.MD5.hash(data: fullData).map { String(format: "%02x", $0) }.joined()

        let capturedEncoding = OSAllocatedUnfairLock<String?>(initialState: nil)
        let mock = MockSessionScope(chunkHandler: { request in
            capturedEncoding.withLock { $0 = request.value(forHTTPHeaderField: "Accept-Encoding") }
            let headers = [
                "Content-Length": "\(fullData.count)",
                "ETag": "\"v1\"",
            ]
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
            return (resp, [chunk1, chunk2, chunk3])
        })
        defer { mock.invalidate() }

        let file = RemoteFile(
            id: "fresh-1",
            filename: "multi.bin",
            downloadLink: "https://store1.gofile.io/download/multi.bin",
            relativeDirectory: ["album"],
            expectedSize: Int64(fullData.count),
            md5: expectedMD5
        )

        let progressCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let lastReceived = OSAllocatedUnfairLock<Int64>(initialState: 0)

        let downloader = FileDownloader(session: mock.session)
        let outcome = try await downloader.download(file: file, to: tempDir, accountToken: "tok") { progress in
            progressCount.withLock { $0 += 1 }
            lastReceived.withLock { $0 = progress.bytesReceived }
        }

        let finalURL = FileDownloader.destinationURL(baseDirectory: tempDir, file: file)
        let partURL = FileDownloader.partURL(for: file, in: tempDir)
        #expect(capturedEncoding.withLock { $0 } == "identity")
        #expect(outcome == .downloaded(totalBytes: Int64(fullData.count), resumed: false))
        #expect(progressCount.withLock { $0 } >= 2)
        #expect(lastReceived.withLock { $0 } == Int64(fullData.count))
        #expect(try Data(contentsOf: finalURL) == fullData)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
        #expect(!FileManager.default.fileExists(atPath: FileDownloader.resumeMetaURL(for: partURL).path))
        #expect(!FileManager.default.fileExists(atPath: tempDir.appendingPathComponent(GoFileConfig.partialStagingDirectoryName).path))
    }

    @Test("Resumes partial .part file via HTTP 206 with Content-Range and If-Range/ETag")
    func resumesPartialDownloadWithIfRange() async throws {
        let fullData = Data("Hello, resumable GoFile world!".utf8)
        let partialPrefix = fullData.prefix(7)
        let remainingSuffix = fullData.dropFirst(7)
        let expectedMD5 = Insecure.MD5.hash(data: fullData).map { String(format: "%02x", $0) }.joined()

        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let remoteFile = RemoteFile(
            id: "f1",
            filename: "sample.txt",
            downloadLink: "https://example.com/sample.txt",
            relativeDirectory: ["album"],
            expectedSize: Int64(fullData.count),
            md5: expectedMD5
        )

        let finalURL = FileDownloader.destinationURL(baseDirectory: tempDir, file: remoteFile)
        let partURL = FileDownloader.partURL(for: remoteFile, in: tempDir)
        let metaURL = FileDownloader.resumeMetaURL(for: partURL)
        try FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try partialPrefix.write(to: partURL)
        try Data(#"{"etag":"\"etag-42\"","lastModified":null,"expectedSize":30}"#.utf8).write(to: metaURL)

        let capturedHeaders = OSAllocatedUnfairLock<(range: String?, ifRange: String?)>(initialState: (nil, nil))
        let mock = MockSessionScope { request in
            capturedHeaders.withLock {
                $0 = (request.value(forHTTPHeaderField: "Range"), request.value(forHTTPHeaderField: "If-Range"))
            }
            let headers = [
                "Content-Length": "\(remainingSuffix.count)",
                "Content-Range": "bytes 7-\(fullData.count - 1)/\(fullData.count)",
                "ETag": "\"etag-42\"",
            ]
            let resp = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!
            return (resp, Data(remainingSuffix))
        }
        defer { mock.invalidate() }

        let downloader = FileDownloader(session: mock.session)
        let outcome = try await downloader.download(file: remoteFile, to: tempDir, accountToken: "tok") { _ in }

        let seen = capturedHeaders.withLock { $0 }
        #expect(seen.range == "bytes=7-")
        #expect(seen.ifRange == "\"etag-42\"")
        #expect(outcome == .downloaded(totalBytes: Int64(fullData.count), resumed: true))
        #expect(try Data(contentsOf: finalURL) == fullData)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    @Test("Misaligned 206 Content-Range or changed ETag restarts cleanly from byte 0")
    func misaligned206AndChangedETagRestart() async throws {
        let fullData = Data("0123456789ABCDEF".utf8)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let remoteFile = RemoteFile(
            id: "f-misalign",
            filename: "data.bin",
            downloadLink: "https://example.com/data.bin",
            relativeDirectory: [],
            expectedSize: Int64(fullData.count)
        )
        let finalURL = FileDownloader.destinationURL(baseDirectory: tempDir, file: remoteFile)
        let partURL = FileDownloader.partURL(for: remoteFile, in: tempDir)
        try FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("STALE!!".utf8).write(to: partURL)

        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let mock = MockSessionScope { request in
            let attempt = callCount.withLock { c in c += 1; return c }
            if attempt == 1 {
                let headers = [
                    "Content-Length": "\(fullData.count)",
                    "Content-Range": "bytes 0-\(fullData.count - 1)/\(fullData.count)",
                ]
                return (HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!, fullData)
            }
            let headers = ["Content-Length": "\(fullData.count)"]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, fullData)
        }
        defer { mock.invalidate() }

        let downloader = FileDownloader(session: mock.session)
        let outcome = try await downloader.download(file: remoteFile, to: tempDir, accountToken: "tok") { _ in }
        #expect(callCount.withLock { $0 } == 2)
        #expect(outcome == .downloaded(totalBytes: Int64(fullData.count), resumed: false))
        #expect(try Data(contentsOf: finalURL) == fullData)

        // Server ignoring Range and returning 200 OK overwrites stale .part cleanly
        try FileManager.default.removeItem(at: finalURL)
        try FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("OLD-PART".utf8).write(to: partURL)
        mock.update { request in
            let headers = ["Content-Length": "\(fullData.count)"]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, fullData)
        }
        let freshOutcome = try await downloader.download(file: remoteFile, to: tempDir, accountToken: "tok") { _ in }
        #expect(freshOutcome == .downloaded(totalBytes: Int64(fullData.count), resumed: false))
        #expect(try Data(contentsOf: finalURL) == fullData)
    }

    @Test("HTTP 416 rescues already-complete .part file and caps retry count at 1")
    func handles416RescueAndRetryCap() async throws {
        let fullData = Data("Already complete part bytes".utf8)
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let completeFile = RemoteFile(
            id: "f-416-rescue",
            filename: "complete.bin",
            downloadLink: "https://example.com/complete.bin",
            relativeDirectory: [],
            expectedSize: Int64(fullData.count)
        )
        let completeFinal = FileDownloader.destinationURL(baseDirectory: tempDir, file: completeFile)
        let completePart = FileDownloader.partURL(for: completeFile, in: tempDir)
        try FileManager.default.createDirectory(at: completePart.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fullData.write(to: completePart)

        let rescueRequests = OSAllocatedUnfairLock<Int>(initialState: 0)
        let mock = MockSessionScope { request in
            rescueRequests.withLock { $0 += 1 }
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 416,
                httpVersion: nil,
                headerFields: ["Content-Range": "bytes */\(fullData.count)"]
            )!
            return (resp, Data())
        }
        defer { mock.invalidate() }

        let downloader = FileDownloader(session: mock.session)
        let outcome = try await downloader.download(file: completeFile, to: tempDir, accountToken: "tok") { _ in }

        #expect(rescueRequests.withLock { $0 } == 1)
        #expect(outcome == .downloaded(totalBytes: Int64(fullData.count), resumed: true))
        #expect(try Data(contentsOf: completeFinal) == fullData)

        // Repeated 416 must stop after 1 clean retry without Range
        let badFile = RemoteFile(
            id: "f-416-loop",
            filename: "broken.bin",
            downloadLink: "https://example.com/broken.bin",
            relativeDirectory: [],
            expectedSize: nil
        )
        let badPart = FileDownloader.partURL(for: badFile, in: tempDir)
        try FileManager.default.createDirectory(at: badPart.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: badPart)

        let loopRequests = OSAllocatedUnfairLock<Int>(initialState: 0)
        mock.update { request in
            loopRequests.withLock { $0 += 1 }
            return (HTTPURLResponse(url: request.url!, statusCode: 416, httpVersion: nil, headerFields: nil)!, Data())
        }
        await #expect(throws: GoFileError.httpError(416)) {
            _ = try await downloader.download(file: badFile, to: tempDir, accountToken: "tok") { _ in }
        }
        #expect(loopRequests.withLock { $0 } == 2)
    }

    @Test("Rejects soft-200 size mismatch, IncompleteRead, oversized write, MD5 mismatch, and non-2xx HTTP errors")
    func integrityAndHttpErrorHandling() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let htmlError = Data("<html>Rate limited</html>".utf8)
        let mock = MockSessionScope { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(htmlError.count)"]
            )!
            return (resp, htmlError)
        }
        defer { mock.invalidate() }
        let downloader = FileDownloader(session: mock.session)

        // Soft-200 error page smaller than expectedSize
        let largeRemote = RemoteFile(
            id: "f-soft200",
            filename: "movie.mp4",
            downloadLink: "https://example.com/movie.mp4",
            relativeDirectory: [],
            expectedSize: 50_000
        )
        await #expect(throws: GoFileError.integrityMismatch(
            "Size mismatch for movie.mp4: expected 50000 bytes, server reported \(htmlError.count) bytes."
        )) {
            _ = try await downloader.download(file: largeRemote, to: tempDir, accountToken: "tok") { _ in }
        }

        // Truncated stream (IncompleteRead)
        mock.update { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "100"]
            )!
            return (resp, Data("short".utf8))
        }
        let truncatedFile = RemoteFile(
            id: "f-trunc",
            filename: "trunc.bin",
            downloadLink: "https://example.com/trunc.bin",
            relativeDirectory: [],
            expectedSize: 100
        )
        do {
            _ = try await downloader.download(file: truncatedFile, to: tempDir, accountToken: "tok") { _ in }
            Issue.record("Expected IncompleteRead networkError")
        } catch let GoFileError.networkError(msg) {
            #expect(msg.contains("IncompleteRead"))
        }

        // Oversized stream
        mock.update { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "4"]
            )!
            return (resp, Data("12345678".utf8))
        }
        let oversizedFile = RemoteFile(
            id: "f-over",
            filename: "over.bin",
            downloadLink: "https://example.com/over.bin",
            relativeDirectory: [],
            expectedSize: 4
        )
        do {
            _ = try await downloader.download(file: oversizedFile, to: tempDir, accountToken: "tok") { _ in }
            Issue.record("Expected integrityMismatch on oversized stream")
        } catch is GoFileError {
            let partURL = FileDownloader.partURL(for: oversizedFile, in: tempDir)
            #expect(!FileManager.default.fileExists(atPath: partURL.path))
        }

        // MD5 mismatch
        let payload = Data("Verified payload content".utf8)
        let actualMD5 = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let wrongMD5 = String(repeating: "0", count: 32)
        mock.update { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(payload.count)"]
            )!
            return (resp, payload)
        }
        let badMD5File = RemoteFile(
            id: "f-badmd5",
            filename: "md5.bin",
            downloadLink: "https://example.com/md5.bin",
            relativeDirectory: [],
            expectedSize: Int64(payload.count),
            md5: wrongMD5
        )
        await #expect(throws: GoFileError.checksumMismatch(expected: wrongMD5, actual: actualMD5)) {
            _ = try await downloader.download(file: badMD5File, to: tempDir, accountToken: "tok") { _ in }
        }

        // HTTP error status codes
        for code in [403, 404, 421, 429, 500] {
            mock.update { request in
                (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data())
            }
            let errFile = RemoteFile(
                id: "f-http-\(code)",
                filename: "err\(code).bin",
                downloadLink: "https://example.com/err\(code)",
                relativeDirectory: []
            )
            await #expect(throws: GoFileError.httpError(code)) {
                _ = try await downloader.download(file: errFile, to: tempDir, accountToken: "tok") { _ in }
            }
        }
    }

    @Test("Skips existing files matching expectedSize, re-downloads mismatched size, and skips 0-byte files")
    func skipExistingAndSizeMismatch() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fullData = Data("1234567890".utf8)
        let mock = MockSessionScope { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(fullData.count)"]
            )!
            return (resp, fullData)
        }
        defer { mock.invalidate() }
        let downloader = FileDownloader(session: mock.session)

        // Matching size skips without network
        let file = RemoteFile(
            id: "skip-1",
            filename: "done.bin",
            downloadLink: "https://example.com/done.bin",
            relativeDirectory: [],
            expectedSize: Int64(fullData.count)
        )
        let finalURL = FileDownloader.destinationURL(baseDirectory: tempDir, file: file)
        try fullData.write(to: finalURL)
        let skipped = try await downloader.download(file: file, to: tempDir, accountToken: "tok") { _ in }
        #expect(skipped == .skippedAlreadyExists(totalBytes: Int64(fullData.count)))

        // Truncated existing file is atomically replaced instead of skipped
        try Data("123".utf8).write(to: finalURL)
        let replaced = try await downloader.download(file: file, to: tempDir, accountToken: "tok") { _ in }
        #expect(replaced == .downloaded(totalBytes: Int64(fullData.count), resumed: false))
        #expect(try Data(contentsOf: finalURL) == fullData)

        // 0-byte expected file skips cleanly when 0-byte file already exists
        let emptyFile = RemoteFile(
            id: "skip-empty",
            filename: "empty.txt",
            downloadLink: "https://example.com/empty.txt",
            relativeDirectory: [],
            expectedSize: 0
        )
        try Data().write(to: FileDownloader.destinationURL(baseDirectory: tempDir, file: emptyFile))
        let skippedEmpty = try await downloader.download(file: emptyFile, to: tempDir, accountToken: "tok") { _ in }
        #expect(skippedEmpty == .skippedAlreadyExists(totalBytes: 0))
    }

    @Test("validatedDestinationURL blocks traversal, existing symlinks, and dangling symlinks")
    func pathContainmentAndSymlinks() throws {
        let baseDir = try makeTempDir()
        let outsideDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: baseDir)
            try? FileManager.default.removeItem(at: outsideDir)
        }

        let traversalCases: [RemoteFile] = [
            RemoteFile(id: "1", filename: "..", downloadLink: "https://example.com/1", relativeDirectory: []),
            RemoteFile(id: "2", filename: "evil.plist", downloadLink: "https://example.com/2", relativeDirectory: [".."]),
            RemoteFile(id: "3", filename: "a/b.txt", downloadLink: "https://example.com/3", relativeDirectory: []),
            RemoteFile(id: "4", filename: "a\\b.txt", downloadLink: "https://example.com/4", relativeDirectory: []),
            RemoteFile(id: "5", filename: "a\0b.txt", downloadLink: "https://example.com/5", relativeDirectory: []),
            RemoteFile(id: "6", filename: ".", downloadLink: "https://example.com/6", relativeDirectory: ["sub"]),
            RemoteFile(id: "6b", filename: "staged.part", downloadLink: "https://example.com/6b", relativeDirectory: [GoFileConfig.partialStagingDirectoryName]),
            RemoteFile(id: "6c", filename: GoFileConfig.partialStagingDirectoryName.uppercased(), downloadLink: "https://example.com/6c", relativeDirectory: []),
        ]

        for bad in traversalCases {
            #expect(throws: GoFileError.unsafePath(bad.relativePath)) {
                _ = try FileDownloader.validatedDestinationURL(baseDirectory: baseDir, file: bad)
            }
        }

        // Existing directory symlink escape
        let escapeLink = baseDir.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outsideDir)
        let symlinkFile = RemoteFile(id: "7", filename: "pwned.txt", downloadLink: "https://example.com/7", relativeDirectory: ["escape"])
        #expect(throws: GoFileError.unsafePath(symlinkFile.relativePath)) {
            _ = try FileDownloader.validatedDestinationURL(baseDirectory: baseDir, file: symlinkFile)
        }

        // Chained relative symlink escape: dirLink -> outsideDir/sub, relLink -> ../pwned.txt
        let outsideSub = outsideDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideSub, withIntermediateDirectories: true)
        let nestedDirLink = baseDir.appendingPathComponent("nestedLink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: nestedDirLink, withDestinationURL: outsideSub)
        let relativeEscapeLink = outsideSub.appendingPathComponent("relEscape.txt")
        try FileManager.default.createSymbolicLink(atPath: relativeEscapeLink.path, withDestinationPath: "../pwned.txt")
        let chainedSymlinkFile = RemoteFile(id: "7b", filename: "relEscape.txt", downloadLink: "https://example.com/7b", relativeDirectory: ["nestedLink"])
        #expect(throws: GoFileError.unsafePath(chainedSymlinkFile.relativePath)) {
            _ = try FileDownloader.validatedDestinationURL(baseDirectory: baseDir, file: chainedSymlinkFile)
        }

        // Dangling symlink pointing to non-existent file outside baseDir
        let danglingTarget = outsideDir.appendingPathComponent("never-created.plist")
        let danglingLink = baseDir.appendingPathComponent("dangling.plist")
        try FileManager.default.createSymbolicLink(at: danglingLink, withDestinationURL: danglingTarget)
        let danglingFile = RemoteFile(id: "8", filename: "dangling.plist", downloadLink: "https://example.com/8", relativeDirectory: [])
        #expect(throws: GoFileError.unsafePath(danglingFile.relativePath)) {
            _ = try FileDownloader.validatedDestinationURL(baseDirectory: baseDir, file: danglingFile)
        }

        // Valid nested file passes
        let valid = RemoteFile(id: "9", filename: "safe.bin", downloadLink: "https://example.com/9", relativeDirectory: ["album", "sub"])
        let resolved = try FileDownloader.validatedDestinationURL(baseDirectory: baseDir, file: valid)
        #expect(resolved.lastPathComponent == "safe.bin")
    }

    @Test("Isolated staging partURL, NAME_MAX bounds, literal .part file, and parseContentRange")
    func partURLAndContentRange() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let longFile = RemoteFile(
            id: "file-3",
            filename: String(repeating: "x", count: 240) + ".bin",
            downloadLink: "https://example.com/long",
            relativeDirectory: []
        )
        let longPart = FileDownloader.partURL(for: longFile, in: tempDir)
        let longMeta = FileDownloader.resumeMetaURL(for: longPart)
        #expect(longPart.deletingLastPathComponent().lastPathComponent == GoFileConfig.partialStagingDirectoryName)
        #expect(longPart.lastPathComponent.utf8.count <= 255)
        #expect(longMeta.lastPathComponent.utf8.count <= 255)

        #expect(FileDownloader.parseContentRange("bytes 7-31/32") == .bytes(start: 7, end: 31, total: 32))
        #expect(FileDownloader.parseContentRange("bytes 0-0/*") == .bytes(start: 0, end: 0, total: nil))
        #expect(FileDownloader.parseContentRange("BYTES */1024") == .unsatisfied(total: 1024))
        #expect(FileDownloader.parseContentRange("bytes 10-5/32") == nil)
        #expect(FileDownloader.parseContentRange("bytes 0-32/32") == nil)
        #expect(FileDownloader.parseContentRange("bytes */*") == nil)
        #expect(FileDownloader.parseContentRange("items 0-10/20") == nil)

        // Download both clip.mp4 and clip.mp4.part cleanly
        let videoData = Data("MP4-VIDEO-BYTES".utf8)
        let partData = Data("LITERAL-PART-FILE".utf8)
        let mock = MockSessionScope { request in
            let data = request.url?.lastPathComponent == "clip.mp4.part" ? partData : videoData
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(data.count)"]
            )!
            return (resp, data)
        }
        defer { mock.invalidate() }

        let downloader = FileDownloader(session: mock.session)
        let f1 = RemoteFile(id: "id-video", filename: "clip.mp4", downloadLink: "https://example.com/clip.mp4", relativeDirectory: [], expectedSize: Int64(videoData.count))
        let f2 = RemoteFile(id: "id-literal-part", filename: "clip.mp4.part", downloadLink: "https://example.com/clip.mp4.part", relativeDirectory: [], expectedSize: Int64(partData.count))
        _ = try await downloader.download(file: f1, to: tempDir, accountToken: "tok") { _ in }
        _ = try await downloader.download(file: f2, to: tempDir, accountToken: "tok") { _ in }
        #expect(try Data(contentsOf: tempDir.appendingPathComponent("clip.mp4")) == videoData)
        #expect(try Data(contentsOf: tempDir.appendingPathComponent("clip.mp4.part")) == partData)
    }

    @Test("Mid-stream Task cancellation throws CancellationError and preserves partial .part file")
    func midStreamCancellationPreservesPart() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let chunk = Data(repeating: 0x5A, count: 16 * 1024)
        let mock = MockSessionScope(chunkDelay: 0.12, chunkHandler: { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(chunk.count * 6)"]
            )!
            return (resp, Array(repeating: chunk, count: 6))
        })
        defer { mock.invalidate() }

        let file = RemoteFile(
            id: "cancel-stream",
            filename: "big.bin",
            downloadLink: "https://example.com/big.bin",
            relativeDirectory: [],
            expectedSize: Int64(chunk.count * 6)
        )
        let downloader = FileDownloader(session: mock.session)
        let taskBox = OSAllocatedUnfairLock<Task<FileDownloadOutcome, Error>?>(initialState: nil)

        let task = Task<FileDownloadOutcome, Error> {
            try await downloader.download(file: file, to: tempDir, accountToken: "tok") { progress in
                if progress.bytesReceived >= Int64(chunk.count) {
                    taskBox.withLock { $0?.cancel() }
                }
            }
        }
        taskBox.withLock { $0 = task }

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }

        let finalURL = FileDownloader.destinationURL(baseDirectory: tempDir, file: file)
        let partURL = FileDownloader.partURL(for: file, in: tempDir)
        #expect(!FileManager.default.fileExists(atPath: finalURL.path))
        #expect(FileManager.default.fileExists(atPath: partURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: partURL.path)
        let savedPartSize = (attrs[.size] as? Int64) ?? 0
        #expect(savedPartSize >= Int64(chunk.count))
    }

    @Test("Rejects existing directory, non-HTTP downloadLink, Last-Modified 206 mismatch, and 416 ETag mismatch")
    func rejectsDirectoryConflictNonHTTPSchemeAndValidatorMismatches() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let mock = MockSessionScope { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        defer { mock.invalidate() }
        let downloader = FileDownloader(session: mock.session)

        // Existing directory at destination must fail instead of skipping
        let dirConflict = RemoteFile(
            id: "dir-1",
            filename: "existingDir",
            downloadLink: "https://example.com/existingDir",
            relativeDirectory: []
        )
        try FileManager.default.createDirectory(
            at: FileDownloader.destinationURL(baseDirectory: tempDir, file: dirConflict),
            withIntermediateDirectories: true
        )
        await #expect(throws: GoFileError.unsafePath(dirConflict.relativePath)) {
            _ = try await downloader.download(file: dirConflict, to: tempDir, accountToken: "tok") { _ in }
        }

        // Non-HTTP(S) downloadLink is rejected before issuing any request
        let fileSchemeRemote = RemoteFile(
            id: "scheme-1",
            filename: "secret.txt",
            downloadLink: "file:///etc/passwd",
            relativeDirectory: []
        )
        await #expect(throws: GoFileError.invalidURL("file:///etc/passwd")) {
            _ = try await downloader.download(file: fileSchemeRemote, to: tempDir, accountToken: "tok") { _ in }
        }

        // Last-Modified mismatch on HTTP 206 restarts cleanly from byte 0
        let freshData = Data("UPDATED-PAYLOAD-DATA".utf8)
        let lmFile = RemoteFile(
            id: "lm-206",
            filename: "lm.bin",
            downloadLink: "https://example.com/lm.bin",
            relativeDirectory: [],
            expectedSize: Int64(freshData.count)
        )
        let lmPart = FileDownloader.partURL(for: lmFile, in: tempDir)
        let lmMeta = FileDownloader.resumeMetaURL(for: lmPart)
        try FileManager.default.createDirectory(at: lmPart.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("STALE".utf8).write(to: lmPart)
        try Data(#"{"etag":null,"lastModified":"Mon, 01 Jan 2024 00:00:00 GMT","expectedSize":20}"#.utf8).write(to: lmMeta)

        let lmCalls = OSAllocatedUnfairLock<Int>(initialState: 0)
        mock.update { request in
            let n = lmCalls.withLock { c in c += 1; return c }
            if n == 1 {
                let headers = [
                    "Content-Length": "\(freshData.count - 5)",
                    "Content-Range": "bytes 5-\(freshData.count - 1)/\(freshData.count)",
                    "Last-Modified": "Tue, 02 Jan 2024 00:00:00 GMT",
                ]
                return (HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!, Data(freshData.dropFirst(5)))
            }
            let headers = [
                "Content-Length": "\(freshData.count)",
                "Last-Modified": "Tue, 02 Jan 2024 00:00:00 GMT",
            ]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, freshData)
        }
        let lmOutcome = try await downloader.download(file: lmFile, to: tempDir, accountToken: "tok") { _ in }
        #expect(lmCalls.withLock { $0 } == 2)
        #expect(lmOutcome == .downloaded(totalBytes: Int64(freshData.count), resumed: false))
        #expect(try Data(contentsOf: FileDownloader.destinationURL(baseDirectory: tempDir, file: lmFile)) == freshData)

        // ETag mismatch on HTTP 416 must NOT rescue stale .part of same size
        let newSameSizeData = Data("NEW-SAME-SIZE-BYTES!".utf8)
        let staleSameSize = Data("OLD-SAME-SIZE-BYTES!".utf8)
        let rescueFile = RemoteFile(
            id: "etag-416",
            filename: "same-size.bin",
            downloadLink: "https://example.com/same-size.bin",
            relativeDirectory: [],
            expectedSize: Int64(newSameSizeData.count)
        )
        let rescuePart = FileDownloader.partURL(for: rescueFile, in: tempDir)
        let rescueMeta = FileDownloader.resumeMetaURL(for: rescuePart)
        try FileManager.default.createDirectory(at: rescuePart.deletingLastPathComponent(), withIntermediateDirectories: true)
        try staleSameSize.write(to: rescuePart)
        try Data(#"{"etag":"\"v1\"","lastModified":null,"expectedSize":20}"#.utf8).write(to: rescueMeta)

        let calls416 = OSAllocatedUnfairLock<Int>(initialState: 0)
        mock.update { request in
            let n = calls416.withLock { c in c += 1; return c }
            if n == 1 {
                let headers = [
                    "Content-Range": "bytes */\(newSameSizeData.count)",
                    "ETag": "\"v2\"",
                ]
                return (HTTPURLResponse(url: request.url!, statusCode: 416, httpVersion: nil, headerFields: headers)!, Data())
            }
            let headers = [
                "Content-Length": "\(newSameSizeData.count)",
                "ETag": "\"v2\"",
            ]
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, newSameSizeData)
        }
        let outcome416 = try await downloader.download(file: rescueFile, to: tempDir, accountToken: "tok") { _ in }
        #expect(calls416.withLock { $0 } == 2)
        #expect(outcome416 == .downloaded(totalBytes: Int64(newSameSizeData.count), resumed: false))
        #expect(try Data(contentsOf: FileDownloader.destinationURL(baseDirectory: tempDir, file: rescueFile)) == newSameSizeData)
    }

    @Test("ChunkedURLSessionStream serializes high-water suspend and low-water resume without stalling")
    func chunkedStreamBackpressureNeverStalls() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. High-contention tight-watermark stress directly on ChunkedURLSessionStream (16 KB / 4 KB)
        let smallChunks: [Data] = (0..<128).map { idx in
            Data(repeating: UInt8(idx & 0xFF), count: 8 * 1024)
        }
        let expectedSmall = smallChunks.reduce(into: Data()) { $0.append($1) }
        let tightMock = MockSessionScope(chunkHandler: { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(expectedSmall.count)"]
            )!
            return (resp, smallChunks)
        })
        defer { tightMock.invalidate() }

        let req = URLRequest(url: URL(string: "https://example.com/backpressure-tight")!)
        let (_, stream) = try await ChunkedURLSessionStream.open(
            session: tightMock.session,
            request: req,
            highWaterMark: 16 * 1024,
            lowWaterMark: 4 * 1024
        )
        defer { stream.cancel() }

        var collected = Data()
        collected.reserveCapacity(expectedSmall.count)
        var chunkIndex = 0
        while let chunk = try await stream.nextChunk() {
            collected.append(chunk)
            chunkIndex += 1
            // Periodically pause briefly so producer hits high-water mark while consumer races to drain
            if chunkIndex % 7 == 0 {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(collected == expectedSmall)

        // 2. End-to-end FileDownloader streaming > 4.5 MB across default 2 MB / 512 KB watermarks
        let bigChunk = Data(repeating: 0x3C, count: 256 * 1024)
        let bigChunkCount = 18 // 4.5 MB (> 2 MB high-water mark)
        let bigTotalBytes = Int64(bigChunk.count * bigChunkCount)
        var hasher = Insecure.MD5()
        for _ in 0..<bigChunkCount { hasher.update(data: bigChunk) }
        let bigMD5 = hasher.finalize().map { String(format: "%02x", $0) }.joined()

        let bigMock = MockSessionScope(chunkHandler: { request in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Length": "\(bigTotalBytes)"]
            )!
            return (resp, Array(repeating: bigChunk, count: bigChunkCount))
        })
        defer { bigMock.invalidate() }

        let bigFile = RemoteFile(
            id: "big-bp",
            filename: "large.bin",
            downloadLink: "https://example.com/large.bin",
            relativeDirectory: [],
            expectedSize: bigTotalBytes,
            md5: bigMD5
        )
        let downloader = FileDownloader(session: bigMock.session)
        let outcome = try await downloader.download(file: bigFile, to: tempDir, accountToken: "tok") { _ in }
        #expect(outcome == .downloaded(totalBytes: bigTotalBytes, resumed: false))
    }

    @Test("DiskFileWriter supports cancellable MD5 hashing and independent concurrent writers")
    func diskFileWriterMD5CancellationAndConcurrentWrites() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileA = tempDir.appendingPathComponent("a.bin")
        let fileB = tempDir.appendingPathComponent("b.bin")
        let dataA = Data(repeating: 0x11, count: 512 * 1024)
        let dataB = Data(repeating: 0x22, count: 512 * 1024)

        // Concurrent writers complete independently
        async let writeA: Void = {
            let writer = try await DiskFileWriter.open(at: fileA, append: false)
            try await writer.write(dataA)
            try await writer.synchronizeAndClose()
        }()
        async let writeB: Void = {
            let writer = try await DiskFileWriter.open(at: fileB, append: false)
            try await writer.write(dataB)
            try await writer.synchronizeAndClose()
        }()
        _ = try await (writeA, writeB)

        #expect(try Data(contentsOf: fileA) == dataA)
        #expect(try Data(contentsOf: fileB) == dataB)

        let expectedMD5 = Insecure.MD5.hash(data: dataA).map { String(format: "%02x", $0) }.joined()
        #expect(try await DiskFileWriter.md5Hex(of: fileA) == expectedMD5)

        // Cancelled task entering md5Hex fails promptly with CancellationError
        let cancelledTask = Task<String, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DiskFileWriter.md5Hex(of: fileA)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await cancelledTask.value
        }
    }
}
