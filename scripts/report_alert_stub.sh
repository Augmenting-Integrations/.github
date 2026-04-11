#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF' >&2
Usage:
  report_alert_stub.sh \
    --kind newsletter \
    --title "Report title" \
    --discussion-url https://github.com/... \
    [--output-file path]
EOF
}

kind=""
title=""
discussion_url=""
output_file=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kind)
      kind="${2:-}"
      shift 2
      ;;
    --title)
      title="${2:-}"
      shift 2
      ;;
    --discussion-url)
      discussion_url="${2:-}"
      shift 2
      ;;
    --output-file)
      output_file="${2:-}"
      shift 2
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$kind" || -z "$title" || -z "$discussion_url" ]]; then
  usage
  exit 1
fi

alerting_enabled="${ALERTING_STUB_ENABLED:-false}"
alerting_note="${ALERTING_STUB_NOTE:-Wire a downstream notifier here later.}"

payload="$(cat <<EOF
# Alerting Stub

- Report kind: ${kind}
- Report title: ${title}
- Discussion: ${discussion_url}
- Alerting enabled: ${alerting_enabled}
- Note: ${alerting_note}

This workflow intentionally stops at discussion publication for now.
Replace this stub with Microsoft Teams, email, or another downstream notifier when ready.
EOF
)"

if [[ -n "$output_file" ]]; then
  printf '%s\n' "$payload" >"$output_file"
else
  printf '%s\n' "$payload"
fi
