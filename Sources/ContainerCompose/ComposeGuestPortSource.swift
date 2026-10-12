// Copyright © 2026 Robert DeRose and the container-compose contributors.
// SPDX-License-Identifier: Apache-2.0

import ComposeSupport
import ContainerAPIClient
import ContainerResource
import ContainerizationError
import Darwin
import Foundation
import Logging
import MachineAPIClient

/// Where the published ports of the Compose machine come from.
protocol ComposePortSource: Sendable {
    func machineState() async -> ComposePortForwarder.MachineState

    /// Runs one watcher of the machine's published ports until it ends,
    /// passing each report to `report`.
    func watch(
        containerID: String,
        report: @escaping @Sendable ([UInt16: String]) async -> Void
    ) async -> ComposePortForwarder.WatchOutcome

    /// Ends the current watcher and any started later.
    func stopWatching()
}

/// Reads the Compose machine's state through the API server and its
/// published ports through one long-lived guest process (`watchScript`).
///
/// Published ports are read from the guest's `docker-proxy` processes rather
/// than the Docker API, so watching neither opens a Docker client connection
/// (which idle shutdown counts as activity) nor boots a stopped machine. One
/// process per machine boot also matters because the runtime keeps a record
/// of every exec process until the machine stops.
final class ComposeGuestPortSource: ComposePortSource, @unchecked Sendable {
    /// Seconds between scans of the guest's `docker-proxy` processes.
    static let scanInterval = 2
    /// The watcher repeats an unchanged report this often, so ports that
    /// were unavailable are retried and a stalled watcher is noticed.
    static let heartbeatInterval: Duration = .seconds(30)
    static let heartbeatTimeout: Duration = .seconds(75)
    /// How long a watcher whose output ended gets to confirm its exit.
    static let exitGracePeriod: Duration = .seconds(2)

    private static let heartbeatBeats = Int(heartbeatInterval.components.seconds) / scanInterval

    /// Prints `ports <address>/<port> ...` for the TCP `docker-proxy`
    /// bindings at start, on every change, and every heartbeat. It exits at
    /// EOF on stdin, which the runtime delivers when the forwarder closes its
    /// end of the input pipe, even if a kill request cannot reach the
    /// runtime. Background commands get `/dev/null` as stdin, so the original
    /// stdin is passed through descriptor 3. SIGKILL, because an inherited
    /// ignored SIGTERM would leave the watcher running.
    static let watchScript = """
        exec 3<&0
        { cat <&3 >/dev/null; kill -9 $$; } &
        exec 3<&-
        scan() {
            for f in /proc/[0-9]*/cmdline; do
                set -- $(tr '\\000' ' ' < "$f" 2>/dev/null)
                case "${1:-}" in */docker-proxy|docker-proxy) ;; *) continue ;; esac
                proto= address=0.0.0.0 port=
                while [ $# -ge 2 ]; do
                    case "$1" in
                        -proto) proto=$2 ;;
                        -host-ip) address=$2 ;;
                        -host-port) port=$2 ;;
                    esac
                    shift
                done
                [ "$proto" = tcp ] && [ -n "$port" ] && echo "$address/$port"
            done
        }
        last=- beats=0
        while :; do
            ports=$(scan | sort -u | tr '\\n' ' ')
            if [ "$ports" != "$last" ] || [ "$beats" -ge \(heartbeatBeats) ]; then
                echo "ports $ports" || exit 0
                last=$ports beats=0
            fi
            beats=$((beats + 1))
            sleep \(scanInterval)
        done
        """

    static let watchConfiguration = ProcessConfiguration(
        executable: "/bin/sh",
        arguments: ["-c", watchScript],
        environment: ComposeEnvironment.guestDaemonEnvironmentEntries,
        workingDirectory: "/",
        terminal: false,
        user: .id(uid: 0, gid: 0)
    )

    private let log: Logger
    private let lock = NSLock()
    private var stopped = false
    private var watcher: (any ClientProcess)?
    private var foreignReported = false
    /// The backing container whose guest token last matched. The marker is
    /// written once per machine and a container exists for one boot, so the
    /// check is made once per boot: the runtime keeps a record of every exec
    /// process until the machine stops.
    private var verifiedContainerID: String?

    init(log: Logger) {
        self.log = log
    }

