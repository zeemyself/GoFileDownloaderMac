import Foundation
import Testing
@testable import GoFileDownloader

@Suite("GoFileAPI Tests")
struct GoFileAPITests {
    @Test("Content ID extraction accepts valid GoFile URLs and rejects invalid hosts, schemes, or paths")
    func contentIDExtraction() {
        #expect(GoFileAPI.contentID(from: "https://gofile.io/d/clgeTz") == "clgeTz")
        #expect(GoFileAPI.contentID(from: "https://gofile.io/d/hXHGR1/") == "hXHGR1")
        #expect(GoFileAPI.contentID(from: "  https://gofile.io/d/abc123///  ") == "abc123")
        #expect(GoFileAPI.contentID(from: "https://www.gofile.io/d/abc_123-XYZ") == "abc_123-XYZ")
        #expect(GoFileAPI.contentID(from: "https://gofile.io/d/clgeTz?ref=twitter&x=1") == "clgeTz")
        #expect(GoFileAPI.contentID(from: "https://gofile.io/d/clgeTz#section") == "clgeTz")
        #expect(GoFileAPI.contentID(from: "http://GOFILE.IO/d/clgeTz?a=1#frag") == "clgeTz")

        #expect(GoFileAPI.contentID(from: "https://gofile.io/c/clgeTz") == nil)
        #expect(GoFileAPI.contentID(from: "https://gofile.io/d/clgeTz/extra") == nil)
        #expect(GoFileAPI.contentID(from: "https://gofile.io/d/..") == nil)
        #expect(GoFileAPI.contentID(from: "https://evil.com/d/clgeTz") == nil)
        #expect(GoFileAPI.contentID(from: "https://notgofile.io/d/clgeTz") == nil)
        #expect(GoFileAPI.contentID(from: "https://.gofile.io/d/clgeTz") == nil)
        #expect(GoFileAPI.contentID(from: "ftp://gofile.io/d/clgeTz") == nil)
        #expect(GoFileAPI.contentID(from: "https://example.com") == nil)
        #expect(GoFileAPI.contentID(from: "") == nil)
    }

    @Test("Website token matches Python sha256 implementation")
    func websiteTokenMatchesPython() {
        let token = GoFileAPI.websiteToken(accountToken: "test_token_123", timestamp: 1_700_000_000)
        #expect(token == "7fdb77995702a1e3486350c612c6fb7af1bdeea503565fd9793df57c9bef0043")
    }

    @Test("Password SHA-256 matches Python hashlib.sha256")
    func passwordHashMatchesPython() {
        let hash = GoFileAPI.sha256Hex("TestPassword")
        #expect(hash == "7bcf9d89298f1bfae16fa02ed6b61908fd2fa8de45dd8e2153a3c47300765328")
    }

    @Test("Content URL generation handles passwords, pagination, and rejects unsafe IDs")
    func contentURLGeneration() {
        let urlNoPw = GoFileAPI.contentURL(contentID: "clgeTz")
        #expect(urlNoPw?.absoluteString == "https://api.gofile.io/contents/clgeTz?cache=true&sortField=createTime&sortDirection=1")

        let pwHash = GoFileAPI.sha256Hex("TestPassword")
        let urlWithPw = GoFileAPI.contentURL(contentID: "hXHGR1", hashedPassword: pwHash)
        #expect(urlWithPw?.absoluteString == "https://api.gofile.io/contents/hXHGR1?cache=true&sortField=createTime&sortDirection=1&password=\(pwHash)")

        let urlPage2 = GoFileAPI.contentURL(contentID: "clgeTz", page: 2)
        #expect(urlPage2?.absoluteString == "https://api.gofile.io/contents/clgeTz?cache=true&sortField=createTime&sortDirection=1&page=2")

        #expect(GoFileAPI.contentURL(contentID: "../bad") == nil)
        #expect(GoFileAPI.contentURL(contentID: "abc?x=1") == nil)
        #expect(GoFileAPI.contentURL(contentID: "") == nil)
    }

