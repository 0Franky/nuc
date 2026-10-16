"""Patch upgrades must accept reviewed prefixes and preserve all unrelated edits."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("backend_builder", Path(__file__).with_name("build_input_backend.py"))
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)

class ReviewedPatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="nexus-patch-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        self.git("init", "-q")
        self.git("config", "core.autocrlf", "false")
        self.file = self.source / "config.txt"
        self.file.write_bytes(b"alpha\nbeta\n")
        self.git("add", "config.txt")
        self.git("-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false", "commit", "-qm", "test baseline")
        first = self.root / "first.patch"
        second = self.root / "second.patch"
        first.write_bytes(b"diff --git a/config.txt b/config.txt\n--- a/config.txt\n+++ b/config.txt\n@@ -1,2 +1,2 @@\n-alpha\n+alpha-safe\n beta\n")
        second.write_bytes(b"diff --git a/config.txt b/config.txt\n--- a/config.txt\n+++ b/config.txt\n@@ -1,2 +1,2 @@\n alpha-safe\n-beta\n+beta-safe\n")
        self.patches = [first, second]

    def git(self, *args):
        subprocess.run(["git", *args], cwd=self.source, check=True, capture_output=True)

    def test_clean_old_patch_and_complete_series_are_idempotent(self):
        for state in (b"alpha\nbeta\n", b"alpha-safe\nbeta\n", b"alpha-safe\nbeta-safe\n"):
            with self.subTest(state=state):
                self.file.write_bytes(state)
                builder.apply_reviewed_patches(self.source, self.patches)
                self.assertEqual(self.file.read_bytes(), b"alpha-safe\nbeta-safe\n")
                builder.apply_reviewed_patches(self.source, self.patches)

    def test_unreviewed_edit_is_rejected_and_preserved(self):
        original = b"user change\nbeta\n"
        self.file.write_bytes(original)
        with self.assertRaises(SystemExit):
            builder.apply_reviewed_patches(self.source, self.patches)
        self.assertEqual(self.file.read_bytes(), original)

    def test_staged_changes_are_rejected(self):
        self.file.write_bytes(b"user change\nbeta\n")
        self.git("add", "config.txt")
        with self.assertRaises(SystemExit):
            builder.apply_reviewed_patches(self.source, self.patches)
        self.assertEqual(self.file.read_bytes(), b"user change\nbeta\n")

    def test_untracked_changes_are_rejected_and_preserved(self):
        extra = self.source / "user-notes.txt"
        extra.write_text("keep this")
        with self.assertRaises(SystemExit):
            builder.apply_reviewed_patches(self.source, self.patches)
        self.assertEqual(extra.read_text(), "keep this")

if __name__ == "__main__":
    unittest.main()
