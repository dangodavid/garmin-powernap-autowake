import Toybox.Test;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.Math;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// -----------------------------------------------------------------------------
// Nothing drawn over anything else, nothing outside the display.
//
// Every screen of the app, built by the real view on the running device and
// taken apart into the boxes it draws: the layout's lines, footer and popup
// (ScreenLayout.testBoxes) and what the view draws by itself - the start
// screen's arrows and its clock in the top margin, the clock in the Instinct
// lens (PowerNapView.testScreenBoxes). Each screen is checked in the 12- and
// the 24-hour format, with a full and a low battery, with the clock at the
// widest time of day this device draws, and with its content at its longest:
// a 3-digit heart rate, the 120-minute nap, 12 wakes, a 10-hour Stay Awake
// session with 12 dozes, every warning, every armed footer, every popup -
// so each line is laid out in the longest variant this resolution takes.
//
// The rule, for every box of a screen:
//   * it overlaps no other box of the screen, and
//   * it lies inside the visible display at its own rows: inside the round
//     chord (inside the summary ring, where the ring is drawn), inside the
//     octagon of the Instinct 3 Solar, and clear of that watch's lens -
//     except the clock drawn IN the lens, which must lie inside it.
// A text box is its text at the full height of its font (what the layout
// stacks, so two lines that only touch do not count) and is held to the
// display at its ink rows, 15-85 % of that height: the model ScreenLayout
// fits text with.
//
// The popup ("Press BACK again to ...", "Press START again to stop") is a
// layer over the screen: a sheet from the top edge of one of the screen's
// rows down past the bottom of the display, whose outline cuts its corners.
// It covers what is under it by design, so it is checked as a layer of its
// own - its text inside the sheet and inside the display, its two lines
// clear of each other - and by the rules it is placed by, on every screen
// that shows one:
//   * it covers whole rows only: its top edge is the top edge of a row,
//     every row lies entirely above that edge or entirely under the sheet,
//     the sheet runs across the whole width down to the bottom edge, and it
//     starts no higher than its text needs (one row lower, it would not
//     fit; on one line where one line fits);
//   * its font is the exit popup's on every screen: the largest at which
//     "Press BACK again to exit" fits across the middle of the display;
//   * its text is the longest variant that fits, on one line or on two
//     broken at a space: the next longer one fits under no row of the
//     screen in that font, not even on two lines.
// "Fits" is the layout's own measure: each line inside the visible width
// at its ink rows, 6 px clear of the edge and of the Instinct's lens.
//
// The start screen's menu ("Test alarm") is a Menu2, drawn by the watch's
// firmware and not by the app: there is no box of it to check here.
//
// A failure names the device (part number and resolution - tools/matrix.sh
// prints the product id on the same run), the screen, the clock format, the
// battery level and the time on the clock, and the two boxes that collide or
// the box that leaves the display, each as x,y wxh.
// -----------------------------------------------------------------------------

//! The low battery every screen is also checked with (below the 10 % that
//! makes the screens warn).
(:debug)
const OVERLAP_LOW_BATTERY = 8;

//! Where the test sessions start: 10:00 today, so that a 12-hour clock shows
//! two-digit hours for the next three hours - every time a nap screen shows.
(:debug)
const OVERLAP_SESSION_HOUR = 10;

//! The start screen at every duration step that changes its lines - 5, 30,
//! the three digits of 120, and Stay Awake - laid out as a release build
//! lays it out and with the debug label a debug build adds, each also with
//! the exit popup over it.
(:test)
function testOverlap_startScreen(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var d = new SleepDetector(null);
    var v = layoutHelperStartView(d, new AlarmManager());
    var times = overlapHelperTimes(v, dc);
    var ok = true;
    var durations = [5, 30, 120, 0] as Array<Number>;
    for (var pass = 0; pass < 2; pass++) {
        var build = (pass == 0) ? " (debug label)" : "";
        if (pass == 1) {
            v.testHideDebugLabel();
        }
        for (var i = 0; i < durations.size(); i++) {
            v.testSetPendingDuration(durations[i]);
            var name = "start " + durations[i] + " min" + build;
            ok = overlapHelperStart(name, v, d, dc, times, null, logger) && ok;
            v.pressConfirm(ConfirmPress.CONTEXT_EXIT);
            v.showHint(PowerNapView.HINT_EXIT);
            ok = overlapHelperStart(name + " + exit popup", v, d, dc, times, PowerNapView.HINT_EXIT, logger) && ok;
            v.testAdvanceMs(4100);
        }
    }
    v.onHide();
    return ok;
}

