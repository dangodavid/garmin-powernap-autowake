import Toybox.WatchUi;
import Toybox.Lang;
import Toybox.System;

//! Input handler for Power Nap Auto-Wake.
//!
//! Extends InputDelegate (NOT BehaviorDelegate) so that touchscreen taps
//! arrive in onTap() with their actual [x, y] coordinates.
//!
//! On Fenix 8, BehaviorDelegate intercepts every screen tap and fires
//! onSelect()  - losing the coordinates entirely.  InputDelegate receives
//! the raw ClickEvent before any such mapping, giving us full tap-zone
//! control on the start screen.
//!
//! Physical button key codes on Fenix 8 (Connect IQ InputDelegate):
//!   KEY_UP     - UP / LIGHT button  (top-right)
//!   KEY_DOWN   - DOWN button         (bottom-right)
//!   KEY_ENTER  - START / SELECT      (middle-right, green)
//!   KEY_ESC    - BACK                (top-left)
//!   KEY_LAP    - LAP / RESET         (bottom-left)
class PowerNapDelegate extends WatchUi.InputDelegate {

    private var _view     as PowerNapView;
    private var _detector as SleepDetector;
    private var _alarm    as AlarmManager;

    function initialize(view as PowerNapView, detector as SleepDetector, alarm as AlarmManager) {
        InputDelegate.initialize();
        _view     = view;
        _detector = detector;
        _alarm    = alarm;
    }

    // -- Touch: tap with coordinates ------------------------------------

    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        if (!_view.isStarted()) {
            var y       = clickEvent.getCoordinates()[1];
            var screenH = System.getDeviceSettings().screenHeight;
            // Start screen tap zones (match drawStartScreen layout):
            //   top 35 %    -> up-arrow area    -> +5 min
            //   middle 30 % -> duration / label -> start nap
            //   bottom 35 % -> down-arrow area  -> -5 min
            if (y < screenH * 35 / 100) {
                _view.adjustDuration(5);
            } else if (y > screenH * 65 / 100) {
                _view.adjustDuration(-5);
            } else {
                _view.startNap();
            }
            return true;
        }
        if (_detector.getState() == SleepDetector.STATE_ALARM) {
            dismissAlarm();
            return true;
        }
        return false;
    }

    // -- Physical buttons -----------------------------------------------

    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key   = keyEvent.getKey();
        var state = _detector.getState();

        // -- Start screen ----------------------------------------------
        if (!_view.isStarted()) {
            // UP button (top-right) -> increment duration
            if (key == WatchUi.KEY_UP) {
                _view.adjustDuration(5);
                return true;
            }
            // DOWN button (bottom-right) -> decrement duration
            if (key == WatchUi.KEY_DOWN) {
                _view.adjustDuration(-5);
                return true;
            }
            // START / SELECT (green) -> start nap
            if (key == WatchUi.KEY_ENTER) {
                _view.startNap();
                return true;
            }
            // BACK -> exit app
            if (key == WatchUi.KEY_ESC) {
                System.exit();
            }
            return false;
        }

        // -- Active / post-nap screens ---------------------------------
        if (key == WatchUi.KEY_ESC) {
            if (state == SleepDetector.STATE_CALIBRATING ||
                state == SleepDetector.STATE_MONITORING) {
                // No sleep recorded yet  - go back to the start screen so
                // the user can adjust the duration and try again.
                _view.resetToStart();
            } else if (state == SleepDetector.STATE_ALARM) {
                dismissAlarm();
            } else if (state == SleepDetector.STATE_SUMMARY ||
                       state == SleepDetector.STATE_TIMEOUT) {
                exitApp();
            } else {
                // SLEEPING: cancel and show summary.
                _detector.cancel();
                WatchUi.requestUpdate();
            }
            return true;
        }

        if (key == WatchUi.KEY_ENTER &&
            state == SleepDetector.STATE_ALARM) {
            dismissAlarm();
            return true;
        }

        return false;
    }

    // -- Private helpers ------------------------------------------------

    private function dismissAlarm() as Void {
        _alarm.stop();
        _detector.finishNap();
        _view.resetAlarmFlag();
        WatchUi.requestUpdate();
    }

    private function exitApp() as Void {
        _detector.stop();
        _alarm.stop();
        System.exit();
    }
}
