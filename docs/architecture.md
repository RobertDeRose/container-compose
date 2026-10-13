# Architecture

This document explains how `container compose` is put together and why it
makes the choices it does. Read it before changing machine handling, the
forwarders, or the guest image. The [README](../README.md) covers usage, and
[testing.md](testing.md) covers how changes are verified.

## Overview

The plugin runs Docker Compose unmodified inside one Linux VM that Apple's
`container` host manages. Three processes are involved:

| Process | Lifetime | Role |
| --- | --- | --- |
| `compose` CLI | One per `container compose` invocation | Prepares the machine, then runs `docker compose` inside it and relays its I/O. |
| Forwarder service | One per user, in the background | Serves the host Docker socket and mirrors published ports onto `localhost`. Started on demand by the CLI or by `--socket-path`. |
| `compose` machine | Persistent, booted on demand | A Debian guest running Docker Engine, Compose, and an idle-shutdown watcher. Owned by the host's machine service. |

Everything the plugin does goes through the host's public client libraries:
the machine API for create, inspect, boot, and stop; the process routes for
running programs in the guest; and the host's configuration loader for its
own settings. It never edits the daemon's state files, never replaces a host
service, and never deletes a machine.

## Source layout

| Path | Contents |
| --- | --- |
| `Sources/ComposePlugin` | The executable's entry point. Handles `--help` and `--version` itself, then runs `ComposeCommand`. |
| `Sources/ContainerCompose` | The plugin library. Everything below lives here unless noted. |
| `Sources/ContainerCompose/Compatibility` | The guest process client built on the host's process routes. |
| `Sources/ComposeSupport` | Portable code with no Apple dependencies: `OwnershipRecord` and `AsyncReply`. Builds and tests on Linux. |
| `machine-image` | The guest `Containerfile`, the idle-shutdown script, and its systemd unit. |
| `scripts` | Staging, installation, packaging, and the installer's test. |
| `Tests` | `ComposePluginTests` (macOS) and `ComposeSupportTests` (portable). |

## A command, start to finish

1. The host's plugin loader finds `compose` under
   `<install-root>/libexec/container-plugins/compose` and executes it with
   the remaining arguments. `config.toml` next to the binary is the plugin
   manifest.
2. `ComposeCommand` parses the plugin's own options (`--completions`,
   `--install-path`, `--socket-path`, and the hidden `--serve-socket`).
   Everything after the first positional argument is captured for Compose and
   never reinterpreted, so a guest program's `--help` or `--socket-path` is
   passed straight through.
3. `ComposeEnvironment` settles the guest working directory and environment
   once, before the machine is touched. The current directory must be under
   the home directory, which the machine mounts at the same path; anything
   else fails without booting. Host variables are forwarded for Compose
   interpolation, but Docker connection settings, credential helpers, and SSH
   agent variables are dropped so the guest daemon is always the target.
4. `ComposeSocketLauncher` makes sure a forwarder is running, so published
   ports reach `localhost` even for users who never export `DOCKER_HOST`.
   A failure here is logged and the command continues.
5. `ComposeMachineManager.ensureReady` takes the initialization lock,
   creates or verifies the machine, boots it if needed, waits for its address
   and for Docker, applies the idle timeout, and releases the lock. See the
   next section.
6. `ComposeProcessRunner` runs `docker compose` as a guest process through
   the compatibility client, relaying stdin, stdout, stderr, terminal size,
   and signals, and returns its exit code. For exact help requests
   (`help`, `help <sub>`, `<sub> --help|-h`), `ComposeHelpOutput` rewrites
   `docker compose` to `container compose` on standard output as it streams.

The lock covers initialization only, so independent projects run
concurrently once the machine is ready. Native `container machine` commands
do not take part in it.

## Machine lifecycle and ownership

### Creation and boot

On first use the plugin creates a machine named `compose` from the guest
image pinned by digest in `ComposeConfiguration.defaultImage`, which the
host pulls from GHCR. CPU and memory come from `[plugin.compose]` in the
host's configuration files, read through the host's own loader. Once the
machine exists its native settings are authoritative; the plugin never
reapplies defaults, and `container machine set` is the way to change them.

