import Toybox.Test;
import Toybox.Lang;
import Toybox.Time;

// -----------------------------------------------------------------------------
// Summary / finish / cancel tests for SleepDetector, plus RingMath.
//
// Covers the finishNap()/cancel() paths from every state, the summary
// statistics (planned completion, sleep efficiency, actual sleep, wake
// episodes, avg/min sleep HR), the freeze of those statistics once the nap has
// ended, a second testStart() on the same detector, and the RingMath helpers.
//
// Timing note: testStart() freezes the detector clock (only the fake offset
// moves time), so durations are exact; the small tolerances that remain are
// historical and never needed.
//
// Every test name starts with testSummary_; helpers start with summaryHelper
// and are (:debug) so the test runner never treats them as tests.
// -----------------------------------------------------------------------------

//! Log msg when cond is false; returns cond so callers can fold it into ok.
(:debug)
function summaryHelperCheck(logger as Test.Logger, cond as Boolean, msg as String) as Boolean {
    if (!cond) {
        logger.debug(msg);
    }
    return cond;
}

//! Seconds value of an optional Moment, -1 when null.
(:debug)
function summaryHelperMomentSec(m as Time.Moment?) as Number {
    if (m == null) {
        return -1;
    }
    return (m as Time.Moment).value();
}

//! |actual - expected| <= tol
(:debug)
function summaryHelperNear(actual as Number, expected as Number, tol as Number) as Boolean {
    var diff = actual - expected;
    if (diff < 0) {
        diff = -diff;
    }
    return diff <= tol;
}

//! Fresh detector already in forced sleep with a napMin-minute nap and a
//! 15-minute allowance. Onset is "now" (no stillness to back-date).
(:debug)
function summaryHelperSleepingDetector(napMin as Number) as SleepDetector {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(napMin);
    d.testSetFallAsleepAllowanceMin(15);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    return d;
}

//! Detector driven from forced sleep to the ALARM_NAP_COMPLETE alarm of a
//! 10-minute nap with constant HR hr (fed every second) and no motion.
(:debug)
function summaryHelperRunToNapComplete(hr as Number) as SleepDetector {
    var d = summaryHelperSleepingDetector(10);
    d.testRunMinutes(10, hr, 10.0f);
    return d;
}

// ── cancel() from active states ─────────────────────────────────────────

//! cancel() during CALIBRATING ends the session as cancelled with no sleep data.
(:test)
function testSummary_cancelFromCalibrating(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testRunSeconds(30, 70, 10.0f);
    var ok = true;
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_CALIBRATING, "precondition: CALIBRATING") && ok;
    ok = summaryHelperCheck(logger, d.getNapEndTime() == null, "napEnd must be null while active") && ok;

    var before = d.testNowSec();
    d.cancel();
    var after = d.testNowSec();

    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.isCancelled(), "isCancelled should be true") && ok;
    ok = summaryHelperCheck(logger, !d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should be false") && ok;
    ok = summaryHelperCheck(logger, d.getSleepStartTime() == null, "sleepStart should be null") && ok;
    ok = summaryHelperCheck(logger, d.getPlannedEndTime() == null, "plannedEnd should be null") && ok;
    var fin = summaryHelperMomentSec(d.getNapEndTime());
    ok = summaryHelperCheck(logger, fin >= before && fin <= after, "napEnd=" + fin + " expected in [" + before + "," + after + "]") && ok;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should be false") && ok;
    ok = summaryHelperCheck(logger, !d.isActiveState(), "isActiveState should be false") && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_NONE, "reason=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == 0, "actual=" + d.getActualNapDurationSec()) && ok;
    return ok;
}

