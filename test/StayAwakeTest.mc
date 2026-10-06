import Toybox.Attention;
import Toybox.Test;
import Toybox.Lang;
import Toybox.Time;

// -----------------------------------------------------------------------------
// Stay Awake mode (nap duration 0): the watch keeps the user awake and buzzes
// when they doze off.
//
// testStartStayAwake() starts a session with the documented defaults (5 BPM,
// 50 mg) on the frozen clock. Rules under test:
//   * no timed alarm at all (no deadline, no nap end);
//   * dozing = the nap onset rules: 2 still minutes with an HR drop, or 5
//     still minutes; the HR drop is measured against a rolling reference
//     (minutes 4-13 ago) once 5 such minutes exist;
//   * one gentle nudge at 3 still minutes;
//   * the doze alarm starts loud, at 63 % (its own table, not the nap's
//     ramp); dismissing it goes back on guard;
//   * the session ends only when the user stops it, with its own summary.
// -----------------------------------------------------------------------------

//! Stay Awake detector, optionally wired to an alarm manager (vibration).
(:debug)
function stayHelperStart(a as AlarmManager?) as SleepDetector {
    var d = new SleepDetector(a);
    d.testStartStayAwake();
    return d;
}

(:debug)
function stayHelperAlarm() as AlarmManager {
    return new AlarmManager();
}

//! One minute that is awake but calm: 6 active seconds (not a still minute,
//! not a wake), like turning pages while reading.
(:debug)
function stayHelperReadingMinute(d as SleepDetector, hr as Number) as Void {
    d.testRunSeconds(54, hr, 10.0f);
    d.testRunSeconds(6, hr, 100.0f);
}

//! Hours of activity never ring: there is no timed alarm in Stay Awake mode.
(:test)
function testStay_noTimedAlarmEver(logger as Test.Logger) as Boolean {
    var d = stayHelperStart(null);
    if (!d.isStayAwake() || d.getNapDurationMin() != 0 || d.testGetDeadlineSec() != 0) {
        logger.debug("expected Stay Awake with no deadline");
        return false;
    }
    d.testRunMinutes(30, 72, 200.0f);
    d.testAdvanceClock(10 * 3600);
    d.testTick();
    d.onResume();
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("no alarm expected, state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }
    return true;
}

//! Still from the start with a steady HR: calibration counts, nudge at 3
//! still minutes (once), doze alarm exactly at 5 still minutes (300 s),
//! starting loud (its first ring at least 60 %).
(:test)
function testStay_fiveStillMinutesRingDozeAlarm(logger as Test.Logger) as Boolean {
    var a = stayHelperAlarm();
    var d = stayHelperStart(a);
    var ok = true;
    d.testRunMinutes(3, 70, 10.0f);
    if (a.testGetNudgeCount() != 1 || !d.isDozeWarning() || d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("3 still minutes: nudges " + a.testGetNudgeCount() + " warning " + d.isDozeWarning());
        ok = false;
    }
    d.testRunMinutes(1, 70, 10.0f);
    d.testRunSeconds(59, 70, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING || a.testGetNudgeCount() != 1) {
        logger.debug("299 s: state " + d.getState() + " nudges " + a.testGetNudgeCount());
        ok = false;
    }
    d.testFeedSecond(70, 10.0f);
    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_DOZE
        || d.getDozeCount() != 1 || d.testNowSec() - d.testGetStartSec() != 300) {
        logger.debug("expected the doze alarm at 300 s, state " + d.getState() + " reason " + d.getAlarmReason());
        ok = false;
    }
    var felt = a.testGetLastPattern();
    if (!a.isAlarming() || a.testGetRingsFired() != 1 || felt == null
        || (felt as Array<Attention.VibeProfile>)[0].dutyCycle < 60) {
        logger.debug("the doze alarm must start loud (at least 60 %), rings " + a.testGetRingsFired());
        ok = false;
    }
    if (d.hasSleptAtLeastOnce() || d.getActualNapDurationSec() != 0 || d.getRemainingSeconds() != 0) {
        logger.debug("Stay Awake must never record a nap");
        ok = false;
    }
    a.stop();
    return ok;
}