//! The nap screens before the alarm: calibrating, monitoring (waiting, and
//! with stillness), asleep (the 3-digit countdown of a 120-minute nap, and
//! the smart-wake window), awake after a wake early in the nap ("Alarm in"
//! with three digits), asleep again after 12 wakes; and the peek card over
//! them. Each one plain, with the BACK popup, with START armed, and crowded
//! with "Keep app open" as well.
(:test)
function testOverlap_napScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var times = overlapHelperTimes(layoutHelperStartView(new SleepDetector(null), new AlarmManager()), dc);
    var ok = true;
    var d = overlapHelperSession(120);
    d.testFeedHR(188);
    ok = overlapHelperScreen("calibrating", d, dc, times, -1, false, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testRunMinutes(1, 68, 300.0f);
    d.testFeedHR(188);
    ok = overlapHelperScreen("monitoring, waiting for sleep", d, dc, times, PowerNapView.BACK_HINT_NAP, true, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testRunMinutes(1, 68, 10.0f);
    d.testFeedHR(188);
    ok = overlapHelperScreen("monitoring, stillness", d, dc, times, PowerNapView.BACK_HINT_NAP, false, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testFeedHR(188);
    ok = overlapHelperScreen("asleep", d, dc, times, PowerNapView.BACK_HINT_NAP, true, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testAdvanceClock(116 * 60);
    d.testFeedHR(188);
    ok = overlapHelperScreen("asleep, smart wake window", d, dc, times, PowerNapView.BACK_HINT_NAP, false, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testRunMinutes(3, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);
    d.testFeedHR(188);
    ok = overlapHelperScreen("awake after a wake", d, dc, times, PowerNapView.BACK_HINT_NAP, true, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    for (var i = 0; i < 12; i++) {
        d.testRunMinutes(1, 55, 300.0f);        // a wake
        d.testRunMinutes(2, 55, 10.0f);         // asleep again
    }
    d.testFeedHR(188);
    if (d.getWakeEpisodes() != 12) {
        logger.debug("setup: 12 wakes expected, got " + d.getWakeEpisodes());
        ok = false;
    }
    ok = overlapHelperScreen("asleep after 12 wakes", d, dc, times, PowerNapView.BACK_HINT_NAP, true, logger) && ok;
    return ok;
}

//! The alarm screens: a whole 120-minute nap (3-digit "Slept", average and
//! lowest heart rate), the deadline with no sleep ("Waited 136 min") and a
//! smart wake, each calm and at full strength, plain, with the BACK popup
//! and with the START popup and its armed footer.
(:test)
function testOverlap_alarmScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var times = overlapHelperTimes(layoutHelperStartView(new SleepDetector(null), new AlarmManager()), dc);
    var ok = true;
    var d = overlapHelperWholeNap();
    ok = overlapHelperAlarm("alarm, nap complete", d, dc, times, logger) && ok;

    d = overlapHelperSession(120);
    d.testAdvanceClock((1 + 15 + 120) * 60);
    d.testTick();
    ok = overlapHelperAlarm("alarm, deadline", d, dc, times, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testFeedHR(188);
    d.testAdvanceClock(116 * 60);
    d.testRunSeconds(54, 55, 10.0f);
    d.testRunSeconds(6, 55, 100.0f);
    if (d.getAlarmReason() != SleepDetector.ALARM_SMART_WAKE) {
        logger.debug("setup: a smart wake expected, got reason " + d.getAlarmReason());
        ok = false;
    }
    ok = overlapHelperAlarm("alarm, smart wake", d, dc, times, logger) && ok;
    return ok;
}

//! The summaries: a whole 120-minute nap fallen asleep in 15 minutes (the
//! ring), 12 wakes, a nap stopped early, and the two without any sleep
//! (deadline, stopped).
(:test)
function testOverlap_summaryScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var times = overlapHelperTimes(layoutHelperStartView(new SleepDetector(null), new AlarmManager()), dc);
    var ok = true;
    var d = overlapHelperWholeNap();
    d.finishNap();
    ok = overlapHelperScreen("summary, nap complete", d, dc, times, -1, false, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    for (var i = 0; i < 12; i++) {
        d.testRunMinutes(1, 55, 300.0f);
        d.testRunMinutes(2, 55, 10.0f);
    }
    d.testFeedHR(188);
    d.testAdvanceClock(120 * 60);
    d.testTick();
    d.finishNap();
    ok = overlapHelperScreen("summary, 12 wakes", d, dc, times, -1, false, logger) && ok;

    d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testFeedHR(188);
    d.testAdvanceClock(100 * 60);
    d.cancel();
    ok = overlapHelperScreen("summary, nap stopped", d, dc, times, -1, false, logger) && ok;

    d = overlapHelperSession(120);
    d.testAdvanceClock((1 + 15 + 120) * 60);
    d.testTick();
    d.finishNap();
    ok = overlapHelperScreen("summary, no sleep (deadline)", d, dc, times, -1, false, logger) && ok;

    d = overlapHelperSession(120);
    d.testAdvanceClock(100 * 60);
    d.cancel();
    ok = overlapHelperScreen("summary, no sleep (stopped)", d, dc, times, -1, false, logger) && ok;
    return ok;
}

//! Stay Awake: calibrating, on guard, the "Stay alert!" warning, the doze
//! alarm, and the guard after 12 dozes and 10 hours - with its peek card,
//! the 12th doze alarm and the summary.
(:test)
function testOverlap_stayAwakeScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var times = overlapHelperTimes(layoutHelperStartView(new SleepDetector(null), new AlarmManager()), dc);
    var ok = true;
    var d = overlapHelperSession(0);
    d.testFeedHR(188);
    ok = overlapHelperScreen("Stay Awake calibrating", d, dc, times, -1, false, logger) && ok;

    d = overlapHelperSession(0);
    d.testRunMinutes(3, 70, 200.0f);
    d.testFeedHR(188);
    ok = overlapHelperScreen("Stay Awake on guard", d, dc, times, PowerNapView.BACK_HINT_STAY_AWAKE, true, logger) && ok;

    d = overlapHelperSession(0);
    d.testRunMinutes(3, 70, 200.0f);
    d.testRunMinutes(3, 70, 10.0f);
    d.testFeedHR(188);
    if (!d.isDozeWarning()) {
        logger.debug("setup: the doze warning expected");
        ok = false;
    }
    ok = overlapHelperScreen("Stay Awake, doze warning", d, dc, times, PowerNapView.BACK_HINT_STAY_AWAKE, false, logger) && ok;

    d = overlapHelperSession(0);
    for (var i = 0; i < 12; i++) {
        d.testRunMinutes(5, 70, 10.0f);         // dozing off: the doze alarm
        if (i == 0 || i == 11) {
            ok = overlapHelperAlarm("doze alarm #" + (i + 1), d, dc, times, logger) && ok;
        }
        d.dismissAlarm();
        d.testRunMinutes(1, 70, 200.0f);
    }
    d.testAdvanceClock(10 * 3600);
    d.testFeedHR(188);
    if (d.getDozeCount() != 12) {
        logger.debug("setup: 12 dozes expected, got " + d.getDozeCount());
        ok = false;
    }
    ok = overlapHelperScreen("Stay Awake on guard, 12 dozes, 10 h", d, dc, times, PowerNapView.BACK_HINT_STAY_AWAKE,
        true, logger) && ok;
    d.cancel();
    ok = overlapHelperScreen("Stay Awake summary, 12 dozes, 10 h", d, dc, times, -1, false, logger) && ok;
    return ok;
}

//! The "Test alarm" preview at every step of the ramp.
(:test)
function testOverlap_previewScreen(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
    var v = layoutHelperStartView(new SleepDetector(null), a);
    var times = overlapHelperTimes(v, dc);
    var ok = true;
    a.startPreview();
    var steps = a.getPreviewSteps();
    for (var s = 1; s <= steps; s++) {
        ok = overlapHelperCheck("preview step " + s, v, dc, times, null, logger) && ok;
        a.testPreviewTick();
    }
    a.stop();
    return ok;
}

// -- Scenarios ----------------------------------------------------------------

//! A nap (napMin > 0) or Stay Awake session (0) started at
//! OVERLAP_SESSION_HOUR today, with the documented default settings and no
//! alarm manager of its own (the view's manager draws the alarm screens).
(:debug)
function overlapHelperSession(napMin as Number) as SleepDetector {
    var d = new SleepDetector(null);
    d.testPinClock(Time.today().value() + OVERLAP_SESSION_HOUR * 3600);
    if (napMin == 0) {
        d.testStartStayAwake();
    } else {
        d.testStart();
        d.testSetNapDurationMin(napMin);
    }
    return d;
}

//! A whole 120-minute nap, fallen asleep after 15 minutes, a 3-digit heart
//! rate while asleep, now ringing.
(:debug)
function overlapHelperWholeNap() as SleepDetector {
    var d = overlapHelperSession(120);
    d.testSetBaseline(70.0f);
    d.testAdvanceClock(15 * 60);
    d.testForceSleep();
    for (var i = 0; i < 3; i++) {
        d.testFeedHR(188);
    }
    d.testAdvanceClock(120 * 60);
    d.testTick();
    return d;
}

//! One session screen with everything it can carry: as it is, with the
//! popup of a first BACK over it (backHint >= 0, a BACK_HINT_* kind), with
//! START armed (the longest footer), crowded with "Keep app open" as well
//! (the warning stays for the rest of the session, so it comes last), and
//! with the peek card over it (`peek`), plain and with both popups' worth
//! of arming.
(:debug)
function overlapHelperScreen(name as String, d as SleepDetector, dc as Graphics.Dc, times as Array<Number>,
                             backHint as Number, peek as Boolean, logger as Test.Logger) as Boolean {
    var v = layoutHelperView(d, new AlarmManager());
    var ok = overlapHelperCheck(name, v, dc, times, null, logger);
    if (backHint >= 0) {
        v.pressConfirm(ConfirmPress.CONTEXT_EXIT);
        v.showHint(v.backHintTexts(backHint));
        ok = overlapHelperCheck(name + " + BACK popup", v, dc, times, v.backHintTexts(backHint), logger) && ok;
        v.testAdvanceMs(4100);
    }
    if (d.isActiveState()) {
        v.pressConfirm(ConfirmPress.CONTEXT_STOP);
        ok = overlapHelperCheck(name + " + START armed", v, dc, times, null, logger) && ok;
        v.testAdvanceMs(4100);
        if (peek) {
            v.showPeek();
            ok = overlapHelperCheck(name + ", peek", v, dc, times, null, logger) && ok;
            v.pressConfirm(ConfirmPress.CONTEXT_STOP);
            ok = overlapHelperCheck(name + ", peek + START armed", v, dc, times, null, logger) && ok;
            v.testAdvanceMs(4100);
            v.showPeek();
            v.pressConfirm(ConfirmPress.CONTEXT_EXIT);
            v.showHint(v.backHintTexts(backHint));
            ok = overlapHelperCheck(name + ", peek + BACK popup", v, dc, times, v.backHintTexts(backHint), logger)
                && ok;
            v.testAdvanceMs(5100);
        }
        d.noteInactive();
        v.pressConfirm(ConfirmPress.CONTEXT_STOP);
        ok = overlapHelperCheck(name + " + Keep app open + START armed", v, dc, times, null, logger) && ok;
        v.testAdvanceMs(4100);
    }
    return ok;
}

//! An alarm screen (the detector is ringing), calm and at full strength,
//! each plain, with the BACK popup, and with the START popup and the armed
//! footer that repeats it.
(:debug)
function overlapHelperAlarm(name as String, d as SleepDetector, dc as Graphics.Dc, times as Array<Number>,
                            logger as Test.Logger) as Boolean {
    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("setup: " + name + " is not ringing (state " + d.getState() + ")");
        return false;
    }
    var ok = true;
    for (var loud = 0; loud < 2; loud++) {
        var a = new AlarmManager();
        a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
        if (loud == 1) {
            a.startAlarm();
            while (!a.isFullIntensity()) {
                a.testFireRing();
            }
        }
        var v = layoutHelperView(d, a);
        var what = name + ((loud == 1) ? ", full strength" : ", calm");
        ok = overlapHelperCheck(what, v, dc, times, null, logger) && ok;
        var back = v.backHintTexts(PowerNapView.BACK_HINT_ALARM);
        v.pressConfirm(ConfirmPress.CONTEXT_EXIT);
        v.showHint(back);
        ok = overlapHelperCheck(what + " + BACK popup", v, dc, times, back, logger) && ok;
        v.testAdvanceMs(4100);
        v.pressConfirm(ConfirmPress.CONTEXT_STOP);
        v.showHint(PowerNapView.HINT_STOP);
        ok = overlapHelperCheck(what + " + START popup", v, dc, times, PowerNapView.HINT_STOP, logger) && ok;
        v.testAdvanceMs(4100);
        a.stop();
    }
    return ok;
}

// -- Inputs ---------------------------------------------------------------------

//! The start screen in both formats and with both batteries, its clock and
//! its "Alarm by" promise both at the widest time of day: the detector is
//! pinned so that the promise lands on it. `hint`: the texts of the popup
//! showing over it, or null.
(:debug)
function overlapHelperStart(name as String, v as PowerNapView, d as SleepDetector, dc as Graphics.Dc,
                            times as Array<Number>, hint as Array<String>?, logger as Test.Logger) as Boolean {
    var nap = v.testGetPendingDuration();
    var ok = true;
    for (var f = 0; f < 2; f++) {
        v.testForce24Hour(f == 1);
        var widest = times[2 + f];
        d.testPinClock(widest - (1 + d.getFallAsleepAllowanceMin() + nap) * 60);
        v.testForceClockSec(widest);
        ok = overlapHelperBatteries(name + ", " + ((f == 1) ? "24 h" : "12 h"), v, dc, hint, logger) && ok;
    }
    return ok;
}

//! A screen in both formats and with both batteries, the clock at the
//! widest time of day: the live screens' clock line starts at FONT_TINY,
//! the lens draws it at FONT_XTINY. `hint`: the texts of the popup showing
//! over it, or null.
(:debug)
function overlapHelperCheck(name as String, v as PowerNapView, dc as Graphics.Dc, times as Array<Number>,
                            hint as Array<String>?, logger as Test.Logger) as Boolean {
    var font = v.testHasSubscreen() ? 2 : 0;
    var ok = true;
    for (var f = 0; f < 2; f++) {
        v.testForce24Hour(f == 1);
        v.testForceClockSec(times[font + f]);
        ok = overlapHelperBatteries(name + ", " + ((f == 1) ? "24 h" : "12 h"), v, dc, hint, logger) && ok;
    }
    return ok;
}

//! The screen with a full and with a low battery; with a popup (`hint`, its
//! texts) also the rules the popup is placed by.
(:debug)
function overlapHelperBatteries(name as String, v as PowerNapView, dc as Graphics.Dc, hint as Array<String>?,
                                logger as Test.Logger) as Boolean {
    var ok = true;
    var levels = [100, OVERLAP_LOW_BATTERY] as Array<Number>;
    for (var b = 0; b < levels.size(); b++) {
        v.testForceBattery(levels[b]);
        var what = name + ", battery " + levels[b] + "%, clock " + v.testClockString();
        var boxes = v.testScreenBoxes(dc);
        if (hint != null) {
            if (overlapHelperHasPopup(boxes)) {
                ok = overlapHelperPopup(what, boxes, hint, v, dc, logger) && ok;
            } else {
                logger.debug(overlapHelperDevice() + " " + what + ": the popup is not on screen");
                ok = false;
            }
        }
        ok = overlapHelperRules(what, boxes, v.testRingInnerRadius(dc), dc, logger) && ok;
    }
    v.testForceBattery(100);
    return ok;
}

//! The widest time of day this device draws, as seconds since the epoch
//! (today): [12 h, 24 h] at FONT_TINY, then [12 h, 24 h] at FONT_XTINY.
(:debug)
function overlapHelperTimes(v as PowerNapView, dc as Graphics.Dc) as Array<Number> {
    var out = [] as Array<Number>;
    var fonts = [Graphics.FONT_TINY, Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>;
    for (var fi = 0; fi < fonts.size(); fi++) {
        for (var f = 0; f < 2; f++) {
            v.testForce24Hour(f == 1);
            out.add(overlapHelperWidest(v, dc, fonts[fi]));
        }
    }
    return out;
}

//! The time of day `v` draws widest in `font`, in the format it is set to:
//! the widest minute beside the widest hour (widths add up). Ties go to the
//! first hour from OVERLAP_SESSION_HOUR on.
(:debug)
function overlapHelperWidest(v as PowerNapView, dc as Graphics.Dc, font as Graphics.FontDefinition) as Number {
    var day = Time.today().value() + OVERLAP_SESSION_HOUR * 3600;
    var minute = 0;
    var widest = -1;
    for (var m = 0; m < 60; m++) {
        var w = dc.getTextWidthInPixels(v.testFormatMoment(new Time.Moment(day + m * 60)), font);
        if (w > widest) {
            widest = w;
            minute = m;
        }
    }
    var best = day + minute * 60;
    widest = -1;
    for (var h = 0; h < 24; h++) {
        var sec = day + h * 3600 + minute * 60;
        var w = dc.getTextWidthInPixels(v.testFormatMoment(new Time.Moment(sec)), font);
        if (w > widest) {
            widest = w;
            best = sec;
        }
    }
    return best;
}

// -- The rule -------------------------------------------------------------------

//! Every box inside the visible display, no two boxes of the screen over
//! each other; the popup a layer of its own (see the header).
(:debug)
function overlapHelperRules(what as String, boxes as Array<Array>, ringR as Number, dc as Graphics.Dc,
                            logger as Test.Logger) as Boolean {
    var ok = true;
    var n = boxes.size();
    for (var i = 0; i < n; i++) {
        var why = overlapHelperOutside(boxes[i], ringR, dc);
        if (why != null) {
            logger.debug(overlapHelperDevice() + " " + what + ": " + overlapHelperName(boxes[i]) + " " + why);
            ok = false;
        }
    }
    for (var i = 0; i < n; i++) {
        for (var j = i + 1; j < n; j++) {
            var a = boxes[i];
            var b = boxes[j];
            var popupA = overlapHelperIsPopup(a);
            if (popupA != overlapHelperIsPopup(b)) {
                continue;                        // the popup covers the screen under it
            }
            var sheetA = ((a[4] as Number) == ScreenLayout.BOX_BANNER);
            if (popupA && sheetA != ((b[4] as Number) == ScreenLayout.BOX_BANNER)) {
                var box = sheetA ? a : b;
                var text = sheetA ? b : a;
                if (!overlapHelperContains(box, text)) {
                    logger.debug(overlapHelperDevice() + " " + what + ": " + overlapHelperName(text)
                        + " does not fit inside its " + overlapHelperName(box));
                    ok = false;
                }
                continue;
            }
            // Two lines of the screen, or the popup's two lines of text.
            if (overlapHelperIntersect(a, b)) {
                logger.debug(overlapHelperDevice() + " " + what + ": " + overlapHelperName(a) + " overlaps "
                    + overlapHelperName(b));
                ok = false;
            }
        }
    }
    return ok;
}

// -- The popup ------------------------------------------------------------------

//! How far text keeps from the display edge and from the lens: ScreenLayout's
//! default edge margin, the measure "fits" is taken with.
(:debug)
const OVERLAP_EDGE_MARGIN = 6;

//! The rules a popup is placed by (see the header), on one screen: `boxes`
//! as drawn, `hint` the texts the popup chooses from.
(:debug)
function overlapHelperPopup(what as String, boxes as Array<Array>, hint as Array<String>, v as PowerNapView,
                            dc as Graphics.Dc, logger as Test.Logger) as Boolean {
    var where = overlapHelperDevice() + " " + what + ": ";
    var sheet = [] as Array;
    var lines = [] as Array<Array>;
    var rows = [] as Array<Array>;
    for (var i = 0; i < boxes.size(); i++) {
        var kind = boxes[i][4] as Number;
        if (kind == ScreenLayout.BOX_BANNER) {
            sheet = boxes[i];
        } else if (kind == ScreenLayout.BOX_BANNER_TEXT) {
            lines.add(boxes[i]);
        } else if (kind != ScreenLayout.BOX_LENS_TEXT) {
            rows.add(boxes[i]);
        }
    }
    var ok = true;
    var top = sheet[1] as Number;

    // Whole rows only, the footer and everything down to the bottom edge.
    if ((sheet[0] as Number) > 0 || (sheet[0] as Number) + (sheet[2] as Number) < dc.getWidth()
        || top + (sheet[3] as Number) < dc.getHeight()) {
        logger.debug(where + overlapHelperName(sheet) + " does not run across the whole width to the bottom edge");
        ok = false;
    }
    var onRow = false;
    for (var i = 0; i < rows.size(); i++) {
        var ry = rows[i][1] as Number;
        if (ry == top) {
            onRow = true;
        } else if (ry < top && ry + (rows[i][3] as Number) > top) {
            logger.debug(where + "the popup's top edge, row " + top + ", cuts " + overlapHelperName(rows[i])
                + " in half");
            ok = false;
        }
    }
    if (!onRow) {
        logger.debug(where + "the popup's top edge, row " + top + ", is not the top edge of any row");
        ok = false;
    }

    // The exit popup's font.
    var font = overlapHelperPopupFont(dc);
    var layout = v.testBuildLayout(dc);
    var used = layout.testBannerFont();
    if (used == null || (used as Graphics.FontDefinition) != font) {
        logger.debug(where + "the popup is in " + overlapHelperFontName(used) + ", the exit popup in "
            + overlapHelperFontName(font));
        ok = false;
    }

    // The longest text that fits, as low as it fits.
    var text = layout.getBannerText();
    var index = -1;
    for (var i = 0; i < hint.size(); i++) {
        if (text != null && hint[i].equals(text as String)) {
            index = i;
        }
    }
    if (index < 0) {
        logger.debug(where + "the popup shows '" + text + "', which is not one of its texts");
        return false;
    }
    if (index > 0) {
        var at = overlapHelperPopupLowest(hint[index - 1], rows, font, dc);
        if (at >= 0) {
            logger.debug(where + "'" + hint[index - 1] + "' would fit under the row at " + at
                + " in the same font, the popup shows '" + text + "'");
            ok = false;
        }
    }
    var lowest = overlapHelperPopupLowest(text as String, rows, font, dc);
    if (lowest != top) {
        logger.debug(where + "the popup starts at row " + top + ", its text fits under the row at " + lowest
            + " (-1: under none)");
        ok = false;
    }
    if (lines.size() > 1 && overlapHelperPopupFitsAt([dc.getTextWidthInPixels(text as String, font)] as Array<Number>,
            top, dc.getFontHeight(font), dc)) {
        logger.debug(where + "'" + text + "' is on two lines where one fits");
        ok = false;
    }
    return ok;
}

//! The exit popup's font, which every popup is drawn in: the largest of
//! MEDIUM, SMALL, TINY and XTINY at which "Press BACK again to exit" fits on
//! one line across the middle of the display, in a box a font height wider
//! than the text and two thirds of one taller; XTINY where none does.
(:debug)
function overlapHelperPopupFont(dc as Graphics.Dc) as Graphics.FontDefinition {
    var fonts = [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY]
        as Array<Graphics.FontDefinition>;
    for (var i = 0; i < fonts.size(); i++) {
        var fh = dc.getFontHeight(fonts[i]);
        var h = fh + (fh * 2) / 3;
        var top = dc.getHeight() / 2 - h / 2;
        var b = overlapHelperBounds(top, top + h, dc);
        if (dc.getTextWidthInPixels(PowerNapView.HINT_EXIT[0], fonts[i]) + fh <= b[1] - b[0]) {
            return fonts[i];
        }
    }
    return Graphics.FONT_XTINY;
}

//! The lowest of `rows` under whose top edge a popup sheet leaves `text`
//! room in `font` - on one line, or broken at a space onto two - or -1
//! under none.
(:debug)
function overlapHelperPopupLowest(text as String, rows as Array<Array>, font as Graphics.FontDefinition,
                                  dc as Graphics.Dc) as Number {
    var fh = dc.getFontHeight(font);
    var forms = [[dc.getTextWidthInPixels(text, font)] as Array<Number>] as Array<Array<Number> >;
    var chars = text.toCharArray();
    for (var i = 1; i < chars.size() - 1; i++) {
        if (chars[i] == ' ') {
            forms.add([dc.getTextWidthInPixels(text.substring(0, i) as String, font),
                dc.getTextWidthInPixels(text.substring(i + 1, chars.size()) as String, font)] as Array<Number>);
        }
    }
    var lowest = -1;
    for (var r = 0; r < rows.size(); r++) {
        var t = rows[r][1] as Number;
        for (var f = 0; f < forms.size() && t > lowest; f++) {
            if (overlapHelperPopupFitsAt(forms[f], t, fh, dc)) {
                lowest = t;
            }
        }
    }
    return lowest;
}

//! Whether popup text of these line widths, in a font fh high, fits under a
//! sheet from row t, placed as the layout places it: on the sheet's widest
//! rows - centred on the middle of the display where the sheet reaches it,
//! else a third of a line under its top edge - each line inside the visible
//! width at its ink rows.
(:debug)
function overlapHelperPopupFitsAt(widths as Array<Number>, t as Number, fh as Number, dc as Graphics.Dc) as Boolean {
    var n = widths.size();
    var y = t + fh / 3;
    if (dc.getHeight() / 2 - (n * fh) / 2 > y) {
        y = dc.getHeight() / 2 - (n * fh) / 2;
    }
    if (y + n * fh > dc.getHeight()) {
        return false;
    }
    for (var k = 0; k < n; k++) {
        var ly = y + k * fh;
        var b = overlapHelperBounds(ly + fh * 15 / 100, ly + fh * 85 / 100, dc);
        if (widths[k] > b[1] - b[0]) {
            return false;
        }
    }
    return true;
}

//! The visible [left, right] on every row from y0 to y1 as the layout
//! measures it: the display (round chord, the Instinct's octagon),
//! OVERLAP_EDGE_MARGIN in from its edge and clear of the lens.
(:debug)
function overlapHelperBounds(y0 as Number, y1 as Number, dc as Graphics.Dc) as Array<Number> {
    var cx = dc.getWidth() / 2;
    var h0 = overlapHelperHalfWidth(y0, 0, dc);
    var h1 = overlapHelperHalfWidth(y1, 0, dc);
    var hw = (h0 < h1) ? h0 : h1;
    var left = cx - hw + OVERLAP_EDGE_MARGIN;
    var right = cx + hw - OVERLAP_EDGE_MARGIN;
    var lens = overlapHelperLens();
    if (lens != null) {
        var l = lens as Array<Number>;
        var ry = (l[1] < y0) ? y0 : ((l[1] > y1) ? y1 : l[1]);
        var dy = (ry - l[1]).abs();
        if (dy < l[2]) {
            var half = Math.sqrt((l[2] * l[2] - dy * dy).toFloat()).toNumber();
            if (l[0] >= cx) {
                var limit = l[0] - half - OVERLAP_EDGE_MARGIN;
                if (right > limit) {
                    right = limit;
                }
            } else {
                var limit = l[0] + half + OVERLAP_EDGE_MARGIN;
                if (left < limit) {
                    left = limit;
                }
            }
        }
    }
    if (right < left) {
        right = left;
    }
    return [left, right] as Array<Number>;
}

//! "XTINY": a font in a failure message.
(:debug)
function overlapHelperFontName(font as Graphics.FontDefinition?) as String {
    if (font == null) {
        return "no font";
    }
    var fonts = [Graphics.FONT_XTINY, Graphics.FONT_TINY, Graphics.FONT_SMALL, Graphics.FONT_MEDIUM]
        as Array<Graphics.FontDefinition>;
    var names = ["XTINY", "TINY", "SMALL", "MEDIUM"] as Array<String>;
    for (var i = 0; i < fonts.size(); i++) {
        if (fonts[i] == font) {
            return names[i];
        }
    }
    return "font " + font;
}

//! Why `box` is not inside the visible display, or null when it is.
(:debug)
function overlapHelperOutside(box as Array, ringR as Number, dc as Graphics.Dc) as String? {
    var x = box[0] as Number;
    var y = box[1] as Number;
    var w = box[2] as Number;
    var h = box[3] as Number;
    var kind = box[4] as Number;
    if (w <= 0 || h <= 0) {
        return null;                             // nothing drawn
    }
    var sw = dc.getWidth();
    if (x < 0 || y < 0 || x + w > sw || y + h > dc.getHeight()) {
        return "is off the screen";
    }
    if (kind == ScreenLayout.BOX_BANNER) {
        return null;                             // the popup's sheet: the display's outline cuts its corners
    }
    var lens = overlapHelperLens();
    if (kind == ScreenLayout.BOX_LENS_TEXT) {
        if (lens == null) {
            return "is drawn in a lens this watch does not have";
        }
        var l = lens as Array<Number>;
        if (x < l[3] || y < l[4] || x + w > l[3] + l[5] || y + h > l[4] + l[6]) {
            return "is not inside the lens " + l[3] + "," + l[4] + " " + l[5] + "x" + l[6];
        }
        return null;
    }
    // Text at its ink rows; shapes, dividers and the popup's box at every row.
    var text = (kind == ScreenLayout.BOX_TEXT || kind == ScreenLayout.BOX_BANNER_TEXT);
    var top = text ? y + h * 15 / 100 : y;
    var bottom = text ? y + h * 85 / 100 : y + h - 1;
    var rows = [top, bottom] as Array<Number>;
    for (var i = 0; i < rows.size(); i++) {
        var half = overlapHelperHalfWidth(rows[i], ringR, dc);
        if (x < sw / 2 - half || x + w > sw / 2 + half) {
            return "leaves the visible display at row " + rows[i] + " (visible " + (sw / 2 - half) + ".."
                + (sw / 2 + half) + ((ringR > 0) ? ", inside the ring" : "") + ")";
        }
    }
    if (lens != null) {
        // The point of the box's rows nearest the lens centre.
        var l = lens as Array<Number>;
        var nx = (l[0] < x) ? x : ((l[0] > x + w - 1) ? x + w - 1 : l[0]);
        var ny = (l[1] < top) ? top : ((l[1] > bottom) ? bottom : l[1]);
        var dx = nx - l[0];
        var dy = ny - l[1];
        if (dx * dx + dy * dy < l[2] * l[2]) {
            return "reaches into the lens (centre " + l[0] + "," + l[1] + ", radius " + l[2] + ")";
        }
    }
    return null;
}

//! Half the visible width at row y: the round display (and the summary
//! ring's inner edge when ringR > 0), or the Instinct 3 Solar's octagon as
//! ScreenLayout models it (corners bevelled over the outer 24 %).
(:debug)
function overlapHelperHalfWidth(y as Number, ringR as Number, dc as Graphics.Dc) as Number {
    var w = dc.getWidth();
    var h = dc.getHeight();
    if (y < 0 || y >= h) {
        return 0;
    }
    var shape = System.getDeviceSettings().screenShape;
    var half = w / 2;
    if (shape == System.SCREEN_SHAPE_ROUND) {
        half = overlapHelperChord(w / 2, y - h / 2);
    } else if (shape == System.SCREEN_SHAPE_SEMI_OCTAGON) {
        var edge = (y < h - 1 - y) ? y : (h - 1 - y);
        var cut = w * 24 / 100 - edge;
        if (cut > 0) {
            half -= cut;
        }
    }
    if (ringR > 0) {
        var inner = overlapHelperChord(ringR, y - h / 2);
        if (inner < half) {
            half = inner;
        }
    }
    return half;
}

//! Half the chord of a circle of radius r, dy rows from its centre.
(:debug)
function overlapHelperChord(r as Number, dy as Number) as Number {
    var a = (dy < 0) ? -dy : dy;
    if (a >= r) {
        return 0;
    }
    return Math.sqrt((r * r - a * a).toFloat()).toNumber();
}

//! The Instinct's lens as [centre x, centre y, radius, x, y, w, h], or null:
//! the lens and its bezel form a circle around the subscreen box of radius
//! w/2 + 13 (measured on the Instinct 3, as ScreenLayout keeps text out of it).
(:debug)
function overlapHelperLens() as Array<Number>? {
    if (!(WatchUi has :getSubscreen)) {
        return null;
    }
    try {
        var sub = WatchUi.getSubscreen();
        if (sub != null && sub.x != null && sub.y != null && sub.width != null && sub.height != null
            && (sub.width as Number) > 0) {
            var x = sub.x as Number;
            var y = sub.y as Number;
            var w = sub.width as Number;
            var h = sub.height as Number;
            return [x + w / 2, y + h / 2, w / 2 + 13, x, y, w, h] as Array<Number>;
        }
    } catch (e instanceof Lang.Exception) {
    }
    return null;
}

(:debug)
function overlapHelperIntersect(a as Array, b as Array) as Boolean {
    var ax = a[0] as Number;
    var ay = a[1] as Number;
    var aw = a[2] as Number;
    var ah = a[3] as Number;
    var bx = b[0] as Number;
    var by = b[1] as Number;
    var bw = b[2] as Number;
    var bh = b[3] as Number;
    if (aw <= 0 || ah <= 0 || bw <= 0 || bh <= 0) {
        return false;
    }
    return ax < bx + bw && bx < ax + aw && ay < by + bh && by < ay + ah;
}

//! `inner` lies entirely inside `outer`.
(:debug)
function overlapHelperContains(outer as Array, inner as Array) as Boolean {
    var ox = outer[0] as Number;
    var oy = outer[1] as Number;
    var ix = inner[0] as Number;
    var iy = inner[1] as Number;
    return ix >= ox && iy >= oy && ix + (inner[2] as Number) <= ox + (outer[2] as Number)
        && iy + (inner[3] as Number) <= oy + (outer[3] as Number);
}

(:debug)
function overlapHelperIsPopup(box as Array) as Boolean {
    var kind = box[4] as Number;
    return kind == ScreenLayout.BOX_BANNER || kind == ScreenLayout.BOX_BANNER_TEXT;
}

(:debug)
function overlapHelperHasPopup(boxes as Array<Array>) as Boolean {
    for (var i = 0; i < boxes.size(); i++) {
        if ((boxes[i][4] as Number) == ScreenLayout.BOX_BANNER) {
            return true;
        }
    }
    return false;
}

//! "'POWER NAP' 79,13 101x30": a box in a failure message.
(:debug)
function overlapHelperName(box as Array) as String {
    return (box[5] as String) + " " + (box[0] as Number) + "," + (box[1] as Number) + " "
        + (box[2] as Number) + "x" + (box[3] as Number);
}

//! "006-B3906-00 260x260": the device in a failure message.
(:debug)
function overlapHelperDevice() as String {
    var ds = System.getDeviceSettings();
    return ds.partNumber + " " + ds.screenWidth + "x" + ds.screenHeight;
}