//! cancel() during MONITORING (baseline set, no onset) ends as cancelled with zero stats.
(:test)
function testSummary_cancelFromMonitoring(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    d.testRunMinutes(1, 65, 200.0f);
    var ok = true;
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_MONITORING, "precondition: MONITORING") && ok;

    var before = d.testNowSec();
    d.cancel();
    var after = d.testNowSec();

    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.isCancelled(), "isCancelled should be true") && ok;
    ok = summaryHelperCheck(logger, !d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should be false") && ok;
    ok = summaryHelperCheck(logger, d.getSleepStartTime() == null, "sleepStart should be null") && ok;
    var fin = summaryHelperMomentSec(d.getNapEndTime());
    ok = summaryHelperCheck(logger, fin >= before && fin <= after, "napEnd=" + fin) && ok;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should be false") && ok;
    ok = summaryHelperCheck(logger, d.getWakeEpisodes() == 0, "wakes=" + d.getWakeEpisodes()) && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == 0, "actual=" + d.getActualNapDurationSec()) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 0, "completion=" + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, d.getSleepEfficiencyPct() == 0, "efficiency=" + d.getSleepEfficiencyPct()) && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 0 && d.getMinSleepHR() == 0, "HR stats should be 0 (MONITORING HR must not count)") && ok;
    return ok;
}

//! cancel() 10 min into a 30-min sleep: ~33 % completion, ~600 s asleep, 100 % efficiency, stats frozen afterwards.
(:test)
function testSummary_cancelFromSleepingStats(logger as Test.Logger) as Boolean {
    var d = summaryHelperSleepingDetector(30);
    var ok = true;
    var sleepStart = summaryHelperMomentSec(d.getSleepStartTime());
    var plannedEnd = summaryHelperMomentSec(d.getPlannedEndTime());
    ok = summaryHelperCheck(logger, sleepStart > 0, "sleepStart should be set after forced onset") && ok;
    ok = summaryHelperCheck(logger, plannedEnd == sleepStart + 1800, "plannedEnd=" + plannedEnd + " sleepStart=" + sleepStart) && ok;
    ok = summaryHelperCheck(logger, d.testGetNapEndSec() == plannedEnd, "testGetNapEndSec mismatch") && ok;

    d.testRunMinutes(10, 60, 10.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SLEEPING, "precondition: SLEEPING, state=" + d.getState()) && ok;
    // Live values while the segment is still open.
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 600, 5), "live actual=" + d.getActualNapDurationSec()) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 33, "live completion=" + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, d.getSleepEfficiencyPct() == 100, "live efficiency=" + d.getSleepEfficiencyPct()) && ok;
    ok = summaryHelperCheck(logger, d.getNapEndTime() == null, "napEnd must be null while sleeping") && ok;

    var before = d.testNowSec();
    d.cancel();
    var after = d.testNowSec();

    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.isCancelled(), "isCancelled should be true") && ok;
    ok = summaryHelperCheck(logger, d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should be true") && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_NONE, "reason=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, d.getWakeEpisodes() == 0, "wakes=" + d.getWakeEpisodes()) && ok;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should be false") && ok;
    var actual = d.getActualNapDurationSec();
    var completion = d.getPlannedCompletionPct();
    var efficiency = d.getSleepEfficiencyPct();
    var fin = summaryHelperMomentSec(d.getNapEndTime());
    ok = summaryHelperCheck(logger, summaryHelperNear(actual, 600, 5), "actual=" + actual) && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(completion, 33, 1), "completion=" + completion) && ok;
    ok = summaryHelperCheck(logger, efficiency >= 99 && efficiency <= 100, "efficiency=" + efficiency) && ok;
    ok = summaryHelperCheck(logger, fin >= before && fin <= after, "napEnd=" + fin) && ok;

    // Once cancelled the clock no longer influences the statistics.
    d.testAdvanceClock(300);
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == actual, "actual changed after cancel: " + d.getActualNapDurationSec()) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == completion, "completion changed after cancel: " + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, d.getSleepEfficiencyPct() == efficiency, "efficiency changed after cancel: " + d.getSleepEfficiencyPct()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getNapEndTime()) == fin, "napEnd changed after cancel") && ok;
    return ok;
}

// ── finishNap() / cancel() after the alarm ──────────────────────────────

