import Foundation
import os
import Testing
@testable import GoFileDownloader

@Suite("GoFileAPI Resolution & Account Tests")
struct ContentsParsingTests {
    @Test("createAccountToken succeeds and handles HTTP, decode, empty token, and cancellation errors")
    func accountTokenLifecycle() async throws {
        let mock = MockSessionScope { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"status":"ok","data":{"token":"guest-tok-99"}}"#.utf8))
        }
        defer { mock.invalidate() }

        let api = GoFileAPI(session: mock.session)
        let token = try await api.createAccountToken()
        #expect(token == "guest-tok-99")

        mock.update { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (resp, Data("Service Unavailable".utf8))
        }
        await #expect(throws: GoFileError.httpError(503)) {
            _ = try await api.createAccountToken()
        }

        mock.update { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("not json".utf8))
        }
        await #expect(throws: GoFileError.apiError("Failed to decode account response")) {
            _ = try await api.createAccountToken()
        }

        mock.update { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"status":"ok","data":{"token":""}}"#.utf8))
        }
        await #expect(throws: GoFileError.accountCreationFailed) {
            _ = try await api.createAccountToken()
        }

        mock.update { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            _ = try await api.createAccountToken()
        }
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

        let mock = MockSessionScope { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(payload.utf8))
        }
        defer { mock.invalidate() }

        let api = GoFileAPI(session: mock.session)
        let files = try await api.resolveFiles(contentID: "abc123", plainPassword: nil, accountToken: "tok")

        #expect(files.count == 3)
        #expect(files[0].relativePath == "album/clip.mp4")
        #expect(files[1].relativePath == "album/clip (1).mp4")
        #expect(files[2].relativePath == "album/clip (2).mp4")
    }

    @Test("Resolves single-file root link and multi-page folder pagination")
    func singleFileAndPagination() async throws {
        let singleFileJSON = """
        {
          "status": "ok",
          "data": {
            "id": "single-1",
            "type": "file",
            "name": "report.pdf",
            "link": "https://store1.gofile.io/download/report.pdf",
            "size": 1024,
            "md5": "0123456789abcdef0123456789abcdef"
          }
        }
        """

        let mock = MockSessionScope { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(singleFileJSON.utf8))
        }
        defer { mock.invalidate() }

        let api = GoFileAPI(session: mock.session)
        let singleFiles = try await api.resolveFiles(contentID: "single-1", plainPassword: nil, accountToken: "tok")
        #expect(singleFiles.count == 1)
        #expect(singleFiles[0].relativePath == "report.pdf")
        #expect(singleFiles[0].expectedSize == 1024)
        #expect(singleFiles[0].md5 == "0123456789abcdef0123456789abcdef")

        // Paginated folder across 2 pages
        let page1JSON = """
        {
          "status": "ok",
          "metadata": { "hasNextPage": true },
          "data": {
            "id": "paged",
            "type": "folder",
            "name": "BigAlbum",
            "children": {
              "f1": { "id": "f1", "type": "file", "name": "one.txt", "link": "https://example.com/1", "createTime": 1 }
            }
          }
        }
        """
        let page2JSON = """
        {
          "status": "ok",
          "metadata": { "hasNextPage": false },
          "data": {
            "id": "paged",
            "type": "folder",
            "name": "BigAlbum",
            "children": {
              "f2": { "id": "f2", "type": "file", "name": "two.txt", "link": "https://example.com/2", "createTime": 2 }
            }
          }
        }
        """
        mock.update { request in
            let isPage2 = request.url?.query?.contains("page=2") == true
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data((isPage2 ? page2JSON : page1JSON).utf8))
        }
        let pagedFiles = try await api.resolveFiles(contentID: "paged", plainPassword: nil, accountToken: "tok")
        #expect(pagedFiles.map(\.filename) == ["one.txt", "two.txt"])
    }

    @Test("Password handling distinguishes required, wrong, ok, and explicit falsy password values")
    func passwordStatesAndFalsyValues() async throws {
        let mock = MockSessionScope { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"status":"ok","data":{"type":"folder","name":"secret","password":true,"passwordStatus":"passwordRequired"}}"#.utf8))
        }
        defer { mock.invalidate() }

        let api = GoFileAPI(session: mock.session)
        await #expect(throws: GoFileError.passwordRequired) {
            _ = try await api.resolveFiles(contentID: "sec1", plainPassword: nil, accountToken: "tok")
        }

        mock.update { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"status":"ok","data":{"type":"folder","name":"secret","password":true,"passwordStatus":"passwordWrong"}}"#.utf8))
        }
        await #expect(throws: GoFileError.wrongPassword) {
            _ = try await api.resolveFiles(contentID: "sec1", plainPassword: "bad", accountToken: "tok")
        }

        mock.update { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("""
            {
              "status": "ok",
              "data": {
                "type": "folder",
                "name": "secret",
                "password": true,
                "passwordStatus": "passwordOk",
                "children": {
                  "f1": { "id": "f1", "type": "file", "name": "ok.txt", "link": "https://example.com/ok" }
                }
              }
            }
            """.utf8))
        }
        let unlocked = try await api.resolveFiles(contentID: "sec1", plainPassword: "good", accountToken: "tok")
        #expect(unlocked.count == 1)

        // Explicit falsy password values (false, "", 0) must NOT trigger passwordRequired
        for falsyLiteral in ["false", "\"\"", "0", "\"false\"", "null"] {
            mock.update { request in
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (resp, Data("""
                {
                  "status": "ok",
                  "data": {
                    "type": "folder",
                    "name": "public",
                    "password": \(falsyLiteral),
                    "children": {
                      "f1": { "id": "f1", "type": "file", "name": "open.txt", "link": "https://example.com/open" }
                    }
                  }
                }
                """.utf8))
            }
            let files = try await api.resolveFiles(contentID: "pub1", plainPassword: nil, accountToken: "tok")
            #expect(files.count == 1)
        }
    }

    @Test("Handles deterministic sorting, APFS folder collisions, cycles, API error mapping, and password redaction")
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

        let mock = MockSessionScope { request in
            let path = request.url?.path ?? ""
            let json = path.hasSuffix("/f-1") ? sub1 : (path.hasSuffix("/f-2") ? sub2 : cyclicPayload)
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(json.utf8))
        }
        defer { mock.invalidate() }

        let api = GoFileAPI(session: mock.session)
        let files = try await api.resolveFiles(contentID: "root", plainPassword: nil, accountToken: "tok")

        #expect(files.count == 4)
        #expect(files[0].id == "a-id")
        #expect(files[0].relativePath == "Root/dup.jpg")
        #expect(files[1].id == "z-id")
        #expect(files[1].relativePath == "Root/dup (1).jpg")
        #expect(files[2].relativePath == "Root/Photos/a.jpg")
        #expect(files[3].relativePath == "Root/photos (1)/a.jpg")

        // API status mappings
        mock.update { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"status":"error-notFound"}"#.utf8))
        }
        await #expect(throws: GoFileError.notFound("missing1")) {
            _ = try await api.resolveFiles(contentID: "missing1", plainPassword: nil, accountToken: "tok")
        }

        mock.update { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(#"{"status":"error-notPublic"}"#.utf8))
        }
        await #expect(throws: GoFileError.notPublic("priv1")) {
            _ = try await api.resolveFiles(contentID: "priv1", plainPassword: nil, accountToken: "tok")
        }

        // HTTP status, password redaction, and cancellation propagation
        let secret = "SuperSecret123"
        let secretHash = GoFileAPI.sha256Hex(secret)
        mock.update { request in
            let resp = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!
            return (resp, Data("Too Many Requests".utf8))
        }
        await #expect(throws: GoFileError.httpError(429)) {
            _ = try await api.resolveFiles(contentID: "root", plainPassword: secret, accountToken: "tok")
        }

        mock.update { _ in throw URLError(.cannotFindHost) }
        do {
            _ = try await api.resolveFiles(contentID: "root", plainPassword: secret, accountToken: "tok")
            Issue.record("Expected networkError")
        } catch let error as GoFileError {
            let desc = error.localizedDescription
            #expect(!desc.contains(secretHash))
            #expect(!desc.contains("password="))
        }

        mock.update { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            _ = try await api.resolveFiles(contentID: "root", plainPassword: secret, accountToken: "tok")
        }
    }

    @Test("Reports pagination overflow, recursion depth overflow, and renames staging-dir collisions")
    func reportsPaginationDepthOverflowAndStagingRename() async throws {
        let pageCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        let mock = MockSessionScope { request in
            let p = pageCount.withLock { c in c += 1; return c }
            let json = """
            {
              "status": "ok",
              "metadata": { "hasNextPage": true },
              "data": {
                "id": "huge",
                "type": "folder",
                "name": "HugeAlbum",
                "children": {
                  "f-\(p)": { "id": "f-\(p)", "type": "file", "name": "file\(p).txt", "link": "https://example.com/\(p)", "createTime": \(p) }
                }
              }
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        defer { mock.invalidate() }

        let api = GoFileAPI(session: mock.session)
        do {
            _ = try await api.resolveFiles(contentID: "huge", plainPassword: nil, accountToken: "tok")
            Issue.record("Expected pagination overflow error")
        } catch let GoFileError.apiError(msg) {
            #expect(msg.contains("pagination"))
        }
        #expect(pageCount.withLock { $0 } == GoFileConfig.maxPaginationPages)

        // Recursion depth overflow
        mock.update { request in
            let currentID = request.url?.lastPathComponent ?? "d0"
            let depthNum = Int(currentID.dropFirst()) ?? 0
            let nextID = "d\(depthNum + 1)"
            let json = """
            {
              "status": "ok",
              "data": {
                "id": "\(currentID)",
                "type": "folder",
                "name": "level\(depthNum)",
                "children": {
                  "\(nextID)": { "id": "\(nextID)", "type": "folder", "name": "level\(depthNum + 1)", "createTime": 1 }
                }
              }
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        do {
            _ = try await api.resolveFiles(contentID: "d0", plainPassword: nil, accountToken: "tok")
            Issue.record("Expected recursion depth overflow error")
        } catch let GoFileError.apiError(msg) {
            #expect(msg.contains("depth"))
        }

        // Root folder named .gofile-partial is renamed out of staging namespace
        mock.update { request in
            let json = """
            {
              "status": "ok",
              "data": {
                "id": "stg",
                "type": "folder",
                "name": "\(GoFileConfig.partialStagingDirectoryName)",
                "children": {
                  "f1": { "id": "f1", "type": "file", "name": "a.txt", "link": "https://example.com/a", "createTime": 1 }
                }
              }
            }
            """
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
        let renamed = try await api.resolveFiles(contentID: "stg", plainPassword: nil, accountToken: "tok")
        #expect(renamed.count == 1)
        #expect(renamed[0].relativeDirectory.first == "\(GoFileConfig.partialStagingDirectoryName) (1)")
    }
}
