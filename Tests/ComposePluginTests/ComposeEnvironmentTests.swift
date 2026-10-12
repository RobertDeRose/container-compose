// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerizationError
import Foundation
import SystemPackage
import Testing

@testable import ContainerCompose

@Suite("Compose environment")
struct ComposeEnvironmentTests {
    @Test
    func hostSSHAgentIsNotForwardedToComposeEnvironment() throws {
        let environment = try ComposeEnvironment.make(
            hostEnvironment: [
                "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
                "GIT_SSH_COMMAND": "ssh -A",
                "PATH": "/host/bin",
            ],
            homeDirectory: FilePath("/Users/tester"),
            workingDirectory: FilePath("/Users/tester/project")
        )
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["GIT_SSH_COMMAND"] == nil)
        #expect(environment["PATH"] != "/host/bin")
    }

    @Test
    func composeHelpUsesHostCommandAndSubcommandArgument() {
        #expect(
            ComposeCommand.usageString(for: ComposeCommand.self)
                == "container compose [--completions <bash|zsh|fish> | --install-path | --socket-path | <subcommand> ...]"
        )
    }

    @Test
    func workingDirectoryMustBeVisibleInMachine() throws {
        let cwd = try ComposeEnvironment.workingDirectory(
            currentDirectory: FilePath("/Users/tester/project"),
            homeDirectory: FilePath("/Users/tester")
        )

        #expect(cwd == "/Users/tester/project")
    }

    @Test
    func workingDirectoryOutsideHomeIsRejected() {
        #expect(throws: ContainerizationError.self) {
            try ComposeEnvironment.workingDirectory(
                currentDirectory: FilePath("/private/tmp/project"),
                homeDirectory: FilePath("/Users/tester")
            )
        }
    }

    @Test
    func environmentUsesInnerDockerEndpointAndPreservesComposeValues() throws {
        let environment = try ComposeEnvironment.make(
            hostEnvironment: [
                "COMPOSE_PROJECT_NAME": "demo",
                "DOCKER_HOST": "unix:///host/docker.sock",
                "DOCKER_CONTEXT": "desktop-linux",
                "DOCKER_TLS_VERIFY": "1",
                "DOCKER_CONFIG": "/Users/tester/.docker",
                "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
                "TMPDIR": "/var/folders/host",
                "USER_SETTING": "kept",
            ],
            homeDirectory: FilePath("/Users/tester"),
            workingDirectory: FilePath("/Users/tester/project")
        )

        #expect(environment["COMPOSE_PROJECT_NAME"] == "demo")
        #expect(environment["USER_SETTING"] == "kept")
        #expect(environment["DOCKER_HOST"] == "unix:///etc/docker/docker.sock")
        #expect(environment["DOCKER_CONTEXT"] == nil)
        #expect(environment["DOCKER_TLS_VERIFY"] == nil)
        #expect(environment["DOCKER_CONFIG"] == "/root/.docker")
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["TMPDIR"] == "/tmp")
        #expect(environment["HOME"] == "/Users/tester")
        #expect(environment["PWD"] == "/Users/tester/project")
    }
}