//! finishNap() after the nap-complete alarm: 100 % completion, napEnd is the alarm moment, not the dismiss moment.
(:test)
function testSummary_finishAfterNapCompleteAlarm(logger as Test.Logger) as Boolean {
    var d = summaryHelperSleepingDetector(10);
    var ok = true;
    var sleepStart = summaryHelperMomentSec(d.getSleepStartTime());
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getPlannedEndTime()) == sleepStart + 600, "plannedEnd should be onset + 600") && ok;

    d.testRunMinutes(10, 55, 10.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_ALARM, "expected ALARM, state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_NAP_COMPLETE, "reason=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, d.testIsRunning(), "tick loop keeps running while in ALARM") && ok;
    var alarmSec = summaryHelperMomentSec(d.getNapEndTime());
    ok = summaryHelperCheck(logger, alarmSec >= sleepStart + 600 && alarmSec <= sleepStart + 605, "alarm moment=" + alarmSec + " onset=" + sleepStart) && ok;
    // Stats are already computed when the alarm fires.
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 55 && d.getMinSleepHR() == 55, "HR stats at alarm: avg=" + d.getAvgSleepHR() + " min=" + d.getMinSleepHR()) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 100, "completion at alarm=" + d.getPlannedCompletionPct()) && ok;

    d.testAdvanceClock(37);
    d.finishNap();

    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, !d.isCancelled(), "isCancelled should be false") && ok;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should be false") && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_NAP_COMPLETE, "reason after finish=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getNapEndTime()) == alarmSec, "napEnd moved to dismiss time: " + summaryHelperMomentSec(d.getNapEndTime()) + " vs " + alarmSec) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 100, "completion=" + d.getPlannedCompletionPct()) && ok;
    var efficiency = d.getSleepEfficiencyPct();
    ok = summaryHelperCheck(logger, efficiency >= 99 && efficiency <= 100, "efficiency=" + efficiency) && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 600, 5), "actual=" + d.getActualNapDurationSec()) && ok;
    ok = summaryHelperCheck(logger, d.getWakeEpisodes() == 0, "wakes=" + d.getWakeEpisodes()) && ok;
    ok = summaryHelperCheck(logger, d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should be true") && ok;
    return ok;
}

//! cancel() while the alarm rings behaves like finishNap(): SUMMARY, not cancelled, alarm moment kept.
(:test)
function testSummary_cancelFromAlarmActsLikeFinish(logger as Test.Logger) as Boolean {
    var d = summaryHelperRunToNapComplete(60);
    var ok = true;
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_ALARM, "precondition: ALARM, state=" + d.getState()) && ok;
    var alarmSec = summaryHelperMomentSec(d.getNapEndTime());

    d.testAdvanceClock(20);
    d.cancel();

    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, !d.isCancelled(), "cancel from ALARM must not mark the nap cancelled") && ok;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should be false") && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_NAP_COMPLETE, "reason=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getNapEndTime()) == alarmSec, "napEnd should stay at the alarm moment") && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 100, "completion=" + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 60 && d.getMinSleepHR() == 60, "avg=" + d.getAvgSleepHR() + " min=" + d.getMinSleepHR()) && ok;
    return ok;
}

// ── HR statistics ───────────────────────────────────────────────────────

//! Avg/min sleep HR use only HR fed while SLEEPING; calibration and MONITORING readings are excluded.
(:test)
function testSummary_hrStatsFromSleepOnly(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(30);
    // Calibration: 2 min of HR 45 (would drag min/avg down if counted), moving.
    d.testRunMinutes(2, 45, 200.0f);
    var ok = true;
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_MONITORING, "expected MONITORING after calibration, state=" + d.getState()) && ok;
    // MONITORING: 1 min of HR 40, still moving (no onset).
    d.testRunMinutes(1, 40, 200.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_MONITORING, "should still be MONITORING") && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 0 && d.getMinSleepHR() == 0, "no sleep HR yet") && ok;

    d.testForceSleep();
    d.testRunMinutes(1, 60, 10.0f);
    d.testRunMinutes(1, 70, 10.0f);
    d.testRunMinutes(1, 80, 10.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SLEEPING, "should still be SLEEPING, state=" + d.getState()) && ok;

    d.cancel();
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 70, "avg=" + d.getAvgSleepHR() + " expected 70") && ok;
    ok = summaryHelperCheck(logger, d.getMinSleepHR() == 60, "min=" + d.getMinSleepHR() + " expected 60") && ok;
    return ok;
}

