import Toybox.Test;
import Toybox.Lang;
import Toybox.Attention;

//! Tone support of the running device (vivoactive 5/6 have no playTone; the
//! alarm then falls back to vibration, see AlarmManager channel fallback).
(:debug)
function alarmHelperHasTone() as Boolean {
    return (Attention has :playTone);
}

// -----------------------------------------------------------------------------
// AlarmManager Unit Tests
//
// Covers the ramp table (ring -> step -> wait mapping, the constraints the
// owner set on it: >= 8 perceptible steps, fine first pulses, monotonic
// growth, full strength at 100-130 s, 3 min at full, then the 30 s persistent
// phase), the thresholds derived from it (melody, backlight, doze alarm,
// nudge), the display phases, the per-type vibrate/tone counters, the
// start/stop lifecycle, and the AMOLED backlight regression: a throwing
// Attention.backlight() must never suppress the vibration or tone of the ring
// it belongs to, nor stop the alarm.
//
// Ring times follow from the table: the wait after ring k is the interval of
// ring k's step, so with 2 rings per step the first full ring (ring 16) is at
// 118 s, the last 5 s ring (51) at 293 s, the first persistent ring (52) at
// 298 s.
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
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 0
        && alarm.testGetBlockedDeliveries() == 0;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " phase=" + alarm.getCurrentPhase()
            + " vib=" + alarm.testGetVibrateCount()
            + " tone=" + alarm.testGetToneCount()
            + " bl=" + alarm.testGetBacklightCount());
    }
    return ok;
}

//! startAlarm() fires ring 0 synchronously: ring count 1, one vibration of
//! the first (finest) step, phase 0, isAlarming true, no tone in vibration
//! mode, and no backlight: the gentle steps leave the screen dark.
(:test)
function testAlarm_startFiresRingZeroImmediately(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.startAlarm();
    var ok = alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetRingsFired() == 1
        && alarm.testGetLastRingStep() == 0
        && alarm.testGetVibrateCount() == 1
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 0
        && alarm.getCurrentPhase() == 0
        && alarm.getLastRingPhase() == 0;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " tone=" + alarm.testGetToneCount()
            + " bl=" + alarm.testGetBacklightCount()
            + " phase=" + alarm.getCurrentPhase());
    }
    alarm.stop();
    return ok;
}

//! Ring -> step mapping: 2 rings per step up to full strength (ring 16),
//! 36 full rings (16-51), then the persistent row (52+).
(:test)
function testAlarm_stepForRingBoundaries(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var last = alarm.testGetRampSize() - 1;
    var rings    = [0, 1, 2, 3, 14, 15, 16, 51, 52, 100];
    var expected = [0, 0, 1, 1,  7,  7,  8,  8, last, last];
    var ok = true;
    for (var i = 0; i < rings.size(); i++) {
        var got = alarm.testGetStepForRing(rings[i] as Number);
        if (got != expected[i]) {
            logger.debug("ring " + rings[i] + " expected step " + expected[i] + " got " + got);
            ok = false;
        }
    }
    if (alarm.testGetFirstRingOfStep(8) != 16 || alarm.testGetFirstRingOfStep(last) != 52
        || alarm.testGetFirstRingOfStep(0) != 0) {
        logger.debug("first rings: step 8 " + alarm.testGetFirstRingOfStep(8) + " persistent "
            + alarm.testGetFirstRingOfStep(last));
        ok = false;
    }
    return ok;
}

