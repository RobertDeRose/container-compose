// Copyright © 2026 the container-compose authors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationExtras
import ContainerizationOS
import Darwin
import Foundation
import Logging
import SystemPackage

/// Serves the host Docker socket by bridging each connection to the guest
/// daemon with `docker system dial-stdio`.
///
/// The guest relay's stdin and stdout are pipes that this process copies to
/// and from the client socket. The runtime turns a closed stdin pipe into EOF
/// in the guest, but not a half-closed socket, and Docker clients half-close
/// hijacked streams (`exec` without `-i` does so immediately). The machine
/// boots on the first connection, not when the forwarder starts.
final class ComposeSocketForwarder: @unchecked Sendable {
    static let maxLogBytes: off_t = 1024 * 1024
    static let outputDrainTimeout: Duration = .seconds(3)

    private let endpoint: ComposeSocketEndpoint
    private let session: ComposeMachineSession
    private let log: Logger
    private let lock = NSLock()
    private var activeConnections = 0
    private var draining = false
    private var onDrain: [@Sendable () -> Void] = []
    private var onActivity: [@Sendable () -> Void] = []

    init(
        endpoint: ComposeSocketEndpoint,
        session: ComposeMachineSession,
        log: Logger
    ) {
        self.endpoint = endpoint
        self.session = session
        self.log = log
    }

