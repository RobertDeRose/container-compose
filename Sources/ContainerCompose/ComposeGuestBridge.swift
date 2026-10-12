// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerResource
import Darwin
import Foundation
import Logging

/// Relays a host connection through the stdin and stdout of a guest process,
/// for both the Docker socket and published ports.
///
/// The guest process's stdin and stdout are pipes that this process copies
/// to and from the connection. The runtime turns a closed stdin pipe into
/// EOF in the guest, but not a half-closed socket, and Docker clients
/// half-close hijacked streams (`exec` without `-i` does so immediately).
enum ComposeGuestBridge {
    static let outputDrainTimeout: Duration = .seconds(3)
    static let disconnectPollInterval: Duration = .seconds(1)
    /// How long the guest process gets after SIGTERM before SIGKILL.
    static let terminationGracePeriod: Duration = .seconds(2)

    /// Starts a guest process and relays `connection` through its stdin and
    /// stdout, then closes the connection. Throws, leaving the connection
    /// open, when the process cannot be started.
    static func bridge(_ connection: Int32, containerID: String, configuration: ProcessConfiguration, log: Logger) async throws {
        // An XPC connection does not survive an API server restart, so each
        // bridge uses a new one.
        let client = ComposeProcessClient()
        let input = try ComposeRelayPipe()
        let output = try ComposeRelayPipe()
        let process = try await client.createProcess(
            containerId: containerID,
            processId: UUID().uuidString.lowercased(),
            configuration: configuration,
            stdio: [input.takeReadEnd(), output.takeWriteEnd(), nil]
        )
        try await process.start()
        await relay(connection, process: process, input: input.takeOwnedEnd(), output: output.takeOwnedEnd(), log: log)
        withExtendedLifetime(client) {}
    }

    /// Copies between the client and the guest process until both finish,
    /// then closes all three descriptors.
    ///
    /// The guest process is ended when the client goes away or a copy fails,
    /// with the same bounded escalation as a cancelled Compose command: a
    /// SIGTERM it ignores, or that cannot be delivered, is followed by
    /// SIGKILL after `gracePeriod`, and each request has its own timeout.
    static func relay(
        _ connection: Int32,
        process: any ClientProcess,
        input: Int32,
        output: Int32,
        disconnectPollInterval: Duration = Self.disconnectPollInterval,
        gracePeriod: Duration = Self.terminationGracePeriod,
        log: Logger
    ) async {
        let termination = ProcessCancellationController(process: process, gracePeriod: gracePeriod, log: log)
        let clientToGuest = Task {
            _ = await Self.onThread { Self.pump(from: connection, to: input) }
            // EOF from the client, half-close included, becomes EOF on the
            // guest's stdin, which forwards it to the daemon.
            _ = close(input)
        }
        let guestToClient = Task {
            let end = await Self.onThread { Self.pump(from: output, to: connection) }
            switch end {
            case .endOfInput:
                _ = shutdown(connection, SHUT_WR)
            case .writeFailed, .readFailed:
                termination.cancel()
            }
        }
        // The guest process outlives a vanished client while the daemon
        // keeps a quiet stream open (for example `events`), so stop it then.
        let monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: disconnectPollInterval)
                if !Task.isCancelled, Self.peerClosed(connection) {
                    termination.cancel()
                    return
                }
            }
        }
        do {
            _ = try await process.wait()
            termination.processExited()
        } catch {
            // Only a successful wait confirms exit. The process may still be
            // running, so end it if the service can still be reached.
            log.warning("Waiting for the guest relay failed; stopping it", metadata: ["error": "\(error)"])
            termination.cancel()
        }
        monitor.cancel()
        await monitor.value
        // Output written before exit is still in the pipe. Deliver it, but do
        // not let a pipe the runtime has not closed hold the client open.
        _ = await Self.completes(guestToClient, within: Self.outputDrainTimeout)
        // Wakes the client-to-guest copy and ends the client's stream.
        _ = shutdown(connection, SHUT_RDWR)
        await clientToGuest.value
        // A copy still blocked on the output pipe ends when the runtime
        // closes it, and may then still write to or shut down the client
        // socket. Release both descriptors only after it finishes so neither
        // number is reused by another connection while it is in use.
        Task {
            await guestToClient.value
            _ = close(output)
            _ = close(connection)
            await termination.waitForCompletion()
        }
    }

    enum PumpEnd: Equatable {
        case endOfInput
        case readFailed
        case writeFailed
    }

    /// Copies bytes until the source reaches EOF or either side fails.
    static func pump(from source: Int32, to destination: Int32) -> PumpEnd {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(source, $0.baseAddress, $0.count) }
            if count == 0 {
                return .endOfInput
            }
            if count < 0 {
                if errno == EINTR { continue }
                return .readFailed
            }
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return -1 }
                    return write(destination, base + offset, count - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    return .writeFailed
                }
                offset += written
            }
        }
    }

    /// Waits for `task` for at most `timeout`, and returns whether it finished.
    /// Unlike `Timeout.run`, whose task group waits for its operation even
    /// after the deadline, this returns at the deadline while a blocked copy
    /// (which ignores cancellation) keeps running.
    static func completes(_ task: Task<Void, Never>, within timeout: Duration) async -> Bool {
        let once = ComposeResumeOnce()
        return await withCheckedContinuation { continuation in
            Task {
                await task.value
                once.resume(continuation, returning: true)
            }
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(continuation, returning: false)
            }
        }
    }

    /// Runs blocking I/O on its own thread instead of the cooperative pool.
    static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: body())
            }
        }
    }

    /// Returns whether the client has closed both directions. A client that
    /// only shut down writing (hijacked attach after stdin EOF) still reads.
    /// A Unix socket reports a full close at once; a TCP connection only
    /// after keepalive finds the peer gone (see `ComposePortListener`).
    static func peerClosed(_ connection: Int32) -> Bool {
        send(connection, "", 0, 0) < 0 && errno == EPIPE
    }
}

/// Resumes a continuation from whichever of several tasks gets there first.
final class ComposeResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resume<T: Sendable>(_ continuation: CheckedContinuation<T, Never>, returning value: T) {
        let first = lock.withLock {
            defer { resumed = true }
            return !resumed
        }
        if first {
            continuation.resume(returning: value)
        }
    }
}

/// A pipe whose guest end is transferred to the runtime and whose other end
/// this process owns as a raw descriptor.
final class ComposeRelayPipe: @unchecked Sendable {
    private var readEnd: Int32
    private var writeEnd: Int32

    init() throws {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw POSIXError.fromErrno()
        }
        for descriptor in descriptors {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        }
        readEnd = descriptors[0]
        writeEnd = descriptors[1]
    }

    deinit {
        if readEnd >= 0 { _ = close(readEnd) }
        if writeEnd >= 0 { _ = close(writeEnd) }
    }

    /// Returns the read end for transfer; `createProcess` closes it.
    func takeReadEnd() -> FileHandle {
        defer { readEnd = -1 }
        return FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
    }

    /// Returns the write end for transfer; `createProcess` closes it.
    func takeWriteEnd() -> FileHandle {
        defer { writeEnd = -1 }
        return FileHandle(fileDescriptor: writeEnd, closeOnDealloc: true)
    }

    /// Returns the end that was not transferred. The caller must close it.
    func takeOwnedEnd() -> Int32 {
        if readEnd >= 0 {
            defer { readEnd = -1 }
            return readEnd
        }
        defer { writeEnd = -1 }
        return writeEnd
    }
}
