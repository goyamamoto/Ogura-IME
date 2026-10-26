#!/bin/bash
# Checks that a pkg replaces the installed app whatever version is installed: none of its bundles is checked for its
# version (pkg.plist: BundleIsVersionChecked false).
#
# A pkg that checks leaves a newer app as it is, and the installer still ends with "success": going back to an
# earlier version, or installing a trial build again, then changes nothing and says nothing. pkgbuild's own default
# is to check (a pkg.plist written anew by pkgbuild --analyze has it on), so the built pkg is looked at, not the
# property list: pkgbuild names the bundles it checks under <bundle-version> in the component's PackageInfo, and
# writes <bundle-version/> when there is none.
#
# Usage: Tools/check_pkg_version_check.sh <pkg>     (a component pkg, or a product archive with components in it)
# Exit: 0 no bundle is checked for its version · 1 one is (named) · 2 the pkg has no PackageInfo to read
set -uo pipefail
PKG="${1:?pkg}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

INFOS="$(xar -tf "${PKG}" 2>/dev/null | grep -E '(^|/)PackageInfo$')"
if [ -z "${INFOS}" ]; then
    echo "$(basename "${PKG}"): no PackageInfo in it"
    exit 2
fi
STATUS=0
while IFS= read -r info; do
    xar -xf "${PKG}" -C "${WORK}" "${info}" || exit 2
    CHECKED="$(tr -d '\n' < "${WORK}/${info}" | sed -n 's/.*<bundle-version>\(.*\)<\/bundle-version>.*/\1/p' | grep -o 'id="[^"]*"' | sed 's/^id="//; s/"$//' | tr '\n' ' ')"
    if [ -n "${CHECKED}" ]; then
        echo "$(basename "${PKG}"): ${info} checks the installed version of: ${CHECKED}"
        STATUS=1
    fi
done <<< "${INFOS}"
exit "${STATUS}"
