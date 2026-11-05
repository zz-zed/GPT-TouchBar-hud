"""Validate an explicitly trusted, offline-reviewed historical source mapping."""
import hashlib
import json
from pathlib import Path
import re

from release_metadata import ARCHES, asset_name, require, sha, validate_tag


FINGERPRINT_ALGORITHM = "sha256-path-mode-type-gitblob-lines-v1"
PRODUCTION_SCOPE = {
    "prefixes": ["Sources/", "HookCore/", "HookHelper/", "ResetNewsCore/", "Resources/"],
    "exact": sorted([
        "Package.swift", "scripts/diagnostic-source-identity.py", "scripts/build-app.sh",
        "scripts/hook-core-build.sh", "scripts/reset-news-core-build.sh",
        "scripts/core_library_build_key.py", "scripts/swift-module-cache.sh",
        "scripts/package-dmg.sh", "scripts/ci-timing.sh",
    ]),
}
ENGINEERING_SCOPE = {
    "prefixes": PRODUCTION_SCOPE["prefixes"] + ["Tests/", "scripts/", ".github/workflows/"],
    "exact": sorted([".gitignore", "LICENSE", "Makefile", "Package.swift"]),
    "attribution_basenames": {
        "case_insensitive_prefixes": ["license", "licence", "copying"],
        "case_insensitive_exact": ["notice", "notice.txt", "notices", "notices.txt", "thirdpartynotices.txt"],
    },
}


def fields(value, expected, description):
    require(isinstance(value, dict) and set(value) == set(expected),
            f"Source map {description} has missing or unexpected fields")


def digest(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value),
            "Source map SHA-256 is invalid")
    return value


def positive_integer(value):
    require(type(value) is int and value > 0, "Source map ID, size or count is invalid")


def validate_input_proof(proof, entry):
    fields(proof, ["algorithm", "old_commit", "new_commit", "old_tag_object", "new_tag_object",
                   "production", "protected_engineering"], "input proof")
    require(proof["algorithm"] == FINGERPRINT_ALGORITHM, "Source map input proof algorithm is unsupported")
    require(proof["old_commit"] == entry["original_source_sha"]
            and proof["new_commit"] == entry["rewritten_source_sha"]
            and proof["old_tag_object"] == entry["original_tag_object"]
            and proof["new_tag_object"] == entry["rewritten_tag_object"],
            "Source map input proof belongs to different tag or source identities")
    for name, scope in [("production", PRODUCTION_SCOPE), ("protected_engineering", ENGINEERING_SCOPE)]:
        layer = proof[name]
        fields(layer, ["scope", "old", "new"], "input proof layer")
        require(layer["scope"] == scope, "Source map input proof scope is incomplete or unsupported")
        for side in ["old", "new"]:
            fields(layer[side], ["file_count", "sha256"], "input proof digest")
            positive_integer(layer[side]["file_count"])
            digest(layer[side]["sha256"])
        require(layer["old"] == layer["new"], "Source map input proof shows changed build inputs")
    require(proof["protected_engineering"]["old"]["file_count"] >= proof["production"]["old"]["file_count"],
            "Source map engineering proof does not contain all production inputs")


def unique_keys(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Source map contains duplicate JSON keys")
        result[key] = value
    return result


def load_source_map(path):
    """Load a caller-trusted map; hashes attest its input identity, not its author."""
    path = Path(path)
    require(path.is_file() and not path.is_symlink(), "Source map must be a regular file")
    data = path.read_bytes()
    document = json.loads(data.decode("utf-8"), object_pairs_hook=unique_keys)
    fields(document, ["schema_version", "repository", "releases"], "document")
    require(type(document["schema_version"]) is int and document["schema_version"] == 1,
            "Source map schema is unsupported")
    repository = document["repository"]
    require(isinstance(repository, str) and re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository),
            "Source map repository is invalid")
    releases = document["releases"]
    require(isinstance(releases, list) and releases, "Source map has no supported release entries")
    entries, identifiers = {}, set()
    for entry in releases:
        fields(entry, ["tag", "release_id", "original_tag_object", "original_source_sha",
                       "rewritten_tag_object", "rewritten_source_sha", "assets", "input_proof"], "release entry")
        tag = entry["tag"]
        require(isinstance(tag, str), "Source map version tag is invalid")
        validate_tag(tag, tag.removeprefix("v"))
        positive_integer(entry["release_id"])
        require(tag not in entries and entry["release_id"] not in identifiers, "Source map repeats a release or tag")
        for key in ["original_tag_object", "original_source_sha", "rewritten_tag_object", "rewritten_source_sha"]:
            sha(entry[key])
        validate_input_proof(entry["input_proof"], entry)
        assets = entry["assets"]
        require(isinstance(assets, list) and len(assets) == 4,
                "Source map requires the original four public assets, including build-manifest.json")
        names, asset_ids = set(), set()
        for asset in assets:
            fields(asset, ["id", "name", "size", "sha256"], "asset")
            positive_integer(asset["id"])
            positive_integer(asset["size"])
            require(isinstance(asset["name"], str) and asset["name"] not in names and asset["id"] not in asset_ids,
                    "Source map asset identity is invalid or duplicate")
            digest(asset["sha256"])
            names.add(asset["name"])
            asset_ids.add(asset["id"])
        expected = {asset_name(tag[1:], arch) for arch in ARCHES} | {"SHA256SUMS.txt", "build-manifest.json"}
        require(names == expected, "Source map asset names do not match its release tag")
        entries[tag] = entry
        identifiers.add(entry["release_id"])
    return {"repository": repository, "entries": entries, "sha256": hashlib.sha256(data).hexdigest()}


def select_mapping(source_map, repository, tag):
    require(source_map["repository"] == repository, "Source map repository mismatch")
    require(tag in source_map["entries"],
            "Source map does not support this release; a pinned public build manifest is required")
    return source_map["entries"][tag]


def mapped_build_source(source_map, repository, tag, release, current_tag, records):
    """Keep the old build source only for this exact mapped tag and original assets."""
    entry = select_mapping(source_map, repository, tag)
    require(isinstance(current_tag, dict) and current_tag.get("ref") == f"refs/tags/{tag}"
            and current_tag.get("kind") == "tag"
            and current_tag.get("object_sha") == entry["rewritten_tag_object"]
            and current_tag.get("commit_sha") == entry["rewritten_source_sha"],
            "Source map does not match the current annotated tag identity")
    require(type(release.get("id")) is int and release["id"] == entry["release_id"]
            and release.get("tag_name") == tag, "Source map release identity mismatch")
    expected = {asset["name"]: asset for asset in entry["assets"]}
    assets = release.get("assets")
    require(isinstance(assets, list) and len(assets) == len(expected)
            and {asset.get("name") for asset in assets} == set(expected) == set(records),
            "Source map public asset set mismatch")
    for asset in assets:
        pinned = expected[asset["name"]]
        record = records[asset["name"]]
        require(type(asset.get("id")) is int and asset["id"] == pinned["id"], "Source map public asset ID mismatch")
        require(record["bytes"] == pinned["size"] and record["sha256"] == pinned["sha256"],
                "Source map original public asset digest or size mismatch")
    return entry["original_source_sha"]
