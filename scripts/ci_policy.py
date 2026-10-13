#!/usr/bin/env python3
"""Small, shared CI policy: scopes and the exact jobs required by each profile."""
from pathlib import PurePosixPath

ARCHES = ("arm64", "x86_64")
SUITES = ("data", "interface")
PROFILES = ("docs", "pr-standard", "pr-full", "main-full", "recovery-full")
FULL_PROFILES = ("pr-full", "main-full", "recovery-full")
RUNNERS = {"arm64": "macos-15", "x86_64": "macos-15-intel"}
HIGH_RISK_PREFIXES = (
    ".github/", "scripts/", "HookCore/", "HookHelper/", "ResetNewsCore/", "Resources/",
    "Sources/AppUpdate", "Sources/AppUpdater", "Sources/GitHubReleaseFetcher",
    "Sources/DiagnosticInstaller", "Sources/DiagnosticUpgrade", "Sources/AppDelegate",
    "Sources/AppIdentity", "Sources/main.swift", "Sources/Host", "Sources/SingleInstance",
    "Sources/TouchBar", "Sources/PersistentTouchBar", "Sources/SystemTouchBar",
    "Sources/Notch", "Sources/CompactHUD", "Sources/HUD",
    "Tests/AppUpdate", "Tests/GitHubRelease", "Tests/DiagnosticUpgrade",
    "Tests/Host", "Tests/SingleInstance", "Tests/TouchBar", "Tests/Notch", "Tests/HUD",
)


class PolicyError(ValueError):
    pass


def pr_event_requires_checks(payload):
    """Only understood metadata-only events may leave existing checks alone."""
    if not isinstance(payload, dict):
        return True
    action = payload.get("action")
    if action in ("labeled", "unlabeled"):
        label = payload.get("label", {})
        name = label.get("name") if isinstance(label, dict) else None
        return not isinstance(name, str) or not name or name == "ci:full"
    if action == "edited":
        changes = payload.get("changes")
        return not (isinstance(changes, dict) and changes
                    and set(changes).issubset({"title", "body"}))
    return True


def ordinary_document(path):
    return (path in ("README.md", "LICENSE", "LICENSE.md", "CHANGELOG.md")
            or (path.startswith("Documentation/") and PurePosixPath(path).suffix == ".md")
            or (path.startswith("Documentation/validation/") and PurePosixPath(path).suffix == ".json"))


def profile_for(event, paths, force_full=False, added_paths=()):
    if event == "workflow_dispatch":
        return "recovery-full"
    if event not in ("push", "pull_request"):
        raise PolicyError(f"Unsupported CI event: {event}")
    full = "main-full" if event == "push" else "pr-full"
    if force_full and event == "pull_request":
        return full
    if paths is None:
        return full
    # Only known documentation can skip native checks. Unknown files always
    # escalate, including new source/test files until their scope is reviewed.
    if all(ordinary_document(path) for path in paths):
        return "docs"
    if event == "push":
        return full
    for path in paths:
        if ordinary_document(path):
            continue
        if (path in ("Package.swift", "RELEASE_NOTES.md")
                or path.startswith(HIGH_RISK_PREFIXES) or path in added_paths):
            return full
        if not (path.startswith(("Sources/", "Tests/")) and path.endswith(".swift")):
            return full
    return "pr-standard"


def arches_for(profile):
    if profile not in PROFILES:
        raise PolicyError(f"Unknown CI profile: {profile}")
    return () if profile == "docs" else (ARCHES if profile in FULL_PROFILES else ("arm64",))


def matrices(profile):
    arches = arches_for(profile)
    return ({"include": [{"arch": arch, "runner": RUNNERS[arch], "suite": suite}
                         for arch in arches for suite in SUITES]},
            {"include": [{"arch": arch, "runner": RUNNERS[arch],
                          "kind": "App" if profile == "pr-standard" else "DMG"} for arch in arches]})


def required_jobs(profile):
    arches = arches_for(profile)
    kind = "App" if profile == "pr-standard" else "DMG"
    return ("Validate source revision",) + tuple(
        f"Regression ({arch}, {suite})" for arch in arches for suite in SUITES
    ) + tuple(f"Build {kind} ({arch})" for arch in arches)


def validate_jobs(jobs, names, run_id, attempt):
    if (not isinstance(jobs, list) or not all(isinstance(job, dict) for job in jobs)
            or type(run_id) is not int or run_id <= 0 or type(attempt) is not int or attempt <= 0):
        raise PolicyError("Missing job collection or invalid run identity")
    for name in names:
        found = [job for job in jobs if job.get("name") == name]
        if len(found) != 1:
            raise PolicyError(f"Missing or duplicate required job: {name}")
        job = found[0]
        if (job.get("run_id") != run_id or job.get("run_attempt") != attempt
                or job.get("status") != "completed" or job.get("conclusion") != "success"):
            raise PolicyError(f"Required job did not succeed in run {run_id}, attempt {attempt}: {name}")
