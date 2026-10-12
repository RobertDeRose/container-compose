// Copyright © 2026 the container-compose authors.
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing

@testable import ContainerCompose

/// Serialized: these tests bind real ports, and one test's ephemeral port
/// can be a port another test just closed and expects to stay closed.
@Suite("Published port forwarder", .serialized)
struct ComposePortForwarderTests {
    @Test
    func reportParsingKeepsEachPortsAddress() {
        let report = "ports 0.0.0.0/80 ::/80 127.0.0.1/4000 ::1/5000 192.168.64.2/8080 0.0.0.0/0 x/70000 junk "
        #expect(
            ComposePortForwarder.targets(fromReport: report)
                == [80: "127.0.0.1", 4000: "127.0.0.1", 5000: "::1", 8080: "192.168.64.2"]
        )
        #expect(ComposePortForwarder.targets(fromReport: "ports ") == [:])
        #expect(ComposePortForwarder.targets(fromReport: "sh: tr: not found") == nil)
    }

    @Test(arguments: [
        (["::"], "::1"),
        (["::1", "127.0.0.1"], "127.0.0.1"),
        (["192.168.64.2", "::1"], "::1"),
        (["192.168.64.2", "10.0.0.5"], "10.0.0.5"),
        (["127.0.0.2"], "127.0.0.2"),
    ])
    func targetPrefersWildcardThenLoopback(addresses: [String], target: String) {
        #expect(ComposePortForwarder.target(for: addresses) == target)
    }

    @Test
    func watchScriptIsValidShell() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-n", "-c", ComposePortForwarder.watchScript]
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
    }

    @Test
    func linesSplitsInputAndClosesAtEndOfInput() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        let lines = ComposePortForwarder.lines(from: descriptors[0], timeout: .seconds(10))
        let text = "ports 80\npor"
        _ = text.withCString { write(descriptors[1], $0, strlen($0)) }
        _ = "ts 443\npartial".withCString { write(descriptors[1], $0, strlen($0)) }
        close(descriptors[1])
        var received: [String] = []
        for await line in lines {
            received.append(line)
        }
        #expect(received == ["ports 80", "ports 443"])
    }

    @Test
    func linesEndsWhenInputStalls() async throws {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        defer { close(descriptors[1]) }
        let lines = ComposePortForwarder.lines(from: descriptors[0], timeout: .seconds(1))
        let started = ContinuousClock.now
        var received = 0
        for await _ in lines {
            received += 1
        }
        #expect(received == 0)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test
    func acceptedConnectionsUseKeepalive() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        try withUnsafeMutablePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try #require(bind(listener, $0, length) == 0)
                try #require(listen(listener, 1) == 0)
                try #require(getsockname(listener, $0, &length) == 0)
            }
        }
        let client = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, length) }
        }
        try #require(connected == 0)
        let connection = try #require(ComposePortListener.accept(listener))
        defer { close(connection) }

        func option(_ level: Int32, _ name: Int32) -> Int32 {
            var value: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(connection, level, name, &value, &size)
            return value
        }
        #expect(option(SOL_SOCKET, SO_KEEPALIVE) != 0)
        #expect(option(IPPROTO_TCP, TCP_KEEPALIVE) == ComposePortListener.keepaliveIdleSeconds)
        #expect(option(IPPROTO_TCP, TCP_NODELAY) != 0)
    }

    @Test(arguments: [
        ("0.0.0.0", true), ("::", true), ("127.0.0.1", true), ("127.0.0.2", true), ("::1", true),
        ("::ffff:127.0.0.1", true), ("192.168.1.10", false), ("fe80::1", false),
    ])
    func loopbackCoverage(address: String, covers: Bool) {
        #expect(ComposeHostPorts.coversLoopback(address) == covers)
    }

    /// The listener is opened by a child process: the forwarder ignores its
    /// own sockets, and a real conflict comes from another program.
    @Test
    func anotherProcessesWildcardListenerIsSeenWithoutConnecting() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        child.arguments = [
            "-c",
            "import socket,sys; s=socket.socket(); s.bind(('0.0.0.0',0)); s.listen(1); print(s.getsockname()[1], flush=True); sys.stdin.read()",
        ]
        let stdin = Pipe()
        let stdout = Pipe()
        child.standardInput = stdin
        child.standardOutput = stdout
        try child.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            child.waitUntilExit()
        }
        var line = Data()
        while let byte = try stdout.fileHandleForReading.read(upToCount: 1), !byte.isEmpty, byte != Data("\n".utf8) {
            line.append(byte)
        }
        let port = try #require(UInt16(String(decoding: line, as: UTF8.self)))

        #expect(ComposeHostPorts.listeners(excluding: getpid()).contains(.init(address: "0.0.0.0", port: port)))
        #expect(ComposeHostPorts.loopbackPortsInUse().contains(port))
    }

    @Test
    func bindFailsWhenAnotherProgramHoldsTheIPv6Loopback() throws {
        var other: Int32 = -1
        var port: UInt16 = 0
        // Find a port whose ::1 address another socket can hold.
        for _ in 0..<5 where other < 0 {
            let candidate = try TCPServer.freePort()
            let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
            var enabled: Int32 = 1
            setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, socklen_t(MemoryLayout<Int32>.size))
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = candidate.bigEndian
            address.sin6_addr = in6addr_loopback
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
            if bound == 0, listen(descriptor, 1) == 0 {
                other = descriptor
                port = candidate
            } else {
                Darwin.close(descriptor)
            }
        }
        try #require(other >= 0)
        defer { Darwin.close(other) }

        #expect(throws: (any Error).self) {
            _ = try ComposePortListener.bind(port: port) { Darwin.close($0) }
        }
        // The IPv4 half was released, not left bound. Pass a PID that is
        // never ours so this process's own sockets are listed.
        #expect(!ComposeHostPorts.listeners(excluding: -1).contains(.init(address: "127.0.0.1", port: port)))
    }

    @Test
    func relayTargetsThePublishedAddress() {
        let configuration = ComposePortForwarder.relayConfiguration(address: "::1", port: 4000)
        #expect(configuration.executable == "/bin/bash")
        #expect(configuration.arguments == ["-c", ComposePortForwarder.relayScript, "relay", "::1", "4000"])
        #expect(!configuration.terminal)
    }

    /// Runs the relay script with the host's bash and a host socat.
    private static func runRelay(port: UInt16, input: Data, halfClose: Bool) async throws -> (Data?, Bool) {
        let configuration = ComposePortForwarder.relayConfiguration(address: "127.0.0.1", port: port)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = Array(configuration.arguments)
        process.environment = ["PATH": "\(URL(fileURLWithPath: hostSocat).deletingLastPathComponent().path):/usr/bin:/bin"]
        let stdin = Pipe()
        let stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        try process.run()
        defer {
            try? stdin.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        try stdin.fileHandleForWriting.write(contentsOf: input)
        if halfClose {
            try stdin.fileHandleForWriting.close()
        }
        let reading = Task { await ComposeSocketForwarder.onThread { try? stdout.fileHandleForReading.readToEnd() } }
        let finished = await ComposeSocketForwarder.completes(Task { _ = await reading.value }, within: .seconds(5))
        let output = finished ? await reading.value : nil
        // The relay exits on its own once the server's side ends.
        for _ in 0..<50 where process.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        let exited = !process.isRunning
        if !exited {
            process.terminate()
        }
        return (output, exited)
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: hostSocat)))
    func relayKeepsReadingAfterTheClientHalfCloses() async throws {
        let server = try TCPServer()
        defer { server.close() }
        // Answer once the client half-closes.
        let echo = Task.detached {
            let connection = server.acceptOne()
            defer { Darwin.close(connection) }
            var buffer = [UInt8](repeating: 0, count: 4096)
            var received = Data()
            while true {
                let count = read(connection, &buffer, buffer.count)
                guard count > 0 else { break }
                received.append(contentsOf: buffer[0..<count])
            }
            try? await Task.sleep(for: .milliseconds(500))
            let reply = Data("echo:".utf8) + received
            _ = reply.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        }
        let (output, exited) = try await Self.runRelay(port: server.port, input: Data("hello".utf8), halfClose: true)
        await echo.value
        #expect(output == Data("echo:hello".utf8))
        #expect(exited)
    }

    /// A close-delimited reply must end, and the relay exit, while the
    /// client still has its writing side open.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: hostSocat)))
    func relayEndsWhenTheServerCloses() async throws {
        let server = try TCPServer()
        defer { server.close() }
        let reply = Task.detached {
            let connection = server.acceptOne()
            var buffer = [UInt8](repeating: 0, count: 64)
            _ = read(connection, &buffer, buffer.count)
            _ = "HTTP/1.0 200 OK\r\n\r\nbody".withCString { write(connection, $0, strlen($0)) }
            Darwin.close(connection)
        }
        let (output, exited) = try await Self.runRelay(
            port: server.port,
            input: Data("GET / HTTP/1.0\r\n\r\n".utf8),
            halfClose: false
        )
        await reply.value
        #expect(output == Data("HTTP/1.0 200 OK\r\n\r\nbody".utf8))
        #expect(exited)
    }

    static let hostSocat = "/opt/homebrew/bin/socat"

    @Test
    func listenerServesBothLoopbackAddresses() async throws {
        let accepted = AcceptedPeers()
        // Parallel tests can take a probed port before it is bound; retry.
        var bound: (UInt16, ComposePortListener)?
        for _ in 0..<5 where bound == nil {
            let candidate = try TCPServer.freePort()
            if let listener = try? ComposePortListener.bind(
                port: candidate,
                onAccept: { connection in
                    accepted.record(ComposePortListener.isLoopbackPeer(connection))
                    Darwin.close(connection)
                })
            {
                bound = (candidate, listener)
            }
        }
        let (port, listener) = try #require(bound)
        defer { listener.close() }

        for address in ["127.0.0.1", "::1"] {
            let client = try TCPServer.connect(address: address, port: port)
            Darwin.close(client)
        }
        for _ in 0..<100 where accepted.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(accepted.values == [true, true])

        listener.close()
        #expect(throws: (any Error).self) {
            Darwin.close(try TCPServer.connect(address: "127.0.0.1", port: port))
        }
    }
}

