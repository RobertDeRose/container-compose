// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerPersistence
import ContainerizationOCI
import Foundation

/// Configuration scoped to the Compose plugin.
struct ComposeConfiguration: LoadablePluginConfiguration {
    static let pluginId = "compose"
    static let defaultImage = "container-compose-machine:local"

    static func isValidImage(_ image: String) -> Bool {
        guard !image.isEmpty else { return false }
        return (try? Reference.parse(image)) != nil
    }

    static let defaultCPUs = 4
    static let defaultMemory = "4gb"
    static let defaultIdleShutdownSeconds = 0

    var cpus: Int
    var memory: MemorySize
    var idleShutdownSeconds: Int

    init() {
        self.cpus = Self.defaultCPUs
        // A literal the parser accepts; not user input.
        self.memory = try! MemorySize(Self.defaultMemory)
        self.idleShutdownSeconds = Self.defaultIdleShutdownSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case cpus
        case memory
        case idleShutdownSeconds = "idle-shutdown-seconds"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        self.cpus = try container.decodeIfPresent(Int.self, forKey: .cpus) ?? defaults.cpus
        self.memory = try container.decodeIfPresent(MemorySize.self, forKey: .memory) ?? defaults.memory
        self.idleShutdownSeconds = try container.decodeIfPresent(Int.self, forKey: .idleShutdownSeconds) ?? defaults.idleShutdownSeconds
        guard cpus > 0 else {
            throw DecodingError.dataCorruptedError(forKey: .cpus, in: container, debugDescription: "cpus must be positive")
        }
        guard memory.toUInt64(unit: .bytes) >= 1024 * 1024 * 1024 else {
            throw DecodingError.dataCorruptedError(forKey: .memory, in: container, debugDescription: "memory must be at least 1gb")
        }
        if idleShutdownSeconds < 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .idleShutdownSeconds,
                in: container,
                debugDescription: "idle-shutdown-seconds must not be negative"
            )
        }
    }
}
