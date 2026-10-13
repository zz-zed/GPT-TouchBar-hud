#!/usr/bin/env python3
"""A changed input must not silently reuse a stale test module."""
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("ui_key", ROOT / "scripts/ui_test_build_key.py")
ui_key = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ui_key)


class UISharedBuildKeyTests(unittest.TestCase):
    def test_content_changes_invalidate_even_with_preserved_timestamp(self):
        with tempfile.TemporaryDirectory() as temporary:
            paths = [Path(temporary) / name for name in ("source.swift", "dependency.a", "dependency.swiftmodule", "SDKSettings.json")]
            for path in paths:
                path.write_bytes(b"original")
            original = ui_key.fingerprint({}, paths)
            for path in paths:
                before = path.stat()
                path.write_bytes(b"modified")
                os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
                self.assertNotEqual(original, ui_key.fingerprint({}, paths), path.name)
                path.write_bytes(b"original")
            added = Path(temporary) / "new.swift"
            added.write_text("new source")
            self.assertNotEqual(original, ui_key.fingerprint({}, paths + [added]))
            self.assertNotEqual(original, ui_key.fingerprint({}, paths[:-1]))

    def test_configuration_change_invalidates_and_order_is_stable(self):
        configuration = {"architecture": "arm64", "compilerVersion": "6.2.4", "sdkVersion": "26.2",
                         "compiler": "/compiler", "flags": ["-target", "arm64-apple-macosx11.0"],
                         "environment": {"TOOLCHAINS": None}}
        original = ui_key.fingerprint(configuration, [])
        self.assertEqual(original, ui_key.fingerprint(dict(reversed(list(configuration.items()))), []))
        changes = {"architecture": "x86_64", "compilerVersion": "6.4", "sdkVersion": "26.4",
                   "compiler": "/other", "flags": ["-O"], "environment": {"TOOLCHAINS": "other"}}
        for key, value in changes.items():
            self.assertNotEqual(original, ui_key.fingerprint({**configuration, key: value}, []), key)


if __name__ == "__main__":
    unittest.main()
