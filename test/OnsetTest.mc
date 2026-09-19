import Toybox.Test;
import Toybox.Lang;
import Toybox.Time;

// -----------------------------------------------------------------------------
// OnsetTest.mc  - sleep onset and calibration
//
// Every test drives a detector with the fake clock (testStart) one second at
// a time. Motion values are millig: 10.0 = resting wrist, 300.0+ = clearly
// moving. Defaults: nap 30 min, HR drop threshold 5 BPM, motion threshold
// 50 millig, "still" minute = mean < threshold AND <= 5 active seconds.
// -----------------------------------------------------------------------------

//! Calibration holds for the first 120 fed seconds (still CALIBRATING at 60 s and 119 s) and hands over to MONITORING on the 120 s minute boundary.
(:test)
function testOnset_calibrationEndsAt120Seconds(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    if (d.getState() != SleepDetector.STATE_CALIBRATING) {
        logger.debug("expected CALIBRATING right after testStart, got " + d.getState());
        return false;
    }
    d.testRunSeconds(60, 70, 10.0f);
    if (d.getState() != SleepDetector.STATE_CALIBRATING) {
        logger.debug("expected CALIBRATING after 60 s (first minute boundary), got " + d.getState());
        return false;
    }
    d.testRunSeconds(59, 70, 10.0f);
    if (d.getState() != SleepDetector.STATE_CALIBRATING) {
        logger.debug("expected CALIBRATING after 119 s, got " + d.getState());
        return false;
    }
    d.testRunSeconds(1, 70, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING after 120 s, got " + d.getState());
        return false;
    }
    if (d.testGetMinutesCompleted() != 2) {
        logger.debug("expected 2 completed minutes at 120 s, got " + d.testGetMinutesCompleted());
        return false;
    }
    return true;
}

//! The HR baseline is 0 until calibration completes and then equals the mean of every HR reading fed during calibration (60 s @70 + 60 s @60 -> 65).
(:test)
function testOnset_baselineIsMeanOfCalibrationHR(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testRunSeconds(60, 70, 10.0f);
    if (d.getHRBaseline() != 0.0f) {
        logger.debug("baseline must stay 0 until calibration completes, got " + d.getHRBaseline());
        return false;
    }
    d.testRunSeconds(60, 60, 10.0f);
    var b = d.getHRBaseline();
    if ((b - 65.0f).abs() > 0.01f) {
        logger.debug("expected baseline 65.0, got " + b);
        return false;
    }
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING once the baseline is computed, got " + d.getState());
        return false;
    }
    return true;
}

//! With no HR during calibration the baseline is 0, the HR onset path stays disabled even when HR appears later, and onset needs 5 still minutes.
(:test)
function testOnset_noHrDisablesHrPathAndNeedsFiveStillMinutes(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testRunMinutes(2, 0, 10.0f);   // silent HR sensor, still wrist
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING after calibration, got " + d.getState());
        return false;
    }
    if (d.getHRBaseline() != 0.0f) {
        logger.debug("expected baseline 0 without HR, got " + d.getHRBaseline());
        return false;
    }
    // HR shows up now, absurdly low. With baseline 0 it must be ignored:
    // after minute 4 there are 4 still minutes and 2 HR minute means, yet no onset.
    d.testRunMinutes(2, 40, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("HR path must be disabled with baseline 0, got state " + d.getState());
        return false;
    }
    if (d.getStillMinutes() != 4) {
        logger.debug("expected 4 still minutes, got " + d.getStillMinutes());
        return false;
    }
    d.testRunMinutes(1, 40, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after 5 still minutes, got " + d.getState());
        return false;
    }
    return true;
}