//! With no HR readings at all, avg/min sleep HR stay 0 after both cancel and the alarm.
(:test)
function testSummary_hrStatsZeroWithoutHr(logger as Test.Logger) as Boolean {
    var ok = true;

    var d = summaryHelperSleepingDetector(30);
    d.testRunMinutes(3, 0, 10.0f);
    d.cancel();
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 0, "cancel: avg=" + d.getAvgSleepHR()) && ok;
    ok = summaryHelperCheck(logger, d.getMinSleepHR() == 0, "cancel: min=" + d.getMinSleepHR()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 180, 5), "cancel: actual=" + d.getActualNapDurationSec()) && ok;

    var e = summaryHelperRunToNapComplete(0);
    ok = summaryHelperCheck(logger, e.getState() == SleepDetector.STATE_ALARM, "alarm path: state=" + e.getState()) && ok;
    e.finishNap();
    ok = summaryHelperCheck(logger, e.getAvgSleepHR() == 0, "alarm: avg=" + e.getAvgSleepHR()) && ok;
    ok = summaryHelperCheck(logger, e.getMinSleepHR() == 0, "alarm: min=" + e.getMinSleepHR()) && ok;
    ok = summaryHelperCheck(logger, e.getPlannedCompletionPct() == 100, "alarm: completion=" + e.getPlannedCompletionPct()) && ok;
    return ok;
}

// ── Percentages ─────────────────────────────────────────────────────────

//! Completion and efficiency are 0 before onset (calibrating, monitoring, and after a pre-onset cancel).
(:test)
function testSummary_pctZeroBeforeOnset(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    var ok = true;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 0, "calibrating completion=" + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, d.getSleepEfficiencyPct() == 0, "calibrating efficiency=" + d.getSleepEfficiencyPct()) && ok;
    ok = summaryHelperCheck(logger, d.getRemainingSeconds() == 0, "remaining before onset=" + d.getRemainingSeconds()) && ok;

    d.testRunMinutes(3, 70, 200.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_MONITORING, "expected MONITORING, state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 0, "monitoring completion=" + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, d.getSleepEfficiencyPct() == 0, "monitoring efficiency=" + d.getSleepEfficiencyPct()) && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == 0, "monitoring actual=" + d.getActualNapDurationSec()) && ok;

    d.cancel();
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 0, "cancelled completion=" + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, d.getSleepEfficiencyPct() == 0, "cancelled efficiency=" + d.getSleepEfficiencyPct()) && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == 0, "cancelled actual=" + d.getActualNapDurationSec()) && ok;
    ok = summaryHelperCheck(logger, !d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should be false") && ok;
    return ok;
}

//! Completion is clamped to 100 when the nap ends long after the planned end.
(:test)
function testSummary_completionClampedWhenLate(logger as Test.Logger) as Boolean {
    var d = summaryHelperSleepingDetector(10);
    var ok = true;
    // Jump 20 min ahead without ticking: no alarm check runs, the segment stays open.
    d.testAdvanceClock(1200);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SLEEPING, "still SLEEPING without ticks, state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getRemainingSeconds() == 0, "remaining should clamp to 0, got " + d.getRemainingSeconds()) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 100, "live completion=" + d.getPlannedCompletionPct()) && ok;

    d.cancel();
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.isCancelled(), "isCancelled should be true") && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 100, "completion=" + d.getPlannedCompletionPct()) && ok;
    var efficiency = d.getSleepEfficiencyPct();
    ok = summaryHelperCheck(logger, efficiency >= 99 && efficiency <= 100, "efficiency=" + efficiency) && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 1200, 5), "actual=" + d.getActualNapDurationSec()) && ok;
    return ok;
}

// ── Post-finish immutability ────────────────────────────────────────────

