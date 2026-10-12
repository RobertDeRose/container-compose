# Architecture and compatibility

## Host boundary

The plugin links public client products from `apple/container`, pinned to
`eee7ad097079cc3b02d5309ec10160143f2d0c6a`. The installed services still perform
machine creation, boot, stop, persistent storage, and network management.

Normal flow:

1. Read the running host's app/install roots and plugin configuration.
2. Acquire the plugin initialization lock.
3. Inspect `compose`; refuse ambiguous ownership or a stale local record.
4. On first use, create a native machine from the pinned guest image, which the
   host pulls from GHCR.
5. Boot through the existing machine API; perform one-time user initialization
   only for a machine created by this invocation.
6. Establish or verify the plugin's guest ownership token.
7. Wait for the machine address and Docker, then apply the idle timeout. The
   readiness probe runs with the plugin's own guest context (root of the guest
   filesystem, daemon environment only), so it does not depend on the host
   working directory of whichever process prepares the machine.
8. Release the initialization lock and execute the forwarded Compose command.
   The command's working directory and environment are settled once, at the
   CLI boundary, before the machine is touched.

The lock covers initialization, not the lifetime of a user command. Independent
Compose projects can run concurrently after initialization. Native machine
commands do not participate in this lock; this is not a daemon-wide transaction.

The plugin does not depend on `managedBy`, `runtimeProfile`, `dockerSocketPath`,
`makeDefaultIfNone`, machine ownership labels, or a new machine RPC route.
It does not replace `machine-apiserver` or the main API server.

## Process compatibility

The extracted guest process client uses the existing upstream `containerCreateProcess`,
`containerStartProcess`, `containerWait`, `containerKill`, and `containerResize`
routes and upstream message key definitions. It is not a new RPC protocol.

Three client behaviors are carried locally so that the host need not accept the
process-fix PR first:

- FileHandle ownership is closed through the owner rather than a raw `close(fd)`.
- Reply waits stop promptly on cancellation or timeout; late replies are ignored.
- Process I/O registers and cancels signal handlers and terminates a cancelled
  guest process, or one whose start or wait failed, escalating when exit has
  not been observed.

The compatibility files are derived from the submitted client code. They do not
change the behavior of Apple's already-installed server/runtime processes. The
upstream PR remains worthwhile because those processes also transfer descriptors.

Cancellation of a local reply wait does not roll back a remote operation. A
separate signal request performs guest-process termination. If a service stops
responding entirely, the plugin can stop waiting but cannot prove guest cleanup;
inspect or stop the native machine after such a failure.

## Identity, not duplicated lifecycle state

The host-side record contains machine ID, image digest, user identity, and a
random UUID. It deliberately does not persist running/stopped status, addresses,
process lists, timestamps, default selection, or task progress. Those remain
owned by the native machine service.

The UUID is also stored at `/etc/container/compose-plugin-owner` in the persistent
guest. Matching configuration alone is not permission to adopt a machine; the
token must also match. The existing guest must sometimes be booted to read that
token, but no workload command or idle-policy mutation is performed first.

The baseline daemon reports `Date()` on creation and the bundle's creation date
after restart, so equality of the API's `createdDate` is not a stable identity test.
The token avoids relying on that behavior. This is accidental-collision protection,
not a security boundary against the same host user or guest root.

A crash between creation and writing both markers leaves an ambiguous machine.
The plugin refuses automatic repair/adoption instead of inventing a second
machine lifecycle/recovery engine.

## Host Docker socket

The original branch had the machine service publish the guest socket at
`~/.local/run/docker.socket` through a `dockerSocketPath` boot setting. Upstream
machines cannot publish sockets, so the plugin serves the same path itself:

1. `--socket-path` connects to the socket. If nothing listens, or the owner
   recorded in `docker.socket.lock` is a different plugin build, it spawns
   `compose --serve-socket` in a new session and waits for the socket to accept.
   It never contacts the API server.
