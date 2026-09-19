import Toybox.Test;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.System;
import Toybox.Application;
import Toybox.Time;

// -----------------------------------------------------------------------------
// Screen layout tests.
//
// Each test drives the real PowerNapView layout code for one screen state and
// solves it against a Dc of the running device's screen size (a 1-bit buffered
// bitmap: only the device fonts matter for measuring). Assertions:
//   * no overflow (content fits between the top margin and the footer),
//   * every visible line and the footer fit the visible width at their rows
//     (round bezel, octagon corners, Instinct subscreen),
//   * the last line ends above the footer,
//   * the key information of that screen is still shown.
// Run the suite on several devices (fenix847mm, instinct3solar45mm, fenix7s,
// fr255s, venu3s) to cover 176-454 px screens.
// -----------------------------------------------------------------------------

//! Screen-sized Dc for measuring.
(:debug)
function layoutHelperDc() as Graphics.Dc {
    var ds = System.getDeviceSettings();
    var ref = Graphics.createBufferedBitmap({
        :width => ds.screenWidth,
        :height => ds.screenHeight,
        :palette => [Graphics.COLOR_BLACK, Graphics.COLOR_WHITE] as Array<Graphics.ColorType>
    });
    return (ref.get() as Graphics.BufferedBitmap).getDc();
}

//! View over the given detector, marked as started. A full battery, whatever
//! the simulator says (tests turn the warning on explicitly).
(:debug)
function layoutHelperView(d as SleepDetector, a as AlarmManager) as PowerNapView {
    var v = layoutHelperStartView(d, a);
    v.testSetStarted(true);
    return v;
}

//! Start-screen view with a full battery.
(:debug)
function layoutHelperStartView(d as SleepDetector, a as AlarmManager) as PowerNapView {
    var v = new PowerNapView(d, a);
    v.testForceBattery(100);
    return v;
}

//! Layout work budget per screen build (every screen redraws once a second,
//! and the Instinct watchdog allows 240k bytecodes per event): solve passes
//! and fitLine calls. Round screens need 1-2 passes; the Instinct lens more.
(:debug)
const LAYOUT_MAX_PASSES = 6;
(:debug)
const LAYOUT_MAX_FITS = 60;

//! Common checks; mustShow are text fragments that must appear on screen.
(:debug)
function layoutHelperCheck(name as String, v as PowerNapView, dc as Graphics.Dc,
                           mustShow as Array<String>, logger as Test.Logger) as Boolean {
    var layout = v.testBuildLayout(dc);
    var ok = true;
    var work = layout.testWork();
    if (work[0] > LAYOUT_MAX_PASSES || work[1] > LAYOUT_MAX_FITS) {
        logger.debug(name + ": layout work " + work[0] + " passes, " + work[1] + " line fits, over budget");
        ok = false;
    }
    if (!layout.testDividersFit()) {
        logger.debug(name + ": a divider is outside the visible width or has no title");
        ok = false;
    }
    if (layout.hasOverflow()) {
        logger.debug(name + ": content overflows the screen");
        ok = false;
    }
    if (!layout.allTextFits()) {
        logger.debug(name + ": wider than the visible display: '" + layout.firstMisfit() + "'");
        ok = false;
    }
    if (!layout.clearOfFooter(dc)) {
        logger.debug(name + ": last line overprints the footer");
        ok = false;
    }
    for (var i = 0; i < mustShow.size(); i++) {
        // "A|B" accepts either fragment (short variants on small screens).
        var alts = layoutHelperSplit(mustShow[i]);
        var found = false;
        for (var j = 0; j < alts.size() && !found; j++) {
            found = layout.showsFragment(alts[j]);
        }
        if (!found) {
            logger.debug(name + ": missing '" + mustShow[i] + "'");
            ok = false;
        }
    }
    return ok;
}

//! Split "A|B|C" into ["A", "B", "C"].
(:debug)
function layoutHelperSplit(s as String) as Array<String> {
    var out = [] as Array<String>;
    var rest = s;
    var idx = rest.find("|");
    while (idx != null) {
        out.add(rest.substring(0, idx as Number) as String);
        rest = rest.substring((idx as Number) + 1, rest.length()) as String;
        idx = rest.find("|");
    }
    out.add(rest);
    return out;
}

