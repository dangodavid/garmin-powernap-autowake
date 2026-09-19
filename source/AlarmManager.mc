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
//! Phase 3  (rings 12+,   t = 84 s+,   5 s apart): 100% intensity, 3 x 300 ms
//!
//! Full intensity is reached 84 seconds after the first ring.
//!
//! Output channel: the configured alarm type is a preference, never a reason
//! to stay silent. If the preferred channel is unsupported (vivoactive 5/6
//! have no Attention.playTone), switched off in the watch settings
//! (DeviceSettings.vibrateOn / tonesOn) or throws, the other channel is used.
//! An unknown alarmType value behaves like vibration.
//!
//! Display handling: on AMOLED devices with burn-in protection,
//! Attention.backlight(true) throws once the display has been held on for
//! about a minute. Because rings come every 5-9 s, calling it on every ring
//! would hold the display on continuously and start throwing right when
//! the escalation reaches the perceptible phases. The backlight is therefore
//! requested only on a few rings, always AFTER the vibration/tone, and in
//! its own try block so a failure can never suppress the alarm itself.
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

    // Backlight on the first rings, then only every Nth ring so the
    // display is never held on continuously.
    private const BACKLIGHT_INITIAL_RINGS = 2;
    private const BACKLIGHT_EVERY_N_RINGS = 6;

    private var _alarmType   as Number       = ALARM_VIBRATION;
    private var _repeatTimer as Timer.Timer? = null;
    private var _isAlarming  as Boolean      = false;
    private var _ringCount   as Number       = 0;

    // Diagnostics (read by tests; cheap enough to keep in release)
    private var _vibrateCount   as Number  = 0;
    private var _toneCount      as Number  = 0;
    private var _backlightCount as Number  = 0;
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
        if (_isAlarming) {
            return;
        }
        _isAlarming = true;
        _ringCount  = 0;
        _vibrateCount = 0;
        _toneCount = 0;
        _backlightCount = 0;

        fireAlarm(); // ring 0  - fires immediately

        try {
            _repeatTimer = new Timer.Timer();
            _repeatTimer.start(method(:onRepeatAlarm), getIntervalForPhase(0), true);
        } catch (e instanceof Lang.Exception) {
            // Timer limit reached -- first ring already fired, but no escalation.
            _repeatTimer = null;
        }
    }

    //! Timer callback. Fires the next ring and, on a phase boundary,
    //! restarts the timer with the tighter interval for the new phase.
    function onRepeatAlarm() as Void {
        if (!_isAlarming) {
            return;
        }

        var phaseBeforeFire = getPhase(_ringCount);
        fireAlarm();
        var phaseAfterFire = getPhase(_ringCount);

        // Crossed a phase boundary -> restart timer with new interval.
        if (phaseAfterFire != phaseBeforeFire) {
            if (_repeatTimer != null) {
                _repeatTimer.stop();
            }
            try {
                _repeatTimer = new Timer.Timer();
                _repeatTimer.start(
                    method(:onRepeatAlarm),
                    getIntervalForPhase(phaseAfterFire),
                    true
                );
            } catch (e instanceof Lang.Exception) {
                // Timer limit -- alarm stays at current phase interval.
                _repeatTimer = null;
            }
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
        if (_repeatTimer != null) {
            _repeatTimer.stop();
        }
        try {
            _repeatTimer = new Timer.Timer();
            _repeatTimer.start(method(:onRepeatAlarm), getIntervalForPhase(getPhase(_ringCount)), true);
        } catch (e instanceof Lang.Exception) {
            _repeatTimer = null;
        }
        WatchUi.requestUpdate();
    }

    //! Stop the alarm and reset state for the next session.
    function stop() as Void {
        _isAlarming = false;
        _ringCount  = 0;
        if (_repeatTimer != null) {
            _repeatTimer.stop();
            _repeatTimer = null;
        }
    }

    function isAlarming() as Boolean {
        return _isAlarming;
    }

    //! Current escalation phase (0-3) for the view.
    function getCurrentPhase() as Number {
        return getPhase(_ringCount);
    }

    // -- Private helpers -------------------------------------------------

    //! Fire one ring. Vibration and tone come first, each isolated in its own
    //! try block; the backlight request is last and sparse (see class doc).
    private function fireAlarm() as Void {
        var ring  = _ringCount;
        var phase = getPhase(ring);
        _ringCount += 1;

        var vibeUsable = isVibeUsable();
        var toneUsable = isToneUsable();
        // Preferred channels, widened when the preferred one cannot be heard.
        var tryVibe = (_alarmType != ALARM_TONE) || !toneUsable;
        var tryTone = (_alarmType == ALARM_TONE || _alarmType == ALARM_BOTH) || !vibeUsable;

        var delivered = false;
        if (tryVibe && doVibrate(phase)) { delivered = true; }
        if (tryTone && doTone(phase)) { delivered = true; }
        if (!delivered) {
            // Every preferred call failed: last resort, try the other one.
            if (!tryVibe) { doVibrate(phase); }
            if (!tryTone) { doTone(phase); }
        }

        if (ring < BACKLIGHT_INITIAL_RINGS || (ring % BACKLIGHT_EVERY_N_RINGS) == 0) {
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

    //! One tone; true if the call went through.
    private function doTone(phase as Number) as Boolean {
        if (_forceNoTone || !(Attention has :playTone)) {
            return false;
        }
        try {
            Attention.playTone(getToneForPhase(phase));
            _toneCount += 1;
            return true;
        } catch (e instanceof Lang.Exception) {
            return false;
        }
    }

    //! Map ring count to phase index (0–3).
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
        return 3;
    }

    //! Repeat interval (ms) for each phase.
    private function getIntervalForPhase(phase as Number) as Number {
        if (phase == 0) { return 9000; }
        if (phase == 1) { return 7000; }
        if (phase == 2) { return 6000; }
        return 5000;
    }

    //! Vibration pattern for each phase (0-3).
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
        // Phase 3  - full intensity
        return [
            new Attention.VibeProfile(100, 300),
            new Attention.VibeProfile(0,   150),
            new Attention.VibeProfile(100, 300),
            new Attention.VibeProfile(0,   150),
            new Attention.VibeProfile(100, 300)
        ] as Array<Attention.VibeProfile>;
    }

    //! Returns the tone for the given phase (0-3), escalating from quiet to full alarm.
    private function getToneForPhase(phase as Number) as Attention.Tone {
        if (phase <= 1) { return Attention.TONE_ALERT_LO; }
        if (phase == 2) { return Attention.TONE_ALERT_HI; }
        return Attention.TONE_ALARM;
    }

    // -- Test hooks (debug builds only) -----------------------------------

    (:debug)
    function testGetRingCount() as Number { return _ringCount; }

    (:debug)
    function testGetPhaseForRing(ringCount as Number) as Number { return getPhase(ringCount); }

    (:debug)
    function testGetIntervalForPhase(phase as Number) as Number { return getIntervalForPhase(phase); }

    (:debug)
    function testGetVibrateCount() as Number { return _vibrateCount; }

    (:debug)
    function testGetToneCount() as Number { return _toneCount; }

    (:debug)
    function testGetBacklightCount() as Number { return _backlightCount; }

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
    function testGetToneForPhase(phase as Number) as Attention.Tone { return getToneForPhase(phase); }
}
