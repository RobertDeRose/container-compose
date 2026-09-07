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

import ComposeSupport
import ContainerAPIClient
import ContainerPersistence
import ContainerResource
import ContainerizationError
import Foundation
import Logging
import MachineAPIClient
import SystemPackage
import TerminalProgress

/// Creates, validates, boots, and waits for the shared Compose machine.
struct ComposeMachineManager: Sendable {
    static let machineID = "compose"

    private let machineClient: MachineClient
    private let processRunner: ComposeProcessRunner

    init(
        machineClient: MachineClient = MachineClient(),
        processRunner: ComposeProcessRunner = ComposeProcessRunner()
    ) {
        self.machineClient = machineClient
        self.processRunner = processRunner
    }

    static func configurationFiles(for health: SystemHealth) -> [FilePath] {
        [
            ConfigurationLoader.configurationFile(
                in: FilePath(health.appRoot.path),
                of: .appRoot
            ),
            ConfigurationLoader.configurationFile(
                in: FilePath(health.installRoot.path),
                of: .installRoot
            ),
        ]
    }

    func ensureReady(log: Logger) async throws -> MachineSnapshot {
        let health = try await ClientHealthCheck.ping()
        let configurationFiles = Self.configurationFiles(for: health)
        let systemConfiguration = try await ConfigurationLoader.load(
            configurationFiles: configurationFiles
        )
        let pluginConfiguration: ComposeConfiguration = try await ConfigurationLoader.loadForPlugin(
            configurationFiles: configurationFiles
        )
        let customImage = ProcessInfo.processInfo.environment["CONTAINER_COMPOSE_MACHINE_IMAGE"]
        let image = customImage ?? ComposeConfiguration.defaultImage
        guard ComposeConfiguration.isValidImage(image) else {
            throw ContainerizationError(
                .invalidArgument,
                message: "Compose machine image reference is invalid"
            )
        }
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

        let initializationLock = try await ComposeMachineInitializationLock.acquire(appRoot: health.appRoot)
        defer { initializationLock.release() }

        let store = OwnershipStore(appRoot: health.appRoot)
        let (ownership, created) = try await ensureMachine(
            image: image,
            customImage: customImage != nil,
            configuration: pluginConfiguration,
            systemConfiguration: systemConfiguration,
            health: health,
            store: store,
            log: log
        )

        var snapshot = try await bootMachine(
            newlyCreated: created,
            log: log
        )
        do {
            try await verifyOwnership(snapshot: snapshot, record: ownership, newlyCreated: created)
            if created { try store.saveNew(ownership) }
        } catch {
            if created { try? await machineClient.stop(id: Self.machineID) }
            throw error
        }
        snapshot = try await waitForAddress(snapshot: snapshot)
        try await waitForDocker(
            snapshot: snapshot,
            environment: environment,
            workingDirectory: workingDirectory,
            log: log
        )
        try await configureIdleShutdown(
            snapshot: snapshot,
            seconds: pluginConfiguration.idleShutdownSeconds
        )

        if let ipAddress = snapshot.ipAddress {
            var metadata: Logger.Metadata = ["ip": "\(ipAddress)"]
            if HostDNSResolver().listDomains().contains(where: { $0.pqdn == MachineConfiguration.defaultDNSDomain }) {
                metadata["hostname"] = "\(snapshot.configuration.dnsName)"
            } else {
                metadata["dnsSetup"] = "sudo container system dns create machine"
            }
            log.info("Compose machine is ready", metadata: metadata)
        }

        return snapshot
    }

