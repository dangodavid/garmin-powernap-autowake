#!/bin/bash
# matrix.sh - build, or run the unit tests for, every product in manifest.xml.
#
# Usage: tools/matrix.sh [build|test|list] [options] [device ...]
#
# The device list is read from manifest.xml on every run, so a product added
# there is picked up without touching this script. Devices are handled one at
# a time in alphabetical order, and the run stops at the first one that fails.
#
# Modes
#   build   compile the app for every product (default)
#   test    build with -t and run the unit test suite in the simulator
#   list    print the device ids read from the manifest, one per line
#
# Options
#   --strict       a compiler warning fails the device (default)
#   --permissive   warnings are printed but do not fail the run
#   --release      build mode: compile the release build (-r), the one the
#                  store package is made of; the default is the debug build
#   -h, --help     print this text
#
# Device ids given as arguments limit the run to those devices; every id must
# appear in the manifest.
#
# Exit codes
#   0  every device passed; devices that were skipped are named in the summary
#   1  a device failed: its full output was printed and the run stopped there
#   2  the run never started (bad usage, or no manifest / SDK / developer key)
#
# Environment
#   CIQ_SDK        SDK folder           (default: the SDK manager's current-sdk.cfg)
#   CIQ_HOME       the same, the name the rest of the docs use
#   CIQ_DEVICES    device definitions   (default: the Devices folder beside it)
#   DEVELOPER_KEY  .der signing key     (default: ~/developer_key.der)
#   PROJ_DIR       project folder       (default: the parent of tools/)
#   OUT_DIR        logs and .prg files  (default: /tmp/powernap-matrix)
#   TEST_TIMEOUT   seconds to wait for one test run  (default: 420)
#   TEST_ATTEMPTS  simulator attempts per device     (default: 3)

set -u
set -o pipefail

EXIT_OK=0
EXIT_FAILED=1
EXIT_USAGE=2

