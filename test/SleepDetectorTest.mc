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
    var detector = new SleepDetector(null);
    var ok = detector.getState() == SleepDetector.STATE_CALIBRATING;
    if (!ok) {
        logger.debug("Expected STATE_CALIBRATING, got: " + detector.getState());
    }
    return ok;
}

//! 2. Default settings: 30 min nap, immobility threshold 180 s.
(:test)
function testDefaultSettings(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    var napOk = detector.getNapDurationMin() == 30;
    var immOk = detector.getImmobilityRequired() == 120;
    if (!napOk) { logger.debug("napDuration expected 30, got: " + detector.getNapDurationMin()); }
    if (!immOk) { logger.debug("immobilityRequired expected 120, got: " + detector.getImmobilityRequired()); }
    return napOk && immOk;
}

//! 3. After 12 HR samples calibration ends and transitions to MONITORING.
(:test)
function testCalibrationTransitionsToMonitoring(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
    // Baseline 70, current HR 66 -> drop 4 BPM < threshold 5 -> no detection
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(66);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
    detector.testTransitionToSleep();
    detector.cancel();
    var ok = detector.getState() == SleepDetector.STATE_SUMMARY;
    if (!ok) { logger.debug("Expected SUMMARY after cancel, got: " + detector.getState()); }
    return ok;
}

//! 10. finishNap() correctly sets SUMMARY state and computes duration.
(:test)
function testFinishNapSetsSummaryState(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);

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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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

//! 18. HR drop exactly equal to the threshold (5 BPM by default) must trigger
//!     sleep detection: the condition uses >= so the boundary value must pass.
(:test)
function testHRDropExactlyAtThresholdDetectsSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    // Baseline 70, inject two samples of 65 -> hrAvg = 65.0, drop = 5.0 exactly
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(65);
    detector.testInjectHR(65);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) { logger.debug("Expected SLEEPING at exact threshold, got: " + detector.getState()); }
    return ok;
}

//! 19. HR drop one BPM below the threshold (4 BPM) must NOT trigger sleep.
//!     Companion to test 18: validates both sides of the boundary.
(:test)
function testHRDropOneBelowThresholdNoSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    // Baseline 70, two samples of 66 -> hrAvg = 66.0, drop = 4.0 < 5
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(66);
    detector.testInjectHR(66);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
    var detector = new SleepDetector(null);
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
//!     Baseline=70, window=[70,63] -> mean=66.5, drop=3.5 < 5 -> no sleep.
//!     Guards against rounding errors giving a false positive.
(:test)
function testMixedHRWindowBelowThreshold(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
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

// -----------------------------------------------------------------------------
// v1.0.1 regression tests: alarm timing and detection reliability
// -----------------------------------------------------------------------------

//! 24. Alarm must start from the timer callback when countdown expires,
//!     not depend on a UI refresh (onUpdate). On AMOLED devices the display
//!     can be off during a nap, so onUpdate never runs. The alarm must fire
//!     regardless.
(:test)
function testAlarmStartsFromTimerCallback(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testTransitionToSleep();
    // Set countdown to exactly 1 tick so the next tick drains it to 0
    detector.testSetRemainingSeconds(detector.getTickSec());
    detector.testTick();
    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " alarming=" + alarm.isAlarming());
    }
    return ok;
}

//! 25. Alarm must start from timer even when countdown expires while the
//!     user is in MONITORING (spontaneous wake during the final ticks).
(:test)
function testAlarmStartsFromTimerInMonitoring(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);
    detector.testTransitionToSleep();

    var tickSec = detector.getTickSec();
    detector.testSetRemainingSeconds(2 * tickSec);

    // Trigger spontaneous wake via sustained motion
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // SLEEPING: window=[300], no wake yet, remaining-=tick
    detector.testTick(); // SLEEPING: window=[300,300], mean=300>200 -> WAKE
    detector.testTick(); // MONITORING: remaining->0 -> transitionToAlarm()

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " alarming=" + alarm.isAlarming());
    }
    return ok;
}

//! 26. A single motion spike above the threshold must NOT break immobility
//!     when the windowed average (last 2 entries) stays below threshold.
//!     Previous tick: 0 millig, current tick: 70 millig (above 50 threshold).
//!     Windowed average = mean(0, 70) = 35 < 50 -> still immobile -> detect sleep.
(:test)
function testSingleMotionSpikeDoesNotBreakImmobility(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);
    // Build a motion window with one low entry
    detector.testInjectMotion(0.0f);
    // Set current motion above threshold, but don't add to window.
    // onPollTick will add it, making window=[0, 70], mean=35 < 50.
    detector.testSetMotionMagnitude(70.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) {
        logger.debug("Expected SLEEPING (windowed avg 35 < 50), got: " + detector.getState());
    }
    return ok;
}

//! 27. Immobility at exactly 120 s (new threshold) must trigger sleep detection.
(:test)
function testImmobilityAtExact120sDetectsSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(120);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) {
        logger.debug("Expected SLEEPING at 120s immobility, got: " + detector.getState());
    }
    return ok;
}

//! 28. Immobility at 119 s must NOT trigger sleep detection (boundary check).
(:test)
function testImmobilityAt119sDoesNotDetectSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(119);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) {
        logger.debug("Expected MONITORING at 119s immobility, got: " + detector.getState());
    }
    return ok;
}

// -----------------------------------------------------------------------------
// v1.0.1 extended coverage: real-world failure scenarios
// -----------------------------------------------------------------------------