//! Detector asleep with HR stats: 30-min nap, baseline 70, onset forced.
(:debug)
function layoutHelperAsleep() as SleepDetector {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    return d;
}

//! Calibrating and monitoring screens: status and the guaranteed alarm time
//! ("Latest alarm") are always visible, also with the inactive warning and the
//! armed (longest) footer.
(:test)
function testLayout_monitoringScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var a = new AlarmManager();
    var d = new SleepDetector(null);
    d.testStart();
    var v = layoutHelperView(d, a);
    var ok = layoutHelperCheck("calibrating", v, dc, ["Calibrating", "Latest|By "] as Array<String>, logger);

    d.testSetBaseline(70.0f);
    d.testRunMinutes(1, 68, 10.0f);
    ok = layoutHelperCheck("monitoring", v, dc, ["Monitoring", "Stillness", "Latest|By "] as Array<String>, logger) && ok;

    d.noteInactive();
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    ok = layoutHelperCheck("monitoring+warning+armed", v, dc,
        ["Monitoring", "Latest|By ", "Keep app open"] as Array<String>, logger) && ok;
    return ok;
}

//! Awake after a wake episode: the running countdown is shown.
(:test)
function testLayout_awakeAfterWake(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var d = layoutHelperAsleep();
    d.testRunMinutes(3, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);
    var v = layoutHelperView(d, new AlarmManager());
    var ok = layoutHelperCheck("awake", v, dc, ["Awake", "Alarm in", "Alarm at|At "] as Array<String>, logger);
    if (v.testBuildLayout(dc).showsFragment("after sleep")) {
        logger.debug("after a wake the alarm is fixed: no 'N min after sleep' rule");
        ok = false;
    }
    return ok;
}

//! Sleeping screen with countdown, normal and inside the smart-wake window.
(:test)
function testLayout_sleepingScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var d = layoutHelperAsleep();
    d.testRunMinutes(2, 55, 10.0f);
    var v = layoutHelperView(d, new AlarmManager());
    var ok = layoutHelperCheck("sleeping", v, dc, ["Wake at|At |Wake in", "28:00"] as Array<String>, logger);
    d.testRunMinutes(24, 55, 10.0f);
    ok = layoutHelperCheck("smart window", v, dc, ["Smart Wake", "4:00"] as Array<String>, logger) && ok;
    d.noteInactive();
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    ok = layoutHelperCheck("sleeping+warning+armed", v, dc, ["Keep app open", "4:00"] as Array<String>, logger) && ok;
    return ok;
}

//! Alarm screens for all three reasons, including the armed footer.
(:test)
function testLayout_alarmScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var ok = true;

    // Nap complete with HR stats.
    var d = layoutHelperAsleep();
    d.testRunMinutes(31, 55, 10.0f);
    var v = layoutHelperView(d, new AlarmManager());
    // Gentle phase (the view's alarm manager has not rung yet): calm words.
    ok = layoutHelperCheck("alarm nap complete", v, dc, ["wake up|Wake up", "Slept"] as Array<String>, logger) && ok;
    if (v.testIsFlashPhase()) {
        logger.debug("the gentle phase must not flash");
        ok = false;
    }
    v.pressStop(ConfirmPress.CONTEXT_ALARM);
    ok = layoutHelperCheck("alarm armed", v, dc, ["wake up|Wake up"] as Array<String>, logger) && ok;

    // After ring 11 (the last of phase 2) the next ring is full intensity,
    // but the screen is still calm and the counter shows the phase felt: 3/4.
    var edgeAlarm = new AlarmManager();
    edgeAlarm.testSetAlarmType(0);
    edgeAlarm.startAlarm();
    while (edgeAlarm.testGetRingCount() < 12) {
        edgeAlarm.testFireRing();
    }
    v = layoutHelperView(d, edgeAlarm);
    var edge = v.testBuildLayout(dc);
    if (v.testIsFlashPhase() || edge.showsFragment("4/4") || !edge.showsFragment("3/4")) {
        logger.debug("before ring 12: calm screen and counter 3/4 expected");
        ok = false;
    }
    edgeAlarm.stop();

    // Full intensity: the loud screen, flashing.
    var loudAlarm = new AlarmManager();
    loudAlarm.testSetAlarmType(0);
    loudAlarm.startAlarm();
    while (loudAlarm.testGetRingCount() < 13) {
        loudAlarm.testFireRing();
    }
    v = layoutHelperView(d, loudAlarm);
    ok = layoutHelperCheck("alarm full intensity", v, dc, ["WAKE UP!", "Slept"] as Array<String>, logger) && ok;
    if (!v.testIsFlashPhase()) {
        logger.debug("full intensity must flash");
        ok = false;
    }
    loudAlarm.stop();

    // Deadline: never still, no HR.
    d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(5);
    d.testRunMinutes(21, 0, 300.0f);
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("alarm deadline", v, dc, ["Time's up", "Waited 20 min"] as Array<String>, logger) && ok;

    // Smart wake.
    d = layoutHelperAsleep();
    d.testRunMinutes(26, 55, 10.0f);
    d.testRunSeconds(54, 55, 10.0f);
    d.testRunSeconds(6, 55, 100.0f);
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("alarm smart wake", v, dc, ["wake up|Wake up", "Smart wake"] as Array<String>, logger) && ok;
    if (d.getAlarmReason() != SleepDetector.ALARM_SMART_WAKE) {
        logger.debug("setup: expected smart wake");
        ok = false;
    }
    return ok;
}