2. The forwarder holds an exclusive `flock` on `docker.socket.lock` for its
   lifetime, so concurrent shells start one instance. Only the lock holder
   removes a stale socket, and it refuses to replace a regular file or a socket
   that something else is listening on.
3. For each connection it creates a guest process, `docker system dial-stdio`,
   through the existing `containerCreateProcess` route, using a new XPC
   connection so an API server restart does not break later connections. The
   guest relay talks to `/etc/docker/docker.sock`.
4. The relay's stdin and stdout are pipes, and the forwarder copies between
   them and the client socket. Passing the socket itself as stdio does not
   work: the runtime ends guest stdin when a pipe closes, but not when a client
   half-closes a socket. Docker clients half-close hijacked streams, and `exec`
   without `-i` does so immediately and then waits for the stream to end, so
   it would hang. Client EOF closes the stdin pipe. Output EOF shuts down the
   client's read side.
5. The backing container ID is cached. The first connection, or a retry after a
   failed process creation (the machine stopped or rebooted), runs the normal
   initialization path once for all waiting connections. Preparation waits for
   the client's first byte: a connection that closes without sending anything,
   such as the `--socket-path` check, is a probe and never boots the machine.
6. A zero-length `send` on the client socket fails with `EPIPE` only after the
   client closes both directions. The forwarder checks this every second and
   ends the guest relay, which would otherwise stay open on a quiet stream
   such as `events`. A half-close is left alone. Ending a relay uses the same
   bounded escalation as a cancelled Compose command: SIGTERM, then SIGKILL
   two seconds later unless exit was confirmed, each request with its own
   timeout. Only a successful wait confirms exit; a failed wait ends the relay
   the same way and then closes the client's stream.
7. On SIGTERM the forwarder removes its socket, closes its port listeners, and
   then releases the lock, so a replacement can take over every endpoint at
   once. It exits when its connections finish.

## Published ports on localhost

The same forwarder process mirrors published TCP ports onto the host's
loopback addresses.

- It pings the API server and inspects the `compose` machine. If the machine
  is running and matches the ownership record, guest token included (the same
  check a Compose command makes, so a replacement machine with matching
  configuration is never forwarded; the token is read once per boot, since
  the runtime keeps a record of every exec process until the machine stops),
  it starts one long-lived guest watcher
  that reads the `-host-ip` and `-host-port` of each TCP `docker-proxy`
  command line every two seconds. The watcher prints the port list at start,
  on each change, and every 30 seconds. Neither the token check nor the
  watcher boots a stopped machine or opens a Docker client connection, so
  they do not delay idle shutdown.
- One watcher per boot, rather than one exec per check, matters because the
  runtime keeps a record of every exec process until the machine stops.
- When the watcher ends (the machine stopped or the API server restarted), the
  forwarder checks the machine again at once. While the machine is stopped it
  checks at intervals that double from 2 to 30 seconds, and immediately after
  a Docker connection or a `container compose` invocation, which connects to
  the socket without sending anything once the machine is ready.
- Only a watcher that reported and then exited (the machine stopped or the
  API server restarted) is a successful check. A watcher that cannot start,
  exits without reporting, stops reporting for 75 seconds, or whose wait fails
  counts as a failed check even if it reported first, as does an unreadable
  machine state. Repeated report-then-fail cycles therefore still reach the
  failure limit.
- When the forwarder stops reading a watcher, it closes the watcher's stdin as
  well as killing it, unless the watcher is known to have exited. The runtime
  turns the closed pipe into EOF in the guest, and the watcher exits on that
  EOF, so it ends even when a kill request cannot reach the runtime. A failed
  wait for the watcher is not treated as its exit. The listeners stay open
  until three checks in a row fail or the machine is known to be stopped, so a
  transient error does not drop working forwards.
- For each port it listens on `127.0.0.1` and `::1`, both or neither. When an
  unprivileged bind below 1024 is refused, it binds the wildcard address and
  closes connections from non-loopback peers.
