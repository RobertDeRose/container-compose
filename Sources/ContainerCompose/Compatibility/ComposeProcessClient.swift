// Copyright © 2025-2026 Apple Inc. and the container project authors.
// Modifications copyright © 2026 the container-compose authors.
// SPDX-License-Identifier: Apache-2.0
// Adapted from ContainerAPIClient/ClientProcess.swift and ContainerXPC/XPCClient.swift.

import ComposeSupport
import ContainerAPIClient
import ContainerResource
import ContainerXPC
import ContainerizationError
import ContainerizationOS
import Darwin
import Foundation

/// Uses the upstream process routes, with local cancellation and FileHandle fixes.
/// It does not add a service or require a patched host daemon.
struct ComposeProcessClient: Sendable {
    private let connection = ComposeXPCConnection()

    init() {}

    func createProcess(
        containerId: String,
        processId: String,
        configuration: ProcessConfiguration,
        stdio: [FileHandle?]
    ) async throws -> any ClientProcess {
        let request = XPCMessage(route: XPCRoute.containerCreateProcess.rawValue)
        request.set(key: XPCKeys.id.rawValue, value: containerId)
        request.set(key: XPCKeys.processIdentifier.rawValue, value: processId)
        request.set(key: XPCKeys.processConfig.rawValue, value: try JSONEncoder().encode(configuration))
        let keys: [XPCKeys] = [.stdin, .stdout, .stderr]
        guard stdio.count <= keys.count else {
            throw ContainerizationError(.invalidArgument, message: "at most three stdio handles are supported")
        }
        for (index, handle) in stdio.enumerated() {
            guard let handle else { continue }
            // xpc_fd_create duplicates the descriptor. Close the FileHandle,
            // not its raw descriptor, so later cleanup cannot close a reused fd.
            guard let descriptor = xpc_fd_create(handle.fileDescriptor) else {
                throw ContainerizationError(.internalError, message: "failed to transfer process stdio")
            }
            try handle.close()
            xpc_dictionary_set_value(request.underlying, keys[index].rawValue, descriptor)
        }
        try await connection.send(request)
        return ComposeRemoteProcess(containerID: containerId, id: processId, connection: connection)
    }
}

private struct ComposeRemoteProcess: ClientProcess {
    let containerID: String
    let id: String
    let connection: ComposeXPCConnection

    private func request(_ route: XPCRoute) -> XPCMessage {
        let request = XPCMessage(route: route.rawValue)
        request.set(key: XPCKeys.id.rawValue, value: containerID)
        request.set(key: XPCKeys.processIdentifier.rawValue, value: id)
        return request
    }

    func start() async throws {
        try await connection.send(request(.containerStartProcess))
    }

    func kill(_ signal: Int32) async throws {
        let message = request(.containerKill)
        message.set(key: XPCKeys.signal.rawValue, value: Int64(signal))
        try await connection.send(message)
    }

    func resize(_ size: Terminal.Size) async throws {
        let message = request(.containerResize)
        message.set(key: XPCKeys.width.rawValue, value: UInt64(size.width))
        message.set(key: XPCKeys.height.rawValue, value: UInt64(size.height))
        try await connection.send(message)
    }

    func wait() async throws -> Int32 {
        let reply = try await connection.send(request(.containerWait), timeout: nil)
        return Int32(reply.int64(key: XPCKeys.exitCode.rawValue))
    }
}

private final class ComposeXPCConnection: Sendable {
    private nonisolated(unsafe) let connection: xpc_connection_t

    init() {
        connection = xpc_connection_create_mach_service("com.apple.container.apiserver", nil, 0)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
    }

    deinit { xpc_connection_cancel(connection) }

    @discardableResult
    func send(_ message: XPCMessage, timeout: Duration? = .seconds(60)) async throws -> XPCMessage {
        do {
            return try await AsyncReply.wait(timeout: timeout) { completion in
                xpc_connection_send_message_with_reply(self.connection, message.underlying, nil) { reply in
                    do {
                        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                            throw ContainerizationError(
                                .interrupted,
                                message: XPCMessage(object: reply).errorKeyDescription() ?? "process service disconnected"
                            )
                        }
                        let response = XPCMessage(object: reply)
                        try response.error()
                        completion(.success(response))
                    } catch {
                        completion(.failure(error))
                    }
                }
            }
        } catch is AsyncReply.TimedOut {
            throw ContainerizationError(.timeout, message: "timed out waiting for the container process service")
        }
    }
}
