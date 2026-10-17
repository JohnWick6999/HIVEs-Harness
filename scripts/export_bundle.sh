#!/bin/bash
# 导出完整仓库历史为 git bundle,便于在没有网络/没有远程仓库时迁移。
# 产物:build/ShizukuClaw.bundle
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
git bundle create build/ShizukuClaw.bundle --all
echo "✅ 已生成 build/ShizukuClaw.bundle"
echo "在新位置恢复: git clone build/ShizukuClaw.bundle ShizukuClaw"