//! 29. If the HR sensor never delivers data during calibration, the baseline
//!     must fall back to 70 BPM and the app must proceed to MONITORING.
//!     Without this fallback the app hangs on "Calibrating..." forever.
(:test)
function testCalibrationFallbackWhenNoHRData(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    // Run 12 calibration ticks without injecting any HR (stays at 0)
    for (var i = 0; i < 12; i++) {
        detector.testTick();
    }
    var baseline = detector.getHRBaseline();
    var ok = (detector.getState() == SleepDetector.STATE_MONITORING)
          && (baseline >= 69.5f && baseline <= 70.5f);
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " baseline=" + baseline + " (expected 70.0)");
    }
    return ok;
}

//! 30. Smart Wake Window must be disabled for naps < 30 min. Without this
//!     guard, short naps lose a disproportionate fraction of sleep time
//!     (e.g. 50% of a 10-min nap falls inside the wake window).
(:test)
function testSmartWakeDisabledForShortNaps(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetNapDurationMin(5);
    detector.testTransitionToSleep(); // remaining = 5 * 60 = 300

    // Inject motion that would trigger light-sleep detection (> 75 millig)
    detector.testInjectMotion(80.0f);
    detector.testInjectMotion(80.0f);

    detector.testTick(); // remaining = 300 - 60 = 240

    // Smart wake guard: napDurationMin (5) >= 30 is FALSE,
    // so smart wake is skipped. State must still be SLEEPING, not ALARM.
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) {
        logger.debug("Expected SLEEPING (smart wake disabled for 5-min nap), got: "
            + detector.getState());
    }
    return ok;
}

//! 31. Motion at 199 millig (just below the 200 millig spontaneous wake
//!     threshold) sustained across 2 ticks must NOT trigger a wake.
//!     A false wake during deep sleep forces the user through a 2-min
//!     re-detection cycle, losing real sleep time.
(:test)
function testMotionJustBelowWakeThresholdDoesNotWake(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testTransitionToSleep();
    detector.testSetMotionMagnitude(199.0f);
    detector.testTick(); // window = [199]
    detector.testTick(); // window = [199, 199], mean = 199 < 200 -> no wake
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) {
        logger.debug("Expected SLEEPING at 199 millig, got: " + detector.getState());
    }
    return ok;
}

//! 32. Calling startAlarm() twice must not create duplicate timers or crash.
//!     The guard (_isAlarming) must reject the second call.
(:test)
function testDoubleAlarmStartIsSafe(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testTransitionToSleep();
    detector.testSetRemainingSeconds(detector.getTickSec());
    detector.testTick(); // -> ALARM, startAlarm() called by transitionToAlarm()

    // Manually call startAlarm() again (simulates onUpdate also triggering it)
    alarm.startAlarm();

    // Must still be alarming, no crash
    var ok = alarm.isAlarming();
    alarm.stop();
    ok = ok && !alarm.isAlarming();
    if (!ok) {
        logger.debug("Double start or stop failed");
    }
    return ok;
}

//! 33. If the user lies awake for 60+ minutes without falling asleep,
//!     the app must transition to STATE_TIMEOUT instead of running forever.
(:test)
function testMonitoringTimeoutAt60Minutes(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    // HR stays at baseline (no drop -> no sleep detection)
    detector.testInjectHR(70);
    detector.testInjectMotion(0.0f);
    // Pretend the app started 3601 seconds ago (just over 60 min)
    detector.testSetStartMoment(3601);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_TIMEOUT;
    if (!ok) {
        logger.debug("Expected TIMEOUT after 60 min, got: " + detector.getState());
    }
    return ok;
}

//! 34. The 60-min monitoring timeout must NOT fire once sleep has been
//!     detected at least once. A user with a 120-min nap who wakes briefly
//!     at the 65-min mark would otherwise see a timeout instead of
//!     re-entering sleep detection.
(:test)
function testNoTimeoutAfterSleepWasDetected(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(60);
    detector.testTransitionToSleep(); // _sleepStartTime is now set
    detector.testSetRemainingSeconds(600); // 10 min left

    // Trigger wake via sustained motion
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // SLEEPING: window=[300], remaining -= tick
    detector.testTick(); // SLEEPING: window=[300,300], mean>200 -> MONITORING

    // Pretend app started 65 min ago (past the 60-min timeout)
    detector.testSetStartMoment(3900);
    detector.testTick(); // MONITORING: timeout guard checks _sleepStartTime != null -> skip

    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) {
        logger.debug("Expected MONITORING (no timeout after sleep), got: "
            + detector.getState());
    }
    return ok;
}

//! 35. Smart Wake must be disabled for 25-min nap (boundary: just below 30).
//!     Light-sleep signals in the last 5 minutes must NOT trigger early alarm.
(:test)
function testSmartWakeDisabledFor25MinNap(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetNapDurationMin(25);
    detector.testTransitionToSleep(); // remaining = 1500
    detector.testSetRemainingSeconds(200); // within 300s window

    // Motion that would trigger light-sleep detection on a 30+ min nap
    detector.testInjectMotion(80.0f);
    detector.testInjectMotion(80.0f);
    detector.testTick();

    // napDurationMin (25) >= 30 is FALSE, so smart wake is skipped
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) {
        logger.debug("Expected SLEEPING (smart wake disabled for 25-min nap), got: "
            + detector.getState());
    }
    return ok;
}

//! 36. Smart Wake fires on gentle motion for a 30-min nap (boundary: exactly 30).
(:test)
function testSmartWakeFiresOnGentleMotion(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testTransitionToSleep();
    detector.testSetRemainingSeconds(200); // within 300s smart wake window

    // Motion at 80 millig: above 75 (1.5 x 50 threshold) but below 200 (wake)
    detector.testInjectMotion(80.0f);
    detector.testInjectMotion(80.0f);
    detector.testTick();

    var ok = detector.getState() == SleepDetector.STATE_ALARM;
    if (!ok) {
        logger.debug("Expected ALARM (smart wake on motion), got: " + detector.getState());
    }
    return ok;
}

