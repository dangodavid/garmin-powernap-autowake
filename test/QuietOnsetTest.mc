import Toybox.Test;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Attention;

// -----------------------------------------------------------------------------
// QUIET ONSET RULE (owner, non-negotiable): nothing vibrates, sounds or lights
// up at sleep detection, at a wake episode, at re-entry, at the end of
// calibration, on sensor dropouts, or when the app comes back to the
// foreground. The only output of a nap is the alarm; the only output outside
// an alarm is the Stay Awake nudge, and never in nap mode.
//
// Every test here runs the REAL AlarmManager (alarm types 0, 1 and 2, and
// once with the tone channel forced unavailable, as on a vivoactive 5/6) and
// asserts after EVERY simulated second, until the alarm is actually due, that
// no delivery counter moved, the manager is not alarming, and its gate never
// had to refuse a call. The invariant tests (InvariantTest.mc) repeat the
// same check on random naps.
// -----------------------------------------------------------------------------

//! A fresh real manager of the given alarm type.
(:debug)
function quietAlarm(type as Number) as AlarmManager {
    var a = new AlarmManager();
    a.testSetAlarmType(type);
    a.testForceBacklightThrow(false);
    return a;
}

//! Every output counter is 0, the manager is idle and nothing was refused.
(:debug)
function quietIsSilent(a as AlarmManager) as Boolean {
    return a.testGetVibrateCount() == 0 && a.testGetToneCount() == 0 && a.testGetMelodiesStarted() == 0
        && a.testGetBacklightCount() == 0 && a.testGetNudgeCount() == 0 && a.testGetRingsFired() == 0
        && a.testGetBlockedDeliveries() == 0 && !a.isAlarming();
}

(:debug)
function quietDescribe(a as AlarmManager) as String {
    return "vib " + a.testGetVibrateCount() + " tone " + a.testGetToneCount() + " melodies "
        + a.testGetMelodiesStarted() + " bl " + a.testGetBacklightCount() + " nudge " + a.testGetNudgeCount()
        + " rings " + a.testGetRingsFired() + " blocked " + a.testGetBlockedDeliveries()
        + " alarming " + a.isAlarming();
}

//! Feed n seconds (HR, motion) and check the silence after every one of them
//! while the detector is not alarming. Returns false on the first output.
(:debug)
function quietRun(d as SleepDetector, a as AlarmManager, n as Number, hr as Number, motion as Float,
                  what as String, logger as Test.Logger) as Boolean {
    for (var i = 0; i < n; i++) {
        d.testFeedSecond(hr, motion);
        if (d.getState() == SleepDetector.STATE_ALARM) {
            return true;
        }
        if (!quietIsSilent(a)) {
            logger.debug(what + ": output at " + (d.testNowSec() - d.testGetStartSec()) + " s, state "
                + d.getState() + ": " + quietDescribe(a));
            return false;
        }
    }
    return true;
}

//! After the alarm became due: exactly one ring so far, on the right channel.
(:debug)
function quietRangOnce(d as SleepDetector, a as AlarmManager, reason as Number, what as String,
                       logger as Test.Logger) as Boolean {
    var vib = a.testGetVibrateCount();
    var tone = a.testGetToneCount();
    var ok = d.getState() == SleepDetector.STATE_ALARM && d.getAlarmReason() == reason && a.isAlarming()
        && a.testGetRingsFired() == 1 && (vib + tone >= 1) && vib <= 1 && tone <= 1
        && a.testGetBlockedDeliveries() == 0;
    if (!ok) {
        logger.debug(what + ": expected exactly one first ring (reason " + reason + "), state " + d.getState()
            + " reason " + d.getAlarmReason() + ": " + quietDescribe(a));
    }
    return ok;
}

