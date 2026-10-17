<p align="center">
  <img src="docs/assets/container-compose-icon.png" alt="container-compose-plugin" width="160">
</p>

# container-compose-plugin

`container compose` brings Docker Compose to Apple's [`container`](https://github.com/apple/container)
CLI on macOS. It is an external plugin: once installed, `container compose up`
works the way `docker compose up` does, with the real Docker Engine and
Docker Compose CLI running inside one persistent `container machine` Linux VM.

```bash
cd ~/projects/my-app
container compose up -d
container compose ps
```

The plugin does not translate Compose files into Apple Container operations and
does not replace or patch any installed Apple service. It is a thin, careful
client of the host's public machine and process APIs.

## Features

- **Unmodified Docker Compose.** Every Compose subcommand, flag, and file format
  works because the real `docker compose` runs the project inside the machine.
- **One persistent machine.** All projects share a machine named `compose`.
  Images, named volumes, networks, and build cache survive `compose down` and
  machine shutdowns.
- **Your home directory, same path.** The machine mounts your macOS home
  directory read-write at the same path, so relative and absolute bind mounts
  under it work unchanged.
- **Published ports on `localhost`.** TCP ports a container publishes are
  mirrored onto `127.0.0.1` and `::1`, as Docker Desktop does.
- **A Docker socket for host tools.** `container compose --socket-path` gives
  the `docker` CLI, IDEs, and Testcontainers a `DOCKER_HOST` that talks to the
  machine's daemon.
- **Native `--help` and shell completions.** Forwarded Compose help reads as
  `container compose`, and bash, zsh, and fish completions are generated
  without booting a VM.
- **Optional idle shutdown.** The machine can power itself off after Docker has
  been idle, and boots again on the next command.
- **Safe by design.** The plugin records its own ownership of the machine,
  refuses to adopt machines it did not create, and never deletes machine data
  on install, upgrade, or removal.

## Requirements

- macOS 15 or newer on Apple silicon.
- Swift 6.2 or newer, only to build the plugin from source.
- An installed and running `container` host (`container system start`). The
  plugin pins the host client SDK it is built against in `Package.swift`; that
  pin is a compatibility target, not a guarantee that every released host
  version exposes the same machine APIs.
- A normal login user. Build and operate the plugin as yourself, not as root.
  The installer asks for elevated privileges only when the installation prefix
  is protected.

## Install

Pick the route that matches how you installed `container`. Each one ends
with the same layout in the host's plugin directory, which the host's
external plugin loader discovers on its own:

```text
<install-root>/libexec/container-plugins/compose/
├── config.toml
└── bin/compose
```

No daemon is registered and no host service is replaced. The install root is
wherever `container` itself lives, which is why the route depends on how it
got there.

### container from Homebrew

```bash
brew install RobertDeRose/tap/container-compose-plugin
container system start
compose --help
```

Homebrew installs `container` automatically if it is missing and provides the
shorter `compose` command. On first use, `compose` registers the plugin with
Homebrew's host, then forwards arguments to `container compose`. No separate
registration command or sudo is needed. For example, `compose up -d` is the
same as `container compose up -d`.

The wrapper also restores registration on the next `compose` invocation after
`brew upgrade container`. Both host and plugin paths use Homebrew's stable
`opt` links. After registration, `container compose` remains available directly.

### container from mise

mise installs `container` into a versioned directory of its own, so the
plugin goes there too, with no elevated privileges:

```bash
mise use -g container 'github:RobertDeRose/container-compose-plugin[bin_path=cli,strip_components=1]'
container system start
compose --help
```

The `bin_path` and `strip_components` options put the release archive's
`cli/compose` wrapper on your `PATH`, rather than the native plugin executable.
With mise activated in your shell, `compose` forwards to the selected mise
`container`, registering the plugin on first use and again whenever either
tool changes version. For example, `compose up -d` is the same as
`container compose up -d`.

