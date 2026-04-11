#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  generate_newsletter_report.sh \
    --since YYYY-MM-DD \
    --until YYYY-MM-DD \
    [--team-map .github/reporting/teams.json] \
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

if [[ -z "$since" || -z "$until" || -z "$owner" || -z "$out_dir" ]]; then
  usage
  exit 1
fi

mkdir -p "$out_dir"

teams_dir="${out_dir}/teams"
report_md="${out_dir}/newsletter.md"
index_json="${out_dir}/newsletter-index.json"
team_index_jsonl="${out_dir}/newsletter-teams.jsonl"

mkdir -p "$teams_dir"
: >"$team_index_jsonl"

generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
since_ts="${since}T00:00:00Z"
until_ts="${until}T23:59:59Z"

token_guidance() {
  cat <<'EOF' >&2
This newsletter workflow requires GH_TOKEN to be a fine-grained PAT or equivalent with:
- Resource owner set to the organization
- Repository access set to all organization repositories
- Organization permission: Members (read)
- Repository permissions: Metadata (read), Contents (read), Discussions (write)

If the organization requires PAT approval, make sure the token has been approved before use.
EOF
}

gh_api_json() {
  local endpoint="$1"
  local purpose="$2"
  local err_file
  err_file="$(mktemp)"

  if gh api "$endpoint" 2>"$err_file"; then
    rm -f "$err_file"
    return 0
  fi

  {
    echo "Failed to ${purpose}."
    echo "Endpoint: ${endpoint}"
    cat "$err_file"
    echo
    token_guidance
  } >&2
  rm -f "$err_file"
  exit 1
}

gh_array() {
  local endpoint="$1"
  local purpose="$2"
  local err_file
  err_file="$(mktemp)"

  if gh api --paginate "$endpoint" 2>"$err_file" | jq -s '
    if length == 0 then
      []
    elif all(.[]; type == "array") then
      add
    else
      []
    end
  '; then
    rm -f "$err_file"
    return 0
  fi

  {
    echo "Failed to ${purpose}."
    echo "Endpoint: ${endpoint}"
    cat "$err_file"
    echo
    token_guidance
  } >&2
  rm -f "$err_file"
  exit 1
}

has_path() {
  local repo="$1"
  local branch="$2"
  local path="$3"
  gh api "/repos/${repo}/contents/${path}?ref=${branch}" >/dev/null 2>&1
}

branch_exists() {
  local repo="$1"
  local branch="$2"
  gh api "/repos/${repo}/branches/${branch}" >/dev/null 2>&1
}

commits_for_ref() {
  local repo="$1"
  local ref="$2"
  gh_array \
    "/repos/${repo}/commits?sha=${ref}&since=${since_ts}&until=${until_ts}&per_page=100" \
    "list commits for ${repo}@${ref}"
}

append_branch_history() {
  local report_file="$1"
  local repo="$2"
  local branch="$3"
  local environment_name="$4"

  if ! branch_exists "$repo" "$branch"; then
    echo "- \`${branch}\` (${environment_name}): branch not present" >>"$report_file"
    printf 'missing\t0\n'
    return 0
  fi

  local branch_commits_json
  local branch_commit_count
  branch_commits_json="$(commits_for_ref "$repo" "$branch")"
  branch_commit_count="$(jq 'length' <<<"$branch_commits_json")"

  if [[ "$branch_commit_count" -eq 0 ]]; then
    echo "- \`${branch}\` (${environment_name}): no commits in window" >>"$report_file"
    printf 'no-commits\t0\n'
    return 0
  fi

  echo "- \`${branch}\` (${environment_name}): ${branch_commit_count} commits" >>"$report_file"
  jq -r '.[0:10][]? | "  - `\(.sha[0:7])` \(.commit.author.date[0:10]): \(.commit.message | split("\n")[0])"' <<<"$branch_commits_json" >>"$report_file"
  printf 'active\t%s\n' "$branch_commit_count"
}

team_override_count=0
if [[ -n "$team_map" && -f "$team_map" ]]; then
  team_override_count="$(jq '.teams | length' "$team_map" 2>/dev/null || echo 0)"
fi

