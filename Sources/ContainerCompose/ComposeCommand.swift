// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

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
        usage: "container compose [--completions <bash|zsh|fish> | --install-path | <subcommand> ...]",
        discussion: """
            Compose arguments are forwarded to the Docker Compose CLI inside the
            shared machine. The machine remains running after `compose down`.

            EXAMPLES:
              container compose up -d
              container compose -f compose.yaml config
              container compose exec api sh
              container compose version
              container machine stop compose
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

    @Flag(name: .long, help: "Unsupported: this plugin does not publish a host Docker socket")
    var socketPath = false

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

    func run(compose: ([String]) async throws -> Int32) async throws {
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
            throw ValidationError("Host Docker socket access is not supported by this external plugin; Compose runs inside the machine")
        }

        throw ArgumentParser.ExitCode(try await compose(arguments))
    }

    private static func runCompose(arguments: [String]) async throws -> Int32 {
        LoggingSystem.bootstrap { label in StreamLogHandler.standardError(label: label) }
        let log = Logger(label: "container.compose")
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
