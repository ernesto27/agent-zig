#!/usr/bin/env bash
set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: $0 <session.jsonl>" >&2
    exit 1
fi

input="$1"

if [ ! -f "$input" ]; then
    echo "Error: file not found: $input" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

jq -r '
  select(.type=="user" or .type=="assistant") |
  (if .type=="user" then "you:" else "ia:" end) as $who |
  ( .message.content
    | if type=="string" then .
      else (map(select(.type=="text") | .text) | join("\n"))
      end
  ) as $text |
  select($text != null and $text != "") |
  "\($who) \($text)\n"
' "$input"
