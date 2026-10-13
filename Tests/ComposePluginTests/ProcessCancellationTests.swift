// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerizationOS
import Darwin
import Logging
import Testing

@testable import ContainerCompose

@Suite("Process cancellation", .serialized)
struct ProcessCancellationTests {
    @Test
    func cancellationBeforeStartupAcknowledgementEscalatesOnce() async throws {
        let process = CancellationTestProcess()
        let cancellation = ProcessCancellationController(
            process: process,
            gracePeriod: .milliseconds(10)
        )

        cancellation.cancel()
        cancellation.cancel()
        for _ in 0..<20 where await process.recordedSignals().count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await process.recordedSignals() == [SIGTERM, SIGKILL])
    }

    @Test
    func confirmedExitDisarmsEscalation() async throws {
        let process = CancellationTestProcess()
        let cancellation = ProcessCancellationController(process: process, gracePeriod: .milliseconds(80))
        cancellation.cancel()
        for _ in 0..<30 where await process.recordedSignals().isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        cancellation.processExited()
        try await Task.sleep(for: .milliseconds(120))
        #expect(await process.recordedSignals() == [SIGTERM])
    }

    @Test
    func cancellationAfterExitDoesNotSignal() async throws {
        let process = CancellationTestProcess()
        let cancellation = ProcessCancellationController(process: process, gracePeriod: .milliseconds(1))
        cancellation.processExited()
        cancellation.cancel()
        try await Task.sleep(for: .milliseconds(10))
        #expect(await process.recordedSignals().isEmpty)
    }

    @Test
    func signalDuringStartupIsForwarded() async throws {
        let process = BlockingStartProcess()
        let io = try ComposeProcessIO.create(tty: false, interactive: false, detach: true)
        let task = Task {
            try await io.handleProcess(
                process: process,
                log: Logger(label: "process-signal-test")
            )
        }

        for _ in 0..<20 where !(await process.startEntered) {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard await process.startEntered else {
            task.cancel()
            _ = try? await task.value
            Issue.record("process startup did not begin")
            return
        }
        raise(SIGUSR2)
        await process.releaseStart()

        for _ in 0..<20 where await process.recordedSignals().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        let signals = await process.recordedSignals()
        task.cancel()
        _ = try? await task.value
        #expect(signals.first == SIGUSR2)
    }
}

private actor CancellationTestProcess: ClientProcess {
    nonisolated let id = "mock"
    private var signals = [Int32]()

    func start() async throws {}

    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
    }

    func wait() async throws -> Int32 { 0 }

    func recordedSignals() -> [Int32] { signals }
}

private actor BlockingStartProcess: ClientProcess {
    nonisolated let id = "blocking-start"
    private(set) var startEntered = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var signals = [Int32]()
    private var exitCode: Int32?
    private var waitContinuation: CheckedContinuation<Int32, Never>?

    func start() async throws {
        startEntered = true
        guard exitCode == nil else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func releaseStart() {
        startContinuation?.resume()
        startContinuation = nil
    }

    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
        exitCode = 0
        startContinuation?.resume()
        startContinuation = nil
        waitContinuation?.resume(returning: 0)
        waitContinuation = nil
    }

    func wait() async throws -> Int32 {
        if let exitCode {
            return exitCode
        }
        return await withCheckedContinuation { continuation in
            waitContinuation = continuation
        }
    }

    func recordedSignals() -> [Int32] { signals }
}