private final class AcceptedPeers: @unchecked Sendable {
    private let lock = NSLock()
    private var peers: [Bool] = []

    func record(_ loopback: Bool) {
        lock.withLock { peers.append(loopback) }
    }

    var count: Int { lock.withLock { peers.count } }
    var values: [Bool] { lock.withLock { peers } }
}

/// A blocking IPv4 loopback listener on an ephemeral port.
private struct TCPServer: Sendable {
    let descriptor: Int32
    let port: UInt16

    init(port requested: UInt16 = 0) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = requested.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let fd = descriptor
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(descriptor, 4) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    static func freePort() throws -> UInt16 {
        let server = try TCPServer()
        server.close()
        return server.port
    }

    func acceptOne() -> Int32 {
        accept(descriptor, nil, nil)
    }

    func close() {
        Darwin.close(descriptor)
    }

    static func connect(address: String, port: UInt16) throws -> Int32 {
        if address.contains(":") {
            var target = sockaddr_in6()
            target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            target.sin6_family = sa_family_t(AF_INET6)
            target.sin6_port = port.bigEndian
            inet_pton(AF_INET6, address, &target.sin6_addr)
            let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
            let result = withUnsafePointer(to: &target) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
            guard result == 0 else {
                Darwin.close(descriptor)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            return descriptor
        }
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = port.bigEndian
        inet_pton(AF_INET, address, &target.sin_addr)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        let result = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return descriptor
    }
}
