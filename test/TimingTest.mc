import Toybox.Test;
import Toybox.Lang;
import Toybox.Time;

// -----------------------------------------------------------------------------
// Wall-clock alarm timing, deadline alarm and smart-wake window tests.
//
// testStart() freezes the detector clock: only the fake offset moves time, one
// second per fed tick, so every expectation below is exact. Expectations are
// expressed against the detector's own clock (testNowSec / testGetNapEndSec /
// testGetDeadlineSec); the alarm-tick helper also checks the state on every
// tick before the alarm second.
// -----------------------------------------------------------------------------

// ── Helpers (debug builds only: they call the detector's test hooks) ─────────

//! New detector already asleep: nap napMin, HR baseline 70, onset forced now.
(:debug)
function timingSleepingDetector(napMin as Number) as SleepDetector {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(napMin);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    return d;
}

//! Feed identical seconds until the detector clock reaches alarmSec.
//! While the clock is still before alarmSec the state must be preState (any
//! active state when preState < 0) with no alarm reason; the tick that reaches
//! alarmSec must leave the detector in STATE_ALARM.
(:debug)
function timingRunToAlarm(d as SleepDetector, alarmSec as Number, hr as Number,
                          motion as Float, preState as Number,
                          logger as Test.Logger) as Boolean {
    var guard = (alarmSec - d.testNowSec()) + 5;
    var ticks = 0;
    while (d.testNowSec() < alarmSec) {
        if (ticks >= guard) {
            logger.debug("detector clock never reached the alarm second");
            return false;
        }
        d.testFeedSecond(hr, motion);
        ticks += 1;
        var now = d.testNowSec();
        if (now < alarmSec) {
            var st = d.getState();
            var stateOk = (preState < 0) ? d.isActiveState() : (st == preState);
            if (!stateOk || d.getAlarmReason() != SleepDetector.ALARM_NONE) {
                logger.debug("state " + st + " reason " + d.getAlarmReason()
                    + " with " + (alarmSec - now) + " s still to go");
                return false;
            }
        }
    }
    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("no alarm on the tick that reached the alarm second, state "
            + d.getState());
        return false;
    }
    return true;
}

//! One minute of light stirring: 54 quiet seconds plus 6 seconds at 100 mg.
//! Minute mean 19 mg (< 1.5 x threshold) with 6 active seconds: a smart-wake
//! stir (> 5 active s, i.e. not a still minute) but not a wake episode
//! (< 10 active s, mean <= 100).
(:debug)
function timingFeedStirMinute(d as SleepDetector, hr as Number) as Void {
    d.testRunSeconds(54, hr, 10.0f);
    d.testRunSeconds(6, hr, 100.0f);
}

// ── Nap-complete alarm ──────────────────────────────────────────────────────

//! For every supported duration the alarm fires exactly when the detector clock
//! reaches sleepStart + duration, never earlier, with ALARM_NAP_COMPLETE.
(:test)
function testTiming_napCompleteAlarmAtPlannedEndAllDurations(logger as Test.Logger) as Boolean {
    var durations = [5, 10, 15, 30, 60, 120] as Array<Number>;
    for (var i = 0; i < durations.size(); i++) {
        var dur = durations[i];
        var d = timingSleepingDetector(dur);
        var napEnd = d.testGetNapEndSec();
        var secs = napEnd - d.testNowSec();
        if (secs != dur * 60) {
            logger.debug("nap " + dur + ": planned end " + secs + " s away, expected " + (dur * 60));
            return false;
        }
        if (d.getState() != SleepDetector.STATE_SLEEPING) {
            logger.debug("nap " + dur + ": expected SLEEPING after forced onset");
            return false;
        }
        if (!timingRunToAlarm(d, napEnd, 55, 10.0f, SleepDetector.STATE_SLEEPING, logger)) {
            logger.debug("nap " + dur + " min failed");
            return false;
        }
        if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
            logger.debug("nap " + dur + ": reason " + d.getAlarmReason() + ", expected NAP_COMPLETE");
            return false;
        }
        if (d.getWakeEpisodes() != 0) {
            logger.debug("nap " + dur + ": unexpected wake episodes " + d.getWakeEpisodes());
            return false;
        }
    }
    return true;
}

