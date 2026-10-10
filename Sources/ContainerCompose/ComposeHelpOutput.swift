//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
// Modified for the external container-compose plugin; see NOTICE.md.
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

/// Rewrites Docker Compose help so users see the host command they invoked.
enum ComposeHelpOutput {
    private static let helpFlags: Set<String> = ["--help", "-h"]

    /// Returns whether the forwarded arguments are exactly a Compose help
    /// request: `help`, `help <subcommand>`, or `<subcommand> --help|-h`.
    /// Anything longer is left alone so a guest program's own `--help`
    /// output (for example `exec api python --help`) is never rewritten.
    static func isHelpRequest(_ arguments: [String]) -> Bool {
        switch arguments.count {
        case 1:
            return arguments[0] == "help"
        case 2:
            if arguments[0] == "help" {
                return !arguments[1].hasPrefix("-")
            }
            return !arguments[0].hasPrefix("-") && helpFlags.contains(arguments[1])
        default:
            return false
        }
    }

    /// Streaming, line-buffered rewrite of `docker compose` to
    /// `container compose`. Bytes are passed through unchanged otherwise, so
    /// non-UTF-8 output is preserved.
    final class Rewriter: @unchecked Sendable {
        private static let target = Data("docker compose".utf8)
        private static let replacement = Data("container compose".utf8)
        private static let newline = UInt8(ascii: "\n")

        private let lock = NSLock()
        private var pending = Data()

        /// Returns the rewritten bytes for every complete line received so far.
        func process(_ chunk: Data) -> Data {
            lock.withLock {
                pending.append(chunk)
                guard let last = pending.lastIndex(of: Self.newline) else {
                    return Data()
                }
                let complete = pending[pending.startIndex...last]
                let output = Self.rewrite(complete)
                pending = Data(pending[pending.index(after: last)...])
                return output
            }
        }

        /// Returns the rewritten bytes of a trailing partial line, if any.
        func finish() -> Data {
            lock.withLock {
                let output = Self.rewrite(pending)
                pending = Data()
                return output
            }
        }

        static func rewrite(_ data: Data) -> Data {
            var output = Data()
            output.reserveCapacity(data.count)
            var cursor = data.startIndex
            while let match = data[cursor...].firstRange(of: target) {
                output.append(data[cursor..<match.lowerBound])
                output.append(replacement)
                cursor = match.upperBound
            }
            output.append(data[cursor...])
            return output
        }
    }
}