Boot goes through the existing machine API. One-time user initialization
runs only for a machine this invocation created. The readiness probe runs in
the plugin's own guest context, at the root of the guest filesystem with the
daemon environment only, so readiness never depends on the working directory
of whichever process happens to boot the machine.

### Initialization lock

`ComposeMachineInitializationLock` holds a file lock in the plugin's state
directory for the duration of create, verify, boot, and readiness. Two shells
running their first command at the same time therefore produce one machine.
Do not remove the lock file while an invocation is active: another
invocation could lock a different inode and bypass the serialization.

### Ownership record and guest token

The plugin needs to know that the `compose` machine is one it created,
without duplicating the machine service's state. `OwnershipRecord` stores
only identity: the machine ID, image digest, the user who created it, and a
random UUID. It deliberately omits running state, addresses, process lists,
timestamps, and default selection, all of which the native service owns. The
record lives at `<app-root>/plugin-state/compose/machine.json`.

The same UUID is written inside the guest at
`/etc/container/compose-plugin-owner`. `ComposeMachineOwnership` checks the
machine's immutable configuration against the record before boot, and the
guest token before anything that forwards a command or changes idle
settings. Matching configuration alone never grants adoption; the token must
match too. Reading the token from a stopped machine requires booting it, but
no workload or policy change happens first.

Creation timestamps are not used for identity because the host reports the
creation time differently before and after a daemon restart. The token is
collision protection against look-alike machines, not a security boundary
against the same user or guest root.

Anything ambiguous is an error rather than a repair: a machine with no
record, a record with no machine, a corrupt record, a mismatched token, or a
crash between creation and writing both markers. The plugin never adopts,
reconfigures, or deletes a machine on its own. [operations.md](operations.md)
describes what an operator does in each case.

### Default machine

The host has no option to create a machine without making it the default
when none exists. On an empty host the `compose` machine may therefore
become the default. The plugin accepts and reports that rather than editing
daemon state afterwards.

## Running programs in the guest

`ComposeProcessClient` and `ComposeProcessIO` use the host's existing process
routes: create, start, wait, kill, and resize, with the host's own message
keys. They add no RPC protocol and need no patched host. Three behaviors are
implemented locally because the upstream client lacks them:

- File handles transferred over XPC are closed through their owner rather
  than by raw descriptor, so a descriptor is never closed twice or closed
  while still in flight.
- Waits for XPC replies are cancellable with a timeout (`AsyncReply`). Late
  replies are ignored. Cancelling a local wait stops waiting; it does not
  undo the remote operation.
- Signal handlers are registered and removed per process, and a cancelled
  guest process, or one whose start or wait failed, is terminated by
  `ProcessCancellationController`: SIGTERM, a two-second grace period, then
  SIGKILL unless exit was confirmed. Each kill request has a five-second
  reply deadline. Only a successful wait proves exit; cancelling the local
  wait does not. Delivery failures are logged, not retried forever.

If a host service stops responding entirely, the plugin can stop waiting but
cannot prove the guest process is gone. Inspect or stop the machine after
such a failure.

## The forwarder service

`ComposeForwarderService` is the background process behind `--socket-path`.
It runs `ComposeSocketForwarder` and `ComposePortForwarder` as peers and owns
what they share: a `ComposeMachineSession` that caches the machine's backing
container and serializes preparation, a connection count, and the
drain-and-exit sequence.

### Launch and replacement

`ComposeSocketLauncher` connects to `~/.local/run/docker.socket`. If nothing
answers, or the owner recorded in `docker.socket.lock` is a different plugin
build, it spawns `compose --serve-socket` in a new session and waits for the
socket to accept. It never contacts the API server, which keeps
`--socket-path` cheap enough for a shell profile. The forwarder holds an
exclusive `flock` on the lock file, so concurrent shells start exactly one
instance, and only the lock holder removes a stale socket. It refuses to
replace a regular file or a socket something else is listening on.

