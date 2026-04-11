#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  generate_newsletter_report.sh \
    --since YYYY-MM-DD \
    --until YYYY-MM-DD \
    --team-map .github/reporting/teams.json \
    --owner octo-org \
    --out-dir out
EOF
}

since=""
until=""
team_map=""
owner=""
out_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      since="${2:-}"
      shift 2
      ;;
    --until)
      until="${2:-}"
      shift 2
      ;;
    --team-map)
      team_map="${2:-}"
      shift 2
      ;;
    --owner)
      owner="${2:-}"
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

if [[ -z "$since" || -z "$until" || -z "$team_map" || -z "$owner" || -z "$out_dir" ]]; then
  usage
  exit 1
fi

mkdir -p "$out_dir"

report_md="${out_dir}/newsletter.md"
report_jsonl="${out_dir}/newsletter-repos.jsonl"
report_json="${out_dir}/newsletter.json"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

gh_array() {
  local endpoint="$1"
  if ! gh api --paginate "$endpoint" 2>/dev/null | jq -s 'add // []'; then
    printf '[]\n'
  fi
}

has_path() {
  local repo="$1"
  local branch="$2"
  local path="$3"
  gh api "/repos/${repo}/contents/${path}?ref=${branch}" >/dev/null 2>&1
}

{
  echo "# Team Engineering Newsletter"
  echo
  echo "Window: ${since} to ${until}"
  echo "Generated at: ${generated_at}"
  echo
} >"$report_md"

: >"$report_jsonl"

team_count="$(jq '.teams | length' "$team_map" 2>/dev/null || echo 0)"

if [[ "$team_count" -eq 0 ]]; then
  cat >>"$report_md" <<'EOF'
## Status

- No teams are configured yet.
- Populate `.github/reporting/teams.json` and rerun this workflow.
EOF

  jq -n \
    --arg generated_at "$generated_at" \
    --arg since "$since" \
    --arg until "$until" \
    '{report_type: "team-newsletter", generated_at: $generated_at, since: $since, until: $until, teams: []}' >"$report_json"
  exit 0
fi

org_total_commits=0
org_total_features=0
org_total_fixes=0
org_missing_changelog=0

while IFS= read -r team_json; do
  team_name="$(jq -r '.name' <<<"$team_json")"
  team_slug="$(jq -r '.slug // (.name | ascii_downcase | gsub("[^a-z0-9]+"; "-"))' <<<"$team_json")"
  team_mention="$(jq -r '.discussion_team_mention // empty' <<<"$team_json")"
  repo_count="$(jq '.repos | length' <<<"$team_json")"

  {
    echo "## ${team_name}"
    echo
    if [[ -n "$team_mention" ]]; then
      echo "${team_mention}"
      echo
    fi
  } >>"$report_md"

  if [[ "$repo_count" -eq 0 ]]; then
    cat >>"$report_md" <<'EOF'
- No repositories are mapped to this team yet.

