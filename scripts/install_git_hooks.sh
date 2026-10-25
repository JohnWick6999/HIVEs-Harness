#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/.git/hooks/pre-commit"
cat > "$HOOK" <<'HOOKEOF'
#!/bin/sh
exec "$(git rev-parse --show-toplevel)/scripts/check_secrets.sh"
HOOKEOF
chmod +x "$HOOK"
echo "Installed secret-scan pre-commit hook."