//! Summary screens: uninterrupted, with wakes (longest label), stopped, and
//! the no-sleep summary.
(:test)
function testLayout_summaryScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var ok = true;

    var d = layoutHelperAsleep();
    d.testRunMinutes(31, 55, 10.0f);
    d.finishNap();
    var v = layoutHelperView(d, new AlarmManager());
    if ((v.testBuildLayout(dc).getFooterText() as String).find("START") == null) {
        logger.debug("the summary footer must tell that START sets up a new nap");
        ok = false;
    }
    ok = layoutHelperCheck("summary full", v, dc,
        ["COMPLETE|DONE|100%", "30:00", "Uninterrupted", "in 0 min|0 min to sleep"] as Array<String>, logger) && ok;

    d = layoutHelperAsleep();
    for (var i = 0; i < 2; i++) {
        d.testRunMinutes(3, 55, 10.0f);
        d.testRunMinutes(1, 60, 300.0f);
        d.testRunMinutes(2, 55, 10.0f);
    }
    d.testRunMinutes(20, 55, 10.0f);
    d.finishNap();
    v = layoutHelperView(d, new AlarmManager());
    // Without the ring (Instinct) the title may shrink to just the %.
    ok = layoutHelperCheck("summary wakes", v, dc, ["COMPLETE|DONE|100%", "2 wakes"] as Array<String>, logger) && ok;

    d = layoutHelperAsleep();
    d.testRunMinutes(10, 55, 10.0f);
    d.cancel();
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("summary stopped", v, dc, ["STOP", "Stopped"] as Array<String>, logger) && ok;

    d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(5);
    d.testRunMinutes(21, 0, 300.0f);
    d.finishNap();
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("summary no sleep", v, dc, ["No sleep", "Timer alarm", "Waited 20 min"] as Array<String>, logger) && ok;
    return ok;
}

//! Start-screen tap zones follow the drawn layout: the number and the "min"
//! label start the nap, everything above adds and everything below removes.
(:test)
function testLayout_startScreenTapZones(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var v = layoutHelperStartView(new SleepDetector(null), new AlarmManager());
    var zones = v.testMeasureTapZones(dc);
    var plusMax = zones[0];
    var minusMin = zones[1];
    // The number keeps its big font and sits right on top of its label.
    var expectedBand = zones[2] + zones[3];
    var ok = true;
    if (zones[2] != dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM)) {
        logger.debug("the duration must keep FONT_NUMBER_MEDIUM");
        ok = false;
    }
    if (minusMin - plusMax != expectedBand) {
        logger.debug("start band " + (minusMin - plusMax) + " px, expected number + label " + expectedBand);
        ok = false;
    }
    if (plusMax <= 0 || minusMin >= dc.getHeight()) {
        logger.debug("start band " + plusMax + ".." + minusMin + " leaves no room for the +/- zones");
        ok = false;
    }
    if (v.tapActionAt(plusMax - 1) != 1 || v.tapActionAt(plusMax) != 0
        || v.tapActionAt((plusMax + minusMin) / 2) != 0
        || v.tapActionAt(minusMin) != 0 || v.tapActionAt(minusMin + 1) != -1) {
        logger.debug("tap zone mapping wrong around " + plusMax + ".." + minusMin);
        ok = false;
    }
    // The hint at the bottom ("TAP to begin") starts; just above it removes.
    var hintY = zones[4];
    if (hintY <= minusMin + 1 || v.tapActionAt(hintY) != 0 || v.tapActionAt(hintY + 5) != 0
        || v.tapActionAt(hintY - 1) != -1) {
        logger.debug("hint zone wrong: hint at " + hintY + ", label ends at " + minusMin);
        ok = false;
    }
    // Touch watches say TAP, the others (FR255, Instinct 3) say START.
    var touch = System.getDeviceSettings().isTouchScreen;
    var footer = v.testBuildLayout(dc).getFooterText();
    var expected = touch ? "TAP to begin" : "START to begin";
    if (footer == null || !(footer as String).equals(expected)) {
        logger.debug("hint '" + footer + "', expected '" + expected + "' (touch " + touch + ")");
        ok = false;
    }
    return ok;
}

