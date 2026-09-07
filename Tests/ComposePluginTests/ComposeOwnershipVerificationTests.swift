// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

import ComposeSupport
import ContainerizationError
import Foundation
import Testing

@testable import ContainerCompose

@Suite("Guest ownership verification")
struct ComposeOwnershipVerificationTests {
    private let record = OwnershipRecord(machineID: "compose", imageDigest: "sha256:abc", username: "me", uid: 501, gid: 20)

    @Test
    func matchingTokenIsAccepted() async throws {
        var scripts: [String] = []
        try await ComposeMachineOwnership.verifyGuestToken(record: record) { script in
            scripts.append(script)
            return ComposeCapturedProcess(exitCode: 0, output: record.guestToken + "\n")
        }
        #expect(scripts == ["/usr/bin/cat '\(ComposeMachineOwnership.marker)'"])
    }

    /// A replacement machine with matching configuration has a different
    /// marker, or none, and is refused.
    @Test(arguments: [
        ComposeCapturedProcess(exitCode: 0, output: UUID().uuidString.lowercased()),
        ComposeCapturedProcess(exitCode: 1, output: "cat: /etc/container/compose-plugin-owner: No such file or directory"),
        ComposeCapturedProcess(exitCode: 0, output: ""),
    ])
    func wrongTokenIsRefused(result: ComposeCapturedProcess) async {
        await #expect(throws: ContainerizationError.self) {
            try await ComposeMachineOwnership.verifyGuestToken(record: record) { _ in result }
        }
    }

    /// A check that could not run is not a mismatch; the caller decides.
    @Test
    func failedCheckIsReportedAsItsOwnError() async {
        do {
            try await ComposeMachineOwnership.verifyGuestToken(record: record) { _ in
                throw ContainerizationError(.timeout, message: "process did not exit")
            }
            Issue.record("a failed check passed")
        } catch let error as ContainerizationError {
            #expect(error.isCode(.timeout))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test
    func establishingWritesTheMarkerWithoutClobbering() async throws {
        var scripts: [String] = []
        try await ComposeMachineOwnership.verifyGuestToken(record: record, establishing: true) { script in
            scripts.append(script)
            return ComposeCapturedProcess(exitCode: 0, output: record.guestToken)
        }
        let script = try #require(scripts.first)
        #expect(script.contains("set -euC"))
        #expect(script.contains("'\(record.guestToken)' > '\(ComposeMachineOwnership.marker)'"))
        #expect(script.hasSuffix("/usr/bin/cat '\(ComposeMachineOwnership.marker)'"))
    }
}
