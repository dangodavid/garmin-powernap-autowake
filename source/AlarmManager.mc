using Toybox.Attention;
using Toybox.Timer;
using Toybox.Application;
using Toybox.Lang;
using Toybox.WatchUi;

//! Manages the nap alarm — vibration patterns, optional tone playback, and
//! repeated alarm firing until the user dismisses it.
class AlarmManager {

    // Alarm type constants matching settings values
    enum {
        ALARM_VIBRATION = 0,
        ALARM_TONE = 1,
        ALARM_BOTH = 2
    }

    private var _alarmType as Number = ALARM_VIBRATION;
    private var _repeatTimer as Timer.Timer?;
    private var _isAlarming as Boolean = false;

    function initialize() {
        loadSettings();
    }

    //! Reload alarm type from application properties.
    function loadSettings() as Void {
        var val = Application.Properties.getValue("alarmType");
        if (val != null && val instanceof Number) {
            _alarmType = val as Number;
        }
    }

    //! Starts the alarm. Fires immediately, then repeats every 10 seconds
    //! until stop() is called.
    function startAlarm() as Void {
        if (_isAlarming) {
            return;
        }
        _isAlarming = true;
        fireAlarm();

        // Repeat alarm every 10 seconds
        _repeatTimer = new Timer.Timer();
        _repeatTimer.start(method(:onRepeatAlarm), 10000, true);
    }

    //! Timer callback for repeating the alarm.
    function onRepeatAlarm() as Void {
        if (_isAlarming) {
            fireAlarm();
            WatchUi.requestUpdate();
        }
    }

    //! Fires a single alarm burst (vibration and/or tone).
    private function fireAlarm() as Void {
        // Vibration
        if (_alarmType == ALARM_VIBRATION || _alarmType == ALARM_BOTH) {
            if (Attention has :vibrate) {
                var vibePattern = [
                    new Attention.VibeProfile(100, 1000),
                    new Attention.VibeProfile(0, 500),
                    new Attention.VibeProfile(100, 1000),
                    new Attention.VibeProfile(0, 500),
                    new Attention.VibeProfile(100, 2000)
                ] as Array<Attention.VibeProfile>;
                Attention.vibrate(vibePattern);
            }
        }

        // Tone
        if (_alarmType == ALARM_TONE || _alarmType == ALARM_BOTH) {
            if (Attention has :playTone) {
                Attention.playTone(Attention.TONE_ALARM);
            }
        }
    }

    //! Give a short confirmation vibration (e.g. when sleep is first detected).
    function confirmVibration() as Void {
        if (Attention has :vibrate) {
            var vibePattern = [
                new Attention.VibeProfile(50, 200),
                new Attention.VibeProfile(0, 100),
                new Attention.VibeProfile(50, 200)
            ] as Array<Attention.VibeProfile>;
            Attention.vibrate(vibePattern);
        }
    }

    //! Returns true if the alarm is currently active.
    function isAlarming() as Boolean {
        return _isAlarming;
    }

    //! Stop the alarm and release the repeat timer.
    function stop() as Void {
        _isAlarming = false;
        if (_repeatTimer != null) {
            _repeatTimer.stop();
            _repeatTimer = null;
        }
    }
}
