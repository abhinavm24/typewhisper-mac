#!/usr/bin/env python3
"""Exercise build requests against a real local Git remote; main must stay untouched."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RequestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.remote, self.work = root / "remote.git", root / "work"
        subprocess.run(["git", "init", "--bare", "--quiet", str(self.remote)], check=True)
        self.work.mkdir()
        self.git("init", "--quiet", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.test")
        self.git("config", "commit.gpgsign", "false")
        scripts = self.work / "scripts"
        scripts.mkdir()
        self.script = scripts / "request_personal_release.sh"
        shutil.copy2(Path(__file__).with_name(self.script.name), self.script)
        self.git("add", ".")
        self.git("commit", "-qm", "source main")
        self.main = self.git("rev-parse", "HEAD")
        self.git("remote", "add", "origin", str(self.remote))
        self.git("push", "--quiet", "origin", "main")
        self.git("checkout", "--quiet", "-b", "personal-ci")
        self.git("push", "--quiet", "-u", "origin", "personal-ci")

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.work, check=True,
                              text=True, capture_output=True).stdout.strip()

    def request(self, *args):
        return subprocess.run(["bash", str(self.script), *args], cwd=self.work,
                              text=True, capture_output=True)

    def test_request_pushes_only_ci_and_keeps_the_same_tree(self):
        tree = self.git("rev-parse", "HEAD^{tree}")
        for force in ("false", "true"):
            result = self.request(force)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.git("rev-parse", "HEAD^{tree}"), tree)
            self.assertEqual(self.git("rev-parse", "main"), self.main)
            self.assertIn(self.main, self.git("ls-remote", "origin", "refs/heads/main"))
            self.assertIn(self.git("rev-parse", "HEAD"),
                          self.git("ls-remote", "origin", "refs/heads/personal-ci"))
            self.assertEqual("[force]" in self.git("log", "-1", "--format=%s"), force == "true")

    def test_wrong_branch_dirty_tree_and_invalid_force_do_not_commit(self):
        before = self.git("rev-parse", "HEAD")
        self.assertNotEqual(self.request("invalid").returncode, 0)
        (self.work / "unfinished").write_text("user work")
        self.assertNotEqual(self.request().returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD"), before)
        self.git("checkout", "--quiet", "main")
        self.assertNotEqual(self.request().returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD"), self.main)

    def test_diverged_ci_branch_does_not_push(self):
        self.git("commit", "--allow-empty", "-qm", "local request")
        local = self.git("rev-parse", "HEAD")
        # Move the remote down a different lineage while preserving main.
        self.git("checkout", "--detach", "--quiet", self.main)
        self.git("commit", "--allow-empty", "-qm", "remote request")
        other = self.git("rev-parse", "HEAD")
        self.git("push", "--quiet", "origin", "HEAD:refs/heads/personal-ci")
        self.git("checkout", "--quiet", "personal-ci")
        self.assertNotEqual(self.request().returncode, 0)
        self.assertEqual(self.git("rev-parse", "HEAD"), local)
        self.assertIn(other, self.git("ls-remote", "origin", "refs/heads/personal-ci"))


if __name__ == "__main__":
    unittest.main()