//! A clock jump to exactly plannedEnd does nothing by itself; the next tick
//! fires ALARM_NAP_COMPLETE (the due check is >=, evaluated only on ticks).
(:test)
function testTiming_clockJumpPastPlannedEndFiresOnNextTick(logger as Test.Logger) as Boolean {
    var d = timingSleepingDetector(30);
    var napEnd = d.testGetNapEndSec();

    d.testAdvanceClock(napEnd - d.testNowSec());
    if (d.testNowSec() < napEnd) {
        logger.debug("clock jump did not reach the planned end");
        return false;
    }
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("state changed without a tick: " + d.getState());
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("alarm reason set without a tick");
        return false;
    }
    if (d.getRemainingSeconds() != 0) {
        logger.debug("remaining should clamp to 0 at the planned end, got " + d.getRemainingSeconds());
        return false;
    }

    d.testTick();
    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("expected ALARM after the tick, got " + d.getState());
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("expected NAP_COMPLETE, got " + d.getAlarmReason());
        return false;
    }
    if (d.testGetMinutesCompleted() != 0) {
        logger.debug("a clock jump must not run minute logic");
        return false;
    }
    var endMoment = d.getNapEndTime();
    if (endMoment == null || (endMoment as Time.Moment).value() < napEnd) {
        logger.debug("nap end time not recorded at the alarm");
        return false;
    }
    return true;
}

//! Once in ALARM, further ticks (even with heavy motion or a clock jump) change
//! neither state nor reason, and the actual sleep duration stops growing.
(:test)
function testTiming_alarmIsTerminalForFurtherTicks(logger as Test.Logger) as Boolean {
    var d = timingSleepingDetector(5);
    var napEnd = d.testGetNapEndSec();
    if (!timingRunToAlarm(d, napEnd, 55, 10.0f, SleepDetector.STATE_SLEEPING, logger)) {
        return false;
    }
    var actual = d.getActualNapDurationSec();
    var minutes = d.testGetMinutesCompleted();
    var endMoment = d.getNapEndTime();
    var startMoment = d.getSleepStartTime();
    if (endMoment == null || startMoment == null) {
        logger.debug("sleep start / nap end must be set after the alarm");
        return false;
    }
    var finishSec = (endMoment as Time.Moment).value();
    if (actual < 300 || actual != finishSec - (startMoment as Time.Moment).value()) {
        logger.debug("actual sleep " + actual + " does not match onset..alarm span");
        return false;
    }

    d.testRunSeconds(130, 70, 200.0f);
    d.testAdvanceClock(600);
    d.testTick();

    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("state left ALARM: " + d.getState());
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("alarm reason changed: " + d.getAlarmReason());
        return false;
    }
    if (d.getActualNapDurationSec() != actual) {
        logger.debug("actual sleep kept growing: " + d.getActualNapDurationSec());
        return false;
    }
    if (d.testGetMinutesCompleted() != minutes) {
        logger.debug("minute logic ran after the alarm");
        return false;
    }
    if (d.getRemainingSeconds() != 0) {
        logger.debug("remaining after alarm should be 0");
        return false;
    }
    var endAgain = d.getNapEndTime();
    if (endAgain == null || (endAgain as Time.Moment).value() != finishSec) {
        logger.debug("nap end time moved after the alarm");
        return false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("motion after the alarm counted as a wake episode");
        return false;
    }
    return true;
}

// ── Deadline alarm ──────────────────────────────────────────────────────────

