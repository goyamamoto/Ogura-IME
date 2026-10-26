#!/bin/bash
# Build the pkg for distribution. The output is build/pkg/Ogura-<version>.pkg (it installs into /Library/Input Methods).
#
# Usage:
#   ./pkgbuild.sh --team <TEAM_ID>   Build a pkg signed with Developer ID and notarized (needs the Apple Developer Program).
#                                    It installs like any other app
#   ./pkgbuild.sh --unsigned         Build a pkg whose app is ad-hoc signed and whose pkg is unsigned, for distribution without
#                                    the Developer Program. It runs on any Apple Silicon Mac, but Gatekeeper stops the downloaded
#                                    pkg once: the user allows it in System Settings > Privacy & Security ("Open Anyway") or
#                                    installs it from Terminal with `sudo installer -pkg <pkg> -target /`. Files the installer
#                                    puts in place carry no quarantine attribute, so the installed Ogura starts without
#                                    further warnings
#
# Either way, the genmai GGUF must be in place first (Tools/build_genmai_gguf.sh; it is not in the repository) and the
# submodule weights fetched; the script checks both. The installer's postinstall stops a running Ogura and registers the
# input source for the logged-in account with a helper compiled here from Tools/RegisterInputSource.swift.
#
# Before a signed build, set up these once on this Mac:
#   - Developer ID Application and Developer ID Installer certificates (Xcode > Settings > Accounts > Manage Certificates)
#   - Notarization credentials: xcrun notarytool store-credentials "Notarytool" --apple-id <Apple ID> --team-id <TEAM_ID> --password <app-specific password>
#     (change the profile name with the environment variable OGURA_NOTARY_PROFILE)
#   - Metal Toolchain to compile the MLX shaders: xcodebuild -downloadComponent MetalToolchain
# The version comes from Xcode's MARKETING_VERSION (CFBundleShortVersionString); raise it for every release. The build number
# (CFBundleVersion) is the number of commits in the history, set at build time.
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

# The build number (CFBundleVersion) is the number of commits in the history, so each build can be told apart
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if ! xcrun metal -v > /dev/null 2>&1; then
    echo "Metal Toolchain が見つかりません。xcodebuild -downloadComponent MetalToolchain を実行してインストールしてください。"
    exit 1
fi

# The models the app loads at run time. genmai's GGUF is built, not committed; the Zenzai weights are a submodule
# (a Git LFS pointer is about 134 bytes)
GENMAI="Ogura/Resources/genmai/ggml-model-Q5_K_M.gguf"
if [ ! -f "${GENMAI}" ] || [ "$(stat -f %z "${GENMAI}")" -lt 100000000 ]; then
    echo "genmai の GGUF（${GENMAI}）がありません。先に Tools/build_genmai_gguf.sh を実行してください。"
    exit 1
fi
ZENZ="Ogura/Resources/gguf/ggml-model-Q5_K_M.gguf"
if [ ! -f "${ZENZ}" ] || [ "$(stat -f %z "${ZENZ}")" -lt 10000000 ]; then
    echo "zenz-v3.2-small の重み（${ZENZ}）が無いか、LFS ポインタのままです。git submodule update --init --recursive と git lfs pull を実行してください。"
    exit 1
fi
# The supplementary dictionary is built, not committed (Ogura/Resources/Dictionary/supplement/README.md): it must be
# there, and be the one of this version (the committed list of its files' SHA-256). The check says what is wrong
if ! Tools/check_supplement_dictionary.sh; then
    echo "補助辞書を確かめてから実行してください（docs/development.md を参照）。"
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
    # Same build as install.sh --adhoc: ad-hoc signed. It runs on any Apple Silicon Mac; only Gatekeeper's check of the
    # downloaded pkg differs from a Developer ID build (see the top of this file)
    xcodebuild -project Ogura.xcodeproj -scheme Ogura -configuration Release \
        -derivedDataPath build/DerivedData build \
        -destination "generic/platform=macOS" ARCHS=arm64 \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
        ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
    mkdir -p "${EXPORT_PATH}"
    cp -R build/DerivedData/Build/Products/Release/Ogura.app "${APP_PATH}"
    # The entitlements with their build variables written in (codesign does not expand them; see the tool)
    Tools/sign_adhoc.sh "${APP_PATH}"
