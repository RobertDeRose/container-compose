// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import ContainerizationOS
import Darwin
import Foundation
import SystemPackage

/// Host locations used by the Docker socket forwarder.
struct ComposeSocketEndpoint: Sendable, Equatable {
    let path: FilePath
    let lockPath: FilePath
    let logPath: FilePath

    init(homeDirectory: FilePath) {
        let runDirectory = homeDirectory.appending(".local").appending("run")
        self.path = runDirectory.appending("docker.socket")
        self.lockPath = runDirectory.appending("docker.socket.lock")
        self.logPath =
            homeDirectory
            .appending("Library")
            .appending("Logs")
            .appending("container-compose")
            .appending("docker-socket.log")
    }

    init() {
        self.init(homeDirectory: FilePath(FileManager.default.homeDirectoryForCurrentUser.path))
    }

    var dockerHost: String {
        "unix://\(path.string)"
    }

    /// Returns whether a listener currently accepts connections at `path`.
    func isAccepting() -> Bool {
        guard let descriptor = try? Self.connect(to: path) else {
            return false
        }
        _ = close(descriptor)
        return true
    }

    /// Connects without sending a request, which a running forwarder treats
    /// as a probe: it checks the machine's published ports again, and does
    /// not boot the machine.
    func notifyForwarder() {
        _ = isAccepting()
    }

    static func connect(to path: FilePath) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError.fromErrno()
        }
        do {
            var address = try socketAddress(for: path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw POSIXError.fromErrno()
            }
            return descriptor
        } catch {
            _ = close(descriptor)
            throw error
        }
    }

    static func socketAddress(for path: FilePath) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.string.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Docker socket path is longer than \(capacity - 1) bytes: \(path)"
            )
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
        }
        return address
    }
}