To keep `container compose` registered after `mise upgrade` without running
`compose` first, give each tool a `postinstall` step in your mise config:

```toml
# ~/.config/mise/config.toml
[tools.container]
version = "latest"
# Reinstalls the plugin into a newly installed container, if it is present.
postinstall = """
if plugin=$(mise where github:RobertDeRose/container-compose-plugin 2>/dev/null); then
    "$plugin/install.sh" --replace --prefix "$MISE_TOOL_INSTALL_PATH/Payload"
fi
"""

[tools."github:RobertDeRose/container-compose-plugin"]
version = "latest"
depends = ["container"]
strip_components = 1
bin_path = "cli"
postinstall = """
"$MISE_TOOL_INSTALL_PATH/install.sh" --replace --prefix "$(mise where container)/Payload"
"""
```

### container from Apple's installer

Apple's package installs under `/usr/local`, so the plugin directory is
protected and the installer asks for elevated privileges. Every
[GitHub release](https://github.com/RobertDeRose/container-compose-plugin/releases)
carries `container-compose-plugin-<version>-darwin-arm64.tar.gz` and its
SHA-256 checksum. The archive holds the plugin and its installer:

```bash
gh release download --repo RobertDeRose/container-compose-plugin --pattern '*-darwin-arm64.tar.gz*'
shasum -a 256 -c container-compose-plugin-*-darwin-arm64.tar.gz.sha256
tar -xzf container-compose-plugin-*-darwin-arm64.tar.gz
container system start
./compose/install.sh
container compose --help
```

Without the GitHub CLI, fetch both files from the release page with
`curl -LO`. Release builds are ad-hoc signed, not notarized, so an archive
saved by a browser carries the quarantine attribute and macOS refuses to run
the executable in it. Download with `gh` or `curl`, or clear the attribute
with `xattr -dr com.apple.quarantine compose` before installing.

The installer asks the running host for its install root. To name the root
yourself, or when the host is not running:

```bash
./compose/install.sh --prefix /usr/local
```

### From source

```bash
git clone https://github.com/RobertDeRose/container-compose-plugin.git
cd container-compose-plugin
container system start
make install
container compose --help
```

`make install` builds the `compose` executable in release mode, stages it with
its plugin manifest and licenses, and installs that layout the same way the
release installer does. `make install PREFIX=/usr/local` names the root.

Do not assume `/usr/local`. The default reads the running host's reported root
through `compose --install-path`, and a versioned prefix changes after a host
upgrade, so reinstall after one; the Homebrew `compose` wrapper and mise hooks
keep their installations registered as described above.

### Upgrade and uninstall

Homebrew and mise upgrade the plugin like any other tool. Otherwise, install
again: the installer upgrades this plugin's existing installation in place,
and refuses to overwrite any other plugin at that path.

```bash
./compose/install.sh               # from a newer release archive
make install                       # from source, after git pull
```

Upgrading replaces only the plugin files. The machine, its Docker data, and
the plugin's state are untouched. To uninstall, stop the background forwarder,
then remove the directory that `container compose --install-path` prints, or
`brew uninstall container-compose-plugin`. Removing the plugin does not
delete the machine. See [operations and recovery](docs/operations.md) for the
full procedure.

### Shell completions

The completion scripts chain to any completion already registered for
`container`, so load them after the host's own completion, for example at the
end of your shell profile:

```bash
# ~/.zshrc
eval "$(container compose --completions zsh)"
```

`bash` and `fish` are supported the same way.

## First run

Run Compose from a project under your macOS home directory:

```bash
cd ~/projects/my-app
container compose up -d
container compose logs -f
container compose exec api sh
container compose down
```

The first invocation does more than later ones. The host pulls the guest image
from GHCR, creates the `compose` machine with the default CPU and memory, boots
it, waits for Docker, and then runs your command. Later commands reuse the
running machine, and a stopped machine boots automatically.

A few rules apply to every command:

- Projects must live under your home directory. Bind sources outside it are
  not available in the machine.
- All projects share one machine, so use distinct Compose project names where
  two projects would otherwise collide.
- Your environment variables are forwarded for Compose interpolation. Host
  Docker connection settings, credential helpers, and SSH agent forwarding are
  deliberately not reused.
- After the subcommand, arguments are opaque. `container compose --help` shows
  plugin help, `container compose up --help` runs Compose help inside the
  machine, and a guest program's own `--help` is passed straight through.

### Managing the machine

`compose down` stops containers but leaves the VM running. The native machine
commands manage the VM itself:

```bash
container machine ls
container machine inspect compose
container machine stop compose
container compose ps          # boots the stopped machine again
```

The machine is created with default resources. To change them, use the native
command and restart the machine; the change applies to every project on the
next boot:

```bash
container machine set -n compose cpus=8 memory=8gb
container machine stop compose
container compose ps
```

Native machine deletion is destructive: it removes all Docker data, including
named volumes. Never use it as an install or upgrade step.

## Configuration

The plugin reads its section from the host's existing configuration files. The
app-root `config/config.toml` and install-root `etc/container/config.toml` are
both consulted through the host's own loader, including its environment
variable support. `container system status --format json` reports their
paths.

```toml
[plugin.compose]
cpus = 4
memory = "4gb"
idle-shutdown-seconds = 600
```

| Key | Default | Meaning |
| --- | --- | --- |
| `cpus` | `4` | CPUs for a machine the plugin creates. An existing machine keeps its own setting. |
| `memory` | `"4gb"` | Memory for a machine the plugin creates. At least 1 GB. |
| `idle-shutdown-seconds` | `0` | Power the machine off after Docker has been idle this long. `0` disables it. |

A positive idle timeout takes effect on the next Compose invocation. Running
containers, connected Docker API clients, and failed activity probes keep the
machine up or reset the timer. The watcher samples the timeout, so it is a
best-effort policy rather than an exact deadline, and a running but idle
application container counts as activity.

The guest image can be overridden with `CONTAINER_COMPOSE_MACHINE_IMAGE` for a
machine that has not been created yet, for example to test a local build:

```bash
container build --file machine-image/Containerfile --tag compose-machine:dev machine-image
export CONTAINER_COMPOSE_MACHINE_IMAGE=compose-machine:dev
```

Changing the image does not rebuild an existing machine.

## Ports and host Docker clients

### Published ports on localhost

While the plugin's background forwarder is running, TCP ports that containers
publish are also reachable on macOS `localhost`, both `127.0.0.1` and `::1`.
`container compose` starts the forwarder, and so does `--socket-path`.
Forwarding begins within a few seconds of a container starting and stops when
the port disappears or the machine stops.

- Ports are mirrored only on loopback, never onto your LAN. For ports below
  1024, which an unprivileged user can bind only on all interfaces, the
  forwarder binds the wildcard address and rejects non-local peers.
- A port that another program on the Mac already holds is skipped so that
  `localhost` traffic never splits between two programs. AirPlay Receiver's
  `5000` and `7000` are common examples. The skip is logged once and retried
  every 30 seconds.
- UDP is not forwarded.
- Discovery reads the guest's `docker-proxy` processes, so it requires the
  Docker userland proxy, which is enabled by default.

Published ports stay reachable through the machine's address as well. The
plugin neither installs DNS configuration nor adds wildcard project aliases.

### Host Docker socket

Host Docker clients can use the machine's daemon through a Unix socket in your
home directory:

```bash
# ~/.zshrc
export DOCKER_HOST="$(container compose --socket-path)"
```

`--socket-path` prints `unix://$HOME/.local/run/docker.socket`. If no
forwarder from the installed plugin is listening there, it starts one in the
background. It does not contact the container services or boot the machine, so
it is cheap enough for a shell profile. A forwarder started by an older plugin
build is replaced, which is how upgrades take effect.

The machine boots on the first Docker request, so idle shutdown still applies.
If the machine cannot be prepared, clients receive a Docker API error that says
why. The socket is mode `0600` and no TCP listener is added. Paths sent by
host clients resolve inside the machine, so bind mounts work for paths under
your home directory.

The forwarder logs to `~/Library/Logs/container-compose/docker-socket.log`.
When replaced or sent SIGTERM it releases the socket at once and exits after
open connections finish, so a running `logs -f` is not cut off. To stop it:

```bash
kill "$(head -1 ~/.local/run/docker.socket.lock)"
```

For direct Docker administration inside the guest:

```bash
container machine run -n compose --root env \
    DOCKER_HOST=unix:///etc/docker/docker.sock DOCKER_CONFIG=/root/.docker \
    docker info
```

## Architecture

### How a command runs

1. `container` finds the `compose` executable in its external plugin
   directory and runs it with the remaining arguments.
2. The plugin resolves the working directory and environment to forward,
   failing fast if the directory is outside the home mount. Nothing has
   touched the machine yet.
3. It starts the background forwarder if one is not already running.
4. Under a per-plugin initialization lock it inspects the `compose` machine.
   On first use it creates one from the pinned guest image; otherwise it
   verifies that the machine's immutable configuration and guest ownership
   token match its own record and refuses anything ambiguous.
5. It boots the machine if needed, waits for its address and for Docker, and
   applies the configured idle timeout.
6. It releases the lock and runs `docker compose` as a guest process, relaying
   stdin, stdout, stderr, terminal size, and signals. The lock covers
   initialization only, so independent projects run concurrently.

### Components

| Path | Role |
| --- | --- |
| `Sources/ComposePlugin` | The `compose` executable's entry point. Handles `--help` and `--version`, then hands off to the command. |
| `Sources/ContainerCompose` | The plugin library: the CLI command, configuration, environment policy, machine orchestration and ownership, the guest process runner, help rewriting, completions, and the socket and port forwarder. |
| `Sources/ContainerCompose/Compatibility` | A small client layer over the host's existing process routes. It carries descriptor ownership, cancellable reply waits, and bounded guest process termination locally so no patched host is required. |
| `Sources/ComposeSupport` | Portable pieces with no Apple dependencies: the ownership record store and cancellable callback waits. These build and test on Linux too. |
| `machine-image` | The guest image. Debian with pinned Docker Engine, Compose, and Buildx packages, plus the systemd idle-shutdown service. |
| `scripts` | Staging, installation, packaging, and the installer's own test. |
| `Tests/ComposePluginTests` | macOS tests for the plugin library, including the forwarders and process lifecycle. |
| `Tests/ComposeSupportTests` | Portable tests, including the real idle-shutdown script run against fake commands. |
| `docs` | Architecture, operations, and testing references. |

Inside the plugin library, the main pieces are:

- **ComposeCommand** parses plugin options (`--completions`, `--install-path`,
  `--socket-path`) and captures everything else for Compose.
- **ComposeEnvironment** decides which host paths and variables are forwarded.
- **ComposeMachineManager**, **ComposeMachineOwnership**, and
  **ComposeMachineInitializationLock** create, verify, boot, and serialize
  access to the shared machine.
- **ComposeProcessRunner** runs the forwarded command through the
  compatibility client.
- **ComposeForwarderService** is the background process behind
  `--socket-path`. It runs **ComposeSocketForwarder** (the Docker socket) and
  **ComposePortForwarder** (published ports) as peers, both bridging each
  connection through a guest process with **ComposeGuestBridge**.
  **ComposeGuestPortSource** watches `docker-proxy` processes for published
  ports with one long-lived guest process per boot.

### Ownership and state

The plugin keeps an ownership record at
`<app-root>/plugin-state/compose/machine.json` holding the machine ID, image
digest, user identity, and a random UUID. The same UUID is written inside the
guest at `/etc/container/compose-plugin-owner`. Before boot it checks the
machine's immutable configuration; before forwarding commands or changing the
idle policy it checks the guest token. Runtime state such as running status,
addresses, and process lists is never duplicated. The native machine service
owns it.

A machine that exists without a record, a record without a machine, a corrupt
record, or a mismatched token is an error. The plugin never adopts, repairs, or
deletes a machine on its own. Without an upstream creation-policy option, the
first machine on an empty host may become the host's default machine; the
plugin reports that rather than editing daemon state.

### Guest image

The image is built from `machine-image/` and published for `linux/arm64` to
`ghcr.io/robertderose/container-compose-machine`. The plugin pins its default
by digest in `ComposeConfiguration.defaultImage`, and the host pulls it when
the machine is first created. The `Machine image` GitHub Actions workflow
publishes on pushes to `main` that change `machine-image/` (tagged `edge`), on
`v*` tags (tagged with the version), and manually for any branch. Every image
is also tagged `sha-<commit>`, and the run summary prints the digest to pin.

### Further reading

- [Architecture](docs/architecture.md): how a command runs, machine
  ownership, the guest process client, and the forwarder designs.
- [Operations and recovery](docs/operations.md): state locations, what each
  refusal means, upgrading, and removal.
- [Testing](docs/testing.md): the test tiers, what they cover, and the
  checklist to run on a real host.

## Development

```bash
make build      # release build of the compose executable
make test       # swift test plus the installer test
make lint       # swift-format and shell syntax checks
make stage      # build and stage dist/staging/compose for install or package
make package    # architecture-specific tar.gz with checksum
```

CI runs `make test` on macOS and Linux. Linux builds only the portable
`ComposeSupport` target and its tests; the executable and Apple client
libraries require macOS. Local builds are ad-hoc signed; set
`CODE_SIGN_IDENTITY` to sign with a certificate.

Swift comes from Xcode. Node.js is needed only for the release tooling in
`package.json`; `mise install` provides the LTS release CI uses, as pinned in
`mise.toml`.

`mise install` also provides the linters that [hk](https://hk.jdx.dev/) runs
from `hk.pkl`, and installs Git hooks that fix staged files and check commit
messages with [Cocogitto](https://docs.cocogitto.io/). `mise run check` runs
every linter over the repository, as CI does; `mise run fix` applies their
fixes.

### Website

`site/` holds the project's product page: static HTML, CSS, and JavaScript
with no build step. The `Pages` workflow publishes it to GitHub Pages on pushes
to `main` that change `site/`. Preview it locally with `mise run site`, which
serves it at `http://localhost:8000`; set `PORT` to use another port.

### Releases

Every push to `main` runs the release workflow, which uses
[semantic-release](https://semantic-release.gitbook.io/) to derive the next
version from the Conventional Commits since the last tag: `fix` releases a
patch, `feat` a minor, and a `BREAKING CHANGE` footer a major. Other commit
types do not release. The workflow stamps the version into the executable with
`scripts/set-version.sh`, builds and packages it on macOS, tags `v<version>`,
and publishes a GitHub release with the archive, its checksum, and notes
generated from the commits. The checked-in version stays a development marker.
Release builds are ad-hoc signed; notarization is not configured.

The release requires the Robborg GitHub App and the `ROBBORG_CLIENT_ID`
and `ROBBORG_PRIVATE_KEY` secrets. A tag pushed with the workflow
token would trigger nothing; the app's tag starts the machine image
workflow, which tags the guest image the released plugin pins with the same
version, so `container-compose-machine:<version>` is exactly what that
release installs. The same step renders `homebrew/container-compose-plugin.rb.in`
with the version and checksum and pushes it to the
[RobertDeRose/homebrew-tap](https://github.com/RobertDeRose/homebrew-tap)
repository. The app must be installed on both repositories, and the release
token is scoped to both. Dependency updates come from Dependabot.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the conventions pull requests are
expected to follow.

## License

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for the
attributions of derived and third-party code. This project is not maintained
or endorsed by Apple.