//! After finishNap() further ticks and sensor input change nothing.
(:test)
function testSummary_ticksAfterFinishChangeNothing(logger as Test.Logger) as Boolean {
    var d = summaryHelperRunToNapComplete(58);
    d.finishNap();
    var ok = true;
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "precondition: SUMMARY") && ok;

    var actual = d.getActualNapDurationSec();
    var avg = d.getAvgSleepHR();
    var minHr = d.getMinSleepHR();
    var wakes = d.getWakeEpisodes();
    var minutes = d.testGetMinutesCompleted();
    var fin = summaryHelperMomentSec(d.getNapEndTime());
    var completion = d.getPlannedCompletionPct();
    var efficiency = d.getSleepEfficiencyPct();

    // Two minutes of high HR and heavy motion, ticking every second.
    d.testRunSeconds(120, 95, 300.0f);
    d.testTick();
    d.testTick();

    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == actual, "actual changed: " + d.getActualNapDurationSec() + " vs " + actual) && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == avg && d.getMinSleepHR() == minHr, "HR stats changed: avg=" + d.getAvgSleepHR() + " min=" + d.getMinSleepHR()) && ok;
    ok = summaryHelperCheck(logger, d.getWakeEpisodes() == wakes, "wakes changed: " + d.getWakeEpisodes()) && ok;
    ok = summaryHelperCheck(logger, d.testGetMinutesCompleted() == minutes, "minute logic ran after finish: " + d.testGetMinutesCompleted() + " vs " + minutes) && ok;
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getNapEndTime()) == fin, "napEnd changed") && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == completion, "completion changed: " + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, d.getSleepEfficiencyPct() == efficiency, "efficiency changed: " + d.getSleepEfficiencyPct()) && ok;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should stay false") && ok;
    return ok;
}

//! finishNap() twice, and cancel() from SUMMARY, are safe no-ops that keep the nap un-cancelled.
(:test)
function testSummary_finishNapTwiceAndCancelFromSummary(logger as Test.Logger) as Boolean {
    var d = summaryHelperRunToNapComplete(62);
    d.finishNap();
    var ok = true;
    var actual = d.getActualNapDurationSec();
    var fin = summaryHelperMomentSec(d.getNapEndTime());
    var avg = d.getAvgSleepHR();

    d.testAdvanceClock(10);
    d.finishNap();
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state after 2nd finish=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, !d.isCancelled(), "2nd finish must not cancel") && ok;
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getNapEndTime()) == fin, "napEnd changed on 2nd finish") && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == actual, "actual changed on 2nd finish") && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == avg, "avg changed on 2nd finish") && ok;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should be false") && ok;

    d.testAdvanceClock(10);
    d.cancel();
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state after cancel from SUMMARY=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, !d.isCancelled(), "cancel from SUMMARY must not mark cancelled") && ok;
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getNapEndTime()) == fin, "napEnd changed on cancel from SUMMARY") && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == actual, "actual changed on cancel from SUMMARY") && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_NAP_COMPLETE, "reason=" + d.getAlarmReason()) && ok;
    return ok;
}

// ── Other alarm reasons ─────────────────────────────────────────────────

//! Deadline alarm (sleep never detected) then finishNap(): SUMMARY, ALARM_DEADLINE, never slept, zero stats.
(:test)
function testSummary_deadlineAlarmThenFinish(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(5);
    d.testSetFallAsleepAllowanceMin(5);
    var ok = true;
    var start = d.testGetStartSec();
    var deadline = AlarmCap.deadlineSec(start, 5, 5);
    ok = summaryHelperCheck(logger, d.testGetDeadlineSec() == deadline, "deadline=" + d.testGetDeadlineSec() + " start=" + start) && ok;

    // Never still: the deadline is the only way out (5 + 5 min, plus the
    // minute the cap rounds the start up by).
    d.testRunMinutes(11, 70, 200.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_ALARM, "expected ALARM, state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_DEADLINE, "reason=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, !d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should be false") && ok;
    ok = summaryHelperCheck(logger, d.getSleepStartTime() == null && d.getPlannedEndTime() == null, "sleepStart/plannedEnd should be null") && ok;
    var alarmSec = summaryHelperMomentSec(d.getNapEndTime());
    ok = summaryHelperCheck(logger, alarmSec == deadline, "alarm moment=" + alarmSec + " deadline=" + deadline) && ok;
    ok = summaryHelperCheck(logger, d.getSecondsUntilDeadline() == 0, "secondsUntilDeadline=" + d.getSecondsUntilDeadline()) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 0 && d.getSleepEfficiencyPct() == 0, "pcts should be 0") && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == 0, "actual=" + d.getActualNapDurationSec()) && ok;

    d.testAdvanceClock(15);
    d.finishNap();
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, !d.isCancelled(), "isCancelled should be false") && ok;
    ok = summaryHelperCheck(logger, !d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should still be false") && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_DEADLINE, "reason after finish=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getNapEndTime()) == alarmSec, "napEnd should stay at the alarm moment") && ok;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should be false") && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 0 && d.getMinSleepHR() == 0, "HR stats should be 0") && ok;
    return ok;
}

