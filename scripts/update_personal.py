#!/usr/bin/env python3
"""Download and install the newest complete personal prerelease; no local build required."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

REPO = "abhinavm24/typewhisper-mac"
DMG = "TypeWhisper-personal.dmg"
MANIFEST = "integration-manifest.json"
ASSETS = {DMG, MANIFEST, "SHA256SUMS"}


def run(*args, capture=False):
    return subprocess.run(args, check=True, text=True, stdout=subprocess.PIPE if capture else None).stdout


def select_release(releases):
    candidates = [r for r in releases if not r["draft"] and r["prerelease"]
                  and re.fullmatch(r"personal-\d{8}-\d{6}-run\d+-attempt\d+", r["tag_name"])
                  and ASSETS.issubset({a["name"] for a in r["assets"]})]
    if not candidates:
        raise RuntimeError("No complete personal release exists yet; wait for the integration workflow to pass.")
    return max(candidates, key=lambda r: r["published_at"])


def parse_checksums(text):
    sums = {}
    for line in text.splitlines():
        match = re.fullmatch(r"([a-f0-9]{64})  (TypeWhisper-personal\.dmg|integration-manifest\.json)", line)
        if not match or match[2] in sums:
            raise RuntimeError("Invalid release checksum file")
        sums[match[2]] = match[1]
    if set(sums) != {DMG, MANIFEST}:
        raise RuntimeError("Incomplete release checksum file")
    return sums


def verify(directory, tag, target):
    for name, expected in parse_checksums((directory / "SHA256SUMS").read_text()).items():
        digest = hashlib.sha256()
        with (directory / name).open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(block)
        if digest.hexdigest() != expected:
            raise RuntimeError(f"Checksum mismatch: {name}")
    manifest = json.loads((directory / MANIFEST).read_text())
    if (manifest["repository"] != REPO or manifest["tag"] != tag
            or manifest["candidate"] != target or not re.fullmatch(r"[a-f0-9]{40}", target)):
        raise RuntimeError("Manifest does not match the release tag")
    return manifest


def signing_identity(requested):
    if requested != "auto":
        return requested
    identities = run("security", "find-identity", "-v", "-p", "codesigning", capture=True)
    match = re.search(r'([0-9A-Fa-f]{40})\s+"Apple Development:', identities)
    return match[1] if match else "-"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--download-dir", type=Path, default=Path.home() / "Downloads" / "TypeWhisper-Personal")
    parser.add_argument("--download-only", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--destination", type=Path, default=Path("/Applications/TypeWhisper.app"))
    parser.add_argument("--signing-identity", default="auto", help="auto, -, or an installed Apple Development identity")
    args = parser.parse_args()
    if os.geteuid() == 0:
        parser.error("run as your normal user; only app replacement may request sudo")
    try:
        pages = json.loads(run("gh", "api", f"repos/{REPO}/releases?per_page=100", "--paginate", "--slurp", capture=True))
        release = select_release([r for page in pages for r in page])
        tag = release["tag_name"]
        directory = args.download_dir.expanduser().resolve() / tag
        directory.mkdir(parents=True, exist_ok=True)
        for name in sorted(ASSETS):
            if not (directory / name).exists():
                run("gh", "release", "download", tag, "--repo", REPO, "--pattern", name, "--dir", str(directory))
        ref = json.loads(run("gh", "api", f"repos/{REPO}/git/ref/tags/{tag}", capture=True))
        if ref["object"]["type"] != "commit":
            raise RuntimeError("Expected a personal release tag pointing directly to a commit")
        manifest = verify(directory, tag, ref["object"]["sha"])
        print(f"Verified {tag}: {manifest['candidate']}\nDownloaded to {directory}", flush=True)
        if args.download_only:
            return
        with tempfile.TemporaryDirectory(prefix="typewhisper-install-") as temporary:
            root = Path(temporary)
            mount = root / "mounted"
            mount.mkdir()
            run("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(directory / DMG))
            try:
                app = root / "TypeWhisper.app"
                run("ditto", str(mount / "TypeWhisper.app"), str(app))
            finally:
                run("hdiutil", "detach", str(mount))
            identity = signing_identity(args.signing_identity)
            run("codesign", "--force", "--deep", "--sign", identity, str(app))
            run("codesign", "--verify", "--deep", "--strict", str(app))
            if identity == "-":
                print("Using ad-hoc signing; macOS may request microphone/Accessibility access again.")
            installer = Path(__file__).with_name("install_local.sh")
            command = ["bash", str(installer), "--source", str(app), "--destination", str(args.destination.expanduser())]
            if args.dry_run:
                command.append("--dry-run")
            elif not os.access(args.destination.expanduser().parent, os.W_OK):
                command.insert(0, "sudo")
            run(*command)
    except (RuntimeError, OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Update stopped: {error}\n")


if __name__ == "__main__":
    main()
