# Independently useful upstream PRs

The companion patch archive contains three independent PR candidates, each based
on upstream `eee7ad097079cc3b02d5309ec10160143f2d0c6a`, not on the Compose branch.
The external plugin does not depend on any of them.

## 1. Process and XPC lifecycle correctness

Fix descriptor ownership during XPC transfers, make asynchronous reply waits
cancellable, clean up signal handlers, and terminate cancelled guest processes.
Disarm escalation after confirmed process exit. These improve ordinary container
and machine process handling, not just external Compose use.

The changes retain existing RPC routes. File-descriptor fixes apply on both
client and server sides; an external executable alone cannot fix the installed
server's descriptor lifetime. The patch includes cancellation and descriptor-
reuse regressions. It is a single PR candidate covering related lifecycle fixes,
not a request to merge Docker or managed-machine metadata.

## 2. Native machine start convenience

Add `container machine start [id]` using the existing boot/initialization helper,
with default-ID resolution, help, documentation, and tests. No lifecycle library
extraction or managed-machine change is required. `stop` already exists in this
baseline; this proposal adds `start`, not another stop implementation.

## 3. Explicit default-selection policy on creation

Add `container machine create --no-default` and the matching client/server option.
Creation can leave the default unset when creating an auxiliary machine. Existing
clients keep their current behavior. `--no-default` and `--set-default` are mutually
exclusive. The policy is applied under the existing service lock, without client
read/restore races or direct state-file edits.

This is a generic API affordance for auxiliary-machine consumers. It requires an
updated host service and is intentionally not used by the current plugin.

## Excluded

Docker images/packages, Compose orchestration, socket publication, DNS wildcard
aliases, managed-machine ownership/orphan recovery, and a generic idle-monitoring
framework are not included. The existing guest watcher remains in this repository.
It would not be a correct native BuildKit idleness implementation merely by moving
it into Apple's tree. A native-builder shutdown PR needs its own activity model
and host integration tests.

These are submission candidates, not claims of maintainer acceptance. Run the
macOS build and relevant tests before opening each PR.
