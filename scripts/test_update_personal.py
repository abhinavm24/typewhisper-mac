import hashlib
import json
from pathlib import Path
import tempfile
import unittest

import update_personal as m


def release(tag="personal-20260925-120000-run1-attempt1", date="2026-09-25T12:00:00Z", **kw):
    return dict(tag_name=tag, published_at=date, draft=False, prerelease=True,
                assets=[{"name": n} for n in m.ASSETS], **kw)


class ReleaseTests(unittest.TestCase):
    def test_picks_newest_complete_personal_prerelease(self):
        old = release()
        new = release("personal-20260925-130000-run2-attempt1", "2026-09-25T13:00:00Z")
        draft = release("personal-20260925-140000-run3-attempt1", "2026-09-25T14:00:00Z")
        draft["draft"] = True
        incomplete = release("personal-20260925-150000-run4-attempt1", "2026-09-25T15:00:00Z")
        incomplete["assets"] = []
        self.assertEqual(m.select_release([draft, old, release("v2.0"), new, incomplete]), new)

    def test_no_release_is_actionable_error(self):
        with self.assertRaisesRegex(RuntimeError, "No complete"):
            m.select_release([])

    def test_rejects_checksum_path_traversal_and_duplicates(self):
        for text in ["a" * 64 + "  ../app", ("a" * 64 + "  " + m.DMG + "\n") * 2]:
            with self.assertRaises(RuntimeError):
                m.parse_checksums(text)

    def test_verifies_download_against_exact_tag_and_detects_corruption(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            tag, target = release()["tag_name"], "a" * 40
            (path / m.DMG).write_bytes(b"a disk image")
            (path / m.MANIFEST).write_text(json.dumps({"repository": m.REPO, "candidate": target, "tag": tag}))
            (path / "SHA256SUMS").write_text("".join(hashlib.sha256((path / n).read_bytes()).hexdigest() + "  " + n + "\n" for n in [m.DMG, m.MANIFEST]))
            self.assertEqual(m.verify(path, tag, target)["candidate"], target)
            with self.assertRaisesRegex(RuntimeError, "Manifest"):
                m.verify(path, tag, "b" * 40)
            (path / m.DMG).write_bytes(b"bad image")
            with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
                m.verify(path, tag, target)


if __name__ == "__main__":
    unittest.main()
