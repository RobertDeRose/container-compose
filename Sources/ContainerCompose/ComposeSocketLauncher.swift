// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import ContainerizationOS
import Darwin
import Foundation
import SystemPackage

/// Starts the Docker socket forwarder for `--socket-path` without contacting
/// the container services, so it is cheap enough to run from a shell profile.
enum ComposeSocketLauncher {
    static let serveArgument = "--serve-socket"
    static let maxLogBytes: off_t = 1024 * 1024

    /// Ensures a forwarder from this executable accepts connections at the
    /// endpoint, replacing one started by a different build.
    static func ensureRunning(
        endpoint: ComposeSocketEndpoint = ComposeSocketEndpoint(),
        executablePath: String = ComposeSocketIdentity.executablePath(),
        identity: String = ComposeSocketIdentity.current(),
        startTimeout: Duration = .seconds(5)
    ) throws {
        if endpoint.isAccepting() {
            // An endpoint without an owner record belongs to something else;
            // leave it alone and let Docker clients use it.
            guard let owner = ComposeSocketLock.owner(at: endpoint.lockPath), owner.identity != identity else {
                return
            }
            // The old forwarder releases the endpoint at once and finishes its
            // open connections in the background.
            stop(owner: owner, endpoint: endpoint, timeout: .seconds(3))
        }

        let pid = try spawn(executablePath: executablePath, endpoint: endpoint)
        let deadline = ContinuousClock.now + startTimeout
        while ContinuousClock.now < deadline {
            if endpoint.isAccepting() {
                return
            }
            // A forwarder that exits early has failed, or found another one
            // starting; reap it and stop waiting once no listener appears.
            var status: Int32 = 0
            if waitpid(pid, &status, WNOHANG) == pid {
                if endpoint.isAccepting() {
                    return
                }
                break
            }
            usleep(20_000)
        }
        throw ContainerizationError(
            .timeout,
            message: "Docker socket forwarder did not start; see \(endpoint.logPath)"
        )
    }

    private static func stop(owner: ComposeSocketLock.Owner, endpoint: ComposeSocketEndpoint, timeout: Duration) {
        guard kill(owner.pid, SIGTERM) == 0 else {
            return
        }
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !endpoint.isAccepting() || (kill(owner.pid, 0) != 0 && errno == ESRCH) {
                return
            }
            usleep(20_000)
        }
    }

    /// Rotates the log once it exceeds `maxLogBytes`, keeping one prior file.
    static func rotateLog(at path: FilePath) {
        var status = stat()
        guard lstat(path.string, &status) == 0, status.st_size > maxLogBytes else {
            return
        }
        _ = rename(path.string, path.string + ".1")
    }

    /// Starts a detached forwarder in its own session with its output in the
    /// forwarder log, and returns its process ID.
    static func spawn(executablePath: String, endpoint: ComposeSocketEndpoint) throws -> pid_t {
        let logDirectory = endpoint.logPath.removingLastComponent()
        try FileManager.default.createDirectory(
            atPath: logDirectory.string,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        rotateLog(at: endpoint.logPath)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions,
            STDOUT_FILENO,
            endpoint.logPath.string,
            O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW,
            0o600
        )
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)
        // Detach from the shell's session and inherit only the stdio above.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)
        )

        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup(executablePath), strdup(serveArgument)]
        defer {
            for argument in arguments {
                free(argument)
            }
        }
        var argv = arguments + [nil]
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executablePath, &actions, &attributes, &argv, environ)
        guard result == 0 else {
            throw ContainerizationError(
                .internalError,
                message: "failed to start Docker socket forwarder \(executablePath)",
                cause: POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
            )
        }
        return pid
    }
}
