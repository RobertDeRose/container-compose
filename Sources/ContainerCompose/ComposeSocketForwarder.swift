// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Darwin
import Foundation
import Logging
import SystemPackage

/// Serves the host Docker socket by bridging each connection to the guest
/// daemon with `docker system dial-stdio`. The machine boots on the first
/// request, not when the forwarder starts.
final class ComposeSocketForwarder: @unchecked Sendable {
    private let session: ComposeMachineSession
    private let connections: ComposeConnectionTracker
    private let log: Logger
    private let onActivity: @Sendable () -> Void

    /// `onActivity` runs after a client connects, once the machine may have
    /// been booted by it or by a Compose invocation.
    init(
        session: ComposeMachineSession,
        connections: ComposeConnectionTracker,
        log: Logger,
        onActivity: @escaping @Sendable () -> Void
    ) {
        self.session = session
        self.connections = connections
        self.log = log
        self.onActivity = onActivity
    }

    /// Bridges an accepted connection in the background and takes ownership
    /// of its descriptor.
    func accepted(_ connection: Int32) {
        connections.opened()
        Task {
            await forward(connection)
            connections.closed()
        }
    }

    /// Bridges one client connection and takes ownership of its descriptor.
    ///
    /// A client that closes without sending anything is a probe, such as
    /// `--socket-path` checking that the forwarder runs. It must not boot the
    /// machine, so preparation waits for the first byte of a request.
    func forward(_ connection: Int32) async {
        defer { onActivity() }
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
            onActivity()
            do {
                try await ComposeGuestBridge.bridge(connection, containerID: containerID, configuration: Self.dialStdioConfiguration, log: log)
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
        await ComposeGuestBridge.onThread {
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

    static let dialStdioConfiguration = ProcessConfiguration(
        executable: "/usr/bin/docker",
        arguments: ["system", "dial-stdio"],
        environment: ComposeEnvironment.guestDaemonEnvironmentEntries,
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
