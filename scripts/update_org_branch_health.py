#!/usr/bin/env python3
"""
scripts/update_org_branch_health.py

Scans all public repositories in the org, determines the health of the 'dev'
and 'main' branches by inspecting the latest merged-PR commit, generates local
SVG badges for each repo+branch, and updates profile/README.md with a live
branch health dashboard.

Why local SVG badges:
    GitHub's built-in workflow badge URLs report the status of a single
    workflow file, not an aggregate per-branch result. External badge services
    (shields.io, etc.) add external dependencies and can be rate-limited or
    unavailable. Local SVGs are self-contained, version-controlled, and render
    reliably inside GitHub's Markdown renderer without any network dependency.

Why a cross-repo token is required:
    GITHUB_TOKEN is scoped to the repository the workflow runs in. Reading
    workflow runs, pull requests, and branch data from other org repositories
    requires a token with org-wide read access — either a GitHub App
    installation token (preferred) or a classic PAT with repo/actions scopes.

How merged PR commits are detected:
    For each target branch we walk the most recent commits (up to
    COMMIT_WALK_LIMIT). For every commit SHA we call the GitHub
    "list pull requests associated with a commit" endpoint and look for a PR
    where:
      - merged_at is not null (it was actually merged)
      - base.ref == target branch (it targeted this branch)
      - merge_commit_sha == commit SHA (this commit IS the merge commit)
    This is more robust than parsing commit messages and works for squash and
    rebase merges because GitHub associates the resulting commit with its PR.

How latest-per-workflow aggregation works:
    Multiple workflow runs may exist for the same commit SHA (reruns, retries,
    multiple workflows). We group all push-event runs for the merge SHA by
    workflow_id, then keep only the run with the highest run_number within each
    group. This ensures we evaluate the most recent attempt for each workflow
    rather than a stale prior failure that was subsequently retried.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

TARGET_BRANCHES: list[str] = ["dev", "main"]

# How many recent commits to walk when searching for the latest merged PR.
COMMIT_WALK_LIMIT = 30

GITHUB_API = "https://api.github.com"

README_START_MARKER = "<!-- branch-health:start -->"
README_END_MARKER = "<!-- branch-health:end -->"

# Status colors for SVG badge backgrounds.
_BADGE_COLORS: dict[str, str] = {
    "green": "#4c1",
    "red": "#e05d44",
    "gray": "#9f9f9f",
}

# Conclusions that indicate a hard failure.
_FAILURE_CONCLUSIONS: frozenset[str] = frozenset(
    {"failure", "timed_out", "action_required"}
)

# Conclusions that are considered neutral (not a pass, not a hard failure).
_NEUTRAL_CONCLUSIONS: frozenset[str] = frozenset(
    {"cancelled", "skipped", "neutral", "stale"}
)

# Statuses that mean the run has not finished yet.
_IN_PROGRESS_STATUSES: frozenset[str] = frozenset(
    {"queued", "requested", "waiting", "pending", "in_progress"}
)


# ---------------------------------------------------------------------------
# GitHub API helpers
# ---------------------------------------------------------------------------


def _make_request(url: str, token: str) -> Any:
    """
    Perform a single authenticated GET request to the GitHub REST API.
    Returns parsed JSON, or None on 404/422.
    Raises on all other HTTP errors.
    """
    req = urllib.request.Request(url)
    req.add_header("Authorization", f"Bearer {token}")
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    req.add_header("User-Agent", "org-branch-health/1.0")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        if exc.code in (404, 422):
            return None
        raise


def _paginate_list(url: str, token: str, extra_params: dict[str, str] | None = None) -> list[Any]:
    """
    Fetch all pages of a GitHub API endpoint that returns a JSON array.
    Stops when a page returns fewer than 100 items.
    """
    results: list[Any] = []
    sep = "&" if "?" in url else "?"
    page = 1
    while True:
        paged = f"{url}{sep}per_page=100&page={page}"
        if extra_params:
            paged += "&" + urllib.parse.urlencode(extra_params)
        data = _make_request(paged, token)
        if not data or not isinstance(data, list):
            break
        results.extend(data)
        if len(data) < 100:
            break
        page += 1
    return results


# ---------------------------------------------------------------------------
# SVG badge generation
# ---------------------------------------------------------------------------


def _generate_svg(label: str, message: str, color: str) -> str:
    """
    Produce a self-contained flat SVG badge with no external dependencies.
    Layout: dark-gray label section on the left, colored message section on
    the right, white text on both sides with a subtle drop-shadow.
    """
    bg = _BADGE_COLORS.get(color, _BADGE_COLORS["gray"])

    # Approximate rendered px width per character for 11 px DejaVu Sans
    # (measured empirically; real widths vary by glyph but 7px/char keeps
    # badges readable for typical branch and status label lengths).
    cw = 7
    pad = 10
    lw = len(label) * cw + pad
    mw = len(message) * cw + pad
    tw = lw + mw
    lcx = lw // 2
    mcx = lw + mw // 2

    def x(s: str) -> str:
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")

    le, me = x(label), x(message)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{tw}" height="20">\n'
        f'  <rect width="{tw}" height="20" fill="#555" rx="3"/>\n'
        f'  <rect x="{lw}" width="{mw}" height="20" fill="{bg}" rx="3"/>\n'
        f'  <rect x="{lw}" width="4" height="20" fill="{bg}"/>\n'
        f'  <g fill="#fff" text-anchor="middle"'
        f' font-family="DejaVu Sans,Verdana,Geneva,sans-serif" font-size="11">\n'
        f'    <text x="{lcx}" y="15" fill="#010101" fill-opacity=".3">{le}</text>\n'
        f'    <text x="{lcx}" y="14">{le}</text>\n'
        f'    <text x="{mcx}" y="15" fill="#010101" fill-opacity=".3">{me}</text>\n'
        f'    <text x="{mcx}" y="14">{me}</text>\n'
        f'  </g>\n'
        f'</svg>\n'
    )


# ---------------------------------------------------------------------------
# Repository discovery
# ---------------------------------------------------------------------------


def get_repos(org: str, token: str) -> list[dict]:
    """
    Return all non-archived repositories in the org.

    Defaults to public repos only because this dashboard is embedded in the
    public org profile README. Set the environment variable
    ORG_REPO_VISIBILITY=all to include private repos when running from a
    private repository.
    """
    visibility = os.environ.get("ORG_REPO_VISIBILITY", "public")
    url = f"{GITHUB_API}/orgs/{org}/repos?type={visibility}"
    repos = _paginate_list(url, token)
    # Skip archived repos — their CI is frozen and adds noise.
    # To exclude specific repos, add their names to this set:
    exclude: set[str] = set()
    return [r for r in repos if not r.get("archived") and r["name"] not in exclude]


# ---------------------------------------------------------------------------
# Branch health data collection
# ---------------------------------------------------------------------------


def _get_branch_sha(owner: str, repo: str, branch: str, token: str) -> str | None:
    """Return the HEAD commit SHA of a branch, or None if the branch is absent."""
    url = f"{GITHUB_API}/repos/{owner}/{repo}/branches/{urllib.parse.quote(branch, safe='')}"
    data = _make_request(url, token)
    if not data:
        return None
    return data.get("commit", {}).get("sha")


def _find_latest_merged_pr(
    owner: str, repo: str, branch: str, token: str
) -> dict[str, Any] | None:
    """
    Walk the most recent commits on `branch` and return the first commit that
    is the merge commit of a PR that targeted this branch.

    For each commit SHA we call /repos/{owner}/{repo}/commits/{sha}/pulls,
    which returns PRs associated with that commit. We pick the first PR where:
      - merged_at is not null        → it was actually merged
      - base.ref == branch           → it targeted this branch
      - merge_commit_sha == sha      → this commit is the resulting merge commit

    Stopping at the first match means we always find the most-recent merge.
    """
    commits_url = (
        f"{GITHUB_API}/repos/{owner}/{repo}/commits"
        f"?sha={urllib.parse.quote(branch, safe='')}&per_page={COMMIT_WALK_LIMIT}"
    )
    commits = _make_request(commits_url, token)
    if not commits or not isinstance(commits, list):
        return None

    for commit in commits:
        sha = commit.get("sha")
        if not sha:
            continue

        pulls_url = f"{GITHUB_API}/repos/{owner}/{repo}/commits/{sha}/pulls"
        try:
            pulls = _make_request(pulls_url, token)
        except Exception as exc:
            print(f"  WARN could not fetch pulls for {owner}/{repo}@{sha}: {exc}", file=sys.stderr)
            continue

        if not pulls or not isinstance(pulls, list):
            continue

        for pr in pulls:
            if (
                pr.get("merged_at")
                and pr.get("base", {}).get("ref") == branch
                and pr.get("merge_commit_sha") == sha
            ):
                return {"merge_sha": sha, "pr": pr}

    return None


def _get_workflow_runs_for_sha(
    owner: str, repo: str, branch: str, sha: str, token: str
) -> list[dict]:
    """
    Return the latest-per-workflow push-event runs for a specific merge commit.

    We fetch all push-event runs for (branch, sha), group them by workflow_id,
    and keep only the run with the highest run_number per workflow. This gives
    us the most recent attempt for each workflow so a past failed run that was
    later retried successfully does not make the branch look red.
    """
    url = (
        f"{GITHUB_API}/repos/{owner}/{repo}/actions/runs"
        f"?branch={urllib.parse.quote(branch, safe='')}"
        f"&head_sha={sha}&event=push&per_page=100"
    )
    all_runs: list[dict] = []
    page = 1
    while True:
        data = _make_request(f"{url}&page={page}", token)
        if not data or not isinstance(data, dict):
            break
        batch = data.get("workflow_runs", [])
        all_runs.extend(batch)
        if len(all_runs) >= data.get("total_count", 0) or len(batch) < 100:
            break
        page += 1

    # Group by workflow_id (fall back to workflow name if id is absent).
    # Keep only the run with the highest run_number in each group.
    latest: dict[Any, dict] = {}
    for run in all_runs:
        key = run.get("workflow_id") or run.get("name", "unknown")
        existing = latest.get(key)
        if existing is None or run.get("run_number", 0) > existing.get("run_number", 0):
            latest[key] = run

    return list(latest.values())


# ---------------------------------------------------------------------------
# Status computation
# ---------------------------------------------------------------------------


def _compute_status(runs: list[dict]) -> dict[str, str]:
    """
    Collapse a list of latest-per-workflow runs into a single branch status.

    Rules (evaluated in order):
      gray    — no runs exist
      gray    — any run is still queued / in-progress
      red     — any run concluded with a hard failure
      green   — all runs completed with 'success'
      gray    — all other cases (neutral mix, cancelled-only, etc.)
    """
    if not runs:
        return {"color": "gray", "text": "neutral", "detail": "no workflows"}

    for run in runs:
        if run.get("status") in _IN_PROGRESS_STATUSES:
            return {"color": "gray", "text": "running", "detail": "running"}

    conclusions = {run.get("conclusion") for run in runs}

    if conclusions & _FAILURE_CONCLUSIONS:
        failing = next(r for r in runs if r.get("conclusion") in _FAILURE_CONCLUSIONS)
        return {
            "color": "red",
            "text": "failing",
            "detail": failing.get("name", "unknown workflow"),
            "failing_run_url": failing.get("html_url", ""),
        }

    if conclusions == {"success"}:
        return {"color": "green", "text": "passing", "detail": "passing"}

    # Mixed success + neutral, or all neutral (cancelled, skipped, etc.).
    return {"color": "gray", "text": "neutral", "detail": "neutral"}


def _pick_url(
    owner: str,
    repo: str,
    branch: str,
    status: dict,
    runs: list[dict],
    merge_info: dict | None,
) -> str:
    """Choose the most useful click-through URL for a badge."""
    if status["color"] == "red" and status.get("failing_run_url"):
        return status["failing_run_url"]
    if runs:
        newest = max(runs, key=lambda r: r.get("run_number", 0))
        return newest.get("html_url") or f"https://github.com/{owner}/{repo}/actions"
    if merge_info and merge_info.get("pr"):
        return merge_info["pr"].get("html_url") or f"https://github.com/{owner}/{repo}"
    branch_q = urllib.parse.quote(branch, safe="")
    return f"https://github.com/{owner}/{repo}/actions?query=branch%3A{branch_q}"


def compute_repo_health(owner: str, repo: str, token: str) -> dict[str, Any]:
    """Compute branch health for TARGET_BRANCHES in a single repository."""
    result: dict[str, Any] = {"repo": repo, "branches": {}}

    for branch in TARGET_BRANCHES:
        bd: dict[str, Any] = {"branch": branch}
        try:
            sha = _get_branch_sha(owner, repo, branch, token)
            if not sha:
                bd.update(
                    {
                        "status": {"color": "gray", "text": "missing", "detail": "missing branch"},
                        "merge_sha": None,
                        "pr": None,
                        "runs": [],
                        "url": f"https://github.com/{owner}/{repo}",
                    }
                )
                result["branches"][branch] = bd
                continue

            merge_info = _find_latest_merged_pr(owner, repo, branch, token)
            if not merge_info:
                branch_q = urllib.parse.quote(branch, safe="")
                bd.update(
                    {
                        "status": {
                            "color": "gray",
                            "text": "no merge",
                            "detail": "no merge found",
                        },
                        "merge_sha": None,
                        "pr": None,
                        "runs": [],
                        "url": (
                            f"https://github.com/{owner}/{repo}/actions"
                            f"?query=branch%3A{branch_q}"
                        ),
                    }
                )
                result["branches"][branch] = bd
                continue

            merge_sha: str = merge_info["merge_sha"]
            pr: dict = merge_info["pr"]
            runs = _get_workflow_runs_for_sha(owner, repo, branch, merge_sha, token)
            status = _compute_status(runs)
            url = _pick_url(owner, repo, branch, status, runs, merge_info)

            bd.update(
                {
                    "status": status,
                    "merge_sha": merge_sha,
                    "pr": {
                        "number": pr.get("number"),
                        "url": pr.get("html_url"),
                        "title": pr.get("title"),
                        "merged_at": pr.get("merged_at"),
                    },
                    "runs": [
                        {
                            "id": r.get("id"),
                            "name": r.get("name"),
                            "workflow_id": r.get("workflow_id"),
                            "run_number": r.get("run_number"),
                            "status": r.get("status"),
                            "conclusion": r.get("conclusion"),
                            "html_url": r.get("html_url"),
                        }
                        for r in runs
                    ],
                    "url": url,
                }
            )
        except Exception as exc:
            print(f"  ERROR {repo}/{branch}: {exc}", file=sys.stderr)
            bd.update(
                {
                    "status": {"color": "gray", "text": "error", "detail": str(exc)},
                    "merge_sha": None,
                    "pr": None,
                    "runs": [],
                    "url": f"https://github.com/{owner}/{repo}",
                }
            )

        result["branches"][branch] = bd

    return result


# ---------------------------------------------------------------------------
# Change detection (keeps commits stable when data hasn't changed)
# ---------------------------------------------------------------------------


def _status_fingerprint(results: list[dict]) -> list[dict]:
    """
    Extract just the health-relevant fields from results for comparison.
    Timestamps and run metadata are excluded so that re-scanning the same
    underlying state produces an identical fingerprint.
    """

    def branch_key(bd: dict) -> dict:
        s = bd.get("status", {})
        return {
            "color": s.get("color"),
            "text": s.get("text"),
            "merge_sha": bd.get("merge_sha"),
            "pr_number": (bd.get("pr") or {}).get("number"),
        }

    return sorted(
        [
            {
                "repo": r["repo"],
                "branches": {b: branch_key(bd) for b, bd in r["branches"].items()},
            }
            for r in results
        ],
        key=lambda r: r["repo"],
    )


def _load_existing_fingerprint(generated_dir: Path) -> list[dict] | None:
    """Load the fingerprint stored in status.json from the previous run."""
    path = generated_dir / "status.json"
    if not path.exists():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        return _status_fingerprint(data.get("repos", []))
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Output generation
# ---------------------------------------------------------------------------


def _safe_name(repo: str) -> str:
    """Convert a repo name to a filesystem-safe identifier."""
    return re.sub(r"[^a-zA-Z0-9._-]", "-", repo).lower()


def write_badges(results: list[dict], generated_dir: Path) -> None:
    """Write one SVG file per repo+branch under generated_dir."""
    generated_dir.mkdir(parents=True, exist_ok=True)
    for r in results:
        safe = _safe_name(r["repo"])
        for branch, bd in r["branches"].items():
            s = bd.get("status", {})
            svg = _generate_svg(branch, s.get("text", "unknown"), s.get("color", "gray"))
            (generated_dir / f"{safe}-{branch}.svg").write_text(svg, encoding="utf-8")


def write_status_json(
    results: list[dict], generated_dir: Path, updated_at: str
) -> None:
    """Write machine-readable status.json for debugging and future tooling."""
    generated_dir.mkdir(parents=True, exist_ok=True)
    payload = {"updated_at": updated_at, "repos": results}
    (generated_dir / "status.json").write_text(
        json.dumps(payload, indent=2, default=str), encoding="utf-8"
    )


def _sort_key(r: dict) -> tuple[int, str]:
    """Sort repos: red → gray → green, alphabetical within each tier."""
    colors = {bd.get("status", {}).get("color", "gray") for bd in r["branches"].values()}
    if "red" in colors:
        return (0, r["repo"].lower())
    if "gray" in colors:
        return (1, r["repo"].lower())
    return (2, r["repo"].lower())


def _build_dashboard(
    results: list[dict], org: str, generated_rel: str, updated_at: str
) -> str:
    """Render the Markdown block that is injected between the README markers."""
    sorted_results = sorted(results, key=_sort_key)

    def counts(branch: str) -> dict[str, int]:
        c: dict[str, int] = {"green": 0, "red": 0, "gray": 0}
        for r in results:
            color = r["branches"].get(branch, {}).get("status", {}).get("color", "gray")
            c[color] = c.get(color, 0) + 1
        return c

    dc = counts("dev")
    mc = counts("main")
    n = len(results)

    lines = [
        "## Branch health",
        "",
        f"_Last updated: {updated_at} UTC &mdash; {n} repos scanned_",
        "",
        "| | `dev` | `main` |",
        "|:---|:---:|:---:|",
        f"| :green_circle: passing | {dc['green']} | {mc['green']} |",
        f"| :red_circle: failing | {dc['red']} | {mc['red']} |",
        f"| :white_circle: other | {dc['gray']} | {mc['gray']} |",
        "",
        "| Repo | dev | main | Latest merge | Details |",
        "|:-----|:---:|:----:|:------------:|:--------|",
    ]

    for r in sorted_results:
        repo = r["repo"]
        safe = _safe_name(repo)
        repo_url = f"https://github.com/{org}/{repo}"
        cells: list[str] = [f"[{repo}]({repo_url})"]

        merge_links: list[str] = []
        details: list[str] = []

        for branch in TARGET_BRANCHES:
            bd = r["branches"].get(branch, {})
            status = bd.get("status", {})
            badge_url = bd.get("url") or repo_url
            svg_path = f"{generated_rel}/{safe}-{branch}.svg"
            cells.append(f"[![{branch}]({svg_path})]({badge_url})")

            pr = bd.get("pr")
            if pr and pr.get("number"):
                link = f"[#{pr['number']}]({pr['url']})"
                if link not in merge_links:
                    merge_links.append(link)

            detail = status.get("detail", "")
            if detail and detail not in ("passing", ""):
                details.append(f"`{branch}`: {detail}")

        cells.append(" ".join(merge_links) if merge_links else "&mdash;")
        cells.append("; ".join(details) if details else "&check;")
        lines.append("| " + " | ".join(cells) + " |")

    return "\n".join(lines) + "\n"


def update_readme(
    readme_path: Path,
    results: list[dict],
    org: str,
    generated_rel: str,
    updated_at: str,
) -> None:
    """Insert or replace the generated block inside the README markers."""
    content = readme_path.read_text(encoding="utf-8")
    dashboard = _build_dashboard(results, org, generated_rel, updated_at)
    block = f"{README_START_MARKER}\n{dashboard}{README_END_MARKER}"

    if README_START_MARKER in content and README_END_MARKER in content:
        pattern = re.escape(README_START_MARKER) + r".*?" + re.escape(README_END_MARKER)
        new_content = re.sub(pattern, block, content, flags=re.DOTALL)
    else:
        # Markers not present yet — append near the end of the file.
        new_content = content.rstrip("\n") + "\n\n" + block + "\n"

    readme_path.write_text(new_content, encoding="utf-8")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    org = os.environ.get("ORG_NAME") or os.environ.get("GITHUB_REPOSITORY_OWNER")
    if not org:
        print("ERROR: set ORG_NAME or GITHUB_REPOSITORY_OWNER", file=sys.stderr)
        sys.exit(1)

    token = os.environ.get("ORG_BRANCH_HEALTH_TOKEN") or os.environ.get("GH_TOKEN")
    if not token:
        print(
            "ERROR: set ORG_BRANCH_HEALTH_TOKEN or GH_TOKEN to a token with "
            "org-wide read access to repos, actions, and pull requests.",
            file=sys.stderr,
        )
        sys.exit(1)

    repo_root = Path(os.environ.get("REPO_ROOT", Path(__file__).parent.parent))
    generated_dir = repo_root / "profile" / "generated"
    readme_path = repo_root / "profile" / "README.md"
    # Relative path used inside the Markdown table (relative to profile/).
    generated_rel = "generated"

    updated_at = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M")

    print(f"Scanning org: {org}")
    try:
        repos = get_repos(org, token)
    except Exception as exc:
        print(f"ERROR listing repos: {exc}", file=sys.stderr)
        sys.exit(1)

    print(f"Found {len(repos)} non-archived repos")

    results: list[dict] = []
    for repo_data in repos:
        repo_name: str = repo_data["name"]
        print(f"  {repo_name} ...", flush=True)
        try:
            health = compute_repo_health(org, repo_name, token)
            results.append(health)
        except Exception as exc:
            print(f"  SKIP {repo_name}: {exc}", file=sys.stderr)
            results.append(
                {
                    "repo": repo_name,
                    "branches": {
                        b: {
                            "branch": b,
                            "status": {
                                "color": "gray",
                                "text": "error",
                                "detail": str(exc),
                            },
                            "merge_sha": None,
                            "pr": None,
                            "runs": [],
                            "url": f"https://github.com/{org}/{repo_name}",
                        }
                        for b in TARGET_BRANCHES
                    },
                }
            )

    # Only write new files and update the README when the health data has
    # actually changed. This keeps the commit history clean.
    prev_fingerprint = _load_existing_fingerprint(generated_dir)
    new_fingerprint = _status_fingerprint(results)

    if prev_fingerprint == new_fingerprint:
        print("No status changes detected — skipping file updates.")
        return

    write_badges(results, generated_dir)
    write_status_json(results, generated_dir, updated_at)
    update_readme(readme_path, results, org, generated_rel, updated_at)

    print(f"Done. {len(results)} repos processed.")


if __name__ == "__main__":
    main()
