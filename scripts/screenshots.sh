#!/bin/zsh
# Takes the README screenshots from demo data (docs/demo), in light and dark appearance:
#   docs/screenshots/main-{light,dark}.png  the main window with the Proxmox server "Office"
#   docs/screenshots/ai-{light,dark}.png    the confirmation before an AI app runs a command
#
# Uses build/Hoatzin.app, so run scripts/build-app.sh first. Your own library and settings are
# neither shown nor changed: the app runs with the demo library, its own AI log and its own
# control socket, and Proxmox data comes from docs/demo/proxmox.json instead of a server.
set -euo pipefail
cd "${0:A:h}/.."

MACOS=build/Hoatzin.app/Contents/MacOS
[[ -x $MACOS/Hoatzin ]] || { echo "build the app first: scripts/build-app.sh" >&2; exit 1; }
OUT=docs/screenshots
mkdir -p "$OUT"
WORK=$(mktemp -d -t hoatzin-screenshots)
trap 'rm -rf "$WORK"' EXIT
TEMP=$(getconf DARWIN_USER_TEMP_DIR)
SOCKET="${TEMP}hoatzin-screenshots.sock"
# The confirmation names the program that started the MCP helper, so a tiny launcher called
# "Claude" starts it with one request, as an AI app would.
cat > "$WORK/launcher.swift" <<'SWIFT'
import Foundation
let helper = Process()
helper.executableURL = URL(fileURLWithPath: CommandLine.arguments[1])
let input = Pipe()
helper.standardInput = input
helper.standardOutput = FileHandle.nullDevice
try helper.run()
input.fileHandleForWriting.write(Data((CommandLine.arguments[2] + "\n").utf8))
try input.fileHandleForWriting.close()
helper.waitUntilExit()
SWIFT
DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer} xcrun swiftc -O -o "$WORK/Claude" "$WORK/launcher.swift"
REQUEST='{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"run_command","arguments":{"id":"item:D0000000-0000-4000-8000-000000000002","command":"systemctl status nginx --no-pager"}}}'

shoot() { # <name> <light|dark> <entry to select> [ask]
  local name=$1 appearance=$2 select=$3 ask=${4:-}
  HOATZIN_LIBRARY=$PWD/docs/demo/library.json HOATZIN_DEMO_PROXMOX=$PWD/docs/demo/proxmox.json \
  HOATZIN_AI_LOG=$WORK/ai.jsonl HOATZIN_CONTROL_SOCKET=$SOCKET HOATZIN_SELECT=$select \
  HOATZIN_APPEARANCE=$appearance HOATZIN_SNAPSHOT_SIZE=1240x720 HOATZIN_SNAPSHOT=$WORK/$name HOATZIN_SNAPSHOT_DELAY=6 \
    "$MACOS/Hoatzin" -AppleLanguages '(en)' -aiAccess commands -spotlightConnections NO >"$WORK/$name.log" 2>&1 &
  local pid=$!
  if [[ -n $ask ]]; then
    sleep 3
    HOATZIN_CONTROL_SOCKET=$SOCKET "$WORK/Claude" "$MACOS/hoatzin-mcp" "$REQUEST" >/dev/null 2>&1 &
  fi
  sleep 8
  kill $pid 2>/dev/null; wait $pid 2>/dev/null || true
  rm -f "$SOCKET" "${TEMP}hoatzin-$pid.sock"
  local shot=("$WORK/$name"-*-composite.png(N))
  [[ -z $ask ]] && shot=("$WORK/$name"-0.png(N))
  [[ ${#shot} -gt 0 ]] || { echo "no screenshot for $name (see $WORK/$name.log)" >&2; exit 1; }
  sips -Z 1600 "${shot[1]}" --out "$OUT/$name.png" >/dev/null
  echo "Wrote $OUT/$name.png"
}

for appearance in light dark; do
  shoot "main-$appearance" "$appearance" Office
  shoot "ai-$appearance" "$appearance" web01 ask
done
