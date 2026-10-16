#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGN_IDENTITY="${HALO_SIGN_IDENTITY:-}"
if [ -z "$SIGN_IDENTITY" ] && [ -f .native/signing-identity.txt ]; then SIGN_IDENTITY="$(cat .native/signing-identity.txt)"; fi
if [ -z "$SIGN_IDENTITY" ]; then SIGN_IDENTITY="Mercy Local Signing"; fi
CHECK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/halo-signing-check.XXXXXX")"
cleanup() { /bin/rm -f "$CHECK_DIR/first" "$CHECK_DIR/second"; /bin/rmdir "$CHECK_DIR"; }
trap cleanup EXIT
cp /usr/bin/true "$CHECK_DIR/first"
cp /usr/bin/printf "$CHECK_DIR/second"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --identifier app.halo.native.dev "$CHECK_DIR/first"
codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --identifier app.halo.native.dev "$CHECK_DIR/second"
REQUIREMENT="$(codesign -d -r- build/Halo.app 2>&1 | sed -n 's/^designated => //p')"
case "$REQUIREMENT" in
    *'certificate leaf = H'* ) ;;
    *) printf 'FAIL: Halo still lacks a certificate-based designated requirement.\n' >&2; exit 1 ;;
esac
codesign --verify --strict -R "=$REQUIREMENT" "$CHECK_DIR/first"
codesign --verify --strict -R "=$REQUIREMENT" "$CHECK_DIR/second"
FIRST_HASH="$(codesign -dvvvv "$CHECK_DIR/first" 2>&1 | sed -n 's/^CDHash=//p')"
SECOND_HASH="$(codesign -dvvvv "$CHECK_DIR/second" 2>&1 | sed -n 's/^CDHash=//p')"
test -n "$FIRST_HASH"
test -n "$SECOND_HASH"
test "$FIRST_HASH" != "$SECOND_HASH"
printf 'PASS: different code hashes both satisfy Halo’s certificate-based identity; future code changes do not inherently change its designated requirement.\n'
