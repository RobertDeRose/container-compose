// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationExtras
import Darwin
import Foundation
import Logging
import MachineAPIClient

final class ComposeProcessCancellation: @unchecked Sendable {
    private let process: any ClientProcess
    private let lock = NSLock()
    private var killStarted = false

    init(process: any ClientProcess) {
        self.process = process
    }

    func cancel() {
        lock.withLock {
            guard !killStarted else { return }
            killStarted = true
            Task {
                try? await process.kill(SIGKILL)
            }
        }
    }
}

struct ComposeCapturedProcess: Sendable, Equatable {
    let exitCode: Int32
    let output: String

    init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

/// Runs Docker Compose as a process inside the persistent machine container.
struct ComposeProcessRunner: Sendable {
    private let client: ComposeProcessClient

    init(client: ComposeProcessClient = ComposeProcessClient()) {
        self.client = client
    }

    func run(
        snapshot: MachineSnapshot,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        log: Logger
    ) async throws -> Int32 {
        guard let containerId = snapshot.containerId else {
            throw ContainerizationError(
                .invalidState,
                message: "Compose machine is running but has no backing container ID"
            )
        }

        let tty = isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        // Compose must receive piped stdin for commands such as `exec -T` and
        // `-f -`, even when the host stdin is not a TTY.
        // Help is still streamed; only stdout of an exact Compose help request
        // is rewritten so it names the host command.
        let io = try ComposeProcessIO.create(
            tty: tty,
            interactive: true,
            detach: false,
            stdoutRewriter: ComposeHelpOutput.isHelpRequest(arguments) ? ComposeHelpOutput.Rewriter() : nil
        )
        defer {
            try? io.close()
        }

        let process = try await client.createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: ProcessConfiguration(
                executable: "/usr/bin/docker",
                arguments: ["compose"] + arguments,
                environment: environment.map { "\($0.key)=\($0.value)" },
                workingDirectory: workingDirectory,
                terminal: tty,
                user: .id(uid: 0, gid: 0)
            ),
            stdio: io.stdio
        )

        return try await io.handleProcess(process: process, log: log)
    }

    /// Runs a short diagnostic command and captures combined stdout/stderr.
    /// This is used for daemon readiness checks and diagnostics, not forwarded
    /// user commands.
    func capture(
        snapshot: MachineSnapshot,
        executable: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: String,
        timeout: Duration = .seconds(5),
        maxOutputBytes: Int = 1024 * 1024
    ) async throws -> ComposeCapturedProcess {
        guard let containerId = snapshot.containerId else {
            throw ContainerizationError(
                .invalidState,
                message: "Compose machine is running but has no backing container ID"
            )
        }

        let stdout = Pipe()
        let stderr = Pipe()
        let process = try await client.createProcess(
            containerId: containerId,
            processId: UUID().uuidString.lowercased(),
            configuration: ProcessConfiguration(
                executable: executable,
                arguments: arguments,
                environment: environment.map { "\($0.key)=\($0.value)" },
                workingDirectory: workingDirectory,
                terminal: false,
                user: .id(uid: 0, gid: 0)
            ),
            stdio: [nil, stdout.fileHandleForWriting, stderr.fileHandleForWriting]
        )

        return try await Self.capture(
            process: process,
            stdout: stdout,
            stderr: stderr,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes
        )
    }

    /// Runs a shell script as root in the machine and captures its output.
    func runShell(
        snapshot: MachineSnapshot,
        script: String,
        timeout: Duration = .seconds(10)
    ) async throws -> ComposeCapturedProcess {
        try await capture(
            snapshot: snapshot,
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: ComposeEnvironment.guestDaemonEnvironment,
            workingDirectory: "/",
            timeout: timeout
        )
    }

    static func capture(
        process: any ClientProcess,
        stdout: Pipe,
        stderr: Pipe,
        timeout: Duration,
        maxOutputBytes: Int
    ) async throws -> ComposeCapturedProcess {
        let cancellation = ComposeProcessCancellation(process: process)
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }

        let stopCapture: @Sendable () -> Void = {
            cancellation.cancel()
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
        }

        do {
            return try await Timeout.run(for: timeout) {
                try await withTaskCancellationHandler {
                    do {
                        try Task.checkCancellation()
                        try await process.start()
                        try Task.checkCancellation()
                        async let output: Data = {
                            do {
                                return try Self.readAll(
                                    from: stdout.fileHandleForReading,
                                    maxBytes: maxOutputBytes
                                )
                            } catch {
                                stopCapture()
                                throw error
                            }
                        }()
                        async let error: Data = {
                            do {
                                return try Self.readAll(
                                    from: stderr.fileHandleForReading,
                                    maxBytes: maxOutputBytes
                                )
                            } catch {
                                stopCapture()
                                throw error
                            }
                        }()
                        async let exitCode = process.wait()
                        let (capturedOutput, capturedError, status) = try await (output, error, exitCode)
                        var text = String(decoding: capturedOutput, as: UTF8.self)
                        text.append(String(decoding: capturedError, as: UTF8.self))
                        return ComposeCapturedProcess(exitCode: status, output: text)
                    } catch {
                        stopCapture()
                        throw error
                    }
                } onCancel: {
                    stopCapture()
                }
            }
        } catch is CancellationError {
            guard !Task.isCancelled else {
                throw CancellationError()
            }
            throw ContainerizationError(
                .timeout,
                message: "process did not exit within \(timeout)"
            )
        }
    }

    static func readAll(from handle: FileHandle, maxBytes: Int) throws -> Data {
        guard maxBytes >= 0 else {
            throw ContainerizationError(.invalidArgument, message: "captured process output limit must not be negative")
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            guard chunk.count <= maxBytes - data.count else {
                throw ContainerizationError(
                    .internalError,
                    message: "captured process output exceeded \(maxBytes) bytes"
                )
            }
            data.append(chunk)
        }
        return data
    }
}
