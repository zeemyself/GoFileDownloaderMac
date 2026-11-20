import Foundation

public enum FilenameResolver {
    /// Returns a unique filename within `usedNames` (which stores casefolded names),
    /// appending `" (n)"` before the extension on collision.
    public static func resolveUniqueFilename(_ filename: String, usedNames: inout Set<String>) -> String {
        let lower = filename.lowercased()
        if !usedNames.contains(lower) {
            usedNames.insert(lower)
            return filename
        }

        let (stem, suffix) = splitStemAndSuffix(filename)
        var counter = 1
        while true {
            let candidate = "\(stem) (\(counter))\(suffix)"
            let candidateLower = candidate.lowercased()
            if !usedNames.contains(candidateLower) {
                usedNames.insert(candidateLower)
                return candidate
            }
            counter += 1
        }
    }

    /// Matches Python `pathlib.Path(filename).stem` and `.suffix`.
    private static func splitStemAndSuffix(_ filename: String) -> (stem: String, suffix: String) {
        guard let dotIndex = filename.lastIndex(of: "."),
              dotIndex != filename.startIndex else {
            return (filename, "")
        }
        let stem = String(filename[..<dotIndex])
        let suffix = String(filename[dotIndex...])
        return (stem, suffix)
    }
}
