#!/bin/bash
# 组装最小 HiveHarness.app bundle(Alpha 阶段的 .app 化方案)
# 用法:scripts/make_app.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain.sh

CONFIG="${1:-debug}"
APP="build/HiveHarness.app"

if [ "$CONFIG" = "release" ]; then
  swift build -c release
  PRODUCT_DIR=".build/out/Products/Release"
else
  swift build -c debug
  PRODUCT_DIR=".build/out/Products/Debug"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$PRODUCT_DIR/HiveHarness" "$APP/Contents/MacOS/HiveHarness"
cp scripts/Info.plist "$APP/Contents/Info.plist"

# 资源 bundle:HiveHarnessCore 的人格等资源必须随 app 打包,
# 否则 Bundle.module 会在启动时 fatal error
RESOURCE_BUNDLE="$PRODUCT_DIR/HiveHarness_HiveHarnessCore.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  RESOURCE_BUNDLE="$PRODUCT_DIR/HiveHarnessCore_HiveHarnessCore.bundle"
fi
if [ -d "$RESOURCE_BUNDLE" ]; then
  mkdir -p "$APP/Contents/Resources"
  cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"
fi

echo "✅ 已生成 $APP"
echo "启动: open $APP"
