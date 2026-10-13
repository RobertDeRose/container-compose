// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerizationError
import ContainerizationOS
import Darwin
import Foundation
import Logging
import Testing

@testable import ContainerCompose

@Suite("Compose process lifecycle")
struct ComposeProcessLifecycleTests {
    @Test
    func captureCancellationKillsBeforeStartupAcknowledgement() async throws {
        let process = MockClientProcess()
        let cancellation = ComposeProcessCancellation(process: process)

        cancellation.cancel()
        for _ in 0..<20 where await process.recordedSignals().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await process.recordedSignals() == [SIGKILL])
    }

    @Test
    func capturedOutputLimitKillsTheProcess() async throws {
        let stdout = Pipe()
        let stderr = Pipe()
        let process = MockClientProcess {
            try? stderr.fileHandleForWriting.close()
        }
        stdout.fileHandleForWriting.write(Data(repeating: 1, count: 1_025))
        try stdout.fileHandleForWriting.close()
        defer { try? stderr.fileHandleForWriting.close() }
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: ContainerizationError.self) {
            try await ComposeProcessRunner.capture(
                process: process,
                stdout: stdout,
                stderr: stderr,
                timeout: .seconds(5),
                maxOutputBytes: 1_024
            )
        }
        #expect(clock.now - start < .seconds(1))
        for _ in 0..<20 where await process.recordedSignals().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await process.recordedSignals() == [SIGKILL])
    }

    @Test
    func capturedOutputAcceptsTheLimit() throws {
        let pipe = Pipe()
        pipe.fileHandleForWriting.write(Data(repeating: 1, count: 1_024))
        try pipe.fileHandleForWriting.close()

        let output = try ComposeProcessRunner.readAll(
            from: pipe.fileHandleForReading,
            maxBytes: 1_024
        )
        #expect(output.count == 1_024)
    }

    @Test(.timeLimit(.minutes(1)))
    func startupTimeoutKillsTheProcess() async throws {
        let process = BlockingComposeProcess()
        let stdout = Pipe()
        let stderr = Pipe()
        try stdout.fileHandleForWriting.close()
        try stderr.fileHandleForWriting.close()

        do {
            _ = try await ComposeProcessRunner.capture(
                process: process,
                stdout: stdout,
                stderr: stderr,
                timeout: .milliseconds(20),
                maxOutputBytes: 1_024
            )
            Issue.record("timed out capture unexpectedly succeeded")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.timeout))
        }
        #expect(await process.recordedSignals() == [SIGKILL])
    }
}

private actor MockClientProcess: ClientProcess {
    nonisolated let id = "mock"
    private let onKill: @Sendable () -> Void
    private var signals = [Int32]()

    init(onKill: @escaping @Sendable () -> Void = {}) {
        self.onKill = onKill
    }

    func start() async throws {}

    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
        onKill()
    }

    func wait() async throws -> Int32 { 0 }

    func recordedSignals() -> [Int32] { signals }
}

private actor BlockingComposeProcess: ClientProcess {
    nonisolated let id = "blocking"
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var signals = [Int32]()

    func start() async throws {
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func resize(_ size: Terminal.Size) async throws {}

    func kill(_ signal: Int32) async throws {
        signals.append(signal)
        startContinuation?.resume()
        startContinuation = nil
    }

    func wait() async throws -> Int32 { 0 }

    func recordedSignals() -> [Int32] { signals }
}
