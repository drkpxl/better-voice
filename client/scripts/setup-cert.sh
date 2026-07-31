#!/bin/bash
# Create a self-signed code signing certificate "Better Voice Development"
# so macOS TCC permissions persist across rebuilds (ad-hoc signing changes
# the hash every time, which resets already-granted permissions).
set -euo pipefail

CERT_NAME="Better Voice Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# 1. Check if the certificate already exists
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' already exists, skipping creation"
    exit 0
fi

echo "Creating self-signed code signing certificate '$CERT_NAME' ..."

# 2. Create a temporary working directory
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

CONF="$TMPDIR/cert.conf"
KEY="$TMPDIR/key.pem"
CERT="$TMPDIR/cert.pem"
P12="$TMPDIR/cert.p12"

# 3. Generate openssl config
cat > "$CONF" <<'OPENSSL_CONF'
[req]
distinguished_name = req_dn
x509_extensions = ext
prompt = no

[req_dn]
CN = Better Voice Development

[ext]
keyUsage = digitalSignature
extendedKeyUsage = codeSigning
basicConstraints = CA:FALSE
OPENSSL_CONF

# 4. Generate a self-signed certificate (10-year validity)
openssl req -x509 -newkey rsa:2048 \
    -keyout "$KEY" -out "$CERT" \
    -days 3650 -nodes \
    -config "$CONF" -extensions ext \
    -subj "/CN=$CERT_NAME" \
    2>/dev/null

echo "  Certificate generated"

# 5. Export as p12 format
# OpenSSL 3.x mishandles empty PKCS12 passwords, causing macOS `security import`
# to fail with "MAC verification failed". Use a temporary password as workaround.
# Also force legacy algorithms (3DES + SHA1) since OpenSSL 3.x defaults to
# AES-256-CBC which macOS can't read.
P12_PASS="setup-$(date +%s)"
openssl pkcs12 -export \
    -out "$P12" -inkey "$KEY" -in "$CERT" \
    -passout "pass:$P12_PASS" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg SHA1 \
    2>/dev/null \
|| openssl pkcs12 -export \
    -out "$P12" -inkey "$KEY" -in "$CERT" \
    -passout "pass:$P12_PASS" \
    2>/dev/null

echo "  Exported p12"

# 6. Import into login keychain
security import "$P12" \
    -k "$KEYCHAIN" \
    -P "$P12_PASS" \
    -T /usr/bin/codesign

echo "  Imported into login keychain"

# 7. Trust the self-signed certificate for code signing
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$CERT"
echo "  Added code signing trust"

# 8. Set partition list (allows codesign to use the key without a prompt)
security set-key-partition-list \
    -S "apple-tool:,apple:" \
    -s -k "" \
    "$KEYCHAIN" \
    2>/dev/null || echo "  Note: set-key-partition-list needs an empty keychain password or manual confirmation"

# 9. Verify the certificate
echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
    echo "Certificate '$CERT_NAME' created successfully!"
    echo "You can now use 'make run' to build and launch (TCC permissions will persist across rebuilds)"
else
    echo "Error: certificate not found in keychain after creation"
    echo "Try checking manually: security find-identity -v -p codesigning"
    exit 1
fi
