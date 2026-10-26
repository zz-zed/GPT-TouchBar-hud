#!/usr/bin/env python3
"""Exercise local optimized-library reuse with a recording compiler, on any OS."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CoreLibraryReuseTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        for directory in ("scripts", "HookCore", "ResetNewsCore", "bin", "sdk"):
            (self.root / directory).mkdir()
        for name in ("hook-core-build.sh", "reset-news-core-build.sh", "core_library_build_key.py",
                     "swift-module-cache.sh", "ci-timing.sh"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        for module in ("HookCore", "ResetNewsCore"):
            (self.root / module / "Model.swift").write_text("public struct Model {}\n")
        (self.root / "sdk/SDKSettings.json").write_text('{"Version":"26.3"}')
        (self.root / "compiler-version").write_text("Swift fixture 6.4")
        self.tool("swiftc", r'''
import json, os, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
if "--version" in sys.argv:
    print((root / "compiler-version").read_text())
else:
    args = sys.argv[1:]
    module = args[args.index("-module-name") + 1]
    with (root / "compile.jsonl").open("a") as log:
        log.write(json.dumps({"module": module, "flags": args}) + "\n")
    for flag in ("-emit-module-path", "-o"):
        output = Path(args[args.index(flag) + 1])
        output.write_text("compiled " + module)
    if os.environ.get("FAIL_CORE_MODULE") == module:
        raise SystemExit(17)
''')
        self.tool("xcrun", 'from pathlib import Path\nprint(Path(__file__).with_name("swiftc"))\n')
        self.tool("shasum", 'import hashlib,sys\nprint(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()+"  -")\n')
        self.environment = dict(os.environ, PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])
        self.environment.pop("CI_TIMING_DIR", None)
        self.environment.pop("FAIL_CORE_MODULE", None)
        self.output = self.root / ".build/distribution/arm64"

    def tool(self, name, body):
        path = self.root / "bin" / name
        path.write_text("#!" + sys.executable + "\n" + body)
        path.chmod(0o755)

    def build(self, target="arm64-apple-macosx11.0"):
        script = '''
set -euo pipefail
HOOK_CORE_BUILD_DEFERRED=1 source scripts/hook-core-build.sh
RESET_NEWS_CORE_BUILD_DEFERRED=1 source scripts/reset-news-core-build.sh
hook_core_build "$PWD/.build/distribution/arm64" "$PWD/sdk" "$1"
reset_news_core_build "$PWD/.build/distribution/arm64" "$PWD/sdk" "$1"
'''
        return subprocess.run(["bash", "-c", script, "core-reuse-test", target], cwd=self.root,
                              env=self.environment, text=True, capture_output=True)

    def records(self):
        return [json.loads(line) for line in (self.root / "compile.jsonl").read_text().splitlines()]

    def assert_build(self, target="arm64-apple-macosx11.0"):
        result = self.build(target)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_second_consumer_reuses_both_optimized_libraries(self):
        self.assert_build()
        self.assertEqual(len(self.records()), 2)
        result = self.assert_build()
        self.assertEqual(len(self.records()), 2)
        self.assertIn("Reusing optimized HookCore", result.stderr)
        self.assertIn("Reusing optimized ResetNewsCore", result.stderr)
        for record in self.records():
            flags = record["flags"]
            self.assertIn("-O", flags)
            self.assertIn("-sdk", flags)
            self.assertEqual(flags[flags.index("-target") + 1], "arm64-apple-macosx11.0")
            self.assertNotIn("-enable-testing", flags)

    def test_source_change_with_preserved_mtime_rebuilds_only_affected_module(self):
        self.assert_build()
        path = self.root / "HookCore/Model.swift"
        old = path.stat()
        path.write_text("public struct ChangedModel {}\n")
        os.utime(path, ns=(old.st_atime_ns, old.st_mtime_ns))
        self.assert_build()
        self.assertEqual([record["module"] for record in self.records()], ["HookCore", "ResetNewsCore", "HookCore"])

    def test_sdk_compiler_and_target_changes_invalidate_reuse(self):
        self.assert_build()
        (self.root / "sdk/SDKSettings.json").write_text('{"Version":"26.4"}')
        self.assert_build()
        self.assertEqual(len(self.records()), 4)
        (self.root / "compiler-version").write_text("Swift fixture 6.5")
        self.assert_build()
        self.assertEqual(len(self.records()), 6)
        self.assert_build("x86_64-apple-macosx11.0")
        self.assertEqual(len(self.records()), 8)

    def test_failed_compile_never_leaves_a_reusable_completion_record(self):
        self.assert_build()
        for module in ("HookCore", "ResetNewsCore"):
            with self.subTest(module=module):
                path = self.root / module / "Model.swift"
                path.write_text(path.read_text() + "// rebuild\n")
                self.environment["FAIL_CORE_MODULE"] = module
                self.assertEqual(self.build().returncode, 17)
                self.assertFalse((self.output / (module + ".build-configuration")).exists())
                count = len(self.records())
                del self.environment["FAIL_CORE_MODULE"]
                self.assert_build()
                self.assertEqual(len(self.records()), count + 1)
                self.assertTrue((self.output / (module + ".build-configuration")).is_file())


if __name__ == "__main__":
    unittest.main()
