> **Historical document - do not follow it.**
>
> v1.1.0 shipped on 2026-09-19. This brief records the intent of that day, not
> the state of the project. **`CLAUDE.md` takes precedence over everything
> below**, and `CONTRIBUTING.md` holds the procedure. Known to be out of date
> here:
>
> - the "read this first, it overrides `CLAUDE.md`" ground rule in section 0
>   (reversed: `CLAUDE.md` is the source of truth);
> - the key model: BACK x2 on every screen was tried and rejected on the wrist;
>   BACK is a single-press back button and only the start screen's BACK x2
>   exits;
> - the wording "Latest alarm", replaced by "Alarm by HH:MM";
> - `tools/devices.txt` as the release matrix: that file is gone, and the
>   supported devices are read from `manifest.xml` through `tools/matrix.sh`;
> - the instruction to work on `feature/stay-awake-gentle-wake`: that branch
>   was merged and the project works one branch per PR (`CONTRIBUTING.md`).

# Power Nap v1.1.0 — implementation brief for the next agent

Written 2026-09-19 after the owner's first real-watch test of the current
branch (fēnix 8 Pro 47 mm AMOLED). Everything below was checked against the
code as it is today (line numbers are from this state). You are the agent that
implements it. Work through the items in order; each one ends with tests
passing and a commit.

## 0. Ground rules (read before touching anything)

1. Read `CLAUDE.md` in full first. It is the project's source of truth
   (local file, gitignored). This brief overrides it where they conflict, and
   you update `CLAUDE.md` and `README.md` as you go, not at the end.
2. Git: work on the current branch `feature/stay-awake-gentle-wake`. Never
   commit to `main`, never push, never rebase or amend published history. The
   owner merges and pushes.
   - The working tree starts with UNCOMMITTED audit fixes (see `git status`:
     `source/*`, `test/*`, `README.md`, `monkey.jungle`, new `resources-launcher/`,
     `tools/`, this file). Step 0 = add `.DS_Store` to `.gitignore`, then commit
     all of it as:
     `Fix audit findings: quiet HR/onset math, Instinct layout engine, icons`
     (body: 14 confirmed audit findings fixed, 200 tests, 43/43 devices pass,
     layout engine rework with inkBounds cache / probeAt / snapshot, native
     launcher icons, layout work budget 6/60).
3. Product rules the owner has approved and that you do not change without
   asking (ask by stopping and stating the question; do not guess):
   - Alarm never later than "Latest alarm" = start + fallAsleepAllowance
     (default 15 min) + nap. Late onset shortens the nap (hard cap).
   - Onset: 2 still minutes with an HR drop (default 5 BPM), or 5 still
     minutes. Wake, re-entry, smart-wake rules as in `CLAUDE.md`.
   - Two presses within 4 s for anything that stops a nap or the alarm; taps
     and swipes ignored while napping. (The key model changes in W4, the
     two-press protection stays.)
   - Stay Awake mode thresholds (nudge at 3 still minutes, doze alarm on
     onset).
   - AMOLED backlight rule in `AlarmManager.fireAlarm()` (vibration and tone
     first, each in its own try block; backlight last, own try block, sparse).
4. Quality bar, non-negotiable: every behaviour change ships with tests; the
   suite must pass on all 43 devices in `tools/devices.txt`
   (`tools/runtests.sh`), release builds (`-r -l 3`) must compile without
   warnings on `fenix847mm`, `instinct3solar45mm`, `vivoactive5`, `fr255s`,
   and no text may be truncated on any screen (LayoutTest is the judge; the
   layout work budget of 6 passes / 60 fits per screen stays).
   Baseline today: 200 tests, 43/43 devices PASSED, worst layout work
   Instinct 1/12.
5. Monkey C gotchas that cost time before: strict typing (`-l 3`); `hidden`
   is a reserved word; globals need `$.` and do not persist across test
   functions; Number arithmetic wraps at 32 bits; `(:debug)` helpers are
   excluded from `-r` builds; `logger.debug` needs a String (`"" + x`);
   overlapping `ToneProfile` melodies crash the SDK 9.1 simulator (keep the
   `ToneClock` guard); `Attention has :ToneProfile` is false on vívoactive
   5/6 (guard melody tests); in zsh never `echo =====` (use bash or quotes).