else
    # Fetch dependencies fresh every time and do not reuse leftovers from earlier builds. MLX runs only on Apple Silicon, so build arm64 only
    xcodebuild -project Ogura.xcodeproj -scheme Ogura -configuration Release \
        clean archive \
        -archivePath "${ARCHIVE_PATH}" \
        -derivedDataPath "$(mktemp -d)" \
        -clonedSourcePackagesDirPath "$(mktemp -d)" \
        -destination "generic/platform=macOS" ARCHS=arm64 \
        DEVELOPMENT_TEAM="${TEAM_ID}" CODE_SIGN_STYLE=Automatic \
        CURRENT_PROJECT_VERSION="${BUILD_NUMBER}" \
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
# The input method may register the connection it registers: the name its signature grants is Info.plist's
# InputMethodConnectionName, no build variable left unexpanded (else macOS cannot reach it through that connection)
if ! Tools/check_connection_entitlement.sh "${APP_PATH}"; then
    echo "署名が許す接続の名前が、アプリの InputMethodConnectionName と違います（Ogura.entitlements の変数が展開されていない）。"
    exit 1
fi

# Everything the app loads at run time must be in the bundle: the two conversion models, the personalization n-gram model,
# the reading judge, the supplementary dictionary, the Latin identification model, the license notices, llama.cpp
for f in Resources/genmai/ggml-model-Q5_K_M.gguf Resources/ggml-model-Q5_K_M.gguf Resources/lm_c_abc.marisa \
         Resources/ReadingJudge/model.mlmodelc Resources/Dictionary/supplement/supplement.louds Resources/ScriptModel \
         Resources/Licenses/NOTICE.md Frameworks/llama.framework; do
    if [ ! -e "${APP_PATH}/Contents/${f}" ]; then
        echo "アプリに ${f} が入っていません"
        exit 1
    fi
done

VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")"

# The installer scripts: postinstall plus the helper it runs as the logged-in user to register the input source.
# Built for the oldest macOS the pkg accepts, so it runs there too
SCRIPTS="${OUT}/scripts"
mkdir -p "${SCRIPTS}"
cp pkg-scripts/postinstall "${SCRIPTS}/postinstall"
swiftc -O -target arm64-apple-macos15.0 Tools/RegisterInputSource.swift -o "${SCRIPTS}/register-input-source"
chmod 755 "${SCRIPTS}/postinstall" "${SCRIPTS}/register-input-source"
if [ "$UNSIGNED" = false ]; then
    # Notarization checks every executable in the pkg, scripts included: sign the helper as the app is signed
    codesign --force --options runtime --timestamp --sign "Developer ID Application: ${TEAM_ID}" \
        "${SCRIPTS}/register-input-source" 2>/dev/null \
        || codesign --force --options runtime --timestamp --sign "Developer ID Application" "${SCRIPTS}/register-input-source"
fi

# pkg.plist says how the installed app is treated: replaced as a whole (files only the old version had are removed),
# never looked for in another place, and replaced whatever version is installed (BundleIsVersionChecked false).
# With that check on, the installer leaves a newer app as it is and still ends with "success": going back to an
# earlier version, or installing a build again, then changes nothing and says nothing.
pkgbuild --root "${EXPORT_PATH}" \
    --scripts "${SCRIPTS}" \
    --component-plist pkg.plist \
    --identifier org.if0.inputmethod.ogura \
    --version "${VERSION}" \
    --install-location "/Library/Input Methods" \
    "${OUT}/Ogura-component.pkg"
# The built pkg is looked at, not pkg.plist alone: pkgbuild's own default is to check the version
if ! Tools/check_pkg_version_check.sh "${OUT}/Ogura-component.pkg"; then
    echo "pkg が、入っている版を比べる設定でできました（新しい版の上からは入らず、インストーラーは成功と出します）。pkg.plist の BundleIsVersionChecked を false にしてください。"
    exit 1
fi

sed "s/@VERSION@/${VERSION}/g" distribution.xml > "${OUT}/distribution.xml"

if [ "$UNSIGNED" = true ]; then
    productbuild --distribution "${OUT}/distribution.xml" --package-path "${OUT}" "${OUT}/Ogura-${VERSION}-unsigned.pkg"
    rm "${OUT}/Ogura-component.pkg"
    set +x
    echo "作成しました: ${OUT}/Ogura-${VERSION}-unsigned.pkg"
    echo "アプリは ad-hoc 署名、pkg は無署名です。ダウンロードした人は、初めて開くときに macOS が止めるので、"
    echo "「システム設定」>「プライバシーとセキュリティ」の「このまま開く」で許可するか、ターミナルで次を実行してインストールします。"
    echo "  sudo installer -pkg Ogura-${VERSION}-unsigned.pkg -target /"
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
