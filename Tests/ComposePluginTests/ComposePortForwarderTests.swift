// Copyright © 2026 the container-compose authors.
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import Testing

@testable import ContainerCompose

@Suite("Published port forwarder")
struct ComposePortForwarderTests {
    @Test
    func routeMergesAddressFamiliesAndIgnoresNoise() {
        let output = """
            127.0.0.1 4000
            ::1 4000
            0.0.0.0 8080
            :: 8080
            127.0.0.1 80
            not-a-port
            127.0.0.1 0

            """
        let route = ComposePortForwarder.route(containerID: "machine", scriptOutput: output)
        #expect(route == .init(containerID: "machine", ports: [80, 4000, 8080]))
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
    func relayTargetsTheGuestLoopback() {
        let configuration = ComposePortForwarder.relayConfiguration(port: 4000)
        #expect(configuration.executable == "/usr/bin/socat")
        #expect(configuration.arguments.suffix(2) == ["STDIO", "TCP:127.0.0.1:4000"])
        #expect(!configuration.terminal)
    }

    /// Runs the relay's exact arguments with a host socat when one exists.
    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: hostSocat)))
    func relayForwardsDataAndKeepsReadingAfterHalfClose() async throws {
        let server = try TCPServer()
        defer { server.close() }
        // Echo everything, then answer once the client half-closes.
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
            try? await Task.sleep(for: .seconds(1))
            let reply = Data("echo:".utf8) + received
            _ = reply.withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        }

        let configuration = ComposePortForwarder.relayConfiguration(port: server.port)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.hostSocat)
        process.arguments = configuration.arguments
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("hello".utf8))
        try input.fileHandleForWriting.close()
        let reply = try output.fileHandleForReading.readToEnd()
        process.waitUntilExit()
        await echo.value

        #expect(reply == Data("echo:hello".utf8))
        #expect(process.terminationStatus == 0)
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
