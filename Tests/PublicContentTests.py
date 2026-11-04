#!/usr/bin/env python3
"""Exercise the publication checker through its command-line boundary."""

from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


CHECK = Path(__file__).resolve().parents[1] / "scripts/check-public-content.py"


def chunk(kind, payload):
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def png(*extra):
    header = chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
    pixels = chunk(b"IDAT", zlib.compress(b"\x00\x00\x00\x00\xff"))
    return b"\x89PNG\r\n\x1a\n" + header + b"".join(extra) + pixels + chunk(b"IEND", b"")


class PublicContentTests(unittest.TestCase):
    def check_files(self, files):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, data in files.items():
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            file_list = root / "tracked-files"
            file_list.write_bytes(b"".join(name.encode() + b"\0" for name in files))
            result = subprocess.run([sys.executable, str(CHECK), "--root", str(root), "--files-from", str(file_list)], capture_output=True, text=True)
            for name, data in files.items():
                self.assertEqual((root / name).read_bytes(), data, "The checker must not rewrite assets")
            return result

    def test_native_interface_png_and_example_path_pass(self):
        result = self.check_files({"Marketing/interface.png": png(), "README.md": b"/Users/example/project\n"})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_publication_images_keep_their_provenance_without_echoing(self):
        marker = b"ORIGINAL_PROVENANCE_SENTINEL"
        for name in ["Marketing/interface.png", "assets/interface.png"]:
            with self.subTest(name=name):
                result = self.check_files({name: png(chunk(b"caBX", marker))})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn(marker.decode(), result.stdout + result.stderr)

    def test_application_resources_keep_their_provenance(self):
        result = self.check_files({"Resources/AppIcon.png": png(chunk(b"caBX", b"original credentials"))})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_malformed_publication_images_fail_closed(self):
        good = png()
        bad_crc = bytearray(good)
        bad_crc[-1] ^= 1
        header = chunk(b"IHDR", struct.pack(">IIBBBBB", 1, 1, 8, 6, 0, 0, 0))
        for data in [b"", b"not a PNG", good[:-1], good + b"trailing metadata", bytes(bad_crc), good[:8] + chunk(b"IEND", b""), good[:8] + header + chunk(b"IEND", b""), png(header)]:
            with self.subTest(data=data[:20]):
                result = self.check_files({"Marketing/interface.png": data})
                self.assertEqual(result.returncode, 1)
                self.assertIn("invalid PNG container", result.stderr)

    def test_text_metadata_uses_the_same_privacy_rules(self):
        for value in [b"/Users/private-personal-sentinel/project", b'{"prompt":"private-personal-sentinel","model":"example"}']:
            for kind, payload in [
                (b"tEXt", b"Description\0" + value),
                (b"zTXt", b"Description\0\0" + zlib.compress(value)),
                (b"iTXt", b"Description\0\0\0\0\0" + value),
                (b"iTXt", b"Description\0\1\0\0\0" + zlib.compress(value)),
            ]:
                with self.subTest(kind=kind, value=value[:10]):
                    result = self.check_files({"Marketing/interface.png": png(chunk(b"caBX", b"original credentials"), chunk(kind, payload))})
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("image text metadata", result.stderr)
                    self.assertNotIn("private-personal-sentinel", result.stdout + result.stderr)

    def test_duplicate_prompt_fields_cannot_hide_a_generation_record(self):
        data = png(chunk(b"tEXt", b"prompt\0private-personal-sentinel"), chunk(b"tEXt", b"prompt\0"))
        result = self.check_files({"assets/interface.png": data})
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("private-personal-sentinel", result.stdout + result.stderr)

    def test_benign_text_metadata_is_preserved(self):
        data = png(chunk(b"tEXt", b"Description\0Demonstration interface"), chunk(b"iTXt", b"Title\0\0\0\0\0" + "界面示意".encode()))
        result = self.check_files({"Marketing/interface.png": data})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_invalid_or_oversized_compressed_metadata_is_rejected(self):
        for payload in [b"Description\0\0not-zlib", b"Description\0\0" + zlib.compress(b"x" * (1024 * 1024 + 1))]:
            result = self.check_files({"assets/interface.png": png(chunk(b"zTXt", payload))})
            self.assertEqual(result.returncode, 1)
            self.assertIn("invalid or oversized text metadata", result.stderr)

    def test_international_keyword_translation_is_checked(self):
        data = png(chunk(b"iTXt", b"Description\0\0\0en\0/Users/private-personal-sentinel/project\0Example"))
        result = self.check_files({"Marketing/interface.png": data})
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("private-personal-sentinel", result.stdout + result.stderr)

    def test_metadata_limit_applies_across_chunks(self):
        part = chunk(b"zTXt", b"Description\0\0" + zlib.compress(b"x" * (600 * 1024)))
        result = self.check_files({"Marketing/interface.png": png(part, part)})
        self.assertEqual(result.returncode, 1)
        self.assertIn("invalid or oversized text metadata", result.stderr)

    def test_personal_paths_are_flagged_without_echoing(self):
        result = self.check_files({"README.md": b"/Users/private-personal-sentinel/project\n"})
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("private-personal-sentinel", result.stdout + result.stderr)

    def test_functional_test_privacy_sentinels_remain_allowed(self):
        result = self.check_files({"Tests/sample.json": b'{"path":"/Users/private-personal-sentinel/example"}'})
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
