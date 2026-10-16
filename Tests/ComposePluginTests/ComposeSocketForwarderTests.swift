// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerizationError
import ContainerizationOS
import Darwin
import Foundation
import Logging
import SystemPackage
import Testing

@testable import ContainerCompose

@Suite("Docker socket forwarder")
struct ComposeSocketForwarderTests {
    /// Unix socket paths are limited to 104 bytes, so avoid the long
    /// per-user temporary directory.
    private static func makeDirectory() throws -> FilePath {
        let template = strdup("/tmp/ccs-XXXXXX")!
        defer { free(template) }
        guard mkdtemp(template) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FilePath(String(cString: template))
    }

    private static func endpoint(in directory: FilePath) -> ComposeSocketEndpoint {
        ComposeSocketEndpoint(homeDirectory: directory)
    }

    private static func createRunDirectory(for endpoint: ComposeSocketEndpoint) throws {
        try FileManager.default.createDirectory(
            atPath: endpoint.path.removingLastComponent().string,
            withIntermediateDirectories: true
        )
    }

    @Test
    func endpointUsesTheOriginalSocketLocation() {
        let endpoint = ComposeSocketEndpoint(homeDirectory: FilePath("/Users/me"))

        #expect(endpoint.path == FilePath("/Users/me/.local/run/docker.socket"))
        #expect(endpoint.lockPath == FilePath("/Users/me/.local/run/docker.socket.lock"))
        #expect(endpoint.logPath == FilePath("/Users/me/Library/Logs/container-compose/docker-socket.log"))
        #expect(endpoint.dockerHost == "unix:///Users/me/.local/run/docker.socket")
    }

