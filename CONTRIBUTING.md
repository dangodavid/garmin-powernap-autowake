# Developer Guide

## Prerequisites

- [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 4.0.0 or later
- Visual Studio Code with the [Monkey C extension](https://marketplace.visualstudio.com/items?itemName=garmin.monkey-c)
- A developer key (`.der`): generate one via the SDK Manager or [Garmin's keytool](https://developer.garmin.com/connect-iq/sdk/)

## Git

One branch per pull request, cut from `main`. When the checks in
[What to run and when](#what-to-run-and-when) pass, the branch is merged into
`main` and deleted right away: no long-lived branches, nothing parked on a
branch waiting for something else.

`main` stays publishable. Every commit on it compiles for every product in
`manifest.xml` and passes the suite on the protocol set, so a release can be cut
from `main` at any moment without first repairing it.

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

## What to run and when

### Every pull request

Two commands, together under seven minutes on a warm SDK:

```bash
tools/matrix.sh build                          # strict, every product in the manifest, ~2 min
tools/matrix.sh test fenix847mm instinct3solar45mm fr255s venu3s vivoactive5
```

The build is strict and covers **every** product, because a resource or a text
that only one device rejects is exactly what a narrower run misses. The suite
then runs on the protocol set: five devices that between them cover what the
rest would: the largest AMOLED at 454 px (`fenix847mm`), the 176 px 1-bit
octagon with a subscreen lens (`instinct3solar45mm`), the smallest colour
screen at 218 px MIP (`fr255s`), a small AMOLED (`venu3s`), and a watch with no
`Attention.playTone` at all (`vivoactive5`).

### Pull requests that touch text, colours or layout

The same two commands, **plus** simulator screenshots of the screens you
changed. A build proves the app compiles; it says nothing about how it looks,
and `LayoutTest` only proves that text fits - not that the result reads well.
Three screens are enough to catch the rest:

| Screenshot | Device | Why |
|------------|--------|-----|
| Smallest, and the only monochrome | `instinct3solar45mm` (176 px, 1-bit) | where lines get dropped, texts fall back to their short variants and every colour collapses to white |
| Largest | `fenix847mm` (454 px) | where a block can float apart and slack appears around it |
| Smallest colour screen | `fr255s` (218 px) | the palette on a small MIP display, without the 1-bit fallback hiding a colour mistake |

The smallest screen in the matrix is also the only 1-bit one, so those two
requirements land on the same device; `fr255s` is the third shot because two
pictures of `instinct3solar45mm` would prove the same thing twice.

### Before publishing

The full sweep, all three strict, every product in the manifest:

```bash
tools/matrix.sh build                          # every product compiles, ~2 min
tools/matrix.sh build --release                # the store build, same devices, ~2 min
tools/matrix.sh test                           # the whole suite everywhere, ~1 min per device
```

Then the store package (the version is typed into the upload form; the manifest
carries none):

```bash
monkeyc -e -o bin/PowerNap-<version>.iq -f monkey.jungle -y ~/developer_key.der -r -l 3
```

### New tests are for logic

A new test earns its place when it pins behaviour that can be wrong in a way no
compiler catches: a timing rule, an onset or wake decision, a ramp step, a state
transition, an input sequence. Texts and colours are not tested for their
wording or their hue - `LayoutTest` already checks that whatever a screen says
fits the screen it says it on, and a screenshot is how the rest is judged. A
test that asserts a string literal only has to be edited again the next time the
wording improves.

### `--permissive` is a diagnostic

Strict is the working mode: a `WARNING` fails the device and stops the run.
`--permissive` exists for the one case where you have just introduced warnings
and would rather see all of them in a single pass than fix them one device at a
time. Then make strict green again. A release sweep that needs `--permissive` is
a release that is not ready.

### While working

`tools/runtests.sh <device> ...` for ad-hoc runs on one or two devices: it takes
its list from the command line, restarts the simulator and retries, and prints
one line per device. To run it over the whole matrix without keeping a second
device list anywhere, let the manifest supply the arguments:

```bash
tools/runtests.sh $(tools/matrix.sh list)
```

`manifest.xml`, read through `matrix.sh`, is the source of truth for which
devices the app supports. Nothing else is kept in step with it, and no script or
document may carry a hardcoded copy of that list.

If a test that reads a stored setting fails on every device, the usual culprit is
the simulator's settings file, one per app id and shared by every build: close the
simulator and delete `$TMPDIR/com.garmin.connectiq/GARMIN/APPS/SETTINGS/*.SET`.

## What the tests cover

One file per area under `test/`, each with its own name prefix because test
function names are global. The runner reports the number of **test functions**,
not the number of assertions, and four files multiply what one function checks:

- `LayoutTest.mc` solves every screen against the **running device**, so a full
  sweep runs the same functions once per product in the manifest;
- `InvariantTest.mc` runs a handful of fixed seeds per function and asserts
  after **every simulated second** of every random nap;
- `QuietOnsetTest.mc` loops each scenario over alarm types 0, 1 and 2, and once
  more with the tone channel forced unavailable;
- `AlarmManagerTest.mc` walks the whole `RAMP` table inside single functions, so
  one test covers all ten steps.

So the function count is a floor, not a measure of coverage: a single-digit file
can be carrying more assertions than a file with thirty functions.

| File | What it checks, and why it exists |
|------|-----------------------------------|
| `OnsetTest.mc` | Calibration and sleep onset: the HR baseline as the mean of the first two minutes, what makes a minute "still" (mean motion below the threshold and at most 5 active seconds), and the two ways in - 2 still minutes with the HR drop, or 5 still minutes without it. Onset is the decision the whole nap hangs off; detect it early and the alarm rings early. |
| `WakeTest.mc` | Wake episodes and re-entry: what ends a sleep segment (10 active seconds, a 100 mg minute mean, or a 10 BPM rise held for 2 minutes), that the countdown keeps running through a wake, and that re-entry takes 2 still minutes. The segment arithmetic here is where the summary's "actual sleep" comes from. |
| `TimingTest.mc` | Wall-clock alarm timing: the planned end, the hard deadline cap from `AlarmCap`, and the smart-wake window. The clock is frozen on a whole minute, so every expectation is exact. This is the file that holds the promise the start screen makes - the alarm never rings after "Alarm by HH:MM". |
| `AlarmManagerTest.mc` | The escalation ramp: the owner's constraints (at least 8 steps below full, a gentle first step, intensity and pulse never decreasing, the wait never growing, full strength reached in 100-130 s), the exact ring schedule, the persistent phase, the tone melodies, the nudge, the backlight rule and the "Test alarm" preview. Tuning the table is safe only because these tests fail when a change leaves the approved envelope. |
| `SummaryTest.mc` | Finish and cancel from every state, the statistics (planned completion, sleep efficiency, actual sleep, wake episodes, average and minimum sleep HR), that they freeze once the nap has ended, and `RingMath`'s angle maths for the progress ring. |
| `RegressionTest.mc` | One test per confirmed review finding: HR-plateau wake ping-pong, the sleep-HR fold exclusion, frozen settings and clamping, the app lifecycle (`onInactive`/`onActive`), the alarm channel fallback, the per-phase vibration patterns, `ringNow()`, and the two-press guard. These exist so that a fixed bug cannot come back quietly. |
| `LayoutTest.mc` | Every screen state - start, calibrating, monitoring, sleeping, alarm, summary, Stay Awake, peek card, alarm preview - laid out against a `Dc` of the running device. It asserts that no text is truncated, that nothing leaves the screen or the round chord, and that the layout stays inside its work budget, because every screen redraws at 1 Hz and the Instinct watchdog is 240k bytecodes per event. |
| `StayAwakeTest.mc` | Stay Awake mode: no deadline and no timed alarm at all, the doze rules measured against the rolling HR reference rather than the calibration baseline, the single nudge at 3 still minutes, `noteUserAwake()` ending the still run, and the return to the guard after a doze alarm. |
| `DelegateTest.mc` | The real delegate, view and detector wired together and driven through `handleKey()`/`handleTap()` - the code paths `onKey` and `onTap` run. It owns the key model: BACK walks back one level at a time and only the start screen's BACK x2 exits, START x2 stops, the 1.5 s input lock never traps a burst of presses, and a first START made on one screen never pairs with a second made on another. |
| `QuietOnsetTest.mc` | The QUIET ONSET RULE, with the real `AlarmManager`: nothing vibrates, sounds or lights up at onset, at a wake, at re-entry, at the end of calibration, on a sensor dropout or on resume. Every second of every scenario asserts that the manager's blocked-delivery counter is still zero. The rule is non-negotiable, so it is guarded structurally rather than by review. |
| `MotionTest.mc` | `MotionMath.batchMotion` on raw 25-sample accelerometer batches and the path that turns one batch into one motion second: null axes skipped, ragged arrays, too few usable samples, and above all that a constant sensor offset changes nothing. The old measure read a watch with a +40 mg offset as permanently moving, so a still sleeper was never still on the High setting. |
| `InvariantTest.mc` | Seeded random naps from a small Markov model (awake -> drowsy -> asleep, with wakes, stirs, HR dropouts and minutes with no accelerometer data), checked after every simulated second against the rules that must hold whatever the sensors say - above all that the alarm always fires and never after the deadline. Plus negative tests. A failure prints its seed, so the case replays exactly. |
| `TraceTest.mc` | Replays of naps recorded on a real watch, minute by minute through `testReplayMinute`. The file header documents how to record one. It exists so that a nap that behaved wrong on the wrist becomes a permanent test instead of an anecdote. |
| `StartScreenTest.mc` | The start screen's promise: that `AlarmCap` is the single formula behind both the preview and the running nap, so a nap started in the minute the preview was drawn in keeps exactly that time; the minute-aligned refresh; the duration remembered in `Application.Storage`; and that the whole flow can be driven from the buttons alone. |

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
