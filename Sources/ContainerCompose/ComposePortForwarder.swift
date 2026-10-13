// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerResource
import Darwin
import Foundation
import Logging

/// Mirrors TCP ports published by Docker in the Compose machine onto the
/// host's loopback addresses, as Docker Desktop does for `localhost`.
///
/// While the machine runs, its `source` watches the published ports and
/// reports whenever they change. While the machine is stopped, its state is
/// checked with growing intervals, and immediately when `nudge()` reports
/// Docker or Compose activity.
///
/// Each connection is relayed by `relayScript` in the guest, over process stdio
/// rather than the machine's network address. The host cannot always reach
/// that address (a host firewall may block the vmnet bridge), and a port
/// published on `127.0.0.1` is only reachable from inside the guest anyway.
final class ComposePortForwarder: @unchecked Sendable {
    /// The first and the longest wait between machine state checks.
    static let minimumRetryDelay: Duration = .seconds(2)
    static let maximumRetryDelay: Duration = .seconds(30)
    /// Consecutive failed checks of a machine not known to be stopped before
    /// its listeners are closed.
    static let failureLimit = 3

    /// Relays stdio to a published port, `$1` port `$2`, with one `socat`
    /// per direction sharing the connection.
    ///
    /// The runtime ends the host's output pipe only when the process exits,
    /// not when the guest closes stdout, so the relay must exit when the
    /// server closes. A single `socat` cannot: it either waits for both
    /// directions, holding a close-delimited reply open while the client
    /// keeps writing, or exits a timeout after the first EOF, cutting off the
    /// reply to a client that half-closed. Here the client-to-server copy
    /// shuts down the socket's sending side at the client's EOF, and the relay
    /// exits once the server-to-client copy reaches the server's EOF.
    /// Background commands get `/dev/null` as stdin unless redirected.
    static let relayScript = """
        exec 3<>"/dev/tcp/$1/$2" || exit 1
        socat -u STDIN FD:3,shut-down <&0 >/dev/null 2>&1 &
        writer=$!
        socat -u FD:3 STDOUT </dev/null &
        reader=$!
        exec 3>&- </dev/null
        trap 'kill $writer $reader 2>/dev/null' TERM INT HUP
        wait $reader
        kill $writer 2>/dev/null
        """

