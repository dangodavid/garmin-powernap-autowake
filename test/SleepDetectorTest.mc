import Toybox.Test;
import Toybox.Lang;

// -----------------------------------------------------------------------------
// SleepDetector Unit Tests
//
// Run via: Ctrl+Shift+P -> "Monkey C: Run Tests"
// Each function must return true to pass.
// -----------------------------------------------------------------------------

//! 1. Initial state must be CALIBRATING.
(:test)
function testInitialStateIsCalibrating(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    var ok = detector.getState() == SleepDetector.STATE_CALIBRATING;
    if (!ok) {
        logger.debug("Expected STATE_CALIBRATING, got: " + detector.getState());
    }
    return ok;
}

//! 2. Default settings: 30 min nap, immobility threshold 180 s.
(:test)
function testDefaultSettings(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    var napOk = detector.getNapDurationMin() == 30;
    var immOk = detector.getImmobilityRequired() == 180;
    if (!napOk) { logger.debug("napDuration expected 30, got: " + detector.getNapDurationMin()); }
    if (!immOk) { logger.debug("immobilityRequired expected 180, got: " + detector.getImmobilityRequired()); }
    return napOk && immOk;
}

//! 3. After 12 HR samples calibration ends and transitions to MONITORING.
(:test)
function testCalibrationTransitionsToMonitoring(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testInjectHR(70);
    // 12 ticks × 10 s = 2 minutes of calibration
    for (var i = 0; i < 12; i++) {
        detector.testTick();
    }
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) { logger.debug("Expected MONITORING after 12 ticks, got: " + detector.getState()); }
    return ok;
}

//! 4. Baseline computed after calibration reflects the injected HR.
(:test)
function testBaselineComputedCorrectly(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testInjectHR(72);
    for (var i = 0; i < 12; i++) {
        detector.testTick();
    }
    // Baseline should be ~72.0
    var baseline = detector.getHRBaseline();
    var ok = baseline >= 71.5f && baseline <= 72.5f;
    if (!ok) { logger.debug("Expected baseline ~72.0, got: " + baseline); }
    return ok;
}

//! 5. Sleep detection: HR drop + sustained immobility -> STATE_SLEEPING.
(:test)
function testSleepDetectedWhenHRDropsAndMotionLow(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    // Set baseline to 70 BPM and jump directly to MONITORING
    detector.testSetBaseline(70.0f);
    // Inject low HR (drop of 10 BPM > threshold of 8) and zero motion
    detector.testInjectHR(60);
    detector.testInjectMotion(0.0f);
    // Simulate immobility sustained for 200 s (> 180 s required)
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) { logger.debug("Expected SLEEPING, got: " + detector.getState()); }
    return ok;
}

//! 6. Without a sufficient HR drop, sleep is NOT detected.
(:test)
function testNoSleepWhenHRDropInsufficient(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    // Baseline 70, current HR 65 -> drop 5 BPM < threshold 8 -> no detection
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(65);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) { logger.debug("Expected MONITORING (no sleep), got: " + detector.getState()); }
    return ok;
}

//! 7. High motion prevents sleep detection.
(:test)
function testNoSleepWhenMotionHigh(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);
    // 150 millig > threshold 50 -> too much motion
    detector.testInjectMotion(150.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) { logger.debug("Expected MONITORING (high motion), got: " + detector.getState()); }
    return ok;
}

//! 8. Countdown expiry triggers STATE_ALARM.
(:test)
function testCountdownExpiresTriggersAlarm(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testTransitionToSleep();
    // Drain the countdown: 30 min × 60 s / 60 s per tick = 30 ticks (+ 2 margin)
    for (var i = 0; i < 182; i++) {
        detector.testTick();
    }
    var ok = detector.getState() == SleepDetector.STATE_ALARM;
    if (!ok) { logger.debug("Expected ALARM after countdown, got: " + detector.getState()); }
    return ok;
}

//! 9. Cancel from SLEEPING goes to SUMMARY.
(:test)
function testCancelFromSleepingGoesToSummary(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testTransitionToSleep();
    detector.cancel();
    var ok = detector.getState() == SleepDetector.STATE_SUMMARY;
    if (!ok) { logger.debug("Expected SUMMARY after cancel, got: " + detector.getState()); }
    return ok;
}