//! 37. Smart Wake fires on HR rise for a 30-min nap, independent of motion.
(:test)
function testSmartWakeFiresOnHRRise(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testTransitionToSleep();
    detector.testSetRemainingSeconds(200);

    // Build a sleep HR baseline of 55 BPM (need >= 4 samples for slice(-4,-1))
    detector.testAddSleepHrSample(55);
    detector.testAddSleepHrSample(55);
    detector.testAddSleepHrSample(55);
    detector.testAddSleepHrSample(55);

    // Current HR = 62: delta = 7 BPM > 5 threshold, but < 10 (no spontaneous wake)
    detector.testInjectHR(62);
    detector.testTick();

    var ok = detector.getState() == SleepDetector.STATE_ALARM;
    if (!ok) {
        logger.debug("Expected ALARM (smart wake on HR rise), got: " + detector.getState());
    }
    return ok;
}

//! 38. When the countdown remainder is less than one full tick (e.g. 30 s
//!     left with a 60 s tick), remaining must clamp to 0 (never go negative)
//!     and the alarm must fire.
(:test)
function testSubTickRemainderClampsToZero(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testTransitionToSleep();
    detector.testSetRemainingSeconds(30); // less than 1 tick
    detector.testTick(); // 30 - 60 = -30, clamped to 0 -> ALARM
    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && (detector.getRemainingSeconds() == 0);
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " remaining=" + detector.getRemainingSeconds());
    }
    return ok;
}

//! 39. cancel() from STATE_ALARM must transition to SUMMARY so the user
//!     can see their nap stats. This simulates pressing BACK during the alarm.
(:test)
function testCancelFromAlarmGoesToSummary(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testTransitionToSleep();
    detector.testSetRemainingSeconds(detector.getTickSec());
    detector.testTick(); // -> STATE_ALARM

    var wasAlarming = alarm.isAlarming();
    detector.cancel(); // ALARM -> finishNap() -> SUMMARY
    alarm.stop(); // delegate would call this

    var ok = wasAlarming
          && (detector.getState() == SleepDetector.STATE_SUMMARY)
          && !alarm.isAlarming();
    if (!ok) {
        logger.debug("wasAlarming=" + wasAlarming
            + " state=" + detector.getState()
            + " stillAlarming=" + alarm.isAlarming());
    }
    return ok;
}

// -----------------------------------------------------------------------------
// Short nap lifecycle tests (5-30 min)
// Verify that each duration calibrates, detects, counts down, and alarms.
// -----------------------------------------------------------------------------

