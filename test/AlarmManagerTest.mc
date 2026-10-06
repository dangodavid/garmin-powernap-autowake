import Toybox.Attention;
import Toybox.Test;
import Toybox.Lang;

// -----------------------------------------------------------------------------
// AlarmManager Unit Tests
//
// Covers the ramp table (ring -> step -> wait mapping, the constraints the
// owner set on it: >= 8 perceptible steps, the calibrated first pulse,
// monotonic growth, every step 8-30 % above the one before it, no step
// bigger than 1.1.0's, the maximum and everything from 22 % up as in 1.1.0,
// full strength by 178 s, 3 min at full, then the 30 s persistent phase),
// the backlight threshold derived from it, the display phases, the
// Stay Awake doze alarm and nudge on their own table (ring by ring in
// StayAwakeTest), the vibrate counter, the start/stop lifecycle, the
// "Test alarm" preview (and the moment of the real alarm its screen shows
// for each step), and the AMOLED backlight regression: a throwing
// Attention.backlight() must never suppress the vibration of the ring it
// belongs to, nor stop the alarm.
//
// Ring times follow from the table: the wait after ring k is the interval of
// ring k's step, so with one ring per step up to 19 % and 2 rings per step
// from 22 % the first full ring (ring 22) is at 178 s, the last 5 s ring (57)
// at 353 s, the first persistent ring (58) at 358 s.
//
// Every test that calls startAlarm() calls stop() before returning, because
// startAlarm() arms a real repeat timer.
// -----------------------------------------------------------------------------

//! Time of every ring from 0 to `upTo` (inclusive), in seconds.
(:debug)
function alarmHelperRingTimes(alarm as AlarmManager, upTo as Number) as Array<Number> {
    var times = [0] as Array<Number>;
    var t = 0;
    for (var k = 1; k <= upTo; k++) {
        t += alarm.testGetIntervalForStep(alarm.testGetStepForRing(k - 1)) / 1000;
        times.add(t);
    }
    return times;
}

//! Index of the first ring at full strength (100 %).
(:debug)
function alarmHelperFirstFullRing(alarm as AlarmManager) as Number {
    return alarm.testGetFirstRingOfStep(alarm.testFirstStepAtLeast(100));
}

//! The ramp of 1.1.0, the one the store carries, row for row: the reference
//! the owner's limits of 2026-10-06 are measured against (its largest step,
//! its time to full strength) and the table RAMP must still be from 22 % up.
(:debug)
function alarmHelperRamp110() as Array<Array<Number> > {
    return [
        [ 22, 120, 2, 400, 10000,  2],
        [ 28, 140, 2, 380,  9000,  2],
        [ 35, 160, 2, 350,  8000,  2],
        [ 43, 180, 3, 320,  8000,  2],
        [ 52, 210, 3, 300,  7000,  2],
        [ 63, 240, 3, 260,  6000,  2],
        [ 78, 280, 3, 200,  6000,  2],
        [ 92, 320, 3, 160,  5000,  2],
        [100, 350, 3, 150,  5000, 36],
        [100, 350, 3, 150, 30000,  0]
    ] as Array<Array<Number> >;
}

//! Seconds from a table's first ring to its first ring at 100 %.
(:debug)
function alarmHelperFullAtSec(rows as Array<Array<Number> >) as Number {
    var t = 0;
    for (var s = 0; s < rows.size() && rows[s][0] < 100; s++) {
        t += rows[s][5] * rows[s][4] / 1000;
    }
    return t;
}

//! A row as "22 % x 120 ms x 2, 400 ms apart, 10 s wait, 2 rings".
(:debug)
function alarmHelperRowText(row as Array<Number>) as String {
    return row[0] + " % x " + row[1] + " ms x " + row[2] + ", " + row[3] + " ms apart, "
        + (row[4] / 1000) + " s wait, " + row[5] + " rings";
}

//! When each step of the ramp starts in the real alarm, in seconds from its
//! first ring, one entry per step the preview plays: an alarm is started
//! and rung ring by ring, each ring followed by the wait the alarm itself
//! schedules after it, up to the persistent phase.
(:debug)
function alarmHelperStepStartSecs() as Array<Number> {
    var alarm = new AlarmManager();
    var persistent = alarm.testGetRampSize() - 1;
    var starts = [] as Array<Number>;
    var t = 0;
    alarm.startAlarm();
    while (alarm.testGetLastRingStep() < persistent) {
        if (alarm.testGetLastRingStep() == starts.size()) {
            starts.add(t);
        }
        t += alarm.testGetWaitAfterLastRing() / 1000;
        alarm.testFireRing();
    }
    alarm.stop();
    return starts;
}

//! A delivered vibration as "7 % x 120 ms, 0 % x 400 ms, ...", or "nothing".
(:debug)
function alarmHelperPatternText(pattern as Array<Attention.VibeProfile>?) as String {
    if (pattern == null) {
        return "nothing";
    }
    var p = pattern as Array<Attention.VibeProfile>;
    var out = "";
    for (var i = 0; i < p.size(); i++) {
        out += ((i > 0) ? ", " : "") + p[i].dutyCycle + " % x " + p[i].length + " ms";
    }
    return out;
}

//! A fresh AlarmManager is idle: not alarming, ring 0, phase 0, all counters 0.
(:test)
function testAlarm_initialIdleState(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var ok = !alarm.isAlarming()
        && alarm.testGetRingCount() == 0
        && alarm.getCurrentPhase() == 0
        && alarm.getLastRingPhase() == 0
        && !alarm.isFullIntensity()
        && alarm.testGetVibrateCount() == 0
        && alarm.testGetBacklightCount() == 0
        && alarm.testGetBlockedDeliveries() == 0;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " phase=" + alarm.getCurrentPhase()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount());
    }
    return ok;
}

