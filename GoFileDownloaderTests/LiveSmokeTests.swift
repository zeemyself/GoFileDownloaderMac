import Foundation
import Testing
@testable import GoFileDownloader

@Suite("Live GoFile Smoke Tests", .serialized)
struct LiveSmokeTests {
    @Test(
        "Live end-to-end download and .part resume against GoFile API",
        .enabled(if: ProcessInfo.processInfo.environment["GOFILE_LIVE_TESTS"] == "1")
    )
    func liveDownloadAndResume() async throws {
        let env = ProcessInfo.processInfo.environment
        let api = GoFileAPI()
        let token = try await api.createAccountToken()
        #expect(!token.isEmpty)

        let targets: [(url: String, password: String?)]
        if let customURL = env["GOFILE_LIVE_URL"], !customURL.isEmpty {
            targets = [(customURL, env["GOFILE_LIVE_PASSWORD"])]
        } else {
            targets = [
                ("https://gofile.io/d/clgeTz", nil),
                ("https://gofile.io/d/hXHGR1", "TestPassword"),
            ]
        }

        let downloader = FileDownloader()
        for (url, pw) in targets {
            let cid = try #require(GoFileAPI.contentID(from: url), "Invalid GoFile URL: \(url)")
            let files = try await api.resolveFiles(contentID: cid, plainPassword: pw, accountToken: token)
            let first = try #require(files.first, "Album \(cid) returned no downloadable files")

            let outDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("gofile-live-\(cid)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outDir) }

            // 1. Fresh download
            let freshOutcome = try await downloader.download(file: first, to: outDir, accountToken: token) { _ in }
            let finalURL = FileDownloader.destinationURL(baseDirectory: outDir, file: first)
            let originalData = try Data(contentsOf: finalURL)
            guard case .downloaded(let totalBytes, let resumed) = freshOutcome else {
                Issue.record("Expected fresh .downloaded outcome, got \(freshOutcome)")
                continue
            }
            #expect(!resumed)
            #expect(totalBytes == Int64(originalData.count))

            // 2. Truncated .part resume (when file has > 1 byte)
            if originalData.count > 1 {
                let prefixLength = max(1, originalData.count / 2)
                let partURL = FileDownloader.partURL(for: first, in: outDir)
                try FileManager.default.removeItem(at: finalURL)
                try FileManager.default.createDirectory(at: partURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try originalData.prefix(prefixLength).write(to: partURL)

                let resumedOutcome = try await downloader.download(file: first, to: outDir, accountToken: token) { _ in }
                #expect(resumedOutcome == .downloaded(totalBytes: Int64(originalData.count), resumed: true))
                #expect(try Data(contentsOf: finalURL) == originalData)
            }
        }
    }
}
