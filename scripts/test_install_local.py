#!/usr/bin/env python3
"""Check installer validation and dry-run isolation using mocked macOS tools."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("install_local.sh")


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.app = self.root / "source.app"
        executable = self.app / "Contents/MacOS/TypeWhisper"
        executable.parent.mkdir(parents=True)
        executable.write_text("fixture")
        executable.chmod(0o755)
        (self.app / "Contents/Info.plist").write_text("fixture")
        self.destination = self.root / "installed.app"
        self.destination.mkdir()
        (self.destination / "keep").write_text("existing installation")
        self.tool("plutil", 'case "$2" in CFBundleIdentifier) echo com.typewhisper.mac;; *) echo TypeWhisper;; esac')
        self.tool("file", "echo 'Mach-O 64-bit executable arm64'")
        self.tool("codesign", 'if [ "$1" = "-dvv" ]; then echo Authority=Test; fi')
        self.environment = dict(os.environ, PATH=str(self.bin) + os.pathsep + os.environ["PATH"])

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\n" + body + "\n")
        path.chmod(0o755)

    def invoke(self, *args):
        return subprocess.run(["bash", str(SCRIPT), *args], env=self.environment,
                              text=True, capture_output=True)

    def test_source_required(self):
        self.assertNotEqual(self.invoke().returncode, 0)

    def test_dry_run_preserves_existing_installation(self):
        result = self.invoke("--source", str(self.app), "--destination", str(self.destination), "--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no files changed", result.stdout)
        self.assertEqual((self.destination / "keep").read_text(), "existing installation")

    def test_invalid_signature_stops_before_replacement(self):
        self.tool("codesign", "exit 1")
        result = self.invoke("--source", str(self.app), "--destination", str(self.destination))
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.destination / "keep").exists())

    def test_wrong_bundle_identifier_rejected(self):
        self.tool("plutil", "echo wrong.bundle")
        result = self.invoke("--source", str(self.app), "--destination", str(self.destination))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected bundle metadata", result.stderr)
        self.assertTrue((self.destination / "keep").exists())


if __name__ == "__main__":
    unittest.main()