//! startAlarm() fires ring 0 synchronously: ring count 1, one vibration of
//! the first (finest) step, phase 0, isAlarming true, and no backlight: the
//! gentle steps leave the screen dark.
(:test)
function testAlarm_startFiresRingZeroImmediately(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm();
    var ok = alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetRingsFired() == 1
        && alarm.testGetLastRingStep() == 0
        && alarm.testGetVibrateCount() == 1
        && alarm.testGetBacklightCount() == 0
        && alarm.getCurrentPhase() == 0
        && alarm.getLastRingPhase() == 0;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount()
            + " phase=" + alarm.getCurrentPhase());
    }
    alarm.stop();
    return ok;
}

//! Ring -> step mapping: one ring per step up to 19 % (rings 0-5), then 2
//! rings per step up to full strength (ring 22), 36 full rings (22-57),
//! then the persistent row (58+).
(:test)
function testAlarm_stepForRingBoundaries(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var last = alarm.testGetRampSize() - 1;
    var rings    = [0, 1, 5, 6, 7, 8, 20, 21, 22, 57, 58, 100];
    var expected = [0, 1, 5, 6, 6, 7, 13, 13, 14, 14, last, last];
    var ok = true;
    for (var i = 0; i < rings.size(); i++) {
        var got = alarm.testGetStepForRing(rings[i] as Number);
        if (got != expected[i]) {
            logger.debug("ring " + rings[i] + " expected step " + expected[i] + " got " + got);
            ok = false;
        }
    }
    if (alarm.testGetFirstRingOfStep(14) != 22 || alarm.testGetFirstRingOfStep(last) != 58
        || alarm.testGetFirstRingOfStep(6) != 6 || alarm.testGetFirstRingOfStep(0) != 0) {
        logger.debug("first rings: step 14 " + alarm.testGetFirstRingOfStep(14) + " persistent "
            + alarm.testGetFirstRingOfStep(last));
        ok = false;
    }
    return ok;
}

//! Wait after a ring per step: 10 s on the steps up to 22 %, then
//! 9/8/8/7/6/6/5/5 s, then 30 s persistent.
(:test)
function testAlarm_intervalPerStep(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var expected = [10000, 10000, 10000, 10000, 10000, 10000, 10000, 9000, 8000, 8000, 7000, 6000, 6000, 5000,
        5000, 30000];
    var ok = alarm.testGetRampSize() == expected.size();
    for (var s = 0; s < expected.size() && ok; s++) {
        var got = alarm.testGetIntervalForStep(s);
        if (got != expected[s]) {
            logger.debug("step " + s + " expected " + expected[s] + " ms got " + got);
            ok = false;
        }
    }
    return ok;
}

//! The owner's constraints on the ramp: at least 8 steps below full
//! strength; the first step at most 25 % with pulses of at least 120 ms
//! (testAlarm_rampStartsAtTheCalibratedPulse pins it); intensity, pulse
//! length and pulse count never decrease from step to step and the wait
//! never grows; every pattern stays within 8 vibe profiles; the last row is
//! the persistent phase (100 %, 30 s, unbounded) and the row before it holds
//! full strength for 3 minutes.
(:test)
function testAlarm_rampIsGentleAndMonotonic(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var n = alarm.testGetRampSize();
    var ok = true;
    var full = alarm.testFirstStepAtLeast(100);
    if (full < 8) {
        logger.debug("only " + full + " steps below full strength, need 8");
        ok = false;
    }
    var first = alarm.testGetRampRow(0);
    if (first[0] > 25 || first[1] < 120) {
        logger.debug("first step " + first[0] + " % / " + first[1] + " ms: must be <= 25 % and >= 120 ms");
        ok = false;
    }
    for (var s = 1; s < n; s++) {
        var prev = alarm.testGetRampRow(s - 1);
        var row = alarm.testGetRampRow(s);
        if (row[0] < prev[0] || row[1] < prev[1] || row[2] < prev[2]) {
            logger.debug("step " + s + " weaker than step " + (s - 1));
            ok = false;
        }
        if (s < n - 1 && row[4] > prev[4]) {
            logger.debug("step " + s + " waits longer than step " + (s - 1));
            ok = false;
        }
        if (s < full && row[0] == prev[0] && row[1] == prev[1] && row[2] == prev[2]) {
            logger.debug("step " + s + " is not a perceptible increase over step " + (s - 1));
            ok = false;
        }
    }
    for (var s = 0; s < n; s++) {
        var row = alarm.testGetRampRow(s);
        if (row[2] < 1 || row[2] > 4 || alarm.testGetVibePattern(s).size() > 8 || row[0] > 100 || row[0] < 1) {
            logger.debug("step " + s + ": " + row[2] + " pulses, " + row[0] + " %");
            ok = false;
        }
    }
    var fullRow = alarm.testGetRampRow(n - 2);
    var persistent = alarm.testGetRampRow(n - 1);
    if (fullRow[0] != 100 || fullRow[5] * fullRow[4] != 180000) {
        logger.debug("the full-strength row must hold 100 % for 3 minutes, got " + fullRow[0] + " % for "
            + (fullRow[5] * fullRow[4] / 1000) + " s");
        ok = false;
    }
    if (persistent[0] != 100 || persistent[4] != 30000 || persistent[5] != 0) {
        logger.debug("the persistent row must be 100 % every 30 s until stopped");
        ok = false;
    }
    return ok;
}

