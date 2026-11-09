#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This uninstaller runs on macOS.' >&2
  exit 1
fi
AGENT_PATH="$HOME/Library/LaunchAgents/com.local.bluebar.plist"
CLI_PATH="$HOME/.local/bin/bluetti"
/usr/bin/osascript -e 'if application id "com.local.bluebar" is running then tell application id "com.local.bluebar" to quit' >/dev/null 2>&1 || true
if [[ -f "$AGENT_PATH" ]] && /usr/bin/grep -q 'BlueBar-owned' "$AGENT_PATH"; then
  /bin/launchctl bootout "gui/$(id -u)" "$AGENT_PATH" >/dev/null 2>&1 || true
  /bin/rm "$AGENT_PATH"
fi
for app_path in /Applications/BluettiBar.app "$HOME/Applications/BluettiBar.app" \
                /Applications/BlueBar.app "$HOME/Applications/BlueBar.app"; do
  if [[ -f "$app_path/Contents/Resources/bluebar-owned" ]]; then
    if [[ -L "$CLI_PATH" ]]; then
      case "$(readlink "$CLI_PATH")" in
        "$app_path/Contents/MacOS/bluetti"|"$app_path/Contents/MacOS/BluettiBar") /bin/rm "$CLI_PATH" ;;
      esac
    fi
    /bin/rm -rf "$app_path"
  fi
done
if [[ -d "$HOME/Library/Caches/BlueBar" ]]; then /bin/rm -rf "$HOME/Library/Caches/BlueBar"; fi
/usr/bin/defaults delete com.local.bluebar >/dev/null 2>&1 || true
echo 'BluettiBar removed. Saved station aliases remain.'
