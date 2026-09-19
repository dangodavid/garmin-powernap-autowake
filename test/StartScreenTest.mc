import Toybox.Test;
import Toybox.Lang;
import Toybox.Application;
import Toybox.Time;
import Toybox.WatchUi;

// -----------------------------------------------------------------------------
// The start screen: the promise it makes, how live it is, what it remembers
// and that it can be driven from the buttons alone.
//
//   * AlarmCap is the one formula behind the alarm cap ("Alarm by HH:MM"):
//     the start screen's preview and the running nap's deadline both come
//     from it, so a nap started in the minute the preview was drawn in keeps
//     exactly that time, and the alarm rings at the latest at that minute.
//   * The preview and the time of day are live: the start screen redraws
//     itself right after every minute change, with no press.
//   * The duration a nap started with is remembered (Application.Storage)
//     and opens the next session, unless the phone setting changed since.
//   * UP/DOWN/START/BACK run the whole flow without the touchscreen.
//
// The detector's clock is pinned (testPinClock) where the second within the
// minute matters, so these tests are exact. Helpers from DelegateTest
// (DelegateRig, delegateHelperStored/Restore) and LayoutTest
// (layoutHelperDc) are reused.
// -----------------------------------------------------------------------------

//! A whole minute of the current wall clock: the base for pinned clocks.
(:debug)
function startHelperMinuteBase() as Number {
    return (Time.now().value() / 60) * 60;
}

//! The "Alarm by" time the screen would print for a cap.
(:debug)
function startHelperCapText(v as PowerNapView, capSec as Number) as String {
    return v.testFormatMoment(new Time.Moment(capSec));
}

//! Whether the promise line of this layout shows `time` (it may have been
//! dropped on the smallest screens, which counts as "not shown").
(:debug)
function startHelperShowsPromise(layout as ScreenLayout, time as String) as Boolean {
    return layout.showsFragment("Alarm by " + time) || layout.showsFragment("By " + time);
}

//! Whether the layout has a promise line at all.
(:debug)
function startHelperHasPromise(layout as ScreenLayout) as Boolean {
    return layout.showsFragment("Alarm by") || layout.showsFragment("By ");
}

// ── The cap formula ─────────────────────────────────────────────────────────

//! One formula, one answer per minute: every second of a minute gives the
//! same cap, the cap falls on a whole minute, and it is later than
//! start + allowance + nap but never by more than a minute (the allowance is
//! rounded up, never cut).
(:test)
function testStart_capIsTheSameForEverySecondOfAMinute(logger as Test.Logger) as Boolean {
    var base = startHelperMinuteBase();
    var allowances = [5, 15, 30] as Array<Number>;
    var naps = [5, 30, 120] as Array<Number>;
    for (var a = 0; a < allowances.size(); a++) {
        for (var n = 0; n < naps.size(); n++) {
            var expected = AlarmCap.deadlineSec(base, allowances[a], naps[n]);
            if (expected % 60 != 0) {
                logger.debug("cap " + expected + " is not a whole minute");
                return false;
            }
            for (var s = 0; s < 60; s++) {
                var cap = AlarmCap.deadlineSec(base + s, allowances[a], naps[n]);
                if (cap != expected) {
                    logger.debug("second " + s + " of the minute gave " + (cap - expected) + " s more");
                    return false;
                }
                var exact = base + s + (allowances[a] + naps[n]) * 60;
                if (cap <= exact - 1 || cap > exact + 60) {
                    logger.debug("cap " + (cap - exact) + " s off the exact sum at second " + s);
                    return false;
                }
            }
        }
    }
    return true;
}

