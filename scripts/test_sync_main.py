"""Exercise local sync against real disposable Git repositories."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("sync_main.sh").resolve()


def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args], text=True,
                                   stderr=subprocess.PIPE).strip()


class SyncMainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.origin, self.upstream, self.local = (root / n for n in ("origin", "upstream", "local"))
        for repo in (self.origin, self.upstream):
            subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(repo)],
                           check=True, capture_output=True)
        subprocess.run(["git", "clone", str(self.origin), str(self.local)],
                       check=True, capture_output=True)
        git(self.local, "config", "user.name", "Sync Test")
        git(self.local, "config", "user.email", "sync@example.com")
        git(self.local, "config", "commit.gpgsign", "false")
        git(self.local, "config", "core.hooksPath", "/dev/null")
        self.commit("shared.txt", "base\n")
        git(self.local, "remote", "add", "upstream", str(self.upstream))
        git(self.local, "push", "origin", "main")
        git(self.local, "push", "upstream", "main")
        self.base = git(self.local, "rev-parse", "HEAD")

    def commit(self, name, content):
        (self.local / name).write_text(content)
        git(self.local, "add", name)
        git(self.local, "commit", "-m", name)
        return git(self.local, "rev-parse", "HEAD")

    def sync(self):
        return subprocess.run(["bash", str(SCRIPT)], cwd=self.local,
                              text=True, capture_output=True)

    def test_fast_forwards_origin_merges_upstream_and_does_not_push(self):
        fork = self.commit("fork.txt", "fork\n")
        git(self.local, "push", "origin", "main")
        git(self.local, "checkout", "--detach", self.base)
        upstream = self.commit("upstream.txt", "upstream\n")
        git(self.local, "push", "upstream", "HEAD:main")
        git(self.local, "checkout", "main")
        git(self.local, "reset", "--hard", self.base)
        result = self.sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(git(self.local, "rev-parse", "HEAD^1"), fork)
        self.assertEqual(git(self.local, "rev-parse", "HEAD^2"), upstream)
        self.assertEqual(git(self.origin, "rev-parse", "main"), fork)

    def test_conflicts_remain_available_for_manual_resolution(self):
        self.commit("shared.txt", "fork\n")
        git(self.local, "push", "origin", "main")
        git(self.local, "checkout", "--detach", self.base)
        self.commit("shared.txt", "upstream\n")
        git(self.local, "push", "upstream", "HEAD:main")
        git(self.local, "checkout", "main")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git merge --abort", result.stderr)
        self.assertEqual(git(self.local, "diff", "--name-only", "--diff-filter=U"), "shared.txt")
        git(self.local, "rev-parse", "--verify", "MERGE_HEAD")

    def test_refuses_diverged_local_main_without_changing_it(self):
        self.commit("remote.txt", "remote\n")
        git(self.local, "push", "origin", "main")
        git(self.local, "reset", "--hard", self.base)
        local = self.commit("local.txt", "local\n")
        result = self.sync()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("diverged", result.stderr)
        self.assertEqual(git(self.local, "rev-parse", "HEAD"), local)

    def test_refuses_dirty_checkout(self):
        (self.local / "untracked.txt").write_text("work\n")
        result = self.sync()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(git(self.local, "rev-parse", "HEAD"), self.base)

    def test_refuses_feature_branch_and_detached_head(self):
        git(self.local, "checkout", "-b", "feature")
        self.assertEqual(self.sync().returncode, 2)
        git(self.local, "checkout", "--detach")
        self.assertEqual(self.sync().returncode, 2)


if __name__ == "__main__":
    unittest.main()
