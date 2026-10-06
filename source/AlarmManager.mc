import Toybox.Attention;
import Toybox.Timer;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Manages the nap alarm: a data-driven crescendo from taps that are barely
//! perceptible to full strength in about two minutes, three minutes at full
//! strength five seconds apart, then a slow persistent phase until the user
//! stops it.
//!
//! The ramp is one table (RAMP), one row per step:
//!   [intensity %, pulse ms, pulses, gap ms, interval ms, rings]
//! and everything else is derived from it: the vibration pattern of a ring,
//! the wait after it, when the backlight may come on, and the phase the
//! screen shows ("ALARM x/4", calm or loud). The table is what the owner
//! tunes on the wrist (the "Test alarm" preview plays every step once).
//!
//! Stay Awake does not read RAMP. Its doze alarm climbs DOZE_RAMP and its
//! nudge is one ring of NUDGE_ROW: their own copy of the 1.1.0 rows they
//! rang with (steps 5-9 and step 2), so a retuned nap ramp never changes
//! them (owner, 2026-10-06; testStay_dozeAlarmAndNudgeAsIn110).
//!
//!   step  %    pulse  pulses  gap   interval  rings  first ring at
//!   0     22   120    2       400   10 s      2      0 s
//!   1     28   140    2       380   9 s       2      20 s
//!   2     35   160    2       350   8 s       2      38 s
//!   3     43   180    3       320   8 s       2      54 s
//!   4     52   210    3       300   7 s       2      70 s
//!   5     63   240    3       260   6 s       2      84 s
//!   6     78   280    3       200   6 s       2      96 s
//!   7     92   320    3       160   5 s       2      108 s
//!   8     100  350    3       150   5 s       36     118 s (3 min at full)
//!   9     100  350    3       150   30 s      -      298 s (persistent)
//!
//! The interval of a row is the wait AFTER each of its rings, so a step's
//! first ring comes one interval of the previous step after that step's last
//! ring. Full strength is reached 118 s after the first ring (the owner
//! accepts 100-130 s), the first pulses are 22 % for 120 ms (shorter or
//! weaker pulses may not start the motor at all), and every step raises
//! intensity, pulse length or pulse count while the wait never grows. After
//! three minutes at full strength nobody wakes from the next burst five
//! seconds later (a watch left on the nightstand), so the alarm keeps ringing
//! every 30 s until dismissed instead of draining the battery.
//!
//! Derived thresholds, the same for both tables: the backlight may come on
//! from a ring >= 50 % (BACKLIGHT_FROM_PCT), and the display phase of a ring
//! is 0 below 40 %, 1 below 65 %, 2 below 100 % and 3 at 100 %
//! (getCurrentPhase / getLastRingPhase / isFullIntensity keep their meaning
//! for the view).
//!
//! Output: every ring is a vibration and nothing else (tools/no-sound.sh
//! keeps it that way). A watch without vibration, or a vibrate call that
//! throws, leaves the ring to the screen and the backlight: the ramp keeps
//! its schedule either way, so the alarm never ends by itself.
//!
//! Display handling: the wake-up is gentle for the eyes too. Below
//! BACKLIGHT_FROM_PCT the screen stays dark (a raised wrist shows a calm
//! screen), and the view only flashes once the rings are at full strength
//! (isFullIntensity). On AMOLED devices with burn-in protection,
//! Attention.backlight(true) throws once the display has been held on for
//! about a minute. Because rings come every 5-10 s, calling it on every ring
//! would hold the display on continuously and start throwing right when the
//! escalation reaches the perceptible steps. The backlight is therefore
//! requested only on the first two rings at or above BACKLIGHT_FROM_PCT and
//! then every 6th, always AFTER the vibration, and in its own try block so a
//! failure can never suppress the alarm itself.
//!
//! Quiet onset gate (owner rule, non-negotiable): nothing may vibrate, sound
//! or light up at sleep detection or at any other moment than the alarm and
//! the Stay Awake nudge. deliver() and requestBacklight() refuse every call
//! made while the alarm is not ringing, except from inside nudge(); nudge()
//! refuses every call unless the detector told the manager that the running
//! session is Stay Awake (setStayAwake). A refused call is a no-op that
//! increments _blockedDeliveries, which the tests assert stays 0.
//!
//! Preview ("Test alarm" in the start-screen menu, never during a nap): the
//! ramp is played once, one ring per step 3 s apart, with the same backlight
//! rule, without the persistent phase; it stops by itself after the last
//! step. A preview and an alarm exclude each other. The gate allows output
//! while a preview runs.
class AlarmManager {

