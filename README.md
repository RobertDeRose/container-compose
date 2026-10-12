# container-compose

An external executable plugin for Apple's `container` CLI. It runs the real
Docker Compose CLI and Docker Engine inside one persistent `container machine`.
It does not translate Compose files into Apple Container operations and does not
replace any installed Apple service.

This is the option-1 extraction from `feature/container-compose` at `b599cfb8`.
The client SDK is pinned to unmodified upstream commit
`eee7ad097079cc3b02d5309ec10160143f2d0c6a`. None of the accompanying upstream PRs
is required by this repository.

**Status:** source implementation with portable regression tests. The complete
macOS build and VM/XPC integration have not been run during this extraction.
Use the [validation checklist](docs/validation.md) before publishing a release.
The SDK pin is a compatibility target, not a claim that every released host
version supports these APIs.

## Requirements

macOS 15 or newer, Swift 6.2 or newer, and an installed/running `container` host
with the machine APIs present at the pinned baseline. VM/network support remains
subject to that host's requirements. Build and operate the plugin as your normal
login user, not as root. The installer requests elevated privileges only for
copying files into a protected installation prefix.

The guest image is built from `machine-image/` and published for `linux/arm64`
to `ghcr.io/robertderose/container-compose-machine`. The plugin pins its default
by digest (`ComposeConfiguration.defaultImage`), and the host pulls it when the
machine is first created. Existing images and machines are reused. Another
compatible image can be selected with `CONTAINER_COMPOSE_MACHINE_IMAGE`, for
example one built locally:

```bash
container build --file machine-image/Containerfile --tag compose-machine:dev machine-image
export CONTAINER_COMPOSE_MACHINE_IMAGE=compose-machine:dev
```

The `Machine image` GitHub Actions workflow publishes the image. It runs on
pushes to `main` that change `machine-image/` (tagged `edge`), on `v*` tags
(tagged with the version), and manually for any branch. Every image is also
tagged `sha-<commit>`, and the run summary prints the digest. After changing
`machine-image/`, publish it and update the pinned digest.

## Build and install

```bash
container system start
make test
make install
container compose --help
```

`make install` builds and stages the executable, asks the
running host for its installation root, and installs only:

```text
<install-root>/libexec/container-plugins/compose/
├── config.toml
└── bin/compose
```

The external plugin loader discovers this layout. No daemon registration or
host service replacement is performed. Root help/plugin discovery still depends
on the installed host's behavior and availability.

To specify the installation root explicitly:

```bash
make install PREFIX=/usr/local
```

Do not assume `/usr/local` for every installation. The default installer uses
`compose --install-path`, which reads the running host's reported root. For a
versioned package-manager prefix, reinstall after a host upgrade that changes
that root.

The installer refuses to overwrite an existing plugin by default. After
reviewing an upgrade, replace an installation owned by this repository with:

```bash
make install REPLACE=1
```

To produce an archive containing the executable, manifest, and licenses, run
`make package`. The archive is architecture-specific; it is not a
universal binary. Local builds are ad-hoc signed by default. Setting
`CODE_SIGN_IDENTITY` changes signing; notarization and release hosting are not
configured. A source bundle is not a prebuilt installer.

## Use

Run from a project under your macOS home directory:

```bash
container compose up -d
container compose ps
container compose logs -f
container compose exec api sh
container compose down
```

All projects share a machine named `compose`. Use distinct Compose project
names where appropriate. The home directory is mounted read-write at the same
path, and project environment variables are forwarded for interpolation. Bind
sources outside the shared home are not supported by this wrapper. Host Docker
connection settings, host credential-helper configuration, and SSH agent
forwarding are deliberately not reused.

Arguments become opaque after forwarding starts. A guest program's `--help`,
`-h`, `--socket-path`, or `--completions` is not interpreted by this wrapper.
`container compose --help` shows plugin help; `container compose up --help`
executes Compose help inside the machine and rewrites `docker compose` to
`container compose` in its standard output. Only the exact forms `help`,
`help <subcommand>`, and `<subcommand> --help|-h` are rewritten. `--completions bash`, `zsh`, and `fish`
produce static completion scripts without booting a VM.

Docker images, named volumes, networks, and build cache remain in the persistent
machine filesystem across shutdown. `compose down` does not stop the VM.

```bash
container machine ls
container machine inspect compose
container machine stop compose
container compose ps
```

The last command boots the stopped machine automatically. This plugin does not
require the proposed native `container machine start` command.

CPU and memory defaults are used when creating a machine. Existing machine
resource settings remain authoritative; change them through the native command:

```bash
container machine set -n compose cpus=8 memory=8gb
container machine stop compose
container compose ps
```

Resource changes affect all Compose projects and take effect on the next boot.
Removing the plugin files does not delete the machine. Native machine deletion
is destructive: it removes Docker data, including named volumes. Do not use it
as an installation or upgrade step.

## Configuration

Use the host's existing configuration files. Their paths are reported by
`container system status --format json`. The plugin reads the app-root file
`config/config.toml` and install-root file `etc/container/config.toml` through the
upstream configuration loader, with its environment-variable support:

```toml
[plugin.compose]
cpus = 4
memory = "4gb"
idle-shutdown-seconds = 600
```

The default idle timeout is **0**, meaning disabled. A positive timeout enables
the guest-side watcher after the next normal Compose invocation. Running Docker
containers, connected Docker API clients, and failed activity probes prevent or
reset shutdown. The timeout is sampled by the watcher; it is not an exact
shutdown deadline. This is a best-effort policy with a final recheck, not an
atomic guarantee against a newly arriving client at the shutdown boundary.

The watcher powers off the guest through systemd. It does not stop Apple's
separate native builder and does not monitor general service utilization. A
running but otherwise idle application container keeps the machine running.

## Networking and host Docker clients

TCP ports that containers publish are also forwarded to macOS `localhost`
(`127.0.0.1` and `::1`), as Docker Desktop does, while the Docker socket
forwarder described below is running. `container compose` starts it, and so does
`--socket-path`. Ports bound to the machine's loopback, such as
`127.0.0.1:4000:4000`, are forwarded too. Forwarding begins within a few
seconds of a container starting and stops when the port disappears or the
machine stops.

- Ports are mirrored only on loopback, never onto your LAN. macOS lets a normal
  user bind ports below 1024 only on all interfaces, so for those ports the
  forwarder binds all interfaces and closes connections that do not come from
  this Mac.
- A port that another program on the Mac already listens on, at `localhost` or
  on all interfaces, is skipped, so `localhost` traffic never splits between
  two programs. For example, AirPlay Receiver holds `*:5000` and `*:7000`. The
  skip is logged once and retried every 30 seconds, so forwarding starts when
  the port is freed.
- UDP is not forwarded.
- Discovery reads the guest's `docker-proxy` processes. It does not work if the
  Docker userland proxy is disabled.
- Each connection is relayed by `socat` inside the machine to the address the
  port was published on, over the same process channel as
  `container machine run`, so it works even when the Mac cannot reach the
  machine's network address.

Published ports remain reachable through the machine's address as well. The
ordinary `compose.machine` hostname can use the host's existing `machine` DNS
domain configuration. The plugin neither installs DNS configuration nor adds
wildcard project aliases.

### Host Docker socket

Host Docker clients (the `docker` CLI, IDEs, Testcontainers) can use the
machine's daemon through a Unix socket in your home directory:

```bash
# ~/.zshrc
export DOCKER_HOST="$(container compose --socket-path)"
```

`--socket-path` prints `unix://$HOME/.local/run/docker.socket`. If no forwarder
from the installed plugin is listening there, it first starts one in the
background. It does not contact the container services or boot the machine, so
it is cheap enough for a shell profile. A forwarder started by a different
plugin build is replaced, which is how upgrades take effect.

The forwarder boots the `compose` machine on the first Docker request, so idle
shutdown still applies. Each connection is relayed to
`docker system dial-stdio` inside the machine. If the machine cannot be
prepared, clients receive a Docker API error that explains why. The socket is
mode `0600`, and no TCP listener is added.

When a forwarder is replaced or sent SIGTERM, it releases the socket at once
and exits after its open connections finish, so a running `logs -f` or
`compose up` is not cut off. A second signal stops it immediately.

The forwarder logs to `~/Library/Logs/container-compose/docker-socket.log`.
To stop it, run:

```bash
kill "$(head -1 ~/.local/run/docker.socket.lock)"
```

Paths sent by host clients are resolved inside the machine. Bind mounts work
for paths under your home directory, which the machine mounts at the same path.

For direct Docker administration, use the native guest execution interface:

```bash
container machine run -n compose --root env \
    DOCKER_HOST=unix:///etc/docker/docker.sock DOCKER_CONFIG=/root/.docker \
    docker info
```

## Ownership and migration

The plugin serializes its own initialization attempts and records an ownership
UUID in its own `plugin-state/compose/machine.json` and in the guest filesystem.
It checks immutable machine configuration before boot and verifies the guest
token before forwarding commands or changing idle-shutdown settings. It does
not read or edit the daemon's `state.json`, change another machine's default, or
install orphan-recovery logic in Apple's service.

**An existing `compose` machine from the original feature branch is not adopted
automatically.** Installing this plugin does not migrate that machine or its
Docker data. See [migration and recovery](docs/migration.md) before testing on a
host that already uses the original branch.

Without an upstream creation-policy option, the first machine may become the
host's default machine. This plugin accepts and reports that host behavior
rather than silently changing daemon state.

## Repository layout

`Sources/ContainerCompose` owns the command, machine orchestration, environment
policy, the Docker socket and port forwarder, and a small client compatibility
layer. `machine-image` holds the guest image's Containerfile and idle-shutdown
service. `Sources/ComposeSupport`
contains portable identity storage and cancellable callback waiting. Apple client
libraries remain external Swift package dependencies.

See [architecture and compatibility](docs/architecture.md),
[upstream PR scope](docs/upstream-prs.md), and [validation](docs/validation.md).
Original Apache-2.0 notices are retained; this is not an Apple-supported plugin.
