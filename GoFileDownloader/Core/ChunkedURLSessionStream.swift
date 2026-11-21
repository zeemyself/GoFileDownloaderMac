import Foundation
import os

/// Backpressure-bounded chunked streaming adapter over `URLSessionDataTask` (`URLSessionTask.delegate`).
/// Delivers full network `Data` chunks instead of iterating byte-by-byte via `URLSession.AsyncBytes`.
internal final class ChunkedURLSessionStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    internal static let defaultHighWaterMark = 2 * 1024 * 1024 // 2 MB
    internal static let defaultLowWaterMark = 512 * 1024       // 512 KB

    private let highWaterMark: Int
    private let lowWaterMark: Int

    private struct State {
        var task: URLSessionDataTask?
        var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
        var responseDelivered = false

        var chunks: [Data] = []
        var headIndex = 0
        var bufferedBytes = 0
        var desiredSuspended = false
        var appliedSuspended = false
        var isUpdatingTaskSuspension = false

        var consumerContinuation: CheckedContinuation<Data?, Error>?
        var finished = false
        var terminalError: Error?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    internal init(
        highWaterMark: Int = ChunkedURLSessionStream.defaultHighWaterMark,
        lowWaterMark: Int = ChunkedURLSessionStream.defaultLowWaterMark
    ) {
        self.highWaterMark = max(1, highWaterMark)
        self.lowWaterMark = max(0, min(lowWaterMark, self.highWaterMark - 1))
        super.init()
    }

    static func open(
        session: URLSession,
        request: URLRequest,
        highWaterMark: Int = ChunkedURLSessionStream.defaultHighWaterMark,
        lowWaterMark: Int = ChunkedURLSessionStream.defaultLowWaterMark
    ) async throws -> (HTTPURLResponse, ChunkedURLSessionStream) {
        try Task.checkCancellation()
        let bridge = ChunkedURLSessionStream(highWaterMark: highWaterMark, lowWaterMark: lowWaterMark)
        let task = session.dataTask(with: request)
        task.delegate = bridge
        bridge.state.withLock { $0.task = task }

        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPURLResponse, Error>) in
                let shouldResumeCancelled: Bool = bridge.state.withLock { s in
                    if s.cancelled {
                        return true
                    }
                    s.responseContinuation = continuation
                    return false
                }
                if shouldResumeCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    task.resume()
                }
            }
        } onCancel: {
            bridge.cancel()
        }

        return (response, bridge)
    }

    func nextChunk() async throws -> Data? {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                let action: (result: Result<Data?, Error>?, shouldReconcile: Bool) = state.withLock { s in
                    if s.cancelled {
                        return (.failure(CancellationError()), false)
                    }
                    if s.headIndex < s.chunks.count {
                        let chunk = s.chunks[s.headIndex]
                        s.chunks[s.headIndex] = Data()
                        s.headIndex += 1
                        if s.headIndex >= 64 && s.headIndex * 2 >= s.chunks.count {
                            s.chunks.removeFirst(s.headIndex)
                            s.headIndex = 0
                        }
                        s.bufferedBytes -= chunk.count
                        var shouldReconcile = false
                        if s.desiredSuspended && s.bufferedBytes <= self.lowWaterMark && !s.finished {
                            s.desiredSuspended = false
                            shouldReconcile = true
                        }
                        return (.success(chunk), shouldReconcile)
                    }
                    if s.finished {
                        if let err = s.terminalError {
                            return (.failure(err), false)
                        }
                        return (.success(nil), false)
                    }
                    s.consumerContinuation = continuation
                    return (nil, false)
                }

                if action.shouldReconcile {
                    self.reconcileTaskSuspension()
                }
                if let result = action.result {
                    continuation.resume(with: result)
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        let action: (
            respCont: CheckedContinuation<HTTPURLResponse, Error>?,
            consCont: CheckedContinuation<Data?, Error>?,
            task: URLSessionDataTask?
        ) = state.withLock { s in
            guard !s.cancelled else { return (nil, nil, nil) }
            s.cancelled = true
            s.finished = true
            s.desiredSuspended = false
            s.chunks.removeAll(keepingCapacity: false)
            s.headIndex = 0
            s.bufferedBytes = 0
            let respCont = s.responseContinuation
            s.responseContinuation = nil
            let consCont = s.consumerContinuation
            s.consumerContinuation = nil
            let task = s.task
            s.task = nil
            return (respCont, consCont, task)
        }

        action.task?.cancel()
        action.respCont?.resume(throwing: CancellationError())
        action.consCont?.resume(throwing: CancellationError())
    }

    /// Serializes `URLSessionTask.suspend()` and `resume()` calls without holding `state` lock across
    /// external `URLSessionTask` methods, ensuring a low-water resume can never overtake a high-water suspend.
    private func reconcileTaskSuspension() {
        var holdsControl = false
        while true {
            let alreadyHolding = holdsControl
            let step: (task: URLSessionDataTask, suspend: Bool)? = state.withLock { s in
                if !alreadyHolding {
                    guard !s.isUpdatingTaskSuspension else { return nil }
                    guard !s.cancelled, !s.finished, let task = s.task,
                          s.desiredSuspended != s.appliedSuspended else {
                        return nil
                    }
                    s.isUpdatingTaskSuspension = true
                    let target = s.desiredSuspended
                    s.appliedSuspended = target
                    return (task, target)
                } else {
                    guard !s.cancelled, !s.finished, let task = s.task,
                          s.desiredSuspended != s.appliedSuspended else {
                        s.isUpdatingTaskSuspension = false
                        return nil
                    }
                    let target = s.desiredSuspended
                    s.appliedSuspended = target
                    return (task, target)
                }
            }

            guard let step else { return }
            holdsControl = true
            if step.suspend {
                step.task.suspend()
            } else {
                step.task.resume()
            }
        }
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let action: (
            disposition: URLSession.ResponseDisposition,
            respCont: CheckedContinuation<HTTPURLResponse, Error>?,
            result: Result<HTTPURLResponse, Error>?
        ) = state.withLock { s in
            if s.cancelled {
                return (.cancel, nil, nil)
            }
            s.responseDelivered = true
            let respCont = s.responseContinuation
            s.responseContinuation = nil
            if let http = response as? HTTPURLResponse {
                return (.allow, respCont, .success(http))
            } else {
                let err = GoFileError.networkError("Invalid HTTP response.")
                s.finished = true
                s.terminalError = err
                return (.cancel, respCont, .failure(err))
            }
        }

        completionHandler(action.disposition)
        if let respCont = action.respCont, let result = action.result {
            respCont.resume(with: result)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        let action: (
            consCont: CheckedContinuation<Data?, Error>?,
            shouldReconcile: Bool
        ) = state.withLock { s in
            guard !s.cancelled, !s.finished else { return (nil, false) }
            if let continuation = s.consumerContinuation {
                s.consumerContinuation = nil
                return (continuation, false)
            }
            s.chunks.append(data)
            s.bufferedBytes += data.count
            if !s.desiredSuspended && s.bufferedBytes >= self.highWaterMark {
                s.desiredSuspended = true
                return (nil, true)
            }
            return (nil, false)
        }

        if action.shouldReconcile {
            reconcileTaskSuspension()
        }
        action.consCont?.resume(returning: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let initialError: Error? = {
            guard let error else { return nil }
            if let urlErr = error as? URLError, urlErr.code == .cancelled {
                return CancellationError()
            }
            return error
        }()

        let action: (
            respCont: CheckedContinuation<HTTPURLResponse, Error>?,
            consCont: CheckedContinuation<Data?, Error>?,
            finalError: Error?
        ) = state.withLock { s in
            s.finished = true
            s.desiredSuspended = false
            s.task = nil
            let effectiveError: Error? = s.cancelled ? CancellationError() : initialError
            if let effectiveError, s.terminalError == nil {
                s.terminalError = effectiveError
            }
            let respCont = s.responseContinuation
            s.responseContinuation = nil
            let consCont: CheckedContinuation<Data?, Error>?
            if s.headIndex >= s.chunks.count {
                consCont = s.consumerContinuation
                s.consumerContinuation = nil
            } else {
                consCont = nil
            }
            return (respCont, consCont, s.terminalError ?? effectiveError)
        }

        if let respCont = action.respCont {
            respCont.resume(
                throwing: action.finalError ?? GoFileError.networkError("Connection closed before HTTP headers arrived.")
            )
        }
        if let consCont = action.consCont {
            if let err = action.finalError {
                consCont.resume(throwing: err)
            } else {
                consCont.resume(returning: nil)
            }
        }
    }
}