//! Still minutes accumulated during calibration count: a user still from t=0 with no HR has 2 still minutes at 120 s and falls asleep exactly at the 300 s boundary.
(:test)
function testOnset_stillnessDuringCalibrationCounts(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testRunSeconds(120, 0, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING at 120 s, got " + d.getState());
        return false;
    }
    if (d.getStillMinutes() != 2) {
        logger.debug("expected 2 still minutes carried over from calibration, got " + d.getStillMinutes());
        return false;
    }
    d.testRunSeconds(179, 0, 10.0f);   // t = 299 s
    if (d.getState() != SleepDetector.STATE_MONITORING || d.hasSleptAtLeastOnce()) {
        logger.debug("expected MONITORING at 299 s, got " + d.getState());
        return false;
    }
    if (d.getStillMinutes() != 4) {
        logger.debug("expected 4 still minutes at 299 s, got " + d.getStillMinutes());
        return false;
    }
    d.testRunSeconds(1, 0, 10.0f);     // t = 300 s
    if (d.getState() != SleepDetector.STATE_SLEEPING || !d.hasSleptAtLeastOnce()) {
        logger.debug("expected SLEEPING at 300 s, got " + d.getState());
        return false;
    }
    if (d.getStillMinutes() != 5) {
        logger.debug("expected 5 still minutes at onset, got " + d.getStillMinutes());
        return false;
    }
    return true;
}

//! HR-drop path: baseline 70, HR 65 (drop == threshold 5) while still -> SLEEPING exactly at the second still minute (2 minute means available), not at 119 s.
(:test)
function testOnset_hrDropPathSleepsAfterExactlyTwoStillMinutes(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("testSetBaseline should skip calibration, got " + d.getState());
        return false;
    }
    d.testRunSeconds(60, 65, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("one still minute with one HR mean must not trigger onset, got " + d.getState());
        return false;
    }
    if (d.getStillMinutes() != 1) {
        logger.debug("expected 1 still minute, got " + d.getStillMinutes());
        return false;
    }
    d.testRunSeconds(59, 65, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING at 119 s, got " + d.getState());
        return false;
    }
    d.testRunSeconds(1, 65, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING at 120 s via HR drop, got " + d.getState());
        return false;
    }
    if (d.getStillMinutes() != 2 || !d.hasSleptAtLeastOnce()) {
        logger.debug("expected 2 still minutes and hasSleptAtLeastOnce at onset");
        return false;
    }
    return true;
}

//! A 4 BPM drop (HR 66 vs baseline 70, threshold 5) does not qualify: onset waits for the 5th still minute.
(:test)
function testOnset_insufficientHrDropFallsBackToFiveStillMinutes(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    for (var m = 1; m <= 4; m++) {
        d.testRunMinutes(1, 66, 10.0f);
        if (d.getState() != SleepDetector.STATE_MONITORING) {
            logger.debug("drop of 4 BPM must not accelerate onset; got state " + d.getState() + " after minute " + m);
            return false;
        }
    }
    d.testRunMinutes(1, 66, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after 5 still minutes, got " + d.getState());
        return false;
    }
    return true;
}

//! The HR drop comparison is inclusive: drop == threshold sleeps at 2 min, threshold + 1 does not, and lowering the threshold to 4 makes a 4 BPM drop count.
(:test)
function testOnset_hrDropThresholdBoundaryIsInclusive(logger as Test.Logger) as Boolean {
    var a = new SleepDetector(null);
    a.testStart();
    a.testSetBaseline(70.0f);
    a.testSetHrDropThreshold(5);
    a.testRunMinutes(2, 65, 10.0f);
    if (a.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("drop 5 with threshold 5 must count, got " + a.getState());
        return false;
    }

    var b = new SleepDetector(null);
    b.testStart();
    b.testSetBaseline(70.0f);
    b.testSetHrDropThreshold(6);
    b.testRunMinutes(2, 65, 10.0f);
    if (b.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("drop 5 with threshold 6 must not count, got " + b.getState());
        return false;
    }

    var c = new SleepDetector(null);
    c.testStart();
    c.testSetBaseline(70.0f);
    c.testSetHrDropThreshold(4);
    c.testRunMinutes(2, 66, 10.0f);
    if (c.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("drop 4 with threshold 4 must count, got " + c.getState());
        return false;
    }
    return true;
}