//! Never still with a 5 min nap: ALARM_DEADLINE fires from MONITORING exactly at
//! start + (15 + 5) min, and not one second earlier.
(:test)
function testTiming_deadlineAlarmNap5NeverStill(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(5);
    var deadline = d.testGetDeadlineSec();
    if (deadline - d.testGetStartSec() != 20 * 60) {
        logger.debug("deadline expected 1200 s after start, got " + (deadline - d.testGetStartSec()));
        return false;
    }

    d.testRunSeconds(120, 70, 200.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING after calibration, got " + d.getState());
        return false;
    }
    if (!timingRunToAlarm(d, deadline, 70, 200.0f, SleepDetector.STATE_MONITORING, logger)) {
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_DEADLINE) {
        logger.debug("expected ALARM_DEADLINE, got " + d.getAlarmReason());
        return false;
    }
    if (d.hasSleptAtLeastOnce() || d.getRemainingSeconds() != 0 || d.getSecondsUntilDeadline() != 0) {
        logger.debug("deadline alarm must not look like a detected nap");
        return false;
    }
    return true;
}

//! Never still with a 120 min nap: the deadline is start + 135 min and the
//! planned end stays unset.
(:test)
function testTiming_deadlineAlarmNap120NeverStill(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(120);
    var deadline = d.testGetDeadlineSec();
    if (deadline - d.testGetStartSec() != 135 * 60) {
        logger.debug("deadline expected 8100 s after start, got " + (deadline - d.testGetStartSec()));
        return false;
    }

    d.testRunSeconds(120, 70, 200.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING after calibration, got " + d.getState());
        return false;
    }
    if (!timingRunToAlarm(d, deadline, 70, 200.0f, SleepDetector.STATE_MONITORING, logger)) {
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_DEADLINE) {
        logger.debug("expected ALARM_DEADLINE, got " + d.getAlarmReason());
        return false;
    }
    if (d.getPlannedEndTime() != null || d.testGetNapEndSec() != 0) {
        logger.debug("planned end must stay unset when sleep was never detected");
        return false;
    }
    return true;
}

//! A custom fall-asleep allowance moves the deadline: allowance 5 + nap 30 ->
//! ALARM_DEADLINE at start + 35 min.
(:test)
function testTiming_deadlineUsesCustomAllowance(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(30);
    var start = d.testGetStartSec();
    if (d.testGetDeadlineSec() - start != 45 * 60) {
        logger.debug("default allowance 15 + nap 30 should give 2700 s, got " + (d.testGetDeadlineSec() - start));
        return false;
    }
    d.testSetFallAsleepAllowanceMin(5);
    var deadline = d.testGetDeadlineSec();
    if (deadline - start != 35 * 60 || d.getFallAsleepAllowanceMin() != 5) {
        logger.debug("allowance 5 + nap 30 should give 2100 s, got " + (deadline - start));
        return false;
    }

    d.testRunSeconds(120, 70, 200.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING after calibration, got " + d.getState());
        return false;
    }
    if (!timingRunToAlarm(d, deadline, 70, 200.0f, SleepDetector.STATE_MONITORING, logger)) {
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_DEADLINE) {
        logger.debug("expected ALARM_DEADLINE, got " + d.getAlarmReason());
        return false;
    }
    return true;
}

//! The deadline is a hard upper bound: nap 30, allowance 5 (deadline 35 min),
//! restless for 10 min, onset at 10 min -> the alarm is capped at 35 min
//! (not 40) with NAP_COMPLETE, and 83 % of the planned nap is reported.
(:test)
function testTiming_deadlineCapsPlannedEndAfterLateOnset(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(30);
    d.testSetFallAsleepAllowanceMin(5);
    d.testSetBaseline(70.0f);
    var start = d.testGetStartSec();
    var deadline = d.testGetDeadlineSec();
    if (deadline != start + 35 * 60) {
        logger.debug("deadline expected at 35 min, got " + (deadline - start));
        return false;
    }

    d.testRunMinutes(10, 70, 200.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING || d.hasSleptAtLeastOnce()) {
        logger.debug("expected still awake after 10 restless minutes");
        return false;
    }
    d.testForceSleep();
    if (d.testGetNapEndSec() != deadline) {
        logger.debug("planned end must be capped at the deadline, got offset " + (d.testGetNapEndSec() - start));
        return false;
    }
    var pe = d.getPlannedEndTime();
    if (pe == null || (pe as Time.Moment).value() != d.getDeadlineTime().value()) {
        logger.debug("getPlannedEndTime() must equal the displayed 'Alarm by' time");
        return false;
    }

    if (!timingRunToAlarm(d, deadline, 55, 10.0f, SleepDetector.STATE_SLEEPING, logger)) {
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("expected NAP_COMPLETE (sleep was detected), got " + d.getAlarmReason());
        return false;
    }
    if (d.getPlannedCompletionPct() != 83) {
        logger.debug("25 of 30 planned minutes -> 83 %, got " + d.getPlannedCompletionPct());
        return false;
    }
    return true;
}