    /// Relays stdio to a published port at the guest address it was
    /// published on. The forwarder ends the relay when the client goes away.
    static func relayConfiguration(address: String, port: UInt16) -> ProcessConfiguration {
        ProcessConfiguration(
            executable: "/bin/bash",
            arguments: ["-c", relayScript, "relay", address, "\(port)"],
            environment: ComposeEnvironment.guestDaemonEnvironmentEntries,
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
    }

    /// The running machine's published ports, each with the guest address
    /// that its connections are relayed to.
    struct Route: Sendable, Equatable {
        let containerID: String
        let targets: [UInt16: String]

        var ports: Set<UInt16> { Set(targets.keys) }
    }

    enum MachineState: Sendable, Equatable {
        case running(containerID: String)
        /// Stopped, missing, or not owned by this plugin.
        case stopped
        /// The state could not be read.
        case unknown
    }

    /// How one run of the published port watcher ended.
    enum WatchOutcome: Sendable, Equatable {
        /// The watcher exited, as it does when the machine stops or the API
        /// server restarts. Only an exit after a report is a successful check.
        case exited(reported: Bool)
        /// The watcher could not be started.
        case notStarted
        /// The watcher stopped reporting, or its output ended without it
        /// exiting, and it was ended.
        case stalled
        /// Waiting for the watcher failed, so its exit is unconfirmed; it was
        /// ended as far as the runtime could be reached.
        case waitFailed
    }

    private let source: any ComposePortSource
    private let connections: ComposeConnectionTracker
    private let log: Logger
    private let minimumRetryDelay: Duration
    private let maximumRetryDelay: Duration
    private let lock = NSLock()
    private var route: Route?
    private var listeners: [UInt16: ComposePortListener] = [:]
    /// Ports that cannot be forwarded and were already logged. They are
    /// retried on every report but logged once.
    private var unavailable: Set<UInt16> = []
    private var stopped = false
    private var nudged = false
    private var sleeper: Task<Void, Never>?

    init(
        source: any ComposePortSource,
        connections: ComposeConnectionTracker,
        log: Logger,
        minimumRetryDelay: Duration = ComposePortForwarder.minimumRetryDelay,
        maximumRetryDelay: Duration = ComposePortForwarder.maximumRetryDelay
    ) {
        self.source = source
        self.connections = connections
        self.log = log
        self.minimumRetryDelay = minimumRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }

    /// The ports with an open localhost listener.
    var forwardedPorts: Set<UInt16> {
        lock.withLock { Set(listeners.keys) }
    }

    func run() async {
        var delay = minimumRetryDelay
        var failures = 0
        while !lock.withLock({ stopped }) {
            lock.withLock { nudged = false }
            switch await source.machineState() {
            case .running(let containerID):
                let started = ContinuousClock.now
                let outcome = await source.watch(containerID: containerID) { [self] targets in
                    await update(route: Route(containerID: containerID, targets: targets))
                }
                if outcome == .exited(reported: true) {
                    failures = 0
                    delay = minimumRetryDelay
                    // The watcher ends when the machine stops or the API
                    // server restarts; check again at once unless it ended
                    // suspiciously fast.
                    if ContinuousClock.now - started >= minimumRetryDelay {
                        continue
                    }
                } else {
                    // A stalled or unconfirmed watcher is not evidence that
                    // the ports are still published.
                    failures += 1
                    log.debug("Published port watcher did not end normally", metadata: ["outcome": "\(outcome)"])
                }
            case .stopped:
                failures = 0
                await update(route: nil)
            case .unknown:
                failures += 1
            }
            // A watcher that reported before failing reopened the listeners
            // without resetting the count, so close them whenever the limit
            // is reached or exceeded while a route is still set.
            if failures >= Self.failureLimit, lock.withLock({ route != nil }) {
                log.warning("Cannot read the Compose machine's published ports; closing their localhost listeners")
                await update(route: nil)
            }
            if await pause(for: delay) {
                delay = minimumRetryDelay
            } else {
                delay = min(delay * 2, maximumRetryDelay)
            }
        }
    }

    /// Asks for a prompt machine state check, for example after Docker or
    /// Compose activity that may have booted the machine.
    func nudge() {
        let sleeping = lock.withLock {
            nudged = true
            return sleeper
        }
        sleeping?.cancel()
    }

    /// Closes every listener and ends the watcher; open connections continue.
    func stop() {
        let (closing, sleeping) = lock.withLock {
            stopped = true
            defer { listeners = [:] }
            return (Array(listeners.values), sleeper)
        }
        sleeping?.cancel()
        source.stopWatching()
        for listener in closing {
            listener.close()
        }
    }

    /// Waits for `duration` or a nudge, and returns whether it was nudged.
    private func pause(for duration: Duration) async -> Bool {
        let task = Task { _ = try? await Task.sleep(for: duration) }
        let skip = lock.withLock {
            guard !nudged, !stopped else { return true }
            sleeper = task
            return false
        }
        if skip {
            task.cancel()
        }
        await task.value
        return lock.withLock {
            sleeper = nil
            return nudged
        }
    }

    private func update(route newRoute: Route?) async {
        let wanted = newRoute?.ports ?? []
        let (closing, missing) = lock.withLock {
            guard !stopped else {
                return ([ComposePortListener](), [UInt16]())
            }
            route = newRoute
            unavailable.formIntersection(wanted)
            let closing = listeners.filter { !wanted.contains($0.key) }
            for port in closing.keys {
                listeners[port] = nil
            }
            let missing = wanted.subtracting(listeners.keys).sorted()
            return (Array(closing.values), missing)
        }
        for listener in closing {
            listener.close()
            log.info("Stopped forwarding published port", metadata: ["port": "\(listener.port)"])
        }
        guard !missing.isEmpty else {
            return
        }
        let held = await hostPortsInUse()
        for port in missing {
            if held.contains(port) {
                reportUnavailable(port, reason: "another program on this Mac listens on it")
                continue
            }
            do {
                let listener = try ComposePortListener.bind(port: port) { [weak self] connection in
                    self?.accepted(connection, port: port)
                }
                let added = lock.withLock {
                    guard !stopped, listeners[port] == nil else { return false }
                    listeners[port] = listener
                    return true
                }
                if added {
                    lock.withLock { _ = unavailable.remove(port) }
                    log.info("Forwarding published port to localhost", metadata: ["port": "\(port)"])
                } else {
                    listener.close()
                }
            } catch {
                reportUnavailable(port, reason: "\(error)")
            }
        }
    }

    private func reportUnavailable(_ port: UInt16, reason: String) {
        let first = lock.withLock { unavailable.insert(port).inserted }
        if first {
            log.warning(
                "Cannot forward published port to localhost; retrying until it is free",
                metadata: ["port": "\(port)", "reason": "\(reason)"]
            )
        }
    }

    private func hostPortsInUse() async -> Set<UInt16> {
        await ComposeGuestBridge.onThread { ComposeHostPorts.loopbackPortsInUse() }
    }

    private func accepted(_ connection: Int32, port: UInt16) {
        connections.opened()
        Task {
            await forward(connection, port: port)
            connections.closed()
        }
    }

    private func forward(_ connection: Int32, port: UInt16) async {
        guard let route = lock.withLock({ route }), let address = route.targets[port] else {
            _ = close(connection)
            return
        }
        do {
            try await ComposeGuestBridge.bridge(
                connection,
                containerID: route.containerID,
                configuration: Self.relayConfiguration(address: address, port: port),
                log: log
            )
        } catch {
            log.warning("Published port connection failed", metadata: ["port": "\(port)", "error": "\(error)"])
            _ = close(connection)
        }
    }
}

/// Finds host ports that binding would take from another program, without
/// connecting to anything.
///
/// The forwarder binds with `SO_REUSEADDR`, so a restarted forwarder can
/// rebind ports with recently closed connections. On macOS that option also
/// lets a `127.0.0.1` bind succeed over another socket's wildcard bind (and a
/// wildcard bind over a `127.0.0.1` one), splitting `localhost` traffic. The
/// kernel refuses that overlap when the other socket belongs to a different
/// user, so only this user's processes need checking, and `libproc` can list
/// their sockets. The system-wide socket table (`netstat`) is filtered for
/// processes without Apple's private network-statistics entitlement.
enum ComposeHostPorts {
    struct Listener: Hashable, Sendable {
        let address: String
        let port: UInt16
    }