//! Restless calibration at 70 BPM, then HR 62 while still: the drop to the
//! baseline (mean of the last 3 minutes 64.7, drop 5.3) makes 2 still
//! minutes enough -> doze alarm at 240 s, without a nudge.
(:test)
function testStay_hrDropDozesAfterTwoStillMinutes(logger as Test.Logger) as Boolean {
    var a = stayHelperAlarm();
    var d = stayHelperStart(a);
    d.testRunMinutes(2, 70, 200.0f);
    d.testRunMinutes(1, 62, 10.0f);
    var ok = true;
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("one still minute must not doze, state " + d.getState());
        ok = false;
    }
    d.testRunMinutes(1, 62, 10.0f);
    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_DOZE
        || d.testNowSec() - d.testGetStartSec() != 240 || a.testGetNudgeCount() != 0) {
        logger.debug("expected a doze at 240 s, state " + d.getState() + " t "
            + (d.testNowSec() - d.testGetStartSec()) + " nudges " + a.testGetNudgeCount());
        ok = false;
    }
    a.stop();
    return ok;
}

//! Walking in at 80 BPM then reading calmly at 68 for 15 minutes: the
//! rolling reference follows to 68, so sitting still afterwards needs the
//! full 5 still minutes. (A fixed baseline of 80 would read a 12 BPM "drop"
//! and buzz the reader after 2 still minutes.)
(:test)
function testStay_rollingReferenceIgnoresCalmReader(logger as Test.Logger) as Boolean {
    var d = stayHelperStart(null);
    d.testRunMinutes(2, 80, 200.0f);
    for (var i = 0; i < 15; i++) {
        stayHelperReadingMinute(d, 68);
    }
    var ok = true;
    var ref = d.testGetHrReference();
    if ((ref - 68.0f).abs() > 0.01f || (d.getHRBaseline() - 80.0f).abs() > 0.01f) {
        logger.debug("reference " + ref + " (expected 68), baseline " + d.getHRBaseline());
        ok = false;
    }
    d.testRunMinutes(4, 68, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("a calm reader must not doze after 4 still minutes, state " + d.getState());
        ok = false;
    }
    d.testRunMinutes(1, 68, 10.0f);
    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_DOZE) {
        logger.debug("5 still minutes must doze, state " + d.getState());
        ok = false;
    }
    return ok;
}

//! After a long calm period the HR path still works against the rolling
//! reference: HR falling from 68 to 60 while still dozes after 2 minutes.
(:test)
function testStay_hrDropAgainstRollingReference(logger as Test.Logger) as Boolean {
    var d = stayHelperStart(null);
    d.testRunMinutes(2, 80, 200.0f);
    for (var i = 0; i < 15; i++) {
        stayHelperReadingMinute(d, 68);
    }
    d.testRunMinutes(1, 60, 10.0f);          // window 68, 68, 60 -> 65.3: drop 2.7
    var ok = d.getState() == SleepDetector.STATE_MONITORING;
    d.testRunMinutes(1, 60, 10.0f);          // window 68, 60, 60 -> 62.7: drop 5.3
    ok = ok && d.getState() == SleepDetector.STATE_ALARM && d.getAlarmReason() == SleepDetector.ALARM_DOZE;
    if (!ok) {
        logger.debug("expected a doze at the second still minute, state " + d.getState()
            + " reference " + d.testGetHrReference());
    }
    return ok;
}