//! A restless minute (20 s @300 mg then 40 s @10 mg: mean ~106.7, 20 active s) resets the still-minute counter to 0 and the 5-minute count starts over.
(:test)
function testOnset_restlessMinuteResetsStillMinutes(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    d.testRunMinutes(2, 0, 10.0f);
    if (d.getStillMinutes() != 2) {
        logger.debug("expected 2 still minutes before the restless one, got " + d.getStillMinutes());
        return false;
    }
    d.testRunSeconds(20, 0, 300.0f);
    d.testRunSeconds(40, 0, 10.0f);
    if (d.getStillMinutes() != 0) {
        logger.debug("restless minute must reset still minutes to 0, got " + d.getStillMinutes());
        return false;
    }
    if ((d.testGetMinuteMotionMean() - 106.67f).abs() > 0.1f) {
        logger.debug("expected minute mean ~106.67, got " + d.testGetMinuteMotionMean());
        return false;
    }
    if (d.testGetMinuteActiveSec() != 20) {
        logger.debug("expected 20 active seconds, got " + d.testGetMinuteActiveSec());
        return false;
    }
    d.testRunMinutes(4, 0, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getStillMinutes() != 4) {
        logger.debug("expected MONITORING with 4 still minutes after the reset, got state "
            + d.getState() + " still " + d.getStillMinutes());
        return false;
    }
    d.testRunMinutes(1, 0, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING once 5 fresh still minutes accumulated, got " + d.getState());
        return false;
    }
    return true;
}

//! A 3-second roll-over at 500 mg inside an otherwise still minute (mean 34.5 < 50, 3 active s <= 5) keeps the minute still and does not reset the counter.
(:test)
function testOnset_shortRollOverDoesNotBreakStillness(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    d.testRunMinutes(1, 0, 10.0f);
    if (d.getStillMinutes() != 1) {
        logger.debug("expected 1 still minute, got " + d.getStillMinutes());
        return false;
    }
    d.testRunSeconds(3, 0, 500.0f);
    d.testRunSeconds(57, 0, 10.0f);
    if (d.getStillMinutes() != 2) {
        logger.debug("roll-over minute must still count as still, got " + d.getStillMinutes());
        return false;
    }
    if ((d.testGetMinuteMotionMean() - 34.5f).abs() > 0.01f) {
        logger.debug("expected minute mean 34.5, got " + d.testGetMinuteMotionMean());
        return false;
    }
    if (d.testGetMinuteActiveSec() != 3) {
        logger.debug("expected 3 active seconds, got " + d.testGetMinuteActiveSec());
        return false;
    }
    d.testRunMinutes(3, 0, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after 5 still minutes including the roll-over one, got " + d.getState());
        return false;
    }
    return true;
}

//! Active-second tolerance is exactly 5: a minute with 5 seconds above threshold stays still, 6 seconds break it even though the mean (15 mg) is far below threshold.
(:test)
function testOnset_activeSecondsBoundaryIsFive(logger as Test.Logger) as Boolean {
    var a = new SleepDetector(null);
    a.testStart();
    a.testSetBaseline(70.0f);
    a.testRunMinutes(1, 0, 10.0f);
    a.testRunSeconds(5, 0, 60.0f);
    a.testRunSeconds(55, 0, 10.0f);
    if (a.testGetMinuteActiveSec() != 5) {
        logger.debug("expected 5 active seconds, got " + a.testGetMinuteActiveSec());
        return false;
    }
    if (a.getStillMinutes() != 2) {
        logger.debug("5 active seconds must keep the minute still, got still minutes " + a.getStillMinutes());
        return false;
    }

    var b = new SleepDetector(null);
    b.testStart();
    b.testSetBaseline(70.0f);
    b.testRunMinutes(1, 0, 10.0f);
    b.testRunSeconds(6, 0, 60.0f);
    b.testRunSeconds(54, 0, 10.0f);
    if (b.testGetMinuteActiveSec() != 6) {
        logger.debug("expected 6 active seconds, got " + b.testGetMinuteActiveSec());
        return false;
    }
    if ((b.testGetMinuteMotionMean() - 15.0f).abs() > 0.01f) {
        logger.debug("expected minute mean 15.0 (below threshold), got " + b.testGetMinuteMotionMean());
        return false;
    }
    if (b.getStillMinutes() != 0) {
        logger.debug("6 active seconds must break stillness, got still minutes " + b.getStillMinutes());
        return false;
    }
    return true;
}

