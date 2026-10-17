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

# 稳定签名:同一证书能让 TCC/钥匙串授权跨构建保留。
CERT_NAME="HIVE's Harness Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$CERT_NAME"; then
  codesign --force --deep --sign "$CERT_NAME" --identifier com.hiveharness.app "$APP" >/dev/null
  codesign --verify --deep --strict "$APP"
  echo "🔐 已用稳定身份签名: $CERT_NAME"
else
  echo "⚠️ 未找到本地稳定签名身份,本次使用 ad-hoc 签名(每次构建都会重新授权)。"
  echo "   运行 scripts/setup_signing.sh 一次即可解决。"
  codesign --force --deep --sign - --identifier com.hiveharness.app "$APP" >/dev/null
fi

echo "✅ 已生成 $APP"
echo "启动: open $APP"
