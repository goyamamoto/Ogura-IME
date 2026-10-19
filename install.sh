#!/bin/bash
set -xe -o pipefail

IGNORE_LINT=false
DRY_RUN=false
NO_PKILL=false
ADHOC=false
# Build on what the last build left (build/DerivedData) instead of from clean: after a change to Ogura or Core only
# those are compiled again, not the dependencies
INCREMENTAL=false
TEAM_ID="${OGURA_TEAM_ID:-}"

# Parse command-line options
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --ignore-lint) IGNORE_LINT=true ;;
        --dry-run) DRY_RUN=true ;;
        --no-pkill) NO_PKILL=true ;;
        --adhoc) ADHOC=true ;;
        --incremental) INCREMENTAL=true ;;
        --team) TEAM_ID="$2"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

if [ "$IGNORE_LINT" = false ]; then
    if command -v swiftlint &> /dev/null
    then
        # Fix auto-fixable errors
        swiftlint --fix --format
        # Check other errors
        swiftlint --quiet --strict
    else
        echo "swiftlint could not be found. Please rerun the script as \`./install.sh --ignore-lint\`."
        echo "For contributing Ogura, we strongly recommend you to install swiftlint"
        echo "To install swiftlint, run \`brew install swiftlint\`"
        exit 1
    fi
else
    echo "Skipping swiftlint checks due to --ignore-lint option."
fi


APP_PATH="build/Ogura.app"
rm -rf "$APP_PATH"
mkdir -p build

CLEAN=clean
if [ "$INCREMENTAL" = true ]; then
    CLEAN=
fi

# The build number (CFBundleVersion) is the number of commits in the history, so each build can be told apart. The version
# shown to users (CFBundleShortVersionString) is MARKETING_VERSION in the Xcode project
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"

if [ "$ADHOC" = false ] && [ -z "$TEAM_ID" ]; then
    echo "署名に使う Team ID を指定してください: ./install.sh --team <TEAM_ID>（または環境変数 OGURA_TEAM_ID）"
    echo "Team ID は Xcode > Settings > Accounts で確認できます。Personal Team でも構いません。"
    echo "証明書がない場合は ./install.sh --adhoc でローカル動作確認用にインストールできます。"
    exit 1
fi

if [ "$ADHOC" = true ]; then
    # Path for local testing without a certificate.
    # Build Release with signing turned off, then ad-hoc sign it with the entitlements.
    # Not usable for distribution (that needs Developer ID and notarization).
    xcodebuild -project Ogura.xcodeproj -scheme Ogura -configuration Release \
        -derivedDataPath build/DerivedData $CLEAN build \
        CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO
    cp -R build/DerivedData/Build/Products/Release/Ogura.app "$APP_PATH"
    codesign --force --deep --sign - \
        --entitlements Ogura/Ogura.entitlements "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH"
else
    # Build Release and sign it with an Apple Development certificate (a Personal Team is fine).
    # The signing identity stays the same across reinstalls, so macOS keeps its permission settings.
    # For Developer ID signing and notarization for distribution, use pkgbuild.sh.
    xcodebuild -project Ogura.xcodeproj -scheme Ogura -configuration Release \
        -derivedDataPath build/DerivedData $CLEAN build \
        DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
        -allowProvisioningUpdates
    cp -R build/DerivedData/Build/Products/Release/Ogura.app "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH"
    codesign -dv "$APP_PATH" 2>&1 | grep -E "^(Authority|TeamIdentifier)=" | head -2
fi

if [ "$DRY_RUN" = true ]; then
    echo "DRY RUN: Would execute the following commands:"
    echo "  sudo rm -rf /Library/Input\ Methods/Ogura.app"
    echo "  sudo cp -r "$APP_PATH" /Library/Input\ Methods/"
    if [ "$NO_PKILL" = false ]; then
        echo "  sudo pkill -x Ogura || true"
    fi
    echo "Build completed successfully. Use without --dry-run to actually install."
else
    sudo rm -rf /Library/Input\ Methods/Ogura.app
    sudo cp -r "$APP_PATH" /Library/Input\ Methods/
    if [ "$NO_PKILL" = false ]; then
        # Quit Ogura in every account (as the pkg's postinstall does). Without sudo, only this account's Ogura quits,
        # and other accounts keep running the old version until they log out
        sudo pkill -x Ogura || true
    fi
    # Register the input source without logging out (affects only this account's session)
    "$(dirname "$0")/Tools/register_input_source.sh" || echo "入力ソースの登録に失敗しました。ログアウト・再ログインしてください。"
    set +x
    echo ""
    echo "Ogura を更新しました。この登録は、いま実行しているアカウントにだけ反映されます。"
    echo "ほかのアカウントで Ogura がグレイアウトして選べないときは、そのアカウントで次を実行するか、ログインし直してください。"
    echo "  \"$(cd "$(dirname "$0")" && pwd)/Tools/register_input_source.sh\""
fi