self=${0##*/}
proj=${PROJ_DIR:-$(cd "$(dirname "$0")/.." && pwd)}
manifest="$proj/manifest.xml"
jungle="$proj/monkey.jungle"
out=${OUT_DIR:-/tmp/powernap-matrix}
test_timeout=${TEST_TIMEOUT:-420}
test_attempts=${TEST_ATTEMPTS:-3}

usage() { sed -e '1d' -e '/^[^#]/,$d' -e 's/^# \{0,1\}//' "$0"; }
die()   { printf '%s: %s\n' "$self" "$1" >&2; exit "$EXIT_USAGE"; }

# ---------------------------------------------------------------- manifest --
# Every <iq:product id="..."/> outside an XML comment, alphabetically, no
# duplicates. Splitting on "<!--" and dropping everything up to the matching
# "-->" keeps a product that was commented out from being built.
manifest_products() {
    awk '
        BEGIN { RS = "<!--" }
        NR == 1 { doc = $0; next }
        { at = index($0, "-->"); if (at > 0) { doc = doc substr($0, at + 3) } }
        END {
            tags = 0; ids = 0; rest = doc
            while (match(rest, /<iq:product[^>]*>/)) {
                tag = substr(rest, RSTART, RLENGTH)
                rest = substr(rest, RSTART + RLENGTH)
                # "<iq:product" is 11 characters; what follows tells a product
                # tag from the <iq:products> list that holds them.
                if (substr(tag, 12, 1) !~ /[ \t\r\n\/>]/) { continue }
                tags++
                # id="..." or id=\047...\047, the attribute name preceded by
                # space so that a uuid="..." next to it cannot pass for one.
                if (match(tag, /[ \t\r\n]id[ \t\r\n]*=[ \t\r\n]*"[^"]*"/) ||
                    match(tag, /[ \t\r\n]id[ \t\r\n]*=[ \t\r\n]*\047[^\047]*\047/)) {
                    id = substr(tag, RSTART, RLENGTH)
                    sub(/^[ \t\r\n]+id[ \t\r\n]*=[ \t\r\n]*["\047]/, "", id)
                    sub(/["\047]$/, "", id)
                    gsub(/[ \t\r\n]/, "", id)
                    if (id != "") { print id; ids++ }
                }
            }
            if (tags == 0) { print "no <iq:product> in the manifest" > "/dev/stderr"; exit 1 }
            if (tags != ids) {
                printf("could not read the id of %d <iq:product> tag(s)\n", tags - ids) > "/dev/stderr"
                exit 1
            }
        }
    ' "$1" | LC_ALL=C sort -u
}

# ------------------------------------------------------------------- setup --
find_sdk() {
    if [ -n "${CIQ_SDK:-}" ]; then printf '%s' "${CIQ_SDK%/}"; return; fi
    if [ -n "${CIQ_HOME:-}" ]; then printf '%s' "${CIQ_HOME%/}"; return; fi
    local cfg dir newest
    for cfg in "$HOME/Library/Application Support/Garmin/ConnectIQ/current-sdk.cfg" \
               "$HOME/.Garmin/ConnectIQ/current-sdk.cfg"; do
        if [ -f "$cfg" ]; then
            dir=$(tr -d '\r\n' < "$cfg"); dir=${dir%/}
            if [ -x "$dir/bin/monkeyc" ]; then printf '%s' "$dir"; return; fi
        fi
    done
    [ -x "$HOME/connectiq-sdk/bin/monkeyc" ] && { printf '%s' "$HOME/connectiq-sdk"; return; }
    # Newest installed SDK by folder date: version numbers do not sort by name.
    newest=""
    for dir in "$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks"/*/ \
               "$HOME/.Garmin/ConnectIQ/Sdks"/*/; do
        [ -x "${dir%/}/bin/monkeyc" ] || continue
        if [ -z "$newest" ] || [ "${dir%/}" -nt "$newest" ]; then newest=${dir%/}; fi
    done
    [ -n "$newest" ] && printf '%s' "$newest"
}

find_devices_dir() {
    if [ -n "${CIQ_DEVICES:-}" ]; then printf '%s' "${CIQ_DEVICES%/}"; return; fi
    local dir
    for dir in "$(dirname "$(dirname "$sdk")")/Devices" \
               "$HOME/Library/Application Support/Garmin/ConnectIQ/Devices" \
               "$HOME/.Garmin/ConnectIQ/Devices"; do
        [ -d "$dir" ] && { printf '%s' "$dir"; return; }
    done
}

find_key() {
    if [ -n "${DEVELOPER_KEY:-}" ]; then printf '%s' "$DEVELOPER_KEY"; return; fi
    [ -f "$HOME/developer_key.der" ] && { printf '%s' "$HOME/developer_key.der"; return; }
    local from_vscode
    if [ -f "$proj/.vscode/settings.json" ]; then
        from_vscode=$(sed -n 's/.*"monkeyC.developerKeyPath"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
                      "$proj/.vscode/settings.json" | head -1)
        [ -n "$from_vscode" ] && [ -f "$from_vscode" ] && { printf '%s' "$from_vscode"; return; }
    fi
}

# A device the SDK manager never downloaded, or one whose definition has no
# watch-app slot, cannot build or run anything: in test mode it is skipped
# with the reason printed, in build mode it fails like any other device.
unsupported_reason() {
    local dev=$1
    [ -z "$devices_dir" ] && return 0
    if [ ! -f "$devices_dir/$dev/compiler.json" ]; then
        printf 'not installed in the SDK (no %s/%s)' "${devices_dir##*/}" "$dev"
    elif ! grep -q '"watchApp"' "$devices_dir/$dev/compiler.json"; then
        printf 'the device definition has no watch-app support'
    fi
}

# ----------------------------------------------------------------- reports --
rule()     { printf -- '--------------------------------------------------------------------\n'; }
fmt_secs() {
    if [ "$1" -lt 60 ]; then printf '%ds' "$1"; else printf '%dm%02ds' $(($1 / 60)) $(($1 % 60)); fi
}
show_log() {  # the whole compiler output, framed, for the device that failed
    printf '\n'; rule
    printf '%s\n' "$2"
    rule
    cat "$1"
    rule
}

# A run of the suite is ~1000 lines, almost all of them "PASS". Print the test
# blocks that did not pass (they carry the assertion or the stack trace), the
# rows the results table marks FAIL/ERROR, and the runner's own last word.
show_suite_log() {
    printf '\n'; rule
    printf '%s\n' "$2"
    rule
    awk '
        /^-{20,}$/ { if (lines > 0 && !passed) printf "%s", block; block = ""; lines = 0; passed = 0; next }
        /^={20,}$/ { if (lines > 0 && !passed) printf "%s", block; block = ""; lines = 0; passed = 0; summary = 1 }
        summary == 0 { block = block $0 "\n"; lines++; if ($0 == "PASS") { passed = 1 }; next }
        /FAIL|ERROR|^Ran [0-9]+ tests|^(PASSED|FAILED)/ { print }
        END { if (lines > 0 && !passed) printf "%s", block }
    ' "$1"
    rule
    printf 'full log: %s\n' "$1"
}

# The same warning comes back from every device. Print each distinct text
# once - the count on the device's line says it was seen again - and keep the
# per-device originals in the logs.
note_warnings() { [ "$2" -gt 0 ] && { warn_devices=$((warn_devices + 1)); report_warnings "$1"; }; return 0; }
report_warnings() {
    local line key
    while IFS= read -r line; do
        key=${line#WARNING: }
        key=${key#*: }                      # drop the device the compiler names first
        case "
$warn_seen" in
            *"
$key"*) continue ;;
        esac
        warn_seen="$warn_seen
$key"
        warn_distinct=$((warn_distinct + 1))
        printf '    %s\n' "$line"
    done < <(grep '^WARNING' "$1")
}

# ------------------------------------------------------------------ builds --
# Sets build_fail (empty when the device is fine) and build_warnings.
compile_device() {
    local dev=$1 kind=$2 flags rc errors
    build_log="$out/$kind-$dev.log"
    build_prg="$out/prg/$kind-$dev.prg"
    if [ "$kind" = test ]; then flags="-t -l 3 -w"; else flags="$build_flags"; fi
    build_cmd="\"$monkeyc\" -o \"$build_prg\" -f \"$jungle\" -d $dev -y \"$key\" $flags"
    build_fail=""; build_warnings=0
    rm -f "$build_log" "$build_prg"
    ( cd "$proj" && "$monkeyc" -o "$build_prg" -f "$jungle" -d "$dev" -y "$key" $flags ) \
        > "$build_log" 2>&1
    rc=$?
    errors=$(grep -c '^ERROR' "$build_log")
    build_warnings=$(grep -c '^WARNING' "$build_log")
    if [ "$errors" -gt 0 ]; then
        build_fail="the compiler reported $errors error(s)"
    elif [ "$rc" -ne 0 ]; then
        build_fail="monkeyc exited with $rc"
    elif [ ! -f "$build_prg" ]; then
        build_fail="monkeyc produced no .prg"
    elif [ "$strict" -eq 1 ] && [ "$build_warnings" -gt 0 ]; then
        build_fail="$build_warnings compiler warning(s), strict mode"
    fi
}

# -------------------------------------------------------------- unit tests --
sim_running() { pgrep -f 'ConnectIQ.app' >/dev/null 2>&1 || pgrep -x simulator >/dev/null 2>&1; }
start_sim()   { "$sdk/bin/connectiq" >/dev/null 2>&1 & sleep 8; }
restart_sim() {
    pkill -f MonkeyDoDeux >/dev/null 2>&1
    pkill -f 'ConnectIQ.app' >/dev/null 2>&1
    pkill -x simulator >/dev/null 2>&1
    sleep 3
    "$sdk/bin/connectiq" >/dev/null 2>&1 & sleep 10
}

# Runs the suite built by compile_device. Sets test_fail (empty when the suite
# passed) and test_summary ("Ran N tests PASSED"). The simulator drops or hangs
# a run now and then, so a run without any result is retried on a fresh one.
run_suite() {
    local dev=$1 attempt waited pid
    test_log="$out/test-run-$dev.log"
    test_fail=""; test_summary=""
    for attempt in $(seq 1 "$test_attempts"); do
        sim_running || start_sim
        rm -f "$test_log"
        "$monkeydo" "$build_prg" "$dev" -t > "$test_log" 2>&1 &
        pid=$!
        waited=0
        while [ "$waited" -lt "$test_timeout" ]; do
            kill -0 "$pid" 2>/dev/null || break
            if grep -q 'Ran [0-9][0-9]* tests' "$test_log" 2>/dev/null; then sleep 2; break; fi
            sleep 3; waited=$((waited + 3))
        done
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        if grep -q 'Ran [0-9][0-9]* tests' "$test_log" 2>/dev/null; then
            test_summary=$(grep -E 'Ran [0-9]+ tests|^(PASSED|FAILED)' "$test_log" | tail -2 | tr '\n' ' ')
            test_summary=$(printf '%s' "$test_summary" | sed 's/  */ /g; s/ *$//')
            case "$test_summary" in
                *FAILED*) test_fail="the suite reported FAILED" ;;
                *PASSED*) test_fail="" ;;
                *)        test_fail="the runner printed no PASSED/FAILED line" ;;
            esac
            return
        fi
        if [ "$attempt" -lt "$test_attempts" ]; then
            printf 'no result after %s, restarting the simulator... ' "$(fmt_secs "$waited")"
            restart_sim
        fi
    done
    test_fail="no result from the simulator after $test_attempts attempts"
}

# ------------------------------------------------------------------- flags --
mode=""
strict=1
release=0
wanted=""
while [ $# -gt 0 ]; do
    case "$1" in
        build|test|list)
            [ -n "$mode" ] && die "one mode at a time, got '$mode' and '$1'"
            mode=$1 ;;
        --strict)                strict=1 ;;
        --permissive|--no-strict) strict=0 ;;
        --release)               release=1 ;;
        -h|--help)               usage; exit "$EXIT_OK" ;;
        -*)                      die "unknown option '$1' (try --help)" ;;
        *)                       wanted="$wanted $1" ;;
    esac
    shift
