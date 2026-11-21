import Foundation
import Testing
@testable import GoFileDownloader

@Suite("P0 Security & Integrity Tests")
struct P0SecurityAndIntegrityTests {
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

    @Test("validatedDestinationURL blocks path traversal and symlink escapes")
    func validatedDestinationURLContainment() throws {
        let baseDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outsideDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
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
        ]

        for bad in traversalCases {
            #expect(throws: GoFileError.unsafePath(bad.relativePath)) {
                _ = try FileDownloader.validatedDestinationURL(baseDirectory: baseDir, file: bad)
            }
        }

        // Symlink inside baseDir pointing outside baseDir must be blocked
        let escapeLink = baseDir.appendingPathComponent("escape", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: escapeLink, withDestinationURL: outsideDir)
        let symlinkEscapeFile = RemoteFile(
            id: "7",
            filename: "pwned.txt",
            downloadLink: "https://example.com/7",
            relativeDirectory: ["escape"]
        )
        #expect(throws: GoFileError.unsafePath(symlinkEscapeFile.relativePath)) {
            _ = try FileDownloader.validatedDestinationURL(baseDirectory: baseDir, file: symlinkEscapeFile)
        }

        // Valid nested file succeeds even when parent does not yet exist
        let valid = RemoteFile(
            id: "8",
            filename: "safe.bin",
            downloadLink: "https://example.com/8",
            relativeDirectory: ["album", "sub"]
        )
        let resolved = try FileDownloader.validatedDestinationURL(baseDirectory: baseDir, file: valid)
        #expect(resolved.lastPathComponent == "safe.bin")
    }

    @Test("partURL avoids .part filename collisions and respects 255-byte NAME_MAX")
    func collisionSafePartURL() {
        let dir = URL(fileURLWithPath: "/tmp/gfd-part-test", isDirectory: true)
        let normalFinal = dir.appendingPathComponent("clip.mp4")
        let literalPartFinal = dir.appendingPathComponent("clip.mp4.part")

        let normalPart = FileDownloader.partURL(for: normalFinal, fileID: "file-1")
        let literalPartTemp = FileDownloader.partURL(for: literalPartFinal, fileID: "file-2")

        #expect(normalPart != literalPartFinal)
        #expect(normalPart != literalPartTemp)
        #expect(normalPart.pathExtension == "part")

        let longName = String(repeating: "x", count: 240) + ".bin"
        let longPart = FileDownloader.partURL(for: dir.appendingPathComponent(longName), fileID: "file-3")
        let longMeta = FileDownloader.resumeMetaURL(for: longPart)
        #expect(longPart.lastPathComponent.utf8.count <= 255)
        #expect(longMeta.lastPathComponent.utf8.count <= 255)
    }

    @Test("parseContentRange handles valid and malformed Content-Range headers")
    func parseContentRangeCases() {
        #expect(FileDownloader.parseContentRange("bytes 7-31/32") == .bytes(start: 7, end: 31, total: 32))
        #expect(FileDownloader.parseContentRange("bytes 0-0/*") == .bytes(start: 0, end: 0, total: nil))
        #expect(FileDownloader.parseContentRange("BYTES */1024") == .unsatisfied(total: 1024))
        #expect(FileDownloader.parseContentRange("bytes 10-5/32") == nil)
        #expect(FileDownloader.parseContentRange("bytes 0-32/32") == nil)
        #expect(FileDownloader.parseContentRange("bytes */*") == nil)
        #expect(FileDownloader.parseContentRange("items 0-10/20") == nil)
    }

    @Test("File download headers enforce Accept-Encoding identity while API headers keep gzip")
    func downloadHeadersUseIdentityEncoding() {
        let apiHeaders = GoFileAPI.headers(accountToken: "tok", includeAuth: true, timestamp: 1_700_000_000)
        #expect(apiHeaders["Accept-Encoding"] == "gzip")

        let dlHeaders = GoFileAPI.headers(
            accountToken: "tok",
            url: "https://store1.gofile.io/download/x",
            includeAuth: false
        )
        #expect(dlHeaders["Accept-Encoding"] == "identity")
    }

    @Test("FilenameResolver handles Unicode case-folding, trailing dots, and UTF-8 length bounds")
    func filenameResolverEdgeCases() {
        var used = Set<String>()
        #expect(FilenameResolver.resolveUniqueFilename("CAFÉ.txt", usedNames: &used) == "CAFÉ.txt")
        #expect(FilenameResolver.resolveUniqueFilename("café.txt", usedNames: &used) == "café (1).txt")

        #expect(FilenameResolver.resolveUniqueFilename("file.", usedNames: &used) == "file.")
        #expect(FilenameResolver.resolveUniqueFilename("file.", usedNames: &used) == "file. (1)")

        let longBase = String(repeating: "a", count: 230) + ".mp4"
        let first = FilenameResolver.resolveUniqueFilename(longBase, usedNames: &used)
        let second = FilenameResolver.resolveUniqueFilename(longBase, usedNames: &used)
        #expect(first.utf8.count <= GoFileConfig.maxPathComponentUTF8Bytes)
        #expect(second.utf8.count <= GoFileConfig.maxPathComponentUTF8Bytes)
        #expect(first.hasSuffix(".mp4"))
        #expect(second.hasSuffix(".mp4"))
        #expect(first != second)
    }
}