//! 10. finishNap() correctly sets SUMMARY state and computes duration.
(:test)
function testFinishNapSetsSummaryState(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testTransitionToSleep();
    // A few ticks to accumulate some sleep time
    for (var i = 0; i < 5; i++) {
        detector.testTick();
    }
    detector.finishNap();
    var ok = detector.getState() == SleepDetector.STATE_SUMMARY;
    if (!ok) { logger.debug("Expected SUMMARY, got: " + detector.getState()); }
    return ok;
}

//! 11. A single high-motion tick must NOT wake the user.
//!     Motion must be sustained across 2+ consecutive ticks.
(:test)
function testSingleHighMotionTickDoesNotWake(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testTransitionToSleep();
    // Tick 1: normal motion (0 millig) -> window = [0]
    detector.testTick();
    // Tick 2: single motion spike -> window = [0, 300], mean = 150 < 200
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) { logger.debug("Expected SLEEPING after single spike, got: " + detector.getState()); }
    return ok;
}

//! 12. After a spontaneous wake, sleep time does NOT accumulate in MONITORING,
//!     but the countdown CONTINUES to decrease so the alarm fires on time.
(:test)
function testMonitoringAfterWakeCountdownContinues(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testTransitionToSleep();

    // 3 ticks of real sleep
    detector.testTick();
    detector.testTick();
    detector.testTick();

    // Trigger sustained-motion wake (takes 2 ticks: first tick is still "sleeping"
    // because last-2-window mean is below threshold, second tick fires the wake).
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // tick 4: last-2 = [0,300], mean=150 < 200 -> still sleeping
    detector.testTick(); // tick 5: last-2 = [300,300], mean=300 > 200 -> WAKE

    // Snapshot values at the moment of wake
    var sleepAtWake  = detector.getActualNapDurationSec();
    var remainAtWake = detector.getRemainingSeconds();

    // 3 more ticks in MONITORING:
    //   - _actualSleepSec must NOT increase (user is awake, no sleep accumulation)
    //   - _remainingSeconds MUST decrease by 3 × _tickSec (countdown runs continuously)
    detector.testTick();
    detector.testTick();
    detector.testTick();

    var tickSec = detector.getTickSec();
    var expectedRemain = remainAtWake - (3 * tickSec);
    if (expectedRemain < 0) { expectedRemain = 0; }

    var ok = (detector.getState() == SleepDetector.STATE_MONITORING)
          && (detector.getActualNapDurationSec() == sleepAtWake)
          && (detector.getRemainingSeconds() == expectedRemain);
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " sleep=" + detector.getActualNapDurationSec()
            + " (want " + sleepAtWake + ")"
            + " remain=" + detector.getRemainingSeconds()
            + " (want " + expectedRemain + ")");
    }
    return ok;
}

//! 13. Sustained motion across 2 consecutive ticks (>= 20 s) must return
//!     state to MONITORING (not SUMMARY)  - the app keeps running.
(:test)
function testSustainedMotionReturnsToMonitoring(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testTransitionToSleep();
    // Tick 1: high motion -> window = [300], fewer than 2 samples yet
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick();
    // Tick 2: high motion continues -> window = [300, 300], mean = 300 > 200 -> wake
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) { logger.debug("Expected MONITORING after sustained motion, got: " + detector.getState()); }
    return ok;
}

//! 14. After returning to sleep following a spontaneous wake, _actualSleepSec
//!     must continue accumulating  - not reset to zero and not stay frozen.
(:test)
function testSleepAccumulatesAfterReSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();

    // Set up HR conditions needed for sleep re-detection in MONITORING
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);

    // Phase 1: 2 ticks of real sleep
    detector.testTransitionToSleep();
    detector.testTick(); // actSleep = 1 × tickSec
    detector.testTick(); // actSleep = 2 × tickSec

    // Spontaneous wake: high motion across 2 consecutive ticks
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // last-2 = [0, 300] -> mean=150 < 200 -> still sleeping; actSleep = 3 × tickSec
    detector.testTick(); // last-2 = [300, 300] -> mean=300 > 200 -> WAKE -> MONITORING
    var sleepAtWake = detector.getActualNapDurationSec(); // 3 × tickSec

    // Clear motion from the window (2 zero injections + next tick will make last-2=[0,0])
    detector.testInjectMotion(0.0f);
    detector.testInjectMotion(0.0f);

    // Shortcut immobility detection (otherwise it would take 180 s of real ticks)
    detector.testSetImmobilityStart(200);

    // Re-detection tick: handleMonitoring sees immobility 200 s >= 180 s -> transitionToSleep()
    detector.testTick();

    // Phase 2: 2 ticks of sleep after returning  - accumulation must resume
    detector.testTick(); // actSleep = sleepAtWake + 1 × tickSec
    detector.testTick(); // actSleep = sleepAtWake + 2 × tickSec

    var tickSec = detector.getTickSec();
    var expectedSleep = sleepAtWake + (2 * tickSec);

    var ok = (detector.getState() == SleepDetector.STATE_SLEEPING)
          && (detector.getActualNapDurationSec() == expectedSleep);
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " actSleep=" + detector.getActualNapDurationSec()
            + " (want " + expectedSleep + ")"
            + " sleepAtWake=" + sleepAtWake);
    }
    return ok;
}

