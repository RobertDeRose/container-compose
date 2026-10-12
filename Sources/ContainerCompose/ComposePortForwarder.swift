// Copyright © 2026 the container-compose authors.
// SPDX-License-Identifier: Apache-2.0

import ComposeSupport
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import ContainerizationOS
import Darwin
import Foundation
import Logging
import MachineAPIClient

/// Mirrors TCP ports published by Docker in the Compose machine onto the
/// host's loopback addresses, as Docker Desktop does for `localhost`.
///
/// Published ports are read from the guest's `docker-proxy` processes rather
/// than the Docker API, so polling neither opens a Docker client connection
/// (which idle shutdown counts as activity) nor boots a stopped machine.
///
/// Each connection is relayed by `socat` in the guest, over process stdio
/// rather than the machine's network address. The host cannot always reach
/// that address (a host firewall may block the vmnet bridge), and a port
/// published on `127.0.0.1` is only reachable from inside the guest anyway.
final class ComposePortForwarder: @unchecked Sendable {
    static let pollInterval: Duration = .seconds(2)

    /// Lists `address port` for each TCP `docker-proxy`.
    static let publishedPortsScript = """
        for f in /proc/[0-9]*/cmdline; do
            set -- $(tr '\\000' ' ' < "$f" 2>/dev/null)
            case "${1:-}" in */docker-proxy|docker-proxy) ;; *) continue ;; esac
            proto= address= port=
            while [ $# -ge 2 ]; do
                case "$1" in
                    -proto) proto=$2 ;;
                    -host-ip) address=$2 ;;
                    -host-port) port=$2 ;;
                esac
                shift
            done
            [ "$proto" = tcp ] && [ -n "$port" ] && echo "$address $port"
        done
        exit 0
        """

    /// Relays stdio to a port on the guest's loopback. Every published port
    /// listens there, whichever host address it was bound to. `-t` keeps the
    /// relay open after the client half-closes so the reply still arrives;
    /// the forwarder ends it when the client goes away.
    static func relayConfiguration(port: UInt16) -> ProcessConfiguration {
        ProcessConfiguration(
            executable: "/usr/bin/socat",
            arguments: ["-t", "86400", "STDIO", "TCP:127.0.0.1:\(port)"],
            environment: ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
            workingDirectory: "/",
            terminal: false,
            user: .id(uid: 0, gid: 0)
        )
    }

    /// The running machine's published ports.
    struct Route: Sendable, Equatable {
        let containerID: String
        let ports: Set<UInt16>
    }

    private let connections: ComposeSocketForwarder
    private let log: Logger
    private let lock = NSLock()
    private var route: Route?
    private var listeners: [UInt16: ComposePortListener] = [:]
    /// Ports that cannot be forwarded and were already logged. They are
    /// retried on every poll but logged once.
    private var unavailable: Set<UInt16> = []
    private var stopped = false

    init(connections: ComposeSocketForwarder, log: Logger) {
        self.connections = connections
        self.log = log
    }

    func run() async {
        while !lock.withLock({ stopped }) {
            await update(route: await Self.currentRoute())
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    /// Closes every listener; open connections continue.
    func stop() {
        let closing = lock.withLock {
            stopped = true
            defer { listeners = [:] }
            return Array(listeners.values)
        }
        for listener in closing {
            listener.close()
        }
    }

    /// Returns nil unless this plugin's machine is running.
    static func currentRoute() async -> Route? {
        do {
            let health = try await ClientHealthCheck.ping()
            let snapshot = try await MachineClient().inspect(id: ComposeMachineManager.machineID)
            guard snapshot.status == .running, let containerID = snapshot.containerId,
                let record = try OwnershipStore(appRoot: health.appRoot).load()
            else {
                return nil
            }
            try ComposeMachineOwnership.validate(snapshot, record: record)
            let result = try await ComposeProcessRunner().capture(
                snapshot: snapshot,
                executable: "/bin/sh",
                arguments: ["-c", publishedPortsScript],
                environment: [:],
                workingDirectory: "/"
            )
            guard result.exitCode == 0 else {
                return nil
            }
            return route(containerID: containerID, scriptOutput: result.output)
        } catch {
            return nil
        }
    }

    /// Parses the output of `publishedPortsScript`, merging the IPv4 and IPv6
    /// bindings of a port.
    static func route(containerID: String, scriptOutput: String) -> Route {
        var ports = Set<UInt16>()
        for line in scriptOutput.split(separator: "\n") {
            guard let field = line.split(separator: " ").last, let port = UInt16(field), port > 0 else {
                continue
            }
            ports.insert(port)
        }
        return Route(containerID: containerID, ports: ports)
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
        await ComposeSocketForwarder.onThread { ComposeHostPorts.loopbackPortsInUse() }
    }

    private func accepted(_ connection: Int32, port: UInt16) {
        connections.connectionOpened()
        Task {
            await forward(connection, port: port)
            connections.connectionClosed()
        }
    }

    private func forward(_ connection: Int32, port: UInt16) async {
        guard let route = lock.withLock({ route }), route.ports.contains(port) else {
            _ = close(connection)
            return
        }
        do {
            try await ComposeSocketForwarder.bridge(
                connection,
                containerID: route.containerID,
                configuration: Self.relayConfiguration(port: port)
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
    private let descriptors: [Int32]
    private let sources: [DispatchSourceRead]
    private let lock = NSLock()
    private var closed = false

    private init(port: UInt16, descriptors: [Int32], sources: [DispatchSourceRead]) {
        self.port = port
        self.descriptors = descriptors
        self.sources = sources
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
            source.setCancelHandler { _ = Darwin.close(descriptor) }
            source.resume()
            return source
        }
        return ComposePortListener(port: port, descriptors: descriptors, sources: sources)
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            for source in sources {
                source.cancel()
            }
        }
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

    /// Accepts one pending connection as a blocking descriptor, or returns nil
    /// when none is pending.
    private static func accept(_ descriptor: Int32) -> Int32? {
        while true {
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED {
                    continue
                }
                return nil
            }
            configure(connection)
            return connection
        }
    }

    private static func configure(_ connection: Int32) {
        _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
        _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
        var enabled: Int32 = 1
        _ = setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(connection, IPPROTO_TCP, TCP_NODELAY, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }
}