done
mode=${mode:-build}
[ "$release" -eq 1 ] && [ "$mode" != build ] && die "--release only applies to the build mode"

build_flags="-l 3 -w"
[ "$release" -eq 1 ] && build_flags="-r $build_flags"

# ------------------------------------------------------------------- start --
[ -f "$manifest" ] || die "no manifest at $manifest (set PROJ_DIR?)"
[ -f "$jungle" ]   || die "no jungle at $jungle (set PROJ_DIR?)"

products=$(manifest_products "$manifest") || die "cannot read the products from $manifest"

if [ -n "$wanted" ]; then
    for dev in $wanted; do
        printf '%s\n' "$products" | grep -qx -- "$dev" \
            || die "'$dev' is not a product in manifest.xml"
    done
    devices=$(printf '%s\n' $wanted | LC_ALL=C sort -u)
else
    devices=$products
fi
total=$(printf '%s\n' "$devices" | wc -l | tr -d ' ')
in_manifest=$(printf '%s\n' "$products" | wc -l | tr -d ' ')

if [ "$mode" = list ]; then
    printf '%s\n' "$devices"
    exit "$EXIT_OK"
fi

sdk=$(find_sdk)
[ -n "$sdk" ] || die "no Connect IQ SDK found; set CIQ_SDK to the SDK folder"
monkeyc="$sdk/bin/monkeyc"
monkeydo="$sdk/bin/monkeydo"
[ -x "$monkeyc" ] || die "no monkeyc in $sdk/bin"
key=$(find_key)
[ -n "$key" ] || die "no developer key; set DEVELOPER_KEY to the .der file"
[ -f "$key" ] || die "no developer key at $key"
devices_dir=$(find_devices_dir)
if [ "$mode" = test ]; then
    [ -x "$monkeydo" ] || die "no monkeydo in $sdk/bin"