//! An onset early enough is not affected by the cap: onset at 2 min of a 30
//! min nap with a 15 min allowance -> alarm at 32 min, before the 45 min deadline.
(:test)
function testTiming_earlyOnsetIsNotCapped(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    d.testRunMinutes(2, 70, 200.0f);
    d.testForceSleep();
    var start = d.testGetStartSec();
    if (d.testGetNapEndSec() != start + 32 * 60) {
        logger.debug("expected planned end at 32 min, got " + (d.testGetNapEndSec() - start));
        return false;
    }
    if (d.testGetNapEndSec() >= d.testGetDeadlineSec()) {
        logger.debug("planned end must lie before the deadline here");
        return false;
    }
    return true;
}

// ── Countdown getters ───────────────────────────────────────────────────────

//! getRemainingSeconds is 0 before onset, plannedEnd - now while asleep, and 0
//! again once the alarm has fired.
(:test)
function testTiming_remainingSecondsLifecycle(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(30);
    d.testSetBaseline(70.0f);
    if (d.getRemainingSeconds() != 0) {
        logger.debug("remaining before onset should be 0, got " + d.getRemainingSeconds());
        return false;
    }
    d.testRunMinutes(1, 70, 200.0f);
    if (d.getRemainingSeconds() != 0) {
        logger.debug("remaining while monitoring should be 0, got " + d.getRemainingSeconds());
        return false;
    }

    d.testForceSleep();
    var napEnd = d.testGetNapEndSec();
    if (d.getRemainingSeconds() != 30 * 60 || d.getRemainingSeconds() != napEnd - d.testNowSec()) {
        logger.debug("remaining right after onset should be 1800, got " + d.getRemainingSeconds());
        return false;
    }
    d.testRunSeconds(100, 55, 10.0f);
    var rem = d.getRemainingSeconds();
    if (rem != napEnd - d.testNowSec() || rem > 1700 || rem < 1698) {
        logger.debug("remaining after 100 s should be ~1700, got " + rem);
        return false;
    }

    if (!timingRunToAlarm(d, napEnd, 55, 10.0f, SleepDetector.STATE_SLEEPING, logger)) {
        return false;
    }
    if (d.getRemainingSeconds() != 0) {
        logger.debug("remaining after the alarm should be 0, got " + d.getRemainingSeconds());
        return false;
    }
    return true;
}

//! getSecondsUntilDeadline starts at (allowance + duration) * 60, tracks the
//! detector clock tick by tick, and clamps at 0.
(:test)
function testTiming_secondsUntilDeadlineCountsDown(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(5);
    var deadline = d.testGetDeadlineSec();
    var first = d.getSecondsUntilDeadline();
    if (first != 20 * 60 || first != deadline - d.testNowSec()) {
        logger.debug("initial seconds until deadline should be 1200, got " + first);
        return false;
    }

    for (var i = 0; i < 10; i++) {
        var before = d.getSecondsUntilDeadline();
        var nowBefore = d.testNowSec();
        d.testTick();
        var after = d.getSecondsUntilDeadline();
        var elapsed = d.testNowSec() - nowBefore;
        if (elapsed < 1 || before - after != elapsed || after != deadline - d.testNowSec()) {
            logger.debug("tick " + i + ": " + before + " -> " + after + " for " + elapsed + " s");
            return false;
        }
    }
    var dropped = first - d.getSecondsUntilDeadline();
    if (dropped < 10 || dropped > 11) {
        logger.debug("10 ticks should drop the countdown by 10, dropped " + dropped);
        return false;
    }

    d.testAdvanceClock(20 * 60);
    if (d.getSecondsUntilDeadline() != 0) {
        logger.debug("countdown past the deadline should clamp to 0, got " + d.getSecondsUntilDeadline());
        return false;
    }
    return true;
}