    /// Runs the forwarder until it receives SIGTERM, SIGINT, or SIGHUP. The
    /// first signal stops accepting and releases the endpoint so a replacement
    /// can start, then exits once open connections finish. A second exits now.
    /// Returns immediately when another forwarder owns the endpoint.
    static func serve(endpoint: ComposeSocketEndpoint = ComposeSocketEndpoint()) async throws {
        LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
        let log = Logger(label: "container.compose.socket")
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        // Machine preparation resolves the guest working directory from ours.
        guard FileManager.default.changeCurrentDirectoryPath(homeDirectory) else {
            throw ContainerizationError(.invalidState, message: "cannot change to home directory \(homeDirectory)")
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

        let session = ComposeMachineSession {
            let manager = ComposeMachineManager(processRunner: ComposeProcessRunner())
            let snapshot = try await manager.ensureReady(log: log)
            guard let containerID = snapshot.containerId else {
                throw ContainerizationError(.invalidState, message: "Compose machine is running but has no backing container ID")
            }
            return containerID
        }
        let forwarder = ComposeSocketForwarder(endpoint: endpoint, session: session, log: log)
        let ports = ComposePortForwarder(connections: forwarder, log: log)
        forwarder.whenDraining { ports.stop() }
        forwarder.whenActive { ports.nudge() }
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
                forwarder.connectionOpened()
                Task {
                    await forwarder.forward(connection)
                    forwarder.connectionClosed()
                }
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
                forwarder.drain()
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

    func connectionOpened() {
        lock.withLock { activeConnections += 1 }
    }

    func connectionClosed() {
        let finished = lock.withLock {
            activeConnections -= 1
            return draining && activeConnections == 0
        }
        if finished {
            exitStopped()
        }
    }

    /// Registers work to stop accepting connections when draining begins.
    func whenDraining(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { onDrain.append(action) }
    }

    /// Registers work to run after a client connects, once the machine may
    /// have been booted by it or by a Compose invocation.
    func whenActive(_ action: @escaping @Sendable () -> Void) {
        lock.withLock { onActivity.append(action) }
    }

    private func reportActivity() {
        for action in lock.withLock({ onActivity }) {
            action()
        }
    }

    private func drain() {
        let (alreadyDraining, actions) = lock.withLock {
            defer { draining = true }
            return (draining, onDrain)
        }
        if alreadyDraining {
            exitStopped()
        }
        for action in actions {
            action()
        }
        // Count only after the actions stop accepting, so a connection
        // accepted while they ran is waited for.
        let connections = lock.withLock { activeConnections }
        if connections == 0 {
            exitStopped()
        }
        log.info("Waiting for open Docker connections", metadata: ["connections": "\(connections)"])
    }

    private func exitStopped() -> Never {
        log.info("Docker socket forwarder stopped")
        exit(0)
    }

    /// Bridges one client connection and takes ownership of its descriptor.
    ///
    /// A client that closes without sending anything is a probe, such as
    /// `--socket-path` checking that the forwarder runs. It must not boot the
    /// machine, so preparation waits for the first byte of a request.
    func forward(_ connection: Int32) async {
        defer { reportActivity() }
        guard await Self.awaitRequest(connection) else {
            _ = close(connection)
            return
        }
        var staleContainerID: String?
        var failure: Error?
        // A cached container ID becomes stale when the machine stops or
        // reboots. Retry once with a freshly prepared machine.
        for _ in 0..<2 {
            let containerID: String
            do {
                containerID = try await session.containerID(replacing: staleContainerID)
            } catch {
                failure = error
                break
            }
            reportActivity()
            do {
                try await Self.bridge(connection, containerID: containerID, configuration: Self.dialStdioConfiguration)
                return
            } catch {
                staleContainerID = containerID
                failure = error
            }
        }
        let reason = failure.map { "\($0)" } ?? "unknown error"
        log.error("Docker socket connection failed", metadata: ["error": "\(reason)"])
        Self.respondUnavailable(connection, message: "container compose could not reach Docker in the Compose machine: \(reason)")
        _ = close(connection)
    }

    /// Waits until the client sends data, and returns false if it closes
    /// the connection first.
    static func awaitRequest(_ connection: Int32) async -> Bool {
        await onThread {
            var byte: UInt8 = 0
            while true {
                let count = recv(connection, &byte, 1, MSG_PEEK)
                if count < 0, errno == EINTR {
                    continue
                }
                return count > 0
            }
        }
    }

    /// Starts a guest process and relays `connection` through its stdin and
    /// stdout, then closes the connection. Throws, leaving the connection
    /// open, when the process cannot be started.
    static func bridge(_ connection: Int32, containerID: String, configuration: ProcessConfiguration) async throws {
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
        await relay(connection, process: process, input: input.takeOwnedEnd(), output: output.takeOwnedEnd())
        withExtendedLifetime(client) {}
    }

    /// Copies between the client and the guest relay until both finish, then
    /// closes all three descriptors.
    private static func relay(_ connection: Int32, process: any ClientProcess, input: Int32, output: Int32) async {
        let clientToGuest = Task {
            _ = await Self.onThread { Self.pump(from: connection, to: input) }
            // EOF from the client, half-close included, becomes EOF on the
            // relay's stdin, which forwards it to the daemon.
            _ = close(input)
        }
        let guestToClient = Task {
            let end = await Self.onThread { Self.pump(from: output, to: connection) }
            switch end {
            case .endOfInput:
                _ = shutdown(connection, SHUT_WR)
            case .writeFailed, .readFailed:
                try? await process.kill(SIGTERM)
            }
        }
        // The relay outlives a vanished client while the daemon keeps a
        // quiet stream open (for example `events`), so stop it then.
        let monitor = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.disconnectPollInterval)
                // Relay awaits this task after the process exits; a kill
                // then would only wait on an acknowledgement that never comes.
                if !Task.isCancelled, Self.peerClosed(connection) {
                    try? await process.kill(SIGTERM)
                    return
                }
            }
        }
        _ = try? await process.wait()
        monitor.cancel()
        await monitor.value
        // Output written before exit is still in the pipe. Deliver it, but do
        // not let a pipe the runtime has not closed hold the client open.
        _ = try? await Timeout.run(for: Self.outputDrainTimeout) { await guestToClient.value }
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

