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

Tests live in `test/SleepDetectorTest.mc` and use the `Toybox.Test` framework (`:test` annotation). All test helpers in `SleepDetector.mc` carry the `(:debug)` annotation and are excluded from production builds.

## Architecture

### Source files

| File | Responsibility |
|------|----------------|
| `PowerNapApp.mc` | `AppBase` lifecycle: creates `SleepDetector` and `AlarmManager`, hands them to the view stack, cleans up on exit |
| `PowerNapView.mc` | Renders 6 screens by polling `SleepDetector.getState()`; triggers `AlarmManager.startAlarm()` on first entry into `STATE_ALARM` |
| `PowerNapDelegate.mc` | `InputDelegate` (not `BehaviorDelegate`): routes physical button presses and tap coordinates to view actions |
| `SleepDetector.mc` | Core sleep-detection engine: 6-state machine driven by two timers and two sensor callbacks |
| `AlarmManager.mc` | 4-phase escalating alarm: restarts its own timer on each phase boundary |

### State machine (SleepDetector)

```
STATE_CALIBRATING (0)
  -> STATE_MONITORING (1)    after 12 x 10s calibration ticks (2 min)
  -> STATE_TIMEOUT (5)       if 60 min pass with no sleep detected

STATE_MONITORING (1)
  -> STATE_SLEEPING (2)      when HR drop + immobility conditions hold for >= 3 min
  -> STATE_TIMEOUT (5)       60-min monitoring timeout (only if sleep never started)

STATE_SLEEPING (2)
  -> STATE_MONITORING (1)    on spontaneous wake (motion or HR spike)
  -> STATE_ALARM (3)         on countdown expiry or Smart Wake trigger

STATE_ALARM (3)
  -> STATE_SUMMARY (4)       when user dismisses alarm

STATE_SUMMARY (4) / STATE_TIMEOUT (5)
  Terminal states; user presses BACK to exit
```

### Timer architecture

Two independent timers run concurrently once `start()` is called:

- **`_calibTimer`** (10s): collects 12 HR samples for the resting baseline; auto-stops when `_calibTickCount >= 12`.
- **`_pollTimer`** (60s): drives monitoring logic, countdown decrement, and state transitions for the entire nap lifecycle. Also ticks during `STATE_CALIBRATING` to pre-populate the HR and motion rolling windows.

### Sleep detection

Detection requires all of the following, sustained for `_immobilityRequiredSec` (180 s):

1. `mean(_hrWindow[-3:]) <= _hrBaseline - _hrDropThreshold`
2. `_motionMagnitude < _motionThreshold` (live accelerometer reading, no windowing)

### Smart Wake Window

In the last 5 minutes before alarm time, `detectLightSleep()` checks for light-sleep
signals and fires the alarm early if found. Guard: skipped entirely for naps of 5 min
or less, where the window would cover the entire nap.

### Alarm escalation (AlarmManager)

Four phases, each running for 4 rings before the timer interval tightens:

| Phase | Rings | Interval | Vibration intensity |
|-------|-------|----------|---------------------|
| 0 - feather | 0-3  | 9 s | 15 % |
| 1 - gentle  | 4-7  | 7 s | 30 % |
| 2 - medium  | 8-11 | 6 s | 65 % |
| 3 - full    | 12+  | 5 s | 100 % |

On each phase transition the current timer is stopped and restarted with the new interval.

## Coding Conventions

- All identifiers, comments, and strings are in English.
- Private fields prefixed with `_` (e.g. `_napDurationMin`).
- Test helpers annotated `(:debug)` to exclude from production builds.
- No external libraries or barrels.

## Store Submission Notes

- Minimum API level: `4.0.0`
- Permission required: `Sensor`
- A privacy policy URL is required by the Connect IQ store because the app reads heart rate data. All processing is on-device; no data leaves the watch.
