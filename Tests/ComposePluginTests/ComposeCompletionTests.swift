// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import ContainerCompose

@Suite("Compose completions")
struct ComposeCompletionTests {
    @Test
    func bashDelegatesNonComposeCompletion() throws {
        let probe = """
            _previous_container_completion() { COMPREPLY=(previous); }
            complete -o default -F _previous_container_completion container
            \(ComposeCompletionProvider.script(for: .bash))
            COMP_WORDS=(container list)
            COMP_CWORD=2
            COMPREPLY=()
            _container_compose_complete
            [[ "${COMPREPLY[0]}" == previous ]]
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", probe]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }

    @Test(arguments: ComposeCompletionShell.allCases)
    func pluginOptionsAreOnlyOfferedBeforeAComposeSubcommand(shell: ComposeCompletionShell) {
        let script = ComposeCompletionProvider.script(for: shell)

        #expect(ComposeCompletionProvider.pluginOptions.contains("--install-path"))
        #expect(ComposeCompletionProvider.pluginOptions.contains("--completions"))
        #expect(ComposeCompletionProvider.pluginOptions.contains("--socket-path"))
        #expect(!ComposeCompletionProvider.pluginOptions.contains("--serve-socket"))
        #expect(!ComposeCompletionProvider.composeOptions.contains("--install-path"))
        #expect(!ComposeCompletionProvider.composeOptions.contains("--completions"))
        #expect(script.components(separatedBy: ComposeCompletionProvider.pluginOptions).count == 2)

        switch shell {
        case .bash:
            #expect(script.contains("if (( COMP_CWORD <= 2 )); then"))
            #expect(script.contains("_container_compose_previous_completion"))
        case .zsh:
            #expect(script.contains("if (( CURRENT == 3 )); then"))
            #expect(script.contains("_container_compose_previous_completion"))
        case .fish:
            #expect(script.contains("test (count (commandline -opc)) -eq 2"))
            #expect(script.contains("test (count (commandline -opc)) -gt 2"))
            #expect(script.contains("test (commandline -opc)[2] = compose"))
        }
    }
}
