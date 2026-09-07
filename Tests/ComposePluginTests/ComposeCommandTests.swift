// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import ContainerCompose

@Suite("Compose command arguments")
struct ComposeCommandTests {
    @Test(arguments: [
        ["exec", "api", "python", "--help"],
        ["exec", "api", "my-tool", "--install-path"],
        ["exec", "api", "python", "-h"],
        ["run", "db", "psql", "-h", "db", "-U", "docker"],
        ["exec", "api", "my-tool", "--socket-path", "/tmp/app.sock"],
        ["run", "api", "my-tool", "--socket-path=/tmp/app.sock"],
        ["exec", "api", "my-tool", "--completions", "bash"],
        ["run", "api", "my-tool", "--completions=bash"],
        ["exec", "api", "my-tool", "--", "--help"],
        ["run", "api", "my-tool", "--", "--socket-path"],
        ["-f", "compose.yaml", "exec", "api", "python", "--help"],
        ["-f", "-", "config"],
        ["up", "--help"],
        ["config", "-h"],
        ["up", "--socket-path"],
        ["up", "--completions=bash"],
    ])
    func capturedArgumentsRemainOpaque(arguments: [String]) async throws {
        let command = try ComposeCommand.parse(arguments)

        #expect(command.arguments == arguments)
        #expect(!command.socketPath)
        #expect(command.completions == nil)

        var forwardedArguments: [[String]] = []
        do {
            try await command.run { arguments in
                forwardedArguments.append(arguments)
                return 37
            }
            Issue.record("forwarded command did not propagate its exit code")
        } catch {
            #expect(ComposeCommand.exitCode(for: error).rawValue == 37)
        }
        #expect(forwardedArguments == [arguments])
    }

    @Test
    func unsupportedSocketDoesNotLaunchCompose() async throws {
        let command = try ComposeCommand.parse(["--socket-path"])
        do {
            try await command.run { _ in
                Issue.record("unsupported host socket option reached the guest")
                return 0
            }
            Issue.record("unsupported host socket option unexpectedly succeeded")
        } catch {
            #expect(ComposeCommand.message(for: error).contains("Host Docker socket access is not supported"))
        }
    }

    @Test(arguments: [["--install-path", "up"], ["--install-path", "--completions", "bash"]])
    func installPathRejectsMixedInvocation(arguments: [String]) async throws {
        let command = try ComposeCommand.parse(arguments)
        do {
            try await command.run { _ in
                Issue.record("mixed install-path invocation reached the guest")
                return 0
            }
            Issue.record("mixed invocation unexpectedly succeeded")
        } catch {
            #expect(ComposeCommand.message(for: error).contains("--install-path cannot be combined"))
        }
    }

    @Test
    func leadingSocketPathIsAPluginOption() throws {
        let command = try ComposeCommand.parse(["--socket-path"])

        #expect(command.socketPath)
        #expect(command.completions == nil)
        #expect(command.arguments.isEmpty)
    }

    @Test(arguments: ["bash", "zsh", "fish"])
    func leadingCompletionsIsAPluginOption(shell: String) throws {
        let command = try ComposeCommand.parse(["--completions", shell])

        #expect(command.completions?.rawValue == shell)
        #expect(!command.socketPath)
        #expect(command.arguments.isEmpty)
    }

    @Test(arguments: [
        ["--completions", "bash", "up"],
        ["--completions=bash", "exec", "api", "python", "--help"],
        ["--completions", "bash", "--socket-path"],
        ["--socket-path", "--completions", "bash"],
        ["--socket-path", "up"],
        ["--socket-path", "exec", "api", "python", "--help"],
    ])
    func pluginOptionsStillRejectMixedInvocations(arguments: [String]) async throws {
        let command = try ComposeCommand.parse(arguments)
        let expectedMessage =
            command.completions == nil
            ? "--socket-path cannot be combined with Compose arguments"
            : "--completions cannot be combined with Compose arguments or --socket-path"

        do {
            try await command.run { _ in
                Issue.record("mixed plugin and Compose invocation was forwarded")
                return 0
            }
            Issue.record("mixed plugin and Compose invocation unexpectedly succeeded")
        } catch {
            #expect(ComposeCommand.message(for: error) == expectedMessage)
        }
    }
}