//! Dismissing the doze alarm goes back on guard: clean minute, stillness from
//! zero, the next doze again after 5 still minutes (with its own nudge), and
//! the session keeps counting.
(:test)
function testStay_dismissGoesBackOnGuard(logger as Test.Logger) as Boolean {
    var a = stayHelperAlarm();
    var d = stayHelperStart(a);
    d.testRunMinutes(5, 70, 10.0f);
    a.stop();
    d.dismissAlarm();
    var ok = true;
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getAlarmReason() != SleepDetector.ALARM_NONE
        || d.getStillMinutes() != 0 || d.getNapEndTime() != null || !d.testIsRunning()
        || d.getDozeCount() != 1 || d.testGetSecInMinute() != 0 || d.isDozeWarning()) {
        logger.debug("after dismiss: state " + d.getState() + " still " + d.getStillMinutes()
            + " dozes " + d.getDozeCount());
        ok = false;
    }
    var resumedAt = d.testNowSec();
    d.testRunMinutes(5, 70, 10.0f);
    if (d.getState() != SleepDetector.STATE_ALARM || d.getDozeCount() != 2
        || d.testNowSec() - resumedAt != 300 || a.testGetNudgeCount() != 2) {
        logger.debug("second doze: state " + d.getState() + " dozes " + d.getDozeCount()
            + " after " + (d.testNowSec() - resumedAt) + " s, nudges " + a.testGetNudgeCount());
        ok = false;
    }
    a.stop();
    d.dismissAlarm();
    d.testRunMinutes(2, 70, 200.0f);
    d.cancel();
    if (d.getState() != SleepDetector.STATE_SUMMARY || d.getSessionSec() != 12 * 60 || d.testIsRunning()) {
        logger.debug("summary: state " + d.getState() + " session " + d.getSessionSec());
        ok = false;
    }
    return ok;
}

//! Moving before the doze resets everything: no alarm, the warning clears,
//! and the nudge came only once.
(:test)
function testStay_movementBeforeDozeResets(logger as Test.Logger) as Boolean {
    var a = stayHelperAlarm();
    var d = stayHelperStart(a);
    d.testRunMinutes(4, 70, 10.0f);
    var warned = d.isDozeWarning();
    d.testRunMinutes(1, 70, 200.0f);
    var ok = warned && !d.isDozeWarning() && d.getStillMinutes() == 0
        && d.getState() == SleepDetector.STATE_MONITORING && a.testGetNudgeCount() == 1 && !a.isAlarming();
    if (!ok) {
        logger.debug("warned " + warned + " still " + d.getStillMinutes() + " state " + d.getState()
            + " nudges " + a.testGetNudgeCount());
    }
    a.stop();
    return ok;
}

//! Without any HR the stillness-only rule still catches a doze at 5 minutes.
(:test)
function testStay_noHrUsesStillnessOnly(logger as Test.Logger) as Boolean {
    var d = stayHelperStart(null);
    d.testRunMinutes(5, 0, 10.0f);
    var ok = d.getState() == SleepDetector.STATE_ALARM && d.getAlarmReason() == SleepDetector.ALARM_DOZE
        && d.testGetHrReference() == 0.0f;
    if (!ok) {
        logger.debug("state " + d.getState() + " reference " + d.testGetHrReference());
    }
    return ok;
}

//! Stopping while the doze alarm rings ends the session now (not at the
//! doze), and a plain stop reports the session length without dozes.
(:test)
function testStay_summaryTimes(logger as Test.Logger) as Boolean {
    var d = stayHelperStart(null);
    d.testRunMinutes(5, 70, 10.0f);
    d.testAdvanceClock(30);
    d.cancel();
    var ok = true;
    if (d.getState() != SleepDetector.STATE_SUMMARY || d.getSessionSec() != 330) {
        logger.debug("stop during the alarm: session " + d.getSessionSec() + ", expected 330");
        ok = false;
    }
    d = stayHelperStart(null);
    d.testRunMinutes(10, 75, 200.0f);
    d.cancel();
    if (d.getSessionSec() != 600 || d.getDozeCount() != 0 || !d.isStayAwake() || d.hasSleptAtLeastOnce()) {
        logger.debug("plain stop: session " + d.getSessionSec() + " dozes " + d.getDozeCount());
        ok = false;
    }
    var end = d.getNapEndTime();
    if (end == null || (end as Time.Moment).value() != d.testGetStartSec() + 600) {
        logger.debug("session end time missing");
        ok = false;
    }
    return ok;
}

