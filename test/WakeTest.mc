import Toybox.Test;
import Toybox.Lang;

// -----------------------------------------------------------------------------
// Wake episodes and sleep re-entry (SleepDetector)
//
// Every test starts from a detector that is already asleep:
//   testStart(); testSetNapDurationMin(n); testSetBaseline(70.0f); testForceSleep();
// so the onset is at t0 with no back-date and plannedEnd = t0 + nap.
// The minute logic runs on the 60th tick; the alarm-due check runs on every
// tick. testStart() freezes the detector clock, so all values are exact.
//
// Segment model (source of the actual-sleep numbers below): a sleep segment
// closes at the START of the minute that triggers the wake episode (that
// minute counts as awake), and a re-entry back-dates the new segment by the
// two still minutes it needed. Every re-entry also restarts the sleep-phase
// HR mean.
// -----------------------------------------------------------------------------

//! Fresh detector already in STATE_SLEEPING: HR baseline 70 BPM, given nap
//! duration, onset forced at "now" (no back-date).
(:debug)
function wakeHelperAsleep(napMin as Number) as SleepDetector {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(napMin);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    return d;
}

//! 15 active seconds at 300 mg (mean only 82.5 mg) -> wake episode: MONITORING, 1 episode, planned end unchanged, countdown keeps decreasing.
(:test)
function testWake_activeSecondsTriggerWakeEpisode(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    var napEndBefore = d.testGetNapEndSec();
    d.testRunSeconds(15, 60, 300.0f);
    d.testRunSeconds(45, 60, 10.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING after wake minute, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("expected 1 wake episode, got " + d.getWakeEpisodes());
        ok = false;
    }
    if (!d.hasSleptAtLeastOnce()) {
        logger.debug("hasSleptAtLeastOnce must stay true after a wake");
        ok = false;
    }
    if (d.testGetNapEndSec() != napEndBefore) {
        logger.debug("planned end moved: " + napEndBefore + " -> " + d.testGetNapEndSec());
        ok = false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("alarm reason should be NONE, got " + d.getAlarmReason());
        ok = false;
    }
    if (d.testGetMinuteActiveSec() != 15) {
        logger.debug("expected 15 active seconds, got " + d.testGetMinuteActiveSec());
        ok = false;
    }
    var mean = d.testGetMinuteMotionMean();
    if (mean < 82.0f || mean > 83.0f) {
        logger.debug("minute mean expected ~82.5 (below the 100 mean rule), got " + mean);
        ok = false;
    }

    // Countdown keeps running while awake.
    var r1 = d.getRemainingSeconds();
    d.testRunSeconds(10, 60, 300.0f);
    var r2 = d.getRemainingSeconds();
    if (r1 <= 0 || r2 >= r1 || (r1 - r2) < 10 || (r1 - r2) > 12) {
        logger.debug("remaining should drop by ~10 s while awake: " + r1 + " -> " + r2);
        ok = false;
    }
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected to stay MONITORING mid-minute, got " + d.getState());
        ok = false;
    }
    return ok;
}

//! A whole minute at 120 mg (mean > 100, 60 active seconds) -> wake episode.
(:test)
function testWake_highMeanMotionMinuteTriggersWakeEpisode(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunMinutes(1, 60, 120.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("expected 1 wake episode, got " + d.getWakeEpisodes());
        ok = false;
    }
    var mean = d.testGetMinuteMotionMean();
    if (mean < 119.5f || mean > 120.5f) {
        logger.debug("minute mean expected ~120, got " + mean);
        ok = false;
    }
    if (d.testGetMinuteActiveSec() != 60) {
        logger.debug("expected 60 active seconds, got " + d.testGetMinuteActiveSec());
        ok = false;
    }
    return ok;
}

//! A 5-second roll-over at 500 mg in an otherwise quiet minute is not a wake (5 active s, mean ~51).
(:test)
function testWake_shortRollOverStaysAsleep(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunSeconds(5, 60, 500.0f);
    d.testRunSeconds(55, 60, 10.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after a short roll-over, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("expected 0 wake episodes, got " + d.getWakeEpisodes());
        ok = false;
    }
    if (d.testGetMinuteActiveSec() != 5) {
        logger.debug("expected 5 active seconds, got " + d.testGetMinuteActiveSec());
        ok = false;
    }
    var mean = d.testGetMinuteMotionMean();
    if (mean < 50.0f || mean > 52.0f) {
        logger.debug("minute mean expected ~50.8, got " + mean);
        ok = false;
    }
    return ok;
}

