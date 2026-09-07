// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerResource
import ContainerVersion
import ContainerizationError
import ContainerizationOCI
import Foundation
import MachineAPIClient
import SystemPackage
import Testing

@testable import ContainerCompose

struct MachineConfigurationTests {
    @Test
    func composeConfigurationUsesDaemonRoots() throws {
        let health = try JSONDecoder().decode(
            SystemHealth.self,
            from: Data(
                #"{"appRoot":"/tmp/app","installRoot":"/tmp/install","logRoot":null,"apiServerVersion":"test","apiServerCommit":"test","apiServerBuild":"debug","apiServerAppName":"test"}"#
                    .utf8)
        )
        let files = ComposeMachineManager.configurationFiles(for: health)
        #expect(
            files.map(\.string) == [
                "/tmp/app/config/config.toml",
                "/tmp/install/etc/container/config.toml",
            ])
    }

    @Test
    func idleShutdownSecondsDecodeFromConfiguration() throws {
        let data = Data(#"{"idle-shutdown-seconds":600}"#.utf8)
        let configuration = try JSONDecoder().decode(ComposeConfiguration.self, from: data)
        #expect(configuration.idleShutdownSeconds == 600)
    }

    @Test
    func defaultComposeImageIsAccepted() {
        #expect(ComposeConfiguration.defaultImage == "container-compose-machine:local")
        #expect(ComposeConfiguration.isValidImage(ComposeConfiguration.defaultImage))
    }

    @Test
    func customComposeImageReferenceIsAccepted() {
        #expect(ComposeConfiguration.isValidImage("registry.example/compose-machine:dev"))
        #expect(ComposeConfiguration.isValidImage("registry.example/compose-machine@sha256:\(String(repeating: "a", count: 64))"))
        #expect(!ComposeConfiguration.isValidImage("not a reference"))
    }

    @Test
    func emptyComposeImageIsRejected() {
        #expect(!ComposeConfiguration.isValidImage(""))
    }

    @Test
    func installedImageResourcesUseSiblingPluginResources() throws {
        let root = URL(fileURLWithPath: "/tmp/compose-plugin")
        let executable = FilePath(root.appendingPathComponent("bin/compose").path)
        let resources = root.appendingPathComponent("resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: resources.appendingPathComponent("Containerfile"))
        try Data().write(to: resources.appendingPathComponent("container-compose-idle-shutdown"))
        try Data().write(to: resources.appendingPathComponent("container-compose-idle-shutdown.service"))

        let found = try ComposeMachineImageResources.locate(
            executablePath: executable,
            mainResourceURL: nil,
            moduleResourceURL: nil
        )
        #expect(found.directory.path == resources.path)
    }

    @Test
    func missingImageResourceReportsRequiredFiles() throws {
        let root = URL(fileURLWithPath: "/tmp/compose-missing-resources")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Containerfile"))

        #expect(throws: ContainerizationError.self) {
            try ComposeMachineImageResources.locate(
                executablePath: FilePath("/unrelated/compose"),
                mainResourceURL: nil,
                moduleResourceURL: root
            )
        }
    }

    @Test
    func moduleResourcesCanBeInjectedForResolutionTests() throws {
        let root = URL(fileURLWithPath: "/tmp/compose-module")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: root.appendingPathComponent("Containerfile"))
        try Data().write(to: root.appendingPathComponent("container-compose-idle-shutdown"))
        try Data().write(to: root.appendingPathComponent("container-compose-idle-shutdown.service"))

        let found = try ComposeMachineImageResources.locate(
            executablePath: FilePath("/unrelated/compose"),
            mainResourceURL: nil,
            moduleResourceURL: root
        )
        #expect(found.directory.path == root.path)
    }

    @Test(arguments: [0, -1])
    func invalidCPUCountsAreRejected(cpus: Int) {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ComposeConfiguration.self, from: Data("{\"cpus\":\(cpus)}".utf8))
        }
    }

    @Test
    func invalidIdleTimeoutIsRejected() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(ComposeConfiguration.self, from: Data(#"{"idle-shutdown-seconds":-1}"#.utf8))
        }
    }

}
