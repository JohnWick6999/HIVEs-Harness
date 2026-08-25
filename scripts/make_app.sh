#!/bin/bash
# 组装最小 ShizukuClaw.app bundle(Alpha 阶段的 .app 化方案)
# 用法:scripts/make_app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-debug}"
APP="build/ShizukuClaw.app"

if [ "$CONFIG" = "release" ]; then
  swift build -c release
  PRODUCT_DIR=".build/out/Products/Release"
else
  swift build -c debug
  PRODUCT_DIR=".build/out/Products/Debug"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PRODUCT_DIR/ShizukuClaw" "$APP/Contents/MacOS/ShizukuClaw"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# 资源 bundle:ShizukuCore 的人格等资源必须随 app 打包,
# 否则 Bundle.module 会在启动时 fatal error
if [ -d "$PRODUCT_DIR/ShizukuCore_ShizukuCore.bundle" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp -R "$PRODUCT_DIR/ShizukuCore_ShizukuCore.bundle" "$APP/Contents/Resources/"
fi

echo "✅ 已生成 $APP"
echo "启动: open $APP"
