# Historical updater compatibility

Run this test after building a release DMG on native macOS:

```sh
python3 scripts/test-legacy-update-compatibility.py \
  --dmg dist/GPT-TouchBar-HUD-0.1.45-arm64.dmg \
  --arch arm64 \
  --output .build/legacy-update-compatibility-arm64
```

Use `--arch x86_64` and that job's actual Intel DMG on a native Intel runner.
The output directory must not exist. It retains extracted sources, compiler and
case logs, generated test packages, isolated homes, and `summary.json`; none of
those generated files belong in Git. CI must use `actions/checkout` with
`fetch-depth: 0` so the pinned historical tag and objects are available. The test
does not fetch from the network or fall back to the current updater's sources.

`manifest.json` pins the original annotated `v0.1.38` tag object
`093cd4d159ad5db443860e01e7ed49c2aac86cf2` and its peeled source commit
`382f49390ec2cb7b50beceea44307530a862806d`. The runner checks both references,
extracts each listed file with `git show <commit>:<path>`, and checks the recorded
SHA-256 before compiling the historical sources without modifications. The tag
object hash is not a commit hash. To add or change a baseline, review the exact
historical code and its boundary assumptions before updating this manifest.

The input is the actual DMG built by the current job. Its retained
`GPT TouchBar HUD.app` filename, `GPT HUD` display identity, bundle identifier,
strict signature, version, asset filename and native architecture are checked
before the old updater uses it. The test currently requires an upgrade from
0.1.38 and derives the target version from that DMG, rather than fixing the
target to 0.1.45.

Coverage:

- Original stable release decoding, version discovery and trusted GitHub asset
  selection, followed by original download, size/SHA-256 checks, readonly DMG
  mounting, bundle/version/signature/architecture/minimum-OS checks and copy.
- A correct real DMG; a wrong expected archive digest; a mismatched release
  version; and a deliberately modified signed resource packaged with a correct
  archive digest. Negative results must fail at their expected validation step.
- The old updater copies its installer from the old harness's `Bundle.main`.
  Its staged bytes must equal the pinned historical installer; the test executes
  that staged script, not the install script shipped inside the new DMG.
- Historical receipt primitives accept the retained old target path and reject
  a `GPT HUD.app` path, wrong identity and wrong version. They also accept an old
  version restoration receipt. The historical path whitelist is unmodified.
- Original shell path/owner/context validation, liveness checks, state writes,
  moves, old-version retention and rollback under isolated `HOME/Applications`.
  Old and new file bytes, modes, symlinks and strict signatures are checked after
  both successful replacement and forced new-launch failure with restoration.

Boundaries:

- Release metadata is synthetic, with the historical repository/tag/asset URL
  structure. Only after original trusted selection does the harness substitute
  loopback transport URLs. This does not test live GitHub API or download access.
- The installed old target is an inert, newly compiled version fixture, never
  represented as an original historical application binary and never launched.
- A sleep-only progress helper exercises original helper liveness without UI.
  The callback stops the old updater at `installing/waitingForExit` before its
  installer process is spawned. The test checks that no installer process/log,
  installer lock or backup appeared in that preparation session.
- Separate shell cases override only OS launch, launch confirmation and pause.
  The historical installer validation and filesystem behavior stay unchanged.
  The direct receipt tests exercise the original functions using supplied bundle
  arguments; they do not prove the full new app calls those functions on startup.
- Full app startup, real process handoff/exit, real launch receipts, real installed
  preferences/LaunchAgents/hooks and macOS 11 runtime remain outside this test.
  No installed user application or configuration is changed.

Each download case owns a fresh process group. Its `finally` terminates only
that group, detaches only exact channel mount paths inside that case's isolated
home, and records `cleanup.json` after checking that neither remains. A controlled
timeout case mounts the real DMG and starts a sleep child, then exercises the
same cleanup path. Generated evidence and application copies are retained.
