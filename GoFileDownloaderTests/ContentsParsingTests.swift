import Foundation
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
        let partURL = FileDownloader.partURL(for: finalURL)
        try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try partialPrefix.write(to: partURL)

        var capturedRangeHeader: String?
        MockURLProtocol.handler = { request in
            capturedRangeHeader = request.value(forHTTPHeaderField: "Range")
            let headers = ["Content-Length": "\(remainingSuffix.count)"]
            let resp = HTTPURLResponse(url: request.url!, statusCode: 206, httpVersion: nil, headerFields: headers)!
            return (resp, Data(remainingSuffix))
        }

        let downloader = FileDownloader(session: makeMockSession())
        let outcome = try await downloader.download(
            file: remoteFile,
            to: tempDir,
            accountToken: "tok"
        ) { _ in }

        #expect(capturedRangeHeader == "bytes=7-")
        #expect(outcome == .downloaded(totalBytes: Int64(fullData.count), resumed: true))
        #expect(FileManager.default.fileExists(atPath: finalURL.path))
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
        let saved = try Data(contentsOf: finalURL)
        #expect(saved == fullData)
    }
}