    /// Ports with a listener, in another process of this user, whose address
    /// includes loopback.
    static func loopbackPortsInUse() -> Set<UInt16> {
        let me = getpid()
        return Set(
            listeners(excluding: me)
                .filter { coversLoopback($0.address) }
                .map(\.port)
        )
    }

    static func coversLoopback(_ address: String) -> Bool {
        address == "0.0.0.0" || address == "::" || address == "::1"
            || address.hasPrefix("127.") || address.hasPrefix("::ffff:127.")
    }

    /// Lists listening TCP sockets of this user's processes.
    static func listeners(excluding excluded: pid_t) -> Set<Listener> {
        var result = Set<Listener>()
        for pid in userProcesses() where pid != excluded {
            for descriptor in socketDescriptors(of: pid) {
                var info = socket_fdinfo()
                let size = proc_pidfdinfo(pid, descriptor, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
                guard size == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == Int32(SOCKINFO_TCP) else {
                    continue
                }
                let tcp = info.psi.soi_proto.pri_tcp
                guard tcp.tcpsi_state == TSI_S_LISTEN else {
                    continue
                }
                let endpoint = tcp.tcpsi_ini
                let port = UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoint.insi_lport))
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if endpoint.insi_vflag & UInt8(INI_IPV6) != 0 {
                    var address = endpoint.insi_laddr.ina_6
                    inet_ntop(AF_INET6, &address, &text, socklen_t(text.count))
                } else {
                    var address = endpoint.insi_laddr.ina_46.i46a_addr4
                    inet_ntop(AF_INET, &address, &text, socklen_t(text.count))
                }
                let address = String(decoding: text.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
                result.insert(Listener(address: address, port: port))
            }
        }
        return result
    }

    private static func userProcesses() -> [pid_t] {
        let uid = getuid()
        let needed = proc_listpids(UInt32(PROC_UID_ONLY), uid, nil, 0)
        guard needed > 0 else {
            return []
        }
        // Leave room for processes started between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(needed) / MemoryLayout<pid_t>.size + 64)
        let filled = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_UID_ONLY), uid, $0.baseAddress, Int32($0.count))
        }
        return pids.prefix(max(0, Int(filled)) / MemoryLayout<pid_t>.size).filter { $0 > 0 }
    }

    private static func socketDescriptors(of pid: pid_t) -> [Int32] {
        let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard needed > 0 else {
            return []
        }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / MemoryLayout<proc_fdinfo>.size + 16)
        let filled = descriptors.withUnsafeMutableBytes {
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
        }
        return descriptors.prefix(max(0, Int(filled)) / MemoryLayout<proc_fdinfo>.size)
            .filter { $0.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) }
            .map(\.proc_fd)
    }
}

/// Listens on a port of the host's IPv4 and IPv6 loopback addresses.
///
/// macOS lets an unprivileged process bind ports below 1024 only on the
/// wildcard address. For those ports the listener binds the wildcard address
/// and closes every connection that does not come from a loopback address.
final class ComposePortListener: @unchecked Sendable {
    let port: UInt16
    private let sources: [DispatchSourceRead]
    /// Left by each source's cancel handler once its socket is closed.
    private let cancelled: DispatchGroup
    private let lock = NSLock()
    private var closed = false

    private init(port: UInt16, sources: [DispatchSourceRead], cancelled: DispatchGroup) {
        self.port = port
        self.sources = sources
        self.cancelled = cancelled
    }

