#!/bin/bash
# Create a stable self-signed code-signing identity ("Orchestra Dev") in the login keychain.
#
# Why: build-app.sh otherwise signs the app ad-hoc (`codesign -s -`), which produces a NEW code hash
# every build. macOS TCC ties permission grants (Screen Recording, Accessibility, …) to the app's
# code identity, so each rebuild looks like a brand-new app and the grant is dropped. Signing with a
# stable identity gives the app a constant designated requirement, so a grant given once persists
# across rebuilds.
#
# Run this ONCE, WITHOUT sudo (sudo would target root's keychain, which your build's codesign can't
# use). It's idempotent and only touches your login keychain.
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "error: don't run this with sudo — it must create the identity in YOUR login keychain," >&2
  echo "       not root's. Re-run as: scripts/make-dev-cert.sh" >&2
  exit 1
fi

CN="Orchestra Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$CN"; then
  echo "✓ '$CN' codesigning identity already exists."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CN
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

echo "Generating self-signed code-signing certificate '$CN' (10y)…"
openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -nodes -config "$TMP/cfg.cnf" >/dev/null 2>&1

# `-legacy` makes OpenSSL 3 write a SHA1/3DES PKCS#12 that Apple's `security import` can parse;
# without it OpenSSL 3's modern MAC fails with a misleading "MAC verification failed (wrong password?)".
# Fall back to the non-legacy form for OpenSSL 1.1 / LibreSSL, which don't accept `-legacy`.
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -passout pass:orchestra -name "$CN" >/dev/null 2>&1 \
|| openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
  -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -passout pass:orchestra -name "$CN" >/dev/null 2>&1

echo "Importing into login keychain (lets codesign use the key without prompting)…"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P orchestra -T /usr/bin/codesign -A

# Trust the cert for code signing in the user domain so `codesign --sign` accepts it.
echo "Trusting the certificate for code signing (you may be asked for your login password)…"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null || true

echo
if security find-identity -v -p codesigning "$KEYCHAIN" | grep -q "$CN"; then
  echo "✓ Done. '$CN' is ready. Rebuild with scripts/build-app.sh, then grant Orchestra"
  echo "  Screen Recording once — it will now persist across rebuilds."
else
  echo "⚠ '$CN' was imported but isn't showing as a valid codesigning identity yet."
  echo "  It may still work for signing; build-app.sh will fall back to ad-hoc if not."
fi
