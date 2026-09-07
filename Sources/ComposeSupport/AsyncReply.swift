// Copyright © 2026 the container-compose authors.
// SPDX-License-Identifier: Apache-2.0

/// A cancellable wait for a callback. Cancellation stops waiting, not the remote operation.
public enum AsyncReply {
    public struct TimedOut: Error, Sendable {}

    public static func wait<Value: Sendable>(
        timeout: Duration? = nil,
        register: (@escaping @Sendable (Result<Value, any Error>) -> Void) -> Void
    ) async throws -> Value {
        try Task.checkCancellation()
        let (stream, continuation) = AsyncThrowingStream<Value, any Error>.makeStream()
        register { result in
            switch result {
            case .success(let value):
                continuation.yield(value)
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
        }
        let timer = timeout.map { duration in
            Task {
                do { try await Task.sleep(for: duration) } catch { return }
                continuation.finish(throwing: TimedOut())
            }
        }
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            for try await value in stream {
                return value
            }
            // The stream is only finished without a value by cancellation.
            throw CancellationError()
        } onCancel: {
            continuation.finish(throwing: CancellationError())
        }
    }
}
