#!/bin/zsh
# Build and run the unit tests for one or more devices, one at a time.
# Usage: runtests.sh <device> [<device> ...]
# Writes $OUT_DIR/log-<device>.txt (default /tmp/powernap-tests); prints one line per device.
# PROJ_DIR overrides the project folder (e.g. a frozen copy of the tree).
SDK="$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b"
PROJ=${PROJ_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
OUT=${OUT_DIR:-/tmp/powernap-tests}
mkdir -p "$OUT"

ensure_sim() {
  if ! pgrep -f "ConnectIQ.app" >/dev/null 2>&1 && ! pgrep -x simulator >/dev/null 2>&1; then
    "$SDK/bin/connectiq" >/dev/null 2>&1 &
    sleep 8
  fi
}

restart_sim() {
  pkill -f MonkeyDoDeux >/dev/null 2>&1
  pkill -f "ConnectIQ.app" >/dev/null 2>&1
  pkill -x simulator >/dev/null 2>&1
  sleep 3
  "$SDK/bin/connectiq" >/dev/null 2>&1 &
  sleep 10
}

for dev in "$@"; do
  prg="$OUT/T-$dev.prg"
  log="$OUT/log-$dev.txt"
  (cd "$PROJ" && "$SDK/bin/monkeyc" -o "$prg" -f monkey.jungle -d "$dev" -y ~/developer_key.der -t -l 3 -w 2>&1 | grep -v "launcher icon" | grep -v "^BUILD SUCCESSFUL") > "$OUT/build-$dev.txt"
  if [ ! -f "$prg" ] || grep -q "ERROR" "$OUT/build-$dev.txt"; then
    echo "$dev: BUILD FAILED"; cat "$OUT/build-$dev.txt"; continue
  fi
  done_ok=0
  for attempt in 1 2 3; do
    ensure_sim
    rm -f "$log"
    "$SDK/bin/monkeydo" "$prg" "$dev" -t > "$log" 2>&1 &
    pid=$!
    waited=0
    while [ $waited -lt 420 ]; do
      if grep -q -E "^(PASSED|FAILED)|Ran [0-9]+ tests" "$log" 2>/dev/null && ! kill -0 $pid 2>/dev/null; then
        break
      fi
      if ! kill -0 $pid 2>/dev/null; then break; fi
      sleep 3; waited=$((waited + 3))
    done
    if kill -0 $pid 2>/dev/null; then kill $pid 2>/dev/null; fi
    if grep -q -E "Ran [0-9]+ tests" "$log"; then
      done_ok=1; break
    fi
    echo "$dev: attempt $attempt gave no result (waited ${waited}s), restarting simulator"
    tail -5 "$log"
    restart_sim
  done
  if [ $done_ok -eq 1 ]; then
    summary=$(grep -E "Ran [0-9]+ tests" "$log" | tail -1)
    result=$(grep -E "^(PASSED|FAILED)" "$log" | tail -1)
    fails=$(grep -E "FAIL|ERROR" "$log" | grep -v "^PASSED" | head -20)
    echo "$dev: $summary $result"
    if [ -n "$fails" ]; then echo "$fails"; fi
  else
    echo "$dev: NO RESULT after 3 attempts"
  fi
done
