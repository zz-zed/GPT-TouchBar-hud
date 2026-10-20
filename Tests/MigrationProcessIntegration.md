# Real migration process integration

Run `bash scripts/test-migration-process-integration.sh --compile-only` locally.
It compiles the test executable and records source hashes/commands, and does not
launch or register an app. The default also compiles only outside GitHub Actions.

On disposable native macOS GitHub runners the default executes the real process
suite. Python additionally requires `--execute-disposable-ci`, GitHub runner
environment markers, a native architecture and an available `gui/<uid>` domain.
Missing GUI support fails the suite; it is not silently replaced by fake launches
or marked passed. Evidence is retained under
`build/migration-integration/<arch>/<UUID>/`.

The test compiles production runtime, driver, coordinator, maintenance and
single-instance locks with `MIGRATION_PROCESS_INTEGRATION`. That compile flag
selects a separate test `AppIdentity` and a driver configured by signed test
bundle resources. The shipping identity source is excluded. The production
`automaticMigrationEnabled = false` remains unchanged; there is no environment
or preference switch that enables migration in the product.

Every case has a unique test bundle ID, preference domain/launchd label, direct
temporary root and signed application. Actual `open`, LaunchServices running-app
PID/launch date checks, codesign validation, copies, moves, helper executable,
kernel application/maintenance locks, core-ready callback and ready receipt are
used. The process suite disables autolaunch in its unique test preference domain;
reference refresh performs actual LaunchServices registration. The separate
launch-entry suite covers launchd.

Cases include normal source-to-candidate handoff; real SIGKILL of the private
helper at pending/lock-acquired, prepared, candidatePublished, candidateReady,
referencesReady, archived and committed; restart of that actual signed helper
using its validated original handoff; and a separate process contending for the
real maintenance lock. At candidateReady, both helper and candidate are killed,
and LaunchServices opens the candidate again to produce a fresh real receipt.
The normal case reopens the archived entry and verifies it forwards to the live
canonical target without initializing an archived core.

The normal case exercises the first handoff without a test pause or exit
barrier. The contention case explicitly waits for its old actors to disappear
from both the kernel and LaunchServices before orchestrating a test retry. It
also holds the new helper at the existing test checkpoint until its owner has
disappeared from those lists. Production waits for the parent's process identity
to exit, then independently rejects any remaining source/other entry reported
by LaunchServices; lagging LS state can safely defer migration for that boot.
The contention retry does not prove automatic retry or completion in the same
boot. Its real observations are retained in `maintenance-exit-barrier.json`.

Readiness mutation checks start from the genuine running candidate's message:
changed launch date with the original live PID, another live PID, changed exact
path and changed nonce must be rejected. A changed simulated boot while the
original PID/date remains live is rejected, as is a pre-boot-schema message.
These are message mutations, not a claim to have forced kernel PID reuse. The
test never synthesizes a successful readiness ACK.

Boot UUID transitions are explicitly simulated through the test root's boot
file; this is not a real reboot. The test application has a minimal signed core,
not the product's full AppDelegate, UI, account or Hooks initialization. Crashes
are real process SIGKILL events, not thrown coordinator exceptions. Final
cleanup signals only executable paths rooted in that exact unique fixture,
unregisters its test apps and removes its unique test preference domain. It
retains evidence and never opens, registers or changes the installed product.
