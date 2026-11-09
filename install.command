#!/bin/bash
# Build one native macOS app using only the Apple SDK shipped with Xcode tools.
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This installer runs on macOS12 or newer.' >&2
  exit 1
fi
if ! /usr/bin/xcrun --find swiftc >/dev/null 2>&1; then
  echo 'Install Apple Command Line Tools: xcode-select --install' >&2
  exit 1
fi

# Prefer the standard Applications folder when the current user can write there.
# User-level installation is registered with LaunchServices as well.
APP_PARENT="$HOME/Applications"
if [[ -w /Applications ]]; then APP_PARENT='/Applications'; fi
APP_PATH="$APP_PARENT/BluettiBar.app"
echo "Installing to: $APP_PATH"
BUILD_DIR="$PROJECT_DIR/.build"
STAGED_APP="$BUILD_DIR/BluettiBar.app"
CLI_PATH="$HOME/.local/bin/bluetti"
AGENT_PATH="$HOME/Library/LaunchAgents/com.local.bluebar.plist"
OWNERSHIP_FILE='Contents/Resources/bluebar-owned'
if [[ "${BLUETTI_CHECK_ONLY:-0}" != 1 ]]; then
  if [[ -e "$APP_PATH" && ! -f "$APP_PATH/$OWNERSHIP_FILE" ]]; then
    echo "An unrelated application already exists at $APP_PATH. Move it first." >&2
    exit 1
  fi
  if [[ -e "$AGENT_PATH" ]] && ! /usr/bin/grep -q 'BlueBar-owned' "$AGENT_PATH"; then
    echo "An unrelated launch agent already exists at $AGENT_PATH." >&2
    exit 1
  fi
  mkdir -p "$APP_PARENT" "$HOME/.local/bin" "$HOME/Library/LaunchAgents"
fi
mkdir -p "$BUILD_DIR"
if [[ -e "$STAGED_APP" ]]; then /bin/rm -rf "$STAGED_APP"; fi
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

