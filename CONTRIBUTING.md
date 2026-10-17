# Contributing

Thanks for helping improve `container compose`. This guide covers how the
project is built, tested, and reviewed so that your change lands smoothly.

## Before you start

- Open an issue first for anything beyond a small fix, so the approach can be
  agreed on before you invest in it. Bug reports should include the host's
  `container system status --format json` output and the plugin version.
- Check [docs/architecture.md](docs/architecture.md) for the boundaries the
  plugin keeps on purpose: it uses the host's public machine and process APIs,
  never edits daemon state, and never deletes machine data. Changes that cross
  those lines need discussion first.

## Development setup

You need macOS 15 or newer, Swift 6.2 or newer, and a running `container`
host. Linux can build and test only the portable `ComposeSupport` target.

```bash
container system start
make build      # release build of the compose executable
make test       # swift test plus scripts/test-install.sh
make lint       # swift-format lint and shell syntax checks
make stage      # stage dist/staging/compose
make install             # install your build, upgrading an existing one
```

Validate against an unmodified host, ideally with an isolated `container` app
root. Do not test on a host whose `compose` machine holds data you care about.

## One change per pull request

Each pull request addresses one issue or one feature. Keep unrelated fixes,
refactors, and formatting changes out of it, even when you notice them along
the way. Open a second pull request instead. Small, focused pull requests get
reviewed faster and are easier to revert if something goes wrong.

Branch from `main` and name the branch after the change, for example
`feat/docker-socket-forwarder` or `fix/port-skip-logging`.

## Commit messages

Commits follow [Conventional Commits](https://www.conventionalcommits.org/):

```text
<type>(<scope>): <summary>

<body>
```

- `type` is one of `feat`, `fix`, `test`, `docs`, `build`, `ci`, `refactor`,
  or `chore`.
- `scope` names the area touched, such as `compose`, `socket`, `help`, or
  `image`. Omit it when the change is repository-wide.
- The summary is imperative, lower case, and has no trailing period. Keep it
  under about 60 characters.
- The body explains what changed and why, wrapped at 72 columns. Describe the
  behavior, not the diff. Mention user-visible effects, compatibility
  consequences, and anything a reviewer could not infer from the code.

For example:

```text
feat(help): use the host command in forwarded Compose help

Rewrite docker compose to container compose in stdout for exact Compose
help requests. Stream output with byte-oriented line buffering rather
than capturing it with a timeout or size limit.

Leave longer invocations and guest programs' help arguments opaque.
```

Commits on `main` are signed. Signing yours is encouraged if you have a key
set up, but it is not required to contribute.

## Tests

Every behavior change ships with tests in the same pull request, and every
bug fix includes a regression test that fails without the fix.

- `Tests/ComposePluginTests` covers the plugin library on macOS: argument
  forwarding, environment policy, configuration, ownership verification, the
  socket and port forwarders, help rewriting, completions, and process
  lifecycle, signals, and cancellation.
- `Tests/ComposeSupportTests` covers the portable pieces and runs on Linux as
  well: ownership records, reply waits, and the real idle-shutdown script
  exercised with fake `docker`, `date`, and `systemctl` commands.
- `scripts/test-install.sh` exercises the installer against staged fixtures.
  Extend it when the installer's behavior changes.

Tests must be deterministic. Drive concurrency and timing through injected
fixtures and short, bounded waits rather than long wall-clock delays, as the
existing forwarder and cancellation tests do. `make test` must pass on macOS
before you open the pull request. CI runs it on both macOS and Linux and must
be green before merge.

Hosted CI does not run VM integration. If your change affects machine
creation, boot, forwarding, or idle shutdown, run the relevant parts of the
[host checklist](docs/testing.md) on a real host and say which ones in the
pull request description.

## Code style

- `make lint` must pass. Formatting follows the repository's `.swift-format`
  configuration: four-space indentation and a 180-column limit. Run
  `swift format --in-place --recursive Sources Tests` to apply it.
- Avoid force unwraps, force tries, and implicitly unwrapped optionals. Where a
  literal is known to parse, say so in a comment, as the configuration code
  does.
- Prefer early exits, one declaration per line, and explanatory comments that
  state why a non-obvious choice was made. Comments that describe runtime
  behavior of the host or Docker are especially valuable because the code
  often works around it.
- New files start with the project header:

  ```swift
  // Copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
  // SPDX-License-Identifier: Apache-2.0
  ```

  Files that contain code adapted from `apple/container` keep the original
  Apple notice and add the modifications line directly under it:

  ```swift
  // Copyright © 2026 Apple Inc. and the container project authors.
  // Modifications copyright © 2026 Robert DeRose and the container-compose-plugin contributors.
  ```

  New third-party code needs an entry in `NOTICE.md`.
- Shell scripts use `set -euo pipefail`, quote every expansion, and pass
  `bash -n`. The guest idle-shutdown script is POSIX `sh`.

## Guest image changes

Changes under `machine-image/` affect only machines created after the image
is pulled. To change the image:

1. Build it locally and point the plugin at it with
   `CONTAINER_COMPOSE_MACHINE_IMAGE` to test.
2. Run the `Machine image` workflow manually for your branch. The run summary
   prints the published digest.
3. Update the pinned digest in `ComposeConfiguration.defaultImage` in the same
   pull request so the plugin and image change together.

Keep package versions in the `Containerfile` pinned.

## Documentation

Update the documentation in the same pull request as the behavior it
describes. `README.md` is the user-facing guide. `docs/architecture.md`
explains the design, `docs/operations.md` covers state and recovery, and
`docs/testing.md` covers verification. The documentation exists so that a
contributor can understand the system before reading the code; write for
that reader.

Documentation records durable information only: behavior, contracts,
architecture, decisions, and how to operate or extend the system. Do not add
pull request numbers, commit SHAs, branch names, review notes, or the results
of a particular validation run. Those belong in the pull request and Git
history.

## Opening the pull request

The pull request template asks for a summary, the reasoning, and how you
tested. Fill it in rather than deleting it. A good description lets a reviewer
understand the change without reconstructing it from the diff.

Before requesting review, confirm that:

- The pull request addresses one issue or feature.
- Commits follow the message conventions above.
- `make test` and `make lint` pass locally and CI is green.
- Tests cover the change, and any required host validation is noted.
- Documentation is updated and contains no transient state.
- Any guest image change comes with an updated pinned digest.

Reviewers may ask you to split a pull request or to add coverage. That is
normal and not a judgement on the work.

## License

By contributing you agree that your contributions are licensed under the
Apache License 2.0, the same license as the project. See [LICENSE](LICENSE)
and [NOTICE.md](NOTICE.md).
