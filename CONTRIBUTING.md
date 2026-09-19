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

## Architecture

### Source files

| File | Responsibility |
|------|----------------|
| `PowerNapApp.mc` | `AppBase` lifecycle: creates `SleepDetector` and `AlarmManager`, hands them to the view stack, cleans up on exit |
| `PowerNapView.mc` | Start screen + 4 nap screens built as prioritised line lists; live 1 Hz refresh; owns the two-press `ConfirmPress` |
| `PowerNapDelegate.mc` | `InputDelegate` (not `BehaviorDelegate`): routes physical button presses and tap coordinates to view actions |
| `SleepDetector.mc` | Core engine: wall-clock timing, per-minute sensor aggregation, onset / wake / smart-wake logic, deadline alarm |
| `AlarmManager.mc` | Ramp-table crescendo (9 steps to full strength in ~2 min, then persistent); restarts its own timer when the wait changes; AMOLED-safe backlight handling; quiet onset gate |
| `ScreenLayout.mc` | Line layout that fits any screen (drops/shrinks by priority, round chord, Instinct subscreen) + `Palette` |
| `ConfirmPress.mc` | Two-press confirmation for stopping a nap or the alarm |
| `RingMath.mc` | Angle math for the summary ring |

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
  Terminal state; user presses BACK to exit
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

The deadline (start + allowance + nap) is shown as "Alarm by HH:MM" (rounded up to the minute) and is a hard cap: a late onset shortens the nap instead of pushing the alarm past it. Detector settings are frozen for the running nap; changes from the phone apply to the next one. Alarm Type applies immediately.

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