fi
mkdir -p "$out/prg" || die "cannot write to $out"

if [ "$strict" -eq 1 ]; then strictness="strict: a warning fails the device"
else                          strictness="permissive: warnings are printed only"; fi
if [ "$mode" = test ]; then what="unit tests (-t)"
elif [ "$release" -eq 1 ]; then what="release build (-r)"
else what="debug build"; fi

printf '%s %s - %s, %s\n' "$self" "$mode" "$what" "$strictness"
printf 'manifest %s: %s product(s)' "${manifest#$proj/}" "$in_manifest"
[ "$total" != "$in_manifest" ] && printf ', %s of them asked for' "$total"
printf '\n'
printf 'SDK      %s\n' "${sdk##*/}"
printf 'logs     %s\n' "$out"
rule

missing=""
for dev in $devices; do
    [ -n "$(unsupported_reason "$dev")" ] && missing="$missing $dev"
done
if [ -n "$missing" ]; then
    printf 'note     the SDK has no definition for:%s\n' "$missing"
    if [ "$mode" = test ]; then
        printf '         skipped below, but monkeyc warns about them on every build,\n'
        printf '         and in strict mode that warning fails the first device built\n'
    else
        printf '         install them in the SDK manager, or name the products to build\n'
    fi
    rule
fi

