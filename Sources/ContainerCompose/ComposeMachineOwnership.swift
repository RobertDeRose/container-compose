// Copyright © 2026 the container-compose authors.
// SPDX-License-Identifier: Apache-2.0

import ComposeSupport
import ContainerizationError
import Foundation
import MachineAPIClient

/// Checks immutable configuration before boot, then a random guest marker before mutation.
/// Creation timestamps are intentionally not used: the baseline daemon reports a
/// new Date() on creation but the bundle creation date after a daemon restart.
enum ComposeMachineOwnership {
    static let marker = "/etc/container/compose-plugin-owner"

    static func record(for snapshot: MachineSnapshot) -> OwnershipRecord {
        let configuration = snapshot.configuration
        let user = configuration.userSetup
        return OwnershipRecord(
            machineID: snapshot.id,
            imageDigest: configuration.image.descriptor.digest,
            username: user.username,
            uid: user.uid,
            gid: user.gid
        )
    }

    static func validate(_ snapshot: MachineSnapshot, record: OwnershipRecord) throws {
        let configuration = snapshot.configuration
        let user = configuration.userSetup
        guard
            record.matches(
                machineID: snapshot.id,
                imageDigest: configuration.image.descriptor.digest,
                username: user.username,
                uid: user.uid,
                gid: user.gid
            ), snapshot.bootConfig.homeMount == .rw
        else {
            throw ContainerizationError(
                .invalidState,
                message: "machine 'compose' does not match this plugin's ownership record; refusing adoption or automatic migration"
            )
        }
    }
}