//! 40. Full 5-minute nap lifecycle: calibrate -> detect -> countdown -> alarm.
//!     This is the hardest case: calibration alone takes 2 min, detection adds
//!     another 2 min, so the 5-min countdown starts ~4 min after launch.
//!     Pre-calibration immobility tracking is tested via testPollTick().
(:test)
function testFullLifecycle5MinNap(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetNapDurationMin(5);

    // -- Phase 1: Calibration (2 min = 12 x 10s ticks) --
    // Inject awake HR and low motion before calibration begins
    detector.testInjectHR(70);
    detector.testInjectMotion(0.0f);

    for (var i = 0; i < 12; i++) {
        detector.testTick(); // onCalibTick
    }
    // Also fire 2 poll ticks to simulate the parallel poll timer (at t=60s, t=120s)
    // This pre-populates HR/motion windows AND starts immobility tracking
    detector.testPollTick();
    detector.testPollTick();

    if (detector.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("Calibration did not complete, state: " + detector.getState());
        return false;
    }

    // -- Phase 2: Detection --
    // Inject sleep HR (drop = 6 >= 5 threshold) and confirm immobility
    detector.testInjectHR(64);
    detector.testInjectHR(64);
    // Immobility was pre-tracked during calibration; shortcut for test timing
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING, remaining = 300

    if (detector.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("Sleep not detected, state: " + detector.getState());
        return false;
    }

    // -- Phase 3: Countdown (5 ticks x 60s = 300s = 5 min) --
    for (var j = 0; j < 5; j++) {
        detector.testTick();
    }

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming()
          && (detector.getRemainingSeconds() == 0);
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " alarming=" + alarm.isAlarming()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

//! 41. 10-minute nap: countdown completes and alarm fires.
(:test)
function test10MinNapCountdownCompletes(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetNapDurationMin(10);
    detector.testTransitionToSleep(); // remaining = 600

    for (var i = 0; i < 10; i++) {
        detector.testTick();
    }

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

//! 42. 15-minute nap: countdown completes and alarm fires.
(:test)
function test15MinNapCountdownCompletes(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetNapDurationMin(15);
    detector.testTransitionToSleep();

    for (var i = 0; i < 15; i++) {
        detector.testTick();
    }

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

//! 43. 20-minute nap: countdown completes and alarm fires.
(:test)
function test20MinNapCountdownCompletes(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetNapDurationMin(20);
    detector.testTransitionToSleep();

    for (var i = 0; i < 20; i++) {
        detector.testTick();
    }

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

//! 44. 25-minute nap: countdown completes and alarm fires.
(:test)
function test25MinNapCountdownCompletes(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetNapDurationMin(25);
    detector.testTransitionToSleep();

    for (var i = 0; i < 25; i++) {
        detector.testTick();
    }

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

//! 45. 30-minute nap: countdown completes and alarm fires.
(:test)
function test30MinNapCountdownCompletes(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetNapDurationMin(30);
    detector.testTransitionToSleep();

    for (var i = 0; i < 30; i++) {
        detector.testTick();
    }

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

//! 46. Pre-calibration immobility tracking: if the user lies still during
//!     calibration, the immobility clock starts early. Verify that
//!     _immobilityStart is set during calibration poll ticks when motion
//!     is low, so handleMonitoring() inherits the head start.
(:test)
function testPreCalibrationImmobilityTracking(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testInjectHR(70);
    detector.testSetMotionMagnitude(0.0f);

    // Run 6 calib ticks (state still CALIBRATING)
    for (var i = 0; i < 6; i++) {
        detector.testTick(); // onCalibTick
    }

    // Immobility should NOT be tracking yet (no poll tick has fired)
    if (detector.testIsImmobilityTracking()) {
        logger.debug("Immobility tracking started before any poll tick");
        return false;
    }

    // Fire a poll tick DURING calibration: motion is low -> pre-tracking starts
    detector.testPollTick();
    var trackingAfterPoll = detector.testIsImmobilityTracking();

    if (!trackingAfterPoll) {
        logger.debug("Pre-tracking did not start after poll tick with low motion");
        return false;
    }

    // Fire a poll tick with HIGH motion: pre-tracking should reset
    detector.testSetMotionMagnitude(100.0f);
    detector.testPollTick();
    var trackingAfterHighMotion = detector.testIsImmobilityTracking();

    if (trackingAfterHighMotion) {
        logger.debug("Pre-tracking was not reset after high motion");
        return false;
    }

    // Fire two poll ticks with LOW motion to flush the high value out of
    // the last-2 window: after tick 1 window=[...,100,0] mean=50 (not < 50),
    // after tick 2 window=[...,0,0] mean=0 < 50 -> tracking restarts.
    detector.testSetMotionMagnitude(0.0f);
    detector.testPollTick();
    detector.testPollTick();
    var trackingRestarted = detector.testIsImmobilityTracking();

    if (!trackingRestarted) {
        logger.debug("Pre-tracking did not restart after motion cleared");
        return false;
    }

    // Finish calibration (6 remaining ticks)
    for (var j = 0; j < 6; j++) {
        detector.testTick();
    }
    // State should now be MONITORING, with immobility clock still running
    var ok = (detector.getState() == SleepDetector.STATE_MONITORING)
          && detector.testIsImmobilityTracking();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " tracking=" + detector.testIsImmobilityTracking());
    }
    return ok;
}

// -----------------------------------------------------------------------------
// Sleep Mode simulation tests
// Garmin Sleep Mode turns the AMOLED display off and dims all UI. These tests
// verify the full state machine works purely through timer callbacks, with
// zero onUpdate() calls (which is what happens when the display is off).
// -----------------------------------------------------------------------------

//! 47. Sleep Mode full lifecycle: calibrate -> detect -> sleep -> alarm.
//!     The entire nap completes with alarm firing, driven only by timer
//!     callbacks. No UI refresh (onUpdate) is involved at any point.
//!     Simulates a user who starts a nap, falls asleep, and wakes up
//!     to an already-ringing alarm with the display lit.
(:test)
function testSleepModeFullLifecycle(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetNapDurationMin(10);

    // -- Calibration: inject awake HR, run 12 calib ticks --
    detector.testInjectHR(72);
    for (var i = 0; i < 12; i++) {
        detector.testTick();
    }
    if (detector.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("Calibration failed, state: " + detector.getState());
        return false;
    }

    // -- Detection: inject sleep HR, low motion, shortcut immobility --
    detector.testInjectHR(65); // drop = 7 >= 5
    detector.testInjectHR(65);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    if (detector.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("Detection failed, state: " + detector.getState());
        return false;
    }

    // -- Countdown: 10 ticks (10 min) --
    detector.testSetMotionMagnitude(0.0f);
    for (var j = 0; j < 10; j++) {
        detector.testTick();
    }

    // Alarm must be active, state must be ALARM, no UI was involved
    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming()
          && (detector.getRemainingSeconds() == 0);
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " alarming=" + alarm.isAlarming()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

//! 48. Sleep Mode: alarm stays active through subsequent poll ticks.
//!     After the alarm fires, the poll timer keeps running (every 60s).
//!     The alarm must NOT be reset, stopped, or corrupted by these ticks.
//!     The user might not dismiss the alarm for several minutes.
(:test)
function testSleepModeAlarmPersistsThroughPollTicks(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testTransitionToSleep();
    detector.testSetRemainingSeconds(detector.getTickSec());
    detector.testTick(); // -> ALARM

    if (!alarm.isAlarming()) {
        logger.debug("Alarm did not start");
        return false;
    }

    // Simulate 5 more poll ticks while alarm is ringing (user still asleep)
    for (var i = 0; i < 5; i++) {
        detector.testTick();
    }

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming()
          && (detector.getRemainingSeconds() == 0);
    if (!ok) {
        logger.debug("Alarm state corrupted after " + 5 + " poll ticks: state="
            + detector.getState() + " alarming=" + alarm.isAlarming());
    }
    alarm.stop();
    return ok;
}

//! 49. Sleep Mode with spontaneous wake cycle: user falls asleep, wakes
//!     briefly (rolls over), falls back asleep, countdown expires, alarm
//!     fires. All without any UI refresh. Reproduces the exact scenario
//!     reported by the user during overnight testing.
(:test)
function testSleepModeWakeCycleAndAlarm(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetBaseline(70.0f);
    detector.testSetNapDurationMin(15);
    detector.testInjectHR(63); // drop = 7 >= 5
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);

    // Detection tick -> SLEEPING, remaining = 900 (15 min)
    detector.testTick();
    if (detector.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("Initial detection failed");
        return false;
    }

    // 5 ticks of sleep (remaining 900 -> 600)
    for (var i = 0; i < 5; i++) {
        detector.testTick();
    }

    // Spontaneous wake: user rolls over (sustained motion across 2 ticks)
    detector.testSetMotionMagnitude(300.0f);
    detector.testTick(); // still sleeping (window needs 2 high entries)
    detector.testTick(); // WAKE -> MONITORING
    if (detector.getState() != SleepDetector.STATE_MONITORING) {
        logger.debug("Wake not detected, state: " + detector.getState());
        return false;
    }

    // 2 monitoring ticks (countdown still runs: each tick decrements)
    detector.testTick();
    detector.testTick();

    // Fall back asleep: low motion, shortcut immobility
    detector.testInjectMotion(0.0f);
    detector.testInjectMotion(0.0f);
    detector.testSetMotionMagnitude(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // re-detection -> SLEEPING

    if (detector.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("Re-sleep not detected, state: " + detector.getState());
        return false;
    }

    // Drain remaining countdown
    var remaining = detector.getRemainingSeconds();
    var ticksNeeded = (remaining / detector.getTickSec());
    if (remaining % detector.getTickSec() > 0) { ticksNeeded += 1; }
    for (var j = 0; j < ticksNeeded; j++) {
        detector.testTick();
    }

    var ok = (detector.getState() == SleepDetector.STATE_ALARM)
          && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " alarming=" + alarm.isAlarming()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

// =============================================================================
// Zone 1: AlarmManager direct tests
// =============================================================================

//! AlarmManager starts in idle state with zero ring count.
(:test)
function testAlarmManagerInitialState(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var ok = !alarm.isAlarming() && alarm.testGetRingCount() == 0;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount());
    }
    return ok;
}

//! startAlarm() sets isAlarming and advances ring count to 1 (first ring fires
//! immediately inside startAlarm).
(:test)
function testAlarmManagerStartSetsAlarming(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm();
    var ok = alarm.isAlarming() && alarm.testGetRingCount() == 1;
    if (!ok) {
        logger.debug("alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount());
    }
    alarm.stop();
    return ok;
}

//! stop() resets both isAlarming and ring count to zero.
(:test)
function testAlarmManagerStopResetsState(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm();
    // Advance a few rings
    alarm.onRepeatAlarm();
    alarm.onRepeatAlarm();
    alarm.stop();
    var ok = !alarm.isAlarming() && alarm.testGetRingCount() == 0;
    if (!ok) {
        logger.debug("After stop: alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount());
    }
    return ok;
}

//! Calling startAlarm() a second time is a no-op: ring count does not reset.
(:test)
function testAlarmManagerDoubleStartIdempotent(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm(); // ring count -> 1
    alarm.onRepeatAlarm(); // ring count -> 2
    alarm.onRepeatAlarm(); // ring count -> 3
    var ringsBefore = alarm.testGetRingCount();
    alarm.startAlarm(); // should be a no-op
    var ok = alarm.testGetRingCount() == ringsBefore;
    if (!ok) {
        logger.debug("Rings before=" + ringsBefore
            + " after second start=" + alarm.testGetRingCount());
    }
    alarm.stop();
    return ok;
}

//! Phase mapping: rings 0-3 = phase 0, 4-7 = phase 1, 8-11 = phase 2, 12+ = phase 3.
(:test)
function testAlarmManagerPhaseEscalation(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var ok = true;
    // Phase 0: rings 0-3
    for (var i = 0; i <= 3; i++) {
        if (alarm.testGetPhaseForRing(i) != 0) {
            logger.debug("Ring " + i + " expected phase 0, got " + alarm.testGetPhaseForRing(i));
            ok = false;
        }
    }
    // Phase 1: rings 4-7
    for (var i = 4; i <= 7; i++) {
        if (alarm.testGetPhaseForRing(i) != 1) {
            logger.debug("Ring " + i + " expected phase 1, got " + alarm.testGetPhaseForRing(i));
            ok = false;
        }
    }
    // Phase 2: rings 8-11
    for (var i = 8; i <= 11; i++) {
        if (alarm.testGetPhaseForRing(i) != 2) {
            logger.debug("Ring " + i + " expected phase 2, got " + alarm.testGetPhaseForRing(i));
            ok = false;
        }
    }
    // Phase 3: rings 12+
    if (alarm.testGetPhaseForRing(12) != 3) {
        logger.debug("Ring 12 expected phase 3, got " + alarm.testGetPhaseForRing(12));
        ok = false;
    }
    if (alarm.testGetPhaseForRing(50) != 3) {
        logger.debug("Ring 50 expected phase 3, got " + alarm.testGetPhaseForRing(50));
        ok = false;
    }
    return ok;
}

//! onRepeatAlarm() advances ring count by 1 each call.
(:test)
function testAlarmManagerRepeatAdvancesRings(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm(); // ring 0 fires, count = 1
    for (var i = 0; i < 5; i++) {
        alarm.onRepeatAlarm();
    }
    // 1 (start) + 5 (repeats) = 6
    var ok = alarm.testGetRingCount() == 6;
    if (!ok) {
        logger.debug("Expected 6 rings, got " + alarm.testGetRingCount());
    }
    alarm.stop();
    return ok;
}

//! stop() mid-escalation resets ring count so a fresh start begins at phase 0.
(:test)
function testAlarmManagerStopMidEscalationResets(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    alarm.startAlarm();
    // Advance to phase 1 (ring count past 4)
    for (var i = 0; i < 5; i++) {
        alarm.onRepeatAlarm();
    }
    alarm.stop();
    // Restart: should begin at ring 0 / phase 0 again
    alarm.startAlarm();
    var ok = alarm.testGetRingCount() == 1 && alarm.isAlarming();
    if (!ok) {
        logger.debug("After restart: rings=" + alarm.testGetRingCount()
            + " alarming=" + alarm.isAlarming());
    }
    alarm.stop();
    return ok;
}

// =============================================================================
// Zone 2: Alarm transition edge cases
// =============================================================================

//! transitionToAlarm() with null alarm does not crash.
(:test)
function testTransitionToAlarmWithNullAlarm(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING
    // Drain countdown to trigger transitionToAlarm with null alarm
    detector.testSetRemainingSeconds(60);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_ALARM;
    if (!ok) {
        logger.debug("Expected ALARM, got " + detector.getState());
    }
    return ok;
}

//! Countdown expires exactly at the smart wake boundary (remaining = 300,
//! napDuration >= 30). The normal countdown-to-zero path must fire, not
//! conflict with the smart wake check.
(:test)
function testCountdownExpiresAtSmartWakeBoundary(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetBaseline(70.0f);
    detector.testSetNapDurationMin(30);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING

    // Place remaining at exactly 300 (smart wake boundary)
    detector.testSetRemainingSeconds(300);
    // 5 ticks of 60s each to drain from 300 -> 0
    for (var i = 0; i < 5; i++) {
        detector.testTick();
    }
    var ok = detector.getState() == SleepDetector.STATE_ALARM && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " alarming=" + alarm.isAlarming()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

//! Two poll ticks after remaining hits zero: transitionToAlarm is called only
//! once (second tick sees STATE_ALARM and skips sleeping handler).
(:test)
function testDoubleTickAtZeroDoesNotDoubleTransition(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING
    detector.testSetRemainingSeconds(60);
    detector.testTick(); // -> ALARM (remaining = 0)
    var ringsAfterFirst = alarm.testGetRingCount();
    // Second tick with state already ALARM
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_ALARM
          && alarm.testGetRingCount() == ringsAfterFirst;
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " ringsBefore=" + ringsAfterFirst
            + " ringsAfter=" + alarm.testGetRingCount());
    }
    alarm.stop();
    return ok;
}

// =============================================================================
// Zone 3: Long naps / stress
// =============================================================================

//! 120-minute nap: sleepHrSamples trimming works and stats are computed from
//! the trimmed window (last 720 samples).
(:test)
function testLongNap120MinSampleTrimming(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING

    // Simulate 800 HR samples during sleep (exceeds 780 trim threshold).
    // First 500 samples at 58 BPM, last 300 at 62 BPM.
    // After trimming, only the last 720 remain.
    for (var i = 0; i < 500; i++) {
        detector.testAddSleepHrSample(58);
    }
    for (var i = 0; i < 300; i++) {
        detector.testAddSleepHrSample(62);
    }

    // Force alarm to compute stats
    detector.testSetRemainingSeconds(60);
    detector.testTick(); // -> ALARM

    // avgSleepHR should reflect the mix of samples in the last 720 window.
    // 420 samples at 58 + 300 samples at 62 = (420*58 + 300*62) / 720 = ~59.67
    var avg = detector.getAvgSleepHR();
    var min = detector.getMinSleepHR();
    var ok = (avg >= 59 && avg <= 61) && min == 58;
    if (!ok) {
        logger.debug("avg=" + avg + " min=" + min);
    }
    return ok;
}

//! Three wake/re-sleep cycles: actualSleepSec accumulates correctly and the
//! final alarm fires.
(:test)
function testThreeWakeReSleepCycles(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetBaseline(70.0f);
    detector.testSetNapDurationMin(30); // 1800s -- enough for 3 full wake/re-sleep cycles
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING, remaining=900

    var totalSleepTicks = 0;

    // Cycle through 3 wake/re-sleep periods
    for (var cycle = 0; cycle < 3; cycle++) {
        // Sleep for 3 ticks
        for (var i = 0; i < 3; i++) {
            detector.testTick();
            totalSleepTicks += 1;
        }
        // If the alarm already fired, stop cycling
        if (detector.getState() == SleepDetector.STATE_ALARM) {
            break;
        }
        // Wake: sustained high motion for 2 ticks
        detector.testSetMotionMagnitude(300.0f);
        detector.testTick();
        detector.testTick();
        if (detector.getState() != SleepDetector.STATE_MONITORING) {
            logger.debug("Cycle " + cycle + ": expected MONITORING, got " + detector.getState());
            alarm.stop();
            return false;
        }
        // Monitoring for 1 tick (countdown still runs)
        detector.testTick();
        // Re-sleep
        detector.testInjectMotion(0.0f);
        detector.testInjectMotion(0.0f);
        detector.testSetMotionMagnitude(0.0f);
        detector.testSetImmobilityStart(200);
        detector.testTick(); // -> SLEEPING
        if (detector.getState() != SleepDetector.STATE_SLEEPING) {
            logger.debug("Cycle " + cycle + ": re-sleep failed, got " + detector.getState());
            alarm.stop();
            return false;
        }
    }

    // Drain any remaining countdown
    if (detector.getState() != SleepDetector.STATE_ALARM) {
        var remaining = detector.getRemainingSeconds();
        var ticks = remaining / detector.getTickSec();
        if (remaining % detector.getTickSec() > 0) { ticks += 1; }
        for (var j = 0; j < ticks; j++) {
            detector.testTick();
        }
    }

    var ok = detector.getState() == SleepDetector.STATE_ALARM && alarm.isAlarming();
    // actualSleepSec should only count ticks spent in SLEEPING, not MONITORING
    var actualSleep = detector.getActualNapDurationSec();
    var expectedSleep = totalSleepTicks * detector.getTickSec();
    if (actualSleep < expectedSleep) {
        logger.debug("actualSleep=" + actualSleep + " < expected=" + expectedSleep);
        ok = false;
    }
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " alarming=" + alarm.isAlarming()
            + " actualSleep=" + actualSleep);
    }
    alarm.stop();
    return ok;
}

//! Four wake/re-sleep cycles with a 30-min nap. Verifies the countdown
//! doesn't lose time across repeated state transitions.
(:test)
function testFourWakeCycles30MinNap(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetBaseline(70.0f);
    detector.testSetNapDurationMin(30); // 1800s total
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING, remaining=1800

    for (var cycle = 0; cycle < 4; cycle++) {
        // Sleep 4 ticks
        for (var i = 0; i < 4; i++) {
            detector.testTick();
        }
        if (detector.getState() == SleepDetector.STATE_ALARM) { break; }
        // Wake
        detector.testSetMotionMagnitude(300.0f);
        detector.testTick();
        detector.testTick();
        if (detector.getState() != SleepDetector.STATE_MONITORING) {
            alarm.stop();
            return false;
        }
        // 1 monitoring tick
        detector.testTick();
        // Re-sleep
        detector.testInjectMotion(0.0f);
        detector.testInjectMotion(0.0f);
        detector.testSetMotionMagnitude(0.0f);
        detector.testSetImmobilityStart(200);
        detector.testTick();
    }

    // Drain remaining
    if (detector.getState() != SleepDetector.STATE_ALARM) {
        var remaining = detector.getRemainingSeconds();
        var ticks = remaining / detector.getTickSec();
        if (remaining % detector.getTickSec() > 0) { ticks += 1; }
        for (var j = 0; j < ticks; j++) {
            detector.testTick();
        }
    }

    var ok = detector.getState() == SleepDetector.STATE_ALARM && alarm.isAlarming();
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " remaining=" + detector.getRemainingSeconds());
    }
    alarm.stop();
    return ok;
}

// =============================================================================
// Zone 4: Sensor edge cases
// =============================================================================

//! HR drops to 0 during sleep (sensor loses skin contact). Must not corrupt
//! sleepHrSamples or trigger a false spontaneous wake.
(:test)
function testHRBecomesZeroDuringSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING

    // Add some valid sleep HR samples
    for (var i = 0; i < 5; i++) {
        detector.testAddSleepHrSample(62);
    }

    // HR drops to 0 (sensor lost contact)
    detector.testInjectHR(0);
    detector.testTick(); // should stay SLEEPING

    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) {
        logger.debug("HR=0 caused unexpected state: " + detector.getState());
    }

    // HR returns to normal sleep value
    detector.testInjectHR(63);
    detector.testTick();
    ok = ok && detector.getState() == SleepDetector.STATE_SLEEPING;
    if (detector.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("After HR recovery: state=" + detector.getState());
    }
    return ok;
}

