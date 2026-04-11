#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  generate_platform_drift_report.sh \
    --owner octo-org \
    --current-repo octo-org/.github \
    --out-dir out
EOF
}

owner=""
current_repo=""
out_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --owner)
      owner="${2:-}"
      shift 2
      ;;
    --current-repo)
      current_repo="${2:-}"
      shift 2
      ;;
    --out-dir)
      out_dir="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

: "${GH_TOKEN:?GH_TOKEN is required}"

if [[ -z "$owner" || -z "$current_repo" || -z "$out_dir" ]]; then
  usage
  exit 1
fi

mkdir -p "$out_dir"

report_md="${out_dir}/platform-drift.md"
report_jsonl="${out_dir}/platform-drift-repos.jsonl"
report_json="${out_dir}/platform-drift.json"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

has_path() {
  local repo="$1"
  local branch="$2"
  local path="$3"
  gh api "/repos/${repo}/contents/${path}?ref=${branch}" >/dev/null 2>&1
}

first_existing_path() {
  local repo="$1"
  local branch="$2"
  shift 2
  local path=""
  for path in "$@"; do
    if has_path "$repo" "$branch" "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

org_repos_json="$(
  if gh api --paginate "/orgs/${owner}/repos?type=all&per_page=100" 2>/dev/null | jq -s '
    if length == 0 then
      []
    elif all(.[]; type == "array") then
      add
    else
      []
    end
  '; then
    :
  else
    printf '[]\n'
  fi
)"

