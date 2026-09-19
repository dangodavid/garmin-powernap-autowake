import Toybox.Attention;
import Toybox.Timer;
import Toybox.Application;
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
//! the wait after it, when the melody joins ("Both"), when the backlight may
//! come on, where the Stay Awake doze alarm and nudge start, and the phase
//! the screen shows ("ALARM x/4", calm or loud). The table is what the owner
//! tunes on the wrist (the "Test alarm" preview plays every step once).
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
//! Derived thresholds: the "Both" melody joins at the first step >= 40 %
//! (TONE_FROM_PCT), the backlight may come on from the first step >= 50 %
//! (BACKLIGHT_FROM_PCT), the Stay Awake doze alarm starts at the first step
//! >= 60 % (DOZE_START_PCT) and the nudge uses the first step >= 30 %
//! (NUDGE_PCT). The display phase of a step is 0 below 40 %, 1 below 65 %,
//! 2 below 100 % and 3 at 100 % (getCurrentPhase / getLastRingPhase /
//! isFullIntensity keep their meaning for the view).
//!
//! Tones: Connect IQ can neither play audio files nor set the volume, so the
//! "nature sound" is a ToneProfile melody per step: a distant, low "cuckoo"
//! first, then bird chirps that gain notes, pitch and length with the ramp
//! (small buzzers get louder towards their 2-4 kHz resonance), up to a
//! trill. "Nature sound only" plays it from the first ring; with "Vibration
//! + nature sound" the vibration opens the wake-up alone and the melody joins
//! at TONE_FROM_PCT.
//!
//! Output channel: the configured alarm type is a preference, never a reason
//! to stay silent. If the preferred channel is unsupported (vivoactive 5/6
//! have no Attention.playTone), switched off in the watch settings
//! (DeviceSettings.vibrateOn / tonesOn) or throws, the other channel is used.
//! An unknown alarmType value behaves like vibration.
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
//! then every 6th, always AFTER the vibration/tone, and in its own try block
//! so a failure can never suppress the alarm itself.
//!
//! Quiet onset gate (owner rule, non-negotiable): nothing may vibrate, sound
//! or light up at sleep detection or at any other moment than the alarm and
//! the Stay Awake nudge. deliver() and requestBacklight() refuse every call
//! made while the alarm is not ringing, except from inside nudge(); nudge()
//! refuses every call unless the detector told the manager that the running
//! session is Stay Awake (setStayAwake). A refused call is a no-op that
//! increments _blockedDeliveries, which the tests assert stays 0.
class AlarmManager {

    // Alarm type constants matching settings values
    enum {
        ALARM_VIBRATION = 0,
        ALARM_TONE      = 1,
        ALARM_BOTH      = 2
    }

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

    // Thresholds on the ramp, all resolved to steps with firstStepAtLeast().
    private const TONE_FROM_PCT      = 40;  // "Both": the melody joins here
    private const BACKLIGHT_FROM_PCT = 50;  // gentle visuals: dark below this
    private const DOZE_START_PCT     = 60;  // Stay Awake doze alarm starts here
    private const NUDGE_PCT          = 30;  // Stay Awake nudge: one burst of this step

    // Display phases for "ALARM x/4" and the calm/loud screen.
    private const PHASE1_FROM_PCT = 40;
    private const PHASE2_FROM_PCT = 65;
    private const PHASE3_FROM_PCT = 100;

    // Backlight: on the first rings at or above BACKLIGHT_FROM_PCT, then only
    // every Nth ring so the display is never held on continuously.
    private const BACKLIGHT_INITIAL_RINGS = 2;
    private const BACKLIGHT_EVERY_N_RINGS = 6;

    private var _alarmType   as Number       = ALARM_VIBRATION;
    private var _repeatTimer as Timer.Timer? = null;
    private var _isAlarming  as Boolean      = false;
    private var _ringCount   as Number       = 0;     // index of the next ring (sets its step)
    private var _ringsFired  as Number       = 0;     // rings since startAlarm
    private var _brightRings as Number       = 0;     // rings fired at or above BACKLIGHT_FROM_PCT
    private var _stayAwake   as Boolean      = false; // the running session may nudge (Stay Awake)
    private var _nudging     as Boolean      = false; // inside nudge(): output allowed once
    private var _blockedDeliveries as Number = 0;     // calls refused by the quiet onset gate