6. The owner cannot feel or hear the simulator. Anything about vibration
   strength or melody must be data-driven, previewable on the watch (W6) and
   described in the final report so the owner can tune it.
7. Final report to the owner in Romanian; code, comments, docs and commit
   messages in English.

## 1. What the owner found on the watch, and the root causes

| # | Owner's report | Root cause in today's code | Work item |
|---|---|---|---|
| 1 | The alarm vibrates with DND on and with DND off | Good news: DND does not mute `Attention.vibrate`. The warning "DND on: alarm may be silent" is wrong. | W5 |
| 2 | "The crescendo does not exist any more; the first vibrations must be very, very fine, almost imperceptible, then grow" | The vibration table (`AlarmManager.mc:397-430`: 15 %×80 ms ×2, 30 %×120 ms ×3, 65 %×200 ms ×3, 100 %×300 ms ×3, intervals 9/7/6/5 s, 4 rings per phase, full at 84 s) is byte-for-byte the one from the first commit `53b8b76`. What changed in `b565b72` is the screen: no backlight in phases 0-1. On the fēnix 8 Pro motor 15 % and 30 % pulses of 80-120 ms are below the perceptual threshold, and now there is no visual cue either, so the first thing the owner notices is phase 2 (65 %): the photo shows "ALARM 2/4" with the calm "Time to wake up". Perceived: nothing, then a firm buzz. | W2, W6 |
| 3 | "When sleep was detected the watch vibrated (DND off). Remove any vibration at sleep detection, add a test that always runs, non-negotiable" | Verified: the only `Attention` calls in the app are in `AlarmManager` (`deliver()` ← `fireAlarm()` ← `startAlarmFromPhase()` / `onRepeatAlarm()` / `ringNow()`, and `nudge()`), and `nudge()` is called only from `SleepDetector.handleMonitoring()` under `_stayAwake`. `enterSleep()` (`SleepDetector.mc:665`) calls nothing; `checkAlarmDue()` runs before `onMinute()` in every tick, so a deadline alarm cannot coincide with an onset. Nap-mode code has no path that vibrates at onset. The rule still has to be enforced structurally and guarded by tests for ever, and the owner needs a way to prove where a vibration came from (the debug trace already logs `onset`, `alarm,<reason>` and `nudge` with timestamps). | W1 |
| 4 | "A nature sound should play by default on watches that support it (fēnix 8 Pro does: I chose 'Nature Awaits' for my normal alarms)" | Connect IQ cannot play the watch's built-in alarm sounds or audio files from a watch app: `Toybox.Attention` (SDK 9.1 docs) has only `vibrate`, `playTone(Tone or {:toneProfile})`, `backlight` and the flashlight functions. The "nature sound" can only be a synthesized note sequence (`getToneProfile`, `AlarmManager.mc:435-475`, already bird-like), and today it is off by default (`alarmType` 0 = vibration only). | W3 |
| 5 | "To exit during or after the nap I must be able to press BACK twice and the app closes. Now I press many times, very unintuitive. Possibly a popup 'press BACK to exit'" | `PowerNapDelegate.handleKey()` (`PowerNapDelegate.mc:117-121`): while the input lock is active every press re-arms it (`_view.lockInput()`, 2500 ms, `PowerNapView.mc:48`). After the alarm is stopped (2 presses) the summary appears under that lock; a user who keeps pressing BACK more often than every 2.5 s is trapped indefinitely. On top of that the flow needs 3 presses (2 to stop, 1 to exit). | W4 |

Deferred items the owner approved earlier and that this release touches:
"#8 on-watch settings + Test alarm" (W6 delivers the Test alarm part), "#10
mention the fēnix hot key in the store description" (Appendix A does it).

## 2. Work items

### W1 — Quiet onset rule: nothing ever vibrates, sounds or lights up at sleep detection

