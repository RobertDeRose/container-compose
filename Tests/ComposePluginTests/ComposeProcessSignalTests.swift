// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerAPIClient
import ContainerXPC
import Containerization
import ContainerizationError
import Darwin
import Testing

@testable import ContainerCompose

@Suite("Compose process signal wire contract")
struct ComposeProcessSignalTests {
    @Test(arguments: [SIGTERM, SIGKILL, SIGINT, SIGUSR1, SIGUSR2, SIGWINCH])
    func signalsUseTheUnmodifiedHostsStringContract(_ signal: Int32) throws {
        let request = try ComposeProcessClient.killRequest(containerID: "container", processID: "exec", signal: signal)
        let name = try #require(request.string(key: XPCKeys.signal.rawValue))
        #expect(name == "SIG\(try #require(Signal.platformName(signal)))")
        #expect(try Signal(name).rawValue == Signal(rawValue: signal).linuxSignal()?.rawValue)
        #expect(request.string(key: XPCMessage.routeKey) == XPCRoute.containerKill.rawValue)
        #expect(request.string(key: XPCKeys.id.rawValue) == "container")
        #expect(request.string(key: XPCKeys.processIdentifier.rawValue) == "exec")
    }

    @Test(arguments: [Int32(-1), 0, Int32.max, SIGINFO, SIGEMT])
    func rejectsSignalsWithoutALinuxEquivalent(_ signal: Int32) {
        #expect(throws: ContainerizationError.self) {
            try ComposeProcessClient.killRequest(containerID: "container", processID: "exec", signal: signal)
        }
    }
}
