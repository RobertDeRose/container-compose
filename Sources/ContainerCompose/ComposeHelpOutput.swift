// Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
// SPDX-License-Identifier: Apache-2.0

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
