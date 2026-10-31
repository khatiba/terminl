#!/bin/sh
# Install Terminl __TAG__: copy the system Terminal to ~/Applications, embed terminl.dylib, ad-hoc re-sign.
#   curl -fsSL https://github.com/__REPO__/releases/latest/download/install.sh | sh
#   ... | sh -s -- --uninstall
# TERMINL_DYLIB=/path/to/terminl.dylib uses a local build instead of downloading the release.
set -e
REPO="__REPO__"
TAG="__TAG__"
APP="$HOME/Applications/Terminl.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

if [ "$1" = "--uninstall" ]; then
    [ -d "$APP" ] && "$LSREGISTER" -u "$APP" || true
    rm -rf "$APP"
    echo "removed $APP"
    exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
if [ -n "$TERMINL_DYLIB" ]; then
    cp "$TERMINL_DYLIB" "$tmp/terminl.dylib"
else
    curl -fsSL -o "$tmp/terminl.dylib" "https://github.com/$REPO/releases/download/$TAG/terminl.dylib"
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP"
cp -R /System/Applications/Utilities/Terminal.app "$APP"
mkdir -p "$APP/Contents/Frameworks"
cp "$tmp/terminl.dylib" "$APP/Contents/Frameworks/"
# Inject the dylib on every LaunchServices launch (Dock, Spotlight, open).
/usr/libexec/PlistBuddy -c 'Add :LSEnvironment dict' \
    -c "Add :LSEnvironment:DYLD_INSERT_LIBRARIES string $APP/Contents/Frameworks/terminl.dylib" "$APP/Contents/Info.plist"
# Record the source Terminal version so a stale copy is detectable after macOS updates.
/usr/libexec/PlistBuddy -c "Add :TerminlSourceVersion string $(defaults read /System/Applications/Utilities/Terminal.app/Contents/Info CFBundleVersion)" "$APP/Contents/Info.plist"
# Nested code must be signed before the bundle.
codesign -fs - "$APP/Contents/Frameworks/terminl.dylib"
codesign -fs - "$APP"
"$LSREGISTER" -f "$APP"
echo "installed $APP — re-run after macOS updates Terminal"
