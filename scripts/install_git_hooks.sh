#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
for hook_name in pre-commit pre-push; do
  HOOK="$ROOT/.git/hooks/$hook_name"
  if [ "$hook_name" = "pre-push" ]; then
    ARGS='--history'
  else
    ARGS=''
  fi
  cat > "$HOOK" <<HOOKEOF
#!/bin/sh
exec "\$(git rev-parse --show-toplevel)/scripts/check_secrets.sh" $ARGS
HOOKEOF
  chmod +x "$HOOK"
done
echo "Installed secret-scan pre-commit and pre-push hooks."