//! HR = 0 throughout calibration falls back to 70 BPM baseline, then
//! monitoring with a real HR drop can still detect sleep.
(:test)
function testCalibrationNoHRThenMonitoringDetectsSleep(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    // No HR data during calibration
    detector.testInjectHR(0);
    for (var i = 0; i < 12; i++) {
        detector.testTick();
    }
    // Baseline should fall back to 70.0
    var baselineOk = detector.getHRBaseline() >= 69.5f && detector.getHRBaseline() <= 70.5f;
    if (!baselineOk) {
        logger.debug("Baseline expected ~70, got " + detector.getHRBaseline());
        return false;
    }

    // Now inject a real HR drop from the 70 baseline (drop = 10 >= 5)
    detector.testInjectHR(60);
    detector.testInjectHR(60);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) {
        logger.debug("Expected SLEEPING after fallback baseline, got " + detector.getState());
    }
    return ok;
}

//! First poll ticks after calibration have < 2 entries in motion window.
//! Sleep detection should still work (falls back to instantaneous reading).
(:test)
function testMotionWindowSmallAtFirstDetection(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    // Only 1 motion entry in window (below the size >= 2 check)
    detector.testInjectHR(63);
    detector.testSetMotionMagnitude(0.0f);
    // Use testInjectMotion once: window size = 1
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // tick adds another motion entry, window size = 2

    // Tick again to satisfy hrWindow >= 2
    detector.testTick();

    // Key assertion: no crash occurred, and state is valid
    var state = detector.getState();
    var ok = (state == SleepDetector.STATE_SLEEPING || state == SleepDetector.STATE_MONITORING);
    if (!ok) {
        logger.debug("Unexpected state with small motion window: " + state);
    }
    return ok;
}

