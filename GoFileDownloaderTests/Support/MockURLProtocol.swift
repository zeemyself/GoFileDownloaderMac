import Foundation
import os

/// Thread-safe, per-session URLProtocol mock safe for parallel Swift Testing suites.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias ChunkHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, [Data])
    typealias SingleHandler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private struct Registration: Sendable {
        let handler: ChunkHandler
        let chunkDelay: TimeInterval
    }

    fileprivate static let sessionHeaderKey = "X-Mock-Session-ID"
    private static let handlers = OSAllocatedUnfairLock<[String: Registration]>(initialState: [:])

    private let isStopped = OSAllocatedUnfairLock<Bool>(initialState: false)

    static func register(id: String, chunkDelay: TimeInterval = 0, handler: @escaping ChunkHandler) {
        handlers.withLock { $0[id] = Registration(handler: handler, chunkDelay: chunkDelay) }
    }

    static func unregister(id: String) {
        _ = handlers.withLock { $0.removeValue(forKey: id) }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let sessionID = request.value(forHTTPHeaderField: Self.sessionHeaderKey),
              let registration = Self.handlers.withLock({ $0[sessionID] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, chunks) = try registration.handler(request)
            if isStopped.withLock({ $0 }) { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for (index, chunk) in chunks.enumerated() {
                if isStopped.withLock({ $0 }) { return }
                if index > 0 && registration.chunkDelay > 0 {
                    Thread.sleep(forTimeInterval: registration.chunkDelay)
                    if isStopped.withLock({ $0 }) { return }
                }
                if !chunk.isEmpty {
                    client?.urlProtocol(self, didLoad: chunk)
                }
            }
            if !isStopped.withLock({ $0 }) {
                client?.urlProtocolDidFinishLoading(self)
            }
        } catch {
            if !isStopped.withLock({ $0 }) {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {
        isStopped.withLock { $0 = true }
    }
}

/// Owns a `URLSession` scoped to a unique `MockURLProtocol` ID and unregisters automatically.
final class MockSessionScope: @unchecked Sendable {
    let session: URLSession
    private let id: String

    init(chunkDelay: TimeInterval = 0, chunkHandler: @escaping MockURLProtocol.ChunkHandler) {
        let id = UUID().uuidString
        self.id = id
        MockURLProtocol.register(id: id, chunkDelay: chunkDelay, handler: chunkHandler)

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        config.httpAdditionalHeaders = [MockURLProtocol.sessionHeaderKey: id]
        self.session = URLSession(configuration: config)
    }

    convenience init(handler: @escaping MockURLProtocol.SingleHandler) {
        self.init { request in
            let (response, data) = try handler(request)
            return (response, [data])
        }
    }

    func update(handler: @escaping MockURLProtocol.SingleHandler) {
        MockURLProtocol.register(id: id) { request in
            let (response, data) = try handler(request)
            return (response, [data])
        }
    }

    func updateChunks(chunkDelay: TimeInterval = 0, _ chunkHandler: @escaping MockURLProtocol.ChunkHandler) {
        MockURLProtocol.register(id: id, chunkDelay: chunkDelay, handler: chunkHandler)
    }

    func invalidate() {
        MockURLProtocol.unregister(id: id)
        session.invalidateAndCancel()
    }

    deinit {
        MockURLProtocol.unregister(id: id)
        session.invalidateAndCancel()
    }
}