//! Smart wake at 26 of 30 min: ALARM_SMART_WAKE, completion ~86 %, efficiency 100 %, kept through finishNap().
(:test)
function testSummary_smartWakeCompletionBelow100(logger as Test.Logger) as Boolean {
    var d = summaryHelperSleepingDetector(30);
    var ok = true;
    var sleepStart = summaryHelperMomentSec(d.getSleepStartTime());
    ok = summaryHelperCheck(logger, d.getSmartWakeWindowSec() == 300, "window=" + d.getSmartWakeWindowSec()) && ok;

    d.testRunMinutes(25, 60, 10.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SLEEPING, "should still sleep at 25 min, state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.isSmartWakeActive(), "smart wake window should be open at 25 min") && ok;

    // One minute of stirring inside the window.
    d.testRunMinutes(1, 60, 80.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_ALARM, "expected ALARM, state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_SMART_WAKE, "reason=" + d.getAlarmReason()) && ok;
    var alarmSec = summaryHelperMomentSec(d.getNapEndTime());
    ok = summaryHelperCheck(logger, alarmSec >= sleepStart + 1560 && alarmSec <= sleepStart + 1566, "alarm moment=" + alarmSec + " onset=" + sleepStart) && ok;
    var completion = d.getPlannedCompletionPct();
    ok = summaryHelperCheck(logger, summaryHelperNear(completion, 86, 1), "completion=" + completion) && ok;
    var efficiency = d.getSleepEfficiencyPct();
    ok = summaryHelperCheck(logger, efficiency >= 99 && efficiency <= 100, "efficiency=" + efficiency) && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 1560, 6), "actual=" + d.getActualNapDurationSec()) && ok;

    d.testAdvanceClock(30);
    d.finishNap();
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SUMMARY, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, !d.isCancelled(), "isCancelled should be false") && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_SMART_WAKE, "reason after finish=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == completion, "completion changed after finish: " + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperMomentSec(d.getNapEndTime()) == alarmSec, "napEnd should stay at the alarm moment") && ok;
    return ok;
}

// ── Multiple sleep segments ─────────────────────────────────────────────

//! A wake episode closes the segment; re-entry opens a back-dated one; actual sleep sums both and efficiency drops.
(:test)
function testSummary_wakeEpisodeSegmentsAndEfficiency(logger as Test.Logger) as Boolean {
    var d = summaryHelperSleepingDetector(30);
    var ok = true;

    // 5 min asleep, then one minute of heavy motion -> wake episode.
    d.testRunMinutes(5, 60, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_MONITORING, "expected MONITORING after wake, state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getWakeEpisodes() == 1, "wakes=" + d.getWakeEpisodes()) && ok;
    var closed = d.getActualNapDurationSec();
    // The wake minute itself counts as awake: the segment closes at its start.
    ok = summaryHelperCheck(logger, summaryHelperNear(closed, 300, 5), "closed segment=" + closed) && ok;
    ok = summaryHelperCheck(logger, d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should stay true") && ok;

    // 3 min awake with high HR (must not enter the sleep HR stats), no open segment.
    d.testRunMinutes(3, 100, 300.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_MONITORING, "should still be awake") && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == closed, "actual grew while awake: " + d.getActualNapDurationSec()) && ok;

    // 2 still minutes -> re-entry, back-dated by 120 s (MONITORING HR not counted).
    d.testRunMinutes(2, 60, 10.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SLEEPING, "expected re-entry into SLEEPING, state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 420, 6), "actual after re-entry=" + d.getActualNapDurationSec()) && ok;

    d.testRunMinutes(2, 60, 10.0f);
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_SLEEPING, "should still be SLEEPING") && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 540, 6), "live actual=" + d.getActualNapDurationSec()) && ok;

    d.cancel();
    ok = summaryHelperCheck(logger, d.isCancelled(), "isCancelled should be true") && ok;
    ok = summaryHelperCheck(logger, d.getWakeEpisodes() == 1, "wakes after cancel=" + d.getWakeEpisodes()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 540, 6), "actual=" + d.getActualNapDurationSec()) && ok;
    // 780 s elapsed since onset of a 1800 s nap -> 43 %; 540 s asleep of 780 -> 69 %.
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getPlannedCompletionPct(), 43, 1), "completion=" + d.getPlannedCompletionPct()) && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getSleepEfficiencyPct(), 69, 2), "efficiency=" + d.getSleepEfficiencyPct()) && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 60, "avg=" + d.getAvgSleepHR() + " (awake HR 100 must not count)") && ok;
    ok = summaryHelperCheck(logger, d.getMinSleepHR() == 60, "min=" + d.getMinSleepHR()) && ok;
    return ok;
}