//! The ramp starts with the pulse the owner measured on the wrist on
//! 2026-10-06: the first one felt lying down on the fenix 8 Pro was one
//! pulse of 120 ms at 7 % (10 % standing), the pulse the calibration ladder
//! played. The first step is that pulse, and the first ring is exactly it:
//! one profile, 7 %, 120 ms, nothing before or after it.
(:test)
function testAlarm_rampStartsAtTheCalibratedPulse(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var ok = true;
    var row = alarm.testGetRampRow(0);
    if (row[0] != 7 || row[1] != 120 || row[2] != 1) {
        logger.debug("the first step is " + row[0] + " % x " + row[1] + " ms x " + row[2]
            + "; the calibrated pulse is 7 % x 120 ms x 1");
        ok = false;
    }
    alarm.startAlarm();
    var felt = alarm.testGetLastPattern();
    if (felt == null || (felt as Array<Attention.VibeProfile>).size() != 1
        || (felt as Array<Attention.VibeProfile>)[0].dutyCycle != 7
        || (felt as Array<Attention.VibeProfile>)[0].length != 120) {
        logger.debug("the first ring is " + alarmHelperPatternText(felt) + "; the calibrated pulse is 7 % x 120 ms");
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! Every step rises in proportion to the one before it, as the 1.1.0 ramp
//! does from 22 % up (owner, 2026-10-06): by at most 30 % and by at least
//! 8 %, from the first step to full strength. 7 -> 10 % was a jump of 43 %;
//! 92 -> 100 % is the smallest rise there is (9 %). The persistent phase
//! repeats full strength: it is not a step up.
(:test)
function testAlarm_everyStepRisesInProportion(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var full = alarm.testFirstStepAtLeast(100);
    var ok = full > 0;
    for (var s = 1; s <= full; s++) {
        var from = alarm.testGetRampRow(s - 1)[0];
        var to = alarm.testGetRampRow(s)[0];
        if (to * 100 > from * 130 || to * 100 < from * 108) {
            logger.debug("step " + s + " rises " + (((to - from) * 1000 / from + 5) / 10) + " % (" + from + " -> "
                + to + " %): every step must be 8-30 % above the one before it");
            ok = false;
        }
    }
    return ok;
}

//! No step rises more than the largest step of the 1.1.0 ramp (63 -> 78 %,
//! 15 points; computed from alarmHelperRamp110, not written in): a gentler
//! start must not buy a jump anywhere else.
(:test)
function testAlarm_noStepBiggerThanIn110(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var old = alarmHelperRamp110();
    var limit = 0;
    for (var s = 1; s < old.size(); s++) {
        var rise = old[s][0] - old[s - 1][0];
        if (rise > limit) {
            limit = rise;
        }
    }
    var ok = limit == 15;
    if (!ok) {
        logger.debug("the 1.1.0 ramp's largest step is " + limit + " points, expected 15");
    }
    for (var s = 1; s < alarm.testGetRampSize(); s++) {
        var from = alarm.testGetRampRow(s - 1)[0];
        var to = alarm.testGetRampRow(s)[0];
        if (to - from > limit) {
            logger.debug("step " + s + " rises " + (to - from) + " points (" + from + " -> " + to
                + " %), more than the 1.1.0 ramp's largest step, " + limit + " points");
            ok = false;
        }
    }
    return ok;
}

//! The maximum is unchanged, and so is everything from 22 % up (owner,
//! 2026-10-06): the strongest ring is still 100 %, the 1.1.0 ramp follows
//! its first step (22 %) row for row - the same three minutes at full
//! strength 5 s apart, the same persistent phase every 30 s - and the new
//! steps only come before it.
(:test)
function testAlarm_maximumAndUpperRampUnchanged(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var old = alarmHelperRamp110();
    var n = alarm.testGetRampSize();
    var ok = true;
    var max = 0;
    for (var s = 0; s < n; s++) {
        var pct = alarm.testGetRampRow(s)[0];
        if (pct > max) {
            max = pct;
        }
    }
    if (max != 100) {
        logger.debug("the strongest step is " + max + " %; the maximum was 100 %");
        ok = false;
    }
    var first = n - old.size();                  // where 1.1.0's first step (22 %) sits now
    if (first < 0) {
        logger.debug("RAMP has " + n + " rows, fewer than the " + old.size() + " of 1.1.0");
        return false;
    }
    for (var i = 0; i < old.size(); i++) {
        var row = alarm.testGetRampRow(first + i);
        var same = true;
        for (var c = 0; c < 6; c++) {
            same = same && row[c] == old[i][c];
        }
        if (!same) {
            logger.debug("step " + (first + i) + " is " + alarmHelperRowText(row) + "; 1.1.0's step " + i
                + " was " + alarmHelperRowText(old[i]));
            ok = false;
        }
    }
    return ok;
}

//! Full strength comes at most 60 s later than in 1.1.0 (owner,
//! 2026-10-06): 1.1.0 reached it 118 s after the first ring, so the limit is
//! 178 s; the lower bound the owner set for 1.1.0 stays (not before 100 s).
//! The table reaches it with ring 22 at 178 s, the limit itself, and every
//! step on the way is rung (none is skipped).
(:test)
function testAlarm_fullReachedInTime(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var before = alarmHelperFullAtSec(alarmHelperRamp110());
    var limit = before + 60;
    var fullRing = alarmHelperFirstFullRing(alarm);
    var times = alarmHelperRingTimes(alarm, fullRing);
    var t = times[fullRing];
    var ok = before == 118;
    if (!ok) {
        logger.debug("the 1.1.0 ramp reached full strength at " + before + " s, expected 118 s");
    }
    if (t > limit) {
        logger.debug("full strength at " + t + " s, later than the limit of " + limit + " s (1.1.0's " + before
            + " s + 60 s)");
        ok = false;
    }
    if (t < 100) {
        logger.debug("full strength at " + t + " s, sooner than 100 s");
        ok = false;
    }
    if (fullRing != 22 || t != 178) {
        logger.debug("table changed: first full ring " + fullRing + " at " + t + " s (was 22 at 178 s)");
        ok = false;
    }
    // Every step below full is reached: each ring's step is at most one
    // above the previous ring's, so no step is skipped.
    for (var k = 1; k <= fullRing; k++) {
        if (alarm.testGetStepForRing(k) - alarm.testGetStepForRing(k - 1) > 1) {
            logger.debug("ring " + k + " skips a step");
            ok = false;
        }
    }
    return ok;
}

//! Display phases follow the intensity: 0 below 40 %, 1 below 65 %, 2 below
//! 100 %, 3 at full. getCurrentPhase() is the next ring's phase and
//! getLastRingPhase() the phase of the ring just felt.
(:test)
function testAlarm_displayPhasesFollowRamp(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var ok = alarm.testDisplayPhase(39) == 0 && alarm.testDisplayPhase(40) == 1 && alarm.testDisplayPhase(64) == 1
        && alarm.testDisplayPhase(65) == 2 && alarm.testDisplayPhase(99) == 2 && alarm.testDisplayPhase(100) == 3;
    if (!ok) {
        logger.debug("displayPhase thresholds wrong");
    }
    var expected = [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 2, 2, 3, 3];
    for (var s = 0; s < alarm.testGetRampSize(); s++) {
        var got = alarm.testDisplayPhase(alarm.testGetRampRow(s)[0]);
        if (got != expected[s]) {
            logger.debug("step " + s + " (" + alarm.testGetRampRow(s)[0] + " %) phase " + got + ", expected " + expected[s]);
            ok = false;
        }
    }
    alarm.startAlarm();                                  // ring 0
    // (rings fired, expected last phase, expected next phase)
    var totals   = [1, 12, 13, 18, 19, 22, 23, 66];
    var lastPh   = [0, 0, 1,  1,  2,  2,  3,  3];
    var nextPh   = [0, 1, 1,  2,  2,  3,  3,  3];
    for (var i = 0; i < totals.size(); i++) {
        while (alarm.testGetRingCount() < (totals[i] as Number)) {
            alarm.testFireRing();
        }
        if (alarm.getLastRingPhase() != lastPh[i] || alarm.getCurrentPhase() != nextPh[i]) {
            logger.debug("after " + totals[i] + " rings: last " + alarm.getLastRingPhase() + "/" + lastPh[i]
                + " next " + alarm.getCurrentPhase() + "/" + nextPh[i]);
            ok = false;
        }
    }
    alarm.stop();
    return ok;
}

//! The Stay Awake doze alarm climbs its own table, not RAMP: its first ring
//! fires at once at 63 % with the display on (above the 50 % backlight
//! threshold), full strength comes with its seventh ring, the backlight
//! schedule counts from its start (rings 1, 2 and 7 by then), and the next
//! nap alarm climbs RAMP from its first step again. Ring by ring it is
//! testStay_dozeAlarmAndNudgeAsIn110.
(:test)
function testAlarm_dozeAlarmClimbsItsOwnTable(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testForceBacklightThrow(false);
    var ok = true;
    alarm.startDozeAlarm();
    var first = alarm.testGetLastPattern();
    if (!alarm.isAlarming() || alarm.testGetLastRingStep() != 0 || alarm.testGetRingsFired() != 1
        || alarm.testGetVibrateCount() != 1 || alarm.testGetBacklightCount() != 1
        || alarm.getLastRingPhase() != 1 || alarm.isFullIntensity()
        || first == null || (first as Array<Attention.VibeProfile>)[0].dutyCycle != 63) {
        logger.debug("start: step " + alarm.testGetLastRingStep() + " vib " + alarm.testGetVibrateCount()
            + " bl " + alarm.testGetBacklightCount() + " phase " + alarm.getLastRingPhase());
        ok = false;
    }
    while (!alarm.isFullIntensity() && alarm.testGetRingsFired() < 50) {
        alarm.testFireRing();
    }
    if (alarm.testGetRingsFired() != 7 || alarm.testGetBacklightCount() != 3) {
        logger.debug("full strength after " + alarm.testGetRingsFired() + " rings (expected 7), backlight "
            + alarm.testGetBacklightCount() + " (expected 3)");
        ok = false;
    }
    alarm.stop();
    alarm.startAlarm();
    var nap = alarm.testGetLastPattern();
    if (alarm.testGetLastRingStep() != 0 || nap == null
        || (nap as Array<Attention.VibeProfile>)[0].dutyCycle != alarm.testGetRampRow(0)[0]) {
        logger.debug("a nap alarm after a doze alarm must start at the first step of RAMP");
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! After three minutes at full strength (rings 22-57, 5 s apart) the alarm
//! keeps ringing every 30 s: ring 58 is the first persistent ring. The
//! screen still shows the last phase (4/4), every ring still vibrates, and
//! the timeline is 178 s / 353 s / 358 s / 388 s for rings 22 / 57 / 58 / 59.
(:test)
function testAlarm_persistentPhaseAfterThreeMinutesAtFull(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var times = alarmHelperRingTimes(alarm, 59);
    var ok = true;
    if (times[22] != 178 || times[57] != 353 || times[58] != 358 || times[59] != 388) {
        logger.debug("ring times 22/57/58/59: " + times[22] + "/" + times[57] + "/" + times[58] + "/" + times[59]);
        ok = false;
    }
    var last = alarm.testGetRampSize() - 1;
    if (alarm.testGetStepForRing(57) != last - 1 || alarm.testGetStepForRing(58) != last) {
        logger.debug("ring 57 must be the last full ring, ring 58 the first persistent one");
        ok = false;
    }
    alarm.startAlarm();
    while (alarm.testGetRingCount() < 60) {
        alarm.testFireRing();
    }
    if (!alarm.isAlarming() || alarm.testGetVibrateCount() != 60 || alarm.getCurrentPhase() != 3
        || alarm.getLastRingPhase() != 3 || !alarm.isFullIntensity()) {
        logger.debug("persistent phase: alarming " + alarm.isAlarming() + " vib " + alarm.testGetVibrateCount()
            + " phase " + alarm.getCurrentPhase());
        ok = false;
    }
    var pattern = alarm.testGetVibePattern(last);
    if (pattern[0].dutyCycle != 100) {
        logger.debug("persistent phase must keep full intensity");
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! KEY REGRESSION: with the backlight forced to throw (AMOLED burn-in guard),
//! 22 rings still produce 22 vibrations, the alarm stays active and the
//! backlight counter never moves.
(:test)
function testAlarm_backlightThrowNeverSuppressesVibration(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testForceBacklightThrow(true);
    alarm.startAlarm();
    for (var i = 0; i < 21; i++) {
        alarm.testFireRing();
    }
    var ok = alarm.isAlarming()
        && alarm.testGetRingCount() == 22
        && alarm.testGetVibrateCount() == 22
        && alarm.testGetBacklightCount() == 0
        && alarm.getCurrentPhase() == 3;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount()
            + " phase=" + alarm.getCurrentPhase());
    }
    alarm.stop();
    return ok;
}

//! Backlight is sparse and only from the 50 % step (step 10 = ring 14): over
//! 27 rings it is requested exactly on rings 14, 15, 20 and 26 (the first
//! two bright rings, then every 6th) while every ring vibrates (count 27).
(:test)
function testAlarm_backlightSparseSchedule(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testForceBacklightThrow(false);
    var ok = alarm.testBacklightFromStep() == 10 && alarm.testGetFirstRingOfStep(10) == 14
        && alarm.testGetRampRow(10)[0] >= 50 && alarm.testGetRampRow(9)[0] < 50;
    if (!ok) {
        logger.debug("backlight step " + alarm.testBacklightFromStep() + ", expected 10 (ring 14)");
    }
    alarm.startAlarm();
    for (var i = 0; i < 26; i++) {
        alarm.testFireRing();
    }
    if (alarm.testGetRingCount() != 27 || alarm.testGetVibrateCount() != 27 || alarm.testGetBacklightCount() != 4) {
        logger.debug("rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount());
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! The gentle steps (rings 0-13, below 50 %) never turn the screen on;
//! ring 14 (52 %) and ring 15 do, rings 16-19 do not, ring 20 does.
(:test)
function testAlarm_backlightSkipsGentlePhases(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testForceBacklightThrow(false);
    alarm.startAlarm();              // ring 0
    for (var i = 0; i < 13; i++) {   // rings 1..13
        alarm.testFireRing();
    }
    var afterRing13 = alarm.testGetBacklightCount();
    alarm.testFireRing();            // ring 14 -> bl 1
    var afterRing14 = alarm.testGetBacklightCount();
    alarm.testFireRing();            // ring 15 -> bl 2
    var afterRing15 = alarm.testGetBacklightCount();
    for (var i = 0; i < 4; i++) {    // rings 16..19
        alarm.testFireRing();
    }
    var afterRing19 = alarm.testGetBacklightCount();
    alarm.testFireRing();            // ring 20 -> bl 3
    var afterRing20 = alarm.testGetBacklightCount();
    var ok = afterRing13 == 0 && afterRing14 == 1 && afterRing15 == 2 && afterRing19 == 2
        && afterRing20 == 3 && alarm.testGetRingCount() == 21;
    if (!ok) {
        logger.debug("bl after ring13=" + afterRing13 + " ring14=" + afterRing14 + " ring15=" + afterRing15
            + " ring19=" + afterRing19 + " ring20=" + afterRing20);
    }
    alarm.stop();
    return ok;
}

//! A backlight failure is per request, not latched: rings 14 and 15 throw,
//! and once the throw stops the next scheduled rings (20, then 26) request
//! the backlight again.
(:test)
function testAlarm_backlightThrowDoesNotLatch(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testForceBacklightThrow(true);
    alarm.startAlarm();              // ring 0
    for (var i = 0; i < 15; i++) {   // rings 1..15 (14 and 15 throw)
        alarm.testFireRing();
    }
    var duringThrow = alarm.testGetBacklightCount();
    alarm.testForceBacklightThrow(false);
    for (var i = 0; i < 5; i++) {    // rings 16..20
        alarm.testFireRing();
    }
    var afterRing20 = alarm.testGetBacklightCount();
    for (var i = 0; i < 6; i++) {    // rings 21..26
        alarm.testFireRing();
    }
    var afterRing26 = alarm.testGetBacklightCount();
    var ok = duringThrow == 0 && afterRing20 == 1 && afterRing26 == 2
        && alarm.testGetRingCount() == 27
        && alarm.testGetVibrateCount() == 27;
    if (!ok) {
        logger.debug("bl duringThrow=" + duringThrow + " afterRing20=" + afterRing20
            + " afterRing26=" + afterRing26
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount());
    }
    alarm.stop();
    return ok;
}

//! stop() clears isAlarming and the ring count, and a later timer tick
//! (testFireRing) is ignored: ring, vibrate and backlight counts stay put.
(:test)
function testAlarm_stopResetsAndSilencesRings(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm();
    alarm.testFireRing();
    alarm.testFireRing();            // rings 0..2 fired: vib 3
    var vibBefore = alarm.testGetVibrateCount();
    var blBefore  = alarm.testGetBacklightCount();
    alarm.stop();
    var stoppedOk = !alarm.isAlarming() && alarm.testGetRingCount() == 0 && !alarm.isFullIntensity();
    alarm.testFireRing();            // must be a no-op
    var silentOk = !alarm.isAlarming()
        && alarm.testGetRingCount() == 0
        && alarm.testGetVibrateCount() == vibBefore
        && alarm.testGetBacklightCount() == blBefore;
    var ok = vibBefore == 3 && stoppedOk && silentOk;
    if (!ok) {
        logger.debug("vibBefore=" + vibBefore + " stoppedOk=" + stoppedOk
            + " silentOk=" + silentOk
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount());
    }
    alarm.stop();
    return ok;
}

//! startAlarm() while already alarming is a no-op: ring count, vibrate count
//! and phase are unchanged and no extra ring 0 is fired.
(:test)
function testAlarm_startWhileAlarmingIsNoOp(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm();
    for (var i = 0; i < 11; i++) {   // rings 1..11 -> total 12, next ring at step 9 (43 %): phase 1
        alarm.testFireRing();
    }
    var ringsBefore = alarm.testGetRingCount();
    var vibBefore   = alarm.testGetVibrateCount();
    var blBefore    = alarm.testGetBacklightCount();
    var phaseBefore = alarm.getCurrentPhase();
    alarm.startAlarm();
    alarm.startDozeAlarm();
    var ok = ringsBefore == 12
        && phaseBefore == 1
        && alarm.isAlarming()
        && alarm.testGetRingCount() == ringsBefore
        && alarm.testGetVibrateCount() == vibBefore
        && alarm.testGetBacklightCount() == blBefore
        && alarm.getCurrentPhase() == phaseBefore;
    if (!ok) {
        logger.debug("before rings=" + ringsBefore + " vib=" + vibBefore
            + " bl=" + blBefore + " phase=" + phaseBefore
            + " after rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount()
            + " phase=" + alarm.getCurrentPhase());
    }
    alarm.stop();
    return ok;
}

//! A fresh startAlarm() after stop() resets every counter and restarts at
//! ring 0 / step 0 (ring 1 fired, one vibration, screen still dark).
(:test)
function testAlarm_restartAfterStopResetsCounters(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm();
    for (var i = 0; i < 15; i++) {   // total 16 rings, vib 16, bl 2 (rings 14, 15), next ring 63 %: phase 1
        alarm.testFireRing();
    }
    var escalated = alarm.testGetRingCount() == 16
        && alarm.testGetVibrateCount() == 16
        && alarm.testGetBacklightCount() == 2
        && alarm.getCurrentPhase() == 1
        && alarm.testGetLastRingStep() == 10;
    alarm.stop();
    alarm.startAlarm();
    var ok = escalated
        && alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetVibrateCount() == 1
        && alarm.testGetBacklightCount() == 0
        && alarm.getCurrentPhase() == 0
        && alarm.testGetLastRingStep() == 0;
    if (!ok) {
        logger.debug("escalated=" + escalated
            + " after restart rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount()
            + " phase=" + alarm.getCurrentPhase());
    }
    alarm.stop();
    return ok;
}

//! A timer tick before startAlarm() (stale callback) is ignored: nothing
//! fires and the manager stays idle.
(:test)
function testAlarm_fireRingBeforeStartIsIgnored(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testFireRing();
    var ok = !alarm.isAlarming()
        && alarm.testGetRingCount() == 0
        && alarm.testGetVibrateCount() == 0
        && alarm.testGetBacklightCount() == 0
        && alarm.testGetBlockedDeliveries() == 0;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount());
    }
    alarm.stop();
    return ok;
}

//! stop() on an idle manager (and twice in a row) is harmless, and the
//! manager can still start normally afterwards.
(:test)
function testAlarm_stopWhenIdleIsSafe(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.stop();
    alarm.stop();
    var idleOk = !alarm.isAlarming() && alarm.testGetRingCount() == 0;
    alarm.startAlarm();
    var startedOk = alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetVibrateCount() == 1;
    var ok = idleOk && startedOk;
    if (!ok) {
        logger.debug("idleOk=" + idleOk + " startedOk=" + startedOk
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount());
    }
    alarm.stop();
    return ok;
}

//! Crossing every step boundary up to full strength (each restarts the
//! repeat timer with a new wait) keeps the alarm active with one vibration
//! per ring.
(:test)
function testAlarm_stepBoundariesKeepAlarming(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm();
    var ok = true;
    for (var i = 0; i < 22; i++) {
        alarm.testFireRing();
        if (!alarm.isAlarming()) {
            logger.debug("alarm stopped after ring " + alarm.testGetRingCount());
            ok = false;
        }
    }
    ok = ok
        && alarm.testGetRingCount() == 23
        && alarm.testGetVibrateCount() == 23
        && alarm.getCurrentPhase() == 3
        && alarm.isFullIntensity();
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " phase=" + alarm.getCurrentPhase());
    }
    alarm.stop();
    return ok;
}

//! A nudge is one vibration (of NUDGE_ROW, 35 %: its pattern is checked in
//! testStay_dozeAlarmAndNudgeAsIn110) with the display turned on; it is not
//! an alarm, it is ignored while the alarm rings, and it is refused (quiet
//! onset gate) unless the session is Stay Awake.
(:test)
function testAlarm_nudgeIsOneGentleBurst(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testForceBacklightThrow(false);
    var ok = true;
    alarm.nudge();                           // a nap session: refused
    if (alarm.testGetNudgeCount() != 0 || alarm.testGetVibrateCount() != 0
        || alarm.testGetBacklightCount() != 0 || alarm.testGetBlockedDeliveries() != 1) {
        logger.debug("nudge outside Stay Awake must be refused: nudges " + alarm.testGetNudgeCount()
            + " vib " + alarm.testGetVibrateCount() + " blocked " + alarm.testGetBlockedDeliveries());
        ok = false;
    }
    alarm.setStayAwake(true);
    alarm.nudge();
    if (alarm.isAlarming() || alarm.testGetNudgeCount() != 1 || alarm.testGetVibrateCount() != 1
        || alarm.testGetRingCount() != 0 || alarm.testGetBacklightCount() != 1) {
        logger.debug("nudge: alarming " + alarm.isAlarming() + " nudges " + alarm.testGetNudgeCount()
            + " vib " + alarm.testGetVibrateCount() + " rings " + alarm.testGetRingCount());
        ok = false;
    }
    alarm.startAlarm();
    alarm.nudge();
    if (alarm.testGetNudgeCount() != 1 || alarm.testGetVibrateCount() != 1) {
        logger.debug("nudge during the alarm must be ignored");
        ok = false;
    }
    alarm.stop();
    alarm.setStayAwake(false);
    alarm.nudge();
    if (alarm.testGetNudgeCount() != 1 || alarm.testGetVibrateCount() != 1) {
        logger.debug("nudge after the session ended must be refused");
        ok = false;
    }
    return ok;
}

//! The screen may flash only at full strength: false before and during the
//! steps below 100 % (rings 0-21), true once ring 22 has fired, false after
//! stop(). getLastRingPhase follows the ring that actually fired.
(:test)
function testAlarm_fullIntensityOnlyAtFullStep(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var ok = !alarm.isFullIntensity();
    var fullRing = alarmHelperFirstFullRing(alarm);
    alarm.startAlarm();                       // ring 0
    while (alarm.testGetRingCount() < fullRing) {   // rings 1..21
        if (alarm.isFullIntensity()) {
            logger.debug("full intensity before ring " + fullRing + " (ring count " + alarm.testGetRingCount() + ")");
            ok = false;
        }
        alarm.testFireRing();
    }
    if (alarm.isFullIntensity() || alarm.getLastRingPhase() != 2 || alarm.getCurrentPhase() != 3) {
        logger.debug("after ring " + (fullRing - 1) + ": full " + alarm.isFullIntensity() + " last "
            + alarm.getLastRingPhase() + " next " + alarm.getCurrentPhase());
        ok = false;
    }
    alarm.testFireRing();                     // ring 22: full strength
    if (!alarm.isFullIntensity() || alarm.getLastRingPhase() != 3) {
        logger.debug("ring " + fullRing + " must be full strength");
        ok = false;
    }
    alarm.stop();
    if (alarm.isFullIntensity() || alarm.getLastRingPhase() != 0) {
        logger.debug("stop() must clear full intensity");
        ok = false;
    }
    return ok;
}

// -- Preview ("Test alarm") ---------------------------------------------------

//! The preview plays every step of the ramp exactly once, in order, one
//! vibration per step, with the same backlight rule, and reports the step
//! and intensity just played for the screen.
(:test)
function testAlarm_previewPlaysEachStepOnce(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testForceBacklightThrow(false);
    var steps = alarm.getPreviewSteps();
    var ok = steps == alarm.testGetRampSize() - 1 && steps >= 9;
    alarm.startPreview();
    if (!alarm.isPreviewing() || alarm.getPreviewStep() != 1 || alarm.testGetVibrateCount() != 1
        || alarm.getPreviewPct() != alarm.testGetRampRow(0)[0] || alarm.isAlarming()
        || alarm.testGetBacklightCount() != 0) {
        logger.debug("start: previewing " + alarm.isPreviewing() + " step " + alarm.getPreviewStep()
            + " vib " + alarm.testGetVibrateCount() + " pct " + alarm.getPreviewPct());
        ok = false;
    }
    for (var s = 2; s <= steps; s++) {
        alarm.testPreviewTick();
        if (alarm.getPreviewStep() != s || alarm.testGetVibrateCount() != s
            || alarm.getPreviewPct() != alarm.testGetRampRow(s - 1)[0] || !alarm.isPreviewing()) {
            logger.debug("tick " + s + ": step " + alarm.getPreviewStep() + " vib " + alarm.testGetVibrateCount()
                + " pct " + alarm.getPreviewPct());
            ok = false;
        }
    }
    // Backlight from the 50 % step: bright rings are steps 10-14 (5 of them):
    // the first two, then every 6th -> 2 requests.
    if (alarm.testGetBacklightCount() != 2 || alarm.testGetBlockedDeliveries() != 0) {
        logger.debug("backlight " + alarm.testGetBacklightCount() + " blocked " + alarm.testGetBlockedDeliveries());
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! The preview plays the steps 3 s apart, but each step's screen shows when
//! that step starts in the real alarm, m:ss from its first ring: the second
//! an alarm rung ring by ring, with the waits it schedules itself, reaches
//! the step (alarmHelperStepStartSecs) - never the preview's own rhythm.
(:test)
function testAlarm_previewShowsWhenEachStepStartsInTheAlarm(logger as Test.Logger) as Boolean {
    var starts = alarmHelperStepStartSecs();
    var dc = layoutHelperDc();
    var a = new AlarmManager();
    var v = layoutHelperStartView(new SleepDetector(null), a);
    a.startPreview();
    var steps = a.getPreviewSteps();
    var ok = starts.size() == steps;
    if (!ok) {
        logger.debug("the alarm rings " + starts.size() + " steps before its persistent phase, the preview "
            + steps);
    }
    for (var s = 1; s <= steps && s <= starts.size(); s++) {
        var sec = starts[s - 1];
        var shown = (sec / 60) + ":" + ((sec % 60 < 10) ? "0" : "") + (sec % 60);
        if (!v.testBuildLayout(dc).showsFragment(shown)) {
            logger.debug("preview step " + s + " must show " + shown + ", when the alarm reaches it");
            ok = false;
        }
        a.testPreviewTick();
    }
    a.stop();
    return ok;
}

//! After the last step the preview ends by itself: no persistent phase, no
//! further output, no alarm state; stop() ends a running preview too.
(:test)
function testAlarm_previewNeverEntersPersistentPhase(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startPreview();
    var steps = alarm.getPreviewSteps();
    for (var s = 2; s <= steps; s++) {
        alarm.testPreviewTick();
    }
    var played = alarm.testGetVibrateCount();
    alarm.testPreviewTick();                 // the tick after the last step ends the preview
    var ok = played == steps && !alarm.isPreviewing() && !alarm.isAlarming()
        && alarm.testGetVibrateCount() == steps;
    for (var i = 0; i < 5; i++) {
        alarm.testPreviewTick();
        alarm.testFireRing();
    }
    if (alarm.testGetVibrateCount() != steps || alarm.isPreviewing() || alarm.isAlarming()
        || alarm.testGetBlockedDeliveries() != 0) {
        logger.debug("output after the preview ended: vib " + alarm.testGetVibrateCount()
            + " previewing " + alarm.isPreviewing());
        ok = false;
    }
    alarm.startPreview();
    alarm.testPreviewTick();
    alarm.stop();
    if (alarm.isPreviewing() || alarm.testGetVibrateCount() != 2) {
        logger.debug("stop() must end a running preview");
        ok = false;
    }
    alarm.testPreviewTick();
    if (alarm.testGetVibrateCount() != 2) {
        logger.debug("a stale preview tick after stop() must not play");
        ok = false;
    }
    if (!ok) {
        logger.debug("played " + played + " of " + steps);
    }
    return ok;
}

//! A preview and an alarm exclude each other: startAlarm() during a preview
//! is refused (no ring, no alarm state), startPreview() during the alarm is
//! refused, and a stopped preview lets the alarm start again.
(:test)
function testAlarm_previewAndAlarmExclude(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startPreview();
    alarm.startAlarm();
    alarm.startDozeAlarm();
    var ok = alarm.isPreviewing() && !alarm.isAlarming() && alarm.testGetRingCount() == 0
        && alarm.testGetVibrateCount() == 1;
    if (!ok) {
        logger.debug("alarm during preview: alarming " + alarm.isAlarming() + " rings " + alarm.testGetRingCount());
    }
    alarm.stopPreview();
    alarm.startAlarm();
    if (!alarm.isAlarming() || alarm.testGetRingCount() != 1) {
        logger.debug("the alarm must start once the preview is over");
        ok = false;
    }
    alarm.startPreview();
    if (alarm.isPreviewing() || alarm.getPreviewStep() != 0 || alarm.testGetVibrateCount() != 1) {
        logger.debug("preview during the alarm must be refused");
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! The tick fallback: when the repeat timer cannot be started, the
//! detector's 1 s tick (onSecond) rings once the wait after the last ring
//! has passed, so the alarm never goes silent; a running timer disables it.
(:test)
function testAlarm_tickFallbackRingsWithoutTimer(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testForceTimerFail(true);
    alarm.startAlarm();
    var ok = alarm.isAlarming() && !alarm.testIsTimerRunning() && alarm.testGetVibrateCount() == 1;
    alarm.onSecond();                            // the wait (10 s) has not passed
    if (alarm.testGetVibrateCount() != 1) {
        logger.debug("onSecond must not ring before the wait has passed");
        ok = false;
    }
    alarm.testAgeLastRing(10000);
    alarm.onSecond();                            // 10 s later: ring 1
    if (alarm.testGetVibrateCount() != 2 || alarm.testGetRingCount() != 2) {
        logger.debug("onSecond must ring once the wait has passed: vib " + alarm.testGetVibrateCount());
        ok = false;
    }
    alarm.testForceTimerFail(false);
    alarm.testAgeLastRing(10000);
    alarm.onSecond();                            // ring 2, and the timer starts again
    if (alarm.testGetVibrateCount() != 3 || !alarm.testIsTimerRunning()) {
        logger.debug("the timer must be restarted once it can: running " + alarm.testIsTimerRunning());
        ok = false;
    }
    alarm.testAgeLastRing(10000);
    alarm.onSecond();                            // the timer runs: the fallback stays quiet
    if (alarm.testGetVibrateCount() != 3) {
        logger.debug("onSecond must not ring while the timer runs");
        ok = false;
    }
    alarm.stop();
    alarm.testAgeLastRing(10000);
    alarm.onSecond();
    if (alarm.testGetVibrateCount() != 3 || alarm.isAlarming()) {
        logger.debug("onSecond after stop() must not ring");
        ok = false;
    }
    return ok;
}
