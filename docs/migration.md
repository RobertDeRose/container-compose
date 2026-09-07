# Migration and recovery

## Existing feature-branch installations

Do not install and invoke this plugin expecting it to take over the machine
created by the embedded Compose implementation. The new installation has a
different ownership mechanism and intentionally refuses unrecorded machines.
The external plugin directory can also shadow a bundled command with the same
name, so use an unmodified host when validating compatibility.

There is no automatic data migration or adoption command in this version.
Validate on a separate test host or a deliberately isolated `container` app root
first. Before moving an existing installation, back up the actual application
and Docker volume data and verify restoration. Changing only the guest image tag
does not migrate a persistent machine. Deleting the old machine destroys its data.

A later adoption/migration feature should explicitly validate the old image and
machine, obtain user authorization, preserve data, and write the new ownership
markers. That operation is not hidden inside ordinary `compose up`.

## Failure handling

An existing native machine with no local ownership record is left untouched.
An existing record with no machine is also refused rather than silently creating
a new empty Docker instance. A corrupt record is an error, not treated as absence.
A mismatched guest token blocks commands and policy changes.

The record is at `<app-root>/plugin-state/compose/machine.json`. The guest token is
at `/etc/container/compose-plugin-owner`. The initialization lock is in the same
plugin directory. Do not remove a lock file while a plugin invocation is active:
it could let another invocation lock a different inode and bypass serialization.

Inspect the native machine and its data before attempting recovery. Do not edit
Apple's machine-service state file or delete backing containers to make an error
disappear. Back up the record and persistent data before any operator repair.
If you intentionally deleted a machine and confirmed that no recoverable backing
machine remains, archive/remove that plugin record before asking the plugin to
create a new empty machine. The plugin does not automate this destructive choice.

If a daemon crash leaves stale/orphaned resources in an unmodified host, use that
host's supported recovery procedures. This external CLI does not install the
orphan-reconciliation implementation from the feature branch.

## Updates and removal

Replacing the installed executable/resources leaves the persistent machine,
Docker packages, guest ownership marker, and plugin state unchanged. New CPU or
memory defaults do not override existing native machine configuration.

To remove only the plugin, first obtain its exact installation directory with
`container compose --install-path` and remove that directory. Do not remove the
machine or plugin state unless data removal is intentional. A later reinstall
can reuse the existing markers and machine.