    // Diagnostics (read by tests; cheap enough to keep in release)
    private var _vibrateCount   as Number  = 0;
    private var _toneCount      as Number  = 0;     // rings with the tone channel sounding
    private var _melodiesStarted as Number = 0;     // Attention.playTone calls with a melody
    private var _backlightCount as Number  = 0;
    private var _nudgeCount     as Number  = 0;
    private var _forceBacklightThrow as Boolean = false;
    private var _forceNoVibe as Boolean = false;     // debug: simulate a device without vibration
    private var _forceNoTone as Boolean = false;     // debug: simulate a device without tones

    function initialize() {
        loadSettings();
    }

    //! Reload alarm type from application properties.
    function loadSettings() as Void {
        try {
            var val = Application.Properties.getValue("alarmType");
            if (val != null && val instanceof Number) {
                _alarmType = val as Number;
            }
        } catch (e instanceof Lang.Exception) {
            // Storage corrupt -- keep default (vibration).
        }
    }

    //! Start the crescendo. Fires the first ring immediately (step 0), then
    //! schedules the repeating rings whose wait shrinks step by step.
    function startAlarm() as Void {
        startAlarmFromStep(0);
    }

    //! The Stay Awake doze alarm: someone who just dozed off at a desk must
    //! notice it at once, not after a minute of feather taps, so it starts
    //! at the first step of DOZE_START_PCT and climbs the ramp from there.
    function startDozeAlarm() as Void {
        startAlarmFromStep(firstStepAtLeast(DOZE_START_PCT));
    }

