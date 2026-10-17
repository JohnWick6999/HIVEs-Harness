#!/bin/bash
# 构建全部 target(App + 核心库),自动选择完整 Xcode 工具链。
# 用法: scripts/build.sh [release|debug] —— 默认 debug。
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh

CONFIG="${1:-debug}"
exec swift build -c "$CONFIG"