//! A nap duration changed from the phone follows on the start screen, but not
//! once a nap is running.
(:test)
function testLayout_startScreenFollowsPhoneSetting(logger as Test.Logger) as Boolean {
    var nap0 = Application.Properties.getValue("napDuration");
    var ok = true;
    try {
        Application.Properties.setValue("napDuration", 30);
        var v = new PowerNapView(new SleepDetector(null), new AlarmManager());
        Application.Properties.setValue("napDuration", 45);
        v.onSettingsChanged();
        if (v.testGetPendingDuration() != 45) {
            logger.debug("start screen must follow the phone: " + v.testGetPendingDuration());
            ok = false;
        }
        v.testSetStarted(true);
        Application.Properties.setValue("napDuration", 60);
        v.onSettingsChanged();
        if (v.testGetPendingDuration() != 45) {
            logger.debug("running nap must not change the pending duration");
            ok = false;
        }
    } catch (e instanceof Lang.Exception) {
        ok = false;
    }
    try {
        Application.Properties.setValue("napDuration", (nap0 != null) ? nap0 as Number : 30);
    } catch (e instanceof Lang.Exception) {
    }
    return ok;
}

//! Start screen for short, long and Stay Awake durations: everything fits,
//! the duration, its label and the promise (Latest alarm / what Stay Awake
//! does) are shown.
(:test)
function testLayout_startScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var v = layoutHelperStartView(new SleepDetector(null), new AlarmManager());
    var ok = true;
    var durations = [5, 30, 120] as Array<Number>;
    for (var i = 0; i < durations.size(); i++) {
        v.testSetPendingDuration(durations[i]);
        ok = layoutHelperCheck("start " + durations[i], v, dc,
            [durations[i].toString(), "min", "Latest|By "] as Array<String>, logger) && ok;
    }
    v.testSetPendingDuration(0);
    ok = layoutHelperCheck("start stay awake", v, dc, ["0", "stay awake", "doze"] as Array<String>, logger) && ok;
    return ok;
}

//! The peek card (UP/DOWN/START during a nap) before and after onset, with
//! wakes and the armed footer, and in Stay Awake mode.
(:test)
function testLayout_peekScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var ok = true;

    var d = new SleepDetector(null);
    d.testStart();
    var v = layoutHelperView(d, new AlarmManager());
    v.showPeek();
    ok = layoutHelperCheck("peek before onset", v, dc, ["No sleep yet", "Latest|By "] as Array<String>, logger) && ok;

    d = layoutHelperAsleep();
    d.testRunMinutes(3, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);
    d.testRunMinutes(2, 55, 10.0f);
    v = layoutHelperView(d, new AlarmManager());
    v.showPeek();
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    ok = layoutHelperCheck("peek asleep + armed", v, dc, ["Slept", "1 wake", "Alarm at|At "] as Array<String>, logger) && ok;
    if ((v.testBuildLayout(dc).getFooterText() as String).find("stats") == null) {
        logger.debug("armed footer after sleep must mention the stats");
        ok = false;
    }

    d = new SleepDetector(null);
    d.testStartStayAwake();
    d.testRunMinutes(3, 70, 200.0f);
    v = layoutHelperView(d, new AlarmManager());
    v.showPeek();
    ok = layoutHelperCheck("peek stay awake", v, dc, ["Awake 3:00", "No dozes"] as Array<String>, logger) && ok;
    return ok;
}