    // Columns of a RAMP row.
    private const R_PCT         = 0;    // vibration intensity (VibeProfile dutyCycle), %
    private const R_PULSE_MS    = 1;    // length of one pulse
    private const R_PULSES      = 2;    // pulses per ring (1-4: at most 8 profiles)
    private const R_GAP_MS      = 3;    // pause between the pulses of a ring
    private const R_INTERVAL_MS = 4;    // wait after each ring of this step
    private const R_RINGS       = 5;    // rings at this step; 0 = until stopped

    //! The crescendo (see class doc). The last row is the persistent phase.
    private const RAMP = [
        [ 22, 120, 2, 400, 10000,  2],
        [ 28, 140, 2, 380,  9000,  2],
        [ 35, 160, 2, 350,  8000,  2],
        [ 43, 180, 3, 320,  8000,  2],
        [ 52, 210, 3, 300,  7000,  2],
        [ 63, 240, 3, 260,  6000,  2],
        [ 78, 280, 3, 200,  6000,  2],
        [ 92, 320, 3, 160,  5000,  2],
        [100, 350, 3, 150,  5000, 36],
        [100, 350, 3, 150, 30000,  0]
    ] as Array<Array<Number> >;

    //! The Stay Awake doze alarm, climbed from its first row: someone who
    //! just dozed off at a desk must notice it at once, not after a minute
    //! of feather taps. Rows 5-9 of the 1.1.0 ramp, copied (see class doc).
    private const DOZE_RAMP = [
        [ 63, 240, 3, 260,  6000,  2],
        [ 78, 280, 3, 200,  6000,  2],
        [ 92, 320, 3, 160,  5000,  2],
        [100, 350, 3, 150,  5000, 36],
        [100, 350, 3, 150, 30000,  0]
    ] as Array<Array<Number> >;

    //! The Stay Awake nudge: one ring of this row (its interval and rings
    //! are not used). Row 2 of the 1.1.0 ramp, copied (see class doc).
    private const NUDGE_ROW = [35, 160, 2, 350, 8000, 2] as Array<Number>;

    // Gentle visuals: the display stays dark below this.
    private const BACKLIGHT_FROM_PCT = 50;

    // Display phases for "ALARM x/4" and the calm/loud screen.
    private const PHASE1_FROM_PCT = 40;
    private const PHASE2_FROM_PCT = 65;
    private const PHASE3_FROM_PCT = 100;

    // Backlight: on the first rings at or above BACKLIGHT_FROM_PCT, then only
    // every Nth ring so the display is never held on continuously.
    private const BACKLIGHT_INITIAL_RINGS = 2;
    private const BACKLIGHT_EVERY_N_RINGS = 6;

    private var _repeatTimer as Timer.Timer? = null;
    private var _timerRunning as Boolean     = false; // the repeat timer is scheduled
    private var _lastRingMs  as Number       = 0;     // System.getTimer() at the last ring
    private var _forceTimerFail as Boolean   = false; // debug: the repeat timer cannot start
    private var _isAlarming  as Boolean      = false;
    private var _doze        as Boolean      = false; // the ringing alarm climbs DOZE_RAMP, not RAMP
    private var _ringCount   as Number       = 0;     // index of the next ring (sets its step)
    private var _ringsFired  as Number       = 0;     // rings since startAlarm
    private var _brightRings as Number       = 0;     // rings fired at or above BACKLIGHT_FROM_PCT
    private var _stayAwake   as Boolean      = false; // the running session may nudge (Stay Awake)
    private var _nudging     as Boolean      = false; // inside nudge(): output allowed once
    private var _blockedDeliveries as Number = 0;     // calls refused by the quiet onset gate

    // Preview of the ramp (see class doc): one ring per step, 3 s apart.
    private const PREVIEW_INTERVAL_MS = 3000;
    private var _previewing   as Boolean      = false;
    private var _previewStep  as Number       = 0;    // the next step to play
    private var _previewTimer as Timer.Timer? = null;

