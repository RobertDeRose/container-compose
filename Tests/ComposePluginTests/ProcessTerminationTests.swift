// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerizationError
import ContainerizationOS
import Foundation
import Logging
import Testing

@testable import ContainerCompose

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@Suite("Bounded process termination", .serialized, .timeLimit(.minutes(1)))
struct ProcessTerminationTests {
    @Test
    func missingTermReplyIsCancelledBeforeEscalation() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGTERM])
        let controller = makeController(process)
        controller.cancel()
        await controller.waitForCompletion()
        #expect(await process.signals == [SIGTERM, SIGKILL])
        #expect(await process.cancelled == [SIGTERM])
        #expect(await process.pendingCount == 0)
        #expect(await process.maximumPending == 1)
    }

    @Test
    func neitherReplyCanLeaveTerminationRunningForever() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGTERM, SIGKILL])
        let controller = makeController(process)
        let start = ContinuousClock.now
        controller.cancel()
        await controller.waitForCompletion()
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(await process.signals == [SIGTERM, SIGKILL])
        #expect(await process.cancelled == [SIGTERM, SIGKILL])
        #expect(await process.pendingCount == 0)
        #expect(await process.maximumPending == 1)
    }

    @Test
    func confirmedExitCancelsAPendingTermReply() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGTERM])
        let controller = makeController(process, timeout: .seconds(10))
        controller.cancel()
        try await waitUntil { await process.signals == [SIGTERM] }
        let exitTime = ContinuousClock.now
        controller.processExited()
        await controller.waitForCompletion()
        #expect(ContinuousClock.now - exitTime < .seconds(1))
        #expect(await process.signals == [SIGTERM])
        #expect(await process.cancelled == [SIGTERM])
        #expect(await process.pendingCount == 0)
    }

    @Test
    func confirmedExitCancelsAPendingKillReply() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGKILL])
        let controller = makeController(process, timeout: .seconds(10))
        controller.cancel()
        try await waitUntil { await process.signals == [SIGTERM, SIGKILL] }
        let exitTime = ContinuousClock.now
        controller.processExited()
        await controller.waitForCompletion()
        #expect(ContinuousClock.now - exitTime < .seconds(1))
        #expect(await process.cancelled == [SIGKILL])
        #expect(await process.pendingCount == 0)
    }

    @Test
    func gracePeriodStartsAfterTheTermReply() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGTERM])
        let grace: Duration = .milliseconds(30)
        let controller = ProcessCancellationController(process: process, gracePeriod: grace, requestTimeout: .seconds(2))
        controller.cancel()
        try await waitUntil { await process.signals == [SIGTERM] }
        // Longer than grace: the old independently started timer escalated here.
        try await Task.sleep(for: .milliseconds(90))
        #expect(await process.signals == [SIGTERM])
        await process.reply(to: SIGTERM)
        await controller.waitForCompletion()
        let termCompleted = try #require(await process.completedAt[SIGTERM])
        let killStarted = try #require(await process.startedAt[SIGKILL])
        #expect(killStarted - termCompleted >= grace)
        #expect(await process.maximumPending == 1)
    }

    @Test
    func deliveryFailureStillAllowsBoundedEscalation() async throws {
        let process = ControlledTerminationProcess(failed: [SIGTERM, SIGKILL])
        let controller = makeController(process)
        controller.cancel()
        await controller.waitForCompletion()
        #expect(await process.signals == [SIGTERM, SIGKILL])
        #expect(await process.pendingCount == 0)
    }

    @Test
    func concurrentCancellationStartsOnlyOneSequence() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGTERM, SIGKILL])
        let controller = makeController(process)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 { group.addTask { controller.cancel() } }
        }
        await controller.waitForCompletion()
        controller.cancel()
        await controller.waitForCompletion()
        #expect(await process.signals == [SIGTERM, SIGKILL])
    }

    @Test
    func cancellingTheLocalWaitDoesNotDisarmTermination() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGTERM])
        let controller = makeController(process, timeout: .seconds(2))
        let localWait = Task {
            controller.cancel()
            await controller.waitForCompletion()
        }
        try await waitUntil { await process.signals == [SIGTERM] }
        localWait.cancel()
        await process.reply(to: SIGTERM)
        await localWait.value
        #expect(await process.signals == [SIGTERM, SIGKILL])
        #expect(await process.pendingCount == 0)
    }

    @Test
    func confirmedExitBeforeCancellationDoesNotSendAnything() async {
        let process = ControlledTerminationProcess()
        let controller = makeController(process)
        controller.processExited()
        controller.cancel()
        await controller.waitForCompletion()
        #expect(await process.signals.isEmpty)
    }

    @Test
    func lateRepliesAfterTimeoutCannotRestartTermination() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGTERM, SIGKILL])
        let controller = makeController(process)
        controller.cancel()
        await controller.waitForCompletion()
        await process.reply(to: SIGTERM)
        await process.reply(to: SIGKILL)
        controller.cancel()
        await controller.waitForCompletion()
        #expect(await process.signals == [SIGTERM, SIGKILL])
        #expect(await process.pendingCount == 0)
    }

    #if os(macOS)
    @Test
    func processIOJoinsTerminationBeforeReturningCancellation() async throws {
        let process = ControlledTerminationProcess(withheld: [SIGTERM])
        let finished = CompletionFlag()
        let io = try ComposeProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        let task = Task {
            defer { finished.set() }
            return try await io.handleProcess(process: process, log: Logger(label: "test.process-join"))
        }
        defer { task.cancel() }
        try await waitUntil { await process.waitEntered }
        task.cancel()
        try await waitUntil { await process.signals == [SIGTERM] }
        #expect(!finished.value)
        await process.reply(to: SIGTERM)
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await process.signals == [SIGTERM, SIGKILL])
        #expect(await process.pendingCount == 0)
    }

    /// A wait that fails leaves a guest process whose exit was never
    /// confirmed; the command must still try to end it before returning.
    @Test
    func processIOTerminatesTheGuestWhenWaitingForItFails() async throws {
        let process = FailingWaitProcess()
        let io = try ComposeProcessIO.create(tty: false, interactive: false, detach: true)
        defer { try? io.close() }
        await #expect(throws: ContainerizationError.self) {
            try await io.handleProcess(process: process, log: Logger(label: "test.process-wait-failure"))
        }
        #expect(await process.signals == [SIGTERM, SIGKILL])
    }
    #endif

    private func makeController(
        _ process: ControlledTerminationProcess, timeout: Duration = .milliseconds(25)
    ) -> ProcessCancellationController {
        ProcessCancellationController(process: process, gracePeriod: .milliseconds(10), requestTimeout: timeout)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                throw TestFailure.conditionNotMet
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum TestFailure: Error { case conditionNotMet, rejectedSignal }

/// Simulates a callback-based service that can withhold or reject acknowledgements.
/// Like XPCClient.send, cancellation stops waiting without revoking the remote call.
private actor ControlledTerminationProcess: ClientProcess {
    nonisolated let id = "controlled"
    private let withheld: Set<Int32>
    private let failed: Set<Int32>
    private(set) var signals: [Int32] = []
    private(set) var cancelled: [Int32] = []
    private(set) var pendingCount = 0
    private(set) var maximumPending = 0
    private(set) var waitEntered = false
    private(set) var startedAt: [Int32: ContinuousClock.Instant] = [:]
    private(set) var completedAt: [Int32: ContinuousClock.Instant] = [:]
    private var replies: [Int32: AsyncThrowingStream<Void, any Error>.Continuation] = [:]

    init(withheld: Set<Int32> = [], failed: Set<Int32> = []) {
        self.withheld = withheld
        self.failed = failed
    }

    func start() async throws {}
    func resize(_ size: Terminal.Size) async throws {}
    func wait() async throws -> Int32 {
        waitEntered = true
        try await Task.sleep(for: .seconds(60))
        return 0
    }

    func kill(_ signal: Int32) async throws {
        try Task.checkCancellation()
        signals.append(signal)
        startedAt[signal] = .now
        pendingCount += 1
        maximumPending = max(maximumPending, pendingCount)
        defer {
            pendingCount -= 1
            completedAt[signal] = .now
        }
        if failed.contains(signal) { throw TestFailure.rejectedSignal }
        guard withheld.contains(signal) else { return }
        let (stream, reply) = AsyncThrowingStream<Void, any Error>.makeStream()
        replies[signal] = reply
        do {
            try await withTaskCancellationHandler {
                for try await _ in stream { return }
                try Task.checkCancellation()
            } onCancel: {
                reply.finish(throwing: CancellationError())
            }
        } catch {
            if Task.isCancelled { cancelled.append(signal) }
            throw error
        }
    }

    func reply(to signal: Int32) {
        let reply = replies.removeValue(forKey: signal)
        reply?.yield()
        reply?.finish()
    }
}

#if os(macOS)
/// A process whose wait fails as if the service disconnected, and whose
/// signals are acknowledged without it ever exiting.
private actor FailingWaitProcess: ClientProcess {
    nonisolated let id = "failing-wait"
    private(set) var signals: [Int32] = []

    func start() async throws {}
    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
    }

    func wait() async throws -> Int32 {
        throw ContainerizationError(.interrupted, message: "process service disconnected")
    }
}

private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    var value: Bool { lock.withLock { finished } }
    func set() { lock.withLock { finished = true } }
}
#endif