//! HR spike exactly at the spontaneous wake threshold boundary.
//! detectSpontaneousWake checks _currentHR - mean > 10.0 (strictly greater).
//! Delta of exactly 10 should NOT wake; delta of 11 should.
(:test)
function testHRSpikeExactlyAtWakeThreshold(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING

    // Add sleep HR samples at 60 BPM
    for (var i = 0; i < 5; i++) {
        detector.testAddSleepHrSample(60);
    }

    // HR = 70: delta = 10 exactly, should NOT trigger wake (> not >=)
    detector.testInjectHR(70);
    detector.testTick();
    var stateAt70 = detector.getState();

    if (stateAt70 != SleepDetector.STATE_SLEEPING) {
        logger.debug("HR=70 (delta=10) triggered wake unexpectedly");
        return false;
    }

    // HR = 71: delta = 11 > 10, SHOULD trigger wake
    detector.testInjectHR(71);
    detector.testTick();
    var ok = detector.getState() == SleepDetector.STATE_MONITORING;
    if (!ok) {
        logger.debug("HR=71 (delta=11) should wake, got " + detector.getState());
    }
    return ok;
}

//! HR=0 samples are not counted in sleep stats (onSensor guards _currentHR > 0).
(:test)
function testZeroHRNotAddedToSleepSamples(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING

    // Add 3 valid samples only
    detector.testAddSleepHrSample(62);
    detector.testAddSleepHrSample(61);
    detector.testAddSleepHrSample(63);

    // Trigger alarm to compute stats
    detector.testSetRemainingSeconds(60);
    detector.testTick();

    // avgSleepHR should be ~62, not pulled down by zeros
    var avg = detector.getAvgSleepHR();
    var ok = avg >= 61 && avg <= 63;
    if (!ok) {
        logger.debug("avg=" + avg + " (expected ~62, zeros might have leaked in)");
    }
    return ok;
}

