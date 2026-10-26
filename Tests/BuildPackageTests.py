#!/usr/bin/env python3
"""Portable behavior tests for build/package/verify separation, not macOS emulation."""
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("verify_app", ROOT / "scripts/verify_app.py")
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class AppVerificationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / "Resources").mkdir()
        self.info = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())
        (self.root / "Resources/Info.plist").write_bytes(plistlib.dumps(self.info))
        self.app = self.root / "GPT TouchBar HUD.app"
        for relative in ("Contents/MacOS/GPTTouchBarHUD", "Contents/Helpers/HookEmitter"):
            binary = self.app / relative
            binary.parent.mkdir(parents=True, exist_ok=True)
            binary.write_bytes(b"fixture")
            binary.chmod(0o755)
        self.info["HUDSourceSHA256"] = "a" * 64
        self.write_info()
        self.architecture, self.minimum = "arm64", "11.0"
        self.addCleanup(patch.stopall)
        patch.object(verify, "command", side_effect=self.command).start()
        patch.object(verify.subprocess, "run", return_value=subprocess.CompletedProcess(
            [], 0, b"", b"Identifier=com.gpt-touchbar-hud.hook-emitter\n")).start()

    def write_info(self):
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps(self.info))

    def command(self, *arguments):
        if arguments[0] == sys.executable:
            return "a" * 64
        if arguments[0] == "lipo":
            return self.architecture + "\n"
        if arguments[0] == "xcrun":
            return "platform MACOS\nminos " + self.minimum + "\n"
        if arguments[0] == "codesign":
            return ""
        raise AssertionError("Unexpected native command: " + repr(arguments))

    def test_current_app_is_accepted_without_a_build(self):
        self.assertTrue(verify.verify_app(self.app, self.root, ["arm64"])["passed"])

    def test_stale_source_is_rejected(self):
        self.info["HUDSourceSHA256"] = "b" * 64
        self.write_info()
        with self.assertRaisesRegex(ValueError, "different source"):
            verify.verify_app(self.app, self.root, ["arm64"])

    def test_wrong_architecture_and_minimum_os_are_rejected(self):
        self.architecture = "x86_64"
        with self.assertRaisesRegex(ValueError, "architecture mismatch"):
            verify.verify_app(self.app, self.root, ["arm64"])
        self.architecture, self.minimum = "arm64", "12.0"
        with self.assertRaisesRegex(ValueError, "minimum macOS"):
            verify.verify_app(self.app, self.root, ["arm64"])

    def test_wrong_version_and_missing_helper_are_rejected(self):
        self.info["CFBundleVersion"] = "999999"
        self.write_info()
        with self.assertRaisesRegex(ValueError, "CFBundleVersion"):
            verify.verify_app(self.app, self.root, ["arm64"])
        self.info["CFBundleVersion"] = plistlib.loads((ROOT / "Resources/Info.plist").read_bytes())["CFBundleVersion"]
        self.write_info()
        (self.app / "Contents/Helpers/HookEmitter").unlink()
        with self.assertRaisesRegex(ValueError, "Missing executable"):
            verify.verify_app(self.app, self.root, ["arm64"])


class PackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for directory in ("scripts", "Resources", "bin", "build/GPT TouchBar HUD.app"):
            (self.root / directory).mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts/package-dmg.sh", self.root / "scripts/package-dmg.sh")
        for name in ("Info.plist", "first-open.command", "first-open-guide.txt"):
            shutil.copyfile(ROOT / "Resources" / name, self.root / "Resources" / name)
        self.app = self.root / "build/GPT TouchBar HUD.app"
        (self.app / "existing-binary").write_bytes(b"already built")
        self.write_tool("scripts/build-app.sh", "#!/bin/bash\ntouch unexpected-build\nexit 97\n")
        self.write_tool("scripts/verify-app.sh",
                        "#!/bin/bash\nif [[ -n \"$PACKAGE_VERIFY_FAIL\" ]]; then exit 45; fi\n"
                        "test -f \"$HUD_APP_DIR/existing-binary\"\n")
        self.write_tool("bin/codesign", "#!/bin/bash\necho CDHash=" + "a" * 40 + " >&2\n")
        self.write_tool("bin/hdiutil", "#!" + sys.executable + "\n"
                        "from pathlib import Path\nimport sys\n"
                        "stage=Path(sys.argv[sys.argv.index('-srcfolder')+1])\n"
                        "assert (stage/'GPT TouchBar HUD.app/existing-binary').read_bytes()==b'already built'\n"
                        "assert '" + "a" * 40 + "' in (stage/'首次打开助手.command').read_text()\n"
                        "Path(sys.argv[-1]).write_bytes(b'packaged fixture')\n")
        self.write_tool("bin/shasum", "#!" + sys.executable + "\n"
                        "import hashlib,sys\nfrom pathlib import Path\n"
                        "name=sys.argv[-1]\nprint(hashlib.sha256(Path(name).read_bytes()).hexdigest()+'  '+name)\n")
        self.environment = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"],
                                HUD_PACKAGE_ARCH="arm64", PACKAGE_VERIFY_FAIL="")
        self.environment.pop("HUD_APP_DIR", None)
        self.environment.pop("HUD_DIST_DIR", None)

    def write_tool(self, name, content):
        path = self.root / name
        path.write_text(content)
        path.chmod(0o755)

    def package(self):
        return subprocess.run(["bash", "scripts/package-dmg.sh"], cwd=self.root,
                              env=self.environment, capture_output=True, text=True)

    def test_packages_existing_app_without_building_and_writes_matching_checksum(self):
        result = self.package()
        self.assertEqual(result.returncode, 0, result.stderr)
        version = plistlib.loads((self.root / "Resources/Info.plist").read_bytes())["CFBundleShortVersionString"]
        name = f"GPT-TouchBar-HUD-{version}-arm64.dmg"
        dmg = self.root / "dist" / name
        self.assertEqual((self.root / "dist/SHA256SUMS.txt").read_text(),
                         hashlib.sha256(dmg.read_bytes()).hexdigest() + "  " + name + "\n")
        self.assertFalse((self.root / "unexpected-build").exists())
        self.assertEqual((self.app / "existing-binary").read_bytes(), b"already built")
        self.assertEqual(list((self.root / "dist").glob("dmg-stage.*")), [])

    def test_missing_app_does_not_trigger_an_implicit_build(self):
        shutil.rmtree(self.app)
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No built app", result.stderr)
        self.assertFalse((self.root / "unexpected-build").exists())

    def test_failed_app_verification_prevents_packaging(self):
        self.environment["PACKAGE_VERIFY_FAIL"] = "1"
        result = self.package()
        self.assertEqual(result.returncode, 45)
        self.assertFalse((self.root / "dist").exists())
        self.assertFalse((self.root / "unexpected-build").exists())

    def test_make_entries_do_not_duplicate_or_hide_builds(self):
        def commands(target):
            return subprocess.check_output(["make", "-n", target], cwd=ROOT, text=True)
        self.assertEqual(commands("package").count("bash scripts/build-app.sh"), 1)
        self.assertEqual(commands("check").count("bash scripts/build-app.sh"), 1)
        self.assertEqual(commands("verify").strip(), "bash scripts/verify-package.sh")
        self.assertNotIn("ci_regression", commands("full"))


if __name__ == "__main__":
    unittest.main()
