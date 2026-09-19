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

//! startAlarm() fires ring 0 synchronously: ring count 1, one vibration,
//! phase 0, isAlarming true, no tone in vibration mode, and no backlight: the
//! gentle phases leave the screen dark.
(:test)
function testAlarm_startFiresRingZeroImmediately(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.startAlarm();
    var ok = alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetVibrateCount() == 1
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 0
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

//! Ring -> phase mapping boundaries: 0-3 -> 0, 4-7 -> 1, 8-11 -> 2,
//! 12-47 -> 3 (three minutes at full intensity), 48+ -> 4 (persistent).
(:test)
function testAlarm_phaseForRingBoundaries(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var rings    = [0, 3, 4, 7, 8, 11, 12, 47, 48, 100];
    var expected = [0, 0, 1, 1, 2, 2,  3,  3,  4,  4];
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

//! Repeat interval per phase is 9000/7000/6000/5000 ms, then 30000 ms in
//! the persistent phase.
(:test)
function testAlarm_intervalPerPhase(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var phases   = [0, 1, 2, 3, 4];
    var expected = [9000, 7000, 6000, 5000, 30000];
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

//! Backlight is sparse and only from phase 2: over 21 rings it is requested
//! exactly on rings 8, 9, 14 and 20 (the first two of phase 2, then every
//! 6th) while every ring vibrates (count 21).
(:test)
function testAlarm_backlightSparseSchedule(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    alarm.startAlarm();
    for (var i = 0; i < 20; i++) {
        alarm.testFireRing();
    }
    var ok = alarm.testGetRingCount() == 21
        && alarm.testGetVibrateCount() == 21
        && alarm.testGetBacklightCount() == 4;
    if (!ok) {
        logger.debug("rings=" + alarm.testGetRingCount()
            + " vib=" + alarm.testGetVibrateCount()
            + " bl=" + alarm.testGetBacklightCount());
    }
    alarm.stop();
    return ok;
}

//! The gentle phases (rings 0-7) never turn the screen on; ring 8 (phase 2)
//! and ring 9 do, rings 10-13 do not, ring 14 does.
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

//! Both (type 2): every ring vibrates; the vibration opens the wake-up
//! alone and the tone joins from phase 2 (ring 8): 8 silent rings, then
//! one tone per ring.
(:test)
function testAlarm_bothTypeTonesFromPhaseTwo(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(2);
    alarm.startAlarm();
    for (var i = 0; i < 7; i++) {
        alarm.testFireRing();
    }
    var ok = alarm.testGetRingCount() == 8
        && alarm.testGetVibrateCount() == 8
        && alarm.testGetToneCount() == 0;
    if (!ok) {
        logger.debug("phases 0-1: rings=" + alarm.testGetRingCount()
            + " tone=" + alarm.testGetToneCount() + " vib=" + alarm.testGetVibrateCount());
    }
    for (var i = 0; i < 5; i++) {
        alarm.testFireRing();
    }
    var tones = alarmHelperHasTone() ? 5 : 0;
    if (ok && (alarm.testGetVibrateCount() != 13 || alarm.testGetToneCount() != tones)) {
        logger.debug("phases 2-3: vib=" + alarm.testGetVibrateCount()
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
//! ring 0 / phase 0 (ring 1 fired, one vibration, screen still dark).
(:test)
function testAlarm_restartAfterStopResetsCounters(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.startAlarm();
    for (var i = 0; i < 9; i++) {    // total 10 rings, vib 10, bl 2 (rings 8, 9), phase 2
        alarm.testFireRing();
    }
    var escalated = alarm.testGetRingCount() == 10
        && alarm.testGetVibrateCount() == 10
        && alarm.testGetBacklightCount() == 2
        && alarm.getCurrentPhase() == 2;
    alarm.stop();
    alarm.startAlarm();
    var ok = escalated
        && alarm.isAlarming()
        && alarm.testGetRingCount() == 1
        && alarm.testGetVibrateCount() == 1
        && alarm.testGetToneCount() == 0
        && alarm.testGetBacklightCount() == 0
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
    // "Both": tones only from phase 2 (rings 8..12).
    ok = ok
        && alarm.testGetRingCount() == 13
        && alarm.testGetVibrateCount() == 13
        && alarm.testGetToneCount() == (alarmHelperHasTone() ? 5 : 0)
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

//! After three minutes at full intensity (rings 12-47) the alarm keeps
//! ringing, but every 30 s: ring 48 enters the persistent phase. The screen
//! still shows the last phase (4/4) and every ring still vibrates. The
//! intervals add up to the documented timeline: ring 12 at 84 s, ring 47 at
//! 259 s, ring 48 at 289 s.
(:test)
function testAlarm_persistentPhaseAfterThreeMinutes(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.startAlarm();                      // ring 0
    var t = 0;
    var ringTime = [0] as Array<Number>;
    while (alarm.testGetRingCount() < 49) {
        // The interval before ring k is the interval of ring k's phase.
        t += alarm.testGetIntervalForPhase(alarm.testGetPhaseForRing(alarm.testGetRingCount())) / 1000;
        alarm.testFireRing();
        ringTime.add(t);
    }
    var ok = true;
    if (ringTime[12] != 84 || ringTime[47] != 259 || ringTime[48] != 289) {
        logger.debug("ring times 12/47/48: " + ringTime[12] + "/" + ringTime[47] + "/" + ringTime[48]);
        ok = false;
    }
    if (!alarm.isAlarming() || alarm.testGetVibrateCount() != 49) {
        logger.debug("alarm must keep vibrating: vib " + alarm.testGetVibrateCount());
        ok = false;
    }
    if (alarm.testGetPhaseForRing(alarm.testGetRingCount()) != 4 || alarm.getCurrentPhase() != 3) {
        logger.debug("expected persistent phase 4 shown as 3, got " + alarm.getCurrentPhase());
        ok = false;
    }
    var pattern = alarm.testGetVibePattern(4);
    if (pattern[0].dutyCycle != 100) {
        logger.debug("persistent phase must keep full intensity");
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! The Stay Awake doze alarm starts at phase 2: first ring immediately at
//! 65 %, the display turned on, full intensity four rings later.
(:test)
function testAlarm_startFromPhaseTwo(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    alarm.startAlarmFromPhase(2);
    var ok = true;
    if (!alarm.isAlarming() || alarm.testGetRingCount() != 9 || alarm.getCurrentPhase() != 2
        || alarm.testGetVibrateCount() != 1 || alarm.testGetBacklightCount() != 1) {
        logger.debug("start: rings " + alarm.testGetRingCount() + " phase " + alarm.getCurrentPhase()
            + " vib " + alarm.testGetVibrateCount() + " bl " + alarm.testGetBacklightCount());
        ok = false;
    }
    for (var i = 0; i < 3; i++) {
        alarm.testFireRing();
    }
    if (alarm.getCurrentPhase() != 3 || alarm.testGetRingsFired() != 4) {
        logger.debug("after 4 rings expected phase 3, got " + alarm.getCurrentPhase());
        ok = false;
    }
    // Backlight follows the rings fired from phase 2 on (first two, then
    // every 6th), so a phase-2 start lights the screen at once.
    if (alarm.testGetBacklightCount() != 2) {
        logger.debug("backlight after 4 rings " + alarm.testGetBacklightCount() + ", expected 2");
        ok = false;
    }
    alarm.stop();
    return ok;
}

//! A nudge is one gentle burst on the configured channel with the display
//! turned on; it is not an alarm, and it is ignored while the alarm rings.
(:test)
function testAlarm_nudgeIsOneGentleBurst(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    alarm.testForceBacklightThrow(false);
    alarm.nudge();
    var ok = true;
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

//! The nature melodies escalate: every phase has more notes, a higher top
//! note and a longer melody than the one before, stays within 8 notes, and
//! is far shorter than its ring interval (melodies never overlap).
(:test)
function testAlarm_toneMelodiesEscalate(logger as Test.Logger) as Boolean {
    if (!(Attention has :ToneProfile)) {
        return true;                         // vivoactive 5/6: no tones at all
    }
    var alarm = new AlarmManager();
    var prevNotes = 0;
    var prevTop = 0;
    var prevLen = 0;
    for (var p = 0; p <= 4; p++) {
        var melody = alarm.testGetToneProfile(p);
        var top = 0;
        var len = 0;
        for (var i = 0; i < melody.size(); i++) {
            if (melody[i].frequency > top) { top = melody[i].frequency; }
            len += melody[i].duration;
        }
        if (melody.size() > 8 || len * 4 > alarm.testGetIntervalForPhase(p)) {
            logger.debug("phase " + p + ": " + melody.size() + " notes, " + len + " ms");
            return false;
        }
        if (p <= 3 && (melody.size() <= prevNotes || top <= prevTop || len <= prevLen)) {
            logger.debug("phase " + p + " does not escalate: notes " + melody.size() + " top " + top + " Hz len " + len);
            return false;
        }
        prevNotes = melody.size();
        prevTop = top;
        prevLen = len;
    }
    return true;
}

//! The screen may flash only at full intensity: false before and during
//! phases 0-2 (rings 0-11), true once ring 12 has fired, false after stop().
//! getLastRingPhase follows the ring that actually fired.
(:test)
function testAlarm_fullIntensityOnlyFromPhaseThree(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.testSetAlarmType(0);
    var ok = !alarm.isFullIntensity();
    alarm.startAlarm();                       // ring 0
    while (alarm.testGetRingCount() < 12) {   // rings 1..11
        if (alarm.isFullIntensity()) {
            logger.debug("full intensity before ring 12 (ring count " + alarm.testGetRingCount() + ")");
            ok = false;
        }
        alarm.testFireRing();
    }
    if (alarm.isFullIntensity() || alarm.getLastRingPhase() != 2 || alarm.getCurrentPhase() != 3) {
        logger.debug("after ring 11: full " + alarm.isFullIntensity() + " last " + alarm.getLastRingPhase()
            + " next " + alarm.getCurrentPhase());
        ok = false;
    }
    alarm.testFireRing();                     // ring 12: full intensity
    if (!alarm.isFullIntensity() || alarm.getLastRingPhase() != 3) {
        logger.debug("ring 12 must be full intensity");
        ok = false;
    }
    alarm.stop();
    if (alarm.isFullIntensity() || alarm.getLastRingPhase() != 0) {
        logger.debug("stop() must clear full intensity");
        ok = false;
    }
    return ok;
}