//! Constant motion just below the threshold (49.0 mg) is still: 0 active seconds, mean 49, and onset after 5 minutes.
(:test)
function testOnset_meanMotionJustBelowThresholdIsStill(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    d.testRunMinutes(1, 0, 49.0f);
    if ((d.testGetMinuteMotionMean() - 49.0f).abs() > 0.01f) {
        logger.debug("expected minute mean 49.0, got " + d.testGetMinuteMotionMean());
        return false;
    }
    if (d.testGetMinuteActiveSec() != 0) {
        logger.debug("49.0 is not above 50.0, expected 0 active seconds, got " + d.testGetMinuteActiveSec());
        return false;
    }
    if (d.getStillMinutes() != 1) {
        logger.debug("expected 1 still minute at 49 mg, got " + d.getStillMinutes());
        return false;
    }
    d.testRunMinutes(4, 0, 49.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after 5 minutes at 49 mg, got " + d.getState());
        return false;
    }
    return true;
}

//! Constant motion at (50.0) or above (51.0) the threshold is never still: 51 counts 60 active seconds; 50 has 0 active seconds but the mean is not strictly below the threshold.
(:test)
function testOnset_meanMotionAtOrAboveThresholdIsNotStill(logger as Test.Logger) as Boolean {
    var a = new SleepDetector(null);
    a.testStart();
    a.testSetBaseline(70.0f);
    a.testRunMinutes(1, 0, 51.0f);
    if (a.testGetMinuteActiveSec() != 60) {
        logger.debug("expected 60 active seconds at 51 mg, got " + a.testGetMinuteActiveSec());
        return false;
    }
    if (a.getStillMinutes() != 0) {
        logger.debug("51 mg must not be still, got still minutes " + a.getStillMinutes());
        return false;
    }
    a.testRunMinutes(4, 0, 51.0f);
    if (a.getState() != SleepDetector.STATE_MONITORING || a.hasSleptAtLeastOnce()) {
        logger.debug("expected no onset after 5 minutes at 51 mg, got " + a.getState());
        return false;
    }

    var b = new SleepDetector(null);
    b.testStart();
    b.testSetBaseline(70.0f);
    b.testRunMinutes(1, 0, 50.0f);
    if (b.testGetMinuteActiveSec() != 0) {
        logger.debug("50.0 is not above 50.0, expected 0 active seconds, got " + b.testGetMinuteActiveSec());
        return false;
    }
    if ((b.testGetMinuteMotionMean() - 50.0f).abs() > 0.01f) {
        logger.debug("expected minute mean 50.0, got " + b.testGetMinuteMotionMean());
        return false;
    }
    if (b.getStillMinutes() != 0) {
        logger.debug("mean == threshold must not be still (strict <), got still minutes " + b.getStillMinutes());
        return false;
    }
    return true;
}

//! testSetMotionThreshold changes the verdict: 49 mg is restless under a 30 mg threshold, 70 mg is still under an 80 mg threshold (and restless under the default 50).
(:test)
function testOnset_motionThresholdSettingChangesOutcome(logger as Test.Logger) as Boolean {
    var a = new SleepDetector(null);
    a.testStart();
    a.testSetBaseline(70.0f);
    a.testSetMotionThreshold(30.0f);
    a.testRunMinutes(1, 0, 49.0f);
    if (a.getStillMinutes() != 0 || a.testGetMinuteActiveSec() != 60) {
        logger.debug("49 mg under a 30 mg threshold must be restless; still " + a.getStillMinutes()
            + " active " + a.testGetMinuteActiveSec());
        return false;
    }

    var b = new SleepDetector(null);
    b.testStart();
    b.testSetBaseline(70.0f);
    b.testSetMotionThreshold(80.0f);
    b.testRunMinutes(1, 0, 70.0f);
    if (b.getStillMinutes() != 1 || b.testGetMinuteActiveSec() != 0) {
        logger.debug("70 mg under an 80 mg threshold must be still; still " + b.getStillMinutes()
            + " active " + b.testGetMinuteActiveSec());
        return false;
    }
    b.testRunMinutes(4, 0, 70.0f);
    if (b.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after 5 minutes at 70 mg with threshold 80, got " + b.getState());
        return false;
    }

    var c = new SleepDetector(null);
    c.testStart();
    c.testSetBaseline(70.0f);
    c.testRunMinutes(1, 0, 70.0f);
    if (c.getStillMinutes() != 0) {
        logger.debug("70 mg under the default 50 mg threshold must be restless, got still minutes " + c.getStillMinutes());
        return false;
    }
    return true;
}