echo 'Building BluettiBar with the macOS SDK…'
/usr/bin/xcrun swiftc -O -swift-version 5 -parse-as-library \
  -import-objc-header "$PROJECT_DIR/Sources/Bluetooth/BluettiPOSIX.h" \
  -target "$(uname -m)-apple-macosx12.0" \
  -framework AppKit -framework Foundation -framework CoreBluetooth \
  -framework CryptoKit -framework Security \
  "$PROJECT_DIR"/Sources/*/*.swift "$PROJECT_DIR"/Tests/*.swift \
  -o "$STAGED_APP/Contents/MacOS/BluettiBar"
/bin/cp "$PROJECT_DIR/resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/bin/cp "$PROJECT_DIR/resources/bluetti-icon.jpg" "$STAGED_APP/Contents/Resources/bluetti-icon.jpg"
/bin/cp "$PROJECT_DIR/resources/BluettiBar.icns" "$STAGED_APP/Contents/Resources/BluettiBar.icns"
printf '%s\n' 'BlueBar-owned: BluettiBar AC50P monitor' > "$STAGED_APP/$OWNERSHIP_FILE"

# The compact Finder icon is supplied ready to use; no image tools or upscaling.
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
"$STAGED_APP/Contents/MacOS/BluettiBar" --bluetti-helper --help >/dev/null
echo 'Checking protocol, cache and runtime logic…'
"$STAGED_APP/Contents/MacOS/BluettiBar" --bluetti-helper --self-test
"$STAGED_APP/Contents/MacOS/BluettiBar" --ui-self-test
if [[ "${BLUETTI_CHECK_ONLY:-0}" == 1 ]]; then exit 0; fi

# Complete all build checks before touching the previous working installation.
STAGED_EXE="$STAGED_APP/Contents/MacOS/BluettiBar"
"$STAGED_EXE" --preserve-legacy-reading
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$STAGED_APP/Contents/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$STAGED_APP/Contents/Info.plist")"
LAUNCH_TOKEN="$(/usr/bin/uuidgen)"
GUI_DOMAIN="gui/$(id -u)"
SERVICE="$GUI_DOMAIN/com.local.bluebar"
INSTALL_DIR="$(mktemp -d "$APP_PARENT/.bluettibar-install.XXXXXX")"
COMMITTED=0
TRANSACTION_STARTED=0
APP_REPLACED=0
PREVIOUS_MOVED=0
HAD_AGENT=0
CLI_CHANGED=0
OLD_CLI_TARGET=''
if [[ -f "$AGENT_PATH" ]]; then
  /bin/cp "$AGENT_PATH" "$INSTALL_DIR/previous-agent.plist"
  HAD_AGENT=1
fi
if [[ -L "$CLI_PATH" ]]; then OLD_CLI_TARGET="$(readlink "$CLI_PATH")"; fi

finish_installation() {
  local result=$?
  local preserve_recovery=0
  trap - EXIT
  if [[ "$result" -ne 0 && "$TRANSACTION_STARTED" -eq 1 && "$COMMITTED" -eq 0 ]]; then
    set +e
    echo 'Update was not confirmed; restoring the previous installation…' >&2
    # All job and process operations are limited to the previously checked owned app.
    /bin/launchctl bootout "$SERVICE" >/dev/null 2>&1
    if [[ "$APP_REPLACED" -eq 1 ]]; then
      if ! "$STAGED_EXE" --installer-stop-ui; then
        preserve_recovery=1
        echo 'The new UI could not be stopped; its app and the previous app backup were preserved.' >&2
      elif [[ -f "$APP_PATH/$OWNERSHIP_FILE" ]]; then
        /bin/rm -rf "$APP_PATH" || preserve_recovery=1
      else
        preserve_recovery=1
      fi
    fi
    if [[ "$preserve_recovery" -eq 0 && "$PREVIOUS_MOVED" -eq 1 && -d "$INSTALL_DIR/previous.app" ]]; then
      /bin/mv "$INSTALL_DIR/previous.app" "$APP_PATH" || preserve_recovery=1
    fi
    if [[ "$preserve_recovery" -eq 0 ]]; then
      if [[ "$HAD_AGENT" -eq 1 ]]; then
        /bin/cp "$INSTALL_DIR/previous-agent.plist" "$AGENT_PATH" || preserve_recovery=1
      elif [[ -f "$AGENT_PATH" ]] && /usr/bin/grep -q 'BlueBar-owned' "$AGENT_PATH"; then
        /bin/rm "$AGENT_PATH" || preserve_recovery=1
      fi
      if [[ "$CLI_CHANGED" -eq 1 ]]; then
        if [[ -L "$CLI_PATH" ]]; then /bin/rm "$CLI_PATH" || preserve_recovery=1; fi
        if [[ -n "$OLD_CLI_TARGET" ]]; then /bin/ln -s "$OLD_CLI_TARGET" "$CLI_PATH" || preserve_recovery=1; fi
      fi
      local restarted=0
      if [[ "$HAD_AGENT" -eq 1 && "$preserve_recovery" -eq 0 ]]; then
        if /bin/launchctl bootstrap "$GUI_DOMAIN" "$AGENT_PATH" >/dev/null 2>&1; then restarted=1; fi
      fi
      if [[ "$restarted" -eq 0 && -f "$INSTALL_DIR/previous-ui.json" ]]; then
        "$STAGED_EXE" --installer-restore-ui "$INSTALL_DIR/previous-ui.json" || preserve_recovery=1
      fi
    fi
    echo 'The new UI was not installed successfully. See the error above.' >&2
  fi
  if [[ "$preserve_recovery" -eq 1 ]]; then
    echo "Recovery files were preserved at: $INSTALL_DIR" >&2
  else
    /bin/rm -rf "$INSTALL_DIR"
  fi
  exit "$result"
}
trap finish_installation EXIT
/usr/bin/ditto "$STAGED_APP" "$INSTALL_DIR/BluettiBar.app"

# Quit each owned UI gracefully, then remove its one-shot login job.
# A same-label job without our owned plist is not ours to replace.
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1 && [[ "$HAD_AGENT" -eq 0 ]]; then
  echo "An unrecognized launch job already uses $SERVICE." >&2
  exit 1
fi
TRANSACTION_STARTED=1
"$STAGED_EXE" --installer-stop-ui "$INSTALL_DIR/previous-ui.json"
if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
  /bin/launchctl bootout "$SERVICE" >/dev/null 2>&1 || true
  if /bin/launchctl print "$SERVICE" >/dev/null 2>&1; then
    echo 'The previous login job could not be stopped; the app was not replaced.' >&2
    exit 1
  fi
fi
if [[ -e "$APP_PATH" ]]; then
  /bin/mv "$APP_PATH" "$INSTALL_DIR/previous.app"
  PREVIOUS_MOVED=1
fi
/bin/mv "$INSTALL_DIR/BluettiBar.app" "$APP_PATH"
APP_REPLACED=1

xml_escape() {
  printf '%s' "$1" | /usr/bin/sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}
EXE_XML="$(xml_escape "$APP_PATH/Contents/MacOS/BluettiBar")"
cat > "$INSTALL_DIR/new-agent.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<!-- BlueBar-owned -->
<key>Label</key><string>com.local.bluebar</string>
<key>ProgramArguments</key><array>
<string>$EXE_XML</string><string>--installation-token</string><string>$LAUNCH_TOKEN</string>
</array>
<key>RunAtLoad</key><true/>
<key>LimitLoadToSessionType</key><string>Aqua</string>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$INSTALL_DIR/new-agent.plist" >/dev/null
/bin/mv "$INSTALL_DIR/new-agent.plist" "$AGENT_PATH"
LSREGISTER='/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'
if [[ -x "$LSREGISTER" ]]; then "$LSREGISTER" -f "$APP_PATH"; fi
/usr/bin/touch "$APP_PATH"

# launchd starts the exact executable once. Never reuse an old app through open.
/bin/launchctl bootstrap "$GUI_DOMAIN" "$AGENT_PATH"
"$STAGED_EXE" --installer-wait-ready "$APP_PATH" "$APP_BUILD" "$LAUNCH_TOKEN"

# The legacy command is a link to this same executable, not another binary.
if [[ ! -e "$CLI_PATH" && ! -L "$CLI_PATH" ]]; then
  CLI_CHANGED=1
  /bin/ln -s "$APP_PATH/Contents/MacOS/BluettiBar" "$CLI_PATH"
elif [[ -L "$CLI_PATH" ]]; then
  case "$(readlink "$CLI_PATH")" in
    "$HOME/Applications/BlueBar.app/Contents/MacOS/bluetti"|\
    "/Applications/BlueBar.app/Contents/MacOS/bluetti"|\
    "$HOME/Applications/BluettiBar.app/Contents/MacOS/BluettiBar"|\
    "/Applications/BluettiBar.app/Contents/MacOS/BluettiBar")
      CLI_CHANGED=1
      /bin/ln -sfn "$APP_PATH/Contents/MacOS/BluettiBar" "$CLI_PATH" ;;
    *) echo "Existing $CLI_PATH was preserved." ;;
  esac
else
  echo "Existing $CLI_PATH was preserved."
fi

# Only now is the new UI confirmed. Keep every prior app until that point.
COMMITTED=1
for old_app in "$HOME/Applications/BlueBar.app" /Applications/BlueBar.app \
               "$HOME/Applications/BluettiBar.app" /Applications/BluettiBar.app; do
  if [[ "$old_app" != "$APP_PATH" && -f "$old_app/$OWNERSHIP_FILE" ]]; then
    /bin/rm -rf "$old_app" || echo "Could not remove the previous owned copy: $old_app" >&2
  fi
done
echo
echo "Installed BluettiBar $APP_VERSION (build $APP_BUILD): $APP_PATH"
echo 'BluettiBar starts at login. Run uninstall.command to remove it.'
/usr/bin/open -R "$APP_PATH" >/dev/null 2>&1 || true
