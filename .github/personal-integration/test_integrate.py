import copy
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import integrate as m


def pr(number, head, **kwargs):
    row = {"number": number, "state": "open", "base": {"ref": "main"},
           "user": {"login": "abhinavm24"},
           "head": {"sha": head, "ref": f"feature-{number}", "repo": {"full_name": m.REPO}},
           "draft": True}
    row.update(kwargs)
    return row


class SelectionTests(unittest.TestCase):
    def test_all_open_prs_including_drafts_sorted_and_closed_excluded(self):
        rows = [pr(3, "a" * 40), pr(1, "b" * 40), pr(2, "c" * 40, state="closed")]
        self.assertEqual([p["number"] for p in m.select_prs(rows)], [1, 3])

    def test_foreign_pr_stops_instead_of_silent_partial_build(self):
        row = pr(4, "a" * 40)
        row["head"]["repo"]["full_name"] = "someone/fork"
        with self.assertRaisesRegex(RuntimeError, "not an owner-authored"):
            m.select_prs([row])

    def test_generated_branch_cannot_feed_itself(self):
        row = pr(1, "a" * 40)
        row["head"]["ref"] = m.BRANCH
        with self.assertRaises(RuntimeError):
            m.select_prs([row])

    def test_pagination_flattens_every_page(self):
        result = subprocess.CompletedProcess([], 0, json.dumps([[1, 2], [3]]), "")
        with patch.object(m, "run", return_value=result) as call:
            self.assertEqual(m.api("endpoint", pages=True), [1, 2, 3])
            self.assertIn("--paginate", call.call_args.args)

    def test_stale_pr_closure_or_change_stops_promotion(self):
        original = {"main": "a" * 40, "prs": m.select_prs([pr(1, "b" * 40)])}
        for changed in [{"main": "c" * 40, "prs": original["prs"]},
                        {"main": original["main"], "prs": []}]:
            with patch.object(m, "snapshot", return_value=changed):
                with self.assertRaisesRegex(RuntimeError, "changed"):
                    m.ensure_current({"inputs": original})

    def test_fingerprint_ignores_json_key_order_but_tracks_commit_changes(self):
        first = {"main": "a", "prs": []}
        self.assertEqual(m.fingerprint(first), m.fingerprint({"prs": [], "main": "a"}))
        self.assertNotEqual(m.fingerprint(first), m.fingerprint({"prs": [], "main": "b"}))

    def test_failed_or_partial_release_does_not_suppress_retry(self):
        release = {"draft": True, "prerelease": True, "tag_name": "personal-example",
                   "body": "<!-- personal-inputs:abc -->", "assets": [{"name": n} for n in m.FILES]}
        self.assertIsNone(m.completed_release([release], "abc"))
        release["draft"] = False
        self.assertEqual(m.completed_release([release], "abc"), release)
        self.assertIsNone(m.completed_release([release], "changed"))
        release["assets"] = []
        self.assertIsNone(m.completed_release([release], "abc"))

    def test_promotion_retry_and_lease(self):
        manifest = {"candidate": "a" * 40, "previous_integration": "b" * 40}
        with patch.object(m, "remote_ref", return_value="a" * 40), patch.object(m, "push") as push:
            m.promote(Path("."), manifest)
            push.assert_not_called()
        with patch.object(m, "remote_ref", return_value="c" * 40), patch.object(m, "push") as push:
            with self.assertRaisesRegex(RuntimeError, "advanced"):
                m.promote(Path("."), manifest)
            push.assert_not_called()
        with patch.object(m, "remote_ref", return_value="b" * 40), patch.object(m, "push") as push:
            m.promote(Path("."), manifest)
            self.assertIn("--force-with-lease=refs/heads/personal-integration:" + "b" * 40, push.call_args.args)


class GitAssemblyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name)
        m.git(self.path, "init", "--quiet")
        for key, value in [("user.name", "Fixture"), ("user.email", "fixture@example.test"),
                           ("commit.gpgsign", "false"), ("core.hooksPath", "/dev/null")]:
            m.git(self.path, "config", key, value)
        self.base = self.commit("shared", "base")

    def commit(self, name, text):
        (self.path / name).write_text(text)
        m.git(self.path, "add", name)
        m.git(self.path, "commit", "-qm", text)
        return m.git(self.path, "rev-parse", "HEAD")

    def test_exact_heads_and_rebuilding_after_closure(self):
        one = self.commit("first", "one")
        m.git(self.path, "checkout", "--detach", self.base)
        two = self.commit("second", "two")
        inputs = {"main": self.base, "prs": m.select_prs([pr(1, one), pr(2, two)])}
        m.assemble_tree(self.path, inputs)
        self.assertTrue(m.ancestor(self.path, one))
        self.assertTrue(m.ancestor(self.path, two))
        inputs["prs"] = inputs["prs"][1:]
        m.assemble_tree(self.path, inputs)
        self.assertFalse((self.path / "first").exists())
        self.assertEqual((self.path / "second").read_text(), "two")

    def test_already_included_dependency_is_recorded(self):
        one = self.commit("first", "one")
        two = self.commit("second", "two")
        states = m.assemble_tree(self.path, {"main": self.base, "prs": m.select_prs([pr(1, two), pr(2, one)])})
        self.assertEqual(states[1]["result"], "already-included")

    def test_conflict_stops_without_advancing_existing_branch(self):
        one = self.commit("shared", "one")
        m.git(self.path, "branch", m.BRANCH, one)
        m.git(self.path, "checkout", "--detach", self.base)
        two = self.commit("shared", "two")
        with self.assertRaisesRegex(RuntimeError, "PR #2.*"):
            m.assemble_tree(self.path, {"main": self.base, "prs": m.select_prs([pr(1, one), pr(2, two)])})
        self.assertEqual(m.git(self.path, "rev-parse", m.BRANCH), one)

    def test_empty_pr_set_builds_only_base(self):
        self.commit("extra", "extra")
        self.assertEqual(m.assemble_tree(self.path, {"main": self.base, "prs": []}), [])
        self.assertEqual(m.git(self.path, "rev-parse", "HEAD"), self.base)

    def publication_fixture(self):
        root = self.path / "publication-test"
        root.mkdir()
        remote = root / "remote.git"
        m.run("git", "init", "--bare", str(remote))
        source, assets = root / "source", root / "assets"
        source.mkdir()
        assets.mkdir()
        m.git(self.path, "bundle", "create", str(source / "candidate.bundle"), "HEAD")
        inputs = {"main": self.base, "prs": []}
        manifest = {"repository": m.REPO, "inputs": inputs, "fingerprint": m.fingerprint(inputs),
                    "candidate": self.base, "tree": m.git(self.path, "rev-parse", "HEAD^{tree}"),
                    "control_sha": self.base, "previous_integration": "", "upstream_observed": self.base,
                    "upstream_included": True, "tag": "personal-20260925-120000-run1-attempt1",
                    "run_url": "https://github.com/example/run"}
        (source / "integration-manifest.json").write_text(json.dumps(manifest))
        (assets / m.FILES[0]).write_bytes(b"disk image fixture" * 1024)
        state = {"release": None, "assets": {}, "fail_edit": False}
        original_run = m.run

        def repo(path):
            path.mkdir()
            m.git(path, "init", "--quiet")
            m.git(path, "remote", "add", "origin", str(remote))

        def command(*args, **kwargs):
            if args[0] != "gh":
                return original_run(*args, **kwargs)
            operation = args[2]
            if operation == "view":
                return subprocess.CompletedProcess(args, 0 if state["release"] else 1, "{}", "")
            if operation == "create":
                state["release"] = {"draft": True, "prerelease": True, "assets": [], "html_url": "https://example/release"}
            elif operation == "upload":
                file = Path(args[4])
                state["assets"][file.name] = file.read_bytes()
                state["release"]["assets"].append({"name": file.name})
            elif operation == "download":
                name = args[args.index("--pattern") + 1]
                destination = Path(args[args.index("--dir") + 1])
                (destination / name).write_bytes(state["assets"][name])
            elif operation == "edit":
                if state["fail_edit"]:
                    raise RuntimeError("simulated API interruption")
                state["release"]["draft"] = False
            else:
                raise AssertionError(args)
            return subprocess.CompletedProcess(args, 0, "", "")

        self.enterContext(patch.object(m, "repository", side_effect=repo))
        self.enterContext(patch.object(m, "summary"))
        self.enterContext(patch.object(m, "run", side_effect=command))
        self.enterContext(patch.object(m, "snapshot", return_value=inputs))
        self.enterContext(patch.object(m, "api", side_effect=lambda *a, **k: copy.deepcopy(state["release"])))
        return root, source, assets, manifest, state, remote

    def test_published_release_retry_verifies_without_overwriting(self):
        root, source, assets, manifest, state, remote = self.publication_fixture()
        for attempt in [1, 2]:
            m.publish(SimpleNamespace(control=self.path, source=source, assets=assets, work=root / f"work{attempt}"))
        self.assertFalse(state["release"]["draft"])
        self.assertEqual(set(state["assets"]), set(m.FILES))
        self.assertEqual(m.git(remote, "rev-parse", f"refs/heads/{m.BRANCH}"), self.base)
        state["assets"][m.FILES[0]] = b"corrupted remotely"
        with self.assertRaisesRegex(RuntimeError, "Uploaded asset differs"):
            m.publish(SimpleNamespace(control=self.path, source=source, assets=assets, work=root / "work3"))

    def test_recovers_after_branch_promotion_before_release_publication(self):
        root, source, assets, manifest, state, remote = self.publication_fixture()
        state["fail_edit"] = True
        with self.assertRaisesRegex(RuntimeError, "simulated API"):
            m.publish(SimpleNamespace(control=self.path, source=source, assets=assets, work=root / "work1"))
        self.assertTrue(state["release"]["draft"])
        self.assertEqual(m.git(remote, "rev-parse", f"refs/heads/{m.BRANCH}"), self.base)
        state["fail_edit"] = False
        m.publish(SimpleNamespace(control=self.path, source=source, assets=assets, work=root / "work2"))
        self.assertFalse(state["release"]["draft"])


if __name__ == "__main__":
    unittest.main()
