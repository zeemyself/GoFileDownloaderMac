import Foundation
import Testing
@testable import GoFileDownloader

@Suite("Live GoFile Smoke Tests", .serialized)
struct LiveSmokeTests {
    @Test("Live end-to-end download and resume against GoFile API", .enabled(if: FileManager.default.fileExists(atPath: "/tmp/gofile_live_enable")))
    func liveDownloadAndResume() async throws {
        let api = GoFileAPI()
        let token = try await api.createAccountToken()
        print("LIVE_TEST: Created guest account token (\(token.prefix(8))...)")
        #expect(!token.isEmpty)

        for (url, pw) in [("https://gofile.io/d/clgeTz", String?.none), ("https://gofile.io/d/hXHGR1", Optional("TestPassword"))] {
            guard let cid = GoFileAPI.contentID(from: url) else { continue }
            do {
                let files = try await api.resolveFiles(contentID: cid, plainPassword: pw, accountToken: token)
                print("LIVE_TEST: Album \(cid) resolved \(files.count) file(s)")
                if let first = files.first {
                    let outDir = URL(fileURLWithPath: "/tmp/gofile_live_test/\(cid)")
                    try? FileManager.default.removeItem(at: outDir)
                    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

                    let downloader = FileDownloader()
                    let outcome = try await downloader.download(file: first, to: outDir, accountToken: token) { progress in
                        if progress.isFirstReport {
                            print("LIVE_TEST: Started downloading \(first.filename), expected=\(progress.totalBytes ?? -1)")
                        }
                    }
                    print("LIVE_TEST: Outcome for \(first.filename): \(outcome)")
                }
            } catch {
                print("LIVE_TEST: Album \(cid) returned error: \(error.localizedDescription)")
            }
        }
    }
}