//! A new nap after a Stay Awake session is a normal nap again.
(:test)
function testStay_nextNapIsNormal(logger as Test.Logger) as Boolean {
    var d = stayHelperStart(null);
    d.testRunMinutes(1, 70, 200.0f);
    d.cancel();
    d.testStart();
    var ok = !d.isStayAwake() && d.getNapDurationMin() == 30 && d.testGetDeadlineSec() > 0
        && d.getDozeCount() == 0;
    if (!ok) {
        logger.debug("stay awake leaked into the next nap");
    }
    return ok;
}

//! Answering the nudge ("Move a bit") with a few seconds of movement ends the
//! still run at once: the warning clears immediately and no doze alarm rings
//! two minutes later. (Before, 3-4 s of movement still counted as a still
//! minute and the doze alarm rang for a user who did what the watch asked.)
(:test)
function testStay_movingAfterNudgeEndsStillRun(logger as Test.Logger) as Boolean {
    var a = stayHelperAlarm();
    var d = stayHelperStart(a);
    d.testRunMinutes(3, 70, 10.0f);
    var warned = d.isDozeWarning() && a.testGetNudgeCount() == 1;
    d.testRunSeconds(4, 70, 150.0f);
    var cleared = !d.isDozeWarning() && d.getStillMinutes() == 0;
    d.testRunSeconds(56, 70, 10.0f);
    d.testRunMinutes(1, 70, 10.0f);
    var ok = warned && cleared && d.getState() == SleepDetector.STATE_MONITORING
        && d.getDozeCount() == 0 && !a.isAlarming();
    if (!ok) {
        logger.debug("warned " + warned + " cleared " + cleared + " state " + d.getState()
            + " dozes " + d.getDozeCount());
    }
    a.stop();
    return ok;
}

//! The nudge's own buzz (at most 2 active seconds) does not count as moving.
(:test)
function testStay_twoActiveSecondsDoNotEndTheWarning(logger as Test.Logger) as Boolean {
    var d = stayHelperStart(null);
    d.testRunMinutes(3, 70, 10.0f);
    d.testRunSeconds(2, 70, 150.0f);
    var ok = d.isDozeWarning() && d.getStillMinutes() == 3;
    if (!ok) {
        logger.debug("2 active seconds ended the warning, still " + d.getStillMinutes());
    }
    return ok;
}

// -- The doze alarm and its warning, as in 1.1.0 --------------------------------

//! What the doze alarm rang in 1.1.0, segment by segment: [intensity %,
//! pulse ms, pulses, gap ms, wait after each ring ms, rings, display phase].
//! The last segment is the persistent phase, of which 4 rings are checked.
(:debug)
function stayHelperDozeRings110() as Array<Array<Number> > {
    return [
        [ 63, 240, 3, 260,  6000,  2, 1],
        [ 78, 280, 3, 200,  6000,  2, 2],
        [ 92, 320, 3, 160,  5000,  2, 2],
        [100, 350, 3, 150,  5000, 36, 3],
        [100, 350, 3, 150, 30000,  4, 3]
    ] as Array<Array<Number> >;
}

//! A vibration as "63 % x 240 ms x 3, 260 ms apart", for the messages.
(:debug)
function stayHelperRingText(pct as Number, pulseMs as Number, pulses as Number, gapMs as Number) as String {
    return pct + " % x " + pulseMs + " ms x " + pulses + ", " + gapMs + " ms apart";
}