    @Test
    func socketAddressRejectsPathsLongerThanTheKernelLimit() {
        let path = FilePath("/" + String(repeating: "a", count: 200))
        #expect(throws: (any Error).self) {
            _ = try ComposeSocketEndpoint.socketAddress(for: path)
        }
    }

    @Test
    func unavailableResponseIsADockerAPIError() throws {
        let response = String(decoding: ComposeSocketForwarder.unavailableResponse(message: "machine \"x\" failed"), as: UTF8.self)
        let parts = response.components(separatedBy: "\r\n\r\n")
        #expect(parts.count == 2)
        #expect(parts[0].hasPrefix("HTTP/1.1 503 Service Unavailable\r\n"))
        #expect(parts[0].contains("Content-Type: application/json"))
        #expect(parts[0].contains("Content-Length: \(parts[1].utf8.count)"))
        let body = try JSONDecoder().decode([String: String].self, from: Data(parts[1].utf8))
        #expect(body == ["message": "machine \"x\" failed"])
    }

    @Test
    func lockAllowsOneOwnerAndRecordsIt() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let path = directory.appending("docker.socket.lock")

        let first = try #require(try ComposeSocketLock.acquire(path: path, identity: "build-a"))
        #expect(try ComposeSocketLock.acquire(path: path, identity: "build-b") == nil)
        #expect(ComposeSocketLock.owner(at: path) == .init(pid: getpid(), identity: "build-a"))

        first.release()
        let second = try #require(try ComposeSocketLock.acquire(path: path, identity: "build-b"))
        #expect(ComposeSocketLock.owner(at: path)?.identity == "build-b")
        second.release()
    }

    @Test
    func listenerAcceptsAndRemovesOnlyItsOwnSocket() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let endpoint = Self.endpoint(in: directory)
        try Self.createRunDirectory(for: endpoint)

        let listener = try ComposeSocketListener.bind(path: endpoint.path)
        #expect(endpoint.isAccepting())
        var status = stat()
        #expect(lstat(endpoint.path.string, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o600)

        listener.close()
        #expect(!FileManager.default.fileExists(atPath: endpoint.path.string))
        #expect(!endpoint.isAccepting())
    }

    @Test
    func listenerReplacesAStaleSocket() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let endpoint = Self.endpoint(in: directory)
        try Self.createRunDirectory(for: endpoint)

        // A crashed forwarder leaves its socket file without a listener.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try ComposeSocketEndpoint.socketAddress(for: endpoint.path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(stale, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        close(stale)
        #expect(!endpoint.isAccepting())

        let listener = try ComposeSocketListener.bind(path: endpoint.path)
        #expect(endpoint.isAccepting())
        listener.close()
    }

    @Test
    func listenerRefusesToReplaceOtherFilesOrLiveSockets() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let endpoint = Self.endpoint(in: directory)
        try Self.createRunDirectory(for: endpoint)

        let live = try ComposeSocketListener.bind(path: endpoint.path)
        #expect(throws: (any Error).self) {
            _ = try ComposeSocketListener.bind(path: endpoint.path)
        }
        #expect(endpoint.isAccepting())
        live.close()

        #expect(FileManager.default.createFile(atPath: endpoint.path.string, contents: Data("keep".utf8)))
        #expect(throws: (any Error).self) {
            _ = try ComposeSocketListener.bind(path: endpoint.path)
        }
        #expect(FileManager.default.contents(atPath: endpoint.path.string) == Data("keep".utf8))
    }

    @Test
    func peerClosedIgnoresHalfCloseButDetectsDisconnect() throws {
        var sockets: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        closeOnExec(sockets)
        defer { close(sockets[0]) }
        var enabled: Int32 = 1
        setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))

        #expect(!ComposeGuestBridge.peerClosed(sockets[0]))
        shutdown(sockets[1], SHUT_WR)
        #expect(!ComposeGuestBridge.peerClosed(sockets[0]))
        close(sockets[1])
        #expect(ComposeGuestBridge.peerClosed(sockets[0]))
    }

    @Test
    func awaitRequestRejectsProbesAndLeavesRequestBytes() async throws {
        var probe: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &probe) == 0)
        closeOnExec(probe)
        defer { close(probe[0]) }
        close(probe[1])
        #expect(await !ComposeSocketForwarder.awaitRequest(probe[0]))

        var request: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &request) == 0)
        closeOnExec(request)
        defer {
            close(request[0])
            close(request[1])
        }
        _ = "GET".withCString { write(request[1], $0, 3) }
        #expect(await ComposeSocketForwarder.awaitRequest(request[0]))
        var buffer = [UInt8](repeating: 0, count: 8)
        #expect(read(request[0], &buffer, buffer.count) == 3)
    }

    @Test
    func completesReturnsAtTheDeadlineForAnUncancellableTask() async throws {
        let blocked = Task {
            _ = await ComposeGuestBridge.onThread { usleep(2_000_000) }
        }
        let started = ContinuousClock.now
        #expect(await !ComposeGuestBridge.completes(blocked, within: .milliseconds(100)))
        #expect(ContinuousClock.now - started < .seconds(1))

        #expect(await ComposeGuestBridge.completes(Task {}, within: .seconds(5)))
    }

    @Test
    func pumpCopiesUntilEndOfInput() throws {
        var source: [Int32] = [0, 0]
        var destination: [Int32] = [0, 0]
        #expect(pipe(&source) == 0)
        closeOnExec(source)
        #expect(pipe(&destination) == 0)
        closeOnExec(destination)
        defer {
            close(source[0])
            close(destination[0])
            close(destination[1])
        }
        let payload = [UInt8](repeating: 7, count: 32 * 1024)
        #expect(write(source[1], payload, payload.count) == payload.count)
        close(source[1])

        #expect(ComposeGuestBridge.pump(from: source[0], to: destination[1]) == .endOfInput)
        var received = [UInt8](repeating: 0, count: payload.count + 1)
        #expect(read(destination[0], &received, received.count) == payload.count)
        #expect(Array(received.prefix(payload.count)) == payload)
    }

    @Test
    func pumpReportsAFailedWrite() throws {
        var source: [Int32] = [0, 0]
        #expect(pipe(&source) == 0)
        closeOnExec(source)
        // A pipe whose read end is closed is not a reliable failure: a child
        // another test spawns before closeOnExec runs can inherit that read
        // end and keep the write succeeding. A read-only descriptor, opened
        // close-on-exec atomically, refuses every write.
        let destination = open("/dev/null", O_RDONLY | O_CLOEXEC)
        try #require(destination >= 0)
        defer {
            close(source[0])
            close(destination)
        }
        #expect(write(source[1], "x", 1) == 1)
        close(source[1])

        #expect(ComposeGuestBridge.pump(from: source[0], to: destination) == .writeFailed)
    }

    @Test
    func relayPipeKeepsTheEndThatWasNotTransferred() throws {
        let input = try ComposeRelayPipe()
        let guestRead = input.takeReadEnd()
        let hostWrite = input.takeOwnedEnd()
        defer { close(hostWrite) }

        #expect(write(hostWrite, "ok", 2) == 2)
        #expect(try guestRead.read(upToCount: 2) == Data("ok".utf8))
        try guestRead.close()
    }

    @Test
    func dialStdioTargetsTheGuestDaemon() {
        let configuration = ComposeSocketForwarder.dialStdioConfiguration
        #expect(configuration.executable == "/usr/bin/docker")
        #expect(configuration.arguments == ["system", "dial-stdio"])
        #expect(configuration.environment.contains("DOCKER_HOST=\(ComposeEnvironment.innerDockerHost)"))
        #expect(!configuration.terminal)
    }

    @Test
    func sessionPreparesOnceForConcurrentConnections() async throws {
        let counter = Counter()
        let session = ComposeMachineSession {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return "container-\(await counter.value)"
        }

        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<5 {
                group.addTask { try await session.containerID(replacing: nil) }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(Set(ids) == ["container-1"])
        #expect(await counter.value == 1)

        // A stale ID is replaced; an ID that was already replaced is not.
        #expect(try await session.containerID(replacing: "container-1") == "container-2")
        #expect(try await session.containerID(replacing: "container-1") == "container-2")
        #expect(await counter.value == 2)
    }

    @Test
    func sessionDoesNotCacheFailures() async throws {
        let counter = Counter()
        let session = ComposeMachineSession {
            await counter.increment()
            if await counter.value == 1 {
                throw POSIXError(.ECONNREFUSED)
            }
            return "container"
        }

        await #expect(throws: POSIXError.self) {
            _ = try await session.containerID(replacing: nil)
        }
        #expect(try await session.containerID(replacing: nil) == "container")
    }

    @Test
    func launcherLeavesAMatchingOrForeignListenerRunning() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let endpoint = Self.endpoint(in: directory)
        try Self.createRunDirectory(for: endpoint)
        let listener = try ComposeSocketListener.bind(path: endpoint.path)
        defer { listener.close() }

        // A spawn would fail: the executable does not exist.
        try ComposeSocketLauncher.ensureRunning(
            endpoint: endpoint,
            executablePath: "/nonexistent/compose",
            identity: "current"
        )

        let lock = try #require(try ComposeSocketLock.acquire(path: endpoint.lockPath, identity: "current"))
        defer { lock.release() }
        try ComposeSocketLauncher.ensureRunning(
            endpoint: endpoint,
            executablePath: "/nonexistent/compose",
            identity: "current"
        )
        #expect(endpoint.isAccepting())
    }

    // MARK: Relay termination

    /// A guest relay that ignores SIGTERM after its client went away is
    /// killed, so the relay cannot wait on it forever.
    @Test(.timeLimit(.minutes(1)))
    func relayEscalatesWhenTheGuestIgnoresTermination() async throws {
        let (connection, client) = try Self.connectionPair()
        let input = try closeOnExecPipe()
        let output = try closeOnExecPipe()
        defer { close(input[0]) }
        let process = ScriptedClientProcess(exitOn: SIGKILL, closingOnExit: output[1])
        // The client closes both directions without sending anything.
        close(client)

        let started = ContinuousClock.now
        await ComposeGuestBridge.relay(
            connection,
            process: process,
            input: input[1],
            output: output[0],
            disconnectPollInterval: .milliseconds(10),
            gracePeriod: .milliseconds(50),
            log: Logger(label: "test.relay")
        )
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(await process.signals == [SIGTERM, SIGKILL])
    }

    /// A failed wait is not an exit: the relay still ends the guest process
    /// and the client's stream.
    @Test(.timeLimit(.minutes(1)))
    func relayEndsTheGuestWhenWaitingForItFails() async throws {
        let (connection, client) = try Self.connectionPair()
        defer { close(client) }
        let input = try closeOnExecPipe()
        let output = try closeOnExecPipe()
        defer { close(input[0]) }
        let process = ScriptedClientProcess(exitOn: nil, closingOnExit: output[1], waitFails: true)

        await ComposeGuestBridge.relay(
            connection,
            process: process,
            input: input[1],
            output: output[0],
            disconnectPollInterval: .milliseconds(10),
            gracePeriod: .milliseconds(50),
            log: Logger(label: "test.relay")
        )
        // The client's stream ended without waiting for the escalation.
        var byte: UInt8 = 0
        #expect(read(client, &byte, 1) == 0)
        try await waitUntil { await process.signals == [SIGTERM, SIGKILL] }
    }

    private static func connectionPair() throws -> (Int32, Int32) {
        var sockets: [Int32] = [0, 0]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0)
        closeOnExec(sockets)
        var enabled: Int32 = 1
        setsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        return (sockets[0], sockets[1])
    }

    // MARK: Connection tracking

    @Test
    func drainFinishesOnceTheLastConnectionCloses() {
        let finished = SyncCounter()
        let tracker = ComposeConnectionTracker(log: Logger(label: "test.tracker")) { finished.incrementSync() }
        let stoppedAccepting = SyncCounter()
        tracker.whenDraining { stoppedAccepting.incrementSync() }
        tracker.opened()
        tracker.opened()

        tracker.drain()
        #expect(stoppedAccepting.count == 1)
        #expect(finished.count == 0)
        tracker.closed()
        #expect(finished.count == 0)
        tracker.closed()
        #expect(finished.count == 1)
        // A late drain does not finish again.
        tracker.drain()
        #expect(finished.count == 1)
    }

    @Test
    func secondDrainFinishesWithoutWaiting() {
        let finished = SyncCounter()
        let tracker = ComposeConnectionTracker(log: Logger(label: "test.tracker")) { finished.incrementSync() }
        tracker.opened()
        tracker.drain()
        #expect(finished.count == 0)
        tracker.drain()
        #expect(finished.count == 1)
    }

    @Test
    func drainWithoutConnectionsFinishesAtOnce() {
        let finished = SyncCounter()
        let tracker = ComposeConnectionTracker(log: Logger(label: "test.tracker")) { finished.incrementSync() }
        tracker.opened()
        tracker.closed()
        #expect(finished.count == 0)
        tracker.drain()
        #expect(finished.count == 1)
    }

    @Test
    func launcherReportsAForwarderThatCannotStart() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.string) }
        let endpoint = Self.endpoint(in: directory)

        #expect(throws: (any Error).self) {
            try ComposeSocketLauncher.ensureRunning(
                endpoint: endpoint,
                executablePath: "/nonexistent/compose",
                identity: "current",
                startTimeout: .milliseconds(100)
            )
        }
    }
}

private actor Counter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

/// A count that synchronous code can bump.
private final class SyncCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func incrementSync() {
        lock.withLock { value += 1 }
    }

    var count: Int { lock.withLock { value } }
}

/// Keeps test descriptors out of processes that concurrent tests spawn, where
/// an inherited end would hold off the EOF or EPIPE a test waits for.
private func closeOnExec(_ descriptors: [Int32]) {
    for descriptor in descriptors {
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
}