On SIGTERM the forwarder removes its socket, closes its port listeners, and
releases the lock, so a replacement can take over every endpoint at once. It
then exits when its open connections finish; a second signal stops it
immediately. This is how upgrades take effect without cutting off a running
`logs -f`.

### Docker socket

Each client connection becomes one guest process, `docker system
dial-stdio`, talking to `/etc/docker/docker.sock`. The process is created
over a fresh XPC connection so an API server restart does not break later
connections. `ComposeGuestBridge` copies between the client socket and the
guest process's stdin and stdout pipes.

Pipes, not the socket itself, are passed as the guest's stdio because of
half-closes. The runtime turns a closed stdin pipe into EOF in the guest, but
not a half-closed socket, and Docker clients half-close hijacked streams:
`exec` without `-i` does so immediately and then waits for the stream to end,
which would hang. With pipes, client EOF closes the guest's stdin, and guest
output EOF shuts down the client's read side.

The machine boots on the first request, not when the forwarder starts, and
preparation waits for the client's first byte. A connection that closes
without sending anything, such as the `--socket-path` liveness check, is a
probe and never boots the machine. The first real connection, or a retry
after process creation fails because the machine stopped, runs the normal
initialization path once for all waiting connections.

A client that closes both directions is detected with a zero-length `send`,
which fails with `EPIPE` only after a full close. The forwarder checks every
second and then ends the guest relay, which would otherwise stay open on a
quiet stream such as `events`. Ending a relay uses the same bounded SIGTERM
then SIGKILL escalation as a cancelled Compose command.

### Published ports

The same process mirrors TCP ports published in the machine onto
`127.0.0.1` and `::1`, so `localhost:8080` works as it does with Docker
Desktop.

Discovery (`ComposeGuestPortSource`) runs one long-lived watcher process in
the guest per machine boot. It reads the `-host-ip` and `-host-port` of each
`docker-proxy` command line every two seconds and prints the list at start,
on each change, and every 30 seconds. Reading processes rather than the
Docker API matters twice over: a Docker API connection counts as activity
for idle shutdown, and the runtime keeps a record of every exec process until
the machine stops, so one watcher per boot is far cheaper than one exec per
poll. Neither the ownership check nor the watcher boots a stopped machine.

While the machine is stopped the forwarder rechecks it at intervals that
double from 2 to 30 seconds, and immediately when the CLI or a Docker
connection nudges it. A watcher that cannot start, exits without reporting,
goes silent for 75 seconds, or whose wait fails counts as a failed check.
Listeners stay open until three checks in a row fail or the machine is known
to be stopped, so a transient error never drops working forwards. When the
forwarder stops reading a watcher it closes the watcher's stdin as well as
killing it, so the watcher ends on EOF even if the kill cannot be delivered.

Binding rules:

- Each port is bound on both loopback addresses or neither. When an
  unprivileged bind below 1024 is refused, the forwarder binds the wildcard
  address and closes connections from non-loopback peers.
- Listeners use `SO_REUSEADDR` so a restarted forwarder can rebind ports with
  connections still in TIME_WAIT. On macOS that option also lets a
  loopback bind overlap another socket's wildcard bind, silently splitting
  `localhost` traffic. The kernel refuses the overlap for other users, so the
  forwarder checks only this user's sockets, listing them with `libproc`
  (`proc_listpids`, `proc_pidfdinfo`) and skipping any port already held at
  a loopback-covering address. It never probes by connecting, which the
  other program would see. `netstat` is not usable: without Apple's private
  network-statistics entitlement the kernel returns an empty table.
- Skipped ports are logged once and retried on every watcher report.

