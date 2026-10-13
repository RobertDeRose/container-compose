// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0
import ComposeSupport
import Foundation
import Testing

@Suite("Cancellable callback waits", .timeLimit(.minutes(1)))
struct AsyncReplyTests {
    @Test func synchronousReply() async throws {
        let value: Int = try await AsyncReply.wait { $0(.success(42)) }
        #expect(value == 42)
    }

    @Test func firstReplyWins() async throws {
        let value: Int = try await AsyncReply.wait { reply in
            reply(.success(1))
            reply(.success(2))
        }
        #expect(value == 1)
    }

    @Test func errorPropagates() async {
        struct Failure: Error {}
        await #expect(throws: Failure.self) {
            let _: Int = try await AsyncReply.wait { $0(.failure(Failure())) }
        }
    }

    @Test func timeoutWithoutCallback() async {
        await #expect(throws: AsyncReply.TimedOut.self) {
            let _: Int = try await AsyncReply.wait(timeout: .milliseconds(10)) { _ in }
        }
    }

    @Test func cancellationDoesNotRequireCallback() async throws {
        let probe = ReplyProbe()
        let task = Task { try await AsyncReply.wait(register: probe.register) }
        for _ in 0..<100 where !probe.registered { try await Task.sleep(for: .milliseconds(1)) }
        #expect(probe.registered)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        probe.reply(.success(1))  // A late callback must not double-resume anything.
    }

    @Test func timeoutIgnoresLateCallback() async {
        let probe = ReplyProbe()
        await #expect(throws: AsyncReply.TimedOut.self) {
            try await AsyncReply.wait(timeout: .milliseconds(10), register: probe.register)
        }
        probe.reply(.success(1))
    }

    @Test func alreadyCancelledDoesNotSend() async throws {
        let probe = ReplyProbe()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try await AsyncReply.wait(register: probe.register)
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!probe.registered)
    }
}

private final class ReplyProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Result<Int, any Error>) -> Void)?
    var registered: Bool { lock.withLock { callback != nil } }
    func register(_ callback: @escaping @Sendable (Result<Int, any Error>) -> Void) {
        lock.withLock { self.callback = callback }
    }
    func reply(_ result: Result<Int, any Error>) {
        let callback = lock.withLock { self.callback }
        callback?(result)
    }
}