Goal: make it impossible, and prove it every run.

1. `AlarmManager`: add a structural gate. `deliver()` and `requestBacklight()`
   may run only while `_isAlarming` is true, or from `nudge()`; `nudge()` may
   run only when the manager was told this session is Stay Awake
   (`setStayAwake(flag)` called by `SleepDetector.start()` / `testStart*`,
   cleared by `stop()`). Any other call is a no-op and, in debug builds,
   increments `_blockedDeliveries` (hook `testGetBlockedDeliveries()`).
2. Debug trace: `SleepDetector.trace()` already logs `onset`, `reentry`,
   `alarm,<reason>`, `nudge` with seconds since start. Add nothing else, but
   document in `README.md` (Trace replays section) how to prove the app was
   silent: an `onset` line without an `alarm`/`nudge` line at the same time
   means the app did not ring.
3. New test file `test/QuietOnsetTest.mc` (prefix `testQuiet_`), all with the
   REAL `AlarmManager` (each of alarm types 0/1/2, use
   `testForceChannelsUnavailable` only to mirror vívoactive), asserting after
   EVERY simulated second until the alarm is actually due that
   `testGetVibrateCount()`, `testGetToneCount()`, `testGetMelodiesStarted()`,
   `testGetBacklightCount()`, `testGetNudgeCount()` are all 0 and
   `isAlarming()` is false:
   - `hrDropOnsetIsSilent`: 2 still minutes + 5 BPM drop, nap 30.
   - `stillOnsetIsSilent`: 5 still minutes, no HR.
   - `wakeAndReentryAreSilent`: onset, wake episode, re-entry.
   - `lateOnsetRingsOnlyAtDeadline`: onset in the last minute before the
     deadline (nap capped): counts stay 0 until the deadline second, then the
     alarm starts (reason NAP_COMPLETE) — exactly one first ring.
   - `calibrationAndDropoutsAreSilent`: calibration end, minutes without HR,
     minutes without accelerometer data.
   - `resumeAfterOnsetIsSilent`: `Lifecycle.resume()` right after onset with
     no alarm due → no ring (`AlarmManager.testGetRingsFired() == 0`).
   - `napModeNeverNudges`: 3, 4, 5 still minutes in nap mode: nudge count 0
     (in Stay Awake the nudge at 3 still minutes is expected and already
     tested in StayAwakeTest).
   - `delegateNapIsSilentUntilAlarm`: through `DelegateRig` from START on the
     start screen to STATE_ALARM.
4. `InvariantTest`: add to `InvChecker` the invariant "no delivery counter
   moved while `getState() != STATE_ALARM`" (use the real manager in the rig;
   check how the rig builds it today).
5. `CLAUDE.md`: a "QUIET ONSET RULE (owner, non-negotiable)" paragraph naming
   the gate and the test file. `README.md`: one sentence in "How it works".