    //! Start the ramp at the first ring of `step`.
    function startAlarmFromStep(step as Number) as Void {
        if (_isAlarming) {
            return;
        }
        _isAlarming = true;
        _ringCount  = firstRingOfStep(step);
        _ringsFired = 0;
        _brightRings = 0;
        _vibrateCount = 0;
        _toneCount = 0;
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
    //! while (one ring of the first step at NUDGE_PCT, display on). Uses the
    //! same channels as the alarm; never while it rings, and never in a nap
    //! session (the quiet onset gate).
    function nudge() as Void {
        if (_isAlarming || !_stayAwake) {
            _blockedDeliveries += 1;
            return;
        }
        _nudgeCount += 1;
        _nudging = true;
        try {
            deliver(firstStepAtLeast(NUDGE_PCT));
            requestBacklight();
        } catch (e instanceof Lang.Exception) {
            // The channels catch their own errors; nothing else to do.
        }
        _nudging = false;
    }

    //! The detector tells the manager whether the running session is Stay
    //! Awake (may nudge) or a nap (must stay silent until the alarm). Set by
    //! SleepDetector at every session start, cleared when the session stops.
    function setStayAwake(stayAwake as Boolean) as Void {
        _stayAwake = stayAwake;
    }

    //! Stop the alarm and reset state for the next session.
    function stop() as Void {
        _isAlarming = false;
        _ringCount  = 0;
        _ringsFired = 0;
        _brightRings = 0;
        if (_repeatTimer != null) {
            _repeatTimer.stop();
            _repeatTimer = null;
        }
    }

    function isAlarming() as Boolean {
        return _isAlarming;
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
        return RAMP[stepOfRing(last)][R_INTERVAL_MS];
    }

    //! (Re)start the repeat timer with the wait after the ring just fired.
    private function restartTimer() as Void {
        if (_repeatTimer != null) {
            _repeatTimer.stop();
        }
        try {
            _repeatTimer = new Timer.Timer();
            _repeatTimer.start(method(:onRepeatAlarm), intervalAfterLastRing(), true);
        } catch (e instanceof Lang.Exception) {
            // Timer limit reached -- the ring already fired, no escalation.
            _repeatTimer = null;
        }
    }

    //! Fire one ring. Vibration and tone come first, each isolated in its own
    //! try block; the backlight request is last and sparse (see class doc).
    private function fireAlarm() as Void {
        var step = stepOfRing(_ringCount);
        _ringCount += 1;
        _ringsFired += 1;

        deliver(step);

        if (pctOfStep(step) >= BACKLIGHT_FROM_PCT) {
            var bright = _brightRings;
            _brightRings += 1;
            if (bright < BACKLIGHT_INITIAL_RINGS || (bright % BACKLIGHT_EVERY_N_RINGS) == 0) {
                requestBacklight();
            }
        }
    }

    //! The quiet onset gate: output is allowed only while the alarm rings or
    //! from inside nudge(). Any other call is refused and counted.
    private function outputAllowed() as Boolean {
        if (_isAlarming || _nudging) {
            return true;
        }
        _blockedDeliveries += 1;
        return false;
    }

    //! Vibration and/or tone for one ring of `step`. The configured type is
    //! a preference, widened when the preferred channel cannot be used.
    private function deliver(step as Number) as Void {
        if (!outputAllowed()) {
            return;
        }
        var vibeUsable = isVibeUsable();
        var toneUsable = isToneUsable();
        // Preferred channels, widened when the preferred one cannot be heard.
        var tryVibe = (_alarmType != ALARM_TONE) || !toneUsable;
        var tryTone = (_alarmType == ALARM_TONE || _alarmType == ALARM_BOTH) || !vibeUsable;
        if (_alarmType == ALARM_BOTH && vibeUsable && pctOfStep(step) < TONE_FROM_PCT) {
            // "Both": the vibration opens the wake-up alone, the birds join later.
            tryTone = false;
        }

        var delivered = false;
        if (tryVibe && doVibrate(step)) { delivered = true; }
        if (tryTone && doTone(step)) { delivered = true; }
        if (!delivered) {
            // Every preferred call failed: last resort, try the other one.
            if (!tryVibe) { doVibrate(step); }
            if (!tryTone) { doTone(step); }
        }
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

    //! Vibration is supported and switched on in the watch settings.
    private function isVibeUsable() as Boolean {
        if (_forceNoVibe || !(Attention has :vibrate)) {
            return false;
        }
        try {
            return System.getDeviceSettings().vibrateOn;
        } catch (e instanceof Lang.Exception) {
            return true;
        }
    }

    //! Tones are supported and switched on in the watch settings.
    private function isToneUsable() as Boolean {
        if (_forceNoTone || !(Attention has :playTone)) {
            return false;
        }
        try {
            return System.getDeviceSettings().tonesOn;
        } catch (e instanceof Lang.Exception) {
            return true;
        }
    }

    //! One vibration burst; true if the call went through.
    private function doVibrate(step as Number) as Boolean {
        if (_forceNoVibe || !(Attention has :vibrate)) {
            return false;
        }
        try {
            Attention.vibrate(getVibePattern(step));
            _vibrateCount += 1;
            return true;
        } catch (e instanceof Lang.Exception) {
            return false;
        }
    }

    //! One tone (the step's melody where custom tones exist); true if the
    //! tone channel is sounding for this ring. A melody still playing from
    //! the previous call covers this ring instead of being cut off: rings
    //! are 5-30 s apart and melodies about a second, so this only happens
    //! when rings come back to back (ringNow, tests). Overlapping melodies
    //! also crash the Connect IQ simulator (SDK 9.1).
    private function doTone(step as Number) as Boolean {
        if (_forceNoTone || !(Attention has :playTone)) {
            return false;
        }
        try {
            if (Attention has :ToneProfile) {
                if (!ToneClock.isPlaying()) {
                    var melody = getToneProfile(step);
                    Attention.playTone({:toneProfile => melody});
                    ToneClock.started(melodyLengthMs(melody));
                    _melodiesStarted += 1;
                }
            } else {
                Attention.playTone(getToneForStep(step));
            }
            _toneCount += 1;
            return true;
        } catch (e instanceof Lang.Exception) {
            return false;
        }
    }

    private function melodyLengthMs(melody as Array<Attention.ToneProfile>) as Number {
        var ms = 0;
        for (var i = 0; i < melody.size(); i++) {
            ms += melody[i].duration;
        }
        return ms;
    }

    // -- The ramp table ---------------------------------------------------

    //! Step of ring `ring` (0-based ring index since the ramp's first ring).
    //! Rings beyond the bounded rows belong to the last (persistent) row.
    private function stepOfRing(ring as Number) as Number {
        var first = 0;
        for (var s = 0; s < RAMP.size(); s++) {
            var rings = RAMP[s][R_RINGS];
            if (rings <= 0 || ring < first + rings) {
                return s;
            }
            first += rings;
        }
        return RAMP.size() - 1;
    }

    //! Index of the first ring of a step (the persistent row's first ring
    //! follows the last bounded ring).
    private function firstRingOfStep(step as Number) as Number {
        var first = 0;
        for (var s = 0; s < step && s < RAMP.size(); s++) {
            first += RAMP[s][R_RINGS];
        }
        return first;
    }

    //! The first step whose intensity is at least `pct` (the last one if none).
    private function firstStepAtLeast(pct as Number) as Number {
        for (var s = 0; s < RAMP.size(); s++) {
            if (RAMP[s][R_PCT] >= pct) {
                return s;
            }
        }
        return RAMP.size() - 1;
    }

    private function pctOfStep(step as Number) as Number {
        return RAMP[step][R_PCT];
    }

    //! Display phase of an intensity: 0 below 40 %, 1 below 65 %, 2 below
    //! 100 %, 3 at full strength.
    private function displayPhase(pct as Number) as Number {
        if (pct >= PHASE3_FROM_PCT) { return 3; }
        if (pct >= PHASE2_FROM_PCT) { return 2; }
        if (pct >= PHASE1_FROM_PCT) { return 1; }
        return 0;
    }

    //! Vibration pattern of a step, built from its RAMP row: `pulses` pulses
    //! of `pulse ms` at `pct` with `gap ms` between them (at most 8 profiles).
    //! Note: Forerunner devices ignore the intensity and run every pulse at
    //! the same duty cycle, so escalation there is by pulse length and count.
    private function getVibePattern(step as Number) as Array<Attention.VibeProfile> {
        var row = RAMP[step];
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

    //! Birdsong-like melody per step (see class doc): from a distant, low
    //! "cuckoo" (two short low notes, the quietest a buzzer or speaker does)
    //! to a trill near the buzzer resonance. Each step has at least as many
    //! notes, as high a top note and as long a melody as the one before, and
    //! every melody is far shorter than its ring interval, so melodies never
    //! overlap. The persistent step repeats the full-strength melody.
    private function getToneProfile(step as Number) as Array<Attention.ToneProfile> {
        if (step <= 0) {
            return [                                    // distant cuckoo, D5-B4
                new Attention.ToneProfile(587, 120),
                new Attention.ToneProfile(494, 160)
            ] as Array<Attention.ToneProfile>;
        }
        if (step == 1) {
            return [                                    // cuckoo, answered
                new Attention.ToneProfile(659, 120),
                new Attention.ToneProfile(523, 160),
                new Attention.ToneProfile(659, 140)
            ] as Array<Attention.ToneProfile>;
        }
        if (step == 2) {
            return [                                    // a first, low chirp
                new Attention.ToneProfile(784, 100),
                new Attention.ToneProfile(659, 120),
                new Attention.ToneProfile(784, 120),
                new Attention.ToneProfile(880, 160)
            ] as Array<Attention.ToneProfile>;
        }
        if (step == 3) {
            return [                                    // rising chirp
                new Attention.ToneProfile(1047, 90),
                new Attention.ToneProfile(1319, 90),
                new Attention.ToneProfile(1568, 120),
                new Attention.ToneProfile(1319, 100),
                new Attention.ToneProfile(1568, 160)
            ] as Array<Attention.ToneProfile>;
        }
        if (step == 4) {
            return [                                    // chirp with a repeat
                new Attention.ToneProfile(1319, 80),
                new Attention.ToneProfile(1568, 80),
                new Attention.ToneProfile(1760, 110),
                new Attention.ToneProfile(1568, 80),
                new Attention.ToneProfile(1760, 110),
                new Attention.ToneProfile(2093, 180)
            ] as Array<Attention.ToneProfile>;
        }
        if (step == 5) {
            return [                                    // two higher chirps
                new Attention.ToneProfile(1568, 80),
                new Attention.ToneProfile(1760, 80),
                new Attention.ToneProfile(2093, 110),
                new Attention.ToneProfile(1760, 80),
                new Attention.ToneProfile(2093, 110),
                new Attention.ToneProfile(2349, 110),
                new Attention.ToneProfile(2637, 180)
            ] as Array<Attention.ToneProfile>;
        }
        if (step == 6) {
            return [                                    // bright chirps
                new Attention.ToneProfile(2093, 80),
                new Attention.ToneProfile(2349, 80),
                new Attention.ToneProfile(2637, 110),
                new Attention.ToneProfile(2349, 80),
                new Attention.ToneProfile(2637, 110),
                new Attention.ToneProfile(2794, 110),
                new Attention.ToneProfile(3136, 120),
                new Attention.ToneProfile(3520, 180)
            ] as Array<Attention.ToneProfile>;
        }
        if (step == 7) {
            return [                                    // insistent chirps
                new Attention.ToneProfile(2349, 80),
                new Attention.ToneProfile(2637, 80),
                new Attention.ToneProfile(3136, 110),
                new Attention.ToneProfile(2637, 80),
                new Attention.ToneProfile(3136, 110),
                new Attention.ToneProfile(3520, 120),
                new Attention.ToneProfile(3951, 140),
                new Attention.ToneProfile(3520, 220)
            ] as Array<Attention.ToneProfile>;
        }
        return [                                        // full strength: trill
            new Attention.ToneProfile(2637, 90),
            new Attention.ToneProfile(3136, 90),
            new Attention.ToneProfile(2637, 90),
            new Attention.ToneProfile(3136, 90),
            new Attention.ToneProfile(3520, 90),
            new Attention.ToneProfile(3951, 110),
            new Attention.ToneProfile(3520, 110),
            new Attention.ToneProfile(4186, 300)
        ] as Array<Attention.ToneProfile>;
    }

    //! Built-in tone per step, for devices without custom tones: by the
    //! display phase of the step.
    private function getToneForStep(step as Number) as Attention.Tone {
        var phase = displayPhase(pctOfStep(step));
        if (phase <= 1) { return Attention.TONE_ALERT_LO; }
        if (phase == 2) { return Attention.TONE_ALERT_HI; }
        return Attention.TONE_ALARM;
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

    //! Steps the thresholds resolve to.
    (:debug)
    function testToneFromStep() as Number { return firstStepAtLeast(TONE_FROM_PCT); }

    (:debug)
    function testBacklightFromStep() as Number { return firstStepAtLeast(BACKLIGHT_FROM_PCT); }

    (:debug)
    function testDozeStartStep() as Number { return firstStepAtLeast(DOZE_START_PCT); }

    (:debug)
    function testNudgeStep() as Number { return firstStepAtLeast(NUDGE_PCT); }

    //! Step of the ring that fired last (-1 before the first ring).
    (:debug)
    function testGetLastRingStep() as Number {
        return (_ringsFired == 0 || _ringCount == 0) ? -1 : stepOfRing(_ringCount - 1);
    }

    (:debug)
    function testGetVibrateCount() as Number { return _vibrateCount; }

    (:debug)
    function testGetToneCount() as Number { return _toneCount; }

    (:debug)
    function testGetMelodiesStarted() as Number { return _melodiesStarted; }

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

    (:debug)
    function testSetAlarmType(type as Number) as Void { _alarmType = type; }

    //! Simulate a device (or watch setting) without vibration / without tones.
    (:debug)
    function testForceChannelsUnavailable(noVibe as Boolean, noTone as Boolean) as Void {
        _forceNoVibe = noVibe;
        _forceNoTone = noTone;
    }

    (:debug)
    function testGetVibePattern(step as Number) as Array<Attention.VibeProfile> { return getVibePattern(step); }

    (:debug)
    function testGetToneProfile(step as Number) as Array<Attention.ToneProfile> { return getToneProfile(step); }

    (:debug)
    function testGetToneForStep(step as Number) as Attention.Tone { return getToneForStep(step); }
}

//! When the last melody started and how long it lasts. Module-level: there
//! is one speaker, whichever AlarmManager started the melody.
module ToneClock {

    var startMs as Number = 0;
    var lengthMs as Number = 0;         // 0: nothing started yet

    function started(length as Number) as Void {
        startMs = System.getTimer();
        lengthMs = length;
    }

    //! A melody started less than its length ago. The difference of two
    //! System.getTimer() values stays correct across its 32-bit wrap.
    function isPlaying() as Boolean {
        if (lengthMs <= 0) {
            return false;
        }
        var elapsed = System.getTimer() - startMs;
        return elapsed >= 0 && elapsed < lengthMs;
    }
}