index=0
compiled=0
warn_devices=0
warn_distinct=0
warn_seen=""
skipped=0
skipped_list=""
failed_device=""
failed_reason=""
started=$SECONDS

for dev in $devices; do
    index=$((index + 1))
    printf '%*s/%s  %-21s' ${#total} "$index" "$total" "$dev"
    device_started=$SECONDS

    reason=$(unsupported_reason "$dev")
    if [ -n "$reason" ] && [ "$mode" = test ]; then
        printf '%-6s %s\n' "SKIP" "$reason"
        skipped=$((skipped + 1))
        skipped_list="$skipped_list
  $dev  $reason"
        continue
    fi
    if [ -n "$reason" ]; then
        printf '%-6s %s\n' "FAIL" "$reason"
        failed_device=$dev
        failed_reason=$reason
        printf '\n%s cannot be built here. Install it in the SDK manager (Devices),\nor run with a device list that leaves it out.\n' "$dev"
        break
    fi

    compile_device "$dev" "$mode"
    if [ -n "$build_fail" ]; then
        printf '%-6s %s (%s)\n' "FAIL" "$build_fail" "$(fmt_secs $((SECONDS - device_started)))"
        show_log "$build_log" "$build_cmd"
        failed_device=$dev
        failed_reason=$build_fail
        break
    fi

    if [ "$mode" = build ]; then
        printf '%-6s %s' "OK" "$(fmt_secs $((SECONDS - device_started)))"
        [ "$build_warnings" -gt 0 ] && printf ', %s warning(s)' "$build_warnings"
        printf '\n'
        note_warnings "$build_log" "$build_warnings"
        compiled=$((compiled + 1))
        continue
    fi

    run_suite "$dev"
    if [ -n "$test_fail" ]; then
        printf '%-6s %s (%s)\n' "FAIL" "$test_fail" "$(fmt_secs $((SECONDS - device_started)))"
        if [ -s "$test_log" ]; then
            show_suite_log "$test_log" "\"$monkeydo\" \"$build_prg\" $dev -t"
        fi
        failed_device=$dev
        failed_reason=$test_fail
        break
    fi
    printf '%-6s %s (%s)' "OK" "$test_summary" "$(fmt_secs $((SECONDS - device_started)))"
    [ "$build_warnings" -gt 0 ] && printf ', %s build warning(s)' "$build_warnings"
    printf '\n'
    note_warnings "$build_log" "$build_warnings"
    compiled=$((compiled + 1))
done

# ----------------------------------------------------------------- summary --
elapsed=$((SECONDS - started))
[ -z "$failed_device" ] && rule
if [ "$mode" = test ]; then did="ran the suite"; else did="compiled"; fi
if [ -n "$failed_device" ]; then
    printf '%s of %s devices %s, then %s FAILED: %s\n' \
        "$compiled" "$total" "$did" "$failed_device" "$failed_reason"
    printf '%s device(s) after it were not attempted. Full output above and in %s.\n' \
        $((total - index)) "$out"
    [ "$skipped" -gt 0 ] && printf '%s device(s) skipped:%s\n' "$skipped" "$skipped_list"
    printf 'Total %s.\n' "$(fmt_secs "$elapsed")"
    exit "$EXIT_FAILED"
fi
printf '%s of %s devices %s, 0 failed' "$compiled" "$total" "$did"
[ "$skipped" -gt 0 ] && printf ', %s skipped' "$skipped"
printf '. Total %s.\n' "$(fmt_secs "$elapsed")"
[ "$skipped" -gt 0 ] && printf 'skipped:%s\n' "$skipped_list"
[ "$warn_devices" -gt 0 ] && printf 'warnings: %s device(s), %s distinct message(s) printed above, all of them in %s\n' \
    "$warn_devices" "$warn_distinct" "$out"
exit "$EXIT_OK"
