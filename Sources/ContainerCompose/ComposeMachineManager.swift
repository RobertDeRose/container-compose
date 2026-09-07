// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

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
        try await waitForDocker(snapshot: snapshot, log: log)
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
        let booted = try await machineClient.boot(id: Self.machineID, dynamicEnv: [:])
        // Booting a running machine returns the state cached when it started,
        // which predates the user initialization done by its creator. Inspect
        // reads the marker from the bundle.
        let snapshot = booted.initialized ? booted : try await machineClient.inspect(id: Self.machineID)
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
        try await ComposeMachineOwnership.verifyGuestToken(record: record, establishing: newlyCreated) { script in
            try await processRunner.runShell(snapshot: snapshot, script: script)
        }
    }

    static let idleShutdownEnvironmentFile = "/etc/container/compose-idle-shutdown.env"

    /// Applies the idle policy to the guest watcher. The environment file is
    /// only left changed once the watcher has restarted with it: a failed
    /// restart puts the previous file back (or removes a new one), so the
    /// next invocation sees the policy that is still running and retries.
    static func idleShutdownScript(
        seconds: Int,
        environmentFile: String = idleShutdownEnvironmentFile,
        systemctl: String = "/usr/bin/systemctl"
    ) -> String {
        """
        set -eu
        desired='COMPOSE_IDLE_SHUTDOWN_IDLE_SECONDS=\(seconds)'
        path='\(environmentFile)'
        if [ -e "$path" ]; then
            existed=yes
            # The file is the single line this script writes.
            IFS= read -r previous < "$path" || true
            [ "$previous" != "$desired" ] || exit 0
        else
            existed=
            previous=
        fi
        /usr/bin/printf '%s\\n' "$desired" > "$path"
        if ! '\(systemctl)' restart container-compose-idle-shutdown.service; then
            if [ -n "$existed" ]; then
                /usr/bin/printf '%s\\n' "$previous" > "$path"
            else
                /bin/rm -f "$path"
            fi
            exit 1
        fi
        """
    }

    private func configureIdleShutdown(
        snapshot: MachineSnapshot,
        seconds: Int
    ) async throws {
        let result = try await processRunner.runShell(snapshot: snapshot, script: Self.idleShutdownScript(seconds: seconds))
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

    /// Probes the daemon with the plugin's own guest context, not the
    /// caller's: readiness does not depend on the host working directory.
    private func waitForDocker(snapshot: MachineSnapshot, log: Logger) async throws {
        let attempts = 60
        var lastOutput = ""
        for attempt in 0..<attempts {
            do {
                let result = try await processRunner.capture(
                    snapshot: snapshot,
                    executable: "/usr/bin/docker",
                    arguments: ["info", "--format", "{{.ServerVersion}}"],
                    environment: ComposeEnvironment.guestDaemonEnvironment,
                    workingDirectory: "/",
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

        let diagnostics = try? await processRunner.runShell(
            snapshot: snapshot,
            script: "systemctl status docker --no-pager -l 2>&1; journalctl -u docker --no-pager -n 80 2>&1",
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