    /// Never boots the machine: a stopped machine is reported as stopped, and
    /// a running one is checked for this plugin's ownership the same way a
    /// Compose command checks it, guest token included.
    func machineState() async -> ComposePortForwarder.MachineState {
        do {
            let health = try await ClientHealthCheck.ping()
            let snapshot = try await MachineClient().inspect(id: ComposeMachineManager.machineID)
            guard snapshot.status == .running, let containerID = snapshot.containerId,
                let record = try OwnershipStore(appRoot: health.appRoot).load()
            else {
                return .stopped
            }
            do {
                try ComposeMachineOwnership.validate(snapshot, record: record)
                if lock.withLock({ verifiedContainerID }) != containerID {
                    // An XPC connection does not survive an API server
                    // restart, so each check uses a new process runner.
                    let processRunner = ComposeProcessRunner()
                    try await ComposeMachineOwnership.verifyGuestToken(record: record) { script in
                        try await processRunner.runShell(snapshot: snapshot, script: script)
                    }
                    lock.withLock { verifiedContainerID = containerID }
                }
            } catch let error as ContainerizationError where error.isCode(.invalidState) {
                let first = lock.withLock {
                    defer { foreignReported = true }
                    return !foreignReported
                }
                if first {
                    log.warning("Not forwarding the ports of a machine this plugin does not own", metadata: ["error": "\(error.message)"])
                }
                return .stopped
            }
            lock.withLock { foreignReported = false }
            return .running(containerID: containerID)
        } catch {
            return .unknown
        }
    }

    func stopWatching() {
        let process = lock.withLock {
            stopped = true
            return watcher
        }
        if let process {
            Task { try? await process.kill(SIGKILL) }
        }
    }

    func watch(
        containerID: String,
        report: @escaping @Sendable ([UInt16: String]) async -> Void
    ) async -> ComposePortForwarder.WatchOutcome {
        let client = ComposeProcessClient()
        let process: any ClientProcess
        let reader: Int32
        let lifeline: Int32
        do {
            let input = try ComposeRelayPipe()
            let output = try ComposeRelayPipe()
            process = try await client.createProcess(
                containerId: containerID,
                processId: UUID().uuidString.lowercased(),
                configuration: Self.watchConfiguration,
                stdio: [input.takeReadEnd(), output.takeWriteEnd(), nil]
            )
            lifeline = input.takeOwnedEnd()
            do {
                try await process.start()
            } catch {
                _ = close(lifeline)
                throw error
            }
            reader = output.takeOwnedEnd()
        } catch {
            log.debug("Cannot start the published port watcher", metadata: ["error": "\(error)"])
            return .notStarted
        }
        let alreadyStopped = lock.withLock {
            watcher = process
            return stopped
        }
        defer { lock.withLock { watcher = nil } }
        if alreadyStopped {
            try? await process.kill(SIGKILL)
        }
        defer { withExtendedLifetime(client) {} }
        return await Self.follow(process: process, reader: reader, lifeline: lifeline, report: report)
    }

    /// Applies the watcher's reports until it ends, and works out how.
    static func follow(
        process: any ClientProcess,
        reader: Int32,
        lifeline: Int32,
        heartbeatTimeout: Duration = ComposeGuestPortSource.heartbeatTimeout,
        exitGracePeriod: Duration = ComposeGuestPortSource.exitGracePeriod,
        report: @escaping @Sendable ([UInt16: String]) async -> Void
    ) async -> ComposePortForwarder.WatchOutcome {
        enum End: Equatable {
            case reports(reported: Bool)
            case stalled
            case exited
            case waitFailed
            case graceElapsed
        }
        let events = Self.lines(from: reader, timeout: heartbeatTimeout)
        return await withTaskGroup(of: End.self) { group in
            group.addTask {
                var reported = false
                for await event in events {
                    switch event {
                    case .line(let line):
                        guard let targets = Self.targets(fromReport: line) else { continue }
                        reported = true
                        await report(targets)
                    case .stalled:
                        return .stalled
                    }
                }
                return .reports(reported: reported)
            }
            group.addTask {
                do {
                    _ = try await process.wait()
                    return .exited
                } catch {
                    return .waitFailed
                }
            }
            guard let first = await group.next() else {
                return .waitFailed
            }
            var ends = [first]
            // Whatever ended first, the watcher's stdin is no longer needed.
            // Closing it ends a running watcher even when a kill request
            // cannot reach the runtime.
            _ = close(lifeline)
            let awaitingTheOtherSide =
                switch first {
                // Output written before exit is still in the pipe.
                case .exited: true
                // Output that ended without stalling most likely means an
                // exit about to be confirmed.
                case .reports: true
                case .stalled, .waitFailed, .graceElapsed: false
                }
            if awaitingTheOtherSide {
                group.addTask {
                    try? await Task.sleep(for: exitGracePeriod)
                    return .graceElapsed
                }
                if let second = await group.next() {
                    ends.append(second)
                }
            }
            if !ends.contains(.exited) {
                try? await process.kill(SIGKILL)
            }
            // Ending the report stream also stops its reader thread.
            group.cancelAll()
            for await end in group {
                ends.append(end)
            }
            let reported = ends.contains { if case .reports(reported: true) = $0 { true } else { false } }
            switch first {
            case .exited:
                return .exited(reported: reported)
            case .waitFailed:
                return .waitFailed
            case .stalled, .graceElapsed:
                return .stalled
            case .reports:
                if ends.contains(.exited) {
                    return .exited(reported: reported)
                }
                return ends.contains(.waitFailed) ? .waitFailed : .stalled
            }
        }
    }

