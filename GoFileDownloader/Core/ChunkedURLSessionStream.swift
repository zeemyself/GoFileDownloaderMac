import Foundation
import os

/// Backpressure-bounded chunked streaming adapter over `URLSessionDataTask` (`URLSessionTask.delegate`).
/// Delivers full network `Data` chunks instead of iterating byte-by-byte via `URLSession.AsyncBytes`.
internal final class ChunkedURLSessionStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private static let highWaterMark = 2 * 1024 * 1024 // 2 MB
    private static let lowWaterMark = 512 * 1024       // 512 KB

    private struct State {
        var task: URLSessionDataTask?
        var responseContinuation: CheckedContinuation<HTTPURLResponse, Error>?
        var responseDelivered = false

        var chunks: [Data] = []
        var headIndex = 0
        var bufferedBytes = 0
        var isTaskSuspended = false

        var consumerContinuation: CheckedContinuation<Data?, Error>?
        var finished = false
        var terminalError: Error?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock<State>(initialState: State())

    static func open(
        session: URLSession,
        request: URLRequest
    ) async throws -> (HTTPURLResponse, ChunkedURLSessionStream) {
        try Task.checkCancellation()
        let bridge = ChunkedURLSessionStream()
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
                let action: (result: Result<Data?, Error>?, taskToResume: URLSessionDataTask?) = state.withLock { s in
                    if s.cancelled {
                        return (.failure(CancellationError()), nil)
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
                        var taskToResume: URLSessionDataTask?
                        if s.isTaskSuspended && s.bufferedBytes <= Self.lowWaterMark && !s.finished {
                            s.isTaskSuspended = false
                            taskToResume = s.task
                        }
                        return (.success(chunk), taskToResume)
                    }
                    if s.finished {
                        if let err = s.terminalError {
                            return (.failure(err), nil)
                        }
                        return (.success(nil), nil)
                    }
                    s.consumerContinuation = continuation
                    return (nil, nil)
                }

                action.taskToResume?.resume()
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
            shouldSuspend: Bool
        ) = state.withLock { s in
            guard !s.cancelled, !s.finished else { return (nil, false) }
            if let continuation = s.consumerContinuation {
                s.consumerContinuation = nil
                return (continuation, false)
            }
            s.chunks.append(data)
            s.bufferedBytes += data.count
            if !s.isTaskSuspended && s.bufferedBytes >= Self.highWaterMark {
                s.isTaskSuspended = true
                return (nil, true)
            }
            return (nil, false)
        }

        if action.shouldSuspend {
            dataTask.suspend()
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