    // Diagnostics (read by tests; cheap enough to keep in release)
    private var _vibrateCount   as Number  = 0;
    private var _backlightCount as Number  = 0;
    private var _nudgeCount     as Number  = 0;
    private var _forceBacklightThrow as Boolean = false;
    private var _forceNoVibe as Boolean = false;     // debug: simulate a device without vibration
    (:debug) private var _lastPattern as Array<Attention.VibeProfile>? = null; // the last vibration delivered

    //! Start the crescendo. Fires the first ring immediately (step 0), then
    //! schedules the repeating rings whose wait shrinks step by step.
    function startAlarm() as Void {
        startRamp(false);
    }

    //! The Stay Awake doze alarm: DOZE_RAMP from its first row, loud at once.
    function startDozeAlarm() as Void {
        startRamp(true);
    }

    //! Start a table at its first ring: RAMP, or DOZE_RAMP for `doze`.
    //! Refused while an alarm rings or a preview plays.
    private function startRamp(doze as Boolean) as Void {
        if (_isAlarming || _previewing) {
            return;
        }
        _doze = doze;
        _isAlarming = true;
        _ringCount  = 0;
        _ringsFired = 0;
        _brightRings = 0;
        _vibrateCount = 0;
        _backlightCount = 0;

        fireAlarm(); // first ring fires immediately
        restartTimer();
    }

    //! Timer callback. Fires the next ring and, when its step has another
    //! wait than the previous one, restarts the timer with it.
    function onRepeatAlarm() as Void {
        if (!_isAlarming) {
            return;
        }
        var intervalBefore = intervalAfterLastRing();
        fireAlarm();
        if (intervalAfterLastRing() != intervalBefore) {
            restartTimer();
        }
        WatchUi.requestUpdate();
    }

    //! Ring right now (e.g. the app just came back to the foreground after
    //! the system had denied alerts) and restart the repeat timer from here.
    function ringNow() as Void {
        if (!_isAlarming) {
            return;
        }
        fireAlarm();
        restartTimer();
        WatchUi.requestUpdate();
    }

    //! Stay Awake: one gentle reminder when the wrist has been still for a
    //! while (one ring of NUDGE_ROW, display on). Never while the alarm
    //! rings, and never in a nap session (the quiet onset gate).
    function nudge() as Void {
        if (_isAlarming || !_stayAwake) {
            _blockedDeliveries += 1;
            return;
        }
        _nudgeCount += 1;
        _nudging = true;
        try {
            deliver(NUDGE_ROW);
            requestBacklight();
        } catch (e instanceof Lang.Exception) {
            // The vibration and the backlight catch their own errors.
        }
        _nudging = false;
    }

    //! The detector tells the manager whether the running session is Stay
    //! Awake (may nudge) or a nap (must stay silent until the alarm). Set by
    //! SleepDetector at every session start, cleared when the session stops.
    function setStayAwake(stayAwake as Boolean) as Void {
        _stayAwake = stayAwake;
    }

    //! Stop the alarm (and a running preview) and reset state for the next
    //! session.
    function stop() as Void {
        _isAlarming = false;
        _doze       = false;
        _ringCount  = 0;
        _ringsFired = 0;
        _brightRings = 0;
        if (_repeatTimer != null) {
            _repeatTimer.stop();
        }
        _timerRunning = false;
        stopPreview();
    }

    function isAlarming() as Boolean {
        return _isAlarming;
    }

    // -- Preview ("Test alarm") -----------------------------------------------

    //! Play every step of the ramp once, 3 s apart, then stop by itself.
    //! Refused while the alarm rings.
    function startPreview() as Void {
        if (_isAlarming || _previewing) {
            return;
        }
        _previewing = true;
        _previewStep = 0;
        _ringsFired = 0;
        _brightRings = 0;
        _vibrateCount = 0;
        _backlightCount = 0;
        firePreviewStep();
        try {
            _previewTimer = new Timer.Timer();
            _previewTimer.start(method(:onPreviewTick), PREVIEW_INTERVAL_MS, true);
        } catch (e instanceof Lang.Exception) {
            // Timer limit: the first step played, the preview ends here.
            _previewing = false;
            _previewTimer = null;
        }
    }

    //! Timer callback: the next step, or the end of the preview.
    function onPreviewTick() as Void {
        if (!_previewing) {
            return;
        }
        if (_previewStep >= getPreviewSteps()) {
            stopPreview();
        } else {
            firePreviewStep();
        }
        WatchUi.requestUpdate();
    }