//! Stay Awake screens: guarding (with every optional line and the armed
//! footer), the drowsiness warning, the doze alarm and the summary.
(:test)
function testLayout_stayAwakeScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var ok = true;
    var d = new SleepDetector(null);
    d.testStartStayAwake();
    var v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("stay calibrating", v, dc,
        ["Keeping you awake|Keeping awake|On guard", "Awake"] as Array<String>, logger) && ok;

    d.testRunMinutes(3, 70, 10.0f);
    ok = layoutHelperCheck("stay warning", v, dc, ["Stay alert!"] as Array<String>, logger) && ok;

    d.testRunMinutes(2, 70, 10.0f);
    ok = layoutHelperCheck("doze alarm", v, dc, ["WAKE UP!", "dozed off|Dozed off"] as Array<String>, logger) && ok;

    d.dismissAlarm();
    d.testRunMinutes(1, 70, 200.0f);
    // The 176 px Instinct has room for three lines here: the hint (95) and
    // the doze count (85) win over the session time (80).
    ok = layoutHelperCheck("stay guarding after a doze", v, dc,
        (dc.getHeight() >= 200 ? ["Keeping you awake|Keeping awake|On guard", "1 doze", "Awake"]
                               : ["Keeping you awake|Keeping awake|On guard", "1 doze"]) as Array<String>, logger) && ok;

    // Crowded: the low-battery and inactive warnings and the armed footer;
    // the warnings must stay.
    d.noteInactive();
    v.testForceBattery(5);
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    ok = layoutHelperCheck("stay guarding + warnings + armed", v, dc,
        ["Keeping you awake|Keeping awake|On guard", "Keep app open", "attery 5%|Batt 5%"] as Array<String>, logger) && ok;
    v.testForceBattery(100);

    d.cancel();
    ok = layoutHelperCheck("stay summary", v, dc, ["STAY AWAKE|AWAKE", "1 doze"] as Array<String>, logger) && ok;

    // A session over an hour shows h:mm:ss.
    d = new SleepDetector(null);
    d.testStartStayAwake();
    d.testAdvanceClock(3 * 3600 + 25 * 60 + 7);
    d.cancel();
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("stay summary long", v, dc, ["3:25:07", "No dozes"] as Array<String>, logger) && ok;
    return ok;
}


//! The time of day is on every live screen (monitoring, asleep, alarm, Stay
//! Awake, peek), except on the Instinct where it is drawn in the lens.
(:test)
function testLayout_clockOnLiveScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var probe = new PowerNapView(new SleepDetector(null), new AlarmManager());
    if (probe.testHasSubscreen()) {
        return true;
    }
    var ok = true;
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    var v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperClock("monitoring", v, dc, logger) && ok;
    d.testForceSleep();
    ok = layoutHelperClock("asleep", v, dc, logger) && ok;
    v.showPeek();
    ok = layoutHelperClock("peek", v, dc, logger) && ok;
    d.testAdvanceClock(31 * 60);
    d.testTick();
    ok = layoutHelperClock("alarm", v, dc, logger) && ok;

    d = new SleepDetector(null);
    d.testStartStayAwake();
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperClock("stay awake", v, dc, logger) && ok;
    return ok;
}

//! Clock shown on this screen (either side of a minute change counts).
(:debug)
function layoutHelperClock(name as String, v as PowerNapView, dc as Graphics.Dc, logger as Test.Logger) as Boolean {
    var before = v.testClockString();
    var layout = v.testBuildLayout(dc);
    var after = v.testClockString();
    if (!layout.showsText(before) && !layout.showsText(after)) {
        logger.debug(name + ": clock " + before + " not shown");
        return false;
    }
    return true;
}