//! 9 active seconds at 60 mg keep the user asleep; the 10th active second in the next minute wakes.
(:test)
function testWake_activeSecondsBoundaryNineVsTen(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunSeconds(9, 60, 60.0f);
    d.testRunSeconds(51, 60, 10.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("9 active seconds: expected SLEEPING, got " + d.getState());
        ok = false;
    }
    if (d.testGetMinuteActiveSec() != 9) {
        logger.debug("expected 9 active seconds, got " + d.testGetMinuteActiveSec());
        ok = false;
    }
    var mean = d.testGetMinuteMotionMean();
    if (mean > 100.0f) {
        logger.debug("minute mean should be far below 100, got " + mean);
        ok = false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("expected 0 wake episodes after 9 active s, got " + d.getWakeEpisodes());
        ok = false;
    }

    d.testRunSeconds(10, 60, 60.0f);
    d.testRunSeconds(50, 60, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("10 active seconds: expected MONITORING, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("expected 1 wake episode after 10 active s, got " + d.getWakeEpisodes());
        ok = false;
    }
    return ok;
}

//! One minute with HR 15 BPM above the sleep mean (3 x 55 then 70) does not wake by itself.
(:test)
function testWake_singleHrRiseMinuteStaysAsleep(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunMinutes(3, 55, 10.0f);
    d.testRunMinutes(1, 70, 10.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after one HR-rise minute, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("expected 0 wake episodes, got " + d.getWakeEpisodes());
        ok = false;
    }
    return ok;
}

//! Two consecutive minutes with HR >= 10 above the sleep mean (3 x 55, then 70, 70) -> wake episode, still-minute counter reset.
(:test)
function testWake_twoConsecutiveHrRiseMinutesWake(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    var napEndBefore = d.testGetNapEndSec();
    d.testRunMinutes(3, 55, 10.0f);
    d.testRunMinutes(1, 70, 10.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("first rise minute: expected SLEEPING, got " + d.getState());
        ok = false;
    }

    // The elevated minute is NOT folded into the sleep mean: it stays 55.
    d.testRunMinutes(1, 70, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("second rise minute: expected MONITORING, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("expected 1 wake episode, got " + d.getWakeEpisodes());
        ok = false;
    }
    if (d.getStillMinutes() != 0) {
        logger.debug("still minutes must restart at 0 after a wake, got " + d.getStillMinutes());
        ok = false;
    }
    if (d.testGetNapEndSec() != napEndBefore) {
        logger.debug("planned end moved on HR wake");
        ok = false;
    }
    if (!d.hasSleptAtLeastOnce()) {
        logger.debug("hasSleptAtLeastOnce must stay true");
        ok = false;
    }
    return ok;
}

//! An HR rise of 9 BPM (3 x 55 then ten minutes at 64) never wakes, however long it lasts.
(:test)
function testWake_hrRiseBelowTenNeverWakes(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunMinutes(3, 55, 10.0f);
    d.testRunMinutes(10, 64, 10.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING with a 9 BPM rise, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("expected 0 wake episodes, got " + d.getWakeEpisodes());
        ok = false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("no alarm expected, got reason " + d.getAlarmReason());
        ok = false;
    }
    return ok;
}

//! A quiet-HR minute between two rise minutes (55,55,55,70,55,70) resets the consecutive counter: no wake.
(:test)
function testWake_hrRiseCounterResetsOnQuietMinute(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunMinutes(3, 55, 10.0f);
    d.testRunMinutes(1, 70, 10.0f);
    d.testRunMinutes(1, 55, 10.0f);
    d.testRunMinutes(1, 70, 10.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING (non-consecutive rise minutes), got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("expected 0 wake episodes, got " + d.getWakeEpisodes());
        ok = false;
    }
    return ok;
}

//! The HR-rise wake needs at least two prior sleeping minutes with HR: 1 x 55 then 3 x 70 never wakes.
(:test)
function testWake_hrRiseNeedsTwoPriorSleepMinutes(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunMinutes(1, 55, 10.0f);
    d.testRunMinutes(3, 70, 10.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING without an established sleep HR mean, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("expected 0 wake episodes, got " + d.getWakeEpisodes());
        ok = false;
    }
    return ok;
}

//! After a wake, two still minutes with HIGH HR (80 > baseline 70, no drop) re-enter SLEEPING; episodes stay 1, planned end unchanged.
(:test)
function testWake_reentryAfterTwoStillMinutesWithoutHrDrop(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    var napEndBefore = d.testGetNapEndSec();
    d.testRunMinutes(3, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getWakeEpisodes() != 1) {
        logger.debug("setup: expected MONITORING with 1 episode, got state " + d.getState()
            + " episodes " + d.getWakeEpisodes());
        ok = false;
    }

    d.testRunMinutes(2, 80, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after 2 still minutes (no HR condition), got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("re-entry must not change wake episodes, got " + d.getWakeEpisodes());
        ok = false;
    }
    if (d.testGetNapEndSec() != napEndBefore) {
        logger.debug("re-entry must not move the planned end");
        ok = false;
    }
    if (d.getPlannedEndTime() == null || d.getSleepStartTime() == null) {
        logger.debug("planned end / sleep start must stay set after re-entry");
        ok = false;
    }
    return ok;
}

//! Re-entry needs two CONSECUTIVE still minutes: an active minute in between resets progress (and is not a new episode).
(:test)
function testWake_reentryRequiresConsecutiveStillMinutes(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunMinutes(2, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("setup: expected MONITORING, got " + d.getState());
        ok = false;
    }
    if (d.getOnsetProgressPct() != 0) {
        logger.debug("onset progress right after a wake should be 0, got " + d.getOnsetProgressPct());
        ok = false;
    }

    d.testRunMinutes(1, 80, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getStillMinutes() != 1) {
        logger.debug("after 1 still minute: expected MONITORING/still=1, got state " + d.getState()
            + " still " + d.getStillMinutes());
        ok = false;
    }
    if (d.getOnsetProgressPct() != 50) {
        logger.debug("onset progress after 1 of 2 still minutes should be 50, got " + d.getOnsetProgressPct());
        ok = false;
    }

    d.testRunMinutes(1, 80, 300.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getStillMinutes() != 0) {
        logger.debug("active minute should reset stillness: state " + d.getState()
            + " still " + d.getStillMinutes());
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("an active minute while already awake is not a new episode, got " + d.getWakeEpisodes());
        ok = false;
    }

    d.testRunMinutes(1, 80, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("one still minute after the reset is not enough, got " + d.getState());
        ok = false;
    }
    d.testRunMinutes(1, 80, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("second consecutive still minute should re-enter sleep, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("expected wake episodes to stay 1, got " + d.getWakeEpisodes());
        ok = false;
    }
    return ok;
}

//! Actual sleep freezes while awake and resumes back-dated on re-entry: 5 sleep + 1 wake + 2 active + 2 still -> 420 s of 600 (70 %).
(:test)
function testWake_actualSleepFreezesWhileAwake(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    var ok = true;

    d.testRunMinutes(5, 55, 10.0f);
    var a1 = d.getActualNapDurationSec();
    if (a1 != 300) {
        logger.debug("after 5 sleeping minutes expected ~300 s, got " + a1);
        ok = false;
    }

    // Wake minute: the open segment closes at the START of this minute,
    // so the minute that showed the motion counts as awake.
    d.testRunMinutes(1, 60, 300.0f);
    var a2 = d.getActualNapDurationSec();
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING after wake minute, got " + d.getState());
        ok = false;
    }
    if (a2 != 300) {
        logger.debug("after the wake minute expected ~300 s, got " + a2);
        ok = false;
    }

    // Two more active minutes: nothing accrues.
    d.testRunMinutes(2, 60, 300.0f);
    var a3 = d.getActualNapDurationSec();
    if (a3 != a2) {
        logger.debug("actual sleep must freeze while awake: " + a2 + " -> " + a3);
        ok = false;
    }

    // Two still minutes: re-entry, segment back-dated by those 120 s.
    d.testRunMinutes(2, 60, 10.0f);
    var a4 = d.getActualNapDurationSec();
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after re-entry, got " + d.getState());
        ok = false;
    }
    if (a4 != 420) {
        logger.debug("after re-entry expected ~420 s (300 + back-dated 120), got " + a4);
        ok = false;
    }
    var eff = d.getSleepEfficiencyPct();
    if (eff != 70) {
        logger.debug("efficiency expected ~70 (420 of 600 s), got " + eff);
        ok = false;
    }
    return ok;
}

//! While awake after a wake episode, efficiency falls below 100 and completion keeps rising (10-min nap: 2 sleep, 1 wake, 2 active -> 120 s asleep, 40 % / 50 %).
(:test)
function testWake_efficiencyBelowHundredWhileAwake(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(10);
    d.testRunMinutes(2, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);
    d.testRunMinutes(2, 60, 300.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING, got " + d.getState());
        ok = false;
    }
    var actual = d.getActualNapDurationSec();
    if (actual < 120 || actual > 123) {
        logger.debug("actual sleep expected ~120 s (wake minute is awake), got " + actual);
        ok = false;
    }
    var eff = d.getSleepEfficiencyPct();
    if (eff < 38 || eff > 42) {
        logger.debug("efficiency expected ~40 (120 of 300 s), got " + eff);
        ok = false;
    }
    var comp = d.getPlannedCompletionPct();
    if (comp < 48 || comp > 52) {
        logger.debug("completion expected ~50 (300 of 600 s), got " + comp);
        ok = false;
    }
    return ok;
}

//! The nap-complete alarm fires from MONITORING-after-wake at the planned end even if the user never re-sleeps (10-min nap, wake at minute 3, motion 300 until the alarm).
(:test)
function testWake_alarmFiresFromMonitoringAfterWake(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(10);
    var napEnd = d.testGetNapEndSec();
    d.testRunMinutes(2, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);

    var ok = true;
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getWakeEpisodes() != 1) {
        logger.debug("setup: expected MONITORING with 1 episode, got state " + d.getState()
            + " episodes " + d.getWakeEpisodes());
        ok = false;
    }

    var fed = 0;
    while (fed < 700 && d.getState() == SleepDetector.STATE_MONITORING) {
        d.testFeedSecond(60, 300.0f);
        fed += 1;
    }

    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("expected ALARM, got " + d.getState() + " after " + fed + " s");
        ok = false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("expected ALARM_NAP_COMPLETE, got " + d.getAlarmReason());
        ok = false;
    }
    var now = d.testNowSec();
    if (now < napEnd || now > napEnd + 2) {
        logger.debug("alarm should fire at the planned end: now " + now + " end " + napEnd);
        ok = false;
    }
    // 420 s remain after the wake minute; allow a real second ticking over.
    if (fed < 415 || fed > 421) {
        logger.debug("expected ~420 fed seconds until the alarm, got " + fed);
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("moving while awake must not add episodes, got " + d.getWakeEpisodes());
        ok = false;
    }
    if (d.isCancelled()) {
        logger.debug("alarm is not a cancel");
        ok = false;
    }
    if (d.getNapEndTime() == null) {
        logger.debug("nap end time should be set once the alarm fired");
        ok = false;
    }
    return ok;
}