//! 2 still minutes with a 5 BPM drop (nap 30): silent through calibration,
//! onset at 4 min and 30 minutes of sleep; one ring at the planned end.
(:test)
function testQuiet_hrDropOnsetIsSilent(logger as Test.Logger) as Boolean {
    for (var type = 0; type <= 2; type++) {
        var a = quietAlarm(type);
        var d = new SleepDetector(a);
        d.testStart();
        var what = "type " + type;
        var ok = quietRun(d, a, 2 * 60, 70, 200.0f, what + " calibration", logger)
            && quietRun(d, a, 2 * 60, 62, 10.0f, what + " onset", logger);
        if (ok && (!d.hasSleptAtLeastOnce() || d.getState() != SleepDetector.STATE_SLEEPING
            || d.testNowSec() - d.testGetStartSec() != 240)) {
            logger.debug(what + ": setup expected onset at 240 s, state " + d.getState());
            ok = false;
        }
        ok = ok && quietIsSilent(a);
        ok = ok && quietRun(d, a, 31 * 60, 58, 10.0f, what + " asleep", logger);
        ok = ok && quietRangOnce(d, a, SleepDetector.ALARM_NAP_COMPLETE, what, logger);
        if (ok && d.testNowSec() != d.testGetSleepStartSec() as Number + 30 * 60) {
            logger.debug(what + ": alarm not at onset + 30 min");
            ok = false;
        }
        a.stop();
        if (!ok) {
            return false;
        }
    }
    return true;
}

//! 5 still minutes without any HR (nap 10): silent until the planned end.
(:test)
function testQuiet_stillOnsetIsSilent(logger as Test.Logger) as Boolean {
    for (var type = 0; type <= 2; type++) {
        var a = quietAlarm(type);
        var d = new SleepDetector(a);
        d.testStart();
        d.testSetNapDurationMin(10);
        var what = "type " + type;
        var ok = quietRun(d, a, 5 * 60, 0, 10.0f, what + " still onset", logger);
        if (ok && (d.getState() != SleepDetector.STATE_SLEEPING || d.testNowSec() - d.testGetStartSec() != 300)) {
            logger.debug(what + ": setup expected onset at 300 s, state " + d.getState());
            ok = false;
        }
        ok = ok && quietRun(d, a, 11 * 60, 0, 10.0f, what + " asleep", logger)
            && quietRangOnce(d, a, SleepDetector.ALARM_NAP_COMPLETE, what, logger);
        a.stop();
        if (!ok) {
            return false;
        }
    }
    return true;
}

//! Onset, a wake episode, re-entry, then the alarm: the wake and the
//! re-entry are as silent as the onset.
(:test)
function testQuiet_wakeAndReentryAreSilent(logger as Test.Logger) as Boolean {
    for (var type = 0; type <= 2; type++) {
        var a = quietAlarm(type);
        var d = new SleepDetector(a);
        d.testStart();
        d.testSetNapDurationMin(20);
        d.testSetBaseline(70.0f);
        var what = "type " + type;
        var ok = quietRun(d, a, 5 * 60, 70, 10.0f, what + " onset", logger)
            && quietRun(d, a, 3 * 60, 58, 10.0f, what + " asleep", logger)
            && quietRun(d, a, 60, 72, 300.0f, what + " wake episode", logger);
        if (ok && (d.getWakeEpisodes() != 1 || d.getState() != SleepDetector.STATE_MONITORING)) {
            logger.debug(what + ": setup expected a wake episode, wakes " + d.getWakeEpisodes());
            ok = false;
        }
        ok = ok && quietRun(d, a, 2 * 60, 58, 10.0f, what + " re-entry", logger);
        if (ok && d.getState() != SleepDetector.STATE_SLEEPING) {
            logger.debug(what + ": setup expected re-entry, state " + d.getState());
            ok = false;
        }
        ok = ok && quietRun(d, a, 20 * 60, 58, 10.0f, what + " asleep again", logger);
        if (ok && d.getState() != SleepDetector.STATE_ALARM) {
            logger.debug(what + ": no alarm at the planned end, state " + d.getState());
            ok = false;
        }
        ok = ok && a.isAlarming() && a.testGetRingsFired() == 1 && a.testGetBlockedDeliveries() == 0;
        a.stop();
        if (!ok) {
            return false;
        }
    }
    return true;
}

