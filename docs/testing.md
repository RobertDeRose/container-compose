# Testing

How changes to the plugin are verified, from unit tests to the manual checks
on a real host. Contribution rules are in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Test tiers

| Tier | Runs where | Proves |
| --- | --- | --- |
| Portable tests | macOS and Linux | `ComposeSupport` logic, the real idle-shutdown script against fake commands, and the installer against staged fixtures. |
| macOS unit tests | macOS | The plugin library, including the forwarders and process lifecycle, against fakes for the host services. |
| Host checklist | A real `container` host, by hand | Machine creation, boot, forwarding, idle shutdown, and upgrades. |

Only the third tier shows that the plugin works on a host. A green unit test
run, on either platform, says nothing about VM, XPC, Docker-in-VM, signing,
or installation behavior.

## Running the tests

```bash
make test       # swift test plus scripts/test-install.sh
make lint       # swift-format lint and shell syntax checks
make stage      # build and stage the plugin
```

Or directly:

```bash
swift test
swift test --filter ComposeSocketForwarderTests
./scripts/test-install.sh
```

On Linux `swift test` builds only `ComposeSupport` and its tests. The
executable and the Apple client libraries require macOS.

## What the targets cover

`Tests/ComposePluginTests` (macOS):

- Argument forwarding and plugin option validation.
- Environment and working-directory policy.
- Configuration decoding and validation.
- Ownership verification and machine configuration checks.
- The Docker socket forwarder: locking, replacement, probes, half-closes,
  relay termination, and draining.
- The port forwarder: discovery, backoff, failure counting, binding rules,
  conflict detection, and relay behavior.
- Help rewriting and completion scripts.
- Process lifecycle: signal translation, withheld and late replies,
  cancellation races, and bounded termination with joined cleanup.

`Tests/ComposeSupportTests` (portable):

- Ownership record encoding and storage.
- Cancellable reply waits.
- The idle-shutdown script, run with fake `docker`, `date`, and `systemctl`
  commands so every branch is deterministic.

`scripts/test-install.sh` installs a fixture plugin into a temporary prefix
and checks spaces in paths, in-place upgrades with and without the legacy
`--replace` flag, refusal to replace a foreign plugin, prefix validation, and
directory modes under a restrictive umask.

Timing-sensitive tests inject fixtures and use short, bounded waits. Do not
add tests that depend on wall-clock sleeps to pass.

## Host checklist

Run this on an unmodified host with no existing `compose` machine, ideally
with an isolated `container` app root. Record the host's
`container system status --format json` output, including the server
commit, with the results. Run the parts that touch what you changed before
opening a pull request, and the whole list before a release.

Installation and discovery:

- Install under the reported external plugin directory. Confirm root help
  lists `compose`, `container compose --help` works, and `--completions`
  works, all without creating a machine.

Machine creation and Compose:

- From a project under the home directory, run the first `compose up -d`
  with the guest image absent from the local image store, so it is pulled.
  Inspect the native machine, the guest Docker version, and readiness
  diagnostics. Confirm published ports answer through the machine address.
- Run a second invocation concurrently with the first. Confirm exactly one
  machine and one ownership record.
- Exercise `exec api python --help`, `run db psql -h db`, `exec -T`,
  stdin-fed `-f - config`, large output, terminal resizing, Ctrl-C, SIGTERM,
  and pipeline exit codes. Diagnostic timeouts must not apply to forwarded
  user commands.
- Write data to a named volume, stop the machine, run Compose again, and
  confirm the data and both ownership markers persist.

Docker socket:

- With the machine stopped, run `container compose --socket-path`. It must
  print the endpoint quickly without booting the machine. Run it again
  against the running forwarder and confirm the machine stays stopped.
- Through that socket run `docker version` (which boots the machine),
  `docker run`, `docker exec` without `-i`, `docker exec -i` with piped
  input, a TTY exec, and `docker build`.
- Kill a `docker logs -f` client and confirm its guest `dial-stdio` relay
  exits.
- Restart the native services and confirm the next Docker command succeeds.

Published ports:

- Publish ports on `127.0.0.1` and on all interfaces, including one below
  1024. Each must answer on `127.0.0.1` and `::1` within a few seconds.
- Publish a port another program of the same user already holds, such as
  AirPlay's `5000`. It must be skipped, logged once, and left to the other
  program.
- Stop the container and confirm the host listener closes. Confirm the guest
  runs exactly one port watcher.
- Against a published port whose server stays silent, close a client and
  confirm its relay exits within about two minutes. Half-close a client
  instead and confirm the relay stays open. Confirm a server that replies
  and closes ends the client's read while the client's write side stays
  open, including for a port published only on `::1`.

Upgrade and replacement:

- Reinstall the plugin and run `--socket-path` while a `logs -f` stream is
  open. The new forwarder must take over the socket and ports, and the stream
  must continue until the old forwarder exits.
- Upgrade only the plugin and confirm the machine's contents are unchanged.
  Remove only the plugin files and confirm no machine or data is deleted.

Ownership and refusal:

- Restart the native services with no in-flight work and confirm ownership
  still verifies.
- Confirm that a machine without a record, a missing or corrupt record, and a
  wrong guest token each produce a refusal instead of adoption,
  reconfiguration, or deletion.
- Confirm a pre-existing default machine stays the default. On an empty host,
  confirm and note that the host may select `compose` as default.

Idle shutdown:

- Set a short `idle-shutdown-seconds`, run a Compose command to apply it, and
  confirm shutdown happens only after an idle interval. Running containers,
  builds, pulls, pushes, Docker errors, and unreadable probes must all prevent
  shutdown. Set it back to `0` and confirm the policy is disabled.

## CI

The `CI` workflow runs `make test` on macOS and Linux and stages the macOS
plugin. The `Machine image` workflow builds and publishes the guest image.
Neither runs the host checklist, and a green run must not be presented as
having done so.

## Before a release

- `Package.resolved` is current for `Package.swift`.
- The digest pinned in `ComposeConfiguration.defaultImage` matches an image
  the `Machine image` workflow published from the same sources.
- The full host checklist has been run, with the host and compiler versions
  noted.
- `make package` produces an archive and checksum for the release
  architecture.
