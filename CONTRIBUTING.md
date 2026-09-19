# Developer Guide

## Prerequisites

- [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 4.0.0 or later
- Visual Studio Code with the [Monkey C extension](https://marketplace.visualstudio.com/items?itemName=garmin.monkey-c)
- A developer key (`.der`): generate one via the SDK Manager or [Garmin's keytool](https://developer.garmin.com/connect-iq/sdk/)

## Building

**VS Code:** `Ctrl+Shift+P` -> *Monkey C: Build for Device* -> select target device.

**Command line:**
```bash
export CIQ_HOME=~/connectiq-sdk
$CIQ_HOME/bin/monkeyc -o bin/PowerNap.prg -f monkey.jungle -d fenix847mm -y dev_key.der
```

Every product in `manifest.xml`, one device at a time, stopping at the first
failure: `tools/matrix.sh` (see [The device matrix](#the-device-matrix-toolsmatrixsh)).

**Simulator:**
```bash
$CIQ_HOME/bin/connectiq &
$CIQ_HOME/bin/monkeydo bin/PowerNap.prg fenix847mm
```

## Running Tests

```
Ctrl+Shift+P -> Monkey C: Run Tests
```

Tests live under `test/` (one file per area, each with its own name prefix because test functions are global) and use the `Toybox.Test` framework (`:test` annotation). All test helpers in the source files carry the `(:debug)` annotation and are excluded from production builds. Tests drive a fake clock second by second (`testFeedSecond`, `testRunMinutes`, `testAdvanceClock`) so every timing rule is exercised without waiting.

Command line: build with `-t` and run `monkeydo <prg> fenix847mm -t` with the simulator open.

Every device at once (and the same suite on each of them): see
[The device matrix](#the-device-matrix-toolsmatrixsh) below.

## The device matrix (`tools/matrix.sh`)

Texts, colours and layouts are resolution- and palette-sensitive: a line that
fits the 454 px fēnix 8 overflows the 176 px Instinct 3 Solar, whose screen is
1-bit. `tools/matrix.sh` is the safety net for changes like those. It builds -
or runs the unit tests for - **every product in `manifest.xml`**, one device at
a time, in alphabetical order, and stops at the first device that fails.

The device list is read out of `manifest.xml` on every run (a product inside an
XML comment is ignored), so a product added there is picked up without touching
the script.

### Modes

| Command | What it does |
|---------|--------------|
| `tools/matrix.sh` (or `tools/matrix.sh build`) | compiles the debug build for every product |
| `tools/matrix.sh build --release` | compiles the release build (`-r`), the one the store package is made of |
| `tools/matrix.sh test` | builds with `-t` and runs the whole suite on each device in the simulator |
| `tools/matrix.sh list` | prints the device ids read from the manifest, one per line |

Device ids after the mode limit the run to those products
(`tools/matrix.sh test fenix847mm instinct3solar45mm`); every id must appear in
the manifest, and the order stays alphabetical.

### Strict and permissive

Strict is the default, and the way to run it: a device whose compiler output
holds a `WARNING` fails, its full output is printed, and the run stops there.
Both builds are warning-free on every product in the manifest, so
`tools/matrix.sh build` and `tools/matrix.sh build --release` each end with
0 failures on a clean tree.

`--permissive` is a diagnostic, not a working mode: it keeps the warnings
visible (counted on the device's line, each distinct text printed once, all of
them kept in the logs) but lets the run continue, which is what you want when
you have just introduced warnings and would rather see all of them in one pass
than fix them one device at a time. Then make strict green again; a release sweep that
needs `--permissive` is a release that is not ready. `--strict` spells out the
default.

```bash
tools/matrix.sh build                          # strict: the first warning stops the run
tools/matrix.sh build --permissive             # diagnostic: every warning in one pass
```

### What a run prints

```
matrix.sh build - debug build, strict: a warning fails the device
manifest manifest.xml: 43 product(s)
SDK      connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b
logs     /tmp/powernap-matrix
--------------------------------------------------------------------
 1/43  d2mach1              OK     3s
 ...
43/43  vivoactive6          OK     3s
--------------------------------------------------------------------
43 of 43 devices compiled, 0 failed. Total 1m54s.
```

One line per device: `OK`, `FAIL` or `SKIP`. A device that fails prints its whole
compiler output, framed, under the exact `monkeyc` command that produced it, so
it can be repeated by hand; in test mode a suite that fails prints the tests that
did not pass and the runner's own summary instead of all ~1000 lines. Nothing
after the failure is attempted, and the summary names the device and counts the
ones that got through before it. Every device leaves its logs in `$OUT_DIR`
(`/tmp/powernap-matrix` by default): `build-<device>.log`, `test-<device>.log`
for the test build and `test-run-<device>.log` for the simulator run.

### Skips (test mode)

A product whose device the SDK manager never downloaded, or whose device
definition carries no watch-app slot, cannot run the suite. Test mode prints
`SKIP` and the reason on that device's line, names it again in the summary, and
carries on; the run can still end with exit 0, but it never passes over a device
in silence. Build mode does not skip: the same device is a `FAIL` there, because
every product in the manifest has to compile. Either way the run opens with a
`note` line listing the products the SDK has no definition for - `monkeyc` warns
about them on every single build, and in strict mode that warning is what fails
the first device.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | every device passed; devices skipped in test mode are named in the summary |
| `1` | a device failed - its output was printed and the run stopped at that device |
| `2` | the run never started: bad usage, or no manifest / product list / SDK / developer key |

### Environment

| Variable | Default |
|----------|---------|
| `CIQ_SDK`, `CIQ_HOME` | the SDK the SDK manager points at (`current-sdk.cfg`), else `~/connectiq-sdk`, else the newest installed SDK |
| `CIQ_DEVICES` | the `Devices` folder beside the SDK, where the skip check reads `compiler.json` |
| `DEVELOPER_KEY` | `~/developer_key.der`, else `monkeyC.developerKeyPath` from `.vscode/settings.json` |
| `PROJ_DIR` | the folder above `tools/`; point it at a frozen copy of the tree to check a release |
| `OUT_DIR` | `/tmp/powernap-matrix` |
| `TEST_TIMEOUT` | `420` seconds to wait for one device's suite |
| `TEST_ATTEMPTS` | `3` tries per device, with a simulator restart in between |

### When to run what

**Every pull request:** the suite on the protocol set - five screens that between
them catch what the rest would (454 px AMOLED, 176 px 1-bit octagon with a lens,
260 px MIP, small AMOLED, and a watch with no tone support):

```bash
tools/matrix.sh test fenix847mm instinct3solar45mm fr255s venu3s vivoactive5
```

**Once before publishing:** the full sweep, every product in the manifest, all
three strict:

```bash
tools/matrix.sh build                          # all 43 products compile, ~2 min
tools/matrix.sh build --release                # the store build, same devices, ~2 min
tools/matrix.sh test                           # the suite everywhere, ~1 min per device
```

**While working:** `tools/runtests.sh <device> ...` for ad-hoc runs on one or two
devices; it takes its list from the command line, restarts the simulator and
retries, and prints one line per device.

`manifest.xml`, read through `matrix.sh`, is the source of truth for which devices
the app supports: nothing else has to be kept in step with it. `tools/devices.txt`
is only a hand-kept copy for `runtests.sh` and can drift, so
`tools/runtests.sh $(tools/matrix.sh list)` is the form that cannot.

If a test that reads a stored setting fails on every device, the usual culprit is
the simulator's settings file, one per app id and shared by every build: close the
simulator and delete `$TMPDIR/com.garmin.connectiq/GARMIN/APPS/SETTINGS/*.SET`.

## Architecture

### Source files

| File | Responsibility |
|------|----------------|
| `PowerNapApp.mc` | `AppBase` lifecycle: creates `SleepDetector` and `AlarmManager`, hands them to the view stack, cleans up on exit |
| `PowerNapView.mc` | Start screen + 4 nap screens built as prioritised line lists; live 1 Hz refresh during a nap, minute-aligned refresh on the start screen; remembers the duration in `Application.Storage`; owns the two-press `ConfirmPress` |
| `PowerNapDelegate.mc` | `InputDelegate` (not `BehaviorDelegate`): routes physical button presses and tap coordinates to view actions |
| `SleepDetector.mc` | Core engine: wall-clock timing, per-minute sensor aggregation, onset / wake / smart-wake logic, deadline alarm |
| `AlarmManager.mc` | Ramp-table crescendo (9 steps to full strength in ~2 min, then persistent); restarts its own timer when the wait changes; AMOLED-safe backlight handling; quiet onset gate |
| `ScreenLayout.mc` | Line layout that fits any screen (drops/shrinks by priority, round chord, Instinct subscreen) + `Palette` |
| `ConfirmPress.mc` | Two-press confirmation for stopping a nap or the alarm |
| `RingMath.mc` | Angle math for the summary ring |
| `AlarmCap.mc` | The one "Alarm by" formula (start rounded up to the next minute + allowance + nap), used by the preview and by the nap |

### State machine (SleepDetector)

```
STATE_CALIBRATING (0)
  -> STATE_MONITORING (1)    at the first minute boundary after 120 s
  -> STATE_ALARM (3)         deadline alarm (never in practice: allowance >= 5 min)

STATE_MONITORING (1)
  -> STATE_SLEEPING (2)      2 still minutes with HR drop, or 5 still minutes,
                             or 2 still minutes when re-entering after a wake
  -> STATE_ALARM (3)         deadline alarm (sleep never detected), or planned
                             alarm time reached while awake after a wake episode

STATE_SLEEPING (2)
  -> STATE_MONITORING (1)    wake episode (sustained motion or 2-minute HR rise)
  -> STATE_ALARM (3)         planned alarm time, or smart wake inside the window

STATE_ALARM (3)
  -> STATE_SUMMARY (4)       when user dismisses alarm

STATE_SUMMARY (4)
  Terminal state; BACK or START returns to the start screen, where BACK twice exits
```

### Timing architecture

A single `Timer.Timer` ticks every second once `start()` is called:

- **every tick:** `checkAlarmDue()` compares the wall clock with `_napEndSec` (after onset; capped at `_deadlineSec`) or `_deadlineSec` (before onset), then `WatchUi.requestUpdate()`.
- **every 60th tick:** `onMinute()` snapshots the per-minute HR/motion accumulators fed by the sensor callbacks and runs the onset / wake / smart-wake logic.

`AlarmManager` owns the only other timer (the ring repeat timer).

### Sleep detection

See the class comment at the top of `SleepDetector.mc`; it is the single source of truth for thresholds. In short: a still minute has mean motion below the threshold and at most 5 active seconds; onset needs 2 still minutes with an HR drop or 5 without; a wake needs 10 active seconds, a 100 mg minute mean, or a 10 BPM rise for 2 minutes.

### Smart Wake Window

Effective naps (planned end minus onset, possibly shortened by the deadline cap) of 15 min or more; window = min(5 min, 20 % of the effective nap) before the planned end. Inside it a restless minute (6 or more active seconds, or mean >= 1.5 x threshold) or a 5 BPM rise fires `ALARM_SMART_WAKE`.

### Deadline cap and frozen settings

The deadline comes from `AlarmCap.deadlineSec()`: the start rounded UP to the next whole minute + allowance + nap. Both the start screen's preview and `beginSession()` call it, so a nap started anywhere in the minute the preview was drawn in keeps that time, and the cap is itself a whole minute, so the alarm rings at the latest exactly at the "Alarm by HH:MM" shown. It is a hard cap: a late onset shortens the nap instead of pushing the alarm past it. Detector settings are frozen for the running nap; changes from the phone apply to the next one. Alarm Type applies immediately. The duration a nap started with is remembered in `Application.Storage` (written at once, unlike properties, which are only saved when the app stops) and opens the next session unless the phone setting changed since.

### Alarm escalation (AlarmManager)

One table, `RAMP`, one row per step `[intensity %, pulse ms, pulses, gap ms, interval ms, rings]`; everything else is derived from it (see the class comment for the full table):

| Step | Intensity | Pulses | Wait after each ring | First ring at |
|------|-----------|--------|----------------------|---------------|
| 0 | 22 % | 2 × 120 ms | 10 s | 0 s |
| 1-7 | 28 → 92 % | 2-3 × 140-320 ms | 9 → 5 s | 20 → 108 s |
| 8 | 100 % | 3 × 350 ms | 5 s | 118 s (36 rings = 3 min) |
| 9 (persistent) | 100 % | 3 × 350 ms | 30 s | 298 s |

The wait after a ring is that of its step; when it changes the repeat timer is restarted. Thresholds resolved with `firstStepAtLeast(pct)`: melody joins ("Both") at 40 %, backlight from 50 %, Stay Awake doze alarm starts at 60 %, nudge uses the 30 % step. Display phases: 0 below 40 %, 1 below 65 %, 2 below 100 %, 3 at full.

**AMOLED rule:** vibration and tone run first, each in its own try block; `Attention.backlight(true)` runs last, in its own try block, only from the 50 % step and only on the first two such rings and every 6th after. Burn-in protected displays throw after the display has been held on for about a minute; a backlight call placed before the vibration in a shared try block silences the alarm.

**Quiet onset gate:** `deliver()` and `requestBacklight()` refuse every call while the alarm is not ringing (except from `nudge()`), and `nudge()` is refused unless the detector marked the session as Stay Awake. `test/QuietOnsetTest.mc` and the invariant tests guard it.

## Coding Conventions

- All identifiers, comments, and strings are in English.
- Private fields prefixed with `_` (e.g. `_napDurationMin`).
- Test helpers annotated `(:debug)` to exclude from production builds.
- No external libraries or barrels.

## Store Submission Notes

- Minimum API level: `4.0.0`
- Permission required: `Sensor`
- A privacy policy URL is required by the Connect IQ store because the app reads heart rate data. All processing is on-device; no data leaves the watch.