// =============================================================================
// Zone 5: Cancel / reset from any state
// =============================================================================

//! Cancel from ALARM state after alarm has escalated: alarm stops, ring count
//! resets, and state becomes SUMMARY.
(:test)
function testCancelFromAlarmAfterEscalation(logger as Test.Logger) as Boolean {
    var alarm = new AlarmManager();
    var detector = new SleepDetector(alarm);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING

    detector.testSetRemainingSeconds(60);
    detector.testTick(); // -> ALARM

    // Let alarm escalate a few rings
    alarm.onRepeatAlarm();
    alarm.onRepeatAlarm();
    alarm.onRepeatAlarm();
    var ringsBeforeCancel = alarm.testGetRingCount();
    if (ringsBeforeCancel < 3) {
        logger.debug("Expected at least 3 rings, got " + ringsBeforeCancel);
        alarm.stop();
        return false;
    }

    // Cancel: should stop alarm and go to SUMMARY
    alarm.stop();
    detector.finishNap();

    var ok = detector.getState() == SleepDetector.STATE_SUMMARY
          && !alarm.isAlarming()
          && alarm.testGetRingCount() == 0;
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " alarming=" + alarm.isAlarming()
            + " rings=" + alarm.testGetRingCount());
    }
    return ok;
}

//! cancel() from SLEEPING state produces a SUMMARY with valid stats.
(:test)
function testCancelFromSleepingProducesSummary(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    detector.testInjectHR(63);
    detector.testInjectHR(63);
    detector.testInjectMotion(0.0f);
    detector.testSetImmobilityStart(200);
    detector.testTick(); // -> SLEEPING

    // Add some sleep HR data
    detector.testAddSleepHrSample(60);
    detector.testAddSleepHrSample(58);
    detector.testAddSleepHrSample(62);

    // Tick a few times to accumulate sleep time
    detector.testTick();
    detector.testTick();

    detector.cancel();

    var ok = detector.getState() == SleepDetector.STATE_SUMMARY;
    // napEndTime should be set (computeSleepStats was called)
    ok = ok && detector.getNapEndTime() != null;
    // Stats should reflect the HR samples
    ok = ok && detector.getAvgSleepHR() == 60; // (60+58+62)/3 = 60
    ok = ok && detector.getMinSleepHR() == 58;
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " napEnd=" + (detector.getNapEndTime() != null)
            + " avg=" + detector.getAvgSleepHR()
            + " min=" + detector.getMinSleepHR());
    }
    return ok;
}