if [[ "$team_override_count" -gt 0 ]]; then
  discovery_mode="api-repos-for-configured-teams"
  mapfile -t team_source < <(
    jq -cr '
      .teams[]
      | {
          slug: (.slug // (.name | ascii_downcase | gsub("[^a-z0-9]+"; "-"))),
          name: (.name // .slug),
          discussion_team_mention: (.discussion_team_mention // "")
        }
    ' "$team_map"
  )
else
  discovery_mode="api-team-discovery"
  teams_json="$(gh_array "/orgs/${owner}/teams?per_page=100" "list organization teams for ${owner}")"
  mapfile -t team_source < <(
    jq -cr '
      .[]
      | {
          slug: .slug,
          name: .name,
          discussion_team_mention: ""
        }
    ' <<<"$teams_json"
  )
fi

if [[ "${#team_source[@]}" -eq 0 ]]; then
  cat >"$report_md" <<EOF
# Team Weekly Updates

Window: ${since} to ${until}
Generated at: ${generated_at}
Discovery mode: ${discovery_mode}

## Status

- No teams were discovered.
- If you expected private-team coverage, ensure \`GH_TOKEN\` can read organization team metadata and private repositories.
EOF

  jq -n \
    --arg generated_at "$generated_at" \
    --arg since "$since" \
    --arg until "$until" \
    --arg discovery_mode "$discovery_mode" \
    '{
      report_type: "team-newsletter-index",
      generated_at: $generated_at,
      since: $since,
      until: $until,
      discovery_mode: $discovery_mode,
      summary: {
        team_count: 0,
        repo_count: 0,
        commit_count: 0,
        feature_count: 0,
        fix_count: 0,
        changelog_drift_count: 0
      },
      teams: []
    }' >"$index_json"
  exit 0
fi

org_total_commits=0
org_total_features=0
org_total_fixes=0
org_missing_changelog=0
processed_team_count=0
processed_repo_count=0

for team_json in "${team_source[@]}"; do
  [[ -z "$team_json" ]] && continue

  team_name="$(jq -r '.name' <<<"$team_json")"
  team_slug="$(jq -r '.slug' <<<"$team_json")"
  team_mention="$(jq -r '.discussion_team_mention // empty' <<<"$team_json")"

  repos_json="$(gh_array \
    "/orgs/${owner}/teams/${team_slug}/repos?per_page=100" \
    "list repositories for team ${team_slug}")"
  mapfile -t team_repos < <(
    jq -r '
      .[]
      | select((.archived // false) | not)
      | select((.disabled // false) | not)
      | .full_name
    ' <<<"$repos_json" | awk '!seen[$0]++'
  )

  if [[ "${#team_repos[@]}" -eq 0 ]]; then
    continue
  fi

  team_body_md="$(mktemp)"
  team_repo_jsonl="$(mktemp)"
  : >"$team_body_md"
  : >"$team_repo_jsonl"

  team_repo_count=0
  team_total_commits=0
  team_total_features=0
  team_total_fixes=0
  team_missing_changelog=()

  for full_repo in "${team_repos[@]}"; do
    repo_meta="$(gh_api_json "/repos/${full_repo}" "read repository metadata for ${full_repo}")"

    team_repo_count=$((team_repo_count + 1))
    processed_repo_count=$((processed_repo_count + 1))
    default_branch="$(jq -r '.default_branch' <<<"$repo_meta")"

    commits_json="$(commits_for_ref "$full_repo" "$default_branch")"
    changelog_commits_json="$(gh_array \
      "/repos/${full_repo}/commits?sha=${default_branch}&path=CHANGELOG.md&since=${since_ts}&until=${until_ts}&per_page=100" \
      "list CHANGELOG commits for ${full_repo}@${default_branch}")"

    commit_count="$(jq 'length' <<<"$commits_json")"
    feature_count="$(jq '[.[].commit.message | split("\n")[0] | ascii_downcase | select(test("^feat(\\(.+\\))?!?: "))] | length' <<<"$commits_json")"
    fix_count="$(jq '[.[].commit.message | split("\n")[0] | ascii_downcase | select(test("^fix(\\(.+\\))?!?: "))] | length' <<<"$commits_json")"
    perf_count="$(jq '[.[].commit.message | split("\n")[0] | ascii_downcase | select(test("^perf(\\(.+\\))?!?: "))] | length' <<<"$commits_json")"
    refactor_count="$(jq '[.[].commit.message | split("\n")[0] | ascii_downcase | select(test("^refactor(\\(.+\\))?!?: "))] | length' <<<"$commits_json")"

    highlights="$(jq -r '[.[].commit.message | split("\n")[0] | select(test("^(feat|fix|perf|refactor)(\\(.+\\))?!?: "; "i"))][0:5][]' <<<"$commits_json")"
    if [[ -z "$highlights" ]]; then
      highlights="$(jq -r '.[0:5][]?.commit.message | split("\n")[0]' <<<"$commits_json")"
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
      echo "- Default-branch commits in window: ${commit_count}"
      echo "- Conventional commit signals on \`${default_branch}\`: feat=${feature_count}, fix=${fix_count}, perf=${perf_count}, refactor=${refactor_count}"
      echo "- CHANGELOG.md: ${changelog_status}"
      if [[ -n "$highlights" ]]; then
        echo "- Highlights on \`${default_branch}\`:"
        while IFS= read -r subject; do
          [[ -z "$subject" ]] && continue
          echo "  - ${subject}"
        done <<<"$highlights"
      fi
      echo "- Last week of git history on deployment branches:"
    } >>"$team_body_md"

    IFS=$'\t' read -r dev_branch_status dev_branch_commit_count < <(
      append_branch_history "$team_body_md" "$full_repo" "dev" "staging"
    )
    IFS=$'\t' read -r main_branch_status main_branch_commit_count < <(
      append_branch_history "$team_body_md" "$full_repo" "main" "production"
    )

    echo >>"$team_body_md"

    jq -nc \
      --arg team_slug "$team_slug" \
      --arg team_name "$team_name" \
      --arg repo "$full_repo" \
      --arg default_branch "$default_branch" \
      --arg changelog_status "$changelog_status" \
      --arg dev_branch_status "$dev_branch_status" \
      --arg main_branch_status "$main_branch_status" \
      --argjson commit_count "$commit_count" \
      --argjson feature_count "$feature_count" \
      --argjson fix_count "$fix_count" \
      --argjson perf_count "$perf_count" \
      --argjson refactor_count "$refactor_count" \
      --argjson dev_branch_commit_count "$dev_branch_commit_count" \
      --argjson main_branch_commit_count "$main_branch_commit_count" \
      --argjson highlights "$(jq -Rsc 'split("\n") | map(select(length > 0))' <<<"$highlights")" \
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
        dev_branch: {
          status: $dev_branch_status,
          commit_count: $dev_branch_commit_count
        },
        main_branch: {
          status: $main_branch_status,
          commit_count: $main_branch_commit_count
        },
        highlights: $highlights
      }' >>"$team_repo_jsonl"
  done

  if [[ "$team_repo_count" -eq 0 ]]; then
    rm -f "$team_body_md" "$team_repo_jsonl"
    continue
  fi

  processed_team_count=$((processed_team_count + 1))

  team_markdown_file="${teams_dir}/${team_slug}.md"
  team_json_file="${teams_dir}/${team_slug}.json"

  {
    echo "# ${team_name} Weekly Update"
    echo
    echo "Window: ${since} to ${until}"
    echo "Generated at: ${generated_at}"
    echo "Discovery mode: ${discovery_mode}"
    echo
    if [[ -n "$team_mention" ]]; then
      echo "${team_mention}"
      echo
    fi
    echo "## Executive Summary"
    echo
    echo "- Repositories covered: ${team_repo_count}"
    echo "- Default-branch commits in window: ${team_total_commits}"
    echo "- Features shipped: ${team_total_features}"
    echo "- Bugs fixed: ${team_total_fixes}"
    if [[ "${#team_missing_changelog[@]}" -gt 0 ]]; then
      echo "- Repositories with code changes but no CHANGELOG.md update:"
      printf '  - %s\n' "${team_missing_changelog[@]}"
    else
      echo "- CHANGELOG.md drift: no issues detected in this window"
    fi
    echo
    echo "## Repository Updates"
    echo
    cat "$team_body_md"
  } >"$team_markdown_file"

  jq -s \
    --arg generated_at "$generated_at" \
    --arg since "$since" \
    --arg until "$until" \
    --arg discovery_mode "$discovery_mode" \
    --arg team_slug "$team_slug" \
    --arg team_name "$team_name" \
    --arg team_mention "$team_mention" \
    --arg markdown_file "$team_markdown_file" \
    --argjson repo_count "$team_repo_count" \
    --argjson commit_count "$team_total_commits" \
    --argjson feature_count "$team_total_features" \
    --argjson fix_count "$team_total_fixes" \
    --argjson changelog_drift_count "${#team_missing_changelog[@]}" \
    '{
      report_type: "team-weekly-update",
      generated_at: $generated_at,
      since: $since,
      until: $until,
      discovery_mode: $discovery_mode,
      team: {
        slug: $team_slug,
        name: $team_name,
        discussion_team_mention: $team_mention
      },
      summary: {
        repo_count: $repo_count,
        commit_count: $commit_count,
        feature_count: $feature_count,
        fix_count: $fix_count,
        changelog_drift_count: $changelog_drift_count
      },
      markdown_file: $markdown_file,
      repos: .
    }' "$team_repo_jsonl" >"$team_json_file"

  jq -nc \
    --arg slug "$team_slug" \
    --arg name "$team_name" \
    --arg discussion_team_mention "$team_mention" \
    --arg markdown_file "$team_markdown_file" \
    --arg json_file "$team_json_file" \
    --argjson repo_count "$team_repo_count" \
    --argjson commit_count "$team_total_commits" \
    --argjson feature_count "$team_total_features" \
    --argjson fix_count "$team_total_fixes" \
    --argjson changelog_drift_count "${#team_missing_changelog[@]}" \
    '{
      slug: $slug,
      name: $name,
      discussion_team_mention: $discussion_team_mention,
      markdown_file: $markdown_file,
      json_file: $json_file,
      repo_count: $repo_count,
      commit_count: $commit_count,
      feature_count: $feature_count,
      fix_count: $fix_count,
      changelog_drift_count: $changelog_drift_count
    }' >>"$team_index_jsonl"

  rm -f "$team_body_md" "$team_repo_jsonl"
done

if [[ "$processed_team_count" -eq 0 ]]; then
  cat >"$report_md" <<EOF
# Team Weekly Updates

Window: ${since} to ${until}
Generated at: ${generated_at}
Discovery mode: ${discovery_mode}

## Status

- No teams with visible repositories were discovered.
- If you expected private-team coverage, ensure \`GH_TOKEN\` can read organization team metadata and private repositories.
EOF

  jq -n \
    --arg generated_at "$generated_at" \
    --arg since "$since" \
    --arg until "$until" \
    --arg discovery_mode "$discovery_mode" \
    '{
      report_type: "team-newsletter-index",
      generated_at: $generated_at,
      since: $since,
      until: $until,
      discovery_mode: $discovery_mode,
      summary: {
        team_count: 0,
        repo_count: 0,
        commit_count: 0,
        feature_count: 0,
        fix_count: 0,
        changelog_drift_count: 0
      },
      teams: []
    }' >"$index_json"
  exit 0
fi

summary_line="Covered ${processed_team_count} teams across ${processed_repo_count} repositories. Default-branch commits: ${org_total_commits}. Features: ${org_total_features}. Fixes: ${org_total_fixes}. Repos with CHANGELOG drift: ${org_missing_changelog}."

{
  echo "# Team Weekly Updates"
  echo
  echo "Window: ${since} to ${until}"
  echo "Generated at: ${generated_at}"
  echo "Discovery mode: ${discovery_mode}"
  echo
  echo "## Executive Summary"
  echo
  echo "- ${summary_line}"
  echo
  echo "## Team Reports"
  echo
  jq -r '
    "- \(.name): \(.markdown_file)"
  ' "$team_index_jsonl"
} >"$report_md"

jq -s \
  --arg generated_at "$generated_at" \
  --arg since "$since" \
  --arg until "$until" \
  --arg discovery_mode "$discovery_mode" \
  '{
    report_type: "team-newsletter-index",
    generated_at: $generated_at,
    since: $since,
    until: $until,
    discovery_mode: $discovery_mode,
    summary: {
      team_count: length,
      repo_count: (map(.repo_count) | add // 0),
      commit_count: (map(.commit_count) | add // 0),
      feature_count: (map(.feature_count) | add // 0),
      fix_count: (map(.fix_count) | add // 0),
      changelog_drift_count: (map(.changelog_drift_count) | add // 0)
    },
    teams: .
  }' "$team_index_jsonl" >"$index_json"
