# Repository publication boundary

Only application code, required resources, build/release scripts, tests, CI,
licenses, stable usage/maintenance documentation and reviewed marketing assets
belong in this repository. The exact admitted paths are registered in
`.github/public-content-paths.txt`. A new path requires a clear project purpose;
do not populate the registry automatically from untracked files.

Keep task plans, execution diaries, handoffs, raw prompts, sessions and tool I/O
outside the repository, even when they contain no sensitive information. Do not
export or archive conversations automatically. When needed, create only minimal
sanitized working material in an external temporary directory. Do not use an
ignored directory inside the repository as the default workspace for these records.

Follow CONTRIBUTING.md. Reuse the public-content checker for staged files,
outgoing commits and final PR/Release/API payloads. Direct API/MCP writes require
checking the exact final text/files immediately before sending; changing the
payload invalidates that check. Hooks cannot intercept those writes. Never bypass
checks with `--no-verify` or broad test/directory exceptions. Use synthetic fixtures.

Preserve reviewed promotional images, their normal provenance, licenses and code
attribution. Product prompt templates are allowed when needed by the application;
raw development/generation records are not. Do not edit existing bot comments as
part of repository hygiene.