    //! End the preview (BACK, the end of the ramp, or stop()).
    function stopPreview() as Void {
        _previewing = false;
        _previewStep = 0;
        if (_previewTimer != null) {
            _previewTimer.stop();
            _previewTimer = null;
        }
    }

    function isPreviewing() as Boolean {
        return _previewing;
    }

    //! Steps a preview plays: every row but the persistent one.
    function getPreviewSteps() as Number {
        return RAMP.size() - 1;
    }

    //! The step the preview played last, 1-based ("step N of M"); 0 before.
    function getPreviewStep() as Number {
        return _previewStep;
    }

    //! Intensity of the step the preview played last, %.
    function getPreviewPct() as Number {
        return (_previewStep > 0) ? RAMP[_previewStep - 1][R_PCT] : 0;
    }

    //! One preview ring: the next step of RAMP, delivered like an alarm ring.
    private function firePreviewStep() as Void {
        var row = RAMP[_previewStep];
        _previewStep += 1;
        _ringsFired += 1;
        deliver(row);
        if (row[R_PCT] >= BACKLIGHT_FROM_PCT) {
            var bright = _brightRings;
            _brightRings += 1;
            if (bright < BACKLIGHT_INITIAL_RINGS || (bright % BACKLIGHT_EVERY_N_RINGS) == 0) {
                requestBacklight();
            }
        }
    }

    //! Display phase of the next ring for the view, 0-3.
    function getCurrentPhase() as Number {
        return displayPhase(pctOfStep(stepOfRing(_ringCount)));
    }

    //! Display phase of the ring that fired last, 0-3 (0 before the first ring).
    function getLastRingPhase() as Number {
        if (_ringsFired == 0 || _ringCount == 0) {
            return 0;
        }
        return displayPhase(pctOfStep(stepOfRing(_ringCount - 1)));
    }

    //! The alarm has reached full strength: the view may flash from now on.
    function isFullIntensity() as Boolean {
        return _isAlarming && _ringsFired > 0 && _ringCount > 0
            && pctOfStep(stepOfRing(_ringCount - 1)) >= PHASE3_FROM_PCT;
    }

    // -- Private helpers -------------------------------------------------

    //! Wait after the ring that fired last (its step's interval).
    private function intervalAfterLastRing() as Number {
        var last = (_ringCount > 0) ? _ringCount - 1 : 0;
        return activeRamp()[stepOfRing(last)][R_INTERVAL_MS];
    }

    //! (Re)start the repeat timer with the wait after the ring just fired.
    //! The Timer object is created once and reused (no allocation on every
    //! step boundary); if it cannot be created or started, onSecond() rings
    //! from the detector's tick instead, so the alarm never goes silent.
    private function restartTimer() as Void {
        try {
            if (_forceTimerFail) {
                throw new Lang.Exception();
            }
            if (_repeatTimer == null) {
                _repeatTimer = new Timer.Timer();
            }
            (_repeatTimer as Timer.Timer).stop();
            (_repeatTimer as Timer.Timer).start(method(:onRepeatAlarm), intervalAfterLastRing(), true);
            _timerRunning = true;
        } catch (e instanceof Lang.Exception) {
            _timerRunning = false;
        }
    }

    //! Called once a second by the detector's tick while the alarm rings:
    //! a safety net for a repeat timer that could not be started (timer
    //! limit, memory). Rings when the wait after the last ring has passed.
    function onSecond() as Void {
        if (!_isAlarming || _timerRunning) {
            return;
        }
        var elapsed = System.getTimer() - _lastRingMs;
        if (elapsed < 0 || elapsed >= intervalAfterLastRing()) {
            fireAlarm();
            restartTimer();
            WatchUi.requestUpdate();
        }
    }

    //! Fire one ring. The vibration comes first, in its own try block; the
    //! backlight request is last and sparse (see class doc).
    private function fireAlarm() as Void {
        var row = activeRamp()[stepOfRing(_ringCount)];
        _ringCount += 1;
        _ringsFired += 1;
        _lastRingMs = System.getTimer();

        deliver(row);

        if (row[R_PCT] >= BACKLIGHT_FROM_PCT) {
            var bright = _brightRings;
            _brightRings += 1;
            if (bright < BACKLIGHT_INITIAL_RINGS || (bright % BACKLIGHT_EVERY_N_RINGS) == 0) {
                requestBacklight();
            }
        }
    }