    @Test("Headers generation sets auth headers for API and Accept-Encoding identity for downloads")
    func headersGeneration() {
        let authHeaders = GoFileAPI.headers(
            accountToken: "test_token_123",
            includeAuth: true,
            timestamp: 1_700_000_000
        )
        #expect(authHeaders["Authorization"] == "Bearer test_token_123")
        #expect(authHeaders["X-Website-Token"] == "7fdb77995702a1e3486350c612c6fb7af1bdeea503565fd9793df57c9bef0043")
        #expect(authHeaders["X-BL"] == "en-US")
        #expect(authHeaders["Accept-Encoding"] == "gzip")

        let downloadHeaders = GoFileAPI.headers(
            accountToken: "test_token_123",
            url: "https://store1.gofile.io/download/abc",
            includeAuth: false
        )
        #expect(downloadHeaders["Cookie"] == "accountToken=test_token_123")
        #expect(downloadHeaders["Referer"] == "https://store1.gofile.io/download/abc/")
        #expect(downloadHeaders["Origin"] == "https://store1.gofile.io/download/abc")
        #expect(downloadHeaders["Accept-Encoding"] == "identity")
    }

    @Test("sanitizePathComponent neutralizes traversal, separators, control/bidi chars, and long UTF-8 names")
    func sanitizePathComponentSafety() {
        #expect(GoFileAPI.sanitizePathComponent("..") == "unnamed")
        #expect(GoFileAPI.sanitizePathComponent(".") == "unnamed")
        #expect(GoFileAPI.sanitizePathComponent("   ") == "unnamed")
        #expect(GoFileAPI.sanitizePathComponent(".\u{202E}.") == "unnamed")
        #expect(GoFileAPI.sanitizePathComponent("..\0") == "unnamed")
        #expect(GoFileAPI.sanitizePathComponent("../etc/passwd") == ".._etc_passwd")
        #expect(GoFileAPI.sanitizePathComponent("a\\b/c:d") == "a_b_c_d")
        #expect(GoFileAPI.sanitizePathComponent("doc\u{202E}txt.exe") == "doctxt.exe")

        let overlong = String(repeating: "あ", count: 100) + ".mp4"
        let sanitized = GoFileAPI.sanitizePathComponent(overlong)
        #expect(sanitized.utf8.count <= GoFileConfig.maxPathComponentUTF8Bytes)
        #expect(sanitized.hasSuffix(".mp4"))
    }

    @Test("Adaptive chunk size thresholds match config.py")
    func chunkThresholds() {
        #expect(GoFileConfig.chunkSize(for: -1) == 512 * 1024)
        #expect(GoFileConfig.chunkSize(for: 500 * 1024) == 8 * 1024)
        #expect(GoFileConfig.chunkSize(for: 5 * 1024 * 1024) == 16 * 1024)
        #expect(GoFileConfig.chunkSize(for: 25 * 1024 * 1024) == 64 * 1024)
        #expect(GoFileConfig.chunkSize(for: 75 * 1024 * 1024) == 128 * 1024)
        #expect(GoFileConfig.chunkSize(for: 150 * 1024 * 1024) == 256 * 1024)
        #expect(GoFileConfig.chunkSize(for: 500 * 1024 * 1024) == 512 * 1024)
    }

    @Test("GoFileError provides non-empty descriptions for all cases")
    func errorDescriptions() {
        let cases: [GoFileError] = [
            .invalidURL("bad"),
            .accountCreationFailed,
            .passwordRequired,
            .wrongPassword,
            .notFound("abc"),
            .notPublic("abc"),
            .unsafePath("../x"),
            .integrityMismatch("size mismatch"),
            .checksumMismatch(expected: "aaa", actual: "bbb"),
            .apiError("error-other"),
            .httpError(503),
            .networkError("offline"),
        ]
        for err in cases {
            #expect(!(err.errorDescription ?? "").isEmpty)
        }
    }
}
