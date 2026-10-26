#!/bin/bash
# shellcheck disable=SC2016 # '$(' is looked for as it is: the start of a build variable left unexpanded
# Checks that a signed Ogura.app may register the connection it registers: the name its signature lets the sandbox
# register (com.apple.security.temporary-exception.mach-register.global-name) is Info.plist's
# InputMethodConnectionName, with no build variable left unexpanded there or in any other entitlement. When they
# differ, the sandbox refuses the registration and macOS cannot reach the input method through that connection (an
# ad-hoc signature given the entitlements file as it is: see Tools/sign_adhoc.sh).
#
# Usage: Tools/check_connection_entitlement.sh <app>
# Exit: 0 the same name and no variable left · 1 not (what differs printed)
set -uo pipefail
APP="${1:?app}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
CONNECTION="$(/usr/libexec/PlistBuddy -c "Print InputMethodConnectionName" "${APP}/Contents/Info.plist" 2>/dev/null)"
codesign -d --entitlements - --xml "${APP}" > "${WORK}/entitlements.plist" 2>/dev/null
GRANTED="$(/usr/libexec/PlistBuddy -c "Print :com.apple.security.temporary-exception.mach-register.global-name" "${WORK}/entitlements.plist" 2>/dev/null)"
if [ -z "${CONNECTION}" ] || [ "${GRANTED}" != "${CONNECTION}" ] || [[ "${GRANTED}" == *'$('* ]]; then
    echo "the connection the input method registers (Info.plist): '${CONNECTION}'; the name its signature lets it register: '${GRANTED}'"
    exit 1
fi
# No other entitlement may keep a build variable either
if grep -q '\$(' "${WORK}/entitlements.plist"; then
    echo "a build variable is left unexpanded in the signed entitlements:"
    grep '\$(' "${WORK}/entitlements.plist"
    exit 1
fi
echo "connection name granted: ${GRANTED}"