// -----------------------------------------------------------------------------
// Production bug regression tests
// -----------------------------------------------------------------------------

//! 15. cancel() from MONITORING after at least one sleep phase must call
//!     computeSleepStats() so _napEndTime is never null in the summary screen.
//!     Bug: the original else-branch just set _state = STATE_SUMMARY, skipping
//!     stats computation and leaving _napEndTime = null (potential view crash).
(:test)
function testCancelFromMonitoringAfterSleepComputesStats(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testTransitionToSleep();

    // A few ticks of real sleep
    detector.testTick();
    detector.testTick();

    // Trigger a spontaneous wake
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // last-2 = [0,300] -> still sleeping
    detector.testTick(); // last-2 = [300,300] -> WAKE -> MONITORING

    // Now cancel from MONITORING
    detector.cancel();

    var ok = (detector.getState() == SleepDetector.STATE_SUMMARY)
          && (detector.getNapEndTime() != null);
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " napEndTime=" + detector.getNapEndTime());
    }
    return ok;
}

//! 16. cancel() from CALIBRATING goes to SUMMARY without crash and without sleep stats.
(:test)
function testCancelFromCalibratingGoesToSummary(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    // State starts at CALIBRATING, no sleep has occurred
    detector.cancel();
    // Must be SUMMARY; napEndTime must be null (no sleep -> no stats computed)
    var ok = (detector.getState() == SleepDetector.STATE_SUMMARY)
          && (detector.getNapEndTime() == null)
          && (detector.getActualNapDurationSec() == 0);
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " napEndTime=" + detector.getNapEndTime()
            + " actSleep=" + detector.getActualNapDurationSec());
    }
    return ok;
}

//! 17. Countdown expiring while in MONITORING (user awake during final tick)
//!     must still transition to STATE_ALARM, not get stuck in MONITORING.
(:test)
function testCountdownExpiresInMonitoringTriggersAlarm(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);
    detector.testTransitionToSleep();

    // Leave just enough countdown for the wake sequence + one monitoring tick:
    // wake takes 2 sleeping ticks, then 1 monitoring tick drains the last chunk.
    var tickSec = detector.getTickSec();
    detector.testSetRemainingSeconds(3 * tickSec); // 3 ticks total

    // Trigger wake: 2 sleeping ticks (tick 1 = last-2=[0,300] no wake;
    //                                 tick 2 = last-2=[300,300] -> WAKE)
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // remaining: 3->2 ticks (this tick decrements in sleeping)
    detector.testTick(); // WAKE -> MONITORING; remaining stays at 2 ticks

    // In MONITORING the countdown still runs; motion stays high so no re-sleep.
    detector.testTick(); // remaining: 2->1 ticks
    detector.testTick(); // remaining: 1->0 -> ALARM

    var ok = detector.getState() == SleepDetector.STATE_ALARM;
    if (!ok) { logger.debug("Expected ALARM, got state: " + detector.getState()); }
    return ok;
}

//! 18. HR drop exactly equal to the threshold (8 BPM by default) must trigger
//!     sleep detection  - the condition uses >= so the boundary value must pass.
(:test)
function testHRDropExactlyAtThresholdDetectsSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    // Baseline 70, inject two samples of 62 -> hrAvg = 62.0, drop = 8.0 exactly
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(62);
    detector.testInjectHR(62);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) { logger.debug("Expected SLEEPING at exact threshold, got: " + detector.getState()); }
    return ok;
}

//! 19. HR drop one BPM below the threshold (7 BPM) must NOT trigger sleep.
//!     Companion to test 18  - validates both sides of the boundary.
(:test)
function testHRDropOneBelowThresholdNoSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    // Baseline 70, two samples of 63 -> hrAvg = 63.0, drop = 7.0 < 8
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) { logger.debug("Expected MONITORING (drop below threshold), got: " + detector.getState()); }
    return ok;
}

