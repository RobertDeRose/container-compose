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

import Foundation
import Testing

@testable import ContainerCompose

@Suite("Compose help output")
struct ComposeHelpOutputTests {
    @Test(arguments: [
        ["help"],
        ["help", "up"],
        ["up", "--help"],
        ["ps", "-h"],
    ])
    func recognizesComposeHelp(arguments: [String]) {
        #expect(ComposeHelpOutput.isHelpRequest(arguments))
    }

    @Test(arguments: [
        [],
        ["ps"],
        ["--help"],
        ["help", "--verbose"],
        ["-f", "--help"],
        ["exec", "api", "python", "--help"],
        ["run", "db", "psql", "-h", "db"],
        ["-f", "compose.yaml", "up", "--help"],
    ])
    func ignoresOtherInvocations(arguments: [String]) {
        #expect(!ComposeHelpOutput.isHelpRequest(arguments))
    }

    @Test
    func rewritesAcrossChunkBoundaries() {
        let rewriter = ComposeHelpOutput.Rewriter()
        var output = Data()
        for chunk in ["Usage:  dock", "er compose ps [OPTIONS]\nRun 'docker com", "pose COMMAND --help'"] {
            output.append(rewriter.process(Data(chunk.utf8)))
        }
        #expect(String(decoding: output, as: UTF8.self) == "Usage:  container compose ps [OPTIONS]\n")
        output.append(rewriter.finish())
        #expect(
            String(decoding: output, as: UTF8.self)
                == "Usage:  container compose ps [OPTIONS]\nRun 'container compose COMMAND --help'"
        )
    }

    @Test
    func preservesUnrelatedBytes() {
        let input = Data([0xff, 0xfe]) + Data(" docker run docker compose\r\n".utf8)
        let expected = Data([0xff, 0xfe]) + Data(" docker run container compose\r\n".utf8)
        let rewriter = ComposeHelpOutput.Rewriter()
        #expect(rewriter.process(input) == expected)
        #expect(rewriter.finish().isEmpty)
    }
}
