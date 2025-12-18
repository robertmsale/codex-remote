#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script is macOS-only."
  exit 1
fi

if ! command -v security >/dev/null 2>&1; then
  echo "Missing required tool: security"
  exit 1
fi

if ! command -v codesign >/dev/null 2>&1; then
  echo "Missing required tool: codesign"
  exit 1
fi

KEYCHAIN="$(security login-keychain | tr -d '\"')"
if [[ -z "${KEYCHAIN}" ]]; then
  echo "Unable to determine login keychain path."
  exit 1
fi

echo "Login keychain: ${KEYCHAIN}"
echo "This will update your Keychain ACL so CLI tools (like codesign) can access your Apple Development private key."
echo

read -r -s -p "Login keychain password: " KEYCHAIN_PASSWORD
echo

security unlock-keychain -p "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "${KEYCHAIN_PASSWORD}" "${KEYCHAIN}"

echo
echo "Done. Now retry:"
echo "  flutter run -d macos"
echo "or:"
echo "  flutter build macos"

