//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
// Modified for the external container-compose plugin; see NOTICE.md.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import ArgumentParser
import ContainerAPIClient
import ContainerPersistence
import ContainerizationError
import Foundation
import Logging
import SystemPackage

public struct ComposeCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "compose",
        abstract: "Run Docker Compose inside a persistent container machine",
        usage: "container compose [--completions <bash|zsh|fish> | --install-path | --socket-path | <subcommand> ...]",
        discussion: """
            Compose arguments are forwarded to the Docker Compose CLI inside the
            shared machine. The machine remains running after `compose down`.

            EXAMPLES:
              container compose up -d
              container compose -f compose.yaml config
              container compose exec api sh
              container compose version
              container machine stop compose
              export DOCKER_HOST="$(container compose --socket-path)"
            """,
        version: ComposeVersion.current
    )

    @Option(
        name: .long,
        help: ArgumentHelp(
            "Print a completion script for bash, zsh, or fish; cannot be combined with Compose arguments or --socket-path",
            valueName: "bash|zsh|fish"
        ),
        completion: .list(ComposeCompletionShell.allCases.map(\.rawValue))
    )
    var completions: ComposeCompletionShell? = nil

    @Flag(
        name: .long,
        help: "Print the host Docker endpoint, starting its forwarder if needed; cannot be combined with --completions or Compose arguments"
    )
    var socketPath = false

    // Started by --socket-path; runs the forwarder in the foreground.
    @Flag(name: .customLong("serve-socket"), help: .hidden)
    var serveSocket = false

    @Flag(name: .long, help: "Print the external plugin installation directory for the running container host")
    var installPath = false

    // Once capture starts, options belong to Compose or its guest command.
    // Do not inspect or reinterpret them as plugin options.
    @Argument(
        parsing: .captureForPassthrough,
        help: ArgumentHelp("Docker Compose subcommand and arguments", valueName: "subcommand")
    )
    var arguments: [String] = []

    public init() {}

    public func run() async throws {
        try await run(compose: Self.runCompose)
    }

    func run(
        compose: ([String]) async throws -> Int32,
        publishSocket: () throws -> String = Self.publishSocket,
        serveSocket serve: () async throws -> Void = { try await ComposeSocketForwarder.serve() }
    ) async throws {
        if serveSocket {
            guard completions == nil, !socketPath, !installPath, arguments.isEmpty else {
                throw ValidationError("--serve-socket cannot be combined with other options or Compose arguments")
            }
            try await serve()
            return
        }
        if installPath {
            guard completions == nil, !socketPath, arguments.isEmpty else {
                throw ValidationError("--install-path cannot be combined with other options or Compose arguments")
            }
            let health = try await ClientHealthCheck.ping()
            print(health.installRoot.appendingPathComponent("libexec/container-plugins/compose").path)
            return
        }
        if let completions {
            guard !socketPath, arguments.isEmpty else {
                throw ValidationError("--completions cannot be combined with Compose arguments or --socket-path")
            }
            print(ComposeCompletionProvider.script(for: completions), terminator: "")
            return
        }

        if socketPath {
            guard arguments.isEmpty else {
                throw ValidationError("--socket-path cannot be combined with Compose arguments")
            }
            print(try publishSocket())
            return
        }

        throw ArgumentParser.ExitCode(try await compose(arguments))
    }

    /// Returns the Docker endpoint after starting its forwarder. The endpoint
    /// is printed even when the forwarder fails, so a shell profile still
    /// exports it and a later `--socket-path` can repair the forwarder.
    private static func publishSocket() throws -> String {
        let endpoint = ComposeSocketEndpoint()
        do {
            try ComposeSocketLauncher.ensureRunning(endpoint: endpoint)
        } catch {
            print(endpoint.dockerHost)
            throw error
        }
        return endpoint.dockerHost
    }

    private static func runCompose(arguments: [String]) async throws -> Int32 {
        LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
        let log = Logger(label: "container.compose")
        // The forwarder also mirrors published ports onto localhost, so start
        // it for Compose users who never export DOCKER_HOST.
        do {
            try ComposeSocketLauncher.ensureRunning()
        } catch {
            log.warning("Docker socket forwarder is unavailable; published ports stay on the machine address", metadata: ["error": "\(error)"])
        }
        let processRunner = ComposeProcessRunner()
        let manager = ComposeMachineManager(processRunner: processRunner)
        let snapshot = try await manager.ensureReady(log: log)
        let homeDirectory = FilePath(FileManager.default.homeDirectoryForCurrentUser.path)
        let currentDirectory = FilePath(FileManager.default.currentDirectoryPath)
        let workingDirectory = try ComposeEnvironment.workingDirectory(
            currentDirectory: currentDirectory,
            homeDirectory: homeDirectory
        )
        let environment = try ComposeEnvironment.make(
            hostEnvironment: ProcessInfo.processInfo.environment,
            homeDirectory: homeDirectory,
            workingDirectory: currentDirectory
        )
        return try await processRunner.run(
            snapshot: snapshot,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            log: log
        )
    }
}