//! After the alarm of a nap with a wake and no re-sleep: completion 100, efficiency 20 (120 of 600 s), actual sleep frozen at 120 s.
(:test)
function testWake_completionFullEfficiencyPartialAfterAlarm(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(10);
    d.testRunMinutes(2, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);
    var fed = 0;
    while (fed < 700 && d.getState() == SleepDetector.STATE_MONITORING) {
        d.testFeedSecond(60, 300.0f);
        fed += 1;
    }

    var ok = true;
    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("setup: expected ALARM, got " + d.getState());
        ok = false;
    }
    if (d.getPlannedCompletionPct() != 100) {
        logger.debug("completion expected 100 after an on-time alarm, got " + d.getPlannedCompletionPct());
        ok = false;
    }
    var eff = d.getSleepEfficiencyPct();
    if (eff < 18 || eff > 22) {
        logger.debug("efficiency expected ~20 (120 of 600 s), got " + eff);
        ok = false;
    }
    var actual = d.getActualNapDurationSec();
    if (actual < 120 || actual > 123) {
        logger.debug("actual sleep expected ~120 s, got " + actual);
        ok = false;
    }
    return ok;
}

//! Three wake/re-sleep cycles in a 30-min nap end with ALARM_NAP_COMPLETE, wakeEpisodes 3, completion 100.
(:test)
function testWake_threeCyclesEndInNapComplete(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    var napEnd = d.testGetNapEndSec();
    var ok = true;

    for (var c = 1; c <= 3; c++) {
        d.testRunMinutes(3, 55, 10.0f);
        d.testRunMinutes(1, 60, 300.0f);
        if (d.getState() != SleepDetector.STATE_MONITORING || d.getWakeEpisodes() != c) {
            logger.debug("cycle " + c + ": expected MONITORING with " + c + " episodes, got state "
                + d.getState() + " episodes " + d.getWakeEpisodes());
            ok = false;
        }
        d.testRunMinutes(2, 55, 10.0f);
        if (d.getState() != SleepDetector.STATE_SLEEPING) {
            logger.debug("cycle " + c + ": expected SLEEPING after re-entry, got " + d.getState());
            ok = false;
        }
    }
    if (d.testGetNapEndSec() != napEnd) {
        logger.debug("planned end must survive all cycles");
        ok = false;
    }

    // 18 minutes elapsed; sleep quietly through the rest (incl. the smart window).
    var fed = 0;
    while (fed < 800 && d.getState() == SleepDetector.STATE_SLEEPING) {
        d.testFeedSecond(55, 10.0f);
        fed += 1;
    }

    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("expected ALARM, got " + d.getState() + " after " + fed + " s");
        ok = false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("expected ALARM_NAP_COMPLETE, got " + d.getAlarmReason());
        ok = false;
    }
    if (d.getWakeEpisodes() != 3) {
        logger.debug("expected 3 wake episodes, got " + d.getWakeEpisodes());
        ok = false;
    }
    var now = d.testNowSec();
    if (now < napEnd || now > napEnd + 2) {
        logger.debug("alarm should fire at the planned end: now " + now + " end " + napEnd);
        ok = false;
    }
    if (d.getPlannedCompletionPct() != 100) {
        logger.debug("completion expected 100, got " + d.getPlannedCompletionPct());
        ok = false;
    }
    // Each wake minute counts as awake and the re-entry is back-dated by the
    // two still minutes, so every cycle costs exactly 60 s: 1800 - 180 = 1620.
    var actual = d.getActualNapDurationSec();
    if (actual != 1620) {
        logger.debug("actual sleep expected ~1620 s (three 1-minute wakes), got " + actual);
        ok = false;
    }
    var eff = d.getSleepEfficiencyPct();
    if (eff != 90) {
        logger.debug("efficiency expected ~90, got " + eff);
        ok = false;
    }
    return ok;
}

