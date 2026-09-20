# CLAUDE.md  - garmin-powernap-autowake

## Rules

- One branch per PR; merge into `main` when the checks pass, then delete the branch. `main` stays publishable.
- Before a merge: `tools/matrix.sh build` (strict, every product) plus `tools/matrix.sh test` on the protocol set.
- A PR that changes text, colours or layout also needs simulator screenshots: `instinct3solar45mm` (smallest, and the only 1-bit), `fenix847mm` (largest), `fr255s` (smallest colour screen, so the three shots do not prove the same thing twice).
- Supported devices are read from `manifest.xml`, never from a hardcoded list.
- New tests are for logic, not for texts and colours.
- Every build meant for a wrist carries its commit in its file name
  (`PowerNap-<version>-<sha>-<device>.prg`, the file copied to `GARMIN/APPS/`);
  only the store package `PowerNap-<version>.iq`, built from `main`, is named
  without one. An old package is never reused. See "Release status".
- BACK contract (owner's; changing it needs the owner's word, not a session's judgement):
  BACK goes back one level and never leaves the app below the start screen, so
  pressing it again walks to the start screen; only the start screen exits, on a
  second BACK within 4 s, after the popup "Press BACK again to exit". Wherever that
  step would END something - a nap, a ringing alarm, a Stay Awake session - it takes
  two presses in that same 4 s window, after a popup saying which of the three it
  is, and the first press changes nothing at all: the nap runs on, the alarm keeps
  ringing exactly as loudly as it had got (not paused, not quietened), the guard
  keeps guarding. Where nothing is lost one press is enough: the first two minutes
  (calibrating), the summary and the "Test alarm" preview. A right swipe is that
  same BACK OUTSIDE a session only; during a nap and during its alarm every swipe
  does nothing at all, not even arm the pair - there only the buttons act. That is
  the single exception to "a right swipe is BACK" (owner decision 2026-09-20). What
  the app cannot refuse is the system BACK GESTURE, which some touch watches deliver
  as `KEY_ESC` and not as a swipe: it is indistinguishable from the button, so it
  goes through the pair like one, and that pair is now what keeps a stray edge swipe
  from ending a nap (walked in the simulator on 2026-09-20: gesture, popup, wait,
  nap still running).
- Guarded by `testDelegate_backNeverLeavesBelowTheStartScreen` and
  `testDelegate_backReachesTheStartScreenFromEveryScreen` (both walk every screen in
  `BACK_SCREENS`, with `BACK_HINTS` and `BACK_STEPS` beside it),
  `testDelegate_backWalksBackToStartThenExits`,
  `testDelegate_startScreenBackTwiceExits`,
  `testDelegate_swipeRightIsBackOutsideTheNap` and, for the wording on each screen,
  `testLayout_backHintBanner`. Verified by mutation on 2026-09-20: letting the nap
  give way to a single BACK fails 6 of them, the alarm 8, both 9, and letting a
  swipe act during a nap or its alarm fails
  `testDelegate_swipeRightIsBackOutsideTheNap` on both screens.
- If something cannot be done the way it was asked for, stop and propose the alternative instead of improvising.

Procedure, device sets, release steps and what each test file covers: `CONTRIBUTING.md`.

## Project Overview

A Garmin Connect IQ watchapp that automatically detects when a user falls asleep
(sustained stillness, accelerated by a heart-rate drop) and wakes them after a
configurable nap duration via an escalating vibration/tone alarm. The alarm is
guaranteed: it never rings later than the deadline shown as "Alarm by HH:MM"
(`AlarmCap`: start rounded up to the next whole minute + fallAsleepAllowance +
napDuration), whether or not sleep is detected.
Duration 0 on the watch is **Stay Awake** mode: the same detection buzzes the
user when they doze off (see "Stay Awake mode" below).

## Release status

The manifest carries no version number - it is typed into the Connect IQ
upload form - so the only authoritative answer to "what is live" is the app's
own page in the Connect IQ store and its entry in the developer dashboard.
Look there before trusting any number written down here.

As of 2026-09-20: **published = 1.0.2 (internal 2)**. **1.1.0 is finished code
on `main` that nobody has downloaded**: every "v1.1.0" and "since 1.1.0" note
below means "since the unreleased 1.1.0", not "in the version users run". So
Stay Awake, the ramp table, "Test alarm", the BACK key model and "Alarm by"
are all unreleased.

**Every build meant for a wrist carries its commit in its file name**:
`PowerNap-<version>-<short sha>-<device>.prg` for a sideload (that is the
file copied to `GARMIN/APPS/`; `monkeyc -e` ignores `-d` and packs all 56
device variants, so an `.iq` is never "the build for one watch"), and
`PowerNap-<version>.iq` only for the file uploaded to the store, built from
`main` at the commit being published. A package whose name does
not say which commit it is cannot be trusted a day later, and an `.iq` left
over from an earlier attempt is never repackaged: it was built from whatever
the tree held that day.

That rule was written after `bin/PowerNap-1.1.0.iq`. Built on 2026-09-19 at
22:02, it predated `b589eb4` of 23:49 (BACK became a back button) and
`130212e` (the exit flag moved behind `(:debug)`), so it never matched
`main`: its BACK was the `44fe39e`/`080c7bc` model, BACK x2 at every level,
which the owner rejected on the wrist that same night. Nothing said so from
its name, and it was sideloaded and tested by mistake. It was deleted on
2026-09-20; `bin/` is not in version control, so nothing was lost.

## Language & SDK

- **Language:** Monkey C (Garmin proprietary)
- **SDK:** Garmin Connect IQ SDK 4.0.0+ (developed with SDK 9.1.0)
- **APIs used:** `Toybox.Sensor`, `Toybox.WatchUi`, `Toybox.Attention`,
  `Toybox.Timer`, `Toybox.Application`, `Toybox.Time`, `Toybox.Math`

## Build Commands

**VS Code (recommended):**
`Ctrl+Shift+P` -> *Monkey C: Build for Device* -> select target device

**Command-line (SDK lives under Library on macOS; `~/connectiq-sdk` is a symlink convention):**
```bash
SDK="$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/<sdk-folder>"
"$SDK/bin/monkeyc" -o bin/PowerNap.prg -f monkey.jungle -d fenix847mm -y ~/developer_key.der -r
```

**Simulator:**
```bash
"$SDK/bin/connectiq" &
"$SDK/bin/monkeydo" bin/PowerNap.prg fenix847mm
```

**Deploy to device:** Copy `bin/PowerNap.prg` to `GARMIN/APPS/` via USB.

**Run unit tests (VS Code):** `Ctrl+Shift+P` -> *Monkey C: Run Tests*

**Run unit tests (CLI, headless apart from the simulator window):**
```bash
"$SDK/bin/monkeyc" -o /tmp/PowerNapTest.prg -f monkey.jungle -d fenix847mm -y ~/developer_key.der -t -l 3 -w
"$SDK/bin/connectiq" &
"$SDK/bin/monkeydo" /tmp/PowerNapTest.prg fenix847mm -t     # prints "Ran N tests" and PASSED/FAILED
```

## Project Structure

```
source/
  PowerNapApp.mc        # AppBase lifecycle  - creates SleepDetector + AlarmManager,
                        #   provides them to View/Delegate, cleans up on exit;
                        #   Lifecycle.resume (onActive) is a testable module function
  PowerNapView.mc       # Start screen, nap screens, Stay Awake screens and the peek card,
                        #   each a prioritised line list for ScreenLayout; live 1 Hz refresh
                        #   (start screen: own UI timer aligned to the minute boundary for the
                        #   clock and the "Alarm by" preview); remembers the last nap duration
                        #   in Application.Storage; tap zones measured from the laid-out start screen
  PowerNapDelegate.mc   # InputDelegate (NOT BehaviorDelegate) for raw tap coords;
                        #   key model (BACK goes back, x2 exits on the start screen; START x2 stop)
                        #   in handleKey()/handleTap()/handleSwipe();
                        #   start-screen menu (Menu2) with "Test alarm" + PowerNapMenuDelegate
  SleepDetector.mc      # Core engine  - wall-clock timing, per-minute sensor aggregation,
                        #   onset / wake / smart-wake logic, deadline cap, frozen settings,
                        #   Stay Awake mode, debug-only trace log
  AlarmManager.mc       # Ramp-table alarm (9 steps to full in ~2 min + persistent),
                        #   vibration/melody channel fallback, quiet onset gate, Stay
                        #   Awake nudge; ToneClock overlap guard
  MotionMath.mc         # Offset-free motion value of one accelerometer batch
  ScreenLayout.mc       # Line layout that fits 176-454 px round/octagon screens (text,
                        #   dividers, spacers, popup banner, two-tone label/value lines);
                        #   Palette module: the text hierarchy and the accent
                        #   (Instinct 3 Solar is 1-bit, so every shade folds onto white)
  ConfirmPress.mc       # Two-press confirmation, contexts EXIT (BACK) / STOP (START), wrap-safe
  RingMath.mc           # Angle math for the summary progress ring (unit-testable)
  AlarmCap.mc           # The one "Alarm by" formula (start rounded up to the next minute
                        #   + allowance + nap), used by the preview and by the running nap
test/
  OnsetTest.mc          # calibration, stillness, HR-drop and stillness-only onset
  WakeTest.mc           # wake episodes, re-entry, sleep accumulation
  TimingTest.mc         # wall-clock alarm, deadline cap, smart-wake window
  AlarmManagerTest.mc   # ramp constraints/schedule, persistent phase, melodies, nudge, backlight, preview
  SummaryTest.mc        # finish/cancel paths, statistics, RingMath
  RegressionTest.mc     # HR wake rules, frozen settings, lifecycle, channel fallback, timer wrap
  LayoutTest.mc         # every screen (start, nap, peek, Stay Awake) fits the running device
  StayAwakeTest.mc      # doze rules, rolling HR reference, nudge, back on guard
  DelegateTest.mc       # buttons/taps through the real delegate + view + detector
  QuietOnsetTest.mc     # QUIET ONSET RULE: the real AlarmManager is silent every second until the alarm
  MotionTest.mc         # raw accelerometer batches, offset independence
  InvariantTest.mc      # seeded random naps checked every second + negative tests
  TraceTest.mc          # replays of recorded naps (how to record one is in the file)
  StartScreenTest.mc    # the AlarmCap formula, preview == the nap it starts, the live
                        #   minute refresh, the remembered duration, the button-only flow
resources/
  drawables/            # launcher_icon.png (60x60 default) + drawables.xml
  properties/           # Default property values
  settings/             # Companion app settings UI definitions
  strings/              # Localized strings (English only), the on-screen hints included
resources-launcher/     # LauncherIcon at each device's native size (40 MIP, 54, 56, 62 1-bit,
                        #   65, 70), wired per device in monkey.jungle; PNGs drawn by
                        #   generate_launcher_icons.py (outside every resource path)
tools/
  matrix.sh             # every <iq:product> of manifest.xml, read on each run (never a
                        #   hardcoded list): modes build | test | list, alphabetical,
                        #   one device at a time, stop at the first failure; --strict
                        #   (default: a WARNING fails the device) / --permissive,
                        #   --release; exit 0 ok, 1 a device failed, 2 could not start;
                        #   device ids as arguments narrow the run (CONTRIBUTING.md)
  runtests.sh           # build (-t -l 3 -w) + monkeydo -t per device, log per device,
                        #   simulator restart + 3 attempts; PROJ_DIR/OUT_DIR overrides
                        #   (no device list of its own: tools/matrix.sh list feeds it)
  lib.sh                # sourced by both (bash and zsh): ciq_find_sdk(), the one
                        #   SDK lookup in the repo - CIQ_SDK/CIQ_HOME, then
                        #   current-sdk.cfg, ~/connectiq-sdk, newest installed;
                        #   never a pinned SDK build id
CONTRIBUTING.md         # the full procedure: git flow, the BACK contract, what to
                        #   run and when, the screenshots a text/colour/layout PR
                        #   needs, the release sweep, and what each test/ file covers
CHANGELOG.md            # what changed for the wearer, from 1.1.0 on (not filled
                        #   in backwards; the published version lives in the store)
docs/history/           # superseded documents, kept for provenance only; each one
                        #   opens with a header saying CLAUDE.md takes precedence
  PLAN-v1.1.0.md        #   the v1.1.0 brief (W1-W7, D1-D4), finished 2026-09-19
```

## Key Configuration (properties.xml defaults)

| Property              | Default       | Range / Values                                     |
|-----------------------|---------------|----------------------------------------------------|
| `napDuration`         | 30 min        | 5–120 min (watch picker: 0 = Stay Awake, never stored; the last started duration lives in Storage, see below) |
| `fallAsleepAllowance` | 15 min        | 5–30 min: deadline = start + this + nap (hard cap) |
| `alarmType`           | 2 (Vibration + nature sound) | 0 = Vibration only, 1 = Nature sound only, 2 = Both (default since 1.1.0) |
| `hrDropThreshold`     | 5 BPM         | 3–20 BPM                                           |
| `motionSensitivity`   | 1 (Medium)    | 0 = Low (80 mg), 1 = Med (50 mg), 2 = High (30 mg); labels say "restless sleepers" / "strict stillness" |

## Supported Devices (manifest.xml, minApiLevel 4.0.0)

Fenix 8 series, Fenix 7 series, Fenix E, Epix 2 series, Forerunner 255/265/570/955/965/970,
Enduro 3, Instinct 3 (AMOLED/Solar), Venu 3/3S/4/4S, Vivoactive 5/6,
MARQ Gen 2, D2 Mach 1/2, Descent MK3

## Sleep Detection Engine (SleepDetector.mc)

### States

| State | Value | Description |
|---|---|---|
| `STATE_CALIBRATING` | 0 | First 2 min: HR baseline = mean of all 1 Hz readings |
| `STATE_MONITORING`  | 1 | Watching for sleep onset, or awake after a wake episode |
| `STATE_SLEEPING`    | 2 | Sleep detected, countdown running |
| `STATE_ALARM`       | 3 | Alarm firing (`getAlarmReason()`: NAP_COMPLETE / SMART_WAKE / DEADLINE / DOZE) |
| `STATE_SUMMARY`     | 4 | Nap finished, stats displayed (`isCancelled()`, `hasSleptAtLeastOnce()`) |

There is no silent timeout state any more: if sleep is never detected the
deadline alarm fires with `ALARM_DEADLINE` and the summary shows "No sleep detected".

### Timing model (wall clock)

- All times are seconds since epoch via `nowSec()` (real clock plus a debug-only
  offset used by tests). One `Timer.Timer` ticks every second (`onTick`).
- Every tick: alarm-due check, then every 60th tick the minute logic (`onMinute`),
  then `WatchUi.requestUpdate()` so every screen value is live.
- `_deadlineSec = AlarmCap.deadlineSec(start, fallAsleepAllowance, napDuration)`
  (= (start / 60 + 1 + allowance + nap) * 60: the start rounded UP to the next
  whole minute, so every second of the minute gives the same cap and the cap is
  itself a whole minute) is a hard cap:
  alarm there if sleep was never detected; once detected the alarm is at
  `_napEndSec = min(onset + _sessionNapSec, _deadlineSec)`. Before onset the view
  shows the deadline as "Alarm by HH:MM"; after onset "Alarm at HH:MM" /
  "Wake at HH:MM" (the planned end). The start screen labels the duration
  "min of sleep" and the monitoring screen says "Alarm N min after sleep":
  users otherwise assume the alarm is start + nap (it floats with onset).
- Detector settings are frozen for the running nap: `loadSettings()` returns early
  while `_running`; the next `start()` (via `PowerNapView.startNap`) reads them
  again. `AlarmManager.loadSettings()` is not frozen: Alarm Type applies at once.
- "Alarm by" is the cap's own minute (the view's `alarmByTexts`, one function
  for the start screen and the nap screens), so the alarm rings at the latest
  exactly at the time shown, never after it. The start screen previews the same
  formula through `SleepDetector.previewDeadlineSec(napMin)` (same clock, same
  allowance): a nap started anywhere in the minute the preview was drawn in
  keeps that time (`testStart_previewMatchesTheNapItStarts`).
  "Alarm at"/"Wake at" show the minute
  the planned end falls in (rounded down). All times follow
  `DeviceSettings.is24Hour` (12 h: "h:mm", no am/pm).