    private func ensureMachine(
        image: String,
        customImage: Bool,
        configuration: ComposeConfiguration,
        systemConfiguration: ContainerSystemConfig,
        health: SystemHealth,
        store: OwnershipStore,
        log: Logger
    ) async throws -> (OwnershipRecord, Bool) {
        let record = try store.load()
        let existing: MachineSnapshot?
        do {
            existing = try await machineClient.inspect(id: Self.machineID)
        } catch {
            guard contains(error, code: .notFound) else { throw error }
            existing = nil
        }
        if let existing {
            guard let record else {
                throw ContainerizationError(
                    .exists,
                    message: "machine 'compose' already exists without this plugin's ownership record; refusing adoption. See docs/migration.md"
                )
            }
            try ComposeMachineOwnership.validate(existing, record: record)
            return (record, false)
        }
        guard record == nil else {
            throw ContainerizationError(
                .invalidState,
                message: "Compose ownership record exists but the machine is missing; refusing automatic recreation. See docs/migration.md"
            )
        }

        if !customImage {
            let imageAvailable = try await isImageAvailable(
                image: image,
                systemConfiguration: systemConfiguration
            )
            if !imageAvailable {
                let builder = try ComposeMachineImageBuilder.make(health: health)
                try await builder.build(image: image, log: log)
            }
        }

        let machineConfiguration: MachineConfiguration
        let resources: MachineResources?
        let noProgress: ProgressUpdateHandler = { _ in }
        do {
            let management = try Flags.MachineManagement.parse([])
            let registry = try Flags.Registry.parse([])
            let imageFetch = try Flags.ImageFetch.parse([])
            (machineConfiguration, resources) = try await MachineClient.machineConfigFromFlags(
                id: Self.machineID,
                image: image,
                management: management,
                registry: registry,
                imageFetch: imageFetch,
                containerSystemConfig: systemConfiguration,
                progressUpdate: noProgress
            )
        } catch {
            throw ContainerizationError(
                .internalError,
                message: "failed to prepare Compose machine image \(image)",
                cause: error
            )
        }

        let bootConfiguration = try MachineConfig(
            cpus: configuration.cpus,
            memory: configuration.memory,
            homeMount: .rw,
            virtualization: false,
            kernelPath: nil
        )

        // Unmodified upstream selects the first machine as default. Do not
        // edit its state file or attempt a racy set/restore workaround.
        if try await machineClient.getDefault() == nil {
            log.warning("Upstream will select the first machine as default; 'compose' may become your default machine")
        }
        try await machineClient.create(
            configuration: machineConfiguration,
            resources: resources,
            bootConfig: bootConfiguration
        )
        let snapshot = try await machineClient.inspect(id: Self.machineID)
        log.info("Created Compose machine", metadata: ["id": "\(Self.machineID)"])
        return (ComposeMachineOwnership.record(for: snapshot), true)
    }

    private func isImageAvailable(
        image: String,
        systemConfiguration: ContainerSystemConfig
    ) async throws -> Bool {
        do {
            _ = try await ClientImage.get(
                reference: image,
                containerSystemConfig: systemConfiguration
            )
            return true
        } catch let error as ContainerizationError where error.isCode(.notFound) {
            return false
        }
    }

    private func bootMachine(newlyCreated: Bool, log: Logger) async throws -> MachineSnapshot {
        let snapshot = try await machineClient.boot(id: Self.machineID, dynamicEnv: [:])
        guard !snapshot.initialized else { return snapshot }
        guard newlyCreated else {
            throw ContainerizationError(.invalidState, message: "owned Compose machine has lost its initialization marker; refusing reprovisioning")
        }
        do {
            let environment = Dictionary(
                uniqueKeysWithValues: snapshot.configuration.processEnvironment.map { value in
                    let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    return (String(parts[0]), String(parts[1]))
                })
            let result = try await processRunner.capture(
                snapshot: snapshot,
                executable: "/\(MachineBundle.sbinDirectory)/\(MachineBundle.initFile)",
                arguments: ["-u"],
                environment: environment,
                workingDirectory: "/",
                timeout: .seconds(120)
            )
            guard result.exitCode == 0 else {
                throw ContainerizationError(.invalidState, message: "machine user initialization failed: \(result.output)")
            }
            return try await machineClient.inspect(id: Self.machineID)
        } catch {
            try? await machineClient.stop(id: Self.machineID)
            throw error
        }
    }