//! Inside the smart-wake window the same wake minute yields ALARM_SMART_WAKE, not a wake episode.
(:test)
function testWake_insideSmartWindowMotionIsSmartWake(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(30);
    d.testRunMinutes(2, 55, 10.0f);

    var ok = true;
    if (d.isSmartWakeActive()) {
        logger.debug("smart wake must be inactive with 28 min remaining");
        ok = false;
    }
    if (d.getSmartWakeWindowSec() != 300) {
        logger.debug("30-min nap window expected 300 s, got " + d.getSmartWakeWindowSec());
        ok = false;
    }

    // Jump to 300 s before the planned end (window = min(300, 1800/5)).
    d.testAdvanceClock(1380);
    if (!d.isSmartWakeActive()) {
        logger.debug("smart wake should be active with <= 300 s remaining, remaining " + d.getRemainingSeconds());
        ok = false;
    }

    d.testRunMinutes(1, 55, 300.0f);
    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("expected ALARM inside the window, got " + d.getState());
        ok = false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_SMART_WAKE) {
        logger.debug("expected ALARM_SMART_WAKE, got " + d.getAlarmReason());
        ok = false;
    }
    if (d.getWakeEpisodes() != 0) {
        logger.debug("a smart wake is not a wake episode, got " + d.getWakeEpisodes());
        ok = false;
    }
    var comp = d.getPlannedCompletionPct();
    if (comp < 85 || comp > 87) {
        logger.debug("completion expected ~86 (1560 of 1800 s), got " + comp);
        ok = false;
    }
    return ok;
}

