// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import Darwin
import Foundation
import Logging

/// Owns the entire termination sequence. ClientProcess.kill must cooperate with
/// cancellation; the XPC reply wait does so even when the service never replies.
final class ProcessCancellationController: @unchecked Sendable {
    private let process: any ClientProcess
    private let gracePeriod: Duration
    private let requestTimeout: Duration
    private let log: Logger
    private let lock = NSLock()
    private var terminationStarted = false
    private var exited = false
    private var termination: Task<Void, Never>?

    init(
        process: any ClientProcess,
        gracePeriod: Duration = .seconds(2),
        requestTimeout: Duration = .seconds(5),
        log: Logger = Logger(label: "container.process")
    ) {
        self.process = process
        self.gracePeriod = gracePeriod
        self.requestTimeout = requestTimeout
        self.log = log
    }

    func cancel() {
        lock.withLock {
            guard !terminationStarted, !exited else { return }
            terminationStarted = true
            // This task must survive cancellation of the local process wait.
            // It is retained, joined by ProcessIO, and bounded by both deadlines.
            termination = Task { await terminate() }
        }
    }

    // Only a successful remote wait confirms exit. Cancelling the local wait
    // alone must not disarm termination of a guest that may still be running.
    func processExited() {
        let task = lock.withLock {
            exited = true
            return termination
        }
        // Cancellation handlers may acquire locks. Do not run them under ours.
        task?.cancel()
    }

    func waitForCompletion() async {
        let task = lock.withLock { termination }
        await task?.value
    }

    private func terminate() async {
        defer { lock.withLock { termination = nil } }
        for signal in [SIGTERM, SIGKILL] {
            guard !Task.isCancelled, lock.withLock({ !exited }) else { return }
            do {
                try await deliver(signal)
            } catch {
                guard !Task.isCancelled else { return }
                log.warning(
                    "failed to deliver process cancellation signal",
                    metadata: ["id": "\(process.id)", "signal": "\(signal)", "error": "\(error)"]
                )
            }
            guard signal == SIGTERM else { return }
            // A reply acknowledges the delivery attempt, not process exit. If
            // the reply times out, delivery is uncertain: still allow grace
            // before escalation, but never wait indefinitely for that reply.
            do { try await Task.sleep(for: gracePeriod) } catch { return }
        }
    }

    private func deliver(_ signal: Int32) async throws {
        try Task.checkCancellation()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await self.process.kill(signal) }
            group.addTask {
                try await Task.sleep(for: self.requestTimeout)
                throw SignalDeliveryTimedOut()
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }
}

private struct SignalDeliveryTimedOut: Error, CustomStringConvertible {
    var description: String { "timed out waiting for signal delivery acknowledgement" }
}
