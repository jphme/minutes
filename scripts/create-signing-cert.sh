#!/usr/bin/env bash
# Creates a self-signed code-signing certificate "Minutes Local Signing" in the login keychain, so
# rebuilt versions of Minutes keep their microphone/system-audio permissions. Run once.
# Remove it later with: security delete-identity -c "Minutes Local Signing"
set -euo pipefail
if security find-certificate -c "Minutes Local Signing" >/dev/null 2>&1; then
  echo "Certificate already exists."; exit 0
fi
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
cat > "$D/cert.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = Minutes Local Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$D/key.pem" -out "$D/cert.pem" -days 3650 -config "$D/cert.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout pass:minutes -name "Minutes Local Signing" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$D/key.pem" -in "$D/cert.pem" -out "$D/id.p12" -passout pass:minutes -name "Minutes Local Signing"
security import "$D/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P minutes -T /usr/bin/codesign
# Let codesign use the key without a keychain prompt on every build (asks for the login password once).
security set-key-partition-list -S apple-tool:,apple:,codesign: -s "$HOME/Library/Keychains/login.keychain-db" >/dev/null \
  || echo "Could not update the key's access list; approve the keychain prompt with 'Always Allow' on the first build."
echo "Created 'Minutes Local Signing'. Rebuild with scripts/build-app.sh."
