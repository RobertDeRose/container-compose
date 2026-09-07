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
record the compiler and host versions before a release. The supplied guest
Containerfile uses pinned live package repositories; test a genuinely fresh
image build, not only reuse of a cached image.

`ComposePluginTests` includes argument forwarding, environment policy, resource
lookup, configuration validation, capture bounds/timeouts, and signal/cancellation
regressions. `ComposeSupportTests` covers callback waits, ownership records, and
the actual idle policy with deterministic command fixtures.

## Integration checklist on an unmodified host

Use a test installation/app root without an existing feature-branch `compose`
machine. Record `container system status --format json`, including server commit.

- Confirm installation under the reported external directory, root help discovery,
  `container compose --help`, and `--completions` without creating a machine.
- From a home-directory project, run the first `compose up -d` using an uncached
  guest image. Inspect the native machine, guest Docker version, and readiness
  diagnostics. Confirm normal published-port access through the machine address.
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
