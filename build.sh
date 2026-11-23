#!/bin/zsh
# Builds Merlin.app (no Xcode needed).
#   ./build.sh            build into ./build/Merlin.app
#   ./build.sh --install  build, copy to ~/Applications, and launch
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# App icon: the binary draws its own spark icon set; iconutil packs it.
mkdir -p build
rm -rf build/AppIcon.iconset
.build/release/Merlin --render-icon build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns

APP=build/Merlin.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Merlin "$APP/Contents/MacOS/Merlin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Geist + Geist Mono (registered at launch by MerlinFonts.register()).
mkdir -p "$APP/Contents/Resources/Fonts"
cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
# Sign with the private "Margin Local Signing" identity when it's set up (scripts/setup-signing.sh),
# so macOS sees every build as the same app and keeps its permissions. Otherwise sign ad hoc.
SIGN_DIR="$HOME/Library/Application Support/Margin Signing"
SIGN_KC="$SIGN_DIR/margin-signing.keychain-db"
# The identity and keychain keep their old "Margin" names on purpose: renaming the certificate would reset macOS permissions.
IDENTITY="Margin Local Signing"
signed=false
if [[ -f "$SIGN_KC" && -f "$SIGN_DIR/keychain-password" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_KC" 2>/dev/null || true
  if security find-identity -v -p codesigning | grep -q "$IDENTITY" \
     && codesign --force --sign "$IDENTITY" --keychain "$SIGN_KC" --identifier com.kien.merlin "$APP"; then
    signed=true
    echo "Built $APP (signed as \"$IDENTITY\": permissions carry over between builds)"
  fi
fi
if [[ $signed == false ]]; then
  codesign --force --sign - --identifier com.kien.merlin "$APP"
  echo "Built $APP (signed ad hoc: run scripts/setup-signing.sh so macOS stops forgetting permissions)"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Merlin 2>/dev/null || true
  pkill -x Margin 2>/dev/null || true
  # Wait for both to really exit; opening too soon fails with LaunchServices error -600.
  for _ in {1..20}; do pgrep -x Merlin >/dev/null || pgrep -x Margin >/dev/null || break; sleep 0.2; done
  mkdir -p ~/Applications
  rm -rf ~/Applications/Merlin.app
  cp -R "$APP" ~/Applications/Merlin.app
  open ~/Applications/Merlin.app || { sleep 1; open ~/Applications/Merlin.app; }
  echo "Installed and launched ~/Applications/Merlin.app"
  if [[ -d ~/Applications/Margin.app ]]; then echo "Note: the old ~/Applications/Margin.app is still there; delete it yourself once Merlin works for you."; fi
fi