EOF
    continue
  fi

  team_total_commits=0
  team_total_features=0
  team_total_fixes=0
  team_missing_changelog=()

  while IFS= read -r repo_ref; do
    full_repo="$repo_ref"
    if [[ "$full_repo" != */* ]]; then
      full_repo="${owner}/${full_repo}"
    fi

    repo_meta="$(gh api "/repos/${full_repo}")"
    default_branch="$(jq -r '.default_branch' <<<"$repo_meta")"

    commits_endpoint="/repos/${full_repo}/commits?sha=${default_branch}&since=${since}T00:00:00Z&until=${until}T23:59:59Z&per_page=100"
    changelog_endpoint="/repos/${full_repo}/commits?sha=${default_branch}&path=CHANGELOG.md&since=${since}T00:00:00Z&until=${until}T23:59:59Z&per_page=100"

    commits_json="$(gh_array "$commits_endpoint")"
    changelog_commits_json="$(gh_array "$changelog_endpoint")"

    commit_count="$(jq 'length' <<<"$commits_json")"
    feature_count="$(jq '[.[].commit.message | split("\n")[0] | ascii_downcase | select(test("^feat(\\(.+\\))?!?: "))] | length' <<<"$commits_json")"
    fix_count="$(jq '[.[].commit.message | split("\n")[0] | ascii_downcase | select(test("^fix(\\(.+\\))?!?: "))] | length' <<<"$commits_json")"
    perf_count="$(jq '[.[].commit.message | split("\n")[0] | ascii_downcase | select(test("^perf(\\(.+\\))?!?: "))] | length' <<<"$commits_json")"
    refactor_count="$(jq '[.[].commit.message | split("\n")[0] | ascii_downcase | select(test("^refactor(\\(.+\\))?!?: "))] | length' <<<"$commits_json")"

    highlights="$(jq -r '[.[].commit.message | split("\n")[0] | select(test("^(feat|fix|perf|refactor)(\\(.+\\))?!?: "; "i"))][0:3][]' <<<"$commits_json")"
    if [[ -z "$highlights" ]]; then
      highlights="$(jq -r '.[0:3][]?.commit.message | split("\n")[0]' <<<"$commits_json")"
    fi

    if has_path "$full_repo" "$default_branch" "CHANGELOG.md"; then
      changelog_status="not updated"
      if [[ "$(jq 'length' <<<"$changelog_commits_json")" -gt 0 ]]; then
        changelog_status="updated"
      elif [[ "$commit_count" -gt 0 ]]; then
        team_missing_changelog+=("$full_repo")
        org_missing_changelog=$((org_missing_changelog + 1))
      fi
    else
      changelog_status="missing"
      if [[ "$commit_count" -gt 0 ]]; then
        team_missing_changelog+=("$full_repo")
        org_missing_changelog=$((org_missing_changelog + 1))
      fi
    fi

    team_total_commits=$((team_total_commits + commit_count))
    team_total_features=$((team_total_features + feature_count))
    team_total_fixes=$((team_total_fixes + fix_count))

    org_total_commits=$((org_total_commits + commit_count))
    org_total_features=$((org_total_features + feature_count))
    org_total_fixes=$((org_total_fixes + fix_count))

    {
      echo "### \`${full_repo}\`"
      echo
      echo "- Default branch: \`${default_branch}\`"
      echo "- Commits in window: ${commit_count}"
      echo "- Conventional commit signals: feat=${feature_count}, fix=${fix_count}, perf=${perf_count}, refactor=${refactor_count}"
      echo "- CHANGELOG.md: ${changelog_status}"
      if [[ -n "$highlights" ]]; then
        echo "- Highlights:"
        while IFS= read -r subject; do
          [[ -z "$subject" ]] && continue
          echo "  - ${subject}"
        done <<<"$highlights"
      fi
      echo
    } >>"$report_md"

    jq -nc \
      --arg team_slug "$team_slug" \
      --arg team_name "$team_name" \
      --arg repo "$full_repo" \
      --arg default_branch "$default_branch" \
      --arg changelog_status "$changelog_status" \
      --argjson commit_count "$commit_count" \
      --argjson feature_count "$feature_count" \
      --argjson fix_count "$fix_count" \
      --argjson perf_count "$perf_count" \
      --argjson refactor_count "$refactor_count" \
      --argjson highlights "$(jq -Rc 'split("\n") | map(select(length > 0))' <<<"$highlights")" \
      '{
        team_slug: $team_slug,
        team_name: $team_name,
        repo: $repo,
        default_branch: $default_branch,
        commit_count: $commit_count,
        feature_count: $feature_count,
        fix_count: $fix_count,
        perf_count: $perf_count,
        refactor_count: $refactor_count,
        changelog_status: $changelog_status,
        highlights: $highlights
      }' >>"$report_jsonl"
  done < <(jq -r '.repos[]' <<<"$team_json")

  {
    echo "### Team Summary"
    echo
    echo "- Repositories covered: ${repo_count}"
    echo "- Commits in window: ${team_total_commits}"
    echo "- Features shipped: ${team_total_features}"
    echo "- Bugs fixed: ${team_total_fixes}"
    if [[ "${#team_missing_changelog[@]}" -gt 0 ]]; then
      echo "- Repositories with code changes but no CHANGELOG.md update:"
      printf '  - %s\n' "${team_missing_changelog[@]}"
    else
      echo "- CHANGELOG.md status: no drift detected in this window"
    fi
    echo
  } >>"$report_md"
done < <(jq -c '.teams[]' "$team_map")

summary_line="Covered ${team_count} teams with ${org_total_commits} commits in total. Features: ${org_total_features}. Fixes: ${org_total_fixes}. Repos with CHANGELOG drift: ${org_missing_changelog}."

tmp_md="$(mktemp)"
{
  echo "# Executive Summary"
  echo
  echo "- ${summary_line}"
  echo
  cat "$report_md"
} >"$tmp_md"
mv "$tmp_md" "$report_md"

jq -s \
  --arg generated_at "$generated_at" \
  --arg since "$since" \
  --arg until "$until" \
  '{
    report_type: "team-newsletter",
    generated_at: $generated_at,
    since: $since,
    until: $until,
    summary: {
      team_count: ([.[].team_slug] | unique | length),
      repo_count: length,
      commit_count: (map(.commit_count) | add // 0),
      feature_count: (map(.feature_count) | add // 0),
      fix_count: (map(.fix_count) | add // 0),
      changelog_drift_count: (map(select(.changelog_status != "updated")) | map(select(.commit_count > 0)) | length)
    },
    teams: (
      group_by(.team_slug)
      | map({
          slug: .[0].team_slug,
          name: .[0].team_name,
          repos: map({
            repo: .repo,
            default_branch: .default_branch,
            commit_count: .commit_count,
            feature_count: .feature_count,
            fix_count: .fix_count,
            perf_count: .perf_count,
            refactor_count: .refactor_count,
            changelog_status: .changelog_status,
            highlights: .highlights
          })
        })
    )
  }' "$report_jsonl" >"$report_json"
