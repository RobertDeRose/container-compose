// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
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

    /// Compares the guest marker with the record's token, the check that
    /// configuration alone cannot make: a replacement machine with matching
    /// configuration is not this plugin's. Every path that runs processes in
    /// the machine makes this check. With `establishing`, the marker is
    /// written first, for a machine this invocation created. `run` executes a
    /// shell script in the guest and returns its output.
    ///
    /// Throws `.invalidState` on a mismatch; other errors are the script's.
    static func verifyGuestToken(
        record: OwnershipRecord,
        establishing: Bool = false,
        run: (String) async throws -> ComposeCapturedProcess
    ) async throws {
        let script: String
        if establishing {
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
        let result = try await run(script)
        guard result.exitCode == 0,
            result.output.trimmingCharacters(in: .whitespacesAndNewlines) == record.guestToken
        else {
            throw ContainerizationError(.invalidState, message: "Compose machine guest ownership check failed; refusing adoption or reconfiguration")
        }
    }

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
