# Validation

## Checks performed during extraction

The extraction environment is Linux with Swift 6.2.1. `swift test` on Linux
builds only `ComposeSupport` and its tests. The actual guest idle-shutdown script
is exercised with fake Docker/date/systemctl commands. The installer is exercised
against temporary staged-plugin fixtures. These are not VM integration tests.

Swift syntax/format checks can inspect the macOS files without importing or
linking the Apple SDK. A parsed file is not a typechecked macOS binary. The build
container could not resolve github.com for Swift package fetches; a complete
macOS dependency resolution and build were not performed.

No macOS/XPC/Virtualization, Docker-in-VM, signing, or live installation result
is claimed. The final artifact's delivery notes record the executed check counts.

## Build and unit tests on macOS

```bash
swift --version
swift package resolve
swift build -c release --product compose
swift test
./scripts/test-install.sh
make stage
```

Commit the generated root `Package.resolved` after successful resolution and
record the compiler and host versions before a release. The guest
Containerfile uses pinned live package repositories; confirm the `Machine image`
workflow still builds it, and that the pinned digest matches a published image.

`ComposePluginTests` includes argument forwarding, environment policy,
configuration validation, the socket and port forwarder, capture bounds/timeouts, and signal/cancellation
regressions. `ComposeSupportTests` covers callback waits, ownership records, and
the actual idle policy with deterministic command fixtures.

## Integration checklist on an unmodified host

Use a test installation/app root without an existing feature-branch `compose`
machine. Record `container system status --format json`, including server commit.

- Confirm installation under the reported external directory, root help discovery,
  `container compose --help`, and `--completions` without creating a machine.
- From a home-directory project, run the first `compose up -d` without the guest
  image in the local image store, so it is pulled. Inspect the native machine, guest Docker version, and readiness
  diagnostics. Confirm normal published-port access through the machine address.
- With the machine stopped, run `container compose --socket-path` and confirm it
  prints the endpoint quickly without booting the machine. Through that socket,
  run `docker version` (which boots the machine), `docker run`, `docker exec`
  without `-i`, `docker exec -i` with piped input, a TTY exec, and `docker build`.
  Kill a `docker logs -f` client and confirm its guest `dial-stdio` relay exits.
  With the machine stopped, run `--socket-path` against a running forwarder
  and confirm the machine stays stopped.
  Restart the native services and confirm the next Docker command succeeds.
- Publish ports on `127.0.0.1` and on all interfaces, including one below 1024,
  and confirm each answers on `127.0.0.1` and `::1` within a few seconds.
  Publish a port that another program of the same user already listens on (for
  example AirPlay's `5000`) and confirm it is skipped, logged once, and the other
  program keeps it. Stop the container and confirm the host listener closes.
  Confirm the guest runs exactly one port watcher.
- Against a published port whose server stays silent, close a client and
  confirm its guest `socat` relay exits within about two minutes. Half-close a
  client instead and confirm the relay stays open.
- Reinstall the plugin and run `--socket-path` while a `logs -f` stream is open.
  Confirm the new forwarder takes over the socket and ports and the stream
  continues until the old forwarder exits.
- Run a second invocation concurrently with the first. Confirm exactly one machine
  and one ownership record, with no adoption after a native name collision.
- Exercise `exec api python --help`, `run db psql -h db`, `exec -T`, stdin-fed
  `-f - config`, large output, terminal resizing, Ctrl-C, SIGTERM, and pipeline
  exit codes. Ensure diagnostic timeouts do not apply to forwarded user commands.
- Write test data to a Docker named volume, stop the native machine, then invoke
  Compose again and confirm the data and identity markers persist.
- Restart the native services with no in-flight work and verify token-based
  ownership after restart. Separately document a daemon-crash recovery exercise;
  this plugin does not claim daemon-wide orphan repair.
- Set a short idle timeout in `[plugin.compose]`, invoke Compose to apply it, and
  test shutdown only after empty/inactive intervals. Running containers, builds,
  pulls, pushes, Docker errors, and unreadable activity probes must prevent a
  mistaken shutdown. Test disabling the policy again.
- Verify that a pre-existing default remains selected. On an empty host, confirm
  and document that upstream may select `compose` as default.
- Verify unowned machines, missing/corrupt records, and wrong guest tokens produce
  refusal instead of automatic adoption, reconfiguration, or deletion.
- Upgrade only the plugin. Confirm existing machine contents remain unchanged.
  Uninstall only the plugin files and confirm no machine/data deletion occurs.

## CI

The included workflow runs the macOS build/unit tests and Linux portable tests.
It does not run VM integration on hosted runners or publish a release. A successful
workflow must not be represented as completion of the integration checklist above.

## Signal and termination regressions

The compatibility client sends canonical signal names using the unmodified host
service's string wire format. Unsupported host-only signals are rejected before
sending. Each kill reply has a five-second deadline.

`ProcessCancellationController` owns and joins one termination task. A bounded
SIGTERM attempt is followed by a two-second grace interval and, without confirmed
exit, a bounded SIGKILL attempt. Confirmed remote exit cancels pending reply waits
as well as the grace timer. Cancelling the local process wait is not evidence of
remote exit. Timeouts stop waiting for a reply; they do not revoke an XPC request
already sent to the service. Delivery failures are logged.

Run the new macOS unit coverage with:

```bash
swift test --filter 'ComposeProcessSignalTests|ProcessTerminationTests|ProcessCancellationTests'
```

The tests include withheld acknowledgements, late replies, cancellation of either
pending signal after confirmed exit, ordering of the grace interval, repeated
cancellation, and joining cleanup before returning from process I/O. Linux's
normal package tests do not compile or run these macOS-specific tests.
