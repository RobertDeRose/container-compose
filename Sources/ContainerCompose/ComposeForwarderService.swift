// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Darwin
import Foundation
import Logging

/// The background process started by `--socket-path`. It runs the Docker
/// socket forwarder and the published port forwarder as peers, and owns what
/// they share: the machine session, the connection count, and the
/// drain-and-exit sequence.
enum ComposeForwarderService {
    /// Runs until SIGTERM, SIGINT, or SIGHUP. The first signal stops
    /// accepting and releases the endpoint so a replacement can start, then
    /// exits once open connections finish. A second exits now. Returns
    /// immediately when another forwarder owns the endpoint.
    static func serve(endpoint: ComposeSocketEndpoint = ComposeSocketEndpoint()) async throws {
        LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
        let log = Logger(label: "container.compose.socket")
        // The daemon inherits the directory of the Compose invocation that
        // spawned it. Nothing here uses a relative path, so release it rather
        // than hold it open for the daemon's lifetime.
        guard FileManager.default.changeCurrentDirectoryPath("/") else {
            throw ContainerizationError(.invalidState, message: "cannot change to the root directory")
        }
        umask(0o077)
        signal(SIGPIPE, SIG_IGN)

        let runDirectory = endpoint.path.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: runDirectory.string,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // A forwarder being replaced releases the lock just after its socket.
        guard
            let lock = try await ComposeSocketLock.acquire(
                path: endpoint.lockPath,
                identity: ComposeSocketIdentity.current(),
                waitingUpTo: .seconds(2)
            )
        else {
            log.info("Docker socket forwarder is already running", metadata: ["socket": "\(endpoint.path)"])
            return
        }
        let listener = try ComposeSocketListener.bind(path: endpoint.path)
        log.info("Docker socket forwarder started", metadata: ["socket": "\(endpoint.path)", "pid": "\(getpid())"])

        // An XPC connection does not survive an API server restart, so each
        // preparation uses a new process runner, as each port check does.
        let session = ComposeMachineSession {
            let manager = ComposeMachineManager(processRunner: ComposeProcessRunner())
            let snapshot = try await manager.ensureReady(log: log)
            guard let containerID = snapshot.containerId else {
                throw ContainerizationError(.invalidState, message: "Compose machine is running but has no backing container ID")
            }
            return containerID
        }
        let connections = ComposeConnectionTracker(log: log) {
            log.info("Docker socket forwarder stopped")
            exit(0)
        }
        let ports = ComposePortForwarder(
            source: ComposeGuestPortSource(log: log),
            connections: connections,
            log: log
        )
        let sockets = ComposeSocketForwarder(session: session, connections: connections, log: log) {
            ports.nudge()
        }
        connections.whenDraining { ports.stop() }
        Task { await ports.run() }

        // The listener is closed by the accept source's cancel handler, as
        // dispatch requires, on a queue the signal handler can wait on.
        let acceptSource = DispatchSource.makeReadSource(
            fileDescriptor: listener.descriptor,
            queue: DispatchQueue(label: "container.compose.socket.accept")
        )
        let acceptClosed = DispatchGroup()
        acceptSource.setEventHandler {
            while let connection = listener.accept() {
                sockets.accepted(connection)
            }
        }
        acceptClosed.enter()
        acceptSource.setCancelHandler {
            listener.close()
            acceptClosed.leave()
        }
        acceptSource.resume()

        let queue = DispatchQueue(label: "container.compose.socket")
        var sources: [DispatchSourceProtocol] = [acceptSource]
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
            source.setEventHandler {
                acceptSource.cancel()
                acceptClosed.wait()
                log.info("Docker socket forwarder stopping", metadata: ["signal": "\(signalNumber)"])
                // Draining closes the port listeners before the lock is
                // released, so a replacement can bind every endpoint at once.
                connections.drain()
                lock.release()
            }
            source.resume()
            sources.append(source)
        }

        withExtendedLifetime(sources) {}
        while true {
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

/// Counts the open connections of every forwarder and runs the drain: once
/// draining starts, the forwarders stop accepting, and the service finishes
/// when the last connection closes. A second drain finishes at once.
final class ComposeConnectionTracker: @unchecked Sendable {
    private let log: Logger
    private let finish: @Sendable () -> Void
    private let lock = NSLock()
    private var activeConnections = 0
    private var draining = false
    private var finished = false
    private var onDrain: [@Sendable () -> Void] = []

    /// `finish` runs once, when the drain has nothing left to wait for.
    init(log: Logger, finish: @escaping @Sendable () -> Void) {
        self.log = log
        self.finish = finish
    }

    func opened() {
        lock.withLock { activeConnections += 1 }
    }

    func closed() {
        let last = lock.withLock {
            activeConnections -= 1
            return draining && activeConnections == 0
        }
        if last {
            finishOnce()
        }
    }

    var openConnections: Int {
        lock.withLock { activeConnections }
    }

    /// Registers work to stop accepting connections when draining begins.
    func whenDraining(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { onDrain.append(action) }
    }

    func drain() {
        let (alreadyDraining, actions) = lock.withLock {
            defer { draining = true }
            return (draining, onDrain)
        }
        if alreadyDraining {
            finishOnce()
            return
        }
        for action in actions {
            action()
        }
        // Count only after the actions stop accepting, so a connection
        // accepted while they ran is waited for.
        let connections = lock.withLock { activeConnections }
        if connections == 0 {
            finishOnce()
            return
        }
        log.info("Waiting for open Docker connections", metadata: ["connections": "\(connections)"])
    }

    private func finishOnce() {
        let first = lock.withLock {
            defer { finished = true }
            return !finished
        }
        if first {
            finish()
        }
    }
}

/// Caches the Compose machine's backing container and serializes preparation
/// so concurrent first connections boot the machine once.
actor ComposeMachineSession {
    private let prepare: @Sendable () async throws -> String
    private var containerID: String?
    private var preparation: Task<String, Error>?

    init(prepare: @escaping @Sendable () async throws -> String) {
        self.prepare = prepare
    }

    func containerID(replacing stale: String?) async throws -> String {
        if let stale, containerID == stale {
            containerID = nil
        }
        if let containerID {
            return containerID
        }
        if let preparation {
            return try await preparation.value
        }
        let task = Task { try await prepare() }
        preparation = task
        defer { preparation = nil }
        let prepared = try await task.value
        containerID = prepared
        return prepared
    }
}