    enum LineEvent: Equatable, Sendable {
        case line(String)
        /// No input arrived for the timeout; the stream ends after this.
        case stalled
    }

    /// Reads lines on a dedicated thread until EOF, a read error, no input
    /// for `timeout`, or the stream's termination (its consumer was
    /// cancelled), then closes `descriptor`. Only that thread closes it, so
    /// its number cannot be reused while it is still being read.
    static func lines(from descriptor: Int32, timeout: Duration) -> AsyncStream<LineEvent> {
        AsyncStream { continuation in
            // Termination closes the write end, which wakes the thread's poll.
            var wake: [Int32] = [-1, -1]
            guard pipe(&wake) == 0 else {
                _ = close(descriptor)
                continuation.finish()
                return
            }
            for end in wake {
                _ = fcntl(end, F_SETFD, FD_CLOEXEC)
            }
            let (wakeReader, wakeWriter) = (wake[0], wake[1])
            continuation.onTermination = { _ in
                _ = close(wakeWriter)
            }
            Thread.detachNewThread {
                defer {
                    _ = close(descriptor)
                    _ = close(wakeReader)
                    continuation.finish()
                }
                // Whole milliseconds, rounded up: a sub-second timeout must
                // not become a poll that returns at once.
                let milliseconds = Int32(clamping: Int((timeout / .milliseconds(1)).rounded(.up)))
                var pending = [UInt8]()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    var events = [
                        pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0),
                        pollfd(fd: wakeReader, events: Int16(POLLIN), revents: 0),
                    ]
                    let ready = poll(&events, 2, milliseconds)
                    if ready < 0, errno == EINTR {
                        continue
                    }
                    if ready == 0 {
                        continuation.yield(.stalled)
                        return
                    }
                    guard ready > 0, events[1].revents == 0 else {
                        return
                    }
                    let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
                    if count < 0, errno == EINTR {
                        continue
                    }
                    guard count > 0 else {
                        return
                    }
                    pending.append(contentsOf: buffer[..<count])
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        continuation.yield(.line(String(decoding: pending[..<newline], as: UTF8.self)))
                        pending.removeSubrange(...newline)
                    }
                    // A report is a few hundred bytes; anything longer is not one.
                    if pending.count > 64 * 1024 {
                        return
                    }
                }
            }
        }
    }

    /// Parses one `watchScript` report into the guest address to relay each
    /// port to.
    static func targets(fromReport line: String) -> [UInt16: String]? {
        var fields = line.split(separator: " ")
        guard fields.first == "ports" else {
            return nil
        }
        fields.removeFirst()
        var bindings: [UInt16: [String]] = [:]
        for field in fields {
            guard let slash = field.lastIndex(of: "/"), let port = UInt16(field[field.index(after: slash)...]), port > 0 else {
                continue
            }
            bindings[port, default: []].append(String(field[..<slash]))
        }
        return bindings.mapValues(target(for:))
    }

    /// Chooses where to connect for a port published on `addresses`. A
    /// wildcard binding also listens on loopback; otherwise loopback is
    /// preferred over an address on the machine's network, so one port bound
    /// to several addresses resolves the same way every time.
    static func target(for addresses: [String]) -> String {
        func rank(_ address: String) -> Int {
            switch address {
            case "0.0.0.0", "": 0
            case "::": 1
            case _ where address.hasPrefix("127."): 2
            case "::1": 3
            default: 4
            }
        }
        let best = addresses.min { (rank($0), $0) < (rank($1), $1) } ?? "0.0.0.0"
        switch best {
        case "0.0.0.0", "": return "127.0.0.1"
        case "::": return "::1"
        default: return best
        }
    }
}