readarray -t repo_list < <(
  jq -r '
    .[]
    | select((.archived // false) | not)
    | select((.disabled // false) | not)
    | .full_name
  ' <<<"$org_repos_json"
)

if [[ "${#repo_list[@]}" -eq 0 ]]; then
  repo_list=("$current_repo")
  discovery_mode="current-repo-fallback"
else
  discovery_mode="organization-wide"
fi

{
  echo "# Platform Drift Report"
  echo
  echo "Generated at: ${generated_at}"
  echo "Discovery mode: ${discovery_mode}"
  echo "Organization owner: ${owner}"
  echo
  echo "This report is discussion-first and intentionally read-only."
  echo
} >"$report_md"

: >"$report_jsonl"

for repo_ref in "${repo_list[@]}"; do
  full_repo="$repo_ref"
  if [[ "$full_repo" != */* ]]; then
    full_repo="${owner}/${full_repo}"
  fi

  repo_meta="$(gh api "/repos/${full_repo}" 2>/dev/null || true)"
  if [[ -z "$repo_meta" ]] || ! jq -e '.default_branch' >/dev/null 2>&1 <<<"$repo_meta"; then
    continue
  fi
  default_branch="$(jq -r '.default_branch' <<<"$repo_meta")"

  readme_path="$(first_existing_path "$full_repo" "$default_branch" "README.md" || true)"
  changelog_path="$(first_existing_path "$full_repo" "$default_branch" "CHANGELOG.md" || true)"
  codeowners_path="$(first_existing_path "$full_repo" "$default_branch" ".github/CODEOWNERS" "CODEOWNERS" "docs/CODEOWNERS" || true)"
  security_path="$(first_existing_path "$full_repo" "$default_branch" ".github/SECURITY.md" "SECURITY.md" "docs/SECURITY.md" || true)"
  renovate_path="$(first_existing_path "$full_repo" "$default_branch" ".github/renovate.json5" ".github/renovate.json" "renovate.json5" "renovate.json" || true)"
  sonar_path="$(first_existing_path "$full_repo" "$default_branch" "sonar-project.properties" ".sonarcloud.properties" || true)"

  workflow_count="$(
    if gh api "/repos/${full_repo}/contents/.github/workflows?ref=${default_branch}" >/tmp/platform-drift-workflows.json 2>/dev/null; then
      jq 'if type == "array" then map(select(.type == "file")) | length else 0 end' /tmp/platform-drift-workflows.json
    else
      echo 0
    fi
  )"

  jq -nc \
    --arg repo "$full_repo" \
    --arg default_branch "$default_branch" \
    --arg readme_path "$readme_path" \
    --arg changelog_path "$changelog_path" \
    --arg codeowners_path "$codeowners_path" \
    --arg security_path "$security_path" \
    --arg renovate_path "$renovate_path" \
    --arg sonar_path "$sonar_path" \
    --argjson workflow_count "$workflow_count" \
    '{
      repo: $repo,
      default_branch: $default_branch,
      workflow_count: $workflow_count,
      readme_present: ($readme_path != ""),
      changelog_present: ($changelog_path != ""),
      codeowners_present: ($codeowners_path != ""),
      security_present: ($security_path != ""),
      renovate_present: ($renovate_path != ""),
      sonar_present: ($sonar_path != "")
    }' >>"$report_jsonl"
done

checked_count="$(jq -s 'length' "$report_jsonl")"
missing_readme_count="$(jq -s 'map(select(.readme_present | not)) | length' "$report_jsonl")"
missing_changelog_count="$(jq -s 'map(select(.changelog_present | not)) | length' "$report_jsonl")"
missing_codeowners_count="$(jq -s 'map(select(.codeowners_present | not)) | length' "$report_jsonl")"
missing_security_count="$(jq -s 'map(select(.security_present | not)) | length' "$report_jsonl")"
missing_renovate_count="$(jq -s 'map(select(.renovate_present | not)) | length' "$report_jsonl")"
missing_sonar_count="$(jq -s 'map(select(.sonar_present | not)) | length' "$report_jsonl")"
missing_workflows_count="$(jq -s 'map(select(.workflow_count == 0)) | length' "$report_jsonl")"

{
  echo "## Summary"
  echo
  echo "- Discovery mode: ${discovery_mode}"
  echo "- Repositories checked: ${checked_count}"
  echo "- Missing README.md: ${missing_readme_count}"
  echo "- Missing CHANGELOG.md: ${missing_changelog_count}"
  echo "- Missing CODEOWNERS: ${missing_codeowners_count}"
  echo "- Missing SECURITY.md: ${missing_security_count}"
  echo "- Missing Renovate config: ${missing_renovate_count}"
  echo "- Missing Sonar config: ${missing_sonar_count}"
  echo "- Missing workflow directory or workflow files: ${missing_workflows_count}"
  echo
  cat <<'EOF'
## Check Scope

These are real repository-content checks, but they are currently shallow presence checks.

- A green check means the expected file or config was found in at least one standard location.
- A red X means it was not found in the checked locations.
- A green check does not yet mean the content is correct, enforced, or complete.

## Legend

- `✅` present in a checked standard location
- `❌` not found in the checked locations

## Drift Definitions

- `Workflows`: at least one workflow file exists under `.github/workflows`
- `README`: `README.md` exists at repo root
- `CHANGELOG`: `CHANGELOG.md` exists at repo root
- `CODEOWNERS`: one of `.github/CODEOWNERS`, `CODEOWNERS`, or `docs/CODEOWNERS` exists
- `SECURITY`: one of `.github/SECURITY.md`, `SECURITY.md`, or `docs/SECURITY.md` exists
- `Renovate`: one of `.github/renovate.json5`, `.github/renovate.json`, `renovate.json5`, or `renovate.json` exists
- `Sonar`: `sonar-project.properties` or `.sonarcloud.properties` exists

EOF
  echo "## Repository Matrix"
  echo
  echo "| Repo | Branch | Workflows | README | CHANGELOG | CODEOWNERS | SECURITY | Renovate | Sonar |"
  echo "| --- | --- | ---: | --- | --- | --- | --- | --- | --- |"
  jq -r '
    def mark(v): if v then "✅" else "❌" end;
    "| \(.repo) | \(.default_branch) | \(if .workflow_count > 0 then "✅ \(.workflow_count)" else "❌" end) | \(mark(.readme_present)) | \(mark(.changelog_present)) | \(mark(.codeowners_present)) | \(mark(.security_present)) | \(mark(.renovate_present)) | \(mark(.sonar_present)) |"
  ' "$report_jsonl"
  echo
  cat <<'EOF'
## Not Yet Checked

- Branch protection rules and rulesets
- Auto-merge settings
- Environment protections and deployment approvals
- OIDC and cloud credential posture
- Acceptance test wiring and promotion guard consistency

Those policy checks belong in the next iteration of the standards workflow.
EOF
} >>"$report_md"

jq -s \
  --arg generated_at "$generated_at" \
  --arg discovery_mode "$discovery_mode" \
  --arg owner "$owner" \
  '{
    report_type: "platform-drift",
    generated_at: $generated_at,
    discovery_mode: $discovery_mode,
    owner: $owner,
    summary: {
      repo_count: length,
      missing_readme_count: (map(select(.readme_present | not)) | length),
      missing_changelog_count: (map(select(.changelog_present | not)) | length),
      missing_codeowners_count: (map(select(.codeowners_present | not)) | length),
      missing_security_count: (map(select(.security_present | not)) | length),
      missing_renovate_count: (map(select(.renovate_present | not)) | length),
      missing_sonar_count: (map(select(.sonar_present | not)) | length),
      missing_workflows_count: (map(select(.workflow_count == 0)) | length)
    },
    repos: .
  }' "$report_jsonl" >"$report_json"
