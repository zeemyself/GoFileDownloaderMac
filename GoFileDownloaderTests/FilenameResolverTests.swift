import Foundation
import Testing
@testable import GoFileDownloader

@Suite("FilenameResolver Tests")
struct FilenameResolverTests {
    @Test("Unique filenames remain unchanged")
    func uniqueFilenamesUnchanged() {
        var used = Set<String>()
        #expect(FilenameResolver.resolveUniqueFilename("alpha.txt", usedNames: &used) == "alpha.txt")
        #expect(FilenameResolver.resolveUniqueFilename("beta.png", usedNames: &used) == "beta.png")
    }

    @Test("Duplicate filenames receive incrementing (n) suffixes")
    func duplicateFilenamesNumbered() {
        var used = Set<String>()
        #expect(FilenameResolver.resolveUniqueFilename("photo.jpg", usedNames: &used) == "photo.jpg")
        #expect(FilenameResolver.resolveUniqueFilename("photo.jpg", usedNames: &used) == "photo (1).jpg")
        #expect(FilenameResolver.resolveUniqueFilename("photo.jpg", usedNames: &used) == "photo (2).jpg")
    }

    @Test("Deduplication skips numbers already claimed in the same folder")
    func avoidsExistingNumberedFilename() {
        var used = Set<String>()
        #expect(FilenameResolver.resolveUniqueFilename("file.txt", usedNames: &used) == "file.txt")
        #expect(FilenameResolver.resolveUniqueFilename("file (1).txt", usedNames: &used) == "file (1).txt")
        #expect(FilenameResolver.resolveUniqueFilename("file.txt", usedNames: &used) == "file (2).txt")
    }

    @Test("Case-differing and Unicode duplicates are treated as collisions")
    func caseInsensitiveCollision() {
        var used = Set<String>()
        #expect(FilenameResolver.resolveUniqueFilename("Photo.JPG", usedNames: &used) == "Photo.JPG")
        #expect(FilenameResolver.resolveUniqueFilename("photo.jpg", usedNames: &used) == "photo (1).jpg")
        #expect(FilenameResolver.resolveUniqueFilename("CAFÉ.txt", usedNames: &used) == "CAFÉ.txt")
        #expect(FilenameResolver.resolveUniqueFilename("café.txt", usedNames: &used) == "café (1).txt")
    }

    @Test("Filenames without extensions, dotfiles, and trailing dots deduplicate cleanly")
    func extensionEdgeCases() {
        var used = Set<String>()
        #expect(FilenameResolver.resolveUniqueFilename("README", usedNames: &used) == "README")
        #expect(FilenameResolver.resolveUniqueFilename("README", usedNames: &used) == "README (1)")

        #expect(FilenameResolver.resolveUniqueFilename(".env", usedNames: &used) == ".env")
        #expect(FilenameResolver.resolveUniqueFilename(".env", usedNames: &used) == ".env (1)")

        #expect(FilenameResolver.resolveUniqueFilename("file.", usedNames: &used) == "file.")
        #expect(FilenameResolver.resolveUniqueFilename("file.", usedNames: &used) == "file. (1)")
    }

    @Test("Overlong filenames stay within UTF-8 bounds while preserving extension")
    func utf8LengthBounds() {
        var used = Set<String>()
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
