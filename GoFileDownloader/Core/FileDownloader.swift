import CryptoKit
import Darwin
import Foundation
import os

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
    internal static let stagingLock = OSAllocatedUnfairLock<Void>(initialState: ())
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
        if let first = components.first,
           FilenameResolver.caseFoldKey(first) == FilenameResolver.caseFoldKey(GoFileConfig.partialStagingDirectoryName) {
            throw GoFileError.unsafePath(file.relativePath)
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

    /// Resolves symlinks left-to-right like POSIX path resolution, including dangling/non-existent tails,
    /// without lexically collapsing `..` across unresolved parent symlinks.
    private static func resolveRealPath(_ url: URL, depth: Int = 0) -> URL? {
        guard depth < 32 else { return nil }
        let rawPath = url.path
        guard !rawPath.isEmpty else { return nil }
        let fm = FileManager.default
        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        var current = URL(fileURLWithPath: "/", isDirectory: true)
        var index = 0
        while index < parts.count {
            let component = parts[index]
            if component == "." {
                index += 1
                continue
            }
            if component == ".." {
                if current.path != "/" {
                    current.deleteLastPathComponent()
                }
                index += 1
                continue
            }

            let next = current.appendingPathComponent(component, isDirectory: false)
            if let attrs = try? fm.attributesOfItem(atPath: next.path),
               (attrs[.type] as? FileAttributeType) == .typeSymbolicLink,
               let rawTarget = try? fm.destinationOfSymbolicLink(atPath: next.path) {
                var combinedPath: String
                if rawTarget.hasPrefix("/") {
                    combinedPath = rawTarget
                } else if current.path == "/" {
                    combinedPath = "/\(rawTarget)"
                } else {
                    combinedPath = "\(current.path)/\(rawTarget)"
                }
                let remaining = parts[(index + 1)...]
                if !remaining.isEmpty {
                    if !combinedPath.hasSuffix("/") {
                        combinedPath += "/"
                    }
                    combinedPath += remaining.joined(separator: "/")
                }
                return resolveRealPath(URL(fileURLWithPath: combinedPath), depth: depth + 1)
            }

            current = next
            index += 1
        }

        return current
    }

    /// Staging `.part` path isolated inside `<baseDirectory>/.gofile-partial/` so remote filenames can never collide with temp artifacts.
    public static func partURL(for file: RemoteFile, in baseDirectory: URL) -> URL {
        let foldedPath = (file.relativeDirectory + [file.filename])
            .map(FilenameResolver.caseFoldKey)
            .joined(separator: "/")
        let digest = String(GoFileAPI.sha256Hex("\(foldedPath)\0\(file.id)").prefix(32))
        return baseDirectory
            .appendingPathComponent(GoFileConfig.partialStagingDirectoryName, isDirectory: true)
            .appendingPathComponent("\(digest).part", isDirectory: false)
    }

    internal static func resumeMetaURL(for partURL: URL) -> URL {
        partURL.appendingPathExtension("meta")
    }

    internal static func cleanupStagingDirectoryIfEmpty(in baseDirectory: URL) {
        let stagingDir = baseDirectory.appendingPathComponent(GoFileConfig.partialStagingDirectoryName, isDirectory: true)
        stagingLock.withLock {
            _ = Darwin.rmdir(stagingDir.path)
        }
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
        let stagingDir = canonicalBase.appendingPathComponent(GoFileConfig.partialStagingDirectoryName, isDirectory: true)
        let partURL = Self.partURL(for: file, in: canonicalBase)
        let metaURL = Self.resumeMetaURL(for: partURL)

        if let attrs = try? fm.attributesOfItem(atPath: finalURL.path) {
            let itemType = attrs[.type] as? FileAttributeType
            guard itemType == .typeRegular else {
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

        if let stagingAttrs = try? fm.attributesOfItem(atPath: stagingDir.path) {
            let stagingType = stagingAttrs[.type] as? FileAttributeType
            guard stagingType == .typeDirectory else {
                throw GoFileError.unsafePath(GoFileConfig.partialStagingDirectoryName)
            }
            guard let canonicalStaging = Self.resolveRealPath(stagingDir) else {
                throw GoFileError.unsafePath(GoFileConfig.partialStagingDirectoryName)
            }
            let stagingCheckPath = canonicalStaging.path.hasSuffix("/") ? canonicalStaging.path : canonicalStaging.path + "/"
            guard stagingCheckPath.hasPrefix(basePrefix) else {
                throw GoFileError.unsafePath(GoFileConfig.partialStagingDirectoryName)
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

        for artifactURL in [partURL, metaURL] {
            if let artifactAttrs = try? fm.attributesOfItem(atPath: artifactURL.path),
               (artifactAttrs[.type] as? FileAttributeType) != .typeRegular {
                throw GoFileError.unsafePath(file.relativePath)
            }
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

        guard let requestURL = URL(string: file.downloadLink),
              let scheme = requestURL.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
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

        let http: HTTPURLResponse
        let stream: ChunkedURLSessionStream
        do {
            (http, stream) = try await ChunkedURLSessionStream.open(session: session, request: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }
        defer { stream.cancel() }

        let responseETag = http.value(forHTTPHeaderField: "ETag")
        let responseLastModified = http.value(forHTTPHeaderField: "Last-Modified")
        let validatorMismatch: Bool = {
            if let oldETag = savedMeta?.etag, let newETag = responseETag {
                return oldETag != newETag
            }
            if let oldLM = savedMeta?.lastModified, let newLM = responseLastModified {
                return oldLM != newLM
            }
            return false
        }()

        // Handle 416 Range Not Satisfiable: rescue complete .part if server confirms exact size, else reset once without Range.
        if http.statusCode == 416 {
            stream.cancel()
            if allowResume && existingPartSize > 0 {
                if !validatorMismatch,
                   let crHeader = http.value(forHTTPHeaderField: "Content-Range"),
                   case let .unsatisfied(total)? = Self.parseContentRange(crHeader),
                   total == existingPartSize,
                   file.expectedSize == nil || file.expectedSize == total {
                    do {
                        try await Self.verifyMD5IfPresent(fileURL: partURL, expectedMD5: file.md5)
                    } catch {
                        try? Self.removePartArtifacts(partURL: partURL, metaURL: metaURL, baseDirectory: canonicalBase)
                        throw error
                    }
                    try Self.promotePartFile(from: partURL, to: finalURL, metaURL: metaURL, baseDirectory: canonicalBase)
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

                try Self.removePartArtifacts(partURL: partURL, metaURL: metaURL, baseDirectory: canonicalBase)
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

        var contentRangeTotal: Int64?
        var contentRangeLength: Int64?
        if isPartial {
            let parsedRange = http.value(forHTTPHeaderField: "Content-Range").flatMap(Self.parseContentRange)
            let rangeValid: Bool = {
                guard allowResume, existingPartSize > 0,
                      case let .bytes(start, _, total)? = parsedRange,
                      start == existingPartSize else {
                    return false
                }
                if let total, let expected = file.expectedSize, expected >= 0, total != expected {
                    return false
                }
                return true
            }()

            if !rangeValid || validatorMismatch {
                stream.cancel()
                if allowResume {
                    try Self.removePartArtifacts(partURL: partURL, metaURL: metaURL, baseDirectory: canonicalBase)
                    return try await downloadInternal(
                        file: file,
                        to: baseDirectory,
                        accountToken: accountToken,
                        allowResume: false,
                        onProgress: onProgress
                    )
                }
                throw GoFileError.integrityMismatch(
                    "Server returned mismatched Content-Range or validator for resumed download of \(file.filename)."
                )
            }
            if case let .bytes(start, end, total)? = parsedRange {
                contentRangeTotal = total
                contentRangeLength = end - start + 1
            }
        }

        let contentLength: Int64? = {
            if let header = http.value(forHTTPHeaderField: "Content-Length"),
               let val = Int64(header.trimmingCharacters(in: .whitespaces)),
               val >= 0 {
                return val
            }
            return http.expectedContentLength >= 0 ? http.expectedContentLength : nil
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
                if let contentRangeLength {
                    return startingOffset + contentRangeLength
                }
                return file.expectedSize
            } else {
                return contentLength ?? file.expectedSize
            }
        }()

        if let expected = file.expectedSize, expected >= 0,
           let totalExpected, totalExpected != expected {
            throw GoFileError.integrityMismatch(
                "Size mismatch for \(file.filename): expected \(expected) bytes, server reported \(totalExpected) bytes."
            )
        }

        let writer = try await DiskFileWriter.open(at: partURL, append: isPartial) {
            let localFM = FileManager.default
            if let existingAttrs = try? localFM.attributesOfItem(atPath: stagingDir.path),
               (existingAttrs[.type] as? FileAttributeType) != .typeDirectory {
                throw GoFileError.unsafePath(GoFileConfig.partialStagingDirectoryName)
            }
            try localFM.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            guard let canonicalStaging = Self.resolveRealPath(stagingDir) else {
                throw GoFileError.unsafePath(GoFileConfig.partialStagingDirectoryName)
            }
            let stagingCheckPath = canonicalStaging.path.hasSuffix("/") ? canonicalStaging.path : canonicalStaging.path + "/"
            guard stagingCheckPath.hasPrefix(basePrefix) else {
                throw GoFileError.unsafePath(GoFileConfig.partialStagingDirectoryName)
            }
            if let partAttrs = try? localFM.attributesOfItem(atPath: partURL.path),
               (partAttrs[.type] as? FileAttributeType) != .typeRegular {
                throw GoFileError.unsafePath(file.relativePath)
            }
        }
        defer { writer.closeQuietly() }

        Self.saveResumeMetadata(
            ResumeMetadata(etag: responseETag, lastModified: responseLastModified, expectedSize: totalExpected),
            to: metaURL
        )

        let flushSize = GoFileConfig.chunkSize(for: totalExpected ?? -1)
        var buffer = Data()
        buffer.reserveCapacity(flushSize)

        let expectedMD5 = Self.normalizedMD5(file.md5)
        var incrementalHasher: Insecure.MD5? = (expectedMD5 != nil && startingOffset == 0) ? Insecure.MD5() : nil

        var totalWritten = startingOffset
        var totalReceived = startingOffset
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
            while let chunk = try await stream.nextChunk() {
                try Task.checkCancellation()
                buffer.append(chunk)
                totalReceived += Int64(chunk.count)
                incrementalHasher?.update(data: chunk)

                if buffer.count >= flushSize {
                    let toWrite = buffer
                    buffer = Data()
                    buffer.reserveCapacity(flushSize)
                    try await writer.write(toWrite)
                    totalWritten += Int64(toWrite.count)
                }

                let now = ContinuousClock.now
                if now - lastReportedTime >= .milliseconds(80) {
                    lastReportedTime = now
                    await onProgress(
                        FileDownloadProgress(
                            bytesReceived: totalReceived,
                            totalBytes: totalExpected,
                            resumedFromOffset: startingOffset
                        )
                    )
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw CancellationError()
        }

        try Task.checkCancellation()

        if !buffer.isEmpty {
            let remaining = buffer
            buffer = Data()
            try await writer.write(remaining)
            totalWritten += Int64(remaining.count)
        }

        try await writer.synchronizeAndClose()

        // Verify exact completeness when expected length is known
        if let totalExpected, totalWritten != totalExpected {
            if totalWritten > totalExpected {
                try? Self.removePartArtifacts(partURL: partURL, metaURL: metaURL, baseDirectory: canonicalBase)
                throw GoFileError.integrityMismatch(
                    "Received \(totalWritten) bytes for \(file.filename), expected \(totalExpected) bytes."
                )
            }
            throw GoFileError.networkError(
                "Connection broken: IncompleteRead(\(totalWritten) bytes read, \(totalExpected - totalWritten) more expected)"
            )
        }
        if let expected = file.expectedSize, expected >= 0, totalWritten != expected {
            try? Self.removePartArtifacts(partURL: partURL, metaURL: metaURL, baseDirectory: canonicalBase)
            throw GoFileError.integrityMismatch(
                "Downloaded \(totalWritten) bytes for \(file.filename), expected \(expected) bytes."
            )
        }

        if let expectedMD5 {
            do {
                let actualMD5: String
                if let hasher = incrementalHasher {
                    actualMD5 = hasher.finalize().map { String(format: "%02x", $0) }.joined()
                } else {
                    actualMD5 = try await DiskFileWriter.md5Hex(of: partURL)
                }
                if actualMD5 != expectedMD5 {
                    throw GoFileError.checksumMismatch(expected: expectedMD5, actual: actualMD5)
                }
            } catch {
                try? Self.removePartArtifacts(partURL: partURL, metaURL: metaURL, baseDirectory: canonicalBase)
                throw error
            }
        }

        try Self.promotePartFile(from: partURL, to: finalURL, metaURL: metaURL, baseDirectory: canonicalBase)

        await onProgress(
            FileDownloadProgress(
                bytesReceived: totalWritten,
                totalBytes: totalWritten,
                resumedFromOffset: startingOffset
            )
        )

        return .downloaded(totalBytes: totalWritten, resumed: startingOffset > 0)
    }

    private static func normalizedMD5(_ expectedMD5: String?) -> String? {
        guard let raw = expectedMD5?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              raw.count == 32,
              raw.allSatisfy(\.isHexDigit) else {
            return nil
        }
        return raw
    }

    private static func verifyMD5IfPresent(fileURL: URL, expectedMD5: String?) async throws {
        guard let expected = normalizedMD5(expectedMD5) else { return }
        let actual = try await DiskFileWriter.md5Hex(of: fileURL)
        if actual != expected {
            throw GoFileError.checksumMismatch(expected: expected, actual: actual)
        }
    }

    private static func promotePartFile(from partURL: URL, to finalURL: URL, metaURL: URL, baseDirectory: URL) throws {
        let stagingDir = baseDirectory.appendingPathComponent(GoFileConfig.partialStagingDirectoryName, isDirectory: true)
        try stagingLock.withLock {
            let fm = FileManager.default
            if fm.fileExists(atPath: finalURL.path) {
                _ = try fm.replaceItemAt(finalURL, withItemAt: partURL)
            } else {
                try fm.moveItem(at: partURL, to: finalURL)
            }
            try? fm.removeItem(at: metaURL)
            _ = Darwin.rmdir(stagingDir.path)
        }
    }

    private static func removePartArtifacts(partURL: URL, metaURL: URL, baseDirectory: URL) throws {
        let stagingDir = baseDirectory.appendingPathComponent(GoFileConfig.partialStagingDirectoryName, isDirectory: true)
        try stagingLock.withLock {
            let fm = FileManager.default
            if fm.fileExists(atPath: partURL.path) {
                try fm.removeItem(at: partURL)
            }
            if fm.fileExists(atPath: metaURL.path) {
                try? fm.removeItem(at: metaURL)
            }
            _ = Darwin.rmdir(stagingDir.path)
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
