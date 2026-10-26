#!/bin/bash
# Signs an app ad hoc (no certificate) with the entitlements of Ogura/Ogura.entitlements, its build variables written
# in. codesign takes an entitlements file as it is; only Xcode's own signing expands $(PRODUCT_BUNDLE_IDENTIFIER). Left
# as it is, the sandbox lets the input method register a connection named "$(PRODUCT_BUNDLE_IDENTIFIER)_Connection"
# and refuses the name it really registers (Info.plist's InputMethodConnectionName), so macOS cannot reach the input
# method through that connection. The copy with the app's own bundle identifier is made in a temporary file and
# removed after.
#
# Usage: Tools/sign_adhoc.sh <app>
set -euo pipefail
APP="${1:?app}"
ENTITLEMENTS="$(dirname "$0")/../Ogura/Ogura.entitlements"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print CFBundleIdentifier" "${APP}/Contents/Info.plist")"
EXPANDED="$(mktemp -t ogura-entitlements)"
trap 'rm -f "${EXPANDED}"' EXIT
sed "s/\$(PRODUCT_BUNDLE_IDENTIFIER)/${BUNDLE_ID}/g" "${ENTITLEMENTS}" > "${EXPANDED}"
codesign --force --deep --sign - --entitlements "${EXPANDED}" "${APP}"
