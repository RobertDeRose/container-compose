# Operations and recovery

Where the plugin keeps its state, what its refusals mean, and how to upgrade,
remove, and recover it without losing Docker data. The design behind these
rules is in [architecture.md](architecture.md).

## State locations

| What | Where |
| --- | --- |
| Ownership record | `<app-root>/plugin-state/compose/machine.json` |
| Initialization lock | Same directory as the record |
| Guest ownership token | `/etc/container/compose-plugin-owner` inside the machine |
| Idle timeout | `/etc/container/compose-idle-shutdown.env` inside the machine |
| Host Docker socket | `~/.local/run/docker.socket` |
| Forwarder lock and PID | `~/.local/run/docker.socket.lock` |
| Forwarder log | `~/Library/Logs/container-compose/docker-socket.log` |
| Installed plugin | Printed by `container compose --install-path` |

`container system status --format json` reports the app root and the
configuration file paths.

## Refusals and what they mean

The plugin refuses rather than guesses whenever the machine's identity is in
doubt. Each message maps to one of these situations:

- **A `compose` machine exists but the plugin has no record of it.** The
  machine was created by something else, or the record was lost. The machine
  is left untouched. Inspect it with `container machine inspect compose` and
  decide whether its data matters before doing anything.
- **A record exists but the machine is gone.** The machine was deleted
  outside the plugin. The plugin will not silently create a new, empty
  Docker instance in its place.
- **The record is corrupt.** Treated as an error, not as absence.
- **The guest token does not match.** The machine matches the record's
  configuration but is not the one the plugin created. Commands and idle
  policy changes are blocked.

In every case, back up the record and any data you need before repairing.
Do not edit the machine service's state file or delete backing containers to
make an error go away.

If you intentionally deleted the machine and confirmed nothing recoverable
remains, move the ownership record aside and run a Compose command. The
plugin then creates a fresh machine. This is the only destructive choice, and
it is never automated.

If a daemon crash leaves stale resources, use the host's own recovery
procedures. The plugin does not reconcile the machine service's state.

## Upgrading

With Homebrew or mise, upgrade the plugin like any other tool; see the
README's install routes for what happens when `container` itself is upgraded.
From a newer release archive, or from source:

```bash
./compose/install.sh --replace
```

```bash
git pull
make install REPLACE=1
```

Then replace the running forwarder:

```bash
container compose --socket-path
```

Replacing the executable leaves the machine, its Docker packages, the guest
token, and the plugin state unchanged. New CPU and memory defaults apply only
to machines created afterwards; change an existing machine with
`container machine set`. A new pinned guest image likewise affects only
machines created afterwards.

The forwarder started by an older build is replaced the next time
`--socket-path` or a Compose command runs. It releases the socket and ports
immediately and exits once its open connections finish.

## Removing the plugin

1. Stop the forwarder:

   ```bash
   kill "$(head -1 ~/.local/run/docker.socket.lock)"
   ```

2. Remove the directory printed by `container compose --install-path`.
3. Remove the `DOCKER_HOST="$(container compose --socket-path)"` line and the
   completion line from your shell profile. Otherwise new shells will try, and
   fail, to start the forwarder.

The machine, its data, and the plugin state are left in place. A later
reinstall reuses them. Delete the machine only if you want its Docker data
gone:

```bash
container machine delete compose
```

## Machine resources

The machine is created with the defaults from `[plugin.compose]`. Afterwards
the native settings win:

```bash
container machine set -n compose cpus=8 memory=8gb
container machine stop compose
container compose ps
```

Changes apply on the next boot and affect every Compose project.

## Lock files

Do not delete the initialization lock while a Compose command is running.
A concurrent invocation could then lock a different inode and start a second
initialization. The forwarder's lock file is safe to inspect; its first line
is the forwarder's PID.