// ── Session restart / stop ──────────────────────────────────────────────

//! A second testStart() on the same detector resets every per-session value and works normally.
(:test)
function testSummary_restartResetsSession(logger as Test.Logger) as Boolean {
    var d = summaryHelperSleepingDetector(30);
    d.testRunMinutes(5, 60, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);
    d.cancel();
    var ok = true;
    ok = summaryHelperCheck(logger, d.isCancelled() && d.getWakeEpisodes() == 1 && d.getActualNapDurationSec() > 0, "precondition: cancelled session with a wake episode") && ok;

    d.testStart();
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_CALIBRATING, "state=" + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getWakeEpisodes() == 0, "wakes=" + d.getWakeEpisodes()) && ok;
    ok = summaryHelperCheck(logger, d.getActualNapDurationSec() == 0, "actual=" + d.getActualNapDurationSec()) && ok;
    ok = summaryHelperCheck(logger, d.getAlarmReason() == SleepDetector.ALARM_NONE, "reason=" + d.getAlarmReason()) && ok;
    ok = summaryHelperCheck(logger, !d.isCancelled(), "isCancelled should be false") && ok;
    ok = summaryHelperCheck(logger, !d.hasSleptAtLeastOnce(), "hasSleptAtLeastOnce should be false") && ok;
    ok = summaryHelperCheck(logger, d.getSleepStartTime() == null && d.getPlannedEndTime() == null && d.getNapEndTime() == null, "moments should be null") && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 0 && d.getMinSleepHR() == 0, "HR stats should be 0") && ok;
    ok = summaryHelperCheck(logger, d.getPlannedCompletionPct() == 0 && d.getSleepEfficiencyPct() == 0, "pcts should be 0") && ok;
    ok = summaryHelperCheck(logger, d.getStillMinutes() == 0 && d.testGetMinutesCompleted() == 0, "still/minutes should be 0") && ok;
    ok = summaryHelperCheck(logger, d.getHRBaseline() < 0.001f, "baseline=" + d.getHRBaseline()) && ok;
    ok = summaryHelperCheck(logger, d.testIsRunning(), "running should be true") && ok;
    ok = summaryHelperCheck(logger, summaryHelperNear(d.testGetStartSec(), d.testNowSec(), 1), "startSec should be now") && ok;
    // Settings persist (30 min nap, 15 min allowance) and the deadline is rebuilt from them.
    ok = summaryHelperCheck(logger, d.getNapDurationMin() == 30 && d.getFallAsleepAllowanceMin() == 15, "settings should persist") && ok;
    ok = summaryHelperCheck(logger, d.testGetDeadlineSec() == AlarmCap.deadlineSec(d.testGetStartSec(), 15, 30), "deadline=" + d.testGetDeadlineSec()) && ok;

    // The new session accumulates from scratch.
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testRunMinutes(2, 64, 10.0f);
    d.cancel();
    ok = summaryHelperCheck(logger, summaryHelperNear(d.getActualNapDurationSec(), 120, 5), "2nd session actual=" + d.getActualNapDurationSec()) && ok;
    ok = summaryHelperCheck(logger, d.getWakeEpisodes() == 0, "2nd session wakes=" + d.getWakeEpisodes()) && ok;
    ok = summaryHelperCheck(logger, d.getAvgSleepHR() == 64 && d.getMinSleepHR() == 64, "2nd session HR avg=" + d.getAvgSleepHR() + " min=" + d.getMinSleepHR()) && ok;
    return ok;
}

