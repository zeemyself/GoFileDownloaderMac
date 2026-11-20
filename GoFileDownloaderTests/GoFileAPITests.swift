import Foundation
import Testing
@testable import GoFileDownloader

@Suite("GoFileAPI Tests")
struct GoFileAPITests {
    @Test("Content ID extraction from valid and invalid URLs")
    func contentIDExtraction() {
        #expect(GoFileAPI.contentID(from: "https://gofile.io/d/clgeTz") == "clgeTz")
        #expect(GoFileAPI.contentID(from: "https://gofile.io/d/hXHGR1/") == "hXHGR1")
        #expect(GoFileAPI.contentID(from: "  https://gofile.io/d/abc123///  ") == "abc123")
        #expect(GoFileAPI.contentID(from: "https://gofile.io/c/clgeTz") == nil)
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

    @Test("Content URL generation with and without password")
    func contentURLGeneration() {
        let urlNoPw = GoFileAPI.contentURL(contentID: "clgeTz")
        #expect(urlNoPw?.absoluteString == "https://api.gofile.io/contents/clgeTz?cache=true&sortField=createTime&sortDirection=1")

        let pwHash = GoFileAPI.sha256Hex("TestPassword")
        let urlWithPw = GoFileAPI.contentURL(contentID: "hXHGR1", hashedPassword: pwHash)
        #expect(urlWithPw?.absoluteString == "https://api.gofile.io/contents/hXHGR1?cache=true&sortField=createTime&sortDirection=1&password=\(pwHash)")
    }

    @Test("Headers generation for auth and file download requests")
    func headersGeneration() {
        let authHeaders = GoFileAPI.headers(
            accountToken: "test_token_123",
            includeAuth: true,
            timestamp: 1_700_000_000
        )
        #expect(authHeaders["Authorization"] == "Bearer test_token_123")
        #expect(authHeaders["X-Website-Token"] == "7fdb77995702a1e3486350c612c6fb7af1bdeea503565fd9793df57c9bef0043")
        #expect(authHeaders["X-BL"] == "en-US")

        let downloadHeaders = GoFileAPI.headers(
            accountToken: "test_token_123",
            url: "https://store1.gofile.io/download/abc",
            includeAuth: false
        )
        #expect(downloadHeaders["Cookie"] == "accountToken=test_token_123")
        #expect(downloadHeaders["Referer"] == "https://store1.gofile.io/download/abc/")
        #expect(downloadHeaders["Origin"] == "https://store1.gofile.io/download/abc")
    }

    @Test("Adaptive chunk size thresholds match config.py")
    func chunkThresholds() {
        #expect(GoFileConfig.chunkSize(for: 500 * 1024) == 8 * 1024)
        #expect(GoFileConfig.chunkSize(for: 5 * 1024 * 1024) == 16 * 1024)
        #expect(GoFileConfig.chunkSize(for: 25 * 1024 * 1024) == 64 * 1024)
        #expect(GoFileConfig.chunkSize(for: 75 * 1024 * 1024) == 128 * 1024)
        #expect(GoFileConfig.chunkSize(for: 150 * 1024 * 1024) == 256 * 1024)
        #expect(GoFileConfig.chunkSize(for: 500 * 1024 * 1024) == 512 * 1024)
    }

    @Test("Retry backoff with jitter scales exponentially and increases for HTTP 421/429")
    func retryJitterBackoff() {
        let normal1 = DownloadEngine.retryDelayMilliseconds(attempt: 1, error: GoFileError.httpError(500))
        let normal2 = DownloadEngine.retryDelayMilliseconds(attempt: 2, error: GoFileError.httpError(500))
        #expect((1_450...2_450).contains(normal1))
        #expect((2_650...3_650).contains(normal2))

        let rate1 = DownloadEngine.retryDelayMilliseconds(attempt: 1, error: GoFileError.httpError(421))
        let rate2 = DownloadEngine.retryDelayMilliseconds(attempt: 2, error: GoFileError.httpError(421))
        #expect((3_000...4_500).contains(rate1))
        #expect((5_500...7_000).contains(rate2))
    }
}
