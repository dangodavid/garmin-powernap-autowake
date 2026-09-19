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
//! Key codes (Connect IQ InputDelegate):
//!   KEY_ENTER  - START / select button
//!   KEY_ESC    - BACK button. Some touch devices also send KEY_ESC for a right
//!                swipe that starts at the left edge; every other right swipe
//!                arrives in onSwipe(), and an unhandled one is the system back
//!                gesture, which would close the app (and with it the alarm).
//!   KEY_UP / KEY_DOWN - the UP and DOWN buttons
//! Physical positions differ between product lines (on a 5-button fenix,
//! START is top-right and BACK bottom-right), so no code here depends on them.
//!
//! Safety: once a nap is running, nothing stops it or its alarm by accident.
//! A wrist on a pillow can press a button and a sleeve can touch the screen:
//! * stopping the nap or the alarm needs two presses within 4 seconds
//!   (BACK, or START on the alarm screen);
//! * UP, DOWN and START during a nap only "peek": a few seconds of the
//!   so-far card (time asleep, wakes, alarm time), nothing stops;
//! * taps, swipes, holds, flicks and drags are consumed on every nap screen,
//!   including the alarm, so no gesture reaches system navigation;
//! * every other key is consumed too;
//! * for 2.5 s after a confirmed stop or a screen change every press is
//!   ignored (each ignored press extends it), so a burst of presses cannot
//!   run on into the next screen;
//! * in Stay Awake mode a button press counts as proof of being awake.
//!
//! The logic lives in handleKey()/handleTap() so tests can drive it without
//! constructing system input events.
class PowerNapDelegate extends WatchUi.InputDelegate {

    private var _view     as PowerNapView;
    private var _detector as SleepDetector;
    private var _alarm    as AlarmManager;
    private var _exitEnabled as Boolean = true;   // tests switch System.exit() off

    function initialize(view as PowerNapView, detector as SleepDetector, alarm as AlarmManager) {
        InputDelegate.initialize();
        _view     = view;
        _detector = detector;
        _alarm    = alarm;
    }

    // -- Touch: tap with coordinates ------------------------------------

    function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        return handleTap(clickEvent.getCoordinates()[1]);
    }

    //! A tap at height y. Start screen: tap zones; nap and alarm: ignored.
    function handleTap(y as Number) as Boolean {
        if (_view.isInputLocked()) {
            return true;
        }
        if (!_view.isStarted()) {
            var action = _view.tapActionAt(y);
            if (action > 0) {
                _view.adjustDuration(5);
            } else if (action < 0) {
                _view.adjustDuration(-5);
            } else {
                _view.startNap();
            }
            return true;
        }
        if (_detector.getState() == SleepDetector.STATE_SUMMARY) {
            return false;
        }
        // Nap or alarm running: taps never act.
        return true;
    }

    // -- Other touch gestures -------------------------------------------

    //! True while a nap or its alarm is running: gestures must not act.
    private function napActive() as Boolean {
        return _view.isStarted() && _detector.getState() != SleepDetector.STATE_SUMMARY;
    }

    //! A right swipe that does not start at the left edge arrives here; left
    //! unhandled it becomes the system back action and exits the app.
    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return napActive();
    }

    function onHold(clickEvent as WatchUi.ClickEvent) as Boolean {
        return napActive();
    }

    function onFlick(flickEvent as WatchUi.FlickEvent) as Boolean {
        return napActive();
    }

    function onDrag(dragEvent as WatchUi.DragEvent) as Boolean {
        return napActive();
    }

    // -- Physical buttons -----------------------------------------------

    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        return handleKey(keyEvent.getKey());
    }

    //! One button press (a WatchUi.KEY_* value).
    function handleKey(key as Number) as Boolean {
        if (_view.isInputLocked()) {
            // Presses that keep coming right after a stop or a screen change:
            // ignored, and the lock lasts until they stop for a moment.
            _view.lockInput();
            return true;
        }
        var state = _detector.getState();

        // -- Start screen ----------------------------------------------
        if (!_view.isStarted()) {
            if (key == WatchUi.KEY_UP) {
                _view.adjustDuration(5);
                return true;
            }
            if (key == WatchUi.KEY_DOWN) {
                _view.adjustDuration(-5);
                return true;
            }
            if (key == WatchUi.KEY_ENTER) {
                _view.startNap();
                return true;
            }
            if (key == WatchUi.KEY_ESC) {
                exitApp();
                return true;
            }
            return false;
        }

        // -- Alarm: BACK or START twice stops it --------------------------
        if (state == SleepDetector.STATE_ALARM) {
            if (key == WatchUi.KEY_ESC || key == WatchUi.KEY_ENTER) {
                if (_view.pressStop(ConfirmPress.CONTEXT_ALARM)) {
                    dismissAlarm();
                }
            }
            return true;
        }

        // -- Summary: BACK exits, START sets up a new nap ------------------
        if (state == SleepDetector.STATE_SUMMARY) {
            if (key == WatchUi.KEY_ESC) {
                exitApp();
                return true;
            }
            if (key == WatchUi.KEY_ENTER) {
                _view.resetToStart();
                _view.lockInput();
                return true;
            }
            return false;
        }

        // -- Active nap (CALIBRATING / MONITORING / SLEEPING) ------------
        if (_detector.isStayAwake()
            && (key == WatchUi.KEY_ESC || key == WatchUi.KEY_UP || key == WatchUi.KEY_DOWN || key == WatchUi.KEY_ENTER)) {
            // Stay Awake: a press is proof of being awake (it also answers
            // the "Stay alert!" nudge), so the still run starts over.
            _detector.noteUserAwake();
        }
        if (key == WatchUi.KEY_ESC) {
            if (_view.pressStop(ConfirmPress.CONTEXT_NAP)) {
                if (_detector.hasSleptAtLeastOnce() || _detector.isStayAwake()) {
                    // Something to report: stop and show the summary.
                    _detector.cancel();
                    _alarm.stop();
                    WatchUi.requestUpdate();
                } else {
                    // Nothing recorded yet: back to the start screen so the
                    // user can adjust the duration and try again.
                    _view.resetToStart();
                }
                _view.lockInput();
            }
        } else if (key == WatchUi.KEY_UP || key == WatchUi.KEY_DOWN || key == WatchUi.KEY_ENTER) {
            _view.showPeek();
        }
        return true;
    }

    // -- Private helpers ------------------------------------------------

    //! Stop the ringing. A nap then shows its summary; Stay Awake mode goes
    //! back on guard.
    private function dismissAlarm() as Void {
        _alarm.stop();
        _detector.dismissAlarm();
        _view.lockInput();
        WatchUi.requestUpdate();
    }

    private function exitApp() as Void {
        _detector.stop();
        _alarm.stop();
        if (_exitEnabled) {
            System.exit();
        }
    }

    // -- Test hooks (debug builds only) -----------------------------------

    //! Keep BACK on the start screen and summary from ending the test run.
    (:debug)
    function testDisableExit() as Void {
        _exitEnabled = false;
    }
}
