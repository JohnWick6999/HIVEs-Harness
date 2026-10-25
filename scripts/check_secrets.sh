#!/bin/bash
set -euo pipefail

# 检查常见真实凭据形态。只输出文件与行号，不输出命中值。
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
HISTORY=0
if [ "${1:-}" = "--history" ]; then HISTORY=1; fi

PATTERN='(sk-[0-9a-fA-F]{32}|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|(DEEPSEEK|OPENAI|ANTHROPIC)_API_KEY[[:space:]]*[=:][[:space:]]*[^[:space:]]+)'
fail=0

scan_ref() {
  local label="$1"; shift
  local hits
  hits="$(git grep -I -l -E "$PATTERN" "$@" -- 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    echo "ERROR: possible credential in $label:" >&2
    while IFS= read -r file; do
      echo "  $file" >&2
    done <<< "$hits"
    fail=1
  fi
}

if [ "$HISTORY" = "1" ]; then
  while IFS= read -r commit; do
    scan_ref "commit ${commit:0:10}" "$commit"
  done < <(git rev-list --all)
else
  scan_ref "working tree and staged files"
fi

if [ "$fail" -ne 0 ]; then
  echo "Secret scan failed. Remove the credential, rotate it, and use a dummy fixture." >&2
  exit 1
fi
echo "Secret scan passed."