//! The vibration delivered last against [pct, pulse ms, pulses, gap ms]:
//! null when it is exactly that (`pulses` pulses at pct, 0 % between them),
//! else what was felt.
(:debug)
function stayHelperPatternDiff(a as AlarmManager, want as Array<Number>) as String? {
    var got = a.testGetLastPattern();
    if (got == null) {
        return "nothing vibrated";
    }
    var p = got as Array<Attention.VibeProfile>;
    if (p.size() == 0) {
        return "an empty pattern";
    }
    var same = p.size() == 2 * want[2] - 1;
    for (var i = 0; i < p.size() && same; i++) {
        var pulse = (i % 2 == 0);
        same = p[i].dutyCycle == (pulse ? want[0] : 0) && p[i].length == (pulse ? want[1] : want[3]);
    }
    if (same) {
        return null;
    }
    return stayHelperRingText(p[0].dutyCycle, p[0].length, (p.size() + 1) / 2, (p.size() > 1) ? p[1].length : 0);
}

//! The doze alarm and its warning (the nudge) ring exactly as Stay Awake did
//! in 1.1.0, ring by ring: every ring's vibration (intensity, pulse length,
//! pulse count, gap), the wait after it - so the second each ring comes at -,
//! the display phase and full strength it shows, and which rings turn the
//! display on; then the nudge's one ring, display on. Written on 2026-10-06
//! against the code of that day, before Stay Awake got its own copy of
//! these values and the nap ramp its gentler start, and not edited since: a
//! change to the nap ramp leaves it passing, a change to Stay Awake's copy
//! fails it, naming the ring.
(:test)
function testStay_dozeAlarmAndNudgeAsIn110(logger as Test.Logger) as Boolean {
    var a = stayHelperAlarm();
    a.testForceBacklightThrow(false);
    var ok = true;
    a.startDozeAlarm();
    var segments = stayHelperDozeRings110();
    var ring = 0;
    var sec = 0;
    var lit = 0;
    for (var s = 0; s < segments.size(); s++) {
        var want = segments[s];
        for (var r = 0; r < want[5]; r++) {
            if (ring > 0) {
                a.testFireRing();
            }
            var what = "doze ring " + ring + " at " + sec + " s";
            var diff = stayHelperPatternDiff(a, want);
            if (diff != null) {
                logger.debug(what + ": " + diff + "; 1.1.0: " + stayHelperRingText(want[0], want[1], want[2], want[3]));
                ok = false;
            }
            if (a.testGetWaitAfterLastRing() != want[4]) {
                logger.debug(what + ": the next ring " + a.testGetWaitAfterLastRing() + " ms later; 1.1.0: "
                    + want[4] + " ms");
                ok = false;
            }
            if (a.getLastRingPhase() != want[6] || a.isFullIntensity() != (want[0] >= 100)) {
                logger.debug(what + ": phase " + a.getLastRingPhase() + ", full " + a.isFullIntensity()
                    + "; 1.1.0: phase " + want[6]);
                ok = false;
            }
            // 1.1.0 lit the display on the first two rings at or above
            // 50 % - every doze ring is - and then on every 6th.
            if (ring < 2 || ring % 6 == 0) {
                lit += 1;
            }
            if (a.testGetBacklightCount() != lit) {
                logger.debug(what + ": " + a.testGetBacklightCount() + " backlight requests so far; 1.1.0: " + lit);
                ok = false;
            }
            sec += want[4] / 1000;
            ring += 1;
        }
    }
    a.stop();

    // The warning before it: one ring at 35 %, display on, no alarm.
    var nudge = [35, 160, 2, 350] as Array<Number>;
    var w = stayHelperAlarm();
    w.testForceBacklightThrow(false);
    w.setStayAwake(true);
    w.nudge();
    var diff = stayHelperPatternDiff(w, nudge);
    if (diff != null) {
        logger.debug("nudge: " + diff + "; 1.1.0: " + stayHelperRingText(nudge[0], nudge[1], nudge[2], nudge[3]));
        ok = false;
    }
    if (w.testGetVibrateCount() != 1 || w.testGetBacklightCount() != 1 || w.isAlarming()) {
        logger.debug("nudge: " + w.testGetVibrateCount() + " vibrations, " + w.testGetBacklightCount()
            + " backlight requests, alarming " + w.isAlarming() + "; 1.1.0: 1, 1, no");
        ok = false;
    }
    w.setStayAwake(false);
    return ok;
}
