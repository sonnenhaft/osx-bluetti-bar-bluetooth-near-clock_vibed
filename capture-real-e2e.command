#!/bin/bash
# Real macOS GUI verification and PNG capture. Never synthesizes screenshot pixels.
# Run in a logged-in graphical macOS session with Screen Recording and
# Accessibility enabled for the terminal / automation runner.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${BLUETTIBAR_E2E_DIR:-$HOME/Desktop/BluettiBar-E2E-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
REPORT="$OUT/results.txt"
: > "$REPORT"
log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
pass() { log "PASS | $*"; }
fail() { log "FAIL | $*"; }
blocked() { log "BLOCKED | $*"; }

if [[ "$(uname -s)" != Darwin ]]; then
  blocked 'Requires a REAL macOS desktop; no generated/fake PNGs.'
  exit 1
fi
log "macOS: $(sw_vers -productVersion); host: $(hostname); date: $(date -u +%FT%TZ)"
if [[ "$(id -u)" == 0 ]]; then
  fail 'Must run as the logged-in desktop user, not root.'
  exit 1
fi

# The installer builds the original app, executes its native logic/UI tests,
# registers LaunchServices and leaves the existing installation untouched on failure.
log 'STAGE | Build, install, native self-tests and LaunchServices registration'
if ( cd "$ROOT" && /bin/bash ./install.command ) >"$OUT/install.log" 2>&1; then
  pass 'install.command completed; native logic and AppKit UI self-tests returned success.'
else
  fail 'install.command failed (inspect install.log); live UI cannot be trusted.'
  exit 1
fi
APP="/Applications/BluettiBar.app"
[[ -d "$APP" ]] || APP="$HOME/Applications/BluettiBar.app"
EXE="$APP/Contents/MacOS/BluettiBar"
if [[ ! -x "$EXE" ]]; then
  fail 'Installed macOS executable not found.'
  exit 1
fi

# Screen captures are taken only with Apple's screencapture from a real logged-in desktop.
snap() {
  local name="$1"
  if /usr/sbin/screencapture -x "$OUT/$name.png" >/dev/null 2>&1 && [[ -s "$OUT/$name.png" ]] &&
    /usr/bin/sips -g pixelWidth -g pixelHeight "$OUT/$name.png" >/dev/null 2>&1; then
    pass "Captured genuine screen: $name.png"
    /usr/bin/shasum -a 256 "$OUT/$name.png" >> "$OUT/SHA256SUMS"
    return 0
  fi
  fail "Screen capture failed: $name.png (Screen Recording permission / graphical session required)"
  return 1
}

click_status_item() {
  /usr/bin/osascript <<'APPLESCRIPT'
tell application "System Events"
    set p to first process whose name is "BluettiBar"
    repeat with b in (menu bars of p)
      repeat with itemRef in (menu bar items of b)
        set nm to ""
        set ds to ""
        set ident to ""
        try
          set nm to name of itemRef as text
        end try
        try
          set ds to description of itemRef as text
        end try
        try
          set ident to value of attribute "AXIdentifier" of itemRef as text
        end try
        if ident is "BluettiBar.Status" or nm contains "BLUETTI" or ds contains "BLUETTI" then
          click itemRef
          return "clicked_real_status_item"
        end if
      end repeat
    end repeat
  end tell
error "The BluettiBar status item is not accessible; it may be hidden or Accessibility is denied."
APPLESCRIPT
}

/usr/bin/open "$APP" >/dev/null 2>&1 || true
sleep 3
snap '01-real-menu-bar' || true
if click_status_item >"$OUT/status-click.log" 2>&1; then
  pass 'Clicked accessible real BluettiBar status item (AX/UI click).'
  sleep 1
  snap '02-real-open-menu' || true
else
  fail 'Could not ACTUALLY click the menu-bar item; screenshot cannot prove native click.'
  log 'STAGE | Non-click fallback shown separately (must not count as status-click PASS).'
  /usr/bin/open "$APP" --args --show-menu >/dev/null 2>&1 || true
  sleep 1
  snap '02b-fallback-open-menu' || true
fi

# Test a real process STOP and relaunch, rather than only re-open an existing process.
/usr/bin/osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
if "$EXE" --installer-stop-ui >"$OUT/stop.log" 2>&1; then
  /usr/bin/open "$APP" >/dev/null 2>&1 || true
  sleep 3
  if /usr/bin/pgrep -f "^$EXE" >/dev/null 2>&1; then
    pass 'Real app process stopped and was relaunched.'
    snap '03-real-after-relaunch' || true
  else
    fail 'No matching BluettiBar executable after relaunch.'
  fi
else
  fail 'Cannot safely stop the owned BluettiBar process for relaunch.'
fi

# Spotlight visual result; independently record indexing evidence.
/usr/bin/osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true
if /usr/bin/mdfind 'kMDItemCFBundleIdentifier == "com.local.bluebar"' | /usr/bin/grep -Fq 'BluettiBar.app'; then
  pass 'Spotlight metadata search locates a BluettiBar.app bundle.'
else
  fail 'mdfind does not yet index BluettiBar.app (Spotlight may be disabled or indexing).' 
fi
if /usr/bin/osascript <<'SPOTLIGHT' >"$OUT/spotlight-keys.log" 2>&1
tell application "System Events"
  key code 49 using command down
  delay 0.8
  keystroke "BluettiBar"
end tell
SPOTLIGHT
then
  sleep 2
  snap '04-real-spotlight-search' || true
else
  fail 'Could not type into Spotlight via System Events (Accessibility permission needed).'
fi
/usr/bin/osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1 || true

# An isolated DEMO uses the app's actual UI and real AppKit graph, not a mock image.
# Its readings are synthetic *data* as visibly labelled DEMO, not synthetic screenshots.
if "$EXE" --installer-stop-ui >"$OUT/demo-stop.log" 2>&1; then
  "$EXE" --demo >"$OUT/demo-console.log" 2>&1 &
  DEMO_PID=$!
  sleep 4
  if /bin/kill -0 "$DEMO_PID" >/dev/null 2>&1; then
    pass 'Actual app process started in clearly-labelled DEMO data mode.'
    if click_status_item >"$OUT/demo-click.log" 2>&1; then
      pass 'Clicked actual status item for app graph-data state.'
      sleep 1
      snap '05-real-demo-data-graph' || true
    else
      fail 'Could not click demo app menu item, graph screenshot not verified.'
    fi
    /bin/kill "$DEMO_PID" >/dev/null 2>&1 || true
    wait "$DEMO_PID" 2>/dev/null || true
  else
    fail 'App --demo failed to remain running.'
  fi
  /usr/bin/open "$APP" >/dev/null 2>&1 || true
else
  blocked 'Demo graph state omitted: cannot safely stop owned UI process.'
fi

# Explicitly do NOT mark visible-next-to-clock, graph, or Spotlight search result as
# PASS based solely on code paths or screenshot existence. Inspect the true pixels.
blocked 'Human/vision inspection of real PNG pixels still required to decide: clock adjacency, menu contents, graph axes, and Spotlight visual match.'
log "EVIDENCE_DIRECTORY | $OUT"
log 'NOTE | No image was fabricated. Successful screenshot capture is not automatic visual PASS.'