//! Onset in the last minute before the deadline (nap 10, allowance 15: the
//! nap is capped to 1 minute): silent until the deadline second, then the
//! alarm starts with NAP_COMPLETE and exactly one first ring.
(:test)
function testQuiet_lateOnsetRingsOnlyAtDeadline(logger as Test.Logger) as Boolean {
    for (var type = 0; type <= 2; type++) {
        var a = quietAlarm(type);
        var d = new SleepDetector(a);
        d.testStart();
        d.testSetNapDurationMin(10);
        var deadline = d.testGetDeadlineSec();
        var what = "type " + type;
        var ok = quietRun(d, a, 20 * 60, 70, 200.0f, what + " awake", logger)
            && quietRun(d, a, 5 * 60, 70, 10.0f, what + " late onset", logger);
        if (ok && (d.getState() != SleepDetector.STATE_SLEEPING || d.testGetNapEndSec() != deadline
            || deadline - d.testNowSec() != 60)) {
            logger.debug(what + ": setup expected onset 60 s before the deadline, state " + d.getState());
            ok = false;
        }
        ok = ok && quietRun(d, a, 59, 60, 10.0f, what + " last minute", logger) && quietIsSilent(a)
            && d.getState() == SleepDetector.STATE_SLEEPING;
        if (ok) {
            d.testFeedSecond(60, 10.0f);      // the deadline second
            ok = d.testNowSec() == deadline
                && quietRangOnce(d, a, SleepDetector.ALARM_NAP_COMPLETE, what, logger);
        }
        a.stop();
        if (!ok) {
            return false;
        }
    }
    return true;
}

//! The end of calibration, minutes without HR and minutes without any
//! accelerometer data produce no output; the deadline alarm rings once.
(:test)
function testQuiet_calibrationAndDropoutsAreSilent(logger as Test.Logger) as Boolean {
    for (var type = 0; type <= 2; type++) {
        var a = quietAlarm(type);
        var d = new SleepDetector(a);
        d.testStart();
        d.testSetNapDurationMin(5);
        var what = "type " + type;
        var ok = quietRun(d, a, 2 * 60 + 1, 70, 200.0f, what + " calibration end", logger)
            && d.getState() == SleepDetector.STATE_MONITORING
            && quietRun(d, a, 2 * 60, 0, 200.0f, what + " no HR", logger);
        // Two minutes without any accelerometer batch (HR only).
        for (var s = 0; s < 120 && ok; s++) {
            d.testFeedHR(65);
            d.testTick();
            if (!quietIsSilent(a)) {
                logger.debug(what + " no accelerometer: " + quietDescribe(a));
                ok = false;
            }
        }
        ok = ok && d.getStillMinutes() == 0 && d.getState() == SleepDetector.STATE_MONITORING;
        ok = ok && quietRun(d, a, 20 * 60, 65, 200.0f, what + " until the deadline", logger)
            && quietRangOnce(d, a, SleepDetector.ALARM_DEADLINE, what, logger)
            && !d.hasSleptAtLeastOnce();
        a.stop();
        if (!ok) {
            return false;
        }
    }
    return true;
}

