#!/bin/bash
set -euo pipefail

# Ensure Xcode.app toolchain is used even if xcode-select points at CLT
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

APP_NAME="CodeIsland"
BUILD_DIR=".build/release"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ICON_CATALOG="Assets.xcassets"
ICON_SOURCE="AppIcon.icon"
ICON_INFO_PLIST=".build/AppIcon.partial.plist"
WATCH_DIR="android-watch"
WATCH_GRADLEW="$WATCH_DIR/gradlew"
WATCH_APK_DEBUG="$WATCH_DIR/app/build/outputs/apk/debug/app-debug.apk"

BUILD_MAC=true
BUILD_WATCH=false
NOTARIZE=false
INSTALL=true

usage() {
    cat <<'EOF'
Usage: ./build.sh [--watch] [--with-watch] [--notarize] [--no-install]

  --watch       Build Android watch app only
  --with-watch  Build macOS app and Android watch app
  --notarize    Notarize macOS app bundle / DMG after signing
  --no-install  Skip installing the app bundle to /Applications
  --help        Show this help
EOF
}

for arg in "$@"; do
    case "$arg" in
        --watch)
            BUILD_MAC=false
            BUILD_WATCH=true
            ;;
        --with-watch)
            BUILD_WATCH=true
            ;;
        --notarize)
            NOTARIZE=true
            ;;
        --no-install)
            INSTALL=false
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

build_watch() {
    echo "Building Android watch app..."
    if [ ! -x "$WATCH_GRADLEW" ]; then
        echo "Missing executable Gradle wrapper: $WATCH_GRADLEW" >&2
        exit 1
    fi

    "$WATCH_GRADLEW" -p "$WATCH_DIR" testDebugUnitTest
    "$WATCH_GRADLEW" -p "$WATCH_DIR" assembleDebug

    echo "Watch APK ready: $WATCH_APK_DEBUG"
}