//! The first onset is not back-dated: after 5 still minutes sleepStart == now,
//! plannedEnd == sleepStart + 30 min (well before the 45 min deadline), and the
//! full 30 minutes remain.
(:test)
function testOnset_firstOnsetIsNotBackdated(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    if (d.getSleepStartTime() != null || d.getPlannedEndTime() != null) {
        logger.debug("sleep start / planned end must be null before onset");
        return false;
    }
    d.testRunMinutes(5, 0, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after 5 still minutes, got " + d.getState());
        return false;
    }
    var m = d.getSleepStartTime();
    if (m == null) {
        logger.debug("getSleepStartTime() must not be null after onset");
        return false;
    }
    var sleepStart = (m as Time.Moment).value();
    var now = d.testNowSec();
    if (sleepStart != now) {
        logger.debug("expected sleepStart == now; sleepStart " + sleepStart + " now " + now);
        return false;
    }
    var napEnd = d.testGetNapEndSec();
    if (napEnd != sleepStart + 30 * 60) {
        logger.debug("expected napEnd == sleepStart + 1800; napEnd " + napEnd + " sleepStart " + sleepStart);
        return false;
    }
    var pe = d.getPlannedEndTime();
    if (pe == null || (pe as Time.Moment).value() != napEnd) {
        logger.debug("getPlannedEndTime() must equal the internal nap end");
        return false;
    }
    if (d.getRemainingSeconds() != 1800) {
        logger.debug("expected 1800 s remaining right after onset, got " + d.getRemainingSeconds());
        return false;
    }
    return true;
}

//! Onset via the HR path after exactly 2 still minutes starts at that moment
//! (start + 120 s), not at the session start.
(:test)
function testOnset_hrPathOnsetStartsAtDetection(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    d.testRunMinutes(2, 65, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after 2 still minutes with HR drop, got " + d.getState());
        return false;
    }
    var m = d.getSleepStartTime();
    if (m == null) {
        logger.debug("getSleepStartTime() must not be null after onset");
        return false;
    }
    var sleepStart = (m as Time.Moment).value();
    var start = d.testGetStartSec();
    if (sleepStart != start + 120) {
        logger.debug("expected sleepStart == start + 120, got offset " + (sleepStart - start));
        return false;
    }
    if (d.testGetNapEndSec() != sleepStart + 1800) {
        logger.debug("expected napEnd == sleepStart + 1800, got " + (d.testGetNapEndSec() - sleepStart));
        return false;
    }
    return true;
}

//! Ticks with no accelerometer data never count as still: calibration still completes, but even a strong HR drop cannot trigger onset without motion evidence.
(:test)
function testOnset_ticksWithoutMotionDataNeverYieldStillness(logger as Test.Logger) as Boolean {
    var a = new SleepDetector(null);
    a.testStart();
    for (var i = 0; i < 300; i++) {
        a.testTick();
    }
    if (a.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("calibration should complete on bare ticks, got " + a.getState());
        return false;
    }
    if (a.testGetMinutesCompleted() != 5 || a.getStillMinutes() != 0 || a.hasSleptAtLeastOnce()) {
        logger.debug("bare ticks must not produce stillness; minutes " + a.testGetMinutesCompleted()
            + " still " + a.getStillMinutes());
        return false;
    }

    var b = new SleepDetector(null);
    b.testStart();
    b.testSetBaseline(70.0f);
    for (var j = 0; j < 360; j++) {
        b.testFeedHR(65);
        b.testTick();
    }
    if (b.getState() != SleepDetector.STATE_MONITORING || b.hasSleptAtLeastOnce()) {
        logger.debug("HR drop without motion data must not trigger onset, got " + b.getState());
        return false;
    }
    if (b.getStillMinutes() != 0 || b.getOnsetProgressPct() != 0) {
        logger.debug("expected 0 still minutes and 0% progress; still " + b.getStillMinutes()
            + " pct " + b.getOnsetProgressPct());
        return false;
    }
    return true;
}

