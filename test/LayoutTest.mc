import Toybox.Test;
import Toybox.Lang;
import Toybox.Graphics;
import Toybox.System;
import Toybox.Application;

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

//! View over the given detector, marked as started.
(:debug)
function layoutHelperView(d as SleepDetector, a as AlarmManager) as PowerNapView {
    var v = new PowerNapView(d, a);
    v.testSetStarted(true);
    return v;
}

//! Common checks; mustShow are text fragments that must appear on screen.
(:debug)
function layoutHelperCheck(name as String, v as PowerNapView, dc as Graphics.Dc,
                           mustShow as Array<String>, logger as Test.Logger) as Boolean {
    var L = v.testBuildLayout(dc);
    if (L == null) {
        logger.debug(name + ": no layout");
        return false;
    }
    var layout = L as ScreenLayout;
    var ok = true;
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
//! ("Alarm by") are always visible, also with the inactive warning and the
//! armed (longest) footer.
(:test)
function testLayout_monitoringScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var a = new AlarmManager();
    var d = new SleepDetector(null);
    d.testStart();
    var v = layoutHelperView(d, a);
    var ok = layoutHelperCheck("calibrating", v, dc, ["Calibrating", "Alarm by|By "] as Array<String>, logger);

    d.testSetBaseline(70.0f);
    d.testRunMinutes(1, 68, 10.0f);
    ok = layoutHelperCheck("monitoring", v, dc, ["Monitoring", "Stillness", "Alarm by|By "] as Array<String>, logger) && ok;

    d.noteInactive();
    v.pressStop(ConfirmPress.CONTEXT_NAP);
    ok = layoutHelperCheck("monitoring+warning+armed", v, dc,
        ["Monitoring", "Alarm by|By ", "Keep app open"] as Array<String>, logger) && ok;
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
    return layoutHelperCheck("awake", v, dc, ["Awake", "Alarm in"] as Array<String>, logger);
}

//! Sleeping screen with countdown, normal and inside the smart-wake window.
(:test)
function testLayout_sleepingScreens(logger as Test.Logger) as Boolean {
    var dc = layoutHelperDc();
    var d = layoutHelperAsleep();
    d.testRunMinutes(2, 55, 10.0f);
    var v = layoutHelperView(d, new AlarmManager());
    var ok = layoutHelperCheck("sleeping", v, dc, ["Wake in", "28:00"] as Array<String>, logger);
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
    ok = layoutHelperCheck("alarm nap complete", v, dc, ["WAKE UP!", "Slept"] as Array<String>, logger) && ok;
    v.pressStop(ConfirmPress.CONTEXT_ALARM);
    ok = layoutHelperCheck("alarm armed", v, dc, ["WAKE UP!"] as Array<String>, logger) && ok;

    // Deadline: never still, no HR.
    d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(5);
    d.testRunMinutes(21, 0, 300.0f);
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("alarm deadline", v, dc, ["TIME'S UP", "Waited 20 min"] as Array<String>, logger) && ok;

    // Smart wake.
    d = layoutHelperAsleep();
    d.testRunMinutes(26, 55, 10.0f);
    d.testRunSeconds(54, 55, 10.0f);
    d.testRunSeconds(6, 55, 100.0f);
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("alarm smart wake", v, dc, ["WAKE UP!"] as Array<String>, logger) && ok;
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
    ok = layoutHelperCheck("summary full", v, dc, ["COMPLETE|DONE", "30:00", "Uninterrupted"] as Array<String>, logger) && ok;

    d = layoutHelperAsleep();
    for (var i = 0; i < 2; i++) {
        d.testRunMinutes(3, 55, 10.0f);
        d.testRunMinutes(1, 60, 300.0f);
        d.testRunMinutes(2, 55, 10.0f);
    }
    d.testRunMinutes(20, 55, 10.0f);
    d.finishNap();
    v = layoutHelperView(d, new AlarmManager());
    ok = layoutHelperCheck("summary wakes", v, dc, ["COMPLETE|DONE", "2 wakes"] as Array<String>, logger) && ok;

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
    var v = new PowerNapView(new SleepDetector(null), new AlarmManager());
    var zones = v.testMeasureTapZones(dc);
    var plusMax = zones[0];
    var minusMin = zones[1];
    var expectedBand = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM) + dc.getFontHeight(Graphics.FONT_SMALL);
    var ok = true;
    if (minusMin - plusMax != expectedBand) {
        logger.debug("start band " + (minusMin - plusMax) + " px, expected number + label " + expectedBand);
        ok = false;
    }
    if (v.tapActionAt(plusMax - 1) != 1 || v.tapActionAt(plusMax) != 0
        || v.tapActionAt((plusMax + minusMin) / 2) != 0
        || v.tapActionAt(minusMin) != 0 || v.tapActionAt(minusMin + 1) != -1) {
        logger.debug("tap zone mapping wrong around " + plusMax + ".." + minusMin);
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
