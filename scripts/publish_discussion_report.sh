#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  publish_discussion_report.sh \
    --title "Report title" \
    --category "Discussion category" \
    --body-file path/to/report.md \
    --repo owner/repository \
    [--url-output path] \
    [--number-output path]
EOF
}

title=""
category=""
body_file=""
repo=""
url_output=""
number_output=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)
      title="${2:-}"
      shift 2
      ;;
    --category)
      category="${2:-}"
      shift 2
      ;;
    --body-file)
      body_file="${2:-}"
      shift 2
      ;;
    --repo)
      repo="${2:-}"
      shift 2
      ;;
    --url-output)
      url_output="${2:-}"
      shift 2
      ;;
    --number-output)
      number_output="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

: "${GH_TOKEN:?GH_TOKEN is required}"

if [[ -z "$title" || -z "$category" || -z "$body_file" || -z "$repo" ]]; then
  usage
  exit 1
fi

if [[ ! -f "$body_file" ]]; then
  echo "Body file not found: $body_file" >&2
  exit 1
fi

owner="${repo%%/*}"
name="${repo##*/}"

graphql() {
  local payload="$1"
  curl -fsSL \
    -H "Authorization: Bearer ${GH_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    https://api.github.com/graphql
}

repo_query='query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    id
    discussionCategories(first: 25) {
      nodes {
        id
        name
      }
    }
  }
}'

repo_payload="$(jq -n \
  --arg query "$repo_query" \
  --arg owner "$owner" \
  --arg name "$name" \
  '{query: $query, variables: {owner: $owner, name: $name}}')"

repo_response="$(graphql "$repo_payload")"

if jq -e '.errors' >/dev/null <<<"$repo_response"; then
  jq '.errors' <<<"$repo_response" >&2
  exit 1
fi

repo_id="$(jq -r '.data.repository.id // empty' <<<"$repo_response")"
category_id="$(jq -r --arg category "$category" '.data.repository.discussionCategories.nodes[] | select(.name == $category) | .id' <<<"$repo_response")"

if [[ -z "$repo_id" ]]; then
  echo "Unable to resolve repository id for $repo." >&2
  exit 1
fi

if [[ -z "$category_id" ]]; then
  echo "Discussion category \"$category\" was not found in $repo." >&2
  echo "Available categories:" >&2
  jq -r '.data.repository.discussionCategories.nodes[].name' <<<"$repo_response" >&2
  exit 1
fi

body="$(<"$body_file")"

create_mutation='mutation($repositoryId: ID!, $categoryId: ID!, $title: String!, $body: String!) {
  createDiscussion(input: {
    repositoryId: $repositoryId,
    categoryId: $categoryId,
    title: $title,
    body: $body
  }) {
    discussion {
      number
      url
    }
  }
}'

create_payload="$(jq -n \
  --arg query "$create_mutation" \
  --arg repositoryId "$repo_id" \
  --arg categoryId "$category_id" \
  --arg title "$title" \
  --arg body "$body" \
  '{query: $query, variables: {repositoryId: $repositoryId, categoryId: $categoryId, title: $title, body: $body}}')"

create_response="$(graphql "$create_payload")"

if jq -e '.errors' >/dev/null <<<"$create_response"; then
  jq '.errors' <<<"$create_response" >&2
  exit 1
fi

discussion_url="$(jq -r '.data.createDiscussion.discussion.url // empty' <<<"$create_response")"
discussion_number="$(jq -r '.data.createDiscussion.discussion.number // empty' <<<"$create_response")"

if [[ -z "$discussion_url" ]]; then
  echo "Discussion creation did not return a URL." >&2
  exit 1
fi

if [[ -n "$url_output" ]]; then
  printf '%s\n' "$discussion_url" >"$url_output"
fi

if [[ -n "$number_output" ]]; then
  printf '%s\n' "$discussion_number" >"$number_output"
fi

printf '%s\n' "$discussion_url"
