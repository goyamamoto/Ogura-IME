#!/bin/bash
# Build the pkg for distribution. The output is build/pkg/Ogura-<version>.pkg (it installs into /Library/Input Methods).
#
# Usage:
#   ./pkgbuild.sh --team <TEAM_ID>   Build a pkg signed with Developer ID and notarized (needs the Apple Developer Program)
#   ./pkgbuild.sh --unsigned         Build a pkg with no signing or notarization. Only for checking the contents; not for distribution
#
# Before a signed build, set up these once on this Mac:
#   - Developer ID Application and Developer ID Installer certificates (Xcode > Settings > Accounts > Manage Certificates)
#   - Notarization credentials: xcrun notarytool store-credentials "Notarytool" --apple-id <Apple ID> --team-id <TEAM_ID> --password <app-specific password>
#     (change the profile name with the environment variable OGURA_NOTARY_PROFILE)
#   - Metal Toolchain to compile the MLX shaders: xcodebuild -downloadComponent MetalToolchain
# The version comes from Xcode's MARKETING_VERSION (CFBundleShortVersionString). Raise it for every release.
set -euo pipefail

TEAM_ID="${OGURA_TEAM_ID:-}"
UNSIGNED=false
NOTARY_PROFILE="${OGURA_NOTARY_PROFILE:-Notarytool}"
INSTALLER_IDENTITY="${OGURA_INSTALLER_IDENTITY:-Developer ID Installer}"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --team) TEAM_ID="${2:?--team に Team ID を指定してください}"; shift ;;
        --unsigned) UNSIGNED=true ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ "$UNSIGNED" = false ] && [ -z "$TEAM_ID" ]; then
    echo "署名に使う Team ID を指定してください: ./pkgbuild.sh --team <TEAM_ID>（または環境変数 OGURA_TEAM_ID）"
    echo "証明書なしで中身だけを確認するには、./pkgbuild.sh --unsigned を実行してください。"
    exit 1
fi

cd "$(dirname "$0")"

if ! xcrun metal -v > /dev/null 2>&1; then
    echo "Metal Toolchain が見つかりません。xcodebuild -downloadComponent MetalToolchain を実行してインストールしてください。"
    exit 1
fi

OUT="build/pkg"
ARCHIVE_PATH="${OUT}/archive.xcarchive"
EXPORT_PATH="${OUT}/export"   # Contents of the pkg. Holds only Ogura.app
APP_PATH="${EXPORT_PATH}/Ogura.app"

# Delete only the previous pkg work folder (keep development folders such as build/DerivedData)
rm -rf "${OUT}"
mkdir -p "${OUT}"

set -x
if [ "$UNSIGNED" = true ]; then
    # Same build as install.sh --adhoc. It is ad-hoc signed, so it runs only on this Mac
    xcodebuild -project Ogura.xcodeproj -scheme Ogura -configuration Release \
        -derivedDataPath build/DerivedData build \
        -destination "generic/platform=macOS" ARCHS=arm64 \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
    mkdir -p "${EXPORT_PATH}"
    cp -R build/DerivedData/Build/Products/Release/Ogura.app "${APP_PATH}"
    codesign --force --deep --sign - --entitlements Ogura/Ogura.entitlements "${APP_PATH}"
else
    # Fetch dependencies fresh every time and do not reuse leftovers from earlier builds. MLX runs only on Apple Silicon, so build arm64 only
    xcodebuild -project Ogura.xcodeproj -scheme Ogura -configuration Release \
        clean archive \
        -archivePath "${ARCHIVE_PATH}" \
        -derivedDataPath "$(mktemp -d)" \
        -clonedSourcePackagesDirPath "$(mktemp -d)" \
        -destination "generic/platform=macOS" ARCHS=arm64 \
        DEVELOPMENT_TEAM="${TEAM_ID}" CODE_SIGN_STYLE=Automatic \
        ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
        -allowProvisioningUpdates
    xcodebuild -exportArchive \
        -archivePath "${ARCHIVE_PATH}" \
        -exportPath "${EXPORT_PATH}" \
        -exportOptionsPlist exportOptions.plist \
        -allowProvisioningUpdates
    rm -f "${EXPORT_PATH}/Packaging.log" "${EXPORT_PATH}/DistributionSummary.plist" "${EXPORT_PATH}/ExportOptions.plist"

    # Notarize the .app and staple the ticket
    ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${OUT}/Ogura.zip"
    xcrun notarytool submit "${OUT}/Ogura.zip" --keychain-profile "${NOTARY_PROFILE}" --wait
    xcrun stapler staple "${APP_PATH}"
    rm "${OUT}/Ogura.zip"
fi
codesign --verify --deep --strict "${APP_PATH}"

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"

pkgbuild --root "${EXPORT_PATH}" \
    --scripts pkg-scripts \
    --component-plist pkg.plist \
    --identifier org.if0.inputmethod.ogura \
    --version "${VERSION}" \
    --install-location "/Library/Input Methods" \
    "${OUT}/Ogura-component.pkg"

sed "s/@VERSION@/${VERSION}/g" distribution.xml > "${OUT}/distribution.xml"

if [ "$UNSIGNED" = true ]; then
    productbuild --distribution "${OUT}/distribution.xml" --package-path "${OUT}" "${OUT}/Ogura-${VERSION}-unsigned.pkg"
    rm "${OUT}/Ogura-component.pkg"
    set +x
    echo "作成しました: ${OUT}/Ogura-${VERSION}-unsigned.pkg（署名なし。配布には使えません）"
    exit 0
fi

productbuild --distribution "${OUT}/distribution.xml" --package-path "${OUT}" "${OUT}/Ogura-unsigned.pkg"
rm "${OUT}/Ogura-component.pkg"
productsign --sign "${INSTALLER_IDENTITY}" "${OUT}/Ogura-unsigned.pkg" "${OUT}/Ogura-${VERSION}.pkg"
rm "${OUT}/Ogura-unsigned.pkg"

# Notarize the pkg and staple the ticket
xcrun notarytool submit "${OUT}/Ogura-${VERSION}.pkg" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${OUT}/Ogura-${VERSION}.pkg"
pkgutil --check-signature "${OUT}/Ogura-${VERSION}.pkg"
set +x
echo "作成しました: ${OUT}/Ogura-${VERSION}.pkg"
