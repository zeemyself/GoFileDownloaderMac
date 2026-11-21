import CryptoKit
import Foundation

public struct FileDownloadProgress: Sendable {
    public let bytesReceived: Int64
    public let totalBytes: Int64?
    public let resumedFromOffset: Int64
    public let isFirstReport: Bool

    public init(bytesReceived: Int64, totalBytes: Int64?, resumedFromOffset: Int64, isFirstReport: Bool = false) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.resumedFromOffset = resumedFromOffset
        self.isFirstReport = isFirstReport
    }
}

public enum FileDownloadOutcome: Sendable, Equatable {
    case downloaded(totalBytes: Int64, resumed: Bool)
    case skippedAlreadyExists(totalBytes: Int64)
}

public struct FileDownloader: Sendable {
    private let session: URLSession

    internal enum ContentRange: Equatable {
        case bytes(start: Int64, end: Int64, total: Int64?)
        case unsatisfied(total: Int64)
    }

    private struct ResumeMetadata: Codable, Sendable {
        let etag: String?
        let lastModified: String?
        let expectedSize: Int64?
    }

    public static let defaultDownloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: config)
    }()

    public init(session: URLSession = Self.defaultDownloadSession) {
        self.session = session
    }

    public static func destinationURL(baseDirectory: URL, file: RemoteFile) -> URL {
        var dir = baseDirectory
        for component in file.relativeDirectory {
            dir.appendPathComponent(GoFileAPI.sanitizePathComponent(component), isDirectory: true)
        }
        return dir.appendingPathComponent(GoFileAPI.sanitizePathComponent(file.filename), isDirectory: false)
    }

    /// Validates that all path components stay strictly inside `baseDirectory` after symlink resolution.
    public static func validatedDestinationURL(baseDirectory: URL, file: RemoteFile) throws -> URL {
        let components = file.relativeDirectory + [file.filename]
        for component in components {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if component.isEmpty || trimmed == "." || trimmed == ".."
                || component.contains("/") || component.contains("\\") || component.contains("\0") {
                throw GoFileError.unsafePath(file.relativePath)
            }
        }

        guard let canonicalBase = resolveRealPath(baseDirectory) else {
            throw GoFileError.unsafePath(file.relativePath)
        }
        var dir = canonicalBase
        for component in file.relativeDirectory {
            dir.appendPathComponent(component, isDirectory: true)
        }
        let candidate = dir.appendingPathComponent(file.filename, isDirectory: false)
        guard let canonicalFinal = resolveRealPath(candidate) else {
            throw GoFileError.unsafePath(file.relativePath)
        }

        let basePath = canonicalBase.path.hasSuffix("/") ? canonicalBase.path : canonicalBase.path + "/"
        guard canonicalFinal.path.hasPrefix(basePath), canonicalFinal.path != canonicalBase.path else {
            throw GoFileError.unsafePath(file.relativePath)
        }
        return candidate
    }

    private static func resolveRealPath(_ url: URL, depth: Int = 0) -> URL? {
        guard depth < 16 else { return nil }
        let standardized = url.standardizedFileURL
        let fm = FileManager.default
        var missingComponents: [String] = []
        var cursor = standardized

        while cursor.path != "/" {
            if let attrs = try? fm.attributesOfItem(atPath: cursor.path) {
                if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
                   let rawTarget = try? fm.destinationOfSymbolicLink(atPath: cursor.path) {
                    let targetURL = rawTarget.hasPrefix("/")
                        ? URL(fileURLWithPath: rawTarget)
                        : cursor.deletingLastPathComponent().appendingPathComponent(rawTarget)
                    guard var resolved = resolveRealPath(targetURL, depth: depth + 1) else {
                        return nil
                    }
                    for component in missingComponents.reversed() {
                        resolved.appendPathComponent(component, isDirectory: false)
                    }
                    return resolved.standardizedFileURL
                }
                break
            }
            missingComponents.append(cursor.lastPathComponent)
            cursor.deleteLastPathComponent()
        }

        var resolved = cursor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            resolved.appendPathComponent(component, isDirectory: false)
        }
        return resolved.standardizedFileURL
    }

    /// Collision-safe temporary `.part` path keyed by a short hash of `fileID` so literal `*.part` remote files never clash.
    public static func partURL(for finalURL: URL, fileID: String) -> URL {
        let idHash8 = String(GoFileAPI.sha256Hex(fileID).prefix(8))
        let suffix = ".\(idHash8).part"
        let maxNameBytes = 255 - suffix.utf8.count - 5 // keep room for ".meta" within 255-byte NAME_MAX
        let truncatedName = FilenameResolver.truncatePreservingExtension(
            finalURL.lastPathComponent,
            maxBytes: maxNameBytes
        )
        let baseName = truncatedName.isEmpty ? "download" : truncatedName
        return finalURL.deletingLastPathComponent().appendingPathComponent(baseName + suffix, isDirectory: false)
    }

    internal static func resumeMetaURL(for partURL: URL) -> URL {
        partURL.appendingPathExtension("meta")
    }

    internal static func parseContentRange(_ header: String) -> ContentRange? {
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("bytes ") else { return nil }
        let spec = trimmed.dropFirst(6).trimmingCharacters(in: .whitespaces)
        let parts = spec.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let rangePart = parts[0].trimmingCharacters(in: .whitespaces)
        let totalPart = parts[1].trimmingCharacters(in: .whitespaces)

        if rangePart == "*" {
            guard let total = Int64(totalPart), total >= 0 else { return nil }
            return .unsatisfied(total: total)
        }

        let bounds = rangePart.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int64(bounds[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start else {
            return nil
        }

        if totalPart == "*" {
            return .bytes(start: start, end: end, total: nil)
        }
        guard let total = Int64(totalPart), end < total else { return nil }
        return .bytes(start: start, end: end, total: total)
    }

    /// Downloads `file` into `baseDirectory`, supporting HTTP Range resume via a `.part` file.
    public func download(
        file: RemoteFile,
        to baseDirectory: URL,
        accountToken: String,
        onProgress: @escaping @Sendable (FileDownloadProgress) async -> Void
    ) async throws -> FileDownloadOutcome {
        try await downloadInternal(
            file: file,
            to: baseDirectory,
            accountToken: accountToken,
            allowResume: true,
            onProgress: onProgress
        )
    }

    private func downloadInternal(
        file: RemoteFile,
        to baseDirectory: URL,
        accountToken: String,
        allowResume: Bool,
        onProgress: @escaping @Sendable (FileDownloadProgress) async -> Void
    ) async throws -> FileDownloadOutcome {
        let fm = FileManager.default
        guard let canonicalBase = Self.resolveRealPath(baseDirectory) else {
            throw GoFileError.unsafePath(file.relativePath)
        }
        let basePrefix = canonicalBase.path.hasSuffix("/") ? canonicalBase.path : canonicalBase.path + "/"
        let finalURL = try Self.validatedDestinationURL(baseDirectory: canonicalBase, file: file)
        let parentDir = finalURL.deletingLastPathComponent()
        let partURL = Self.partURL(for: finalURL, fileID: file.id)
        let metaURL = Self.resumeMetaURL(for: partURL)

        if let attrs = try? fm.attributesOfItem(atPath: finalURL.path) {
            if (attrs[.type] as? FileAttributeType) == .typeSymbolicLink {
                throw GoFileError.unsafePath(file.relativePath)
            }
            if let existingSize = attrs[.size] as? Int64 {
                if let expected = file.expectedSize {
                    if existingSize == expected {
                        return .skippedAlreadyExists(totalBytes: existingSize)
                    }
                } else if existingSize > 0 {
                    return .skippedAlreadyExists(totalBytes: existingSize)
                }
            }
        }

        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        guard let canonicalParent = Self.resolveRealPath(parentDir),
              let canonicalFinalAfterCreate = Self.resolveRealPath(finalURL) else {
            throw GoFileError.unsafePath(file.relativePath)
        }
        let parentCheckPath = canonicalParent.path.hasSuffix("/") ? canonicalParent.path : canonicalParent.path + "/"
        guard parentCheckPath.hasPrefix(basePrefix),
              canonicalFinalAfterCreate.path.hasPrefix(basePrefix) else {
            throw GoFileError.unsafePath(file.relativePath)
        }

        if let partAttrs = try? fm.attributesOfItem(atPath: partURL.path),
           (partAttrs[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw GoFileError.unsafePath(file.relativePath)
        }

        var existingPartSize: Int64 = 0
        if allowResume,
           fm.fileExists(atPath: partURL.path),
           let attrs = try? fm.attributesOfItem(atPath: partURL.path),
           let size = attrs[.size] as? Int64,
           size > 0 {
            existingPartSize = size
        }

        let savedMeta: ResumeMetadata? = existingPartSize > 0 ? Self.loadResumeMetadata(from: metaURL) : nil

        guard let requestURL = URL(string: file.downloadLink) else {
            throw GoFileError.invalidURL(file.downloadLink)
        }

        var request = URLRequest(url: requestURL, timeoutInterval: 30)
        request.httpMethod = "GET"
        let headers = GoFileAPI.headers(
            accountToken: accountToken,
            url: file.downloadLink,
            includeAuth: false
        )
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if allowResume && existingPartSize > 0 {
            request.setValue("bytes=\(existingPartSize)-", forHTTPHeaderField: "Range")
            if let ifRange = savedMeta?.etag ?? savedMeta?.lastModified, !ifRange.isEmpty {
                request.setValue(ifRange, forHTTPHeaderField: "If-Range")
            }
        }

        let asyncBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (asyncBytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }

        guard let http = response as? HTTPURLResponse else {
            throw GoFileError.networkError("Invalid response for \(file.filename).")
        }

        // Handle 416 Range Not Satisfiable: rescue complete .part if server confirms exact size, else reset once without Range.
        if http.statusCode == 416 {
            if allowResume && existingPartSize > 0 {
                if let crHeader = http.value(forHTTPHeaderField: "Content-Range"),
                   case let .unsatisfied(total)? = Self.parseContentRange(crHeader),
                   total == existingPartSize,
                   file.expectedSize == nil || file.expectedSize == total {
                    do {
                        try Self.verifyMD5IfPresent(fileURL: partURL, expectedMD5: file.md5)
                    } catch {
                        try? Self.removePartArtifacts(partURL: partURL, metaURL: metaURL)
                        throw error
                    }
                    try Self.promotePartFile(from: partURL, to: finalURL, metaURL: metaURL)
                    await onProgress(
                        FileDownloadProgress(
                            bytesReceived: total,
                            totalBytes: total,
                            resumedFromOffset: existingPartSize,
                            isFirstReport: true
                        )
                    )
                    return .downloaded(totalBytes: total, resumed: true)
                }

                try Self.removePartArtifacts(partURL: partURL, metaURL: metaURL)
                return try await downloadInternal(
                    file: file,
                    to: baseDirectory,
                    accountToken: accountToken,
                    allowResume: false,
                    onProgress: onProgress
                )
            }
            throw GoFileError.httpError(416)
        }

        let isPartial = http.statusCode == 206
        guard http.statusCode == 200 || isPartial else {
            throw GoFileError.httpError(http.statusCode)
        }

        let responseETag = http.value(forHTTPHeaderField: "ETag")
        let responseLastModified = http.value(forHTTPHeaderField: "Last-Modified")

        var contentRangeTotal: Int64?
        if isPartial {
            let parsedRange = http.value(forHTTPHeaderField: "Content-Range").flatMap(Self.parseContentRange)
            let etagMismatch: Bool = {
                guard let oldETag = savedMeta?.etag, let newETag = responseETag else { return false }
                return oldETag != newETag
            }()
            let rangeValid: Bool = {
                guard allowResume, existingPartSize > 0,
                      case let .bytes(start, _, total)? = parsedRange,
                      start == existingPartSize else {
                    return false
                }
                if let total, let expected = file.expectedSize, expected > 0, total != expected {
                    return false
                }
                return true
            }()

            if !rangeValid || etagMismatch {
                if allowResume {
                    try Self.removePartArtifacts(partURL: partURL, metaURL: metaURL)
                    return try await downloadInternal(
                        file: file,
                        to: baseDirectory,
                        accountToken: accountToken,
                        allowResume: false,
                        onProgress: onProgress
                    )
                }
                throw GoFileError.integrityMismatch(
                    "Server returned mismatched Content-Range or ETag for resumed download of \(file.filename)."
                )
            }
            if case let .bytes(_, _, total)? = parsedRange {
                contentRangeTotal = total
            }
        }

        let contentLength: Int64? = {
            if let header = http.value(forHTTPHeaderField: "Content-Length"),
               let val = Int64(header.trimmingCharacters(in: .whitespaces)),
               val >= 0 {
                return val
            }
            return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        }()

        let startingOffset: Int64 = isPartial ? existingPartSize : 0
        let totalExpected: Int64? = {
            if isPartial {
                if let contentRangeTotal {
                    return contentRangeTotal
                }
                if let contentLength {
                    return startingOffset + contentLength
                }
                return file.expectedSize
            } else {
                return contentLength ?? file.expectedSize
            }
        }()

        if let expected = file.expectedSize, expected > 0,
           let totalExpected, totalExpected != expected {
            throw GoFileError.integrityMismatch(
                "Size mismatch for \(file.filename): expected \(expected) bytes, server reported \(totalExpected) bytes."
            )
        }

        if !isPartial || !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }

        Self.saveResumeMetadata(
            ResumeMetadata(etag: responseETag, lastModified: responseLastModified, expectedSize: totalExpected),
            to: metaURL
        )

        let handle = try FileHandle(forWritingTo: partURL)
        defer { try? handle.close() }
        if isPartial {
            try handle.seekToEnd()
        } else {
            try handle.truncate(atOffset: 0)
        }

        let flushSize = GoFileConfig.chunkSize(for: totalExpected ?? -1)
        var buffer = Data()
        buffer.reserveCapacity(flushSize)

        var totalWritten = startingOffset
        var lastReportedTime = ContinuousClock.now

        await onProgress(
            FileDownloadProgress(
                bytesReceived: totalWritten,
                totalBytes: totalExpected,
                resumedFromOffset: startingOffset,
                isFirstReport: true
            )
        )

        do {
            for try await byte in asyncBytes {
                try Task.checkCancellation()
                buffer.append(byte)

                if buffer.count >= flushSize {
                    try handle.write(contentsOf: buffer)
                    totalWritten += Int64(buffer.count)
                    buffer.removeAll(keepingCapacity: true)

                    let now = ContinuousClock.now
                    if now - lastReportedTime >= .milliseconds(80) {
                        lastReportedTime = now
                        await onProgress(
                            FileDownloadProgress(
                                bytesReceived: totalWritten,
                                totalBytes: totalExpected,
                                resumedFromOffset: startingOffset
                            )
                        )
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }

        try Task.checkCancellation()

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            totalWritten += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: false)
        }

        try handle.synchronize()
        try handle.close()

        // Verify exact completeness when expected length is known
        if let totalExpected, totalWritten != totalExpected {
            if totalWritten > totalExpected {
                try? Self.removePartArtifacts(partURL: partURL, metaURL: metaURL)
                throw GoFileError.integrityMismatch(
                    "Received \(totalWritten) bytes for \(file.filename), expected \(totalExpected) bytes."
                )
            }
            throw GoFileError.networkError(
                "Connection broken: IncompleteRead(\(totalWritten) bytes read, \(totalExpected - totalWritten) more expected)"
            )
        }
        if let expected = file.expectedSize, expected > 0, totalWritten != expected {
            try? Self.removePartArtifacts(partURL: partURL, metaURL: metaURL)
            throw GoFileError.integrityMismatch(
                "Downloaded \(totalWritten) bytes for \(file.filename), expected \(expected) bytes."
            )
        }

        do {
            try Self.verifyMD5IfPresent(fileURL: partURL, expectedMD5: file.md5)
        } catch {
            try? Self.removePartArtifacts(partURL: partURL, metaURL: metaURL)
            throw error
        }

        try Self.promotePartFile(from: partURL, to: finalURL, metaURL: metaURL)

        await onProgress(
            FileDownloadProgress(
                bytesReceived: totalWritten,
                totalBytes: totalWritten,
                resumedFromOffset: startingOffset
            )
        )

        return .downloaded(totalBytes: totalWritten, resumed: startingOffset > 0)
    }

    private static func verifyMD5IfPresent(fileURL: URL, expectedMD5: String?) throws {
        guard let raw = expectedMD5?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.count == 32,
              raw.allSatisfy(\.isHexDigit) else {
            return
        }
        let readHandle = try FileHandle(forReadingFrom: fileURL)
        defer { try? readHandle.close() }
        var hasher = Insecure.MD5()
        while true {
            let chunk = try readHandle.read(upToCount: 256 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if actual != raw {
            throw GoFileError.checksumMismatch(expected: raw, actual: actual)
        }
    }

    private static func promotePartFile(from partURL: URL, to finalURL: URL, metaURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: finalURL.path) {
            _ = try fm.replaceItemAt(finalURL, withItemAt: partURL)
        } else {
            try fm.moveItem(at: partURL, to: finalURL)
        }
        try? fm.removeItem(at: metaURL)
    }

    private static func removePartArtifacts(partURL: URL, metaURL: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: partURL.path) {
            try fm.removeItem(at: partURL)
        }
        if fm.fileExists(atPath: metaURL.path) {
            try? fm.removeItem(at: metaURL)
        }
    }

    private static func loadResumeMetadata(from metaURL: URL) -> ResumeMetadata? {
        guard let data = try? Data(contentsOf: metaURL) else { return nil }
        return try? JSONDecoder().decode(ResumeMetadata.self, from: data)
    }

    private static func saveResumeMetadata(_ metadata: ResumeMetadata, to metaURL: URL) {
        guard let data = try? JSONEncoder().encode(metadata) else { return }
        try? data.write(to: metaURL, options: .atomic)
    }
}
