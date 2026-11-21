import CryptoKit
import Foundation
import os

/// Runs blocking POSIX file writes, fsync (`synchronize`), and streaming MD5 hashing off Swift's
/// cooperative concurrency thread pool. Each writer owns a dedicated serial queue so concurrent
/// downloads do not block one another, and `md5Hex` runs on a concurrent utility queue with cancellation.
internal final class DiskFileWriter: @unchecked Sendable {
    private static let hashingQueue = DispatchQueue(
        label: "com.gofiledownloader.disk-md5",
        qos: .utility,
        attributes: .concurrent
    )

    private let ioQueue: DispatchQueue
    private let handle: FileHandle
    private var closed = false

    private init(ioQueue: DispatchQueue, handle: FileHandle) {
        self.ioQueue = ioQueue
        self.handle = handle
    }

    static func open(
        at url: URL,
        append: Bool,
        prepareUnderStagingLock: (@Sendable () throws -> Void)? = nil
    ) async throws -> DiskFileWriter {
        let queue = DispatchQueue(label: "com.gofiledownloader.disk-io.\(UUID().uuidString)", qos: .utility)
        return try await runOnQueue(queue) {
            let handle: FileHandle = try FileDownloader.stagingLock.withLock {
                try prepareUnderStagingLock?()
                let fm = FileManager.default
                if !append || !fm.fileExists(atPath: url.path) {
                    fm.createFile(atPath: url.path, contents: nil)
                }
                return try FileHandle(forWritingTo: url)
            }
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
            return DiskFileWriter(ioQueue: queue, handle: handle)
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await Self.runOnQueue(ioQueue) {
            try self.handle.write(contentsOf: data)
        }
    }

    func synchronizeAndClose() async throws {
        try await Self.runOnQueue(ioQueue) {
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
        ioQueue.async {
            guard !self.closed else { return }
            self.closed = true
            try? self.handle.close()
        }
    }

    static func md5Hex(of fileURL: URL) async throws -> String {
        try Task.checkCancellation()
        let isCancelled = OSAllocatedUnfairLock<Bool>(initialState: false)
        return try await withTaskCancellationHandler {
            try await runOnQueue(hashingQueue) {
                let readHandle = try FileHandle(forReadingFrom: fileURL)
                defer { try? readHandle.close() }
                var hasher = Insecure.MD5()
                while true {
                    if isCancelled.withLock({ $0 }) {
                        throw CancellationError()
                    }
                    let chunk = try readHandle.read(upToCount: 256 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    hasher.update(data: chunk)
                }
                if isCancelled.withLock({ $0 }) {
                    throw CancellationError()
                }
                return hasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
        } onCancel: {
            isCancelled.withLock { $0 = true }
        }
    }

    private static func runOnQueue<T: Sendable>(
        _ queue: DispatchQueue,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
