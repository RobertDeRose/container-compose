//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
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