//! Low battery (5 %, not charging) is shown on the start screen and the Stay
//! Awake screen, and on the monitoring screen it never pushes out "Latest".
(:test)
function testLayout_lowBatteryWarning(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var ok = true;
    // The 176 px Instinct has room for one line under the duration: there the
    // warning (act on it before the nap) wins, and "Latest alarm" shows on
    // the monitoring screen right after START. Larger screens show both.
    var roomy = dc.getHeight() >= 200;
    var v = layoutHelperStartView(new SleepDetector(null), new AlarmManager());
    v.testForceBattery(5);
    ok = layoutHelperCheck("start low battery", v, dc,
        (roomy ? ["battery 5%|Battery 5%|Batt 5%", "Latest|By "] : ["battery 5%|Battery 5%|Batt 5%"])
            as Array<String>, logger) && ok;
    v.testForceBattery(15);
    ok = layoutHelperCheck("start 15% is not low", v, dc, ["Latest|By "] as Array<String>, logger) && ok;
    if (v.testBuildLayout(dc).showsFragment("attery")) {
        logger.debug("15% battery must not warn");
        ok = false;
    }

    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    v = layoutHelperView(d, new AlarmManager());
    v.testForceBattery(5);
    ok = layoutHelperCheck("monitoring low battery", v, dc, ["Monitoring", "Latest|By "] as Array<String>, logger) && ok;
    d.noteInactive();
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    ok = layoutHelperCheck("monitoring low battery crowded", v, dc, ["Monitoring", "Latest|By "] as Array<String>, logger) && ok;

    d = new SleepDetector(null);
    d.testStartStayAwake();
    v = layoutHelperView(d, new AlarmManager());
    v.testForceBattery(5);
    ok = layoutHelperCheck("stay awake low battery", v, dc,
        ["Keeping you awake|Keeping awake|On guard", "battery 5%|Battery 5%|Batt 5%"] as Array<String>, logger) && ok;
    return ok;
}

//! The start-screen number only shrinks when that keeps the promise line on
//! screen: with a warning it either keeps its full size, or it is smaller
//! and "Latest alarm" is shown (on the Instinct the warning replaces the
//! promise and the number stays full size).
(:test)
function testLayout_startNumberShrinksOnlyForThePromise(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var full = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
    var ok = true;
    var pcts = [5, 100] as Array<Number>;
    for (var i = 0; i < pcts.size(); i++) {
        var v = layoutHelperStartView(new SleepDetector(null), new AlarmManager());
        v.testSetPendingDuration(30);
        v.testForceBattery(pcts[i]);
        var zones = v.testMeasureTapZones(dc);
        var layout = v.testBuildLayout(dc);
        if (zones[2] < full && !layout.showsFragment("Latest") && !layout.showsFragment("By ")) {
            logger.debug("battery " + pcts[i] + "%: number shrank to " + zones[2] + " px but the promise is gone");
            ok = false;
        }
        if (pcts[i] == 100 && zones[2] != full) {
            logger.debug("without warnings the number must keep its full size");
            ok = false;
        }
    }
    return ok;
}

//! Cases the audit found on the Instinct lens (they must hold everywhere):
//! the promise survives the calibrating screen with a 3-digit HR and the
//! armed footer; the Stay Awake hint shows; 10 h sessions and 12 dozes fit.
(:test)
function testLayout_lensAndLongValues(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var ok = true;

    var d = new SleepDetector(null);
    d.testStart();
    d.testFeedHR(100);
    var v = layoutHelperView(d, new AlarmManager());
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    ok = layoutHelperCheck("calibrating HR 100 armed", v, dc, ["Calibrating", "Latest|By "] as Array<String>, logger) && ok;
    d.noteInactive();
    ok = layoutHelperCheck("calibrating HR 100 armed + inactive", v, dc,
        ["Calibrating", "Latest|By ", "Keep app open"] as Array<String>, logger) && ok;

    d = new SleepDetector(null);
    d.testStartStayAwake();
    d.testRunMinutes(3, 70, 200.0f);
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("stay guard hint", v, dc, ["Buzz"] as Array<String>, logger) && ok;

    d = new SleepDetector(null);
    d.testStartStayAwake();
    d.testRunMinutes(3, 70, 200.0f);
    d.testAdvanceClock(10 * 3600);
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("stay guard 10 h", v, dc, ["10:0"] as Array<String>, logger) && ok;
    v.showPeek();
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    ok = layoutHelperCheck("stay peek 10 h armed", v, dc, ["10:0"] as Array<String>, logger) && ok;
    d.cancel();
    ok = layoutHelperCheck("stay summary 10 h", v, dc, ["10:0", "No dozes"] as Array<String>, logger) && ok;

    // 12 dozes.
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
    d = new SleepDetector(null);
    d.testStartStayAwake();
    v = layoutHelperView(d, a);
    for (var i = 0; i < 12; i++) {
        d.testRunMinutes(5, 70, 10.0f);
        if (i == 11) {
            ok = layoutHelperCheck("doze alarm #12", v, dc, ["Doze #12|dozed off|Dozed off"] as Array<String>, logger) && ok;
        }
        d.dismissAlarm();
        d.testRunMinutes(1, 70, 200.0f);
    }
    ok = layoutHelperCheck("stay guard 12 dozes", v, dc, ["12 dozes"] as Array<String>, logger) && ok;
    d.cancel();
    ok = layoutHelperCheck("stay summary 12 dozes", v, dc, ["12 dozes"] as Array<String>, logger) && ok;
    return ok;
}

