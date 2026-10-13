// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

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