- The alarm is started from the tick callback, so it fires with the display off.

### Sensor aggregation

- `onSensor` (1 Hz) feeds `_accHrSum/_accHrCount`; during calibration also the
  baseline sums; while SLEEPING every reading goes into running
  `_sleepHrSum/_sleepHrCount/_sleepHrMin` (exact nap average, constant memory).
- `onSensorData` (1-second batches of 25 Hz accelerometer) -> `feedAccelBatch`
  -> `MotionMath.batchMotion`: mean absolute deviation of |a| around the
  batch's own mean |a| (millig). Offset-free: the old "|a| - 1 g" read a
  +40 mg sensor offset as permanent motion (never still on High, 30 mg).
  Samples with a null axis are skipped, ragged arrays use the shortest,
  < 2 usable samples = no data. Feeds `_accMotionSum/_accMotionCount` plus
  `_accActiveSec` (seconds whose value exceeds the motion threshold).
- `onMinute` snapshots the accumulators into `_minuteHr` (whole BPM: display,
  trace, sleep-phase rise), `_minuteHrExact` (float: the HR-drop window and the
  Stay Awake history, compared with the exact float baseline), `_minuteMotionMean`,
  `_minuteActiveSec`, decides `_minuteStill`, then resets them. A minute without
  any HR reading sets `_currentHR = 0` (screens show "HR --"). Nothing in the
  detector ever looks at a single sample.