//! Wait after a ring per step: 10/9/8/8/7/6/6/5/5 s, then 30 s persistent.
(:test)
function testAlarm_intervalPerStep(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var expected = [10000, 9000, 8000, 8000, 7000, 6000, 6000, 5000, 5000, 30000];
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
//! (weaker or shorter pulses may not start the motor); intensity, pulse
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

//! Full strength is reached between 100 and 130 s after the first ring (the
//! owner accepts about two minutes instead of the former 84 s): ring 16 at
//! 118 s with the current table.
(:test)
function testAlarm_fullReachedWithinTwoMinutes(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var fullRing = alarmHelperFirstFullRing(alarm);
    var times = alarmHelperRingTimes(alarm, fullRing);
    var t = times[fullRing];
    var ok = t >= 100 && t <= 130;
    if (!ok) {
        logger.debug("first full ring " + fullRing + " at " + t + " s, expected 100-130 s");
    }
    if (fullRing != 16 || t != 118) {
        logger.debug("table changed: first full ring " + fullRing + " at " + t + " s (was 16 at 118 s)");
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
    alarm.testSetAlarmType(0);
    var ok = alarm.testDisplayPhase(39) == 0 && alarm.testDisplayPhase(40) == 1 && alarm.testDisplayPhase(64) == 1
        && alarm.testDisplayPhase(65) == 2 && alarm.testDisplayPhase(99) == 2 && alarm.testDisplayPhase(100) == 3;
    if (!ok) {
        logger.debug("displayPhase thresholds wrong");
    }
    var expected = [0, 0, 0, 1, 1, 1, 2, 2, 3, 3];
    for (var s = 0; s < alarm.testGetRampSize(); s++) {
        var got = alarm.testDisplayPhase(alarm.testGetRampRow(s)[0]);
        if (got != expected[s]) {
            logger.debug("step " + s + " (" + alarm.testGetRampRow(s)[0] + " %) phase " + got + ", expected " + expected[s]);
            ok = false;
        }
    }
    alarm.startAlarm();                                  // ring 0
    // (rings fired, expected last phase, expected next phase)
    var totals   = [1, 6, 7, 12, 13, 16, 17, 60];
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

//! The Stay Awake doze alarm starts at the first step of at least 60 %
//! (step 5, 63 %): first ring immediately at that step, the display turned
//! on (it is above the 50 % backlight threshold), full strength six rings
//! later, and the backlight schedule counts from the start.
(:test)
function testAlarm_dozeStartsAtSixtyPercent(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    var step = alarm.testDozeStartStep();
    var ok = true;
    if (step != 5 || alarm.testGetRampRow(step)[0] < 60 || alarm.testGetRampRow(step - 1)[0] >= 60) {
        logger.debug("doze step " + step + " (" + alarm.testGetRampRow(step)[0] + " %), expected the first >= 60 %");
        ok = false;
    }
    alarm.startDozeAlarm();
    if (!alarm.isAlarming() || alarm.testGetRingCount() != alarm.testGetFirstRingOfStep(step) + 1
        || alarm.testGetLastRingStep() != step || alarm.testGetRingsFired() != 1
        || alarm.testGetVibrateCount() != 1 || alarm.testGetBacklightCount() != 1
        || alarm.getLastRingPhase() != 1 || alarm.isFullIntensity()) {
        logger.debug("start: rings " + alarm.testGetRingCount() + " step " + alarm.testGetLastRingStep()
            + " vib " + alarm.testGetVibrateCount() + " bl " + alarm.testGetBacklightCount());
        ok = false;
    }
    var fullRing = alarmHelperFirstFullRing(alarm);
    while (alarm.testGetRingCount() <= fullRing) {
        alarm.testFireRing();
    }
    if (!alarm.isFullIntensity() || alarm.testGetRingsFired() != fullRing - alarm.testGetFirstRingOfStep(step) + 1) {
        logger.debug("expected full strength at ring " + fullRing + ", rings fired " + alarm.testGetRingsFired());
        ok = false;
    }
    // Backlight: the first two rings, then every 6th bright ring (7 rings
    // fired here: bright indices 0, 1 and 6).
    if (alarm.testGetBacklightCount() != 3) {
        logger.debug("backlight after " + alarm.testGetRingsFired() + " rings " + alarm.testGetBacklightCount() + ", expected 3");
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! After three minutes at full strength (rings 16-51, 5 s apart) the alarm
//! keeps ringing every 30 s: ring 52 is the first persistent ring. The
//! screen still shows the last phase (4/4), every ring still vibrates, and
//! the timeline is 118 s / 293 s / 298 s / 328 s for rings 16 / 51 / 52 / 53.
(:test)
function testAlarm_persistentPhaseAfterThreeMinutesAtFull(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    var times = alarmHelperRingTimes(alarm, 53);
    var ok = true;
    if (times[16] != 118 || times[51] != 293 || times[52] != 298 || times[53] != 328) {
        logger.debug("ring times 16/51/52/53: " + times[16] + "/" + times[51] + "/" + times[52] + "/" + times[53]);
        ok = false;
    }
    var last = alarm.testGetRampSize() - 1;
    if (alarm.testGetStepForRing(51) != last - 1 || alarm.testGetStepForRing(52) != last) {
        logger.debug("ring 51 must be the last full ring, ring 52 the first persistent one");
        ok = false;
    }
    alarm.startAlarm();
    while (alarm.testGetRingCount() < 54) {
        alarm.testFireRing();
    }
    if (!alarm.isAlarming() || alarm.testGetVibrateCount() != 54 || alarm.getCurrentPhase() != 3
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
//! 16 rings still produce 16 vibrations, the alarm stays active and the
//! backlight counter never moves.
(:test)
function testAlarm_backlightThrowNeverSuppressesVibration(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(true);
    alarm.startAlarm();
    for (var i = 0; i < 15; i++) {
        alarm.testFireRing();
    }
    var ok = alarm.isAlarming()
        && alarm.testGetRingCount() == 16
        && alarm.testGetVibrateCount() == 16
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

//! Same regression on the tone path: a throwing backlight never suppresses
//! the tone of a tone-only alarm, and vibration stays at 0.
(:test)
function testAlarm_backlightThrowNeverSuppressesTone(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(1);
    alarm.testForceBacklightThrow(true);
    alarm.startAlarm();
    for (var i = 0; i < 15; i++) {
        alarm.testFireRing();
    }
    var tone = alarmHelperHasTone();
    var ok = alarm.isAlarming()
        && alarm.testGetRingCount() == 16
        && alarm.testGetToneCount() == (tone ? 16 : 0)
        && alarm.testGetVibrateCount() == (tone ? 0 : 16)
        && alarm.testGetBacklightCount() == 0;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " tone=" + alarm.testGetToneCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount());
    }
    alarm.stop();
    return ok;
}

//! Backlight is sparse and only from the 50 % step (step 4 = ring 8): over
//! 21 rings it is requested exactly on rings 8, 9, 14 and 20 (the first two
//! bright rings, then every 6th) while every ring vibrates (count 21).
(:test)
function testAlarm_backlightSparseSchedule(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    var ok = alarm.testBacklightFromStep() == 4 && alarm.testGetFirstRingOfStep(4) == 8
        && alarm.testGetRampRow(4)[0] >= 50 && alarm.testGetRampRow(3)[0] < 50;
    if (!ok) {
        logger.debug("backlight step " + alarm.testBacklightFromStep() + ", expected 4 (ring 8)");
    }
    alarm.startAlarm();
    for (var i = 0; i < 20; i++) {
        alarm.testFireRing();
    }
    if (alarm.testGetRingCount() != 21 || alarm.testGetVibrateCount() != 21 || alarm.testGetBacklightCount() != 4) {
        logger.debug("rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount());
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! The gentle steps (rings 0-7, below 50 %) never turn the screen on; ring 8
//! (52 %) and ring 9 do, rings 10-13 do not, ring 14 does.
(:test)
function testAlarm_backlightSkipsGentlePhases(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    alarm.startAlarm();              // ring 0
    for (var i = 0; i < 7; i++) {    // rings 1..7
        alarm.testFireRing();
    }
    var afterRing7 = alarm.testGetBacklightCount();
    alarm.testFireRing();            // ring 8 -> bl 1
    var afterRing8 = alarm.testGetBacklightCount();
    alarm.testFireRing();            // ring 9 -> bl 2
    var afterRing9 = alarm.testGetBacklightCount();
    for (var i = 0; i < 4; i++) {    // rings 10..13
        alarm.testFireRing();
    }
    var afterRing13 = alarm.testGetBacklightCount();
    alarm.testFireRing();            // ring 14 -> bl 3
    var afterRing14 = alarm.testGetBacklightCount();
    var ok = afterRing7 == 0 && afterRing8 == 1 && afterRing9 == 2 && afterRing13 == 2
        && afterRing14 == 3 && alarm.testGetRingCount() == 15;
    if (!ok) {
        logger.debug("bl after ring7=" + afterRing7 + " ring8=" + afterRing8 + " ring9=" + afterRing9
            + " ring13=" + afterRing13 + " ring14=" + afterRing14);
    }
    alarm.stop();
    return ok;
}

//! A backlight failure is per request, not latched: rings 8 and 9 throw, and
//! once the throw stops the next scheduled rings (14, then 20) request the
//! backlight again.
(:test)
function testAlarm_backlightThrowDoesNotLatch(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(true);
    alarm.startAlarm();              // ring 0
    for (var i = 0; i < 9; i++) {    // rings 1..9 (8 and 9 throw)
        alarm.testFireRing();
    }
    var duringThrow = alarm.testGetBacklightCount();
    alarm.testForceBacklightThrow(false);
    for (var i = 0; i < 5; i++) {    // rings 10..14
        alarm.testFireRing();
    }
    var afterRing14 = alarm.testGetBacklightCount();
    for (var i = 0; i < 6; i++) {    // rings 15..20
        alarm.testFireRing();
    }
    var afterRing20 = alarm.testGetBacklightCount();
    var ok = duringThrow == 0 && afterRing14 == 1 && afterRing20 == 2
        && alarm.testGetRingCount() == 21
        && alarm.testGetVibrateCount() == 21;
    if (!ok) {
        logger.debug("bl duringThrow=" + duringThrow + " afterRing14=" + afterRing14
            + " afterRing20=" + afterRing20
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount());
    }
    alarm.stop();
    return ok;
}

//! Tone-only alarm (type 1): tone count tracks rings, vibrate count stays 0.
(:test)
function testAlarm_toneOnlyNeverVibrates(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(1);
    alarm.startAlarm();
    for (var i = 0; i < 4; i++) {
        alarm.testFireRing();
    }
    var tone = alarmHelperHasTone();
    var ok = alarm.testGetRingCount() == 5
        && alarm.testGetToneCount() == (tone ? 5 : 0)
        && alarm.testGetVibrateCount() == (tone ? 0 : 5);
    if (!ok) {
        logger.debug("rings=" + alarm.testGetRingCount()
            + " tone=" + alarm.testGetToneCount()
            + " vib=" + alarm.testGetVibrateCount());
    }
    alarm.stop();
    return ok;
}

//! "Nature sound only" (type 1) plays the melody from the very first ring,
//! the quietest one of the ladder (two low notes).
(:test)
function testAlarm_toneOnlyPlaysFromFirstRing(logger as Test.Logger) as Boolean {
    if (!alarmHelperHasTone()) {
        return true;                         // vivoactive 5/6: vibration fallback, covered above
    }
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(1);
    alarm.startAlarm();
    var ok = alarm.testGetToneCount() == 1 && alarm.testGetVibrateCount() == 0 && alarm.testGetLastRingStep() == 0;
    if (!ok) {
        logger.debug("first ring: tone " + alarm.testGetToneCount() + " vib " + alarm.testGetVibrateCount());
    }
    if (Attention has :ToneProfile) {
        var first = alarm.testGetToneProfile(0);
        if (first.size() != 2 || first[0].frequency > 700 || first[1].frequency > 700) {
            logger.debug("the first melody must be the quiet two-note cuckoo");
            ok = false;
        }
    }
    alarm.stop();
    return ok;
}

//! "Both" (type 2): every ring vibrates; the vibration opens the wake-up
//! alone and the melody joins at the first step of at least 40 % (step 3 =
//! ring 6): 6 silent rings, then one tone per ring.
(:test)
function testAlarm_bothJoinsMelodyAtFortyPercent(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(2);
    var ok = alarm.testToneFromStep() == 3 && alarm.testGetRampRow(3)[0] >= 40 && alarm.testGetRampRow(2)[0] < 40
        && alarm.testGetFirstRingOfStep(3) == 6;
    if (!ok) {
        logger.debug("tone step " + alarm.testToneFromStep() + ", expected 3 (ring 6)");
    }
    alarm.startAlarm();
    for (var i = 0; i < 5; i++) {
        alarm.testFireRing();
    }
    if (alarm.testGetRingCount() != 6 || alarm.testGetVibrateCount() != 6 || alarm.testGetToneCount() != 0) {
        logger.debug("below 40 %: rings=" + alarm.testGetRingCount()
            + " tone=" + alarm.testGetToneCount() + " vib=" + alarm.testGetVibrateCount());
        ok = false;
    }
    for (var i = 0; i < 5; i++) {
        alarm.testFireRing();
    }
    var tones = alarmHelperHasTone() ? 5 : 0;
    if (alarm.testGetVibrateCount() != 11 || alarm.testGetToneCount() != tones) {
        logger.debug("from 40 %: vib=" + alarm.testGetVibrateCount()
            + " tone=" + alarm.testGetToneCount() + " expected " + tones);
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! Vibration-only alarm (type 0): vibrate count tracks rings, tone stays 0.
(:test)
function testAlarm_vibrationOnlyNeverTones(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.startAlarm();
    for (var i = 0; i < 4; i++) {
        alarm.testFireRing();
    }
    var ok = alarm.testGetRingCount() == 5
        && alarm.testGetVibrateCount() == 5
        && alarm.testGetToneCount() == 0;
    if (!ok) {
        logger.debug("rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " tone=" + alarm.testGetToneCount());
    }
    alarm.stop();
    return ok;
}

//! stop() clears isAlarming and the ring count, and a later timer tick
//! (testFireRing) is ignored: ring, vibrate and backlight counts stay put.
(:test)
function testAlarm_stopResetsAndSilencesRings(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
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
    alarm.testSetAlarmType(0);
    alarm.startAlarm();
    for (var i = 0; i < 6; i++) {    // rings 1..6 -> total 7, next ring at step 3 (43 %): phase 1
        alarm.testFireRing();
    }
    var ringsBefore = alarm.testGetRingCount();
    var vibBefore   = alarm.testGetVibrateCount();
    var blBefore    = alarm.testGetBacklightCount();
    var phaseBefore = alarm.getCurrentPhase();
    alarm.startAlarm();
    alarm.startDozeAlarm();
    var ok = ringsBefore == 7
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
    alarm.testSetAlarmType(0);
    alarm.startAlarm();
    for (var i = 0; i < 9; i++) {    // total 10 rings, vib 10, bl 2 (rings 8, 9), next ring 63 %: phase 1
        alarm.testFireRing();
    }
    var escalated = alarm.testGetRingCount() == 10
        && alarm.testGetVibrateCount() == 10
        && alarm.testGetBacklightCount() == 2
        && alarm.getCurrentPhase() == 1
        && alarm.testGetLastRingStep() == 4;
    alarm.stop();
    alarm.startAlarm();
    var ok = escalated
        && alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetVibrateCount() == 1
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 0
        && alarm.getCurrentPhase() == 0
        && alarm.testGetLastRingStep() == 0;
    if (!ok) {
        logger.debug("escalated=" + escalated
            + " after restart rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " tone=" + alarm.testGetToneCount()
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
    alarm.testSetAlarmType(2);
    alarm.testFireRing();
    var ok = !alarm.isAlarming()
        && alarm.testGetRingCount() == 0
        && alarm.testGetVibrateCount() == 0
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 0
        && alarm.testGetBlockedDeliveries() == 0;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " tone=" + alarm.testGetToneCount()
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
    alarm.testSetAlarmType(0);
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
//! per ring; with "Both" the melody plays from ring 6 on.
(:test)
function testAlarm_stepBoundariesKeepAlarming(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(2);
    alarm.startAlarm();
    var ok = true;
    for (var i = 0; i < 16; i++) {
        alarm.testFireRing();
        if (!alarm.isAlarming()) {
            logger.debug("alarm stopped after ring " + alarm.testGetRingCount());
            ok = false;
        }
    }
    ok = ok
        && alarm.testGetRingCount() == 17
        && alarm.testGetVibrateCount() == 17
        && alarm.testGetToneCount() == (alarmHelperHasTone() ? 11 : 0)
        && alarm.getCurrentPhase() == 3
        && alarm.isFullIntensity();
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " tone=" + alarm.testGetToneCount()
            + " phase=" + alarm.getCurrentPhase());
    }
    alarm.stop();
    return ok;
}

//! A nudge is one burst of the first step of at least 30 % (step 2, 35 %)
//! on the configured channel with the display turned on; it is not an
//! alarm, it is ignored while the alarm rings, and it is refused (quiet
//! onset gate) unless the session is Stay Awake.
(:test)
function testAlarm_nudgeIsOneGentleBurst(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    var ok = true;
    if (alarm.testNudgeStep() != 2 || alarm.testGetRampRow(2)[0] < 30 || alarm.testGetRampRow(1)[0] >= 30) {
        logger.debug("nudge step " + alarm.testNudgeStep() + ", expected 2 (the first >= 30 %)");
        ok = false;
    }
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

//! "Both" on a watch whose vibration is off plays the tone from the very
//! first ring (the tone delay only applies while the vibration works).
(:test)
function testAlarm_bothWithoutVibrationTonesImmediately(logger as Test.Logger) as Boolean {
    if (!alarmHelperHasTone()) {
        return true;
    }
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(2);
    alarm.testForceChannelsUnavailable(true, false);
    alarm.startAlarm();
    var ok = alarm.testGetToneCount() == 1 && alarm.testGetVibrateCount() == 0;
    if (!ok) {
        logger.debug("tone " + alarm.testGetToneCount() + " vib " + alarm.testGetVibrateCount());
    }
    alarm.stop();
    return ok;
}

//! The nature melodies form a ladder: every step up to full strength has at
//! least as many notes (at most 8), as high a top note and as long a melody
//! as the one before, and grows in at least one of them; every melody is far
//! shorter than its ring wait (melodies never overlap); the first one is two
//! low notes; the persistent step repeats the full-strength melody.
(:test)
function testAlarm_toneMelodiesEscalate(logger as Test.Logger) as Boolean {
    if (!(Attention has :ToneProfile)) {
        return true;                         // vivoactive 5/6: no tones at all
    }
    var alarm = new AlarmManager();
    var n = alarm.testGetRampSize();
    var prevNotes = 0;
    var prevTop = 0;
    var prevLen = 0;
    for (var s = 0; s < n; s++) {
        var melody = alarm.testGetToneProfile(s);
        var top = 0;
        var len = 0;
        for (var i = 0; i < melody.size(); i++) {
            if (melody[i].frequency > top) { top = melody[i].frequency; }
            len += melody[i].duration;
        }
        if (melody.size() > 8 || len * 4 > alarm.testGetIntervalForStep(s)) {
            logger.debug("step " + s + ": " + melody.size() + " notes, " + len + " ms");
            return false;
        }
        if (s == 0 && (melody.size() != 2 || top > 700)) {
            logger.debug("step 0 must be two low notes, got " + melody.size() + " notes up to " + top + " Hz");
            return false;
        }
        if (s > 0 && s < n - 1) {
            if (melody.size() < prevNotes || top < prevTop || len < prevLen
                || (melody.size() == prevNotes && top == prevTop && len == prevLen)) {
                logger.debug("step " + s + " does not escalate: notes " + melody.size() + " top " + top + " Hz len " + len);
                return false;
            }
        }
        if (s == n - 1 && (melody.size() != prevNotes || top != prevTop || len != prevLen)) {
            logger.debug("the persistent step must repeat the full-strength melody");
            return false;
        }
        prevNotes = melody.size();
        prevTop = top;
        prevLen = len;
    }
    return true;
}

//! The screen may flash only at full strength: false before and during the
//! steps below 100 % (rings 0-15), true once ring 16 has fired, false after
//! stop(). getLastRingPhase follows the ring that actually fired.
(:test)
function testAlarm_fullIntensityOnlyAtFullStep(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    var ok = !alarm.isFullIntensity();
    var fullRing = alarmHelperFirstFullRing(alarm);
    alarm.startAlarm();                       // ring 0
    while (alarm.testGetRingCount() < fullRing) {   // rings 1..15
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
    alarm.testFireRing();                     // ring 16: full strength
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
//! ring per step, with the configured channel and the same backlight rule,
//! and reports the step and intensity just played for the screen.
(:test)
function testAlarm_previewPlaysEachStepOnce(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
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
    // Backlight from the 50 % step: bright rings are steps 4-8 (5 of them):
    // the first two, then every 6th -> 2 requests.
    if (alarm.testGetBacklightCount() != 2 || alarm.testGetBlockedDeliveries() != 0) {
        logger.debug("backlight " + alarm.testGetBacklightCount() + " blocked " + alarm.testGetBlockedDeliveries());
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! After the last step the preview ends by itself: no persistent phase, no
//! further output, no alarm state; stop() ends a running preview too.
(:test)
function testAlarm_previewNeverEntersPersistentPhase(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
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
    alarm.testSetAlarmType(0);
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