//! Without an HR drop, onset progress climbs 0 -> 20 -> 40 -> 60 -> 80 per still minute and reads 100 once asleep.
(:test)
function testOnset_progressPctClimbsInStepsOfTwenty(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    if (d.getOnsetProgressPct() != 0) {
        logger.debug("expected 0% before any still minute, got " + d.getOnsetProgressPct());
        return false;
    }
    var expected = [20, 40, 60, 80] as Array<Number>;
    for (var i = 0; i < expected.size(); i++) {
        d.testRunMinutes(1, 70, 10.0f);
        if (d.getOnsetProgressPct() != expected[i]) {
            logger.debug("after still minute " + (i + 1) + " expected " + expected[i] + "%, got " + d.getOnsetProgressPct());
            return false;
        }
        if (d.getState() != SleepDetector.STATE_MONITORING) {
            logger.debug("expected MONITORING after still minute " + (i + 1) + ", got " + d.getState());
            return false;
        }
    }
    d.testRunMinutes(1, 70, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING after the 5th still minute, got " + d.getState());
        return false;
    }
    if (d.getOnsetProgressPct() != 100) {
        logger.debug("expected 100% once asleep, got " + d.getOnsetProgressPct());
        return false;
    }
    return true;
}

//! Progress reflects the requirement in force: one still minute is 50% when the HR drop is met (2 minute means, drop 5) but 20% when HR did not drop.
(:test)
function testOnset_progressPctReflectsHrDropRequirement(logger as Test.Logger) as Boolean {
    // Restless first minute contributes an HR minute mean without stillness,
    // so the second (still) minute sees 2 HR means and 1 still minute.
    var a = new SleepDetector(null);
    a.testStart();
    a.testSetBaseline(70.0f);
    a.testRunMinutes(1, 65, 300.0f);
    if (a.getOnsetProgressPct() != 0 || a.getStillMinutes() != 0) {
        logger.debug("restless minute must leave progress at 0, got " + a.getOnsetProgressPct());
        return false;
    }
    a.testRunMinutes(1, 65, 10.0f);
    if (a.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("one still minute must not trigger onset, got " + a.getState());
        return false;
    }
    if (a.getOnsetProgressPct() != 50) {
        logger.debug("expected 50% (1 of 2 still minutes with HR drop), got " + a.getOnsetProgressPct());
        return false;
    }

    var b = new SleepDetector(null);
    b.testStart();
    b.testSetBaseline(70.0f);
    b.testRunMinutes(1, 70, 300.0f);
    b.testRunMinutes(1, 70, 10.0f);
    if (b.getOnsetProgressPct() != 20) {
        logger.debug("expected 20% (1 of 5 still minutes without HR drop), got " + b.getOnsetProgressPct());
        return false;
    }
    return true;
}