build_mac() {
    echo "Building $APP_NAME (universal)..."
    swift build -c release --arch arm64
    swift build -c release --arch x86_64

    echo "Creating universal binaries..."
    ARM_DIR=".build/arm64-apple-macosx/release"
    X86_DIR=".build/x86_64-apple-macosx/release"

    echo "Creating app bundle..."
    rm -rf "$APP_BUNDLE"
    mkdir -p "$APP_BUNDLE/Contents/MacOS"
    mkdir -p "$APP_BUNDLE/Contents/Helpers"
    mkdir -p "$APP_BUNDLE/Contents/Resources"
    mkdir -p "$APP_BUNDLE/Contents/Frameworks"

    lipo -create "$ARM_DIR/$APP_NAME" "$X86_DIR/$APP_NAME" \
         -output "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    lipo -create "$ARM_DIR/codeisland-bridge" "$X86_DIR/codeisland-bridge" \
         -output "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
    cp Info.plist "$APP_BUNDLE/Contents/Info.plist"

    echo "Embedding frameworks..."
    # Sparkle.xcframework macos-arm64_x86_64 slice is already universal; copy as-is to preserve symlinks.
    SPARKLE_SRC=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
    if [ ! -d "$SPARKLE_SRC" ]; then
        echo "Missing Sparkle.framework at $SPARKLE_SRC" >&2
        exit 1
    fi
    ditto "$SPARKLE_SRC" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"

    # Add rpath so executables can locate embedded frameworks.
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true
    install_name_tool -add_rpath "@executable_path/../../Frameworks" \
        "$APP_BUNDLE/Contents/Helpers/codeisland-bridge" 2>/dev/null || true

    echo "Compiling app icon assets..."
    # actool compiles the modern .icon (Icon Composer) catalog, which pulls in
    # CoreSimulator for rendering. On machines where that framework fails to load
    # ("library load denied by system policy") actool aborts. The bundle still runs
    # fine off the AppIcon.icns fallback below, so don't let an icon-tool failure
    # fail the whole release build — warn and continue.
    if ! xcrun actool \
        --output-format human-readable-text \
        --warnings \
        --errors \
        --notices \
        --platform macosx \
        --target-device mac \
        --minimum-deployment-target 14.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$ICON_INFO_PLIST" \
        --compile "$APP_BUNDLE/Contents/Resources" \
        "$ICON_CATALOG" \
        "$ICON_SOURCE"; then
        echo "WARNING: actool failed to compile asset catalog — falling back to AppIcon.icns only." >&2
        echo "         To restore full icon compilation run: sudo xcodebuild -runFirstLaunch" >&2
    fi
    cp "Sources/CodeIsland/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

    # Copy SPM resource bundles into Contents/Resources/ (required for code signing)
    for bundle in .build/*/release/*.bundle; do
        if [ -e "$bundle" ]; then
            cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
            break
        fi
    done

    ENTITLEMENTS="CodeIsland.entitlements"

    # Use SIGN_ID env var, or auto-detect: prefer "Developer ID Application" for distribution,
    # fall back to any valid identity, then ad-hoc
    if [ -z "${SIGN_ID:-}" ]; then
        SIGN_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || true)
    fi
    if [ -z "$SIGN_ID" ]; then
        SIGN_ID=$(security find-identity -v -p codesigning | grep -v "REVOKED" | grep '"' | head -1 | sed 's/.*"\(.*\)".*/\1/' 2>/dev/null || true)
    fi
    if [ -z "$SIGN_ID" ]; then
        echo "No developer certificate found, using ad-hoc signing..."
        SIGN_ID="-"
    fi

    CODESIGN_OPTS=(--force --sign "$SIGN_ID")
    if [ "$SIGN_ID" != "-" ]; then
        CODESIGN_OPTS=(--force --options runtime --sign "$SIGN_ID")
    fi

    echo "Code signing ($SIGN_ID)..."
    # Sign embedded frameworks first (inside-out).
    SPARKLE_FW="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
    # Sign nested helpers inside Sparkle before the framework itself.
    for xpc in "$SPARKLE_FW/Versions/B/XPCServices/"*.xpc; do
        [ -e "$xpc" ] || continue
        codesign "${CODESIGN_OPTS[@]}" "$xpc"
    done
    if [ -d "$SPARKLE_FW/Versions/B/Updater.app" ]; then
        codesign "${CODESIGN_OPTS[@]}" "$SPARKLE_FW/Versions/B/Updater.app"
    fi
    if [ -e "$SPARKLE_FW/Versions/B/Autoupdate" ]; then
        codesign "${CODESIGN_OPTS[@]}" "$SPARKLE_FW/Versions/B/Autoupdate"
    fi
    codesign "${CODESIGN_OPTS[@]}" "$SPARKLE_FW"

    codesign "${CODESIGN_OPTS[@]}" "$APP_BUNDLE/Contents/Helpers/codeisland-bridge"
    codesign "${CODESIGN_OPTS[@]}" --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"

    if [ "$NOTARIZE" = true ] && [[ "$SIGN_ID" == *"Developer ID"* ]]; then
        echo "Creating ZIP for notarization..."
        ZIP_PATH="$BUILD_DIR/$APP_NAME.zip"
        ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

        echo "Submitting for notarization..."
        if xcrun notarytool submit "$ZIP_PATH" --keychain-profile "CodeIsland" --wait 2>&1 | tee /dev/stderr | grep -q "status: Accepted"; then
            echo "Stapling notarization ticket..."
            xcrun stapler staple "$APP_BUNDLE"
        else
            echo "ERROR: Notarization failed. Run 'xcrun notarytool log <submission-id> --keychain-profile CodeIsland' for details."
            rm -f "$ZIP_PATH"
            exit 1
        fi
        rm -f "$ZIP_PATH"

        echo "Creating DMG..."
        DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
        rm -f "$DMG_PATH"
        create-dmg \
            --volname "$APP_NAME" \
            --window-pos 200 120 \
            --window-size 600 400 \
            --icon-size 100 \
            --icon "$APP_NAME.app" 150 185 \
            --app-drop-link 450 185 \
            --no-internet-enable \
            "$DMG_PATH" "$APP_BUNDLE"

        codesign --force --sign "$SIGN_ID" "$DMG_PATH"
        echo "Notarizing DMG..."
        if xcrun notarytool submit "$DMG_PATH" --keychain-profile "CodeIsland" --wait 2>&1 | tee /dev/stderr | grep -q "status: Accepted"; then
            xcrun stapler staple "$DMG_PATH"
            echo "DMG ready: $DMG_PATH"
        else
            echo "WARNING: DMG notarization failed, but app is notarized."
        fi
    fi

    if [ "$INSTALL" = true ]; then
        INSTALLED_APP="/Applications/$APP_NAME.app"
        echo "Installing to $INSTALLED_APP..."
        WAS_RUNNING=false
        if pgrep -xq "$APP_NAME"; then
            WAS_RUNNING=true
            osascript -e "quit app \"$APP_NAME\"" 2>/dev/null || true
            sleep 1
            pkill -x "$APP_NAME" 2>/dev/null || true
        fi
        rm -rf "$INSTALLED_APP"
        # ditto preserves code signatures, symlinks and extended attributes.
        ditto "$APP_BUNDLE" "$INSTALLED_APP"
        if [ "$WAS_RUNNING" = true ]; then
            echo "Relaunching $APP_NAME..."
            open "$INSTALLED_APP"
        fi
        echo "Done: $INSTALLED_APP"
        echo "Run: open $INSTALLED_APP"
    else
        echo "Done: $APP_BUNDLE"
        echo "Run: open $APP_BUNDLE"
    fi
}

if [ "$BUILD_MAC" = true ]; then
    build_mac
fi

if [ "$BUILD_WATCH" = true ]; then
    build_watch
fi
