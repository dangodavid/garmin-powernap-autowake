import Toybox.Attention;
import Toybox.Timer;
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Manages the nap alarm using a four-phase intensity escalation.
//! Each phase runs for 4 rings before the repeat interval tightens
//! and vibration strength increases.
//!
//! Phase 0  (rings  0-3,  t =  0-27 s, 9 s apart): 15% intensity, 2 x 80 ms
//! Phase 1  (rings  4-7,  t = 34-55 s, 7 s apart): 30% intensity, 3 x 120 ms
//! Phase 2  (rings  8-11, t = 61-79 s, 6 s apart): 65% intensity, 3 x 200 ms
//! Phase 3  (rings 12-47, t = 84-259 s, 5 s apart): 100% intensity, 3 x 300 ms
//! Phase 4  (rings 48+,   t = 289 s+,  30 s apart): same full burst, slower
//!
//! Full intensity is reached 84 seconds after the first ring. After three
//! minutes at full intensity nobody is going to wake from the next burst
//! five seconds later (a watch left on the nightstand), so the alarm keeps
//! ringing every 30 s until dismissed instead of draining the battery. The
//! screen shows phases 3 and 4 as "4/4".
//!
//! Tones: Connect IQ can neither play audio files nor set the volume, so the
//! "nature" tone is a ToneProfile melody per phase: a low, soft "coo-coo"
//! first, then bird chirps, then a trill. It escalates in pitch (small
//! buzzers get louder towards their 2-4 kHz resonance), length and number of
//! notes. With "Vibration + Tone" the vibration starts the wake-up alone and
//! the birds join from phase 2.
//!
//! Output channel: the configured alarm type is a preference, never a reason
//! to stay silent. If the preferred channel is unsupported (vivoactive 5/6
//! have no Attention.playTone), switched off in the watch settings
//! (DeviceSettings.vibrateOn / tonesOn) or throws, the other channel is used.
//! An unknown alarmType value behaves like vibration.
//!
//! Display handling: the wake-up is gentle for the eyes too. In phases 0-1
//! the screen stays dark (a raised wrist shows a calm screen); the backlight
//! is first requested at phase 2, and the view only flashes once the rings
//! are at full intensity (isFullIntensity). On AMOLED devices with burn-in
//! protection, Attention.backlight(true) throws once the display has been
//! held on for about a minute. Because rings come every 5-9 s, calling it on
//! every ring would hold the display on continuously and start throwing
//! right when the escalation reaches the perceptible phases. The backlight
//! is therefore requested only on the first two rings from phase 2 and then
//! every 6th, always AFTER the vibration/tone, and in its own try block so a
//! failure can never suppress the alarm itself.
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

    // Number of rings per phase before escalating to the next.
    // Ring 12 (full intensity) fires 3x9 + 4x7 + 4x6 + 5 = 84 s after ring 0.
    private const PHASE0_RINGS = 4;
    private const PHASE1_RINGS = 4;
    private const PHASE2_RINGS = 4;
    private const PHASE3_RINGS = 36;     // 3 minutes at full intensity, 5 s apart
    private const PERSISTENT_PHASE = 4;  // then the same burst every 30 s

    // "Vibration + Tone": the tone joins the vibration from this phase on.
    private const BOTH_TONE_FROM_PHASE = 2;
    // Stay Awake nudge: one burst of this phase (gentle, but noticeable).
    private const NUDGE_PHASE = 1;

    // Backlight from this phase on: on its first rings, then only every Nth
    // ring so the display is never held on continuously.
    private const BACKLIGHT_FROM_PHASE = 2;
    private const BACKLIGHT_INITIAL_RINGS = 2;
    private const BACKLIGHT_EVERY_N_RINGS = 6;

    private var _alarmType   as Number       = ALARM_VIBRATION;
    private var _repeatTimer as Timer.Timer? = null;
    private var _isAlarming  as Boolean      = false;
    private var _ringCount   as Number       = 0;     // index of the next ring (sets its phase)
    private var _ringsFired  as Number       = 0;     // rings since startAlarm
    private var _brightRings as Number       = 0;     // rings fired from BACKLIGHT_FROM_PHASE on
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

    //! Start the escalating alarm. Fires one ring immediately (phase 0),
    //! then schedules repeating ticks whose interval shrinks each phase.
    function startAlarm() as Void {
        startAlarmFromPhase(0);
    }

    //! Start the escalation at the first ring of `phase` (the Stay Awake
    //! doze alarm starts at phase 2: someone who just dozed off at a desk
    //! must notice it at once, not after a minute of feather pulses).
    function startAlarmFromPhase(phase as Number) as Void {
        if (_isAlarming) {
            return;
        }
        _isAlarming = true;
        _ringCount  = firstRingOfPhase(phase);
        _ringsFired = 0;
        _brightRings = 0;
        _vibrateCount = 0;
        _toneCount = 0;
        _backlightCount = 0;

        fireAlarm(); // first ring fires immediately
        restartTimer();
    }

    //! Timer callback. Fires the next ring and, on a phase boundary,
    //! restarts the timer with the interval for the new phase.
    function onRepeatAlarm() as Void {
        if (!_isAlarming) {
            return;
        }

        var phaseBeforeFire = getPhase(_ringCount);
        fireAlarm();
        var phaseAfterFire = getPhase(_ringCount);

        // Crossed a phase boundary -> restart timer with new interval.
        if (phaseAfterFire != phaseBeforeFire) {
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
    //! while. Uses the same channels as the alarm; never while it rings, and
    //! never in a nap session (the quiet onset gate).
    function nudge() as Void {
        if (_isAlarming || !_stayAwake) {
            _blockedDeliveries += 1;
            return;
        }
        _nudgeCount += 1;
        _nudging = true;
        try {
            deliver(NUDGE_PHASE);
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

    //! Current escalation phase for the view, 0-3 (the slower persistent
    //! phase shows as the last one).
    function getCurrentPhase() as Number {
        var p = getPhase(_ringCount);
        return (p > 3) ? 3 : p;
    }

    //! Phase of the ring that fired last, 0-3 (0 before the first ring).
    function getLastRingPhase() as Number {
        if (_ringsFired == 0 || _ringCount == 0) {
            return 0;
        }
        var p = getPhase(_ringCount - 1);
        return (p > 3) ? 3 : p;
    }

    //! The alarm has reached full intensity: the view may flash from now on.
    function isFullIntensity() as Boolean {
        return _isAlarming && getLastRingPhase() >= 3;
    }

    // -- Private helpers -------------------------------------------------

    //! (Re)start the repeat timer with the interval of the next ring's phase.
    private function restartTimer() as Void {
        if (_repeatTimer != null) {
            _repeatTimer.stop();
        }
        try {
            _repeatTimer = new Timer.Timer();
            _repeatTimer.start(method(:onRepeatAlarm), getIntervalForPhase(getPhase(_ringCount)), true);
        } catch (e instanceof Lang.Exception) {
            // Timer limit reached -- the ring already fired, no escalation.
            _repeatTimer = null;
        }
    }

    //! Fire one ring. Vibration and tone come first, each isolated in its own
    //! try block; the backlight request is last and sparse (see class doc).
    private function fireAlarm() as Void {
        var phase = getPhase(_ringCount);
        _ringCount += 1;
        _ringsFired += 1;

        deliver(phase);

        if (phase >= BACKLIGHT_FROM_PHASE) {
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

    //! Vibration and/or tone for one ring of `phase`. The configured type is
    //! a preference, widened when the preferred channel cannot be used.
    private function deliver(phase as Number) as Void {
        if (!outputAllowed()) {
            return;
        }
        var vibeUsable = isVibeUsable();
        var toneUsable = isToneUsable();
        // Preferred channels, widened when the preferred one cannot be heard.
        var tryVibe = (_alarmType != ALARM_TONE) || !toneUsable;
        var tryTone = (_alarmType == ALARM_TONE || _alarmType == ALARM_BOTH) || !vibeUsable;
        if (_alarmType == ALARM_BOTH && vibeUsable && phase < BOTH_TONE_FROM_PHASE) {
            // "Both": the vibration opens the wake-up alone, the birds join later.
            tryTone = false;
        }

        var delivered = false;
        if (tryVibe && doVibrate(phase)) { delivered = true; }
        if (tryTone && doTone(phase)) { delivered = true; }
        if (!delivered) {
            // Every preferred call failed: last resort, try the other one.
            if (!tryVibe) { doVibrate(phase); }
            if (!tryTone) { doTone(phase); }
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
    private function doVibrate(phase as Number) as Boolean {
        if (_forceNoVibe || !(Attention has :vibrate)) {
            return false;
        }
        try {
            Attention.vibrate(getVibePattern(phase));
            _vibrateCount += 1;
            return true;
        } catch (e instanceof Lang.Exception) {
            return false;
        }
    }

    //! One tone (the phase's melody where custom tones exist); true if the
    //! tone channel is sounding for this ring. A melody still playing from
    //! the previous call covers this ring instead of being cut off: rings
    //! are 5-30 s apart and melodies under a second, so this only happens
    //! when rings come back to back (ringNow, tests). Overlapping melodies
    //! also crash the Connect IQ simulator (SDK 9.1).
    private function doTone(phase as Number) as Boolean {
        if (_forceNoTone || !(Attention has :playTone)) {
            return false;
        }
        try {
            if (Attention has :ToneProfile) {
                if (!ToneClock.isPlaying()) {
                    var melody = getToneProfile(phase);
                    Attention.playTone({:toneProfile => melody});
                    ToneClock.started(melodyLengthMs(melody));
                    _melodiesStarted += 1;
                }
            } else {
                Attention.playTone(getToneForPhase(phase));
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

    //! Map ring count to phase index (0-4).
    private function getPhase(ringCount as Number) as Number {
        if (ringCount < PHASE0_RINGS) {
            return 0;
        }
        if (ringCount < PHASE0_RINGS + PHASE1_RINGS) {
            return 1;
        }
        if (ringCount < PHASE0_RINGS + PHASE1_RINGS + PHASE2_RINGS) {
            return 2;
        }
        if (ringCount < PHASE0_RINGS + PHASE1_RINGS + PHASE2_RINGS + PHASE3_RINGS) {
            return 3;
        }
        return PERSISTENT_PHASE;
    }

    //! Index of the first ring of a phase (0-3).
    private function firstRingOfPhase(phase as Number) as Number {
        if (phase <= 0) { return 0; }
        if (phase == 1) { return PHASE0_RINGS; }
        if (phase == 2) { return PHASE0_RINGS + PHASE1_RINGS; }
        return PHASE0_RINGS + PHASE1_RINGS + PHASE2_RINGS;
    }

    //! Repeat interval (ms) for each phase.
    private function getIntervalForPhase(phase as Number) as Number {
        if (phase == 0) { return 9000; }
        if (phase == 1) { return 7000; }
        if (phase == 2) { return 6000; }
        if (phase == 3) { return 5000; }
        return 30000;
    }

    //! Vibration pattern for each phase (0-3; the persistent phase repeats 3).
    //! Note: Forerunner devices ignore the intensity and run every pulse at
    //! the same duty cycle, so escalation there is by pulse length only.
    private function getVibePattern(phase as Number) as Array<Attention.VibeProfile> {
        if (phase == 0) {
            return [
                new Attention.VibeProfile(15,  80),
                new Attention.VibeProfile(0,  500),
                new Attention.VibeProfile(15,  80)
            ] as Array<Attention.VibeProfile>;
        }
        if (phase == 1) {
            return [
                new Attention.VibeProfile(30, 120),
                new Attention.VibeProfile(0,  350),
                new Attention.VibeProfile(30, 120),
                new Attention.VibeProfile(0,  350),
                new Attention.VibeProfile(30, 120)
            ] as Array<Attention.VibeProfile>;
        }
        if (phase == 2) {
            return [
                new Attention.VibeProfile(65, 200),
                new Attention.VibeProfile(0,  220),
                new Attention.VibeProfile(65, 200),
                new Attention.VibeProfile(0,  220),
                new Attention.VibeProfile(65, 200)
            ] as Array<Attention.VibeProfile>;
        }
        // Phase 3 and the persistent phase - full intensity
        return [
            new Attention.VibeProfile(100, 300),
            new Attention.VibeProfile(0,   150),
            new Attention.VibeProfile(100, 300),
            new Attention.VibeProfile(0,   150),
            new Attention.VibeProfile(100, 300)
        ] as Array<Attention.VibeProfile>;
    }

    //! Birdsong-like melody per phase (see class doc). Each is far shorter
    //! than the ring interval, so melodies never overlap.
    private function getToneProfile(phase as Number) as Array<Attention.ToneProfile> {
        if (phase == 0) {
            // Distant "coo-coo": low and short, the quietest a buzzer gets.
            return [
                new Attention.ToneProfile(587, 140),
                new Attention.ToneProfile(494, 200)
            ] as Array<Attention.ToneProfile>;
        }
        if (phase == 1) {
            // A rising chirp that repeats its last two notes.
            return [
                new Attention.ToneProfile(1319, 60),
                new Attention.ToneProfile(1568, 60),
                new Attention.ToneProfile(1760, 90),
                new Attention.ToneProfile(1568, 60),
                new Attention.ToneProfile(1760, 110)
            ] as Array<Attention.ToneProfile>;
        }
        if (phase == 2) {
            // Two higher chirps.
            return [
                new Attention.ToneProfile(2093, 60),
                new Attention.ToneProfile(2349, 60),
                new Attention.ToneProfile(2637, 100),
                new Attention.ToneProfile(2349, 60),
                new Attention.ToneProfile(2637, 60),
                new Attention.ToneProfile(3136, 120)
            ] as Array<Attention.ToneProfile>;
        }
        // Phase 3 and the persistent phase: a trill near the buzzer resonance.
        return [
            new Attention.ToneProfile(2637, 70),
            new Attention.ToneProfile(3136, 70),
            new Attention.ToneProfile(2637, 70),
            new Attention.ToneProfile(3136, 70),
            new Attention.ToneProfile(3520, 70),
            new Attention.ToneProfile(3136, 70),
            new Attention.ToneProfile(3520, 70),
            new Attention.ToneProfile(3951, 160)
        ] as Array<Attention.ToneProfile>;
    }

    //! Built-in tone per phase, for devices without custom tones.
    private function getToneForPhase(phase as Number) as Attention.Tone {
        if (phase <= 1) { return Attention.TONE_ALERT_LO; }
        if (phase == 2) { return Attention.TONE_ALERT_HI; }
        return Attention.TONE_ALARM;
    }

    // -- Test hooks (debug builds only) -----------------------------------

    (:debug)
    function testGetRingCount() as Number { return _ringCount; }

    (:debug)
    function testGetRingsFired() as Number { return _ringsFired; }

    (:debug)
    function testGetPhaseForRing(ringCount as Number) as Number { return getPhase(ringCount); }

    (:debug)
    function testGetIntervalForPhase(phase as Number) as Number { return getIntervalForPhase(phase); }

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
    function testGetVibePattern(phase as Number) as Array<Attention.VibeProfile> { return getVibePattern(phase); }

    (:debug)
    function testGetToneProfile(phase as Number) as Array<Attention.ToneProfile> { return getToneProfile(phase); }

    (:debug)
    function testGetToneForPhase(phase as Number) as Attention.Tone { return getToneForPhase(phase); }
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