Each accepted connection is relayed by a small `bash` script in the guest,
over process stdio, not over the machine's network address. The host cannot
always reach that address (a firewall can block the vmnet bridge), and a port
published on `127.0.0.1` in the guest is only reachable from inside anyway.
The script opens the connection with `/dev/tcp`, then runs two `socat -u`
copies: one from stdin to the server, which shuts down its sending side at
the client's EOF, and one from the server to stdout. The script exits when
the server-to-client copy ends, because the runtime closes the host's output
pipe only on process exit. A single `socat` cannot do this: it either waits
for both directions, holding a close-delimited reply open, or exits a timeout
after the first EOF, cutting off a half-closed client's reply. A wildcard
publish is reached on the guest loopback; a port bound to several addresses
tries IPv4 loopback, then `::1`, then the lowest other address.

A TCP client sends the same FIN for a full close and a half-close, so the
zero-length `send` check cannot tell them apart at first. Accepted
connections enable TCP keepalive (10 seconds idle, three probes 5 seconds
apart). A fully closed client's socket expires after FIN_WAIT_2, the next
probe is reset, and the check fails with `EPIPE`, so a silent server does
not keep the relay alive. A half-closed client still answers probes and its
relay stays open.

## Idle shutdown

`machine-image/container-compose-idle-shutdown` runs as a systemd service in
the guest and powers the machine off through systemd after Docker has had no
running containers for the configured period. It treats a connected Docker
API client (a build, pull, or push in progress, visible in `/proc/net/unix`)
as activity, and a failed probe resets the timer rather than risking a
mistaken shutdown. The interval is sampled, so the timeout is a floor, not a
deadline, and a final recheck narrows but does not eliminate the window for
a client arriving at the shutdown boundary.

The timeout lives in `/etc/container/compose-idle-shutdown.env` in the
guest. The image ships it as `0`, disabled. Each Compose invocation writes
the configured value from `[plugin.compose]` after verifying ownership, so a
changed setting takes effect on the next command. The watcher knows nothing
about Apple's separate native builder and does not measure utilization: a
running but idle application container keeps the machine up.

## Guest image

`machine-image/Containerfile` builds a Debian image with pinned versions of
Docker Engine, the Compose and Buildx plugins, systemd, and `socat` for the
relays. It enables `docker.service` and the idle-shutdown service, masks
units that need host-only devices or login sessions, and moves the daemon
socket to `/etc/docker/docker.sock` with a symlink at the usual path. It
declares no `VOLUME` for `/var/lib/docker`: the machine's root filesystem is
persistent across stop and boot, so Docker's data lives there directly and
survives everything except machine deletion.

The `Machine image` workflow builds the image for `linux/arm64` and publishes
it to GHCR, tagged `sha-<commit>` always, `edge` from `main`, and the version
from `v*` tags. The run summary prints the digest; the plugin's default pin
must be updated to it, and `CONTAINER_COMPOSE_MACHINE_IMAGE` overrides the
pin for machines not yet created. Replacing the image never changes an
existing machine.

## Deliberate boundaries

The plugin stays a client of an unmodified host. It does not:

- read or edit the machine service's `state.json`, or change which machine is
  the default;
- adopt, repair, or delete a machine, or reconcile orphans after a daemon
  crash;
- install DNS configuration or per-project aliases; the host's existing
  `machine` DNS domain covers `compose.machine`;
- monitor or stop Apple's native builder;
- reuse the host's Docker configuration, credential helpers, or SSH agent;
- forward UDP, or forward anything onto non-loopback interfaces.

## Upstream interfaces

`Package.swift` pins the `apple/container` revision and exact versions of
the other dependencies; `Package.resolved` records the full graph. The plugin
relies on these upstream pieces at that revision:

- `Sources/ContainerPlugin/PluginLoader.swift`: external plugin discovery.
- `Sources/ContainerPlugin/PluginFactory.swift`: manifest and executable layout.
- `Sources/Services/MachineAPIService/Client/MachineClient.swift`: machine operations.
- `Sources/Services/ContainerAPIService/Client/ClientProcess.swift`: process routes.
- `Sources/Services/MachineAPIService/Server/MachinesService.swift`: default-machine policy.

Moving the pin is a compatibility change. Rebuild, run the unit tests, and
repeat the host checklist in [testing.md](testing.md) against a host at the
new revision.
