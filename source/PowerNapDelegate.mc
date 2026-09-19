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
//! Key model (owner decision, 2026-09-19, revised the same night): BACK is a
//! normal back button. One press goes back one level, down to the start
//! screen, and only there does BACK twice leave the app.
//!
//!   Screen                         BACK               START              UP/DOWN
//!   Start                          x2: exit; 1st:     start nap          +/- 5 min
//!                                  "Press BACK again
//!                                  to exit"
//!     (MENU / long press: menu with "Test alarm"; BACK closes the menu and
//!      ends the preview, back to the start screen)
//!   Nap / peek                     end the nap,       x2: stop, summary  peek card
//!                                  start screen       1st: peek card
//!                                  (no summary)
//!   Stay Awake guard / peek        end, start screen  x2: stop, summary  peek card
//!   Alarm (nap)                    alarm off, start   x2: alarm off,     nothing
//!                                  screen (no summary) summary
//!   Doze alarm (Stay Awake)        alarm off, back    x2: alarm off,     nothing
//!                                  on guard           back on guard
//!   Summary                        start screen       start screen       nothing
//!
//! Only the first BACK on the start screen shows a popup (what the second
//! one does); everywhere else BACK acts at once. A right swipe is the touch
//! BACK: outside a session it acts as BACK (so it never leaves the app in
//! one gesture); during a nap it is ignored.
//!
//! Safety during a nap: a wrist on a pillow can press a button and a sleeve
//! can touch the screen, so
//! * stopping with the stats takes two START presses within 4 seconds
//!   (ConfirmPress CONTEXT_STOP; a BACK in between never completes it);
//! * UP and DOWN (and a single START) during a nap only "peek": a few seconds
//!   of the so-far card, nothing stops;
//! * taps, swipes, holds, flicks and drags are consumed on every nap screen,
//!   including the alarm, so no gesture reaches system navigation;
//! * every other key is consumed too;
//! * for 1.5 s after a stop or a screen change every press is swallowed,
//!   and never extends the lock, so a burst of presses cannot run on into
//!   the next screen (a BACK burst during the nap ends at the start screen,
//!   it never reaches the exit pair) but can never trap the user either;
//! * in Stay Awake mode a button press counts as proof of being awake.
//! BACK itself is deliberately not guarded during a session (owner
//! decision): one press ends the nap or stops the alarm.
//!
//! The logic lives in handleKey()/handleTap() so tests can drive it without
//! constructing system input events.
class PowerNapDelegate extends WatchUi.InputDelegate {

    private var _view     as PowerNapView;
    private var _detector as SleepDetector;
    private var _alarm    as AlarmManager;
    private var _exitEnabled as Boolean = true;   // tests switch System.exit() off
    (:debug) private var _exitRequested as Boolean = false;
    private var _viewsEnabled as Boolean = true;  // tests switch WatchUi.pushView off
    private var _menuRequests as Number = 0;

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

