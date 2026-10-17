#!/bin/bash
# 一次性创建本地代码签名身份,让 TCC/钥匙串“始终允许”能跨构建保留。
# 私钥只存本机 Application Support,权限 600;不会写入仓库。
set -euo pipefail

CERT_NAME="HIVE's Harness Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
SIGN_DIR="$HOME/Library/Application Support/HiveHarness/signing"
CERT="$SIGN_DIR/hive-signing-cert.pem"
KEY="$SIGN_DIR/hive-signing-key.pem"
P12="$SIGN_DIR/hive-signing-identity.p12"

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$CERT_NAME"; then
  echo "✅ 已存在签名身份: $CERT_NAME"
  exit 0
fi

mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"

if [ ! -f "$CERT" ] || [ ! -f "$KEY" ]; then
  echo "生成自签名代码签名证书(仅本机)..."
  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$KEY" -out "$CERT" -days 3650 \
    -subj "/CN=$CERT_NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
  chmod 600 "$KEY" "$CERT"
fi

PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -out "$P12" \
  -inkey "$KEY" -in "$CERT" -name "$CERT_NAME" -passout "pass:$PASS" >/dev/null 2>&1

echo "导入登录钥匙串(系统可能要求解锁/允许)..."
security import "$P12" -k "$KEYCHAIN" -P "$PASS" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
rm -f "$P12"

echo "信任本地签名证书..."
security add-trusted-cert -r trustRoot -k "$KEYCHAIN" "$CERT" >/dev/null 2>&1 || true

if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$CERT_NAME"; then
  echo "✅ 签名身份已就绪: $CERT_NAME"
  echo "重新构建并启动 App;首次访问文档/钥匙串时点一次“始终允许”。"
else
  echo "⚠️ 身份导入后仍不可用;请在钥匙串访问中检查证书信任设置。"
  exit 1
fi
