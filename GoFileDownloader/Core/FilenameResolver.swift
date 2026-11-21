import Foundation

public enum FilenameResolver {
    /// Unicode case-folding key matching APFS case-insensitive comparison.
    public static func caseFoldKey(_ string: String) -> String {
        string.folding(options: .caseInsensitive, locale: nil)
    }

    /// Truncates `string` on scalar/Character boundaries so its UTF-8 encoding does not exceed `maxBytes`.
    public static func truncateUTF8(_ string: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if string.utf8.count <= maxBytes {
            return string
        }
        var result = ""
        var usedBytes = 0
        for char in string {
            let charBytes = String(char).utf8.count
            if usedBytes + charBytes > maxBytes {
                break
            }
            result.append(char)
            usedBytes += charBytes
        }
        return result
    }

    /// Truncates `filename` to at most `maxBytes` UTF-8 bytes while preserving its extension when possible.
    public static func truncatePreservingExtension(_ filename: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        if filename.utf8.count <= maxBytes {
            return filename
        }
        let (stem, suffix) = splitStemAndSuffix(filename)
        if !suffix.isEmpty, suffix.utf8.count < maxBytes {
            let stemBudget = maxBytes - suffix.utf8.count
            let truncatedStem = truncateUTF8(stem, maxBytes: stemBudget)
            if !truncatedStem.isEmpty {
                return truncatedStem + suffix
            }
        }
        return truncateUTF8(filename, maxBytes: maxBytes)
    }

    /// Returns a unique filename within `usedNames` (which stores casefolded names),
    /// appending `" (n)"` before the extension on collision while staying within UTF-8 path limits.
    public static func resolveUniqueFilename(_ filename: String, usedNames: inout Set<String>) -> String {
        let maxBytes = GoFileConfig.maxPathComponentUTF8Bytes
        let bounded = truncatePreservingExtension(filename, maxBytes: maxBytes)
        let normalized = bounded.isEmpty ? "unnamed" : bounded

        let folded = caseFoldKey(normalized)
        if !usedNames.contains(folded) {
            usedNames.insert(folded)
            return normalized
        }

        let (stem, suffix) = splitStemAndSuffix(normalized)
        var counter = 1
        while true {
            let countTag = " (\(counter))"
            let candidate: String
            let stemBudget = maxBytes - suffix.utf8.count - countTag.utf8.count
            if stemBudget > 0 {
                let truncatedStem = truncateUTF8(stem, maxBytes: stemBudget)
                if !truncatedStem.isEmpty {
                    candidate = "\(truncatedStem)\(countTag)\(suffix)"
                } else {
                    let prefixBudget = max(0, maxBytes - countTag.utf8.count)
                    candidate = truncateUTF8(normalized, maxBytes: prefixBudget) + countTag
                }
            } else {
                let prefixBudget = max(0, maxBytes - countTag.utf8.count)
                candidate = truncateUTF8(normalized, maxBytes: prefixBudget) + countTag
            }

            let candidateFolded = caseFoldKey(candidate)
            if !usedNames.contains(candidateFolded) {
                usedNames.insert(candidateFolded)
                return candidate
            }
            counter += 1
        }
    }

    /// Splits a filename into stem and extension, keeping dotfiles (`.env`) and trailing-dot names (`file.`) whole.
    private static func splitStemAndSuffix(_ filename: String) -> (stem: String, suffix: String) {
        guard let dotIndex = filename.lastIndex(of: "."),
              dotIndex != filename.startIndex,
              dotIndex != filename.index(before: filename.endIndex) else {
            return (filename, "")
        }
        let stem = String(filename[..<dotIndex])
        let suffix = String(filename[dotIndex...])
        return (stem, suffix)
    }
}
