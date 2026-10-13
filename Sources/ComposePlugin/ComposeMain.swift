// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

import ContainerCompose

@main
struct ComposePlugin {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments == ["-h"] {
            print(ComposeCommand.helpMessage())
            return
        }
        if arguments == ["--version"] {
            print(ComposeVersion.current)
            return
        }
        await ComposeCommand.main()
    }
}
