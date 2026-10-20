# Earliest updater model compatibility

`scripts/test-earliest-update-contract.py` extracts the unchanged `Sources/AppUpdateModels.swift` from the pinned v0.1.22 Git commit and compiles it with `main.swift`. It verifies the annotated tag object, peeled commit and model blob before compilation. It uses supplied checksum text and synthetic Release metadata; it makes no network requests and never launches or installs an application.

Example (choose a new output directory on each run):

```sh
python3 scripts/test-earliest-update-contract.py --version 0.1.45 --arch arm64 \
  --checksums .build/rename-compatibility/artifacts/SHA256SUMS.txt \
  --output .build/earliest-update-contract/run-1
```

`evidence.json` records Git identities, extracted source and harness hashes, compiler version, commands, results and limitations. A missing or changed historical Git object fails instead of fetching or silently substituting current code.

The v0.1.22 model accepts the retained `GPT-TouchBar-HUD-{version}-{architecture}.dmg` and `SHA256SUMS.txt` assets from the original repository. Its actual updater separately verifies DMG SHA256 bytes, mounted application identity/version, strict signature, architecture and minimum macOS, then copies `install-update.sh` from the old running application's `Bundle.main`. The installer targets the existing `GPT TouchBar HUD.app` path and treats `open` success as launch success. Those operations are **not executed by this model test**.

v0.1.38 retains the package checks but adds a separate progress helper, a private per-update context, an installer session argument and `launch.json` acknowledgment. It requires the new application to acknowledge the same target path, session and version; successful `open` without that acknowledgment becomes `launchUnconfirmed`. The historical v0.1.38 fixture covers a different layer and must be reported separately. Neither model evidence nor simulated launch/receipt proves a complete real application upgrade.

`legacy` in `AppIdentity` refers to the original `TouchBarCodexToken` identity. It is distinct from the retained GPT TouchBar HUD updater contract and the current GPT HUD display-name change.