//! The nap the detector runs uses that formula, and the deadline alarm rings
//! exactly at the promised minute - not a second later.
(:test)
function testStart_alarmRingsAtThePromisedMinute(logger as Test.Logger) as Boolean {
    var base = startHelperMinuteBase();
    var seconds = [0, 1, 37, 59] as Array<Number>;
    for (var i = 0; i < seconds.size(); i++) {
        var d = new SleepDetector(null);
        d.testPinClock(base + seconds[i]);
        d.testStart();
        d.testSetNapDurationMin(5);
        var cap = AlarmCap.deadlineSec(base + seconds[i], 15, 5);
        if (d.testGetDeadlineSec() != cap || cap % 60 != 0) {
            logger.debug("second " + seconds[i] + ": deadline " + d.testGetDeadlineSec() + ", cap " + cap);
            return false;
        }
        // Restless all the way: the cap is the only way out. testTick()
        // moves the clock on by a second before it looks, so the last tick
        // before the cap must land on cap - 1.
        d.testAdvanceClock(cap - d.testNowSec() - 2);
        d.testTick();
        if (!d.isActiveState()) {
            logger.debug("second " + seconds[i] + ": rang before the promised minute");
            return false;
        }
        d.testTick();
        if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_DEADLINE
            || d.testNowSec() != cap) {
            logger.debug("second " + seconds[i] + ": state " + d.getState() + " at "
                + (d.testNowSec() - cap) + " s from the cap");
            return false;
        }
    }
    return true;
}

//! Acceptance: started anywhere in the minute the preview was drawn in, the
//! nap screen shows the same "Alarm by" time as the start screen did - the
//! value, the text, and the deadline the alarm actually uses.
(:test)
function testStart_previewMatchesTheNapItStarts(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var base = startHelperMinuteBase();
    var seconds = [0, 1, 30, 59] as Array<Number>;
    var ok = true;
    for (var i = 0; i < seconds.size(); i++) {
        var r = new DelegateRig(30);
        r.detector.testPinClock(base + seconds[i]);
        var shown = r.view.testPreviewCapSec();
        var text = startHelperCapText(r.view, shown);
        if (!startHelperShowsPromise(r.view.testBuildLayout(dc), text)) {
            logger.debug("second " + seconds[i] + ": the start screen must promise " + text);
            ok = false;
        }
        // START later in the same minute (the preview is not redrawn).
        r.detector.testAdvanceClock(59 - seconds[i]);
        r.startNap();
        var deadline = r.detector.getDeadlineTime().value();
        if (deadline != shown) {
            logger.debug("second " + seconds[i] + ": promised " + shown + ", nap got "
                + (deadline - shown) + " s more");
            ok = false;
        }
        var layout = r.view.testBuildLayout(dc);
        if (startHelperHasPromise(layout) && !startHelperShowsPromise(layout, text)) {
            logger.debug("second " + seconds[i] + ": the nap screen shows another time than " + text);
            ok = false;
        }
        r.cleanup();
        if (!ok) {
            return false;
        }
    }
    return ok;
}

// ── The live preview ────────────────────────────────────────────────────────

