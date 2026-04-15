import Toybox.Attention;
import Toybox.Timer;
import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! Manages the nap alarm using a four-phase intensity escalation.
//! Each phase runs for 4 rings before the repeat interval tightens
//! and vibration strength increases.
//!
//! Phase 0  (rings  0-3,  9 s apart, ~36 s): 15% intensity, 2 x 80 ms
//! Phase 1  (rings  4-7,  7 s apart, ~28 s): 30% intensity, 3 x 120 ms
//! Phase 2  (rings  8-11, 6 s apart, ~24 s): 65% intensity, 3 x 200 ms
//! Phase 3  (rings 12+,   5 s apart):        100% intensity, 3 x 300 ms
//!
//! Full intensity is reached after approximately 88 seconds.
class AlarmManager {

    // Alarm type constants matching settings values
    enum {
        ALARM_VIBRATION = 0,
        ALARM_TONE      = 1,
        ALARM_BOTH      = 2
    }

    // Number of rings per phase before escalating to the next.
    // 4 rings × (9 + 7 + 6) s = 88 s until full intensity.
    private const PHASE0_RINGS = 4;
    private const PHASE1_RINGS = 4;
    private const PHASE2_RINGS = 4;

    private var _alarmType  as Number        = ALARM_VIBRATION;
    private var _repeatTimer as Timer.Timer? = null;
    private var _isAlarming  as Boolean      = false;
    private var _ringCount   as Number       = 0;

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

    //! Stop the alarm and reset state for the next session.
    function stop() as Void {
        _isAlarming = false;
        _ringCount  = 0;
        if (_repeatTimer != null) {
            _repeatTimer.stop();
            _repeatTimer = null;
        }
    }

    // -- Private helpers -------------------------------------------------

    //! Fire one ring: wake the display, then play vibration and/or tone.
    //! Wrapped in try/catch because Attention APIs can throw on some
    //! devices when called from a timer callback context.
    private function fireAlarm() as Void {
        var phase = getPhase(_ringCount);
        _ringCount += 1;

        try {
            // Force the display on so the WAKE UP screen is visible even in
            // DND/sleep mode where the AMOLED display is completely off.
            if (Attention has :backlight) {
                Attention.backlight(true);
            }

            if (_alarmType == ALARM_VIBRATION || _alarmType == ALARM_BOTH) {
                if (Attention has :vibrate) {
                    Attention.vibrate(getVibePattern(phase));
                }
            }

            if (_alarmType == ALARM_TONE || _alarmType == ALARM_BOTH) {
                if (Attention has :playTone) {
                    Attention.playTone(getToneForPhase(phase));
                }
            }
        } catch (e instanceof Lang.Exception) {
            // Attention API failed -- swallow so the alarm loop keeps running
            // and the WAKE UP screen still displays.
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

    //! Vibration pattern for each phase.
    //!
    //! Returns the vibration pattern for the given phase (0-3).
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

    //! Expose alarm state for test assertions.
    (:debug)
    function isAlarming() as Boolean {
        return _isAlarming;
    }

    //! Expose ring count for phase-escalation test assertions.
    (:debug)
    function testGetRingCount() as Number {
        return _ringCount;
    }

    //! Expose computed phase for a given ring count.
    (:debug)
    function testGetPhaseForRing(ringCount as Number) as Number {
        return getPhase(ringCount);
    }
}