    /// Runs blocking I/O on its own thread instead of the cooperative pool.
    static func onThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(returning: body())
            }
        }
    }

    static let disconnectPollInterval: Duration = .seconds(1)

    /// Returns whether the client has closed both directions. A client that
    /// only shut down writing (hijacked attach after stdin EOF) still reads.
    /// A Unix socket reports a full close at once; a TCP connection only
    /// after keepalive finds the peer gone (see `ComposePortListener`).
    static func peerClosed(_ connection: Int32) -> Bool {
        send(connection, "", 0, 0) < 0 && errno == EPIPE
    }

    static let dialStdioConfiguration = ProcessConfiguration(
        executable: "/usr/bin/docker",
        arguments: ["system", "dial-stdio"],
        environment: [
            "DOCKER_HOST=\(ComposeEnvironment.innerDockerHost)",
            "DOCKER_CONFIG=/root/.docker",
            "HOME=/root",
            "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        ],
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )

    /// Answers with a Docker API error so clients report the cause instead of
    /// an unexplained EOF.
    static func unavailableResponse(message: String) -> Data {
        let body = (try? JSONEncoder().encode(["message": message])) ?? Data("{}".utf8)
        let head =
            "HTTP/1.1 503 Service Unavailable\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    private static func respondUnavailable(_ connection: Int32, message: String) {
        let response = unavailableResponse(message: message)
        response.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = send(connection, base + offset, buffer.count - offset, 0)
                guard written > 0 else { return }
                offset += written
            }
        }
        // Let the client finish sending its request before the close so it
        // reads the response rather than failing its write.
        _ = shutdown(connection, SHUT_WR)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 4096)
        while recv(connection, &buffer, buffer.count, 0) > 0 {}
    }

    /// Rotates the log once it exceeds `maxLogBytes`, keeping one prior file.
    static func rotateLog(at path: FilePath) {
        var status = stat()
        guard lstat(path.string, &status) == 0, status.st_size > maxLogBytes else {
            return
        }
        _ = rename(path.string, path.string + ".1")
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

/// Identifies the forwarder executable so an upgraded plugin replaces a
/// forwarder started by an older build.
enum ComposeSocketIdentity {
    static func executablePath() -> String {
        let path = Bundle.main.executablePath ?? CommandLine.arguments[0]
        guard let resolved = realpath(path, nil) else {
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func current() -> String {
        let path = executablePath()
        var status = stat()
        guard stat(path, &status) == 0 else {
            return "\(ComposeVersion.current) \(path)"
        }
        return "\(ComposeVersion.current) \(path) \(status.st_ino) \(status.st_mtimespec.tv_sec).\(status.st_mtimespec.tv_nsec)"
    }
}

/// The single-instance lock held by a running forwarder. The file records the
/// owner's process ID and identity for `--socket-path`.
final class ComposeSocketLock: @unchecked Sendable {
    struct Owner: Equatable {
        let pid: pid_t
        let identity: String
    }

    private let descriptor: Int32
    private let lock = NSLock()
    private var released = false

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        release()
    }

    /// Returns nil when another process holds the lock.
    static func acquire(path: FilePath, identity: String) throws -> ComposeSocketLock? {
        let descriptor = open(path.string, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else {
            throw ContainerizationError(
                .internalError,
                message: "cannot open Docker socket lock \(path)",
                cause: POSIXError.fromErrno()
            )
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            _ = close(descriptor)
            if error == EWOULDBLOCK {
                return nil
            }
            throw ContainerizationError(
                .internalError,
                message: "cannot lock Docker socket lock \(path)",
                cause: POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            )
        }
        let record = Data("\(getpid())\n\(identity)\n".utf8)
        guard ftruncate(descriptor, 0) == 0,
            record.withUnsafeBytes({ pwrite(descriptor, $0.baseAddress, $0.count, 0) }) == record.count
        else {
            _ = close(descriptor)
            throw ContainerizationError(.internalError, message: "cannot record Docker socket owner in \(path)")
        }
        return ComposeSocketLock(descriptor: descriptor)
    }

    /// Returns the recorded owner while the lock is held. A released lock
    /// keeps its last record, whose process ID may since belong to an
    /// unrelated process.
    static func owner(at path: FilePath) -> Owner? {
        let descriptor = open(path.string, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            return nil
        }
        defer { _ = close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            _ = flock(descriptor, LOCK_UN)
            return nil
        }
        guard errno == EWOULDBLOCK,
            let text = try? String(contentsOfFile: path.string, encoding: .utf8)
        else {
            return nil
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2, let pid = pid_t(lines[0]), pid > 0 else {
            return nil
        }
        return Owner(pid: pid, identity: String(lines[1]))
    }

    static func acquire(path: FilePath, identity: String, waitingUpTo timeout: Duration) async throws -> ComposeSocketLock? {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let lock = try acquire(path: path, identity: identity) {
                return lock
            }
            guard ContinuousClock.now < deadline else {
                return nil
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func release() {
        lock.withLock {
            guard !released else { return }
            released = true
            _ = close(descriptor)
        }
    }
}

/// A listening Unix socket that removes only the endpoint it created.
final class ComposeSocketListener: @unchecked Sendable {
    let descriptor: Int32
    private let path: FilePath
    private let inode: ino_t
    private let lock = NSLock()
    private var closed = false

    private init(descriptor: Int32, path: FilePath, inode: ino_t) {
        self.descriptor = descriptor
        self.path = path
        self.inode = inode
    }

    /// Binds `path`, replacing only a stale socket. The caller must hold the
    /// forwarder lock so no live forwarder's socket can be removed.
    static func bind(path: FilePath) throws -> ComposeSocketListener {
        try removeStaleSocket(at: path)
        var address = try ComposeSocketEndpoint.socketAddress(for: path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError.fromErrno()
        }
        do {
            _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0 else {
                throw ContainerizationError(.internalError, message: "cannot bind Docker socket \(path)", cause: POSIXError.fromErrno())
            }
            var status = stat()
            guard lstat(path.string, &status) == 0,
                chmod(path.string, 0o600) == 0,
                listen(descriptor, SOMAXCONN) == 0,
                fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0
            else {
                throw ContainerizationError(.internalError, message: "cannot listen on Docker socket \(path)", cause: POSIXError.fromErrno())
            }
            return ComposeSocketListener(descriptor: descriptor, path: path, inode: status.st_ino)
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    static func removeStaleSocket(at path: FilePath) throws {
        var status = stat()
        guard lstat(path.string, &status) == 0 else {
            guard errno == ENOENT else {
                throw ContainerizationError(.internalError, message: "cannot inspect \(path)", cause: POSIXError.fromErrno())
            }
            return
        }
        guard (status.st_mode & S_IFMT) == S_IFSOCK else {
            throw ContainerizationError(.exists, message: "cannot publish Docker socket at \(path): path exists and is not a Unix socket")
        }
        if let descriptor = try? ComposeSocketEndpoint.connect(to: path) {
            _ = Darwin.close(descriptor)
            throw ContainerizationError(.exists, message: "cannot publish Docker socket at \(path): another process is listening on it")
        }
        guard unlink(path.string) == 0 || errno == ENOENT else {
            throw ContainerizationError(.internalError, message: "cannot remove stale Docker socket \(path)", cause: POSIXError.fromErrno())
        }
    }

    /// Accepts one pending connection as a blocking descriptor, or returns nil
    /// when none is pending.
    func accept() -> Int32? {
        Self.accept(descriptor)
    }

    /// Accepts one pending connection on a non-blocking listening socket as
    /// a blocking, close-on-exec descriptor without SIGPIPE, or returns nil
    /// when none is pending.
    static func accept(_ descriptor: Int32) -> Int32? {
        while true {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED {
                    continue
                }
                return nil
            }
            // Accepted sockets inherit O_NONBLOCK on Darwin. The guest relay
            // shares this file description and expects blocking I/O.
            _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            var enabled: Int32 = 1
            _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
            return connection
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            _ = Darwin.close(descriptor)
            var status = stat()
            if lstat(path.string, &status) == 0, status.st_ino == inode {
                _ = unlink(path.string)
            }
        }
    }
}
