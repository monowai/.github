#!/usr/bin/env python3
"""Weekly GitHub storage cleanup for the monowai account.

Actions artifacts and GitHub Packages share one pooled storage allowance,
billed by the GB-hour. When it runs out, every `actions/upload-artifact`
step fails with "Artifact storage quota has been hit". This script keeps
that pool small:

1. Workflow runs whose branch no longer exists are deleted, in every
   non-archived repository. Their artifacts go with them. Runs on the
   default branch are never touched.
2. Container packages (ghcr.io/monowai/*) keep only what is deployed:
   the version tagged `latest` or `main`, the version bc-deploy pins as a
   chart's `appVersion`, and any tag listed in KEEP_TAGS. A package with no
   bc-deploy chart keeps its newest UNMAPPED_KEEP tagged versions instead.
   A multi-arch image is a manifest index plus the arch manifests and
   attestations pushed within a few seconds of it; those untagged
   siblings are kept or deleted together with their index.
3. Maven packages (com.beancounter.jar-*) keep the newest version and
   every version a consumer pins as `beancounterVersion`.

Anything younger than --min-age-days is left alone, so a build that has
not been deployed yet is never removed.

Needs the `gh` CLI and a token with `repo`, `read:packages` and
`delete:packages`. Run with --dry-run first.
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

OWNER = "monowai"
DEPLOY_REPO = f"{OWNER}/bc-deploy"
DEPLOY_CHARTS = "charts"
# Chart name -> package name, where they differ. Same name needs no entry.
CHART_PACKAGE = {}
# Repos whose build pins the shared jars: file -> regex that captures the version.
JAR_CONSUMERS = {
    f"{OWNER}/svc-retire": "build.gradle.kts",
    f"{OWNER}/svc-rebalance": "build.gradle.kts",
    f"{OWNER}/bc-mobile": "bff/build.gradle.kts",
}
JAR_PIN = re.compile(r'beancounterVersion\s*=\s*"([^"]+)"')
# Packages whose tags are pinned in Dockerfiles across the estate, so every
# tagged version stays; only untagged orphans go.
KEEP_ALL_TAGGED = {"eclipse-temurin", "aws-lambda-adapter"}
# Tags kept whatever bc-deploy says, per container package.
KEEP_TAGS: dict[str, set[str]] = {}
ALWAYS_KEEP = {"latest", "main"}
UNMAPPED_KEEP = 3  # newest tagged versions kept when no chart pins the package
SIBLING_WINDOW = timedelta(seconds=10)


def gh(path: str, *args: str, method: str = "GET", paginate: bool = False):
    cmd = ["gh", "api", "-X", method, path, *args]
    if paginate:
        cmd += ["--paginate", "--slurp"]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)}: {proc.stderr.strip()}")
    if not proc.stdout.strip():
        return None
    data = json.loads(proc.stdout)
    if paginate:
        merged: list = []
        for page in data:
            if isinstance(page, list):
                merged.extend(page)
            else:
                merged.extend(next(v for v in page.values() if isinstance(v, list)))
        return merged
    return data


def delete(path: str, dry_run: bool) -> bool:
    if dry_run:
        return True
    try:
        gh(path, method="DELETE")
        return True
    except RuntimeError as e:
        print(f"    failed: {e}", file=sys.stderr)
        return False


def ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def file_at(repo: str, path: str) -> str:
    data = gh(f"repos/{repo}/contents/{path}")
    return base64.b64decode(data["content"]).decode()


# --- 1. workflow runs on deleted branches -----------------------------------


def purge_runs(cutoff: datetime, dry_run: bool) -> int:
    repos = gh(f"users/{OWNER}/repos?per_page=100", paginate=True)
    total = 0
    for repo in repos:
        if repo["archived"]:
            continue
        name = repo["full_name"]
        default = repo["default_branch"]
        branches = {b["name"] for b in gh(f"repos/{name}/branches?per_page=100", paginate=True)}
        runs = gh(f"repos/{name}/actions/runs?per_page=100", paginate=True)
        gone = [
            r
            for r in runs
            if r["head_branch"] != default
            and r["head_branch"] not in branches
            and ts(r["created_at"]) < cutoff
            and r["status"] != "in_progress"
        ]
        if not gone:
            continue
        ok = sum(delete(f"repos/{name}/actions/runs/{r['id']}", dry_run) for r in gone)
        print(f"  {name}: delete {ok} of {len(runs)} runs (branch gone)")
        total += ok
    return total


# --- 2. container packages ------------------------------------------------------


def deployed_tags() -> dict[str, set[str]]:
    """Package name -> appVersion tags pinned by bc-deploy charts."""
    out: dict[str, set[str]] = {}
    for entry in gh(f"repos/{DEPLOY_REPO}/contents/{DEPLOY_CHARTS}"):
        if entry["type"] != "dir":
            continue
        try:
            chart = file_at(DEPLOY_REPO, f"{DEPLOY_CHARTS}/{entry['name']}/Chart.yaml")
        except RuntimeError:
            continue
        m = re.search(r'^appVersion:\s*["\']?([^"\'\s]+)', chart, re.M)
        if m:
            pkg = CHART_PACKAGE.get(entry["name"], entry["name"])
            out.setdefault(pkg, set()).add(m.group(1))
    return out


def tags_of(v: dict) -> set[str]:
    return set(v.get("metadata", {}).get("container", {}).get("tags", []))


def purge_containers(cutoff: datetime, dry_run: bool) -> int:
    pinned = deployed_tags()
    total = 0
    for pkg in gh(f"users/{OWNER}/packages?package_type=container&per_page=100", paginate=True):
        name = pkg["name"]
        versions = gh(
            f"users/{OWNER}/packages/container/{name}/versions?per_page=100", paginate=True
        )
        versions.sort(key=lambda v: v["created_at"], reverse=True)
        keep_tags = ALWAYS_KEEP | KEEP_TAGS.get(name, set())
        mapped = name in pinned
        if mapped:
            keep_tags |= pinned[name]
        if name in KEEP_ALL_TAGGED:
            anchors = [v for v in versions if tags_of(v)]
        else:
            anchors = [v for v in versions if tags_of(v) & keep_tags]
            if not mapped:
                anchors += [v for v in versions if tags_of(v)][:UNMAPPED_KEEP]
        anchors = list({a["id"]: a for a in anchors}.values())
        keep_ids = set()
        for a in anchors:
            at = ts(a["created_at"])
            keep_ids |= {
                v["id"] for v in versions if abs(ts(v["created_at"]) - at) <= SIBLING_WINDOW
            }
        gone = [v for v in versions if v["id"] not in keep_ids and ts(v["created_at"]) < cutoff]
        if not gone:
            continue
        kept = sorted({t for a in anchors for t in tags_of(a) - ALWAYS_KEEP})
        ok = sum(
            delete(f"users/{OWNER}/packages/container/{name}/versions/{v['id']}", dry_run)
            for v in gone
        )
        why = "all tags" if name in KEEP_ALL_TAGGED else "chart" if mapped else f"no chart, newest {UNMAPPED_KEEP}"
        print(f"  {name}: delete {ok} of {len(versions)}, keep {kept or ['latest']} ({why})")
        total += ok
    return total


# --- 3. maven packages ---------------------------------------------------------


def pinned_jars() -> set[str]:
    pins = set()
    for repo, path in JAR_CONSUMERS.items():
        m = JAR_PIN.search(file_at(repo, path))
        if m:
            pins.add(m.group(1))
    return pins


def purge_maven(cutoff: datetime, dry_run: bool) -> int:
    pins = pinned_jars()
    total = 0
    for pkg in gh(f"users/{OWNER}/packages?package_type=maven&per_page=100", paginate=True):
        name = pkg["name"]
        versions = gh(f"users/{OWNER}/packages/maven/{name}/versions?per_page=100", paginate=True)
        versions.sort(key=lambda v: v["created_at"], reverse=True)
        keep = pins | {versions[0]["name"]} if versions else set()
        gone = [v for v in versions if v["name"] not in keep and ts(v["created_at"]) < cutoff]
        if not gone:
            continue
        ok = sum(
            delete(f"users/{OWNER}/packages/maven/{name}/versions/{v['id']}", dry_run) for v in gone
        )
        print(f"  {name}: delete {ok} of {len(versions)}, keep {sorted(keep)}")
        total += ok
    return total


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--dry-run", action="store_true", help="report, delete nothing")
    ap.add_argument("--min-age-days", type=int, default=7, help="never touch anything younger")
    ap.add_argument(
        "--only",
        choices=["runs", "containers", "maven"],
        action="append",
        help="limit to one stage (repeatable); default all",
    )
    a = ap.parse_args()
    cutoff = datetime.now(timezone.utc) - timedelta(days=a.min_age_days)
    stages = a.only or ["runs", "containers", "maven"]
    mode = "DRY RUN" if a.dry_run else "deleting"
    print(f"{mode}: older than {cutoff:%Y-%m-%d}")
    counts = {}
    if "runs" in stages:
        print("workflow runs on deleted branches")
        counts["runs"] = purge_runs(cutoff, a.dry_run)
    if "containers" in stages:
        print("container package versions")
        counts["containers"] = purge_containers(cutoff, a.dry_run)
    if "maven" in stages:
        print("maven package versions")
        counts["maven"] = purge_maven(cutoff, a.dry_run)
    print("summary:", ", ".join(f"{k}={v}" for k, v in counts.items()))
    return 0


if __name__ == "__main__":
    sys.exit(main())
