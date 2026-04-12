using Toybox.WatchUi;
using Toybox.Lang;
using Toybox.System;

//! Input delegate that handles physical button presses and touch events.
//! Behavior varies depending on the current sleep-detector state:
//!   - Alarm state:  any key dismisses the alarm and shows the summary.
//!   - Summary/Timeout: BACK exits the application.
//!   - All other states: BACK cancels/exits.
class PowerNapDelegate extends WatchUi.BehaviorDelegate {

    private var _view as PowerNapView;
    private var _detector as SleepDetector;
    private var _alarm as AlarmManager;

    function initialize(view as PowerNapView, detector as SleepDetector, alarm as AlarmManager) {
        BehaviorDelegate.initialize();
        _view = view;
        _detector = detector;
        _alarm = alarm;
    }

    //! Any key press during the alarm state dismisses it.
    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var state = _detector.getState();

        if (state == SleepDetector.STATE_ALARM) {
            dismissAlarm();
            return true;
        }
        return false; // Let the system handle other key events
    }

    //! BACK button behavior:
    //!   Alarm   → dismiss alarm
    //!   Summary → exit app
    //!   Timeout → exit app
    //!   Others  → cancel and exit
    function onBack() as Boolean {
        var state = _detector.getState();

        if (state == SleepDetector.STATE_ALARM) {
            dismissAlarm();
            return true;
        }

        if (state == SleepDetector.STATE_SUMMARY || state == SleepDetector.STATE_TIMEOUT) {
            exitApp();
            return true;
        }

        // Calibrating, Monitoring, or Sleeping — cancel and exit
        _detector.stop();
        _alarm.stop();
        exitApp();
        return true;
    }

    //! Tap / touch anywhere also dismisses the alarm.
    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        var state = _detector.getState();
        if (state == SleepDetector.STATE_ALARM) {
            dismissAlarm();
            return true;
        }
        return false;
    }

    //! SELECT / ENTER button during alarm also dismisses.
    function onSelect() as Boolean {
        var state = _detector.getState();
        if (state == SleepDetector.STATE_ALARM) {
            dismissAlarm();
            return true;
        }
        return false;
    }

    //! Stop the alarm, compute summary stats, and request a UI refresh.
    private function dismissAlarm() as Void {
        _alarm.stop();
        _detector.finishNap();
        _view.resetAlarmFlag();
        WatchUi.requestUpdate();
    }

    //! Exit the application cleanly.
    private function exitApp() as Void {
        _detector.stop();
        _alarm.stop();
        System.exit();
    }
}