//! The alarm reason stays ALARM_NONE through calibration, monitoring and sleep,
//! and a manual cancel is not an alarm either.
(:test)
function testTiming_alarmReasonNoneBeforeAlarm(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    if (d.getState() != SleepDetector.STATE_CALIBRATING || d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("fresh session: reason " + d.getAlarmReason());
        return false;
    }
    d.testRunSeconds(120, 70, 200.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("monitoring: state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }
    d.testForceSleep();
    d.testRunMinutes(3, 55, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING || d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("sleeping: state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }
    d.cancel();
    if (d.getState() != SleepDetector.STATE_SUMMARY || !d.isCancelled()
        || d.getAlarmReason() != SleepDetector.ALARM_NONE || d.testIsRunning()) {
        logger.debug("cancel: state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }
    return true;
}

// ── Smart wake window ───────────────────────────────────────────────────────

//! Window length is 20 % of the nap capped at 300 s, and 0 below 15 min.
(:test)
function testTiming_smartWakeWindowSizes(logger as Test.Logger) as Boolean {
    var cases = [
        [5, 0], [10, 0], [14, 0], [15, 180], [20, 240], [25, 300], [30, 300], [120, 300]
    ] as Array<Array<Number>>;
    var d = new SleepDetector(null);
    for (var i = 0; i < cases.size(); i++) {
        var nap = cases[i][0];
        var expected = cases[i][1];
        d.testStart();
        d.testSetNapDurationMin(nap);
        var got = d.getSmartWakeWindowSec();
        if (got != expected) {
            logger.debug("nap " + nap + ": window " + got + ", expected " + expected);
            return false;
        }
    }
    return true;
}

//! isSmartWakeActive is false before onset and outside the window, and becomes
//! true exactly when the remaining time drops to the window length.
(:test)
function testTiming_smartWakeActiveOnlyInsideWindow(logger as Test.Logger) as Boolean {
    var awake = new SleepDetector(null);
    awake.testStart();
    awake.testSetNapDurationMin(30);
    awake.testSetBaseline(70.0f);
    if (awake.isSmartWakeActive()) {
        logger.debug("smart wake active before sleep onset");
        return false;
    }

    var d = timingSleepingDetector(30);
    var napEnd = d.testGetNapEndSec();
    var window = d.getSmartWakeWindowSec();
    if (window != 300 || d.isSmartWakeActive()) {
        logger.debug("30 min nap: window " + window + ", active at onset " + d.isSmartWakeActive());
        return false;
    }
    var activeTicks = 0;
    while (napEnd - d.testNowSec() > 200) {
        d.testFeedSecond(55, 10.0f);
        var rem = napEnd - d.testNowSec();
        var expected = (rem > 0) && (rem <= window);
        if (d.isSmartWakeActive() != expected) {
            logger.debug("remaining " + rem + ": active " + d.isSmartWakeActive() + ", expected " + expected);
            return false;
        }
        if (d.isSmartWakeActive()) {
            activeTicks += 1;
        }
    }
    if (d.getState() != SleepDetector.STATE_SLEEPING || !d.isSmartWakeActive()) {
        logger.debug("expected SLEEPING inside the window, state " + d.getState());
        return false;
    }
    if (activeTicks < 99 || activeTicks > 101) {
        logger.debug("expected ~100 active ticks between 300 s and 200 s remaining, got " + activeTicks);
        return false;
    }
    return true;
}

//! Six active seconds in a minute inside the window (a minute the onset logic
//! would not call still) fire ALARM_SMART_WAKE at the minute boundary, well
//! before the planned end.
(:test)
function testTiming_stirInsideWindowFiresSmartWake(logger as Test.Logger) as Boolean {
    var d = timingSleepingDetector(30);
    var napEnd = d.testGetNapEndSec();
    d.testRunSeconds(1500, 55, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING || !d.isSmartWakeActive()) {
        logger.debug("expected SLEEPING inside the window, state " + d.getState());
        return false;
    }

    d.testRunSeconds(54, 55, 10.0f);
    d.testRunSeconds(5, 55, 100.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("stir must only be evaluated at the minute boundary, state " + d.getState());
        return false;
    }
    d.testFeedSecond(55, 100.0f);

    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_SMART_WAKE) {
        logger.debug("expected ALARM_SMART_WAKE, state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }
    if (napEnd - d.testNowSec() != 240) {
        logger.debug("smart wake should fire at the first stir minute (240 s left), got " + (napEnd - d.testNowSec()));
        return false;
    }
    if (d.testGetMinuteActiveSec() != 6) {
        logger.debug("minute active seconds " + d.testGetMinuteActiveSec() + ", expected 6");
        return false;
    }
    var mean = d.testGetMinuteMotionMean();
    if (mean < 18.9f || mean > 19.1f) {
        logger.debug("minute mean " + mean + " should be 19.0 (below the 75 mg mean rule)");
        return false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("smart wake must not count as a wake episode");
        return false;
    }
    return true;
}

//! Stir boundary: 5 active seconds is still a still minute and keeps sleeping
//! inside the window; 6 active seconds fires ALARM_SMART_WAKE.
(:test)
function testTiming_stirBoundaryFiveVsSixActiveSeconds(logger as Test.Logger) as Boolean {
    var d = timingSleepingDetector(30);
    d.testRunSeconds(1500, 55, 10.0f);
    d.testRunSeconds(55, 55, 10.0f);
    d.testRunSeconds(5, 55, 100.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING || d.testGetMinuteActiveSec() != 5) {
        logger.debug("5 active seconds must keep sleeping, state " + d.getState()
            + " active " + d.testGetMinuteActiveSec());
        return false;
    }
    d.testRunSeconds(54, 55, 10.0f);
    d.testRunSeconds(6, 55, 100.0f);
    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_SMART_WAKE) {
        logger.debug("6 active seconds must fire SMART_WAKE, state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }
    return true;
}

//! The same stir outside the window is neither a smart wake nor a wake
//! episode; the nap continues to its planned end.
(:test)
function testTiming_stirOutsideWindowIsIgnored(logger as Test.Logger) as Boolean {
    var d = timingSleepingDetector(30);
    var napEnd = d.testGetNapEndSec();
    d.testRunSeconds(600, 55, 10.0f);
    if (d.isSmartWakeActive()) {
        logger.debug("window active with ~20 min remaining");
        return false;
    }

    for (var i = 0; i < 3; i++) {
        timingFeedStirMinute(d, 55);
        if (d.getState() != SleepDetector.STATE_SLEEPING) {
            logger.debug("stir minute " + i + " changed state to " + d.getState());
            return false;
        }
        if (d.getAlarmReason() != SleepDetector.ALARM_NONE || d.getWakeEpisodes() != 0) {
            logger.debug("stir minute " + i + ": reason " + d.getAlarmReason()
                + " wakes " + d.getWakeEpisodes());
            return false;
        }
        if (d.testGetMinuteActiveSec() != 6) {
            logger.debug("stir minute " + i + ": active seconds " + d.testGetMinuteActiveSec());
            return false;
        }
    }

    if (!timingRunToAlarm(d, napEnd, 55, 10.0f, SleepDetector.STATE_SLEEPING, logger)) {
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("expected NAP_COMPLETE, got " + d.getAlarmReason());
        return false;
    }
    return true;
}

//! A minute whose mean HR is 5 BPM above the sleep-phase mean inside the
//! window fires ALARM_SMART_WAKE without any motion.
(:test)
function testTiming_hrRiseInsideWindowFiresSmartWake(logger as Test.Logger) as Boolean {
    var d = timingSleepingDetector(30);
    var napEnd = d.testGetNapEndSec();
    d.testRunSeconds(1500, 55, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING || !d.isSmartWakeActive()) {
        logger.debug("expected SLEEPING inside the window, state " + d.getState());
        return false;
    }

    d.testRunSeconds(59, 60, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("HR rise must only be evaluated at the minute boundary");
        return false;
    }
    d.testFeedSecond(60, 10.0f);

    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_SMART_WAKE) {
        logger.debug("expected ALARM_SMART_WAKE, state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }
    var rem = napEnd - d.testNowSec();
    if (rem <= 180 || rem > 240) {
        logger.debug("smart wake should fire at the first HR-rise minute, remaining " + rem);
        return false;
    }
    if (d.testGetMinuteActiveSec() != 0) {
        logger.debug("motion contributed to the wake: active seconds " + d.testGetMinuteActiveSec());
        return false;
    }
    return true;
}

//! An HR rise of only 4 BPM inside the window is not a light-sleep signal: the
//! nap keeps sleeping and ends with ALARM_NAP_COMPLETE.
(:test)
function testTiming_hrRiseBelowThresholdInsideWindowKeepsSleeping(logger as Test.Logger) as Boolean {
    var d = timingSleepingDetector(30);
    var napEnd = d.testGetNapEndSec();
    d.testRunSeconds(1500, 55, 10.0f);
    if (!d.isSmartWakeActive()) {
        logger.debug("expected the window to be active");
        return false;
    }

    d.testRunMinutes(1, 59, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING || d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("4 BPM rise fired: state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }

    if (!timingRunToAlarm(d, napEnd, 55, 10.0f, SleepDetector.STATE_SLEEPING, logger)) {
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("expected NAP_COMPLETE, got " + d.getAlarmReason());
        return false;
    }
    return true;
}

//! A 10 min nap has no window: stirring plus a 5 BPM HR rise in its last three
//! minutes never smart-wakes, and the nap ends with ALARM_NAP_COMPLETE.
(:test)
function testTiming_tenMinuteNapNeverSmartWakes(logger as Test.Logger) as Boolean {
    var d = timingSleepingDetector(10);
    var napEnd = d.testGetNapEndSec();
    if (d.getSmartWakeWindowSec() != 0) {
        logger.debug("10 min nap should have no window, got " + d.getSmartWakeWindowSec());
        return false;
    }
    d.testRunSeconds(420, 55, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING || d.isSmartWakeActive()) {
        logger.debug("window active for a 10 min nap, state " + d.getState());
        return false;
    }

    // Minutes 8 and 9: stir + HR rise, both smart-wake signals in a longer nap.
    for (var i = 0; i < 2; i++) {
        timingFeedStirMinute(d, 60);
        if (d.getState() != SleepDetector.STATE_SLEEPING || d.getAlarmReason() != SleepDetector.ALARM_NONE
            || d.isSmartWakeActive()) {
            logger.debug("stir minute " + i + " fired: state " + d.getState() + " reason " + d.getAlarmReason());
            return false;
        }
    }
    // Minute 10 reaches the planned end.
    timingFeedStirMinute(d, 60);
    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("expected NAP_COMPLETE, state " + d.getState() + " reason " + d.getAlarmReason());
        return false;
    }
    if (d.testNowSec() < napEnd) {
        logger.debug("alarm fired before the planned end");
        return false;
    }
    return true;
}

// ── AlarmManager wiring ─────────────────────────────────────────────────────

//! An AlarmManager given to the detector is started (ring 0, phase 0) by the
//! nap-complete alarm and idle before it.
(:test)
function testTiming_alarmManagerStartsOnNapComplete(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    var d = new SleepDetector(a);
    d.testStart();
    d.testSetNapDurationMin(5);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    var napEnd = d.testGetNapEndSec();

    var ok = !a.isAlarming();
    if (!ok) {
        logger.debug("alarm manager alarming before the alarm");
    }
    if (ok) {
        ok = timingRunToAlarm(d, napEnd, 55, 10.0f, SleepDetector.STATE_SLEEPING, logger);
    }
    if (ok && !a.isAlarming()) {
        logger.debug("alarm manager not alarming after ALARM_NAP_COMPLETE");
        ok = false;
    }
    if (ok && (a.testGetRingCount() != 1 || a.getCurrentPhase() != 0)) {
        logger.debug("expected ring 0 fired, phase 0: rings " + a.testGetRingCount()
            + " phase " + a.getCurrentPhase());
        ok = false;
    }
    a.stop();
    if (ok && a.isAlarming()) {
        logger.debug("alarm manager still alarming after stop()");
        ok = false;
    }
    return ok;
}

//! The deadline alarm also starts the AlarmManager.
(:test)
function testTiming_alarmManagerStartsOnDeadline(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    var d = new SleepDetector(a);
    d.testStart();
    d.testSetNapDurationMin(5);
    d.testSetBaseline(70.0f);
    var deadline = d.testGetDeadlineSec();

    var ok = timingRunToAlarm(d, deadline, 70, 200.0f, SleepDetector.STATE_MONITORING, logger);
    if (ok && d.getAlarmReason() != SleepDetector.ALARM_DEADLINE) {
        logger.debug("expected ALARM_DEADLINE, got " + d.getAlarmReason());
        ok = false;
    }
    if (ok && !a.isAlarming()) {
        logger.debug("alarm manager not alarming after ALARM_DEADLINE");
        ok = false;
    }
    a.stop();
    return ok;
}

// ── The user's example ──────────────────────────────────────────────────────

//! 15 min nap started at 9:00 with the default 15 min "max time to fall
//! asleep". At the start nothing is fixed at 9:15: the screen promises
//! "Latest alarm 9:30" (start + 15 + 15). Moving until 9:05, then still: the
//! watch decides "asleep" at 9:10 and the alarm moves to 9:10 + 15 = 9:25.
//! Asleep only at 9:20 would be capped at 9:30 (a 10 min nap); never asleep
//! rings at 9:30.
(:test)
function testTiming_fallingAsleepLateMovesTheAlarm(logger as Test.Logger) as Boolean {
    var ok = true;

    // Asleep at 9:10 -> alarm 9:25.
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(15);
    var start = d.testGetStartSec();
    if (d.getFallAsleepSec() != -1) {
        logger.debug("no fall-asleep time before onset");
        ok = false;
    }
    if (d.testGetDeadlineSec() != start + 30 * 60) {
        logger.debug("the promise at 9:00 must be 9:30");
        ok = false;
    }
    d.testRunMinutes(5, 72, 200.0f);             // 9:00-9:05 moving
    d.testRunMinutes(5, 70, 10.0f);              // 9:05-9:10 still -> asleep at 9:10
    var onset = d.testGetSleepStartSec();
    if (d.getFallAsleepSec() != 10 * 60) {
        logger.debug("the summary must say: fell asleep in 10 min, got " + d.getFallAsleepSec() + " s");
        ok = false;
    }
    if (onset == null || (onset as Number) != start + 10 * 60 || d.testGetNapEndSec() != start + 25 * 60) {
        logger.debug("asleep at 9:10 must move the alarm to 9:25, onset "
            + ((onset != null) ? ((onset as Number) - start) / 60 : -1) + " min, alarm "
            + (d.testGetNapEndSec() - start) / 60 + " min");
        ok = false;
    }
    ok = timingRunToAlarm(d, start + 25 * 60, 60, 10.0f, SleepDetector.STATE_SLEEPING, logger) && ok;
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("9:25 alarm reason " + d.getAlarmReason());
        ok = false;
    }

    // Asleep at 9:20 -> capped at 9:30.
    d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(15);
    start = d.testGetStartSec();
    d.testRunMinutes(15, 72, 200.0f);            // 9:00-9:15 moving
    d.testRunMinutes(5, 70, 10.0f);              // 9:15-9:20 still -> asleep at 9:20
    if (d.testGetNapEndSec() != start + 30 * 60) {
        logger.debug("asleep at 9:20 must be capped at 9:30, alarm " + (d.testGetNapEndSec() - start) / 60 + " min");
        ok = false;
    }

    // Never asleep -> 9:30.
    d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(15);
    start = d.testGetStartSec();
    ok = timingRunToAlarm(d, start + 30 * 60, 72, 200.0f, -1, logger) && ok;
    if (d.getAlarmReason() != SleepDetector.ALARM_DEADLINE) {
        logger.debug("never asleep must ring at 9:30 (deadline), reason " + d.getAlarmReason());
        ok = false;
    }
    return ok;
}
