#!/usr/bin/env python3
"""Trusted orchestration for this fork. Never execute candidate code in this process."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from datetime import datetime, timezone

REPO = "abhinavm24/typewhisper-mac"
UPSTREAM = "TypeWhisper/typewhisper-mac"
BRANCH = "personal-integration"
FILES = ("TypeWhisper-personal.dmg", "integration-manifest.json", "SHA256SUMS")


def run(*args, cwd=None, check=True, env=None):
    result = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, env=env)
    if check and result.returncode:
        raise RuntimeError(f"{args[0]} failed: {result.stderr or result.stdout}")
    return result


def git(path, *args):
    return run("git", *args, cwd=path).stdout.strip()


def api(endpoint, pages=False):
    args = ["gh", "api", endpoint]
    if pages:
        args += ["--paginate", "--slurp"]
    data = json.loads(run(*args).stdout)
    return [item for page in data for item in page] if pages else data


def sha(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value or ""):
        raise RuntimeError("Invalid commit SHA")
    return value


def select_prs(rows):
    selected = []
    for row in rows:
        if row["state"] != "open" or row["base"]["ref"] != "main":
            continue
        if (row["user"]["login"] != REPO.split("/")[0]
                or (row["head"].get("repo") or {}).get("full_name") != REPO
                or row["head"]["ref"] == BRANCH):
            raise RuntimeError(f"PR #{row['number']} is not an owner-authored source PR in {REPO}; review it first")
        selected.append({"number": int(row["number"]), "head": sha(row["head"]["sha"]),
                         "branch": row["head"]["ref"], "repository": REPO})
    return sorted(selected, key=lambda p: p["number"])


def snapshot():
    return {"main": sha(api(f"repos/{REPO}/commits/main")["sha"]),
            "prs": select_prs(api(f"repos/{REPO}/pulls?state=open&base=main&per_page=100", pages=True))}


def fingerprint(inputs):
    return hashlib.sha256(json.dumps(inputs, sort_keys=True).encode()).hexdigest()


def completed_release(releases, digest):
    for release in releases:
        if (not release["draft"] and release["prerelease"]
                and release["tag_name"].startswith("personal-")
                and set(FILES).issubset({item["name"] for item in release["assets"]})
                and f"<!-- personal-inputs:{digest} -->" in (release["body"] or "")):
            return release
    return None


def release_by_tag(tag):
    # The REST tag endpoint excludes drafts. gh resolves drafts through GraphQL.
    record = json.loads(run("gh", "release", "view", tag, "--repo", REPO,
                            "--json", "databaseId").stdout)
    return api(f"repos/{REPO}/releases/{int(record['databaseId'])}")


def ensure_current(manifest):
    if snapshot() != manifest["inputs"]:
        raise RuntimeError("Main or the open PR set changed during this run. Withholding publication; rebuild the current inputs.")


def remote_ref(path, ref):
    lines = git(path, "ls-remote", "origin", ref).splitlines()
    return lines[0].split()[0] if lines else ""


def push(path, *args):
    # Credentials exist only in trusted assembly/publication jobs, never candidate builds.
    return git(path, "-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential",
               "push", "origin", *args)


def repository(path):
    path.mkdir(parents=True, exist_ok=False)
    git(path, "init", "--quiet")
    git(path, "config", "user.name", "Abhinav Misra")
    git(path, "config", "user.email", "4698976+abhinavm24@users.noreply.github.com")
    git(path, "config", "commit.gpgsign", "false")
    git(path, "config", "core.hooksPath", "/dev/null")
    git(path, "remote", "add", "origin", f"https://github.com/{REPO}.git")


def ancestor(path, old, new="HEAD"):
    return run("git", "merge-base", "--is-ancestor", old, new, cwd=path, check=False).returncode == 0


def merge(path, commit, label):
    if ancestor(path, commit):
        return "already-included"
    result = run("git", "merge", "--no-ff", "--no-edit", "-m", f"Integrate {label}", commit,
                 cwd=path, check=False)
    if result.returncode:
        conflicts = git(path, "diff", "--name-only", "--diff-filter=U")
        raise RuntimeError(f"Cannot merge {label} ({commit}):\n{conflicts or result.stderr or result.stdout}")
    return "merged"


def assemble_tree(path, inputs):
    git(path, "checkout", "--detach", inputs["main"])
    status = []
    for pr in inputs["prs"]:
        status.append({"number": pr["number"],
                       "result": merge(path, pr["head"], f"PR #{pr['number']}")})
    return status


def summary(text):
    print(text, flush=True)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as stream:
            stream.write(text + "\n")


def output(key, value):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"{key}={value}\n")


def assemble(args):
    control = sha(git(args.control, "rev-parse", "HEAD"))
    path = args.work.resolve()
    repository(path)
    git(path, "fetch", "--no-tags", "origin", "main")
    main = sha(git(path, "rev-parse", "FETCH_HEAD"))
    if control != main:
        summary("A newer main superseded this workflow definition. Run the workflow from current main.")
        output("build", "false")
        return
    git(path, "checkout", "--detach", main)
    git(path, "fetch", "--no-tags", f"https://github.com/{UPSTREAM}.git", "main")
    upstream = sha(git(path, "rev-parse", "FETCH_HEAD"))
    if args.sync:
        merge(path, upstream, "upstream/main")
        synced = sha(git(path, "rev-parse", "HEAD"))
        if synced != main:
            changed = git(path, "diff", "--name-only", main, synced, "--",
                          ".github/personal-integration", ".github/workflows/personal-integration.yml")
            if changed:
                raise RuntimeError("Upstream changed fork CI files; review the sync manually")
            if remote_ref(path, "refs/heads/main") != main:
                raise RuntimeError("Main advanced during synchronization; retry")
            push(path, f"{synced}:refs/heads/main")  # Normal fast-forward only.
            main = synced
    inputs = snapshot()
    if inputs["main"] != main:
        raise RuntimeError("Main changed before assembly; retry")
    digest = fingerprint(inputs)
    if not args.force:
        release = completed_release(api(f"repos/{REPO}/releases?per_page=100", pages=True), digest)
        if release:
            summary(f"These inputs already passed: {release['html_url']}")
            output("build", "false")
            return
    for pr in inputs["prs"]:
        git(path, "fetch", "--no-tags", "origin", pr["head"])
    statuses = assemble_tree(path, inputs)
    candidate = sha(git(path, "rev-parse", "HEAD"))
    previous = remote_ref(path, f"refs/heads/{BRANCH}")
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
    run_id, attempt = os.environ["GITHUB_RUN_ID"], os.environ["GITHUB_RUN_ATTEMPT"]
    tag = f"personal-{stamp}-run{run_id}-attempt{attempt}"
    manifest = {"schema": 1, "repository": REPO, "inputs": inputs, "fingerprint": digest,
                "control_sha": control, "upstream_observed": upstream,
                "upstream_included": ancestor(path, upstream, main),
                "candidate": candidate, "tree": git(path, "rev-parse", "HEAD^{tree}"),
                "previous_integration": previous, "merges": statuses, "tag": tag,
                "force": args.force,
                "run_url": f"https://github.com/{REPO}/actions/runs/{run_id}"}
    ensure_current(manifest)
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "integration-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    git(path, "bundle", "create", str((args.output / "candidate.bundle").resolve()), "HEAD")
    output("build", "true")
    output("candidate", candidate)
    summary(f"Candidate `{candidate}` from main `{main}`; PRs: " +
            ", ".join(f"#{p['number']} `{p['head'][:8]}`" for p in inputs["prs"]))


def checksum(path):
    digest = hashlib.sha256()
    with open(path, "rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def release_notes(manifest):
    prs = "\n".join(f"- #{p['number']}: `{p['head']}`" for p in manifest["inputs"]["prs"])
    return (f"Personal macOS build from `{manifest['candidate']}`.\n\n"
            f"Fork main: `{manifest['inputs']['main']}`.\n"
            f"Upstream observed: `{manifest['upstream_observed']}` "
            f"(included: {manifest['upstream_included']}).\n\n{prs or 'No open feature PRs.'}\n\n"
            "App tests, plugin SDK tests, Release build, warning/instrumentation checks and DMG signature verification passed.\n\n"
            "Ad-hoc signed personal build; macOS permissions may need to be granted after installation.\n\n"
            f"[Build and test run]({manifest['run_url']})\n\n"
            f"<!-- personal-inputs:{manifest['fingerprint']} -->\n")


def promote(path, manifest):
    current = remote_ref(path, f"refs/heads/{BRANCH}")
    if current == manifest["candidate"]:
        return  # Retry after branch update but before release publication.
    if current != manifest["previous_integration"]:
        raise RuntimeError("Integration advanced unexpectedly; refusing to overwrite it")
    push(path, f"--force-with-lease=refs/heads/{BRANCH}:{current}",
         f"{manifest['candidate']}:refs/heads/{BRANCH}")


def publish(args):
    manifest = json.loads((args.source / "integration-manifest.json").read_text())
    if manifest["repository"] != REPO or manifest["fingerprint"] != fingerprint(manifest["inputs"]):
        raise RuntimeError("Invalid assembly manifest")
    if git(args.control, "rev-parse", "HEAD") != manifest["control_sha"]:
        raise RuntimeError("Publisher is not the recorded trusted CI revision")
    tag = manifest["tag"]
    if not re.fullmatch(r"personal-\d{8}-\d{6}-run\d+-attempt\d+", tag):
        raise RuntimeError("Invalid personal release tag")
    ensure_current(manifest)
    if not manifest.get("force", False):
        completed = completed_release(api(f"repos/{REPO}/releases?per_page=100", pages=True),
                                      manifest["fingerprint"])
        if completed and completed["tag_name"] != tag:
            summary(f"Another run already published these inputs: {completed['html_url']}")
            return
    path = args.work.resolve()
    repository(path)
    git(path, "fetch", str((args.source / "candidate.bundle").resolve()), "HEAD")
    git(path, "checkout", "--detach", "FETCH_HEAD")
    if (git(path, "rev-parse", "HEAD") != sha(manifest["candidate"])
            or git(path, "rev-parse", "HEAD^{tree}") != manifest["tree"]):
        raise RuntimeError("Candidate bundle does not match manifest")
    for commit in [manifest["inputs"]["main"], *[p["head"] for p in manifest["inputs"]["prs"]]]:
        if not ancestor(path, sha(commit)):
            raise RuntimeError("Candidate is missing a selected input")
    args.assets.mkdir(parents=True, exist_ok=True)
    dmg = args.assets / FILES[0]
    if not dmg.is_file() or dmg.is_symlink() or dmg.stat().st_size < 1024:
        raise RuntimeError("Missing DMG")
    (args.assets / FILES[1]).write_text(json.dumps(manifest, indent=2) + "\n")
    (args.assets / FILES[2]).write_text("".join(f"{checksum(args.assets / name)}  {name}\n" for name in FILES[:2]))
    notes = args.work.parent / "release-notes.md"
    notes.write_text(release_notes(manifest))
    existing_tag = remote_ref(path, f"refs/tags/{tag}")
    if existing_tag and existing_tag != manifest["candidate"]:
        raise RuntimeError("Release tag already points elsewhere")
    if not existing_tag:
        push(path, f"{manifest['candidate']}:refs/tags/{tag}")
    found = run("gh", "release", "view", tag, "--repo", REPO, "--json", "isDraft", check=False)
    if found.returncode:
        run("gh", "release", "create", tag, "--repo", REPO, "--verify-tag", "--draft", "--prerelease",
            "--latest=false", "--title", f"Personal build {tag.removeprefix('personal-')}", "--notes-file", str(notes))
    release = release_by_tag(tag)
    existing = {item["name"]: item for item in release["assets"]}
    for name in FILES:
        if name not in existing:
            if not release["draft"]:
                raise RuntimeError("Published release has incomplete assets; refusing to mutate it")
            run("gh", "release", "upload", tag, str(args.assets / name), "--repo", REPO)
    # Download and compare even on retries. Never clobber a mismatched asset.
    with tempfile.TemporaryDirectory() as directory:
        for name in FILES:
            run("gh", "release", "download", tag, "--repo", REPO, "--pattern", name, "--dir", directory)
            if checksum(Path(directory) / name) != checksum(args.assets / name):
                raise RuntimeError(f"Uploaded asset differs: {name}")
    ensure_current(manifest)
    promote(path, manifest)
    if release["draft"]:
        run("gh", "release", "edit", tag, "--repo", REPO, "--draft=false", "--prerelease", "--latest=false")
    final = api(f"repos/{REPO}/releases/{release['id']}")
    if final["draft"] or not final["prerelease"] or remote_ref(path, f"refs/tags/{tag}") != manifest["candidate"]:
        raise RuntimeError("Release verification failed")
    summary(f"Published [{tag}]({final['html_url']}) from `{manifest['candidate']}`. All selected tests passed.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("assemble")
    prepare.add_argument("--control", type=Path, required=True)
    prepare.add_argument("--work", type=Path, required=True)
    prepare.add_argument("--output", type=Path, required=True)
    prepare.add_argument("--sync", action="store_true")
    prepare.add_argument("--force", action="store_true")
    release = sub.add_parser("publish")
    for name in ("control", "work", "source", "assets"):
        release.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("GITHUB_REPOSITORY") != REPO:
        parser.error(f"This automation only publishes to {REPO}")
    try:
        (assemble if args.command == "assemble" else publish)(args)
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        summary(f"Integration stopped: {error}")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