//! Without the summary ring (the Instinct) the completion % is shown as text.
(:test)
function testLayout_completionShownWithoutRing(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var probe = new PowerNapView(new SleepDetector(null), new AlarmManager());
    if (probe.testHasSubscreen() == false && System.getDeviceSettings().screenShape == System.SCREEN_SHAPE_ROUND) {
        return true;                             // round screens show it as the ring
    }
    var d = layoutHelperAsleep();
    d.testRunMinutes(31, 55, 10.0f);
    d.finishNap();
    var v = layoutHelperView(d, new AlarmManager());
    var ok = layoutHelperCheck("summary full (no ring)", v, dc, ["100%"] as Array<String>, logger);
    d = layoutHelperAsleep();
    d.testRunMinutes(10, 55, 10.0f);
    d.cancel();
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("summary stopped (no ring)", v, dc, ["33%"] as Array<String>, logger) && ok;
    return ok;
}

//! The promised time itself: "Latest alarm" is the deadline rounded UP to the
//! minute (never earlier than the real alarm), and after onset "Wake at" /
//! "Alarm at" is the minute of the planned end.
(:test)
function testLayout_promiseValues(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    var v = layoutHelperView(d, new AlarmManager());
    var deadline = d.testGetDeadlineSec();
    var latest = v.testFormatMoment(new Time.Moment(deadline + 59));
    var ok = layoutHelperCheck("promise before sleep", v, dc, [latest] as Array<String>, logger);
    if (deadline % 60 != 0) {
        var early = v.testFormatMoment(new Time.Moment(deadline));
        if (!early.equals(latest) && v.testBuildLayout(dc).showsFragment(early)) {
            logger.debug("the promise must be rounded up, not down: " + early);
            ok = false;
        }
    }
    d.testForceSleep();
    var at = v.testFormatMoment(new Time.Moment(d.testGetNapEndSec()));
    ok = layoutHelperCheck("wake at after onset", v, dc, [at] as Array<String>, logger) && ok;

    // The start-screen preview is the same formula before START.
    var s = layoutHelperStartView(new SleepDetector(null), new AlarmManager());
    s.testSetPendingDuration(30);
    var before = s.testFormatMoment(new Time.Moment(Time.now().value() + 45 * 60 + 59));
    var layout = s.testBuildLayout(dc);
    var after = s.testFormatMoment(new Time.Moment(Time.now().value() + 45 * 60 + 59));
    if (!layout.showsFragment(before) && !layout.showsFragment(after)) {
        logger.debug("start preview must show start + 15 + 30 min, rounded up: " + before);
        ok = false;
    }
    return ok;
}

//! Logs the layout work of the heaviest screens on this device (the most
//! lines, warnings, armed footers), for the record; the budget itself is
//! checked by every layoutHelperCheck.
(:test)
function testLayout_workOfHeaviestScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var d = new SleepDetector(null);
    d.testStart();
    d.testFeedHR(100);
    d.noteInactive();
    var v = layoutHelperView(d, new AlarmManager());
    v.testForceBattery(5);
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    var w1 = v.testBuildLayout(dc).testWork();
    d = new SleepDetector(null);
    d.testStartStayAwake();
    d.testRunMinutes(3, 70, 200.0f);
    d.noteInactive();
    v = layoutHelperView(d, new AlarmManager());
    v.testForceBattery(5);
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    var w2 = v.testBuildLayout(dc).testWork();
    logger.debug("layout work: calibrating crowded " + w1[0] + "/" + w1[1] + ", Stay Awake crowded "
        + w2[0] + "/" + w2[1] + " (passes/line fits)");
    return w1[0] <= LAYOUT_MAX_PASSES && w1[1] <= LAYOUT_MAX_FITS
        && w2[0] <= LAYOUT_MAX_PASSES && w2[1] <= LAYOUT_MAX_FITS;
}
