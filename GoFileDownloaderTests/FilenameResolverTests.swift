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

    @Test("Case-differing duplicates are treated as collisions")
    func caseInsensitiveCollision() {
        var used = Set<String>()
        #expect(FilenameResolver.resolveUniqueFilename("Photo.JPG", usedNames: &used) == "Photo.JPG")
        #expect(FilenameResolver.resolveUniqueFilename("photo.jpg", usedNames: &used) == "photo (1).jpg")
    }

    @Test("Filenames without extensions are deduplicated cleanly")
    func noExtension() {
        var used = Set<String>()
        #expect(FilenameResolver.resolveUniqueFilename("README", usedNames: &used) == "README")
        #expect(FilenameResolver.resolveUniqueFilename("README", usedNames: &used) == "README (1)")
    }
}