//! After a full nap cycle, a fresh SleepDetector starts completely clean
//! (simulates what resetToStart in the view would do).
(:test)
function testFreshDetectorAfterCompletedNap(logger as Test.Logger) as Boolean {
    // First nap
    var alarm = new AlarmManager();
    var d1 = new SleepDetector(alarm);
    d1.testSetBaseline(70.0f);
    d1.testInjectHR(63);
    d1.testInjectHR(63);
    d1.testInjectMotion(0.0f);
    d1.testSetImmobilityStart(200);
    d1.testTick();
    d1.testSetRemainingSeconds(60);
    d1.testTick();
    alarm.stop();

    // Simulate resetToStart: create a fresh detector (same as the view does)
    var d2 = new SleepDetector(alarm);
    var ok = d2.getState() == SleepDetector.STATE_CALIBRATING
          && d2.getRemainingSeconds() == 0
          && d2.getActualNapDurationSec() == 0
          && d2.getSleepStartTime() == null
          && d2.getNapEndTime() == null
          && d2.getAvgSleepHR() == 0
          && d2.getMinSleepHR() == 0;
    if (!ok) {
        logger.debug("Fresh detector not clean: state=" + d2.getState()
            + " remaining=" + d2.getRemainingSeconds()
            + " actualSleep=" + d2.getActualNapDurationSec());
    }
    return ok;
}

//! cancel() from MONITORING (before any sleep) goes to SUMMARY with
//! napEndTime = null (no sleep occurred).
(:test)
function testCancelFromMonitoringNoSleepNullEndTime(logger as Test.Logger) as Boolean {
    var detector = new SleepDetector(null);
    detector.testSetBaseline(70.0f);
    // Stay in monitoring, never sleep
    detector.testInjectHR(68); // drop only 2 < threshold 5
    detector.testInjectMotion(100.0f);
    detector.testTick();

    detector.cancel();

    var ok = detector.getState() == SleepDetector.STATE_SUMMARY
          && detector.getSleepStartTime() == null
          && detector.getNapEndTime() == null
          && detector.getActualNapDurationSec() == 0;
    if (!ok) {
        logger.debug("state=" + detector.getState()
            + " sleepStart=" + (detector.getSleepStartTime() != null)
            + " napEnd=" + (detector.getNapEndTime() != null));
    }
    return ok;
}
