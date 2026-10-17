#!/bin/bash
# 运行 ShizukuCore 测试。
#
# 为什么需要这个脚本:
#   Command Line Tools 自带的 Swift Testing 宏插件在
#   usr/lib/swift/host/plugins/testing/ 下,swift-driver 默认不会加载,
#   直接 `swift test` 会报 "plugin for module 'TestingMacros' not found"。
#   改用 Xcode / Xcode-beta 的完整工具链即可正常执行。
#
# 用法: scripts/test.sh [swift test 的其余参数]
set -euo pipefail
cd "$(dirname "$0")/.."

for DEVELOPER in \
  /Applications/Xcode.app/Contents/Developer \
  /Applications/Xcode-beta.app/Contents/Developer
do
  if [ -d "$DEVELOPER" ]; then
    export DEVELOPER_DIR="$DEVELOPER"
    break
  fi
done

exec swift test "$@"
