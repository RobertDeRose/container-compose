// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ContainerCompose

/// Runs the guest idle-policy script with the host shell, a temporary
/// environment file, and a fake `systemctl` that records its calls.
@Suite("Idle shutdown policy script")
struct ComposeIdleShutdownPolicyTests {
    private struct Fixture {
        let directory: URL
        var environmentFile: String { directory.appendingPathComponent("idle.env").path }
        var systemctl: String { directory.appendingPathComponent("systemctl").path }
        var calls: String { directory.appendingPathComponent("calls").path }

        init(restartSucceeds: Bool) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("idle-policy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fake = """
                #!/bin/sh
                printf '%s\\n' "$*" >> '\(calls)'
                exit \(restartSucceeds ? 0 : 1)
                """
            try fake.write(toFile: systemctl, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemctl)
        }

        func remove() {
            try? FileManager.default.removeItem(at: directory)
        }

        func run(seconds: Int) throws -> Int32 {
            let shell = Process()
            shell.executableURL = URL(fileURLWithPath: "/bin/sh")
            shell.arguments = [
                "-c",
                ComposeMachineManager.idleShutdownScript(seconds: seconds, environmentFile: environmentFile, systemctl: systemctl),
            ]
            try shell.run()
            shell.waitUntilExit()
            return shell.terminationStatus
        }

        var fileContents: String? {
            try? String(contentsOfFile: environmentFile, encoding: .utf8)
        }

        var restarts: Int {
            ((try? String(contentsOfFile: calls, encoding: .utf8)) ?? "").split(separator: "\n").count
        }
    }

    @Test
    func scriptIsValidShell() throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-n", "-c", ComposeMachineManager.idleShutdownScript(seconds: 600)]
        try shell.run()
        shell.waitUntilExit()
        #expect(shell.terminationStatus == 0)
    }

    @Test
    func newPolicyIsWrittenAndTheWatcherRestarted() throws {
        let fixture = try Fixture(restartSucceeds: true)
        defer { fixture.remove() }
        #expect(try fixture.run(seconds: 600) == 0)
        #expect(fixture.fileContents == "COMPOSE_IDLE_SHUTDOWN_IDLE_SECONDS=600\n")
        #expect(fixture.restarts == 1)
        // The same policy again does not restart the watcher.
        #expect(try fixture.run(seconds: 600) == 0)
        #expect(fixture.restarts == 1)
    }

    /// A failed restart must not leave the new file in place, or the next
    /// invocation would see a matching policy and never retry.
    @Test
    func failedRestartRestoresThePreviousPolicy() throws {
        let fixture = try Fixture(restartSucceeds: false)
        defer { fixture.remove() }
        try "COMPOSE_IDLE_SHUTDOWN_IDLE_SECONDS=300\n".write(toFile: fixture.environmentFile, atomically: true, encoding: .utf8)
        #expect(try fixture.run(seconds: 600) != 0)
        #expect(fixture.fileContents == "COMPOSE_IDLE_SHUTDOWN_IDLE_SECONDS=300\n")
        #expect(fixture.restarts == 1)
        // The retry attempts the restart again.
        #expect(try fixture.run(seconds: 600) != 0)
        #expect(fixture.restarts == 2)
    }

    @Test
    func failedFirstRestartLeavesNoPolicyFile() throws {
        let fixture = try Fixture(restartSucceeds: false)
        defer { fixture.remove() }
        #expect(try fixture.run(seconds: 600) != 0)
        #expect(fixture.fileContents == nil)
    }
}