//! The start screen keeps itself up to date: at the minute change its own
//! timer redraws, and the time of day and the "Alarm by" preview both move
//! on by a minute without anything being pressed.
(:test)
function testStart_previewFollowsTheClock(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var base = startHelperMinuteBase();
    var r = new DelegateRig(30);
    r.detector.testPinClock(base + 58);
    var ok = true;

    var capBefore = r.view.testPreviewCapSec();
    var clockBefore = r.view.testClockString();
    var textBefore = startHelperCapText(r.view, capBefore);
    if (!startHelperShowsPromise(r.view.testBuildLayout(dc), textBefore)) {
        logger.debug("the start screen must promise " + textBefore);
        ok = false;
    }

    r.view.onShow();                                 // as the app opens it
    if (!r.view.testUiTimerArmed()) {
        logger.debug("the start screen must arm its refresh");
        ok = false;
    }
    r.detector.testAdvanceClock(2);                  // over the minute boundary
    r.view.onUiTimer();                              // what the timer does there
    var capAfter = r.view.testPreviewCapSec();
    var clockAfter = r.view.testClockString();
    if (capAfter != capBefore + 60) {
        logger.debug("the preview must move one minute at the minute change, moved "
            + (capAfter - capBefore) + " s");
        ok = false;
    }
    if (clockAfter.equals(clockBefore)) {
        logger.debug("the clock must move too, still " + clockBefore);
        ok = false;
    }
    if (!startHelperShowsPromise(r.view.testBuildLayout(dc), startHelperCapText(r.view, capAfter))) {
        logger.debug("after the minute change the screen must promise the new time");
        ok = false;
    }
    if (!r.view.testUiTimerArmed()) {
        logger.debug("the refresh must arm itself again");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! The refresh aims at the minute boundary: it waits out the minute and then
//! looks often enough that the new minute is on screen right away.
(:test)
function testStart_refreshAimsAtTheMinuteBoundary(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    var ok = true;
    var poll = r.view.testUiWakeMs(59);
    if (poll > 250) {
        logger.debug("the last second of a minute must be looked at closely, waits " + poll + " ms");
        ok = false;
    }
    var seconds = [0, 1, 30, 58] as Array<Number>;
    for (var i = 0; i < seconds.size(); i++) {
        var ms = r.view.testUiWakeMs(seconds[i]);
        var toBoundary = (60 - seconds[i]) * 1000;
        if (ms > toBoundary || ms < toBoundary - 1000) {
            logger.debug("at second " + seconds[i] + " the refresh waits " + ms
                + " ms, the minute changes in " + toBoundary + " ms");
            ok = false;
        }
    }
    r.cleanup();
    return ok;
}

// ── The remembered duration ─────────────────────────────────────────────────

//! The duration a nap was started with opens the next session, clamped to
//! the valid range; Stay Awake is not remembered; a nap duration changed on
//! the phone in the meantime wins again.
(:test)
function testStart_lastDurationIsRemembered(logger as Test.Logger) as Boolean {
    var napProp = Application.Properties.getValue("napDuration");
    var lastNap = delegateHelperStored("lastNapMin");
    var phoneNap = delegateHelperStored("lastPhoneNapMin");
    var ok = true;
    try {
        Application.Properties.setValue("napDuration", 30);
        Application.Storage.deleteValue("lastNapMin");
        Application.Storage.deleteValue("lastPhoneNapMin");

        // First run: the setting from the phone.
        if (startHelperOpenPick() != 30) {
            logger.debug("the first run must open on the stored setting, got " + startHelperOpenPick());
            ok = false;
        }

        // A nap of 45 min: the next session opens on it.
        startHelperRunNap(45);
        if (startHelperOpenPick() != 45) {
            logger.debug("45 min must be remembered, got " + startHelperOpenPick());
            ok = false;
        }

        // Stay Awake is a choice for one session only.
        startHelperRunNap(0);
        if (startHelperOpenPick() != 45) {
            logger.debug("Stay Awake must not be remembered, got " + startHelperOpenPick());
            ok = false;
        }

        // Changed on the phone since: the setting wins again.
        Application.Properties.setValue("napDuration", 20);
        if (startHelperOpenPick() != 20) {
            logger.debug("a new setting from the phone must win, got " + startHelperOpenPick());
            ok = false;
        }
        // ... and the next nap is remembered against it again.
        startHelperRunNap(10);
        if (startHelperOpenPick() != 10) {
            logger.debug("10 min must be remembered, got " + startHelperOpenPick());
            ok = false;
        }

        // A value from outside the range never reaches the screen.
        Application.Storage.setValue("lastNapMin", 500);
        if (startHelperOpenPick() != 120) {
            logger.debug("500 must clamp to 120, got " + startHelperOpenPick());
            ok = false;
        }
        Application.Storage.setValue("lastNapMin", 1);
        if (startHelperOpenPick() != 5) {
            logger.debug("1 must clamp to 5, got " + startHelperOpenPick());
            ok = false;
        }
    } catch (e instanceof Lang.Exception) {
        logger.debug("exception: " + e.getErrorMessage());
        ok = false;
    }
    try {
        Application.Properties.setValue("napDuration", (napProp != null) ? napProp as Number : 30);
    } catch (e instanceof Lang.Exception) {
    }
    delegateHelperRestore("lastNapMin", lastNap);
    delegateHelperRestore("lastPhoneNapMin", phoneNap);
    return ok;
}

//! The duration the start screen opens on in a fresh view.
(:debug)
function startHelperOpenPick() as Number {
    var d = new SleepDetector(null);
    var v = new PowerNapView(d, new AlarmManager());
    var pick = v.testGetPendingDuration();
    v.onHide();
    return pick;
}

//! Start a nap (or a Stay Awake session, minutes = 0) as the start screen
//! does and end it again, so only what START remembers is left behind.
(:debug)
function startHelperRunNap(minutes as Number) as Void {
    var d = new SleepDetector(null);
    d.testUseFakeRuntime();
    var a = new AlarmManager();
    var v = new PowerNapView(d, a);
    v.testSetPendingDuration(minutes);
    v.startNap();
    d.stop();
    a.stop();
    v.onHide();
}

// ── Buttons ─────────────────────────────────────────────────────────────────

//! The whole flow from the physical buttons, with no tap: UP and DOWN set
//! the duration, START begins the nap with it, START twice stops it with the
//! stats, START opens the start screen again on the remembered duration, and
//! BACK twice leaves the app. Every press is consumed.
(:test)
function testStart_buttonsRunTheWholeFlow(logger as Test.Logger) as Boolean {
    var napProp = Application.Properties.getValue("napDuration");
    var lastNap = delegateHelperStored("lastNapMin");
    var phoneNap = delegateHelperStored("lastPhoneNapMin");
    // A known phone setting and nothing remembered yet, before the view
    // reads either of them.
    try {
        Application.Properties.setValue("napDuration", 30);
        Application.Storage.deleteValue("lastNapMin");
        Application.Storage.deleteValue("lastPhoneNapMin");
    } catch (e instanceof Lang.Exception) {
    }
    var r = new DelegateRig(30);
    var ok = true;
    try {
        if (!r.key(WatchUi.KEY_UP) || !r.key(WatchUi.KEY_UP) || !r.key(WatchUi.KEY_DOWN)) {
            logger.debug("the duration keys must be consumed");
            ok = false;
        }
        if (r.view.testGetPendingDuration() != 35) {
            logger.debug("UP UP DOWN from 30 must give 35, got " + r.view.testGetPendingDuration());
            ok = false;
        }
        if (!r.key(WatchUi.KEY_ENTER) || !r.view.isStarted() || r.detector.getNapDurationMin() != 35) {
            logger.debug("START must begin a 35 min nap, got " + r.detector.getNapDurationMin());
            ok = false;
        }
        r.detector.testSetBaseline(70.0f);
        r.detector.testForceSleep();
        r.detector.testRunMinutes(2, 55, 10.0f);

        r.key(WatchUi.KEY_ENTER);                    // peek
        r.key(WatchUi.KEY_ENTER);                    // stop with the stats
        if (r.detector.getState() != SleepDetector.STATE_SUMMARY) {
            logger.debug("START twice must show the summary, state " + r.detector.getState());
            ok = false;
        }
        r.view.testExpireInputLock();
        r.key(WatchUi.KEY_ENTER);                    // back to the start screen
        if (r.view.isStarted() || r.view.testGetPendingDuration() != 35) {
            logger.debug("the start screen must open on the remembered 35, got "
                + r.view.testGetPendingDuration());
            ok = false;
        }
        r.view.testExpireInputLock();
        r.key(WatchUi.KEY_ESC);
        if (r.delegate.testExitRequested() || !r.view.testIsHintShowing()) {
            logger.debug("the first BACK must only ask");
            ok = false;
        }
        r.key(WatchUi.KEY_ESC);
        if (!r.delegate.testExitRequested()) {
            logger.debug("BACK twice on the start screen must leave the app");
            ok = false;
        }
    } catch (e instanceof Lang.Exception) {
        logger.debug("exception: " + e.getErrorMessage());
        ok = false;
    }
    r.cleanup();
    try {
        Application.Properties.setValue("napDuration", (napProp != null) ? napProp as Number : 30);
    } catch (e instanceof Lang.Exception) {
    }
    delegateHelperRestore("lastNapMin", lastNap);
    delegateHelperRestore("lastPhoneNapMin", phoneNap);
    return ok;
}