    //! The quiet onset gate: output is allowed only while the alarm rings,
    //! from inside nudge(), or during a preview. Any other call is refused
    //! and counted.
    private function outputAllowed() as Boolean {
        if (_isAlarming || _nudging || _previewing) {
            return true;
        }
        _blockedDeliveries += 1;
        return false;
    }

    //! The vibration of one ring of a table `row`, the alarm's only output
    //! (see class doc).
    private function deliver(row as Array<Number>) as Void {
        if (!outputAllowed()) {
            return;
        }
        if (_forceNoVibe || !(Attention has :vibrate)) {
            return;
        }
        try {
            var pattern = getVibePattern(row);
            Attention.vibrate(pattern);
            _vibrateCount += 1;
            noteDelivered(pattern);
        } catch (e instanceof Lang.Exception) {
            // The screen and the backlight carry this ring.
        }
    }

    //! Remember the vibration just delivered, for the tests (debug builds
    //! only: release builds have neither the field nor anything to write).
    (:debug)
    private function noteDelivered(pattern as Array<Attention.VibeProfile>) as Void {
        _lastPattern = pattern;
    }

    (:release)
    private function noteDelivered(pattern as Array<Attention.VibeProfile>) as Void {
    }

    //! Turn the display on, in its own try block (see class doc).
    private function requestBacklight() as Void {
        if (!outputAllowed()) {
            return;
        }
        try {
            if (_forceBacklightThrow) {
                throw new Lang.Exception();
            }
            if (Attention has :backlight) {
                // Counts requests: on burn-in protected displays the call
                // itself may throw once the screen has been on too long.
                _backlightCount += 1;
                Attention.backlight(true);
            }
        } catch (e instanceof Lang.Exception) {
            // BacklightOnTooLongException or unsupported -- harmless.
        }
    }

    // -- The ramp table ---------------------------------------------------

    //! The table the alarm climbs: DOZE_RAMP for the Stay Awake doze alarm,
    //! RAMP otherwise (a nap's alarm, and idle).
    private function activeRamp() as Array<Array<Number> > {
        return _doze ? DOZE_RAMP : RAMP;
    }

    //! Step of ring `ring` (0-based ring index since the ramp's first ring).
    //! Rings beyond the bounded rows belong to the last (persistent) row.
    private function stepOfRing(ring as Number) as Number {
        var ramp = activeRamp();
        var first = 0;
        for (var s = 0; s < ramp.size(); s++) {
            var rings = ramp[s][R_RINGS];
            if (rings <= 0 || ring < first + rings) {
                return s;
            }
            first += rings;
        }
        return ramp.size() - 1;
    }

    //! Index of the first ring of a step (the persistent row's first ring
    //! follows the last bounded ring).
    private function firstRingOfStep(step as Number) as Number {
        var ramp = activeRamp();
        var first = 0;
        for (var s = 0; s < step && s < ramp.size(); s++) {
            first += ramp[s][R_RINGS];
        }
        return first;
    }

    //! The first step of RAMP whose intensity is at least `pct` (the last
    //! one if none). Only the tests resolve thresholds to steps.
    (:debug)
    private function firstStepAtLeast(pct as Number) as Number {
        for (var s = 0; s < RAMP.size(); s++) {
            if (RAMP[s][R_PCT] >= pct) {
                return s;
            }
        }
        return RAMP.size() - 1;
    }

    private function pctOfStep(step as Number) as Number {
        return activeRamp()[step][R_PCT];
    }

    //! Display phase of an intensity: 0 below 40 %, 1 below 65 %, 2 below
    //! 100 %, 3 at full strength.
    private function displayPhase(pct as Number) as Number {
        if (pct >= PHASE3_FROM_PCT) { return 3; }
        if (pct >= PHASE2_FROM_PCT) { return 2; }
        if (pct >= PHASE1_FROM_PCT) { return 1; }
        return 0;
    }