//! cancel() while awake after a wake episode -> SUMMARY, cancelled, sleep stats frozen at the wake (2 sleep + 1 wake + 1 active: 120 s, 50 %).
(:test)
function testWake_cancelWhileAwakeKeepsFrozenStats(logger as Test.Logger) as Boolean {
    var d = wakeHelperAsleep(10);
    d.testRunMinutes(2, 55, 10.0f);
    d.testRunMinutes(1, 60, 300.0f);
    d.testRunMinutes(1, 60, 300.0f);
    d.cancel();

    var ok = true;
    if (d.getState() != SleepDetector.STATE_SUMMARY) {
        logger.debug("expected SUMMARY after cancel, got " + d.getState());
        ok = false;
    }
    if (!d.isCancelled()) {
        logger.debug("cancel from MONITORING must be flagged as cancelled");
        ok = false;
    }
    if (d.testIsRunning()) {
        logger.debug("session should be stopped after cancel");
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("expected 1 wake episode, got " + d.getWakeEpisodes());
        ok = false;
    }
    var actual = d.getActualNapDurationSec();
    if (actual < 120 || actual > 123) {
        logger.debug("actual sleep expected ~120 s, got " + actual);
        ok = false;
    }
    var eff = d.getSleepEfficiencyPct();
    if (eff < 48 || eff > 52) {
        logger.debug("efficiency expected ~50 (120 of 240 s), got " + eff);
        ok = false;
    }
    if (d.getNapEndTime() == null) {
        logger.debug("nap end time should be set after cancel");
        ok = false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("cancel sets no alarm reason, got " + d.getAlarmReason());
        ok = false;
    }
    return ok;
}