//! 20. Motion at exactly the threshold (50 millig) must NOT be counted as
//!     immobility  - the check is strict less-than, so 50.0 fails.
(:test)
function testMotionAtExactThresholdPreventsImmobility(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);
    // 50.0 millig is the threshold; strict < means this is NOT still
    detector.testInjectMotion(50.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) { logger.debug("Expected MONITORING (motion at threshold), got: " + detector.getState()); }
    return ok;
}

//! 21. HR spike during sleep (> 10 BPM above recent sleep average) must
//!     trigger a spontaneous wake via the secondary detection branch in
//!     detectSpontaneousWake(), independent of the motion check.
(:test)
function testHRSpikeDuringSleepTriggersWake(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testTransitionToSleep();

    // Establish a stable sleep-HR baseline of 60 BPM (need >= 3 samples)
    detector.testAddSleepHrSample(60);
    detector.testAddSleepHrSample(60);
    detector.testAddSleepHrSample(60);

    // Inject a spike: _currentHR = 80 BPM (testInjectHR sets both _currentHR and _hrWindow).
    // currentHR (80) - recentSleepHR (60) = 20 > 10 threshold -> wake.
    detector.testInjectHR(80);
    detector.testInjectHR(80);

    // Motion stays at 0  - wake must be driven by the HR spike alone.
    detector.testTick();

    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) { logger.debug("Expected MONITORING after HR spike, got: " + detector.getState()); }
    return ok;
}

//! 22. Two full sleep->wake->sleep->wake cycles: _actualSleepSec must accumulate
//!     across all sleeping phases and remain frozen during both awake periods.
(:test)
function testTwoWakeCyclesAccumulateCorrectly(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);

    detector.testTransitionToSleep();
    var tickSec = detector.getTickSec();

    // -- Cycle 1 ----------------------------------------------------------
    // Phase 1a: 2 sleeping ticks
    detector.testTick();
    detector.testTick();
    var sleepAfter1a = detector.getActualNapDurationSec(); // 2 × tickSec

    // Wake 1: sustained motion (2 ticks: first still sleeping, second wakes)
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // still sleeping (last-2 mean < 200)
    detector.testTick(); // WAKE -> MONITORING
    var sleepAtWake1 = detector.getActualNapDurationSec(); // 3 × tickSec

    // Re-sleep 1: clear motion, shortcut immobility, run detection tick
    detector.testInjectMotion(0.0f);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> transitionToSleep()

    // -- Cycle 2 ----------------------------------------------------------
    // Phase 2a: 2 more sleeping ticks
    detector.testTick();
    detector.testTick();
    var sleepAfter2a = detector.getActualNapDurationSec();

    // Wake 2: another sustained motion wake
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // still sleeping
    detector.testTick(); // WAKE -> MONITORING
    var sleepAtWake2 = detector.getActualNapDurationSec();

    // Expected values
    var expectedAfter1a = 2 * tickSec;
    var expectedAtWake1 = 3 * tickSec;          // tick 3 still sleeping before wake
    var expectedAfter2a = sleepAtWake1 + 2 * tickSec; // cycle-1 sleep + 2 new ticks
    var expectedAtWake2 = sleepAtWake1 + 3 * tickSec; // + one more sleeping tick

    var ok = (detector.getState() == SleepDetector.STATE_MONITORING)
          && (sleepAfter1a == expectedAfter1a)
          && (sleepAtWake1 == expectedAtWake1)
          && (sleepAfter2a == expectedAfter2a)
          && (sleepAtWake2 == expectedAtWake2);
    if (!ok) {
        logger.debug("after1a=" + sleepAfter1a + "(want " + expectedAfter1a + ")"
            + " atWake1=" + sleepAtWake1 + "(want " + expectedAtWake1 + ")"
            + " after2a=" + sleepAfter2a + "(want " + expectedAfter2a + ")"
            + " atWake2=" + sleepAtWake2 + "(want " + expectedAtWake2 + ")");
    }
    return ok;
}

//! 23. Mixed HR window: if one sample is at baseline and one is just above the
//!     drop threshold, the average must not satisfy the threshold.
//!     Baseline=70, window=[70,63] -> mean=66.5, drop=3.5 < 8 -> no sleep.
//!     Guards against rounding errors giving a false positive.
(:test)
function testMixedHRWindowBelowThreshold(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector();
    detector.testSetBaseline(70.0f);
    // Window: one reading at baseline, one at 63 -> average drop = 3.5 BPM
    detector.testInjectHR(70);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) { logger.debug("Expected MONITORING (mixed window), got: " + detector.getState()); }
    return ok;
}
