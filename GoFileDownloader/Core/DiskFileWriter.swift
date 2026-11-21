import CryptoKit
import Foundation

/// Runs blocking POSIX file writes, fsync (`synchronize`), and streaming MD5 hashing on a dedicated
/// serial dispatch queue so Swift's cooperative concurrency thread pool is never blocked by disk I/O.
internal final class DiskFileWriter: @unchecked Sendable {
    private static let ioQueue = DispatchQueue(label: "com.gofiledownloader.disk-io", qos: .utility)

    private let handle: FileHandle
    private var closed = false

    private init(handle: FileHandle) {
        self.handle = handle
    }

    static func open(at url: URL, append: Bool) async throws -> DiskFileWriter {
        try await runOnIOQueue {
            let fm = FileManager.default
            if !append || !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: url)
            do {
                if append {
                    try handle.seekToEnd()
                } else {
                    try handle.truncate(atOffset: 0)
                }
            } catch {
                try? handle.close()
                throw error
            }
            return DiskFileWriter(handle: handle)
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await Self.runOnIOQueue {
            try self.handle.write(contentsOf: data)
        }
    }

    func synchronizeAndClose() async throws {
        try await Self.runOnIOQueue {
            guard !self.closed else { return }
            self.closed = true
            do {
                try self.handle.synchronize()
                try self.handle.close()
            } catch {
                try? self.handle.close()
                throw error
            }
        }
    }

    func closeQuietly() {
        Self.ioQueue.async {
            guard !self.closed else { return }
            self.closed = true
            try? self.handle.close()
        }
    }

    static func md5Hex(of fileURL: URL) async throws -> String {
        try await runOnIOQueue {
            let readHandle = try FileHandle(forReadingFrom: fileURL)
            defer { try? readHandle.close() }
            var hasher = Insecure.MD5()
            while true {
                let chunk = try readHandle.read(upToCount: 256 * 1024) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func runOnIOQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            ioQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