//! 5-minute nap, no HR, still from t=0 (the owner's failing case): onset at
//! 300 s, alarm at exactly 600 s with NAP_COMPLETE, far inside the 20 min
//! deadline; no smart wake for such a short nap.
(:test)
function testOnset_fiveMinuteNapTimeline(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(5);
    var start = d.testGetStartSec();
    if (d.getNapDurationMin() != 5 || d.testGetDeadlineSec() != start + 20 * 60) {
        logger.debug("expected nap 5 min and deadline start + 1200 s");
        return false;
    }
    d.testRunSeconds(299, 0, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("expected MONITORING at 299 s, got " + d.getState());
        return false;
    }
    d.testRunSeconds(1, 0, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING at 300 s, got " + d.getState());
        return false;
    }
    var m = d.getSleepStartTime();
    if (m == null || (m as Time.Moment).value() != start + 300) {
        logger.debug("expected sleepStart == start + 300");
        return false;
    }
    if (d.testGetNapEndSec() != start + 600) {
        logger.debug("expected napEnd == start + 600, got offset " + (d.testGetNapEndSec() - start));
        return false;
    }
    if (d.getSmartWakeWindowSec() != 0 || d.isSmartWakeActive()) {
        logger.debug("smart wake must be disabled for a 5-minute nap");
        return false;
    }
    d.testRunSeconds(299, 0, 10.0f);   // t = 599 s
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING at 599 s, got " + d.getState());
        return false;
    }
    d.testRunSeconds(1, 0, 10.0f);     // t = 600 s
    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("expected ALARM at 600 s, got " + d.getState());
        return false;
    }
    if (d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("expected ALARM_NAP_COMPLETE, got " + d.getAlarmReason());
        return false;
    }
    return true;
}

//! Real calibration with a restless wrist: those minutes do not count as still, and once still the 3-minute HR window (70,70,60 -> 70,60,60) lets the HR path fire at the second still minute (240 s).
(:test)
function testOnset_restlessCalibrationThenHrDropSleepsAtSecondStillMinute(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testRunMinutes(2, 70, 300.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getStillMinutes() != 0) {
        logger.debug("expected MONITORING with 0 still minutes after restless calibration; state "
            + d.getState() + " still " + d.getStillMinutes());
        return false;
    }
    if ((d.getHRBaseline() - 70.0f).abs() > 0.01f) {
        logger.debug("expected baseline 70, got " + d.getHRBaseline());
        return false;
    }
    d.testRunMinutes(1, 60, 10.0f);   // window [70,70,60]: mean 66.7, drop 3.3 -> not met
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getStillMinutes() != 1) {
        logger.debug("expected MONITORING with 1 still minute at 180 s; state "
            + d.getState() + " still " + d.getStillMinutes());
        return false;
    }
    d.testRunMinutes(1, 60, 10.0f);   // window [70,60,60]: mean 63.3, drop 6.7 -> met, 2 still
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected SLEEPING at 240 s via smoothed HR drop, got " + d.getState());
        return false;
    }
    if (d.getStillMinutes() != 2) {
        logger.debug("expected 2 still minutes at onset, got " + d.getStillMinutes());
        return false;
    }
    return true;
}

//! Observed tick by tick over 10 minutes, the state only ever moves CALIBRATING -> MONITORING -> SLEEPING; no step is skipped and no other transition occurs.
(:test)
function testOnset_statesNeverSkip(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    var prev = d.getState();
    if (prev != SleepDetector.STATE_CALIBRATING) {
        logger.debug("expected CALIBRATING at start, got " + prev);
        return false;
    }
    var seenMonitoring = false;
    var seenSleeping = false;
    for (var i = 0; i < 600; i++) {
        var hr = 70;
        if (i >= 120) {
            hr = 60;
        }
        d.testFeedSecond(hr, 10.0f);
        var cur = d.getState();
        if (cur != prev) {
            var allowed = (prev == SleepDetector.STATE_CALIBRATING && cur == SleepDetector.STATE_MONITORING)
                       || (prev == SleepDetector.STATE_MONITORING && cur == SleepDetector.STATE_SLEEPING);
            if (!allowed) {
                logger.debug("illegal transition " + prev + " -> " + cur + " at second " + (i + 1));
                return false;
            }
            if (cur == SleepDetector.STATE_MONITORING) {
                seenMonitoring = true;
            }
            if (cur == SleepDetector.STATE_SLEEPING) {
                seenSleeping = true;
            }
            prev = cur;
        }
    }
    if (!seenMonitoring || !seenSleeping) {
        logger.debug("expected to pass through MONITORING and SLEEPING; monitoring " + seenMonitoring
            + " sleeping " + seenSleeping);
        return false;
    }
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("expected to end SLEEPING at 600 s, got " + d.getState());
        return false;
    }
    return true;
}
