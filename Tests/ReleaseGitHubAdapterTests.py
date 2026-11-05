#!/usr/bin/env python3
"""Offline GitHub draft discovery, stable-ID transport and failure-boundary checks."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from urllib.parse import quote

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("release_github_adapter", ROOT / "scripts/publish-release.py")
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)

SOURCE = "a" * 40
TAG = "v1.2.3"
REPOSITORY = "owner/project"


def lookup_response(release):
    return {"data": {"repository": {"nameWithOwner": REPOSITORY, "release": release}}}


def release_identity(**overrides):
    return {"databaseId": 42, "tagName": TAG, "isDraft": True, "isPrerelease": False, **overrides}


class ReleaseGitHubAdapterTests(unittest.TestCase):
    def setUp(self):
        self.api = publisher.GitHub(REPOSITORY)

    def test_pending_draft_and_public_release_resolve_to_stable_ids(self):
        for draft in (True, False):
            with self.subTest(draft=draft), mock.patch.object(self.api, "command", return_value=json.dumps(
                    lookup_response(release_identity(isDraft=draft)))) as command:
                self.assertEqual(self.api.release(TAG), {
                    "id": 42, "tag_name": TAG, "draft": draft, "prerelease": False})
                args = command.call_args.args
                self.assertIn("graphql", args)
                self.assertIn(f"tag={TAG}", args)
                self.assertIn("owner=owner", args)
                self.assertIn("name=project", args)
                self.assertNotIn("releases?per_page=100", " ".join(args))

    def test_only_explicit_null_in_the_correct_repository_means_absent(self):
        with mock.patch.object(self.api, "command", return_value=json.dumps(lookup_response(None))):
            self.assertIsNone(self.api.release(TAG))
        malformed = [
            {}, {"data": None}, {"data": {"repository": None}},
            {"data": {"repository": {"nameWithOwner": REPOSITORY}}},
            {"data": {"repository": {"nameWithOwner": "other/project", "release": None}}},
            {**lookup_response(None), "errors": [{"message": "permission denied"}]},
            {**lookup_response(None), "errors": {}},
            {**lookup_response(None), "errors": ""},
            lookup_response([]), lookup_response({}),
        ]
        for response in malformed:
            with self.subTest(response=response), mock.patch.object(
                    self.api, "command", return_value=json.dumps(response)):
                with self.assertRaises(publisher.ReleaseError):
                    self.api.release(TAG)

    def test_wrong_tag_channel_types_or_release_ids_are_not_accepted(self):
        variants = [{"databaseId": value} for value in (None, True, 0, -1, "42")]
        variants += [{"tagName": "v9.9.9"}, {"isDraft": 1}, {"isPrerelease": None}]
        for change in variants:
            with self.subTest(change=change), mock.patch.object(self.api, "command", return_value=json.dumps(
                    lookup_response(release_identity(**change)))):
                with self.assertRaises(publisher.ReleaseError):
                    self.api.release(TAG)

    def test_lookup_transport_or_authentication_errors_do_not_establish_absence(self):
        with mock.patch.object(self.api, "command", side_effect=publisher.ReleaseError("HTTP 403")) as command:
            with self.assertRaisesRegex(publisher.ReleaseError, "HTTP 403"):
                self.api.release(TAG)
            self.assertEqual(command.call_count, 1)

    def test_direct_write_checks_exact_final_json_before_network(self):
        private = "/" + "Users/" + "synthetic-private-marker/project"
        with mock.patch.object(self.api, "command") as command:
            with self.assertRaisesRegex(publisher.ReleaseError, "public content"):
                self.api.api("pulls/1", method="PATCH", payload={"title": "Product fix", "body": private})
            command.assert_not_called()
        with mock.patch.object(self.api, "command", return_value="{}") as command:
            self.api.api("pulls/1", method="PATCH", payload={"title": "Product fix", "body": "Public description"})
            self.assertEqual(json.loads(command.call_args.kwargs["payload"])["body"], "Public description")

    def test_create_returns_post_response_and_keeps_the_existing_tag_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            notes = Path(temporary) / "notes.md"
            notes.write_text("## Tested changes\n", encoding="utf-8")
            response = {"id": 42, "tag_name": TAG, "draft": True}
            with mock.patch.object(self.api, "source", return_value=SOURCE), mock.patch.object(
                    self.api, "api", return_value=response) as request:
                self.assertIs(self.api.create(TAG, notes, SOURCE), response)
                request.assert_called_once_with("releases", method="POST", payload={
                    "tag_name": TAG, "target_commitish": SOURCE, "name": f"GPT HUD {TAG}",
                    "body": "## Tested changes\n", "draft": True, "prerelease": False})

            for source in ("b" * 40, None):
                with self.subTest(source=source), mock.patch.object(self.api, "source", return_value=source), \
                        mock.patch.object(self.api, "api") as request:
                    with self.assertRaisesRegex(publisher.ReleaseError, "Tag moved"):
                        self.api.create(TAG, notes, SOURCE)
                    request.assert_not_called()
            with mock.patch.object(self.api, "source", side_effect=publisher.ReleaseError("Tag missing")), \
                    mock.patch.object(self.api, "api") as request:
                with self.assertRaisesRegex(publisher.ReleaseError, "Tag missing"):
                    self.api.create(TAG, notes, SOURCE)
                request.assert_not_called()

    def test_creation_failure_is_not_retried(self):
        with tempfile.TemporaryDirectory() as temporary:
            notes = Path(temporary) / "notes.md"
            notes.write_text("notes", encoding="utf-8")
            with mock.patch.object(self.api, "source", return_value=SOURCE), mock.patch.object(
                    self.api, "api", side_effect=publisher.ReleaseError("Response lost")) as request:
                with self.assertRaisesRegex(publisher.ReleaseError, "Response lost"):
                    self.api.create(TAG, notes, SOURCE)
                self.assertEqual(request.call_count, 1)

    def test_by_id_is_a_single_read_and_preserves_missing_only(self):
        with mock.patch.object(self.api, "api", return_value=None) as request:
            self.assertIsNone(self.api.by_id(42))
            request.assert_called_once_with("releases/42", missing_ok=True)
        for identifier in (True, 0, -1, "42", None):
            with self.subTest(identifier=identifier), mock.patch.object(self.api, "api") as request:
                with self.assertRaises(publisher.ReleaseError):
                    self.api.by_id(identifier)
                request.assert_not_called()

    def test_only_an_http_404_can_be_a_missing_read(self):
        for status in (401, 403, 429, 500):
            with self.subTest(status=status), mock.patch.object(publisher.subprocess, "run", return_value=
                    subprocess.CompletedProcess([], 1, "", f"gh: request failed (HTTP {status})")):
                with self.assertRaises(publisher.ReleaseError):
                    self.api.command("api", "test", missing_ok=True)
        with mock.patch.object(publisher.subprocess, "run", return_value=
                subprocess.CompletedProcess([], 1, "", "gh: Not Found (HTTP 404)")):
            self.assertIsNone(self.api.command("api", "test", missing_ok=True))

    def test_upload_uses_fixed_github_host_repository_and_release_id(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "fixture #1?.dmg"
            path.write_bytes(b"synthetic bytes")
            release = {"id": 42, "upload_url": "https://untrusted.invalid/assets"}
            with mock.patch.object(self.api, "command", return_value="") as command:
                self.api.upload(release, path)
                args = command.call_args.args
                self.assertIn(f"https://uploads.github.com/repos/{REPOSITORY}/releases/42/assets"
                              f"?name={quote(path.name, safe='')}", args)
                self.assertIn("Content-Length: 15", args)
                self.assertIn("Content-Type: application/octet-stream", args)
                self.assertEqual(args[-2:], ("--input", str(path)))
                self.assertNotIn("untrusted.invalid", " ".join(args))
            with mock.patch.object(self.api, "command", side_effect=publisher.ReleaseError("HTTP 422")) as command:
                with self.assertRaisesRegex(publisher.ReleaseError, "HTTP 422"):
                    self.api.upload(release, path)
                self.assertEqual(command.call_count, 1)


if __name__ == "__main__":
    unittest.main()