### QUIET ONSET RULE (owner, non-negotiable)

Nothing vibrates, sounds or lights up at sleep detection, a wake episode, a
re-entry, the end of calibration, a sensor dropout or a resume: the only
output of a nap is the alarm, the only output outside an alarm is the Stay
Awake nudge. Enforced structurally in `AlarmManager`: `deliver()` and
`requestBacklight()` refuse every call while `_isAlarming` is false unless
made from inside `nudge()` (`outputAllowed()`), and `nudge()` refuses every
call unless `setStayAwake(true)` was set (by `SleepDetector.beginSession()`
for a Stay Awake session; cleared by `SleepDetector.stop()`). A refused call
increments `_blockedDeliveries` (`testGetBlockedDeliveries()`), which every
test asserts stays 0. Guarded for ever by `test/QuietOnsetTest.mc`
(`testQuiet_*`: HR-drop onset, still onset, wake + re-entry, late onset
capped by the deadline, calibration end and dropouts, resume, no nudge in nap
mode, the real delegate from START to the alarm; alarm types 0/1/2 and the
tone channel forced unavailable) and by the invariant tests (`InvChecker`
runs the real manager: no output counter moves while
`getState() != STATE_ALARM`, one nudge allowed in Stay Awake at 3 still
minutes). Owner's wrist test of 2026-09-19 felt a vibration at onset with a
build that had no code path for it: the debug trace (`onset` without an
`alarm`/`nudge` line at the same second) shows whether a vibration came from
the app or from the watch (abnormal-HR alert, relax reminder, phone
notification, Garmin's own nap detection).

### Stillness and onset

- Still minute: `minuteMotionMean < threshold && minuteActiveSec <= 5`.
- `_stillMinutes` counts consecutive still minutes (also during calibration).
- Onset when `_stillMinutes >= 2` and the HR drop is met (mean of the last 3
  per-minute HR means <= baseline - hrDropThreshold, baseline known), or when
  `_stillMinutes >= 5` regardless of HR. Re-entry after a wake: 2 still minutes.
- The first onset is NOT back-dated (sleep starts at detection). A re-entry
  segment is back-dated by `min(stillMinutes * 60, 120)` s (stats only) and
  restarts the sleep-phase HR mean (`_sleepMinuteHrSum/_sleepMinuteHrCount`).

### Wake episodes and smart wake

- Wake (outside the smart window): `minuteActiveSec >= 10` or
  `minuteMotionMean > 100 mg`, or minute-mean HR >= 10 BPM above the sleep-phase
  mean for 2 consecutive minutes. -> MONITORING, `_wakeEpisodes++`, countdown
  continues, sleep segment closed (`_actualSleepSec` is real seconds).
- Smart wake: effective nap (`_napEndSec - _sleepStartSec`, shorter than
  napDuration when the deadline cap applied) >= 15 min, window = `min(300,
  effectiveNap / 5)` seconds before `_napEndSec`. Inside it a restless minute
  (`minuteActiveSec >= 6`, i.e. more than a still minute tolerates, or mean >=
  1.5 x threshold), a >= 5 BPM rise, or any full wake signal fires
  `ALARM_SMART_WAKE`.

### Stay Awake mode (`napDuration` 0, `_stayAwake`, frozen per session)

- Chosen on the watch only: DOWN below 5 min on the start screen. Never stored
  (`startNap` persists only nap durations); `start(napMin)` takes the value.
- No deadline, no timed alarm (`checkAlarmDue` returns), never SLEEPING.
- Onset rules as for a nap (2 still + HR drop, or 5 still), but the HR drop is
  against `rollingHrReference()`: mean of `_hrHistory` minus its last 3 minutes
  (up to 10 older minute means, needs >= 5), else the calibration baseline.
- At `_stillMinutes == 3` without onset: one `AlarmManager.nudge()` (one ring
  of the ramp's 30 % step + backlight), screen "Stay alert! Move a bit" (`isDozeWarning()`).
  Answering it ends the still run at once (`noteUserAwake()`: stillness 0,
  clean minute): 3+ active seconds during the warning (the nudge's own buzz
  is at most 2), or any UP/DOWN/START/BACK press in Stay Awake (delegate).
  Hiding the app during a doze alarm also sets the "Keep app open" warning.
- Onset -> `ALARM_DOZE`, `_dozeCount++`, alarm starts at the ramp's 60 % step
  (`AlarmManager.startDozeAlarm()`, step 5 = 63 %).
  `dismissAlarm()` -> `resumeGuard()`: MONITORING, clean minute, stillness 0,
  `_hrWindow` cleared, history kept. START x2 while guarding -> summary;
  BACK x2 -> start screen; BACK x2 on the doze alarm -> back on guard (the
  first press of either pair only shows its popup, and counts as being awake).
- Summary: session length (`getSessionSec`), dozes caught.

### Trace log (debug builds only)

`trace()` prints `PN,<s since start>,m,<state>,<hr>,<motion x100>,<active>,<still>,<baseline>`
(motion in centi-mg, -1 for a minute without accelerometer data)
each minute plus events (start, onset, wake, reentry, alarm,<reason>, nudge,
resume, cancel). On the watch it lands in `GARMIN/APPS/LOGS/PowerNap.TXT` if
that file exists. Never in unit tests (frozen clock) or release builds. Rows
`[hr, motion x10, active]` replay with `testReplayMinute` (see TraceTest.mc).

### Summary statistics

- `getPlannedCompletionPct()` = (end - sleepStart) / configured nap (ring; 100 %
  when the whole nap fitted before the deadline, lower after a cancel, a smart
  wake, or a late onset capped by the deadline). `getSleepEfficiencyPct()` =
  actual sleep / (end - sleepStart).
- The label is derived from `getWakeEpisodes()` and `isCancelled()`, never from a
  threshold on a ratio.

## AlarmManager  - ramp table (v1.1.0)

One `const RAMP` (rows `[pct, pulseMs, pulses, gapMs, intervalMs, rings]`,
columns `R_*`); the last row is the persistent phase (rings 0 = unbounded):

| step | % | pulse | pulses | gap | wait after ring | rings | first ring at |
|---|---|---|---|---|---|---|---|
| 0 | 22 | 120 | 2 | 400 | 10 s | 2 | 0 s |
| 1 | 28 | 140 | 2 | 380 | 9 s | 2 | 20 s |
| 2 | 35 | 160 | 2 | 350 | 8 s | 2 | 38 s |
| 3 | 43 | 180 | 3 | 320 | 8 s | 2 | 54 s |
| 4 | 52 | 210 | 3 | 300 | 7 s | 2 | 70 s |
| 5 | 63 | 240 | 3 | 260 | 6 s | 2 | 84 s |
| 6 | 78 | 280 | 3 | 200 | 6 s | 2 | 96 s |
| 7 | 92 | 320 | 3 | 160 | 5 s | 2 | 108 s |
| 8 | 100 | 350 | 3 | 150 | 5 s | 36 | 118 s (3 min at full) |
| 9 | 100 | 350 | 3 | 150 | 30 s | inf | 298 s (persistent) |

The wait AFTER ring k is the interval of ring k's step (`onRepeatAlarm`
restarts the timer when it changes; `startAlarmFromStep(s)` fires the first
ring of s and starts the timer with s's interval). `stepOfRing`,
`firstRingOfStep`, `firstStepAtLeast(pct)`, `pctOfStep`, `displayPhase(pct)`
(0 < 40 %, 1 < 65 %, 2 < 100 %, 3 = 100 %). Derived thresholds, never magic
ring numbers: `TONE_FROM_PCT` 40 ("Both": melody joins at step 3),
`BACKLIGHT_FROM_PCT` 50 (step 4 = ring 8: first two bright rings, then every
6th, `_brightRings`), `DOZE_START_PCT` 60 (`startDozeAlarm()` = step 5, 63 %;
the detector calls it for `ALARM_DOZE`), `NUDGE_PCT` 30 (`nudge()` = one ring
of step 2). `getCurrentPhase()` = display phase of the next ring,
`getLastRingPhase()` = of the ring just felt (0 before the first),
`isFullIntensity()` = the last ring was 100 %. Owner constraints, tested in
`testAlarm_rampIsGentleAndMonotonic` / `fullReachedWithinTwoMinutes`: >= 8
steps below full, first step <= 25 % and pulse >= 120 ms, intensity / pulse
/ pulses non-decreasing, wait non-increasing, full at 100-130 s (118), then
3 min at full 5 s apart, then 30 s persistent. `getVibePattern(step)` builds
`pulses` pulses with `gap` pauses (<= 8 profiles). Tune the table only inside
these constraints; the "Test alarm" preview (W6) plays every step once.

Tones: `Attention has :ToneProfile` -> a melody per step (`getToneProfile`):
a low two-note "cuckoo" (587/494 Hz), then chirps that gain notes (up to 8),
top pitch (up to 4186 Hz; the piezo gets louder toward 2-4 kHz) and length
(280 -> 970 ms) every step; the persistent step repeats step 8's trill
(`testAlarm_toneMelodiesEscalate`). No volume API. Else the built-in
ALERT_LO (phase 0-1) / ALERT_HI (2) / ALARM (3) (`getToneForStep`).
ALARM_BOTH: the melody joins at `TONE_FROM_PCT` while vibration works;
ALARM_TONE plays it from the first ring. Default `alarmType` is 2 (Vibration
+ nature sound) since v1.1.0; users who saved a choice keep it. `ToneClock`
(module, one speaker) skips starting a melody while the previous one still
plays; that ring counts as toned. Overlapping melodies crash the SDK 9.1
simulator (40 back-to-back did).
`nudge()`: one ring of the 30 % step + backlight, ignored while alarming and
refused unless `setStayAwake(true)` (quiet onset gate, see above).

**Channel fallback:** the alarm type is a preference. If the chosen channel is
unsupported (vívoactive 5/6 have no `Attention.playTone`), switched off
(`DeviceSettings.vibrateOn/tonesOn`) or throws, the other channel is used; an
unknown alarmType vibrates.

**AMOLED rule (do not regress):** in `fireAlarm()` the vibration and tone run
first, each in its own try block; `Attention.backlight(true)` runs last, in its
own try block, and only from the 50 % step (`BACKLIGHT_FROM_PCT`): on the first
two rings at or above it and then every 6th (`_brightRings`). The 52 % step
(display phase 1, "ALARM 2/4", calm screen) is the first with the backlight:
the plan's thresholds (backlight >= 50 %, phase 2 from 65 %) are deliberate.
Repeat timer: one `Timer.Timer` reused across restarts; if it cannot start,
`onSecond()` (called from `SleepDetector.onTick` in STATE_ALARM) rings when
the wait after the last ring has passed (`testAlarm_tickFallbackRingsWithoutTimer`). Burn-in protected displays throw
`BacklightOnTooLongException` after ~1 minute held on; calling backlight before
vibrate in a shared try block silenced the alarm exactly when it reached the
perceptible phases.

**Gentle visuals (approved 2026-09-19):** steps below 50 % leave the screen
dark (no backlight); a raised wrist sees a calm alarm screen ("Time to wake up",
orange title, grey text, no flashing). The view flashes (red fill, white on the
1-bit Instinct) and switches to "WAKE UP!" only when
`AlarmManager.isFullIntensity()` (the last ring was at 100 %, ring 16 at 118 s).
The Stay Awake doze alarm (from the 63 % step) is loud from the start but
flashes only at full strength too.

## Input Design Decisions

Key model (owner decision 2026-09-19 evening, revised the same night after
the wrist test, and again on 2026-09-20; replaces D1 of the v1.1.0 plan):
BACK is a normal back button. It goes back one level, down to the start
screen; only there does it leave the app, with the popup "Press BACK again
to exit". Wherever the step back would END something it takes two presses
in the same 4 s window, after a popup naming what would be lost; where
nothing is lost, one press is enough. Implemented in
`PowerNapDelegate.handleKey` (`goBack`, `backHintKind`) and `handleSwipe`:

| Screen | BACK | START | UP / DOWN | Taps, swipes |
|---|---|---|---|---|
| Start | x2 within 4 s -> `exitApp()`; 1st -> popup `HINT_EXIT` "Press BACK again to exit" | start nap | +/-5 min | zones as below; right swipe = BACK |
| Menu (Test alarm), preview | closes / ends it -> start screen (1 press) | select / nothing | nothing | right swipe = BACK |
| Calibrating (nap or Stay Awake) | 1 press -> `goBack`: `resetToStart()` + lock (no summary, no popup) | x2 -> `stopNap()`; 1st -> peek card | peek card | ignored |
| Nap running (monitoring, sleeping), peek card | x2 -> `goBack`: `resetToStart()` + lock (nap ended, no summary); 1st -> popup "Press BACK again to end nap" | x2 -> `stopNap()` (cancel -> summary, also before any sleep); 1st -> peek card, footer "START again: stop + stats" | peek card | ignored |
| Stay Awake guard, its peek | x2 -> start screen (session ended, no summary); 1st -> popup "Press BACK again to end session" | x2 -> summary | peek card | ignored |
| Alarm ringing (nap) | x2 -> alarm off, start screen (no summary); 1st -> popup "Press BACK again to stop alarm" | x2 -> alarm off, summary; 1st -> `HINT_STOP` | consumed, nothing | ignored |
| Doze alarm (Stay Awake) | x2 -> alarm off, back on guard (`dismissAlarm`); 1st -> "...to stop alarm" | x2 -> alarm off, back on guard | consumed | ignored |
| Summary | start screen (`resetToStart` + lock, 1 press) | start screen (new nap, same) | nothing | right swipe = BACK |

The first press of a pair does nothing but show the popup: it does not end
the nap, and on the alarm it neither stops nor pauses nor quietens the
ringing - the ramp goes on climbing while the popup is up
(`testDelegate_backOnAlarmGoesToStart` asserts the ring phase is unchanged).
The three texts live in `resources/strings/strings.xml`
(`Rez.Strings.BackAgain*`, four length variants each, loaded once by
`PowerNapView.backHintTexts(BACK_HINT_NAP|ALARM|SESSION)`), not in the view -
unlike the older `HINT_EXIT`/`HINT_STOP` consts, which stay where they are.
`testLayout_backHintBanner` fits each of them on every screen it can appear
on, on the device the suite runs on; the 176 px Instinct falls back to
"BACK x2: end" / "BACK x2: stop".

So from the nap alarm the way out is BACK x2 (start screen), BACK x2 (exit);
from the doze alarm BACK x2 (guard), BACK x2 (start), BACK x2 (exit)
(`testDelegate_backWalksBackToStartThenExits`). The 1.5 s lock after every
BACK that changes the screen means a burst of BACK presses during a nap
ends on the start screen and does not run straight on into the exit pair
(`testDelegate_lockDoesNotTrapRepeatedPresses`: BACK every 700 ms from the
alarm leaves at the 6th press - arm, stop, two swallowed by the lock, arm,
exit). A first version with BACK x2 at every level (commit 44fe39e) was
rejected on the wrist because it also asked twice where nothing was at
stake; the pair now exists exactly where something would be lost. The start
screen shows the exit banner (`solveStartScreen` sets it; arrows are drawn
before the lines so the banner covers them) and, having no 1 Hz refresh,
schedules a redraw when the hint expires (`showHint` reuses the one-shot
`_uiTimer`); the session screens redraw every second anyway. The start
screen's footer stays the start hint (it is a tap zone). A right swipe
outside a session (start screen, summary, preview) is handled as KEY_ESC
(`handleSwipe`), so the system back gesture can never leave the app in one
swipe; during a nap AND during its alarm every swipe is consumed and does
nothing, not even arm the pair, which is the one exception to "a right swipe
is BACK". Opening the menu or the preview forgets an armed BACK
(`cancelConfirm`).

- `PowerNapDelegate` extends `WatchUi.InputDelegate` (NOT `BehaviorDelegate`):
  on Fenix 8 `BehaviorDelegate` swallows tap coordinates needed for the start
  screen touch zones. The zones come from the solved start layout: above the
  number = +5 min, number and label = start, below the label = −5 min, and the
  footer hint ("TAP to start" with `isTouchScreen`, else "START to begin";
  both from `resources/strings/strings.xml`, `Rez.Strings.StartHint*`) =
  start again, so tapping the word "TAP" never shortens the nap.
- `ConfirmPress` (owned by the view, window 4000 ms, `System.getTimer()` ms,
  elapsed-based so the 24.8-day timer wrap cannot leave it armed) has contexts
  `CONTEXT_EXIT` (BACK on the start screen only) and `CONTEXT_STOP` (START
  during a session): a press of the other key re-arms for its own context,
  so a BACK and a START never form a pair, in either direction (a BACK
  during a session goes through the same guard, in `CONTEXT_EXIT`, so a
  START in between re-arms for the stop pair and vice versa; `resetToStart`
  forgets an armed press). The armed press is bound to its screen
  (`screenId()`: the detector state, or `SCREEN_START`), so a pair started
  on the nap screen cannot be completed on the alarm.
  `view.pressConfirm(context)` returns true on the confirming press. Taps,
  swipes, holds, flicks and drags are consumed on every nap screen including
  the alarm (an unhandled right swipe is the system back gesture and would
  close the app). In Stay Awake every press also calls `noteUserAwake()`.
- Popup hint: `view.showHint(HINT_EXIT)` after a first BACK on the start
  screen, `showHint(HINT_STOP)` after a first START on the alarm,
  `showHint(backHintTexts(kind))` after a first BACK on a session screen;
  `isHintShowing()`
  while that press is armed on its screen. Drawn by
  `ScreenLayout.setBanner(texts, fonts)` / `solveBanner`: a filled rounded box
  centred on the screen (the screen's negative: white box + black text, or
  black + white while the alarm flashes; 1-bit safe), the longest variant at
  the largest of FONT_MEDIUM/SMALL/TINY/XTINY whose box fits the visible
  width at its rows (`boundsAtRows`, round chord, octagon, lens). Variants:
  `HINT_EXIT` `["Press BACK again to exit", "BACK again to exit", "BACK again: exit"]`,
  `HINT_STOP` `["Press START again to stop", "START again to stop", "START again: stop"]`,
  and from the resources `BackAgainNap` / `BackAgainAlarm` / `BackAgainSession`
  ("Press BACK again to end nap / to stop alarm / to end session") with
  their Short, Tiny and Tiniest variants down to "BACK x2: end" / "BACK x2:
  stop", which is what the 176 px Instinct shows. The armed alarm footer
  repeats the stop hint in red; the BACK popups are carried by the banner
  alone, over a footer that already says both pairs. A first START belongs
  to the screen it was made on (`_armedState`): if the alarm starts inside
  the 4 s window, the press on the alarm screen arms again instead of confirming
  (review finding: one press silenced the alarm;
  `testDelegate_pressBeforeAlarmDoesNotPairWithAlarmPress`). `WatchUi.showToast` (API 3.4.0) is
  NOT used: its look and timing differ per device and LayoutTest could not
  check it. `allTextFits()` / `firstMisfit()` include the banner.
- Unarmed footers (`setNapFooter`): nap, Stay Awake and peek
  `["BACK x2: end, START x2: stats", "BACK x2 end, START x2 stats", "BACK x2: end"]`,
  both alarms `["BACK x2 or START x2: stop", "BACK x2: stop"]`
  (still short: a 31-glyph "BACK x2: stop, START x2: stats" once climbed over
  "ALARM 3/4" on the 260 px fenix7 and failed `testLayout_alarmScreens`, and
  240 px screens pick the short variant of both)
  (ASCII only; on 176-260 px screens the shortest wins and the peek footer
  teaches START x2). They say "x2" because BACK now takes two presses there
  too, and `testLayout_footers` fails a footer that drops it. Armed STOP on the
  nap/peek `["START again: stop + stats", "START again: stop", "Again: stop"]`,
  on the alarm `HINT_STOP` in red;
  summary `["START: new nap", "START: new"]` (`setFooterChoices`; BACK goes
  back to the start screen like START). LayoutTest picks the variant per device.
- Input lock: `INPUT_LOCK_MS` = 1500, applied after every confirmed stop and
  screen change: the alarm or the nap stopped by START x2 or BACK x2, the
  summary's START or BACK, a dismissed doze alarm (`view.lockInput()`, which
  also ends a peek card); never before an exit. While locked
  `handleKey`/`handleTap` swallow everything and NEVER extend the lock (the
  2.5 s lock re-armed by every press trapped the owner on the wrist:
  `testDelegate_lockDoesNotTrapRepeatedPresses`).
- `exitApp()` (only from the start screen): `detector.stop()`, `alarm.stop()`,
  `noteExitRequested()` (`(:debug)`: sets the `(:debug)` field `_exitRequested`
  that `testExitRequested()` reads; a `(:release)` twin does nothing, so the
  release build has neither the field nor an unused-member warning - the same
  idiom as `SleepDetector.trace()`), then `System.exit()` unless
  `testDisableExit()`.
- Start screen: UP/DOWN step 5 and stop at 120 (no wrap); below 5 is Stay Awake
  (0); an odd phone value (7) steps to 5 first. Summary: START or BACK -> start
  screen (`resetToStart`, which also reloads the settings frozen during the
  nap). Alarm dismissal -> `SleepDetector.dismissAlarm` (nap: summary;
  Stay Awake: back on guard).
- A phone settings change on the start screen replaces the pick only when the
  stored napDuration itself changed (`_syncedDuration`), so Stay Awake or an
  unsaved pick survives e.g. an Alarm Type change.
- START remembers the duration in `Application.Storage` (`lastNapMin`, plus
  `lastPhoneNapMin`: the phone's napDuration at that moment), never Stay Awake.
  `initialDuration()` opens the start screen on it (clamped to 5-120), unless
  the phone's napDuration differs from `lastPhoneNapMin` (changed since: the
  setting wins) or nothing is stored yet (first run: the setting). Storage, not
  Properties: `Storage.setValue` writes at once, Properties only when the app
  stops, and `startNap` no longer writes napDuration back to the phone setting.
- The start screen redraws right after every minute change, when the clock and
  the "Alarm by" preview both move (`startUiTimer`/`uiWakeMs`: one reused
  `_uiTimer`, armed into the minute's last second and then every
  `UI_POLL_MS` = 100 ms, because the wall clock has whole seconds only; the
  same timer takes the exit banner off when its 4 s are over).
- Task-switcher devices: `PowerNapApp.onInactive` marks the nap
  (`noteInactive`); the system denies Attention while inactive, so
  `onActive` re-checks the alarm (`SleepDetector.onResume`) and rings
  immediately (`AlarmManager.ringNow`). The nap screens then warn "Keep app open
  for alarm".
- "Test alarm" (v1.1.0, first part of deferred #8): on the start screen
  `WatchUi.KEY_MENU` in `handleKey` (hold UP on 5-button watches, the system
  menu gesture elsewhere) and, on touch screens, `onHold` on the number/label/
  hint zone (`tapActionAt == 0`) call `openMenu()`: a `WatchUi.Menu2` "Power
  Nap" with one item "Test alarm" / "Feel the wake-up ramp" (`:testAlarm`,
  `PowerNapMenuDelegate`, pushed with `pushView`). Selecting it calls
  `view.startPreview()` -> `AlarmManager.startPreview()`: every RAMP step but
  the persistent row once, 3 s apart (`_previewTimer`, `onPreviewTick`), the
  configured alarm type, the same backlight rule, no persistent phase, ends by
  itself after the last step (`getPreviewStep()` 1-based / `getPreviewSteps()`
  / `getPreviewPct()` for the screen). The preview screen (`previewLayout`:
  "ALARM PREVIEW", "Step N of 9", "NN%", "Feel the wake-up ramp", footer "BACK
  to stop") replaces the start screen while `isPreviewing()`; BACK
  (`view.stopPreview()`) or the end returns to the start screen, every other
  key and tap is swallowed meanwhile. Never during a nap (`view.startPreview`
  refuses while `_started`); `startAlarmFromStep` refuses while previewing
  and `startPreview` while alarming; `stop()` ends a preview too; the quiet
  onset gate allows output while `_previewing`. `testDisableExit()` also
  disables `pushView` (`testMenuRequests()` counts menu requests). NOT
  verified from the CLI: that `KEY_MENU` reaches `InputDelegate.onKey` on
  every device (the simulator cannot be driven headless); the long press
  covers touch devices either way.

## Screens and layout

Each screen (the start screen too: its arrows are `addSpacer` slots) is a
list of `LayoutLine`s with a priority (`ScreenLayout.KEEP` = never dropped,
`ScreenLayout.IMPORTANT` = 90). `addWarnings()` shows "Low battery N%" (below
10 %, not charging); priority 97 on start and Stay Awake, 94 on monitoring
(below "Alarm by" 96). On the 176 px Instinct the start screen has room for
one line under the duration: a warning wins over "Alarm by" there.
DND fact (owner's wrist test 2026-09-19, fēnix 8 Pro): `Attention.vibrate`
works with Do Not Disturb on, so there is no DND warning any more (v1.1.0
removed it; keep every try/catch around `Attention` calls, the 1.0.2 crash fix).
Live screens (monitoring, sleeping, alarm, Stay Awake, peek) start with the time
of day (priority 92); on the Instinct it is drawn in the subscreen lens instead. The start screen
shows it too (owner request of 2026-09-19: "Alarm by HH:MM" reads against
it), but NOT as a line of the block: on the 454 px fenix 8 the band's slack
is 26 px and a clock line needs 47, so the engine dropped it (a priority
above IMPORTANT would have shrunk the number instead). `drawStartScreen`
draws it at FONT_XTINY in the margin above the block (`startClockBox`:
centred in the room above the first line, only if the WIDEST time of day
this watch can show fits the chord there, `ScreenLayout.visibleInkBounds`),
the round-screen analogue of the Instinct lens, which shows the clock
instead of "NAP" on the start screen now. **The decision is taken on the
widest time, never on the current one** (`widestClockWidth`: the widest
minute beside the widest hour in the watch's own 12/24 h format, measured
once per format and kept): "12:30" is a glyph wider than "3:32", and on a
240 px screen with the low-battery warning that glyph is the whole
difference, so deciding per draw would show the clock at 9:59 and take it
away at 10:00 while someone was looking at it. The box is centred on the
same point either way, so the time is drawn exactly where it was.
`testLayout_clockOnStartScreen`: the box is the SAME box at the narrowest
and at the widest time of day (or absent at both), on every duration and
both battery states; it is present on every non-lens device, and with the
low-battery warning from 260 px, on screen, clear of the first line, inside
the chord; the promise stays and the number keeps its size. Below 260 px
the warning takes the clock's room - stably, now - which is the right way
round: a watch that dies mid-nap never rings at all. The test reads neither
the battery nor the wall clock from the simulator: it forces one and pins
the other. The wording "Latest
alarm" was replaced by "Alarm by" (the owner: "latest" reads as "most
recent", and the 26-minute gap to a 10-minute nap looked wrong without the
clock); the short variant stays "By HH:MM".
The summary shows "Fell asleep in N min" (`getFallAsleepSec`, priority 86);
without the ring (Instinct) the title carries the completion % ("DONE 100%",
down to just "100%" next to the lens).
`ScreenLayout.solve()` computes `_bandTop`, solves the footer once:
`setFooterTexts` (hints whose wording matters: longest variant that fits,
moving up at most to 72 % of the height) or `setFooterChoices` (summary:
"START: new nap, BACK: exit" / "START: new nap" / "START: new", bottom row
first, else the shortest moved up); never higher, so wide fonts (CJK) cannot
collapse the band. Then `chooseFooterForContent` (round screens only, not
next to the lens): a drop simulation (`dropCount`: protected lines of
priority >= 70 plus dividers at full fonts, dropped lowest priority first as
the height pass would) picks the longest footer variant whose band drops as
few protected lines as the shortest one would; titles (50-60) may still go
for the full wording. So a long hint never drops an informative line
(`testLayout_footerNeverStealsContent`: the Stay Awake screen after a doze on
390-416 px watches lost "Awake h:mm:ss" to the long footer). Then the banner
(`solveBanner`: one text measurement per text/font, counted in `_fitCalls`;
next to the lens the lowest position is tried first and only a text that
fits there is probed from the centre down). Then per pass: drop lines below IMPORTANT, shrink fonts,
drop IMPORTANT lines (fonts restart at full size after each), hide dividers
whose title is hidden (`linkedTo`), place the block centred; on the Instinct
(`_hasSub`), when a line misfits or had to use a shorter text variant, probe
lower block positions (4 px steps, `probeAt`/`probeLine`: fit checks that store
nothing) and run the full `placeAndFit` only at the chosen position. A KEEP
line too wide for its row hides the lowest optional line and freezes the
height-dropped ones (else they refill the space and the block never shrinks).
At the end `restoreHidden()` brings back hidden lines highest priority first,
hiding lower-priority lines to make room if needed; a failed last retry
restores the accepted state from `snapshot()` instead of re-solving. Dividers
are clipped to their row. `inkBounds()` results are cached per `solve()`
(`_inkCache`, key `y * 1024 + fontHeight`). Status lines carry short variants
("Calibrating", "In mm:ss", "Smart", "Buzz if doze") so the Instinct does not
drop a line for a few pixels. `testWork()` reports [passes, fitLine calls];
LayoutTest fails any screen over 6 passes / 60 fits (Instinct worst case 1/12,
round screens 1/6), because every screen redraws at 1 Hz and the Instinct
watchdog is 240k bytecodes per event (the test runner disables the watchdog).
Measured on 2026-09-19 with a bytecode-level replay of every screen state: the
worst Instinct frame is 87k (Chinese/Japanese fonts, 2.8x margin), 23k in
English; fr255s (120k limit) 21k, fenix847mm 24k. Re-measure after adding
lines or text variants to the Instinct screens.
Known limit: on the Instinct with a CJK font set, the monitoring screen before
sleep hides "Alarm by" (the wide glyphs leave no row for it); every
visible line still fits.
The alarm screen's "ALARM x/4" uses `getLastRingPhase()` (the ring just felt),
like the calm/loud style; `getCurrentPhase()` is the next ring's phase.
After a wake episode the monitoring screen drops "Alarm N min after sleep"
(the alarm time is fixed then). Each line gets the largest font/text variant that
fits the round chord (or the Instinct subscreen) at its own rows.
`ScreenLayout.testDescribe()` (debug) prints every line's visibility and position. `LayoutTest.mc` checks
every nap-screen state on the device it runs on; run it on 176-454 px devices after
any UI change. `Palette.fg()` maps every colour to white on the 1-bit Instinct 3
Solar (detected by its semi-octagon screen shape).
Colours come from `Palette`, never spelled out in a view: `TEXT_PRIMARY` /
`TEXT_SECONDARY` / `TEXT_TERTIARY` (what the screen is about / the words
around it / the hints) and `ACCENT` with `ACCENT_DIM` for the start screen's
arrows. The values are ones an 8-bit MIP screen holds exactly (each channel
0x00/0x55/0xAA/0xFF), and on the Instinct all of them fold onto white, so the
hierarchy there is the font sizes alone and no shade may be added for it.
A line may carry a second colour for the part after its last inner space
(`LayoutLine.tailColor`, split by `ScreenLayout.tailStart`): "Alarm by
**HH:MM**" is the only one, drawn the same way on the start screen and on the
nap screen. It is still measured, fitted and centred as one text.

## Testing

**Framework:** `Toybox.Test` (`:test` annotation), files under `test/`, one per area.
Test names are global, so each file uses its own prefix (`testOnset_`, `testWake_`,
`testTiming_`, `testAlarm_`, `testSummary_`, `testReg_`, `testLayout_`, `testStay_`,
`testDelegate_`, `testQuiet_`, `testMotion_`, `testInv_`, `testTrace_`,
`testStart_`). Alarm tests derive tone
expectations from `Attention has :playTone` (vívoactive 5/6 have none) and must
not build melodies without `Attention has :ToneProfile` (Symbol Not Found there).

**Delegate tests:** `DelegateRig` wires the real delegate/view/detector;
`detector.testUseFakeRuntime()` makes `start()` open a frozen-clock session
without sensors or timers (and `loadSettings` a no-op), `delegate.testDisableExit()`
keeps BACK from calling `System.exit()` (`testExitRequested()` tells whether
it would have); `cleanup()` stops the alarm and the view's UI timer and
restores `napDuration` and the two Storage keys of the remembered duration. After a confirmed stop, call
`view.testExpireInputLock()` before the next deliberate press, or
`view.testAdvanceMs()` to move the confirm window / lock / hint clock.

**Invariant tests:** `InvRng` (seeded LCG) + `InvChecker` (checked after every
simulated second). Keep each test function to ~6 random naps: all tests run in
one app, and the simulator's watchdog/runtime is the limit.

**Driving time in tests:** `testStart()` begins a session with the documented
default settings (independent of the simulator's stored properties), a clock
frozen on a whole minute (so the cap lies exactly one minute after
start + allowance + nap; `testPinClock(sec)` pins another second and keeps it
across `start()`), and no sensors or timers (`testStartKeepSettings()` keeps
loaded settings);
`testFeedSecond(hr, motion)` / `testRunMinutes(n, hr, motion)` simulate sensor
input second by second and advance the fake clock; `testAdvanceClock`,
`testSetBaseline`, `testForceSleep` shortcut the setup. Because the clock is
frozen, assert exact values. All helpers are `(:debug)` and excluded from
release builds.

**What to run and when** - the per-PR pair (strict build on every product plus
the suite on the protocol set), the screenshots a text/colour/layout PR needs,
the pre-release sweep, the store package, and why `--permissive` is a
diagnostic only: `CONTRIBUTING.md`. The device list always comes from
`manifest.xml` through `tools/matrix.sh list`; `tools/runtests.sh <device> ...`
stays for ad-hoc runs on one or two devices.

**Layout work budget:** the bytecode-replay watchdog harness that measured the
87k worst Instinct frame on the pre-1.1.0 code cannot run the 1.1.0 code:
its interpreter does not model class-level const arrays (`AlarmManager.RAMP`, `PowerNapView.HINT_*`),
so the proxy is LayoutTest's work budget (worst Instinct 1 pass / 13 fits,
round screens 1/6).

## Privacy

The app reads HR and accelerometer data from `Toybox.Sensor` callbacks. All
processing is in-memory; no data is written to device storage, no health records
are saved via `FitContributor`, and no data leaves the watch. Only the nap
duration is persisted: the `napDuration` preference via `Application.Properties`
(set from the phone) and the last duration started on the watch via
`Application.Storage` (`lastNapMin`, `lastPhoneNapMin`).

Connect IQ store submission requires a privacy policy URL when the app uses health
sensor data. Provide this in the store submission form, not in the manifest.