6. Report to the owner (final report): the code had no path that vibrates at
   onset; the gate and the tests now guarantee it; if the watch still vibrates
   at onset with 1.1.0, record the nap with a debug build (PowerNap.TXT) — no
   `alarm`/`nudge` line at the onset time means the vibration came from the
   system (typical: abnormal-heart-rate low alert, relax reminder, a phone
   notification, Garmin's own nap detection), which is consistent with it
   happening only with DND off.

### W2 — A crescendo you can feel: finer, longer, data-driven ramp

Goal: the first pulses are barely perceptible but perceptible, and every
step is a small, noticeable increase up to full strength ("as Apple would").

1. Replace the four hard-coded phases with one ramp table in `AlarmManager`
   (a `const RAMP as Array<Array<Number>>`, one row per step:
   `[intensityPct, pulseMs, pulses, gapMs, intervalMs, rings]`). Starting
   values (tune only inside the constraints in 2):

   | step | % | pulse | pulses | gap | interval | rings | first ring at |
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
   | persistent | 100 | 350 | 3 | 150 | 30 s | ∞ | 298 s |

2. Constraints (tested): ≥ 8 steps before full; first step ≤ 25 % and pulse
   ≥ 120 ms (shorter/weaker pulses may not start the motor at all);
   intensity, pulse and pulses non-decreasing step to step; interval
   non-increasing; full (100 %) reached between 100 and 130 s after the first
   ring; then 3 minutes at full 5 s apart; then the persistent 30 s phase
   (unchanged). D3 in section 5 records that the owner accepts ~2 min to full
   instead of 84 s.
3. Derived thresholds, all computed from the table (no magic ring numbers):
   `TONE_FROM_PCT = 40` ("Both": the melody joins at the first step ≥ 40 %),
   `BACKLIGHT_FROM_PCT = 50` (gentle visuals: dark screen below it, then the
   existing sparse schedule), `DOZE_START_PCT = 60` (Stay Awake doze alarm
   starts at the first step ≥ 60 %), `NUDGE_PCT = 30` (nudge uses the first
   step ≥ 30 %). Display phase for "ALARM x/4" and for the calm/loud screen:
   0 below 40 %, 1 below 65 %, 2 below 100 %, 3 at 100 %.
   `getCurrentPhase()`, `getLastRingPhase()`, `isFullIntensity()` keep their
   meaning for the view. `startAlarmFromPhase(p)` becomes
   `startAlarmFromStep(s)` plus a helper `firstStepAtLeast(pct)`.
4. AMOLED rule unchanged (see ground rule 3). `_ringsFired`-based backlight
   schedule unchanged in spirit: first two rings at or above
   `BACKLIGHT_FROM_PCT`, then every 6th.
5. Tests (`AlarmManagerTest`): rewrite the schedule tests to the new times;
   add `testAlarm_rampIsGentleAndMonotonic` (constraints of 2),
   `testAlarm_fullReachedWithinTwoMinutes`, `testAlarm_displayPhasesFollowRamp`,
   `testAlarm_dozeStartsAtSixtyPercent`, `testAlarm_persistentPhaseAfterThreeMinutesAtFull`,
   keep and adapt the backlight regression tests. `LayoutTest` alarm screens:
   texts unchanged ("ALARM 1/4" … "4/4").
6. `CLAUDE.md` "AlarmManager" section and `README.md` step 7 rewritten from
   the table.

### W3 — Nature sound on by default (as far as Connect IQ allows)

1. `resources/properties/properties.xml`: `alarmType` default 0 → 2.
   `resources/strings/strings.xml`: "Vibration only" / "Nature sound only" /
   "Vibration + nature sound (default)". Settings order unchanged (values
   0/1/2). vívoactive 5/6 (no `playTone`) keep vibrating through the existing
   fallback; verify that with the existing channel tests on `vivoactive5`.
2. Melody: keep `getToneProfile` but make it a per-step ladder that starts as
   the quietest thing a beeper or speaker can do (two low, short notes, a
   distant "cuckoo") and grows in note count, pitch and length with the ramp;
   on "Both" it joins at `TONE_FROM_PCT`, on "Nature sound only" it plays
   from the first ring. `ToneClock` overlap guard stays. There is no volume
   API; early stages stay short and low.
3. Tests: adapt melody tests; `testAlarm_bothJoinsMelodyAtFortyPercent`,
   `testAlarm_toneOnlyPlaysFromFirstRing`, guard everything with
   `Attention has :ToneProfile`.
4. Tell the owner plainly in the final report: Garmin's "Nature Awaits" and
   any audio file cannot be played by a Connect IQ watch app; the app's
   nature sound is a synthesized melody, and on the fēnix 8 Pro speaker it is
   still a tone sequence.

### W4 — BACK twice exits; START twice stops with stats; popup hint; lock fix

New key model (D1 in section 5):

| Screen | BACK | START | UP / DOWN | Taps, swipes |
|---|---|---|---|---|
| Start | exit (1 press) | start nap | ±5 min | zones as today |
| Nap running (calibrating, monitoring, sleeping), Stay Awake guard, peek card | ×2 within 4 s → app exits (nap ended, no summary). 1st press → popup "Press BACK again to exit" | ×2 within 4 s → nap stopped, summary shown. 1st press → peek card whose footer says "START again: stop + stats" | peek card (as today) | ignored |
| Alarm ringing (nap) | ×2 → alarm off, app exits. 1st press → popup "Press BACK again to exit" | ×2 → alarm off, summary. 1st press → popup "Press START again to stop" | consumed, nothing | ignored |
| Doze alarm (Stay Awake) | ×2 → exit | ×2 → alarm off, back on guard (as today's dismiss) | consumed | ignored |
| Summary | exit (1 press) | new nap (start screen) | nothing | ignored |

Rules:
1. A BACK press and a START press never combine into a pair: `ConfirmPress`
   gets contexts `CONTEXT_EXIT` (BACK) and `CONTEXT_STOP` (START) replacing
   NAP/ALARM; a press of the other key re-arms for its own context. Window
   stays 4000 ms. In Stay Awake every press still calls `noteUserAwake()`.
2. Input lock: `INPUT_LOCK_MS` 2500 → 1500 and it is NEVER extended by
   presses (delete the `_view.lockInput()` call inside the locked branch of
   `handleKey`/`handleTap`; swallowed presses are just swallowed). Applied
   after: alarm stopped by START×2, nap stopped by START×2, summary START
   (new nap), doze alarm dismissed. Not before an exit.
3. Popup: `PowerNapView.showHint(texts)` draws a banner over the current
   screen for the 4 s confirm window: a filled rounded box centred on the
   screen (colours through `Palette`, inverted on the 1-bit Instinct), text
   in the largest font whose widest variant fits the box, variants
   `["Press BACK again to exit", "BACK again to exit", "BACK again: exit"]` and
   `["Press START again to stop", "START again to stop", "START again: stop"]`.
   The armed footer keeps showing the same message in red (existing
   mechanism). `WatchUi.showToast` (API 3.4.0) is NOT used: its look and
   timing differ per device and LayoutTest cannot check it; say so in
   `CLAUDE.md`.
4. Unarmed footer texts: nap, Stay Awake and alarm screens
   `["BACK x2: exit, START x2: stats", "BACK x2 exit · START x2 stats", "BACK x2 to exit"]`
   (alarm: "…START x2: stop"); summary
   `["START: new nap, BACK: exit", "START: new nap", "START: new"]`.
   LayoutTest picks the variant per device; the KEEP/priority scheme and the
   footer modes (`setFooterTexts` / `setFooterChoices`) are unchanged.
5. `exitApp()` keeps `_exitEnabled` for tests and adds a `(:debug)`
   `testExitRequested()` flag so tests can assert an exit.
6. Tests (`DelegateTest`, replace the old backTwice*/lockExtends tests):
   `backTwiceDuringNapExits`, `startTwiceDuringNapShowsSummary`,
   `backThenStartIsNotAPair`, `backTwiceOnAlarmExits`,
   `startTwiceOnAlarmShowsSummary`, `startTwiceOnDozeAlarmResumesGuard`,
   `backTwiceInStayAwakeExits`, `summaryBackExitsWithOnePress`,
   `summaryStartBeginsNewNap` (keep), `firstBackShowsExitHint` (hint text and
   4 s expiry via `testAdvanceMs`), `peekFooterTeachesStartTwice`,
   `lockDoesNotTrapRepeatedPresses` (from the alarm: BACK every 700 ms → exit
   requested at the 2nd press; START every 700 ms → summary at the 2nd, the
   3rd and 4th swallowed, no new nap before 1.5 s), keep
   `pressBurstAfterAlarmStopsAtSummary` and `backBurstOnDozeAlarmKeepsGuarding`
   adapted (a BACK burst on the doze alarm now exits — rename accordingly and
   make sure that is what the table says). `LayoutTest`: `exitHintBanner`
   (banner fits on every device over every screen it can appear on), armed
   and unarmed footers of every screen with the new texts, peek footer.
7. `README.md` steps 8-10 and "Keep the app open" text, `CLAUDE.md` "Input
   Design Decisions" rewritten from the table above.

### W5 — Remove the DND warning

The owner verified that the alarm vibrates in DND. Remove the "DND on: alarm
may be silent" texts and the combined battery+DND variants
(`PowerNapView.addWarnings`, `dndOn()`, `_forceDnd`, `testForceDnd`), the DND
branches in `LayoutTest` (`monitoringWithDnd`, `lowBatteryWarning`,
`layoutHelperView`/`layoutHelperStartView` set-up) and every DND mention in
`README.md`/`CLAUDE.md`. Keep "Low battery N%" (< 10 %, not charging). Keep
every try/catch around `Attention` calls (the 1.0.2 DND/Sleep-mode crash fix).
Add one line to README's alarm step: "Works with Do Not Disturb on".

### W6 — "Test alarm" preview on the watch (recommended; first part of deferred #8)

Why: the only way to tune W2/W3 is on the wrist without napping.

1. Start screen, MENU key (`WatchUi.KEY_MENU` in `onKey`; hold UP on
   5-button watches, the system menu gesture elsewhere; on touch screens also
   a long press on the number via `onHold`): push a `WatchUi.Menu2` titled
   "Power Nap" with one item "Test alarm" (sub-label "Feel the wake-up ramp").
   Verify in the simulator that `KEY_MENU` reaches `InputDelegate.onKey` on
   `fenix847mm`, `venu3`, `vivoactive5`, `instinct3solar45mm` (simulator menu
   key); if a device does not deliver it, the long press must work there.
2. Selecting it runs `AlarmManager.startPreview()`: the real ramp table, one
   ring per step, fixed 3 s interval, the configured alarm type, the same
   backlight rule, no persistent phase, stops by itself after the last step.
   A preview screen (new view state or a flag on `PowerNapView`) shows
   "Alarm preview", "step N of M", "NN %", footer "BACK to stop"; BACK (one
   press) or the end of the ramp returns to the start screen. Never available
   while a nap runs; `startAlarm()` refuses while a preview runs and vice
   versa.
3. Tests: `testAlarm_previewPlaysEachStepOnce`, `testAlarm_previewNeverEntersPersistentPhase`,
   `testAlarm_previewAndAlarmExclude`, `testDelegate_menuOnlyOnStartScreen`,
   `testDelegate_previewBackReturnsToStart`, LayoutTest for the preview
   screen (every step value, all devices).
4. If W6 endangers the schedule or the stability of the rest, stop after
   W5 + W7, say so in the report, and leave W6 for the next release (D2).

### W7 — Docs, version, package, store texts

1. `README.md` and `CLAUDE.md` fully consistent with W1-W6 (tables, steps,
   test counts, file list including `tools/`). `CLAUDE.md` gets the quiet
   onset rule, the ramp table, the key model table and the DND fact.
2. Version: the manifest carries no version; the store version is entered in
   the upload form. This release is **1.1.0** (the store shows 1.0.2 today).
3. Package for the store: `"$SDK/bin/monkeyc" -e -o bin/PowerNap-1.1.0.iq -f monkey.jungle -y ~/developer_key.der -r -l 3`
   (all manifest devices). Must build without warnings. Report the path.
4. Final report (Romanian) must contain, in this order: what changed per
   work item; test count and the 43-device matrix result (device: Ran N
   PASSED); the release-build check; what the owner must verify on the wrist
   (ramp perceptibility per step, melody, exit flow, no vibration at onset,
   Test alarm) and how to record a trace if anything vibrates at onset; the
   store texts (Appendix A, updated to what was actually built) with exactly
   which field each one goes into: **App Info > Edit details > Description**
   (needed: the current description is outdated: says 3 still minutes,
   2-minute calibration only, "efficiency rating", no Stay Awake, no
   guaranteed alarm) and **Upload New Version**: the `.iq` file, version
   `1.1.0`, and the "What's New" text.

## 3. Verification protocol

1. After each work item: build with `-t -l 3 -w` and run on `fenix847mm`,
   then `instinct3solar45mm`, `fr255s`, `venu3s`, `vivoactive5`
   (`tools/runtests.sh fenix847mm instinct3solar45mm fr255s venu3s vivoactive5`).
2. Before the final commit: `tools/runtests.sh $(cat tools/devices.txt)` →
   43 lines "…: Ran N tests PASSED". The simulator sometimes drops a run;
   the script retries and restarts it. Run it on a frozen copy of the tree
   (copy `source test resources resources-launcher manifest.xml monkey.jungle`
   to a scratch folder and set `PROJ_DIR`) so edits during the run cannot
   contaminate it.
3. Release builds `-r -l 3` on `fenix847mm`, `instinct3solar45mm`,
   `vivoactive5`, `fr255s`: no warnings. Then the `-e` package.
4. Layout: `testLayout_workOfHeaviestScreens` logs the work numbers; the
   6/60 budget must hold on every device. If any Instinct screen gained a
   line or text variant (W4 banner and footers do), state the new worst
   Instinct numbers in the report. The bytecode watchdog harness from the
   previous session may still exist at `/tmp/wdfinal/h` (`an.py`,
   `devsweep.py`; the Instinct limit is 240k bytecodes per redraw, previous
   worst frame 87k); if it is there, re-run it and report the worst frame,
   else say it was not re-measured and why.
5. Adversarial review before the final commit: spawn two independent
   reviewer subagents with the diff and these claims to refute: (a) there is
   a path to `Attention.vibrate/playTone/backlight` while the detector is not
   in STATE_ALARM (nudge in Stay Awake excepted), (b) a sequence of presses
   can leave the user unable to exit within two presses on any nap/alarm
   screen, (c) a text is truncated or a line dropped on the Instinct or a
   218 px round screen, (d) the AMOLED backlight rule regressed, (e) two
   melodies can overlap, (f) a nap can be stopped by a single press. Fix
   what they confirm, re-run the matrix.
6. Commit at milestones: step 0 (audit), W1+W5, W2+W3, W4, W6, W7. Each
   commit message states the behaviour change and the test count. No push.

## 4. Deliverables

- Commits on `feature/stay-awake-gentle-wake` (not pushed).
- `bin/PowerNap-1.1.0.iq`.
- The final report described in W7.4.

## 5. Owner decisions recorded in this brief (defaults apply unless the owner edits them)

- **D1** Key model of W4: BACK×2 exits from every nap/alarm screen (no
  summary), START×2 stops and shows the summary, summary BACK exits with one
  press. Default: yes.
- **D2** W6 "Test alarm" preview is in scope for 1.1.0. Default: yes; may be
  dropped only for stability reasons, stated in the report.
- **D3** The ramp reaches full strength at ~2 minutes (100-130 s) instead of
  84 s, with ≥ 8 perceptible steps. Default: yes.
- **D4** Default alarm type becomes "Vibration + nature sound" for everyone
  (users who saved a choice keep it). Default: yes.

## Appendix A — Store texts (finalize to what was built; keep the tone)

### A1. App Info > Edit details > Description

```
Power Nap Auto-Wake watches you fall asleep and wakes you after exactly the nap you asked for. Choose the minutes of sleep you want, lie down, and the watch does the rest: it detects sleep onset from your heart rate and wrist stillness, starts the countdown only once you are asleep, and wakes you with a slow, gentle crescendo.

HOW IT WORKS
- Set 5 to 120 minutes of sleep on the watch (UP/DOWN or tap), then press START or tap "TAP to begin".
- A 2-minute calibration learns your resting heart rate. Sleep is detected after 2 still minutes with a heart-rate drop, or 5 still minutes without one. Detection itself is silent: nothing vibrates until the alarm.
- The countdown starts when you fall asleep, not when you lie down. Woke up early? Lie still and the nap continues; the alarm time does not move.
- Guaranteed alarm: the screen always shows "Latest alarm HH:MM" (start + time allowed to fall asleep + nap). The alarm never rings later than that, even if sleep is never detected.
- Smart wake (naps of 15 min or more): in the last part of the nap a restless minute or a slight heart-rate rise wakes you a little early, at a natural moment.

GENTLE WAKE-UP
- The alarm begins with taps so fine you barely feel them and grows step by step over about two minutes to full strength, then keeps ringing until you stop it.
- Default: vibration plus a soft nature-inspired melody on watches with a beeper or speaker. Choose vibration only or sound only in the settings.
- The screen stays dark at first and shows a calm "Time to wake up"; it flashes only at full strength.
- Works with Do Not Disturb on.

STAY AWAKE MODE
- Set the duration to 0 ("stay awake") and the watch keeps you awake instead: a gentle nudge when you have been still for a while and a firm buzz the moment you doze off. Stopping the buzz puts it back on guard for the next doze.

BUTTONS
- Nothing stops a nap or the alarm by accident: press BACK twice to exit, START twice to stop and see your stats. Taps and swipes are ignored while you sleep. UP/DOWN show the nap so far.
- Tip for fēnix, epix, Enduro, MARQ: assign Power Nap to a hot key (Settings > System > Hot Keys) and start a nap with one long press.

AFTER THE NAP
- Summary with time asleep, how long you took to fall asleep, how much of the planned nap you completed, wake episodes, average and minimum heart rate.

SETTINGS (Garmin Connect app; nap duration also on the watch)
- Nap duration 5-120 min, max time to fall asleep 5-30 min, alarm type, heart-rate drop 3-20 BPM, motion sensitivity.

Keep the app open while napping: watches with a task switcher (fēnix 8, Venu 3/4, vívoactive 6, ...) do not let a background app vibrate. The app warns you when the battery is below 10 %.

PRIVACY
Heart rate and motion are processed in memory on the watch only; nothing is stored or transmitted. Only your nap duration preference is saved.
```

### A2. Upload New Version > What's New (version 1.1.0)

```
Version 1.1.0
- Stay Awake mode: set 0 minutes and the watch keeps you awake, with a gentle nudge when you go still and a buzz the moment you doze off
- Gentle wake-up: a finer, longer crescendo from barely-perceptible taps to full strength over about two minutes; the screen stays dark and calm until the alarm is clearly felt, and the alarm keeps ringing until you stop it
- Nature-inspired melody, on by default together with vibration on watches with a beeper or speaker (vibration only or sound only in the settings)
- Sleep detection is silent: nothing vibrates until the alarm
- Guaranteed alarm time: "Latest alarm HH:MM" is shown from the start and is never missed, whatever the detection does; a late onset shortens the nap instead
- "TAP to begin" on touch watches, UP/DOWN or taps set the minutes, time of day on every screen, low-battery warning
- Peek at the nap so far with UP/DOWN; BACK twice exits, START twice stops with stats; nothing stops the nap by accident
- Summary shows how long you took to fall asleep and how much of the planned nap you completed
- Test alarm from the start-screen menu to feel the wake-up ramp
- Works with Do Not Disturb; crisp app icon on every watch; larger text on small screens
- <N> unit tests, run on all 43 supported watches
```

## Appendix B — Commands

```bash
SDK="$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b"
# test build + run, one device
"$SDK/bin/monkeyc" -o /tmp/pn-test.prg -f monkey.jungle -d fenix847mm -y ~/developer_key.der -t -l 3 -w
"$SDK/bin/connectiq" &            # once
"$SDK/bin/monkeydo" /tmp/pn-test.prg fenix847mm -t          # or "-t testName"
# several / all devices
tools/runtests.sh fenix847mm instinct3solar45mm fr255s venu3s vivoactive5
tools/runtests.sh $(cat tools/devices.txt)
# release build check
"$SDK/bin/monkeyc" -o /tmp/pn-rel.prg -f monkey.jungle -d instinct3solar45mm -y ~/developer_key.der -r -l 3
# store package
"$SDK/bin/monkeyc" -e -o bin/PowerNap-1.1.0.iq -f monkey.jungle -y ~/developer_key.der -r -l 3
```