//! Returning to the foreground right after onset (and after being hidden)
//! with no alarm due never rings.
(:test)
function testQuiet_resumeAfterOnsetIsSilent(logger as Test.Logger) as Boolean {
    for (var type = 0; type <= 2; type++) {
        var a = quietAlarm(type);
        var d = new SleepDetector(a);
        d.testStart();
        d.testSetBaseline(70.0f);
        var what = "type " + type;
        var ok = quietRun(d, a, 5 * 60, 70, 10.0f, what + " onset", logger)
            && d.getState() == SleepDetector.STATE_SLEEPING;
        Lifecycle.resume(d, a);
        d.noteInactive();
        d.testAdvanceClock(30);
        Lifecycle.resume(d, a);
        d.onResume();
        if (ok && (!quietIsSilent(a) || d.getState() != SleepDetector.STATE_SLEEPING)) {
            logger.debug(what + ": resume after onset rang: " + quietDescribe(a));
            ok = false;
        }
        ok = ok && quietRun(d, a, 60, 58, 10.0f, what + " after resume", logger);
        a.stop();
        d.stop();
        if (!ok) {
            return false;
        }
    }
    return true;
}

//! Nap mode never nudges: 3, 4 and 5 still minutes (the Stay Awake nudge
//! point is 3) leave the nudge counter at 0 and the gate untouched.
(:test)
function testQuiet_napModeNeverNudges(logger as Test.Logger) as Boolean {
    var a = quietAlarm(0);
    var d = new SleepDetector(a);
    d.testStart();
    d.testSetBaseline(70.0f);
    var ok = true;
    for (var m = 1; m <= 5 && ok; m++) {
        ok = quietRun(d, a, 60, 70, 10.0f, "still minute " + m, logger);
        if (ok && d.getStillMinutes() != m && d.getState() != SleepDetector.STATE_SLEEPING) {
            logger.debug("setup: still minutes " + d.getStillMinutes() + " after " + m);
            ok = false;
        }
        if (a.testGetNudgeCount() != 0 || d.isDozeWarning()) {
            logger.debug("nap mode nudged after " + m + " still minutes");
            ok = false;
        }
    }
    ok = ok && d.getState() == SleepDetector.STATE_SLEEPING && quietIsSilent(a);
    // The manager refuses a nudge in a nap session even if asked directly.
    a.nudge();
    if (a.testGetNudgeCount() != 0 || a.testGetVibrateCount() != 0 || a.testGetBlockedDeliveries() != 1) {
        logger.debug("a direct nudge in a nap session must be refused: " + quietDescribe(a));
        ok = false;
    }
    a.stop();
    return ok;
}

//! Through the real delegate and view: START on the start screen, a peek
//! press during the nap, onset and the whole nap are silent; the alarm rings
//! once when due. Also with the tone channel unavailable (vivoactive 5/6).
(:test)
function testQuiet_delegateNapIsSilentUntilAlarm(logger as Test.Logger) as Boolean {
    for (var variant = 0; variant < 4; variant++) {
        var r = new DelegateRig(10);
        r.alarm.testSetAlarmType((variant < 3) ? variant : AlarmManager.ALARM_BOTH);
        if (variant == 3) {
            r.alarm.testForceChannelsUnavailable(false, true);
        }
        r.alarm.testForceBacklightThrow(false);
        r.key(WatchUi.KEY_ENTER);
        var d = r.detector;
        var a = r.alarm;
        var what = "variant " + variant;
        var ok = r.view.isStarted() && quietIsSilent(a)
            && quietRun(d, a, 2 * 60, 70, 200.0f, what + " calibration", logger);
        r.key(WatchUi.KEY_UP);                   // peek: no output either
        ok = ok && r.view.isPeeking() && quietIsSilent(a)
            && quietRun(d, a, 5 * 60, 70, 10.0f, what + " onset", logger)
            && d.getState() == SleepDetector.STATE_SLEEPING
            && quietRun(d, a, 11 * 60, 58, 10.0f, what + " asleep", logger)
            && quietRangOnce(d, a, SleepDetector.ALARM_NAP_COMPLETE, what, logger);
        if (ok && variant == 3 && a.testGetVibrateCount() != 1) {
            logger.debug(what + ": without tones the first ring must vibrate");
            ok = false;
        }
        r.cleanup();
        if (!ok) {
            return false;
        }
    }
    return true;
}