//! stop() halts the tick loop without changing the state; later ticks run no minute logic.
(:test)
function testSummary_stopHaltsTicksWithoutChangingState(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testRunSeconds(30, 70, 10.0f);
    d.stop();
    var ok = true;
    ok = summaryHelperCheck(logger, !d.testIsRunning(), "running should be false") && ok;
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_CALIBRATING, "stop() must not change the state, state=" + d.getState()) && ok;

    d.testRunSeconds(150, 70, 10.0f);
    ok = summaryHelperCheck(logger, d.testGetMinutesCompleted() == 0, "minute logic ran after stop: " + d.testGetMinutesCompleted()) && ok;
    ok = summaryHelperCheck(logger, d.getState() == SleepDetector.STATE_CALIBRATING, "state changed after stop: " + d.getState()) && ok;
    ok = summaryHelperCheck(logger, d.getNapEndTime() == null, "napEnd should stay null (stop is not a finish)") && ok;
    ok = summaryHelperCheck(logger, !d.isCancelled(), "stop is not a cancel") && ok;
    return ok;
}

// ── RingMath ────────────────────────────────────────────────────────────

//! endAngle(pct) maps 1..99 onto the clockwise-from-12-o'clock arc end in [0, 360).
(:test)
function testSummary_ringMathEndAngle(logger as Test.Logger) as Boolean {
    var ok = true;
    ok = summaryHelperCheck(logger, RingMath.endAngle(1) == 87, "endAngle(1)=" + RingMath.endAngle(1)) && ok;
    ok = summaryHelperCheck(logger, RingMath.endAngle(25) == 0, "endAngle(25)=" + RingMath.endAngle(25)) && ok;
    ok = summaryHelperCheck(logger, RingMath.endAngle(47) == 281, "endAngle(47)=" + RingMath.endAngle(47)) && ok;
    ok = summaryHelperCheck(logger, RingMath.endAngle(50) == 270, "endAngle(50)=" + RingMath.endAngle(50)) && ok;
    ok = summaryHelperCheck(logger, RingMath.endAngle(75) == 180, "endAngle(75)=" + RingMath.endAngle(75)) && ok;
    ok = summaryHelperCheck(logger, RingMath.endAngle(99) == 94, "endAngle(99)=" + RingMath.endAngle(99)) && ok;
    // Every value in range stays inside [0, 360).
    for (var pct = 1; pct <= 99; pct++) {
        var a = RingMath.endAngle(pct);
        if (a < 0 || a >= 360) {
            ok = summaryHelperCheck(logger, false, "endAngle(" + pct + ")=" + a + " out of range") && ok;
        }
    }
    return ok;
}

//! isFullRing is true only at 100 and above; clampPct pins values into 0..100.
(:test)
function testSummary_ringMathFullRingAndClamp(logger as Test.Logger) as Boolean {
    var ok = true;
    ok = summaryHelperCheck(logger, RingMath.isFullRing(100), "isFullRing(100) should be true") && ok;
    ok = summaryHelperCheck(logger, !RingMath.isFullRing(99), "isFullRing(99) should be false") && ok;
    ok = summaryHelperCheck(logger, RingMath.isFullRing(150), "isFullRing(150) should be true") && ok;
    ok = summaryHelperCheck(logger, !RingMath.isFullRing(0), "isFullRing(0) should be false") && ok;
    ok = summaryHelperCheck(logger, RingMath.clampPct(-5) == 0, "clampPct(-5)=" + RingMath.clampPct(-5)) && ok;
    ok = summaryHelperCheck(logger, RingMath.clampPct(150) == 100, "clampPct(150)=" + RingMath.clampPct(150)) && ok;
    ok = summaryHelperCheck(logger, RingMath.clampPct(0) == 0, "clampPct(0)=" + RingMath.clampPct(0)) && ok;
    ok = summaryHelperCheck(logger, RingMath.clampPct(100) == 100, "clampPct(100)=" + RingMath.clampPct(100)) && ok;
    ok = summaryHelperCheck(logger, RingMath.clampPct(42) == 42, "clampPct(42)=" + RingMath.clampPct(42)) && ok;
    return ok;
}