    /// Binds 127.0.0.1 and, when available, ::1. Fails if 127.0.0.1 is taken.
    static func bind(port: UInt16, onAccept: @escaping @Sendable (Int32) -> Void) throws -> ComposePortListener {
        var wildcard = false
        let ipv4: Int32
        do {
            ipv4 = try listen(family: AF_INET, port: port, wildcard: false)
        } catch let error as POSIXError where error.code == .EACCES && port < 1024 {
            wildcard = true
            ipv4 = try listen(family: AF_INET, port: port, wildcard: true)
        }
        var descriptors = [ipv4]
        do {
            descriptors.append(try listen(family: AF_INET6, port: port, wildcard: wildcard))
        } catch let error as POSIXError where error.code == .EADDRNOTAVAIL || error.code == .EAFNOSUPPORT {
            // No IPv6 loopback; IPv4 alone serves `localhost`.
        } catch {
            // Another program on ::1 would receive some `localhost` clients.
            _ = Darwin.close(ipv4)
            throw error
        }
        let loopbackOnly = wildcard
        let queue = DispatchQueue(label: "container.compose.port.\(port)")
        let cancelled = DispatchGroup()
        let sources = descriptors.map { descriptor in
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler {
                while let connection = accept(descriptor) {
                    guard !loopbackOnly || isLoopbackPeer(connection) else {
                        _ = Darwin.close(connection)
                        continue
                    }
                    onAccept(connection)
                }
            }
            cancelled.enter()
            source.setCancelHandler {
                _ = Darwin.close(descriptor)
                cancelled.leave()
            }
            source.resume()
            return source
        }
        return ComposePortListener(port: port, sources: sources, cancelled: cancelled)
    }

    /// Stops listening and returns once the sockets are closed, so the port
    /// can be bound again immediately. Never call it from the accept queue.
    func close() {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        for source in sources {
            source.cancel()
        }
        cancelled.wait()
    }

    static func isLoopbackPeer(_ connection: Int32) -> Bool {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(connection, $0, &length) }
        }
        guard result == 0 else {
            return false
        }
        switch Int32(storage.ss_family) {
        case AF_INET:
            let address = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            }
            // 127.0.0.0/8
            return UInt32(bigEndian: address) >> 24 == 127
        case AF_INET6:
            var address = withUnsafePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            }
            var loopback = in6addr_loopback
            if memcmp(&address, &loopback, MemoryLayout<in6_addr>.size) == 0 {
                return true
            }
            // ::ffff:127.0.0.0/104
            return withUnsafeBytes(of: &address) { bytes in
                bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff && bytes[12] == 127
            }
        default:
            return false
        }
    }

    private static func listen(family: Int32, port: UInt16, wildcard: Bool) throws -> Int32 {
        let descriptor = socket(family, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError.fromErrno()
        }
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        let bound: Int32
        if family == AF_INET6 {
            _ = setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = port.bigEndian
            address.sin6_addr = wildcard ? in6addr_any : in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = port.bigEndian
            address.sin_addr.s_addr = (wildcard ? in_addr_t(0) : in_addr_t(INADDR_LOOPBACK)).bigEndian
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard bound == 0,
            Darwin.listen(descriptor, SOMAXCONN) == 0,
            fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0
        else {
            let error = POSIXError.fromErrno()
            _ = Darwin.close(descriptor)
            throw error
        }
        return descriptor
    }

    static let keepaliveIdleSeconds: Int32 = 10

    /// Accepts one pending connection as a blocking descriptor with TCP
    /// keepalive, or returns nil when none is pending.
    static func accept(_ descriptor: Int32) -> Int32? {
        guard let connection = ComposeSocketListener.accept(descriptor) else {
            return nil
        }
        let size = socklen_t(MemoryLayout<Int32>.size)
        var enabled: Int32 = 1
        _ = setsockopt(connection, IPPROTO_TCP, TCP_NODELAY, &enabled, size)
        // A closed TCP client only sends FIN, which a half-close also sends,
        // so the relay cannot tell them apart. Keepalive can: the closed
        // client's socket expires after the FIN_WAIT_2 timeout (a minute), the
        // next probe is reset, and sends fail with EPIPE, which `peerClosed`
        // detects. A half-closed client still answers probes.
        _ = setsockopt(connection, SOL_SOCKET, SO_KEEPALIVE, &enabled, size)
        var idle = Self.keepaliveIdleSeconds
        _ = setsockopt(connection, IPPROTO_TCP, TCP_KEEPALIVE, &idle, size)
        var interval: Int32 = 5
        _ = setsockopt(connection, IPPROTO_TCP, TCP_KEEPINTVL, &interval, size)
        var count: Int32 = 3
        _ = setsockopt(connection, IPPROTO_TCP, TCP_KEEPCNT, &count, size)
        return connection
    }
}
