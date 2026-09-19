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
// Covers the four-phase escalation (ring -> phase -> interval mapping), the
// per-type vibrate/tone counters, start/stop lifecycle, and the AMOLED
// backlight regression: a throwing Attention.backlight() must never suppress
// the vibration or tone of the ring it belongs to, nor stop the alarm.
//
// Every test that calls startAlarm() calls stop() before returning, because
// startAlarm() arms a real repeat timer.
// -----------------------------------------------------------------------------

//! A fresh AlarmManager is idle: not alarming, ring 0, phase 0, all counters 0.
(:test)
function testAlarm_initialIdleState(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var ok = !alarm.isAlarming()
        && alarm.testGetRingCount() == 0
        && alarm.getCurrentPhase() == 0
        && alarm.testGetVibrateCount() == 0
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 0;
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

//! startAlarm() fires ring 0 synchronously: ring count 1, one vibration, one
//! backlight request, phase 0, isAlarming true, no tone in vibration mode.
(:test)
function testAlarm_startFiresRingZeroImmediately(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.startAlarm();
    var ok = alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetVibrateCount() == 1
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 1
        && alarm.getCurrentPhase() == 0;
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

//! Ring -> phase mapping boundaries: 0-3 -> 0, 4-7 -> 1, 8-11 -> 2, 12+ -> 3.
(:test)
function testAlarm_phaseForRingBoundaries(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var rings    = [0, 3, 4, 7, 8, 11, 12, 100];
    var expected = [0, 0, 1, 1, 2, 2,  3,  3];
    var ok = true;
    for (var i = 0; i < rings.size(); i++) {
        var got = alarm.testGetPhaseForRing(rings[i] as Number);
        if (got != expected[i]) {
            logger.debug("ring " + rings[i] + " expected phase " + expected[i] + " got " + got);
            ok = false;
        }
    }
    return ok;
}

//! Repeat interval per phase is 9000/7000/6000/5000 ms; any phase above 3
//! falls back to the full-intensity interval of 5000 ms.
(:test)
function testAlarm_intervalPerPhase(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var phases   = [0, 1, 2, 3, 4];
    var expected = [9000, 7000, 6000, 5000, 5000];
    var ok = true;
    for (var i = 0; i < phases.size(); i++) {
        var got = alarm.testGetIntervalForPhase(phases[i] as Number);
        if (got != expected[i]) {
            logger.debug("phase " + phases[i] + " expected " + expected[i] + " ms got " + got);
            ok = false;
        }
    }
    return ok;
}

//! getCurrentPhase() follows the ring count: 4 rings -> 1, 8 -> 2, 12 -> 3,
//! and stays at 0 / 1 / 2 on the last ring before each boundary.
(:test)
function testAlarm_currentPhaseAdvancesWithRings(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.startAlarm(); // rings fired: 1
    var ok = true;
    // Table of (total rings fired, expected phase), checked in ascending order.
    var totals   = [1, 3, 4, 7, 8, 11, 12, 20];
    var expected = [0, 0, 1, 1, 2, 2,  3,  3];
    for (var i = 0; i < totals.size(); i++) {
        while (alarm.testGetRingCount() < (totals[i] as Number)) {
            alarm.testFireRing();
        }
        var got = alarm.getCurrentPhase();
        if (got != expected[i]) {
            logger.debug("after " + totals[i] + " rings expected phase " + expected[i] + " got " + got);
            ok = false;
        }
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

//! Backlight is sparse: over 13 rings it is requested exactly on rings
//! 0, 1, 6 and 12 (count 4) while every ring vibrates (count 13).
(:test)
function testAlarm_backlightSparseSchedule(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    alarm.startAlarm();
    for (var i = 0; i < 12; i++) {
        alarm.testFireRing();
    }
    var ok = alarm.testGetRingCount() == 13
        && alarm.testGetVibrateCount() == 13
        && alarm.testGetBacklightCount() == 4;
    if (!ok) {
        logger.debug("rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount());
    }
    alarm.stop();
    return ok;
}

//! Rings 2-5 never request the backlight: the count stays at 2 after ring 5,
//! becomes 3 on ring 6 and stays 3 on ring 7.
(:test)
function testAlarm_backlightSkipsRingsTwoToFive(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    alarm.startAlarm();              // ring 0 -> bl 1
    alarm.testFireRing();            // ring 1 -> bl 2
    var afterRing1 = alarm.testGetBacklightCount();
    for (var i = 0; i < 4; i++) {    // rings 2, 3, 4, 5
        alarm.testFireRing();
    }
    var afterRing5 = alarm.testGetBacklightCount();
    alarm.testFireRing();            // ring 6 -> bl 3
    var afterRing6 = alarm.testGetBacklightCount();
    alarm.testFireRing();            // ring 7
    var afterRing7 = alarm.testGetBacklightCount();
    var ok = afterRing1 == 2 && afterRing5 == 2 && afterRing6 == 3 && afterRing7 == 3
        && alarm.testGetRingCount() == 8;
    if (!ok) {
        logger.debug("bl after ring1=" + afterRing1 + " ring5=" + afterRing5
            + " ring6=" + afterRing6 + " ring7=" + afterRing7
            + " rings=" + alarm.testGetRingCount());
    }
    alarm.stop();
    return ok;
}

//! A backlight failure is per request, not latched: once the throw stops,
//! the next scheduled ring (6, then 12) requests the backlight again.
(:test)
function testAlarm_backlightThrowDoesNotLatch(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(true);
    alarm.startAlarm();              // ring 0 throws
    alarm.testFireRing();            // ring 1 throws
    var duringThrow = alarm.testGetBacklightCount();
    alarm.testForceBacklightThrow(false);
    for (var i = 0; i < 5; i++) {    // rings 2..6
        alarm.testFireRing();
    }
    var afterRing6 = alarm.testGetBacklightCount();
    for (var i = 0; i < 6; i++) {    // rings 7..12
        alarm.testFireRing();
    }
    var afterRing12 = alarm.testGetBacklightCount();
    var ok = duringThrow == 0 && afterRing6 == 1 && afterRing12 == 2
        && alarm.testGetRingCount() == 13
        && alarm.testGetVibrateCount() == 13;
    if (!ok) {
        logger.debug("bl duringThrow=" + duringThrow + " afterRing6=" + afterRing6
            + " afterRing12=" + afterRing12
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

//! Both (type 2): vibrate and tone counts both track the ring count.
(:test)
function testAlarm_bothTypeVibratesAndTones(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(2);
    alarm.startAlarm();
    for (var i = 0; i < 4; i++) {
        alarm.testFireRing();
    }
    var ok = alarm.testGetRingCount() == 5
        && alarm.testGetToneCount() == (alarmHelperHasTone() ? 5 : 0)
        && alarm.testGetVibrateCount() == 5;
    if (!ok) {
        logger.debug("rings=" + alarm.testGetRingCount()
            + " tone=" + alarm.testGetToneCount()
            + " vib=" + alarm.testGetVibrateCount());
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
    alarm.testFireRing();            // rings 0..2 fired: vib 3, bl 2
    var vibBefore = alarm.testGetVibrateCount();
    var blBefore  = alarm.testGetBacklightCount();
    alarm.stop();
    var stoppedOk = !alarm.isAlarming() && alarm.testGetRingCount() == 0;
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
    for (var i = 0; i < 4; i++) {    // rings 1..4 -> total 5, phase 1
        alarm.testFireRing();
    }
    var ringsBefore = alarm.testGetRingCount();
    var vibBefore   = alarm.testGetVibrateCount();
    var blBefore    = alarm.testGetBacklightCount();
    var phaseBefore = alarm.getCurrentPhase();
    alarm.startAlarm();
    var ok = ringsBefore == 5
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
//! ring 0 / phase 0 (ring 1 fired, one vibration, one backlight request).
(:test)
function testAlarm_restartAfterStopResetsCounters(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.startAlarm();
    for (var i = 0; i < 5; i++) {    // total 6 rings, vib 6, bl 2, phase 1
        alarm.testFireRing();
    }
    var escalated = alarm.testGetRingCount() == 6
        && alarm.testGetVibrateCount() == 6
        && alarm.testGetBacklightCount() == 2
        && alarm.getCurrentPhase() == 1;
    alarm.stop();
    alarm.startAlarm();
    var ok = escalated
        && alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetVibrateCount() == 1
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 1
        && alarm.getCurrentPhase() == 0;
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
        && alarm.testGetBacklightCount() == 0;
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

//! Crossing all three phase boundaries (rings 4, 8, 12 restart the repeat
//! timer) keeps the alarm active with one vibration per ring and phase 3.
(:test)
function testAlarm_phaseBoundariesKeepAlarming(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(2);
    alarm.startAlarm();
    var ok = true;
    for (var i = 0; i < 12; i++) {
        alarm.testFireRing();
        if (!alarm.isAlarming()) {
            logger.debug("alarm stopped after ring " + alarm.testGetRingCount());
            ok = false;
        }
    }
    ok = ok
        && alarm.testGetRingCount() == 13
        && alarm.testGetVibrateCount() == 13
        && alarm.testGetToneCount() == (alarmHelperHasTone() ? 13 : 0)
        && alarm.getCurrentPhase() == 3;
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
