#!/bin/bash
# no-sound.sh - the static test that keeps the alarm vibration only.
#
# Usage: tools/no-sound.sh
#
# Since 1.2.0 the alarm only vibrates: the sound did not play the same on
# every watch, and a wrong sound is worse than none (the owner's decision).
# A Connect IQ app can make a sound in one way only, Attention.playTone - a
# built-in tone, or a melody of Attention.ToneProfile notes - so a tree in
# which no Monkey C file names either of them cannot play one. This reads
# every .mc file under source/ and test/, comments included, and prints each
# line that names one.
#
# tools/matrix.sh runs it before it builds or tests anything, so both
# commands of every pull request run it too.
#
# Exit codes
#   0  no .mc file names a sound API
#   1  some line does: each one is printed as file:line: text
#   2  the run never started (no source/ folder, or grep failed)
#
# Environment
#   PROJ_DIR  project folder (default: the parent of tools/)

set -u

self=${0##*/}
proj=${PROJ_DIR:-$(cd "$(dirname "$0")/.." && pwd)}

# Every way a watch app can play a sound goes through one of these names.
sound_api='playTone|ToneProfile'

[ -d "$proj/source" ] || { printf '%s: no source/ in %s (set PROJ_DIR?)\n' "$self" "$proj" >&2; exit 2; }
dirs="source"
[ -d "$proj/test" ] && dirs="$dirs test"

hits=$(cd "$proj" && grep -rnE --include='*.mc' "$sound_api" $dirs)
rc=$?
if [ "$rc" -gt 1 ]; then
    printf '%s: grep failed with %s in %s\n' "$self" "$rc" "$proj" >&2
    exit 2
fi
if [ -n "$hits" ]; then
    printf '%s: the alarm is vibration only, but these lines name a sound API (%s):\n' "$self" "$sound_api"
    printf '%s\n' "$hits" | sed 's/^/  /'
    exit 1
fi
printf '%s: no sound API (%s) in %s\n' "$self" "$sound_api" "$(printf '%s/ ' $dirs | sed 's/ $//')"
exit 0
