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
            dir.appendPathComponent(component, isDirectory: true)
        }
        return dir.appendingPathComponent(file.filename, isDirectory: false)
    }

    public static func partURL(for finalURL: URL) -> URL {
        finalURL.appendingPathExtension("part")
    }

    /// Downloads `file` into `baseDirectory`, supporting HTTP Range resume via a `.part` file.
    public func download(
        file: RemoteFile,
        to baseDirectory: URL,
        accountToken: String,
        onProgress: @escaping @Sendable (FileDownloadProgress) async -> Void
    ) async throws -> FileDownloadOutcome {
        let fm = FileManager.default
        let finalURL = Self.destinationURL(baseDirectory: baseDirectory, file: file)
        let parentDir = finalURL.deletingLastPathComponent()
        let partURL = Self.partURL(for: finalURL)

        // Skip if final file already exists and is non-empty (matches Python `Path(final_path).exists()`)
        if fm.fileExists(atPath: finalURL.path),
           let attrs = try? fm.attributesOfItem(atPath: finalURL.path),
           let existingSize = attrs[.size] as? Int64,
           existingSize > 0 {
            return .skippedAlreadyExists(totalBytes: existingSize)
        }

        try fm.createDirectory(at: parentDir, withIntermediateDirectories: true)

        var existingPartSize: Int64 = 0
        if fm.fileExists(atPath: partURL.path),
           let attrs = try? fm.attributesOfItem(atPath: partURL.path),
           let size = attrs[.size] as? Int64,
           size > 0 {
            existingPartSize = size
        }

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
        if existingPartSize > 0 {
            request.setValue("bytes=\(existingPartSize)-", forHTTPHeaderField: "Range")
        }

        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GoFileError.networkError("Invalid response for \(file.filename).")
        }

        // Handle 416 Range Not Satisfiable by resetting .part and retrying without Range
        if http.statusCode == 416 && existingPartSize > 0 {
            try? fm.removeItem(at: partURL)
            return try await download(
                file: file,
                to: baseDirectory,
                accountToken: accountToken,
                onProgress: onProgress
            )
        }

        let isPartial = http.statusCode == 206
        guard http.statusCode == 200 || isPartial else {
            throw GoFileError.httpError(http.statusCode)
        }

        let contentLength: Int64? = {
            if let header = http.value(forHTTPHeaderField: "Content-Length"),
               let val = Int64(header), val >= 0 {
                return val
            }
            return response.expectedContentLength >= 0 ? response.expectedContentLength : nil
        }()

        let startingOffset: Int64 = isPartial ? existingPartSize : 0
        let totalExpected: Int64? = {
            if let contentLength {
                return startingOffset + contentLength
            }
            return file.expectedSize
        }()

        if !isPartial || !fm.fileExists(atPath: partURL.path) {
            fm.createFile(atPath: partURL.path, contents: nil)
        }

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

        try Task.checkCancellation()

        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            totalWritten += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: false)
        }

        try handle.synchronize()
        try handle.close()

        // Verify completeness if Content-Length was known
        if let totalExpected, totalExpected > 0, totalWritten < totalExpected {
            throw GoFileError.networkError(
                "Connection broken: IncompleteRead(\(totalWritten) bytes read, \(totalExpected - totalWritten) more expected)"
            )
        }

        if fm.fileExists(atPath: finalURL.path) {
            try fm.removeItem(at: finalURL)
        }
        try fm.moveItem(at: partURL, to: finalURL)

        await onProgress(
            FileDownloadProgress(
                bytesReceived: totalWritten,
                totalBytes: totalWritten,
                resumedFromOffset: startingOffset
            )
        )

        return .downloaded(totalBytes: totalWritten, resumed: startingOffset > 0)
    }
}
