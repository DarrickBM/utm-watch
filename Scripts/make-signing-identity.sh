#!/bin/bash
# Creates, once, the self-signed certificate that release builds are signed with, and puts it in the login keychain.
#
# Why: macOS keeps a privacy permission (Full Disk Access, "Control UTM") for the app whose signature matches the
# requirement it recorded when the permission was given. An ad-hoc signature's requirement is the build's own hash,
# so every update looked like a new app and lost its permissions. A signature made with one lasting certificate has
# a requirement that names that certificate instead, and every later build signed with it still matches.
#
# The certificate names the app only (no email or other personal detail) and costs nothing. Gatekeeper does not
# trust it, which changes nothing for users: downloads were already unnotarized and are opened the same way.
#
# The key stays outside the repository, in $SIGNING_DIR (a copy to back up) and in the login keychain (what codesign
# uses). Losing it means the next release has a new requirement and users grant the permissions once more.
# Usage: Scripts/make-signing-identity.sh          creates it if missing, or imports the saved copy into the keychain
set -euo pipefail

NAME="UTM Watch Release"
SIGNING_DIR="${SIGNING_DIR:-$HOME/.utmwatch-signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "\"$NAME\" is already in the login keychain."
  security find-certificate -c "$NAME" -Z "$KEYCHAIN" | awk '/SHA-1/ {print "SHA-1: " $3}'
  exit 0
fi

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"
if [ ! -f "$SIGNING_DIR/cert.pem" ]; then
  cat > "$SIGNING_DIR/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
  # Twenty years: the certificate only has to keep naming the same key, and macOS does not check its dates here.
  openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$SIGNING_DIR/cert.cnf" \
    -keyout "$SIGNING_DIR/key.pem" -out "$SIGNING_DIR/cert.pem"
  chmod 600 "$SIGNING_DIR/key.pem"
  echo "Created $SIGNING_DIR/cert.pem and key.pem. Back this folder up: it is what keeps users' permissions."
fi

# The keychain takes keys as PKCS#12 with the older ciphers. The passphrase only protects this temporary file.
P12="$(mktemp -t utmwatch-signing).p12"
trap 'rm -f "$P12"' EXIT
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -name "$NAME" -inkey "$SIGNING_DIR/key.pem" -in "$SIGNING_DIR/cert.pem" \
  -out "$P12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -name "$NAME" -inkey "$SIGNING_DIR/key.pem" -in "$SIGNING_DIR/cert.pem" -out "$P12" -passout "pass:$PASS"
# -T lets codesign use the key without asking each time.
security import "$P12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign
echo "Imported \"$NAME\" into the login keychain."
openssl x509 -in "$SIGNING_DIR/cert.pem" -noout -fingerprint -sha1