    private func verifyOwnership(snapshot: MachineSnapshot, record: OwnershipRecord, newlyCreated: Bool) async throws {
        let marker = ComposeMachineOwnership.marker
        let script: String
        if newlyCreated {
            // Token text is generated from UUID, not shell input. Noclobber
            // prevents silently replacing a marker inherited from an image.
            script = """
                set -euC
                umask 077
                /usr/bin/install -d -m 0755 /etc/container
                /usr/bin/printf '%s\\n' '\(record.guestToken)' > '\(marker)'
                /usr/bin/cat '\(marker)'
                """
        } else {
            script = "/usr/bin/cat '\(marker)'"
        }
        let result = try await processRunner.capture(
            snapshot: snapshot,
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: [:],
            workingDirectory: "/",
            timeout: .seconds(10)
        )
        guard result.exitCode == 0,
            result.output.trimmingCharacters(in: .whitespacesAndNewlines) == record.guestToken
        else {
            throw ContainerizationError(.invalidState, message: "Compose machine guest ownership check failed; refusing adoption or reconfiguration")
        }
    }

    private func configureIdleShutdown(
        snapshot: MachineSnapshot,
        seconds: Int
    ) async throws {
        let desired = "COMPOSE_IDLE_SHUTDOWN_IDLE_SECONDS=\(seconds)"
        let script = """
            set -eu
            desired='\(desired)'
            path=/etc/container/compose-idle-shutdown.env
            current=$(/usr/bin/cat "$path" 2>/dev/null || true)
            if [ "$current" != "$desired" ]; then
                /usr/bin/printf '%s\\n' "$desired" > "$path"
                /usr/bin/systemctl restart container-compose-idle-shutdown.service
            fi
            """
        let result = try await processRunner.capture(
            snapshot: snapshot,
            executable: "/bin/sh",
            arguments: ["-c", script],
            environment: [:],
            workingDirectory: "/",
            timeout: .seconds(10)
        )
        guard result.exitCode == 0 else {
            throw ContainerizationError(
                .invalidState,
                message: "failed to configure Compose idle shutdown: \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
            )
        }
    }

    private func waitForAddress(snapshot: MachineSnapshot) async throws -> MachineSnapshot {
        var lastSnapshot = snapshot
        for _ in 0..<30 {
            lastSnapshot = try await machineClient.inspect(id: Self.machineID)
            if lastSnapshot.status == .running, lastSnapshot.ipAddress != nil {
                return lastSnapshot
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw ContainerizationError(
            .timeout,
            message: "Compose machine did not receive a network address within 6 seconds"
        )
    }

    private func waitForDocker(
        snapshot: MachineSnapshot,
        environment: [String: String],
        workingDirectory: String,
        log: Logger
    ) async throws {
        let attempts = 60
        var lastOutput = ""
        for attempt in 0..<attempts {
            do {
                let result = try await processRunner.capture(
                    snapshot: snapshot,
                    executable: "/usr/bin/docker",
                    arguments: ["info", "--format", "{{.ServerVersion}}"],
                    environment: environment,
                    workingDirectory: workingDirectory,
                    timeout: .milliseconds(500)
                )
                if result.exitCode == 0 {
                    return
                }
                lastOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch let error as ContainerizationError where error.isCode(.timeout) {
                lastOutput = error.message
            }
            if attempt < attempts - 1 {
                try await Task.sleep(for: .milliseconds(250))
            }
        }

        let diagnostics = try? await processRunner.capture(
            snapshot: snapshot,
            executable: "/bin/sh",
            arguments: ["-c", "systemctl status docker --no-pager -l 2>&1; journalctl -u docker --no-pager -n 80 2>&1"],
            environment: environment,
            workingDirectory: workingDirectory,
            timeout: .seconds(5)
        )
        let metadata: Logger.Metadata = [
            "probe": "\(lastOutput)",
            "diagnostics": "\(diagnostics?.output ?? "unavailable")",
        ]
        log.error(
            "Docker daemon did not become ready",
            metadata: metadata
        )
        throw ContainerizationError(
            .timeout,
            message: "Docker daemon inside Compose machine did not become ready"
        )
    }

    private func contains(_ error: Error, code: ContainerizationError.Code) -> Bool {
        guard let error = error as? ContainerizationError else {
            return false
        }
        return error.isCode(code) || (error.cause.map { contains($0, code: code) } ?? false)
    }
}