- Listeners use `SO_REUSEADDR` so a restarted forwarder can rebind ports with
  recently closed connections. On macOS that also lets a specific-address bind
  overlap another socket's wildcard bind (or the reverse), silently splitting
  `localhost` traffic. The kernel refuses the overlap when the other socket
  belongs to a different user. For this user's other processes, the forwarder
  lists listening sockets with `libproc` (`proc_listpids`, `proc_pidfdinfo`)
  and skips any port held at a loopback-covering address. It never probes by
  connecting, which the other program would see. `netstat` is not used: the
  kernel filters the system socket table for processes without Apple's private
  network-statistics entitlement, and children of an ad-hoc-signed process get
  an empty table.
- Skipped ports are retried on every watcher report and logged once.
- Every connection goes through a per-connection guest relay with pipe stdio,
  bridged the same way as the Docker socket. The relay runs inside the guest, so the host never needs to
  reach the machine's address: a host firewall can block the vmnet bridge
  while process stdio still works.
- The relay connects to the address the port was published on. A wildcard
  binding (`0.0.0.0` or `::`) is reached on the guest loopback. A port bound to
  several specific addresses uses an IPv4 loopback address first, then `::1`,
  then the lowest other address.
- The relay is a `bash` script: `bash` opens the connection (`/dev/tcp`), one
  `socat -u` copies stdin to it and shuts down its sending side at the
  client's EOF, and another copies it to stdout. The script exits when the
  server-to-client copy ends. The runtime ends the host's output pipe only
  when the process exits, not when the guest closes stdout, so the relay has
  to exit when the server closes. A single `socat` cannot do both: it either
  waits for both directions, holding a close-delimited reply open while the
  client keeps writing, or exits a timeout after the first EOF, cutting off
  the reply to a client that half-closed. The client-disconnect check ends
  the relay when the client goes away; its trap stops both copies.
- A TCP client sends the same FIN for a full close as for a half-close, so the
  zero-length `send` check cannot tell them apart at first. Accepted port
  connections enable TCP keepalive (10 second idle, three 5 second probes). A
  closed client's socket expires after the FIN_WAIT_2 timeout (a minute), the
  next probe is reset, and the check then fails with `EPIPE`. A half-closed
  client still answers probes, so its relay stays open.
- Port listeners close when draining starts, so a replacement forwarder can
  bind them at once.

## Deliberate differences from the original branch

- The host Docker socket is served by a per-user forwarder started by
  `--socket-path`, not published by the machine service. See below.
- No `project.compose.machine` fallback in the main DNS handler.
- No promise that an auxiliary machine cannot become the first/default machine.
- No host-wide ownership labels or daemon startup orphan reconciliation.
- No native `machine start` command; the plugin boots through the existing API.
- No generic native-builder idleness monitor.

The original guest Containerfile and idle policy are retained. Updating the
plugin does not rebuild an existing persistent machine or update Docker inside
it. A replacement image only affects later machine creation.

## Source references

The extraction comes from `b599cfb8d9039c73f7943671081814a479212f6d` in the supplied
`container.b599cfb8.bundle`. Client compatibility changes originate in
`cf5d478913ce903e54a3cc6095d9c62ea85d9def`, with local cancellation-test improvements.

Pinned upstream interfaces:

- <https://github.com/apple/container/tree/eee7ad097079cc3b02d5309ec10160143f2d0c6a>
- `Sources/ContainerPlugin/PluginLoader.swift` — external discovery directories.
- `Sources/ContainerPlugin/PluginFactory.swift` — manifest/executable layout.
- `Sources/Services/MachineAPIService/Client/MachineClient.swift` — existing machine operations.
- `Sources/Services/ContainerAPIService/Client/ClientProcess.swift` — process routes.
- `Sources/Services/MachineAPIService/Server/MachinesService.swift` — machine/default policy.

The package pins the SDK and the directly used dependency versions recorded in
the supplied lockfile. A complete root `Package.resolved` must be generated and
committed on the first successful macOS dependency resolution; the extraction
environment could not resolve GitHub from its build container. No successful
macOS dependency resolution or binary build is claimed here.