    //! Vibration pattern of one ring of a table row: `pulses` pulses of
    //! `pulse ms` at `pct` with `gap ms` between them (at most 8 profiles).
    //! Note: Forerunner devices ignore the intensity and run every pulse at
    //! the same duty cycle, so escalation there is by pulse length and count.
    private function getVibePattern(row as Array<Number>) as Array<Attention.VibeProfile> {
        var out = [] as Array<Attention.VibeProfile>;
        var pulses = row[R_PULSES];
        if (pulses > 4) { pulses = 4; }
        for (var i = 0; i < pulses; i++) {
            if (i > 0) {
                out.add(new Attention.VibeProfile(0, row[R_GAP_MS]));
            }
            out.add(new Attention.VibeProfile(row[R_PCT], row[R_PULSE_MS]));
        }
        return out;
    }

    // -- Test hooks (debug builds only) -----------------------------------

    (:debug)
    function testGetRingCount() as Number { return _ringCount; }

    (:debug)
    function testGetRingsFired() as Number { return _ringsFired; }

    //! Number of RAMP rows, the persistent row included.
    (:debug)
    function testGetRampSize() as Number { return RAMP.size(); }

    //! One RAMP row: [pct, pulseMs, pulses, gapMs, intervalMs, rings].
    (:debug)
    function testGetRampRow(step as Number) as Array<Number> { return RAMP[step]; }

    (:debug)
    function testGetStepForRing(ring as Number) as Number { return stepOfRing(ring); }

    (:debug)
    function testGetFirstRingOfStep(step as Number) as Number { return firstRingOfStep(step); }

    (:debug)
    function testGetIntervalForStep(step as Number) as Number { return RAMP[step][R_INTERVAL_MS]; }

    (:debug)
    function testFirstStepAtLeast(pct as Number) as Number { return firstStepAtLeast(pct); }

    (:debug)
    function testDisplayPhase(pct as Number) as Number { return displayPhase(pct); }

    //! The RAMP step the backlight threshold resolves to.
    (:debug)
    function testBacklightFromStep() as Number { return firstStepAtLeast(BACKLIGHT_FROM_PCT); }

    //! Step of the ring that fired last, in the table the alarm climbs (-1
    //! before the first ring).
    (:debug)
    function testGetLastRingStep() as Number {
        return (_ringsFired == 0 || _ringCount == 0) ? -1 : stepOfRing(_ringCount - 1);
    }

    (:debug)
    function testGetVibrateCount() as Number { return _vibrateCount; }

    (:debug)
    function testGetBacklightCount() as Number { return _backlightCount; }

    (:debug)
    function testGetNudgeCount() as Number { return _nudgeCount; }

    //! Calls that the quiet onset gate refused (must stay 0 in every test).
    (:debug)
    function testGetBlockedDeliveries() as Number { return _blockedDeliveries; }

    //! Make the backlight request throw, as burn-in protected AMOLED
    //! displays do after ~1 minute, to prove the alarm keeps vibrating.
    (:debug)
    function testForceBacklightThrow(force as Boolean) as Void { _forceBacklightThrow = force; }

    //! Fire one more ring synchronously (as the repeat timer would).
    (:debug)
    function testFireRing() as Void { onRepeatAlarm(); }

    //! Make the repeat timer fail to start (timer limit), so the tick
    //! fallback (onSecond) carries the alarm.
    (:debug)
    function testForceTimerFail(fail as Boolean) as Void { _forceTimerFail = fail; }

    //! Whether the repeat timer is scheduled.
    (:debug)
    function testIsTimerRunning() as Boolean { return _timerRunning; }

    //! Pretend the last ring was `ms` ago (moves the fallback clock).
    (:debug)
    function testAgeLastRing(ms as Number) as Void { _lastRingMs -= ms; }

    //! Advance the preview synchronously (as its timer would).
    (:debug)
    function testPreviewTick() as Void { onPreviewTick(); }

    //! Simulate a watch without vibration (no motor, or a call that fails).
    (:debug)
    function testForceNoVibration(force as Boolean) as Void { _forceNoVibe = force; }

    (:debug)
    function testGetVibePattern(step as Number) as Array<Attention.VibeProfile> { return getVibePattern(RAMP[step]); }

    //! The vibration actually delivered last (a ring, a preview step or the
    //! nudge), null before the first.
    (:debug)
    function testGetLastPattern() as Array<Attention.VibeProfile>? { return _lastPattern; }

    //! The wait after the ring that fired last: when the next one rings.
    (:debug)
    function testGetWaitAfterLastRing() as Number { return intervalAfterLastRing(); }
}