    //! A tap at height y. Start screen: tap zones; nap, alarm and the alarm
    //! preview: ignored.
    function handleTap(y as Number) as Boolean {
        if (_view.isInputLocked() || previewActive()) {
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

    //! True while the alarm preview plays on the start screen: only BACK acts.
    private function previewActive() as Boolean {
        return !_view.isStarted() && _alarm.isPreviewing();
    }

    //! A right swipe that does not start at the left edge arrives here; left
    //! unhandled it becomes the system back action and exits the app.
    function onSwipe(swipeEvent as WatchUi.SwipeEvent) as Boolean {
        return handleSwipe(swipeEvent.getDirection());
    }

    //! A swipe (a WatchUi.SWIPE_* direction). During a nap or its alarm every
    //! swipe is ignored. Elsewhere a right swipe is BACK, handled like the
    //! button, so it goes back one level and the start screen asks for a
    //! second one before leaving the app.
    function handleSwipe(direction as Number) as Boolean {
        if (napActive()) {
            return true;
        }
        if (direction == WatchUi.SWIPE_RIGHT) {
            return handleKey(WatchUi.KEY_ESC);
        }
        return previewActive();
    }

    //! Touch watches: a long press on the number of the start screen opens
    //! the menu (their menu gesture); during a nap or the preview holds are
    //! consumed.
    function onHold(clickEvent as WatchUi.ClickEvent) as Boolean {
        if (!_view.isStarted()) {
            if (!_view.isInputLocked() && !previewActive()
                && _view.tapActionAt(clickEvent.getCoordinates()[1]) == 0) {
                openMenu();
            }
            return true;
        }
        return napActive();
    }

    function onFlick(flickEvent as WatchUi.FlickEvent) as Boolean {
        return napActive() || previewActive();
    }

    function onDrag(dragEvent as WatchUi.DragEvent) as Boolean {
        return napActive() || previewActive();
    }

    // -- Physical buttons -----------------------------------------------

    function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        return handleKey(keyEvent.getKey());
    }

    //! One button press (a WatchUi.KEY_* value).
    function handleKey(key as Number) as Boolean {
        if (_view.isInputLocked()) {
            // Presses that keep coming right after a stop or a screen change
            // are swallowed; the lock ends on its own, whatever is pressed.
            return true;
        }
        var state = _detector.getState();

        // -- Alarm preview ("Test alarm"): BACK ends it, everything else waits
        if (previewActive()) {
            if (key == WatchUi.KEY_ESC) {
                _view.stopPreview();
            }
            return true;
        }

        // -- Start screen ----------------------------------------------
        if (!_view.isStarted()) {
            if (key == WatchUi.KEY_MENU) {
                openMenu();
                return true;
            }
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
                // The start screen is the top: BACK twice leaves the app,
                // the first press says so.
                if (_view.pressConfirm(ConfirmPress.CONTEXT_EXIT)) {
                    exitApp();
                } else {
                    _view.showHint(PowerNapView.HINT_EXIT);
                }
                return true;
            }
            return false;
        }

        // -- Summary: BACK goes back, START sets up a new nap: both lead to
        //    the start screen ---------------------------------------------
        if (state == SleepDetector.STATE_SUMMARY) {
            if (key == WatchUi.KEY_ESC || key == WatchUi.KEY_ENTER) {
                _view.resetToStart();
                _view.lockInput();
                return true;
            }
            return false;
        }

        // -- Nap, Stay Awake guard, peek card, alarm ------------------------
        if (_detector.isStayAwake()
            && (key == WatchUi.KEY_ESC || key == WatchUi.KEY_UP || key == WatchUi.KEY_DOWN || key == WatchUi.KEY_ENTER)) {
            // Stay Awake: a press is proof of being awake (it also answers
            // the "Stay alert!" nudge), so the still run starts over.
            _detector.noteUserAwake();
        }
        if (key == WatchUi.KEY_ESC) {
            // One BACK goes back one level: the doze alarm to the guard,
            // everything else (nap, its alarm, the guard) to the start
            // screen, without a summary (START twice gives the stats).
            goBack(state);
            return true;
        }
        if (key == WatchUi.KEY_ENTER) {
            if (state == SleepDetector.STATE_ALARM) {
                // START twice stops the alarm: a nap shows its summary, the
                // Stay Awake doze alarm goes back on guard.
                if (_view.pressConfirm(ConfirmPress.CONTEXT_STOP)) {
                    dismissAlarm();
                } else {
                    _view.showHint(PowerNapView.HINT_STOP);
                }
            } else {
                // START twice stops the nap and shows the summary; the first
                // press shows the peek card, whose footer says so.
                if (_view.pressConfirm(ConfirmPress.CONTEXT_STOP)) {
                    stopNap();
                } else {
                    _view.showPeek();
                }
            }
            return true;
        }
        if ((key == WatchUi.KEY_UP || key == WatchUi.KEY_DOWN) && state != SleepDetector.STATE_ALARM) {
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

    //! BACK on a session screen: one level back. The Stay Awake doze alarm
    //! sits on top of the guard, so it goes back to guarding; a nap, its
    //! alarm and the guard go back to the start screen (the session ends
    //! there, without a summary: START twice gives the stats).
    private function goBack(state as Number) as Void {
        if (state == SleepDetector.STATE_ALARM && _detector.isStayAwake()) {
            dismissAlarm();
            return;
        }
        _view.resetToStart();
        _view.lockInput();
        WatchUi.requestUpdate();
    }

    //! Stop the running nap (or Stay Awake session) and show its summary.
    private function stopNap() as Void {
        _detector.cancel();
        _alarm.stop();
        _view.lockInput();
        WatchUi.requestUpdate();
    }

    //! The start-screen menu (MENU key, or a long press on a touch screen):
    //! "Test alarm" plays the wake-up ramp once. Never during a nap.
    private function openMenu() as Void {
        _menuRequests += 1;
        _view.cancelConfirm();
        if (!_viewsEnabled) {
            return;
        }
        try {
            var menu = new WatchUi.Menu2({:title => "Power Nap"});
            menu.addItem(new WatchUi.MenuItem("Test alarm", "Feel the wake-up ramp", :testAlarm, null));
            WatchUi.pushView(menu, new PowerNapMenuDelegate(_view), WatchUi.SLIDE_UP);
        } catch (e instanceof Lang.Exception) {
            // No menu on this device: nothing to do.
        }
    }

    //! Leave the app (BACK twice on the start screen).
    private function exitApp() as Void {
        _detector.stop();
        _alarm.stop();
        noteExitRequested();
        if (_exitEnabled) {
            System.exit();
        }
    }

    // Debug builds remember that exitApp() ran, for testExitRequested();
    // release builds have neither the field nor anything to write to it.
    (:debug)
    private function noteExitRequested() as Void {
        _exitRequested = true;
    }

    (:release)
    private function noteExitRequested() as Void {
    }

    // -- Test hooks (debug builds only) -----------------------------------

    //! Keep BACK on the start screen and summary from ending the test run,
    //! and the menu from pushing a system view.
    (:debug)
    function testDisableExit() as Void {
        _exitEnabled = false;
        _viewsEnabled = false;
    }

    //! How many times the start-screen menu was requested.
    (:debug)
    function testMenuRequests() as Number {
        return _menuRequests;
    }

    //! Whether exitApp() ran (with System.exit() switched off by tests).
    (:debug)
    function testExitRequested() as Boolean {
        return _exitRequested;
    }
}

//! The start-screen menu: "Test alarm" starts the ramp preview.
class PowerNapMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _view as PowerNapView;

    function initialize(view as PowerNapView) {
        Menu2InputDelegate.initialize();
        _view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        if (item.getId() == :testAlarm) {
            _view.startPreview();
        }
    }

    function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }
}
