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
        // Pinned by digest so every new machine gets the image CI published.
        #expect(ComposeConfiguration.defaultImage.hasPrefix("ghcr.io/robertderose/container-compose-machine@sha256:"))
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
