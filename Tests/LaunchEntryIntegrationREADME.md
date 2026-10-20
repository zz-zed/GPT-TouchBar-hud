# Launch entry integration

```sh
# Safe local preparation: compile, render, sign and inspect fixtures only.
bash scripts/test-launch-entry-integration.sh --compile-only

# Real execution: disposable GitHub-hosted macOS GUI runner only.
bash scripts/test-launch-entry-integration.sh --run
```

Evidence is retained under `build/launch-entry-integration/<arch>/fixture-<nonce>`.
`latest.json` identifies the latest successful preparation/execution. A real run
also writes `gui-environment.json`, `checks.json`, `control-evidence.json` and
`cleanup.json`; a compile-only result never claims those OS checks passed.

The executable compiles the real `HostAutoLaunchManager`, preferences and command
runner with the shared integration identity configuration. Production identity
and migration policy are not compiled into this disposable application. Each
fixture has a random bundle identifier, label, support directory, host process
name, executable name and private root. The real launcher source is copied with
exactly counted identity/path replacements and a temporary HOME prefix.
`launcher-rendering.json` records its original SHA-256 and verifies that reversing
those replacements restores the entire original source. `launchctl`, `pgrep`,
`defaults` and `open` are never replaced or stubbed.

Real execution verifies bootstrap/RunAtLoad without a host, the real host sentinel
and interval launch, registration refresh from the old fixture path to the new
one, manual-quit marker suppression, marker clearing after host exit, host restart,
disable and persistent opt-out, and stale-launcher preference protection. A real
`LSRegisterURL` plus explicit-URL `NSWorkspace.openApplication` checks the returned
`NSRunningApplication.bundleURL` and kernel-reported executable path.

Cleanup unloads only the configured unique label, terminates only freshly verified
fixture applications and owned sentinel children, removes only these unique
preference domains, and unregisters only the exact three fixture bundle URLs.
LaunchServices is queried again to verify those identities have no remaining
registered fixture paths. No Dock operation or global launchd environment change
is performed. Signed fixture copies and their inert nonce configuration remain as
evidence after services and processes have stopped.

This minimal NSApplication does not run the full HUD/AppDelegate. Manual quit is
represented by private marker files, and RunAtLoad is exercised by bootstrap,
not a login or reboot. Registration/explicit-URL success does not establish Dock
or alias following. Boot transitions and PID reuse belong to the separate process
migration suite; this suite does not simulate or claim a real reboot.
