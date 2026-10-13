// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Foundation
import SystemPackage

/// Host-to-machine path and environment policy for the Compose process.
enum ComposeEnvironment {
    static let innerDockerHost = "unix:///etc/docker/docker.sock"
    private static let linuxPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

    /// The environment of guest processes that serve the plugin rather than
    /// a user command: daemon readiness probes, the socket relay, and the
    /// port watcher. It does not depend on the host process that starts them.
    static let guestDaemonEnvironment: [String: String] = [
        "DOCKER_HOST": innerDockerHost,
        "DOCKER_CONFIG": "/root/.docker",
        "HOME": "/root",
        "PATH": linuxPath,
    ]

    /// `guestDaemonEnvironment` as the `KEY=value` entries of a process
    /// configuration.
    static let guestDaemonEnvironmentEntries = guestDaemonEnvironment.map { "\($0.key)=\($0.value)" }.sorted()

    static func workingDirectory(
        currentDirectory: FilePath,
        homeDirectory: FilePath
    ) throws -> String {
        let home = homeDirectory.lexicallyNormalized()
        let current = currentDirectory.lexicallyNormalized()
        guard current == home || current.starts(with: home) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Compose working directory \(current) is outside the mounted host home \(home)"
            )
        }
        return current.string
    }

    static func make(
        hostEnvironment: [String: String],
        homeDirectory: FilePath,
        workingDirectory: FilePath
    ) throws -> [String: String] {
        let cwd = try self.workingDirectory(
            currentDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )

        var environment = hostEnvironment
        for key in [
            "DOCKER_HOST",
            "DOCKER_CONTEXT",
            "DOCKER_TLS_VERIFY",
            "DOCKER_CERT_PATH",
            "DOCKER_CONFIG",
            "SSH_AUTH_SOCK",
            "GIT_SSH_COMMAND",
            "HOME",
            "PATH",
            "PWD",
            "OLDPWD",
            "TMPDIR",
            "TMP",
            "TEMP",
        ] {
            environment.removeValue(forKey: key)
        }

        environment["DOCKER_HOST"] = Self.innerDockerHost
        // Do not reuse a host Docker config that names macOS-only credential
        // helpers. Users can authenticate explicitly inside the machine, or
        // supply DOCKER_AUTH_CONFIG for non-interactive registry access.
        environment["DOCKER_CONFIG"] = "/root/.docker"
        environment["HOME"] = homeDirectory.lexicallyNormalized().string
        // The machine container deliberately runs Compose as root so the
        // nested daemon can manage its own containers. Do not pass the host
        // SSH agent into that rootful trust domain.
        environment.removeValue(forKey: "GIT_SSH_COMMAND")
        environment["PATH"] = Self.linuxPath
        environment["PWD"] = cwd
        environment["TMPDIR"] = "/tmp"
        environment["TMP"] = "/tmp"
        environment["TEMP"] = "/tmp"

        return environment
    }
}
