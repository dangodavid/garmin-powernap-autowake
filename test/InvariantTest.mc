import Toybox.Test;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Application;

// -----------------------------------------------------------------------------
// Invariant ("property") tests with seeded random naps, plus negative tests.
//
// Each random nap draws its settings (nap 5-45 min, allowance 5-30 min,
// sensitivity, HR drop threshold) and a minute-by-minute story from a small
// Markov model (awake -> drowsy -> asleep, with wakes, stirs, HR dropouts and
// minutes without accelerometer data). After EVERY simulated second a
// checker asserts the rules that must hold whatever the sensors say:
//   * the alarm always fires, never later than the deadline;
//   * DEADLINE only without onset and exactly at the deadline;
//   * NAP_COMPLETE exactly at min(onset + nap, deadline), which never moves;
//   * SMART_WAKE only on a minute boundary inside the window of a nap whose
//     effective length is >= 15 min;
//   * calibration ends exactly at 120 s; only valid state transitions;
//   * time asleep never exceeds the time since onset, percentages 0-100,
//     never more wake episodes than minutes;
//   * Stay Awake: never sleeps, only ALARM_DOZE, on a minute boundary after
//     >= 2 still minutes, one doze per alarm;
//   * quiet onset: the real AlarmManager never vibrates, sounds or lights
//     up while the detector is not in STATE_ALARM (the Stay Awake nudge at
//     3 still minutes excepted), and its gate never had to refuse a call.
// A failure prints the seed and settings, so the case can be replayed.
// The seeds are fixed: the same numbers run on every device and every run.
// -----------------------------------------------------------------------------

//! Deterministic pseudo-random numbers (LCG), identical on every device.
(:debug)
class InvRng {
    private var _s as Long;

    function initialize(seed as Number) {
        _s = seed.toLong();
    }

    //! 0 <= result < bound
    function next(bound as Number) as Number {
        _s = (_s * 1103515245l + 12345l) % 2147483648l;
        return ((_s / 65536l) % bound.toLong()).toNumber();
    }

    //! lo <= result <= hi
    function range(lo as Number, hi as Number) as Number {
        return lo + next(hi - lo + 1);
    }
}

//! Checks the invariants after every simulated second.
(:debug)
class InvChecker {
    var failure as String? = null;
    var alarms as Number = 0;
    private var _stay as Boolean;
    private var _prevState as Number;
    private var _napEnd as Number = 0;
    private var _context as String;
    private var _alarm as AlarmManager?;
    private var _outputs as Number = 0;       // vibrations + tones + backlight requests seen so far
    private var _nudges as Number = 0;

    function initialize(d as SleepDetector, a as AlarmManager?, context as String) {
        _stay = d.isStayAwake();
        _prevState = d.getState();
        _context = context;
        _alarm = a;
        syncOutputs();
    }

    //! After a dismissed Stay Awake alarm (ALARM -> MONITORING is valid there).
    function resync(d as SleepDetector) as Void {
        _prevState = d.getState();
        syncOutputs();
    }

    private function outputCount() as Number {
        var a = _alarm as AlarmManager;
        return a.testGetVibrateCount() + a.testGetToneCount() + a.testGetBacklightCount();
    }

    private function syncOutputs() as Void {
        if (_alarm != null) {
            _outputs = outputCount();
            _nudges = (_alarm as AlarmManager).testGetNudgeCount();
        }
    }

    //! Quiet onset: outside STATE_ALARM no vibration, tone or backlight, the
    //! manager is not alarming, and the gate never had to refuse a call. In
    //! Stay Awake one nudge is allowed per still run, while the drowsiness
    //! warning shows.
    private function checkQuiet(d as SleepDetector, st as Number, t as Number) as Boolean {
        if (_alarm == null) {
            return true;
        }
        var a = _alarm as AlarmManager;
        if (a.testGetBlockedDeliveries() != 0) {
            return fail("the alarm manager had to refuse an output call at " + t + " s");
        }
        if (st == SleepDetector.STATE_ALARM) {
            syncOutputs();
            return true;
        }
        if (a.isAlarming()) {
            return fail("manager alarming while state " + st + " at " + t + " s");
        }
        var out = outputCount();
        var nudges = a.testGetNudgeCount();
        if (nudges != _nudges) {
            if (!_stay || nudges != _nudges + 1 || !d.isDozeWarning() || d.getStillMinutes() != 3
                || out > _outputs + 2) {
                return fail("unexpected nudge at " + t + " s (state " + st + ")");
            }
            syncOutputs();
        } else if (out != _outputs) {
            return fail("alarm output while not alarming at " + t + " s (state " + st + ")");
        }
        return true;
    }

    function fail(msg as String) as Boolean {
        if (failure == null) {
            failure = _context + ": " + msg;
        }
        return false;
    }

    function check(d as SleepDetector) as Boolean {
        var st = d.getState();
        var now = d.testNowSec();
        var t = now - d.testGetStartSec();
        if (!validTransition(_prevState, st)) {
            return fail("transition " + _prevState + " -> " + st + " at " + t + " s");
        }
        if (!checkQuiet(d, st, t)) {
            return false;
        }
        if (st == SleepDetector.STATE_CALIBRATING && t >= 120) {
            return fail("still calibrating at " + t + " s");
        }
        if (_prevState == SleepDetector.STATE_CALIBRATING && st == SleepDetector.STATE_MONITORING && t != 120) {
            return fail("calibration ended at " + t + " s");
        }
        var sleepStart = d.testGetSleepStartSec();
        if (_stay) {
            if (st == SleepDetector.STATE_SLEEPING || sleepStart != null) {
                return fail("Stay Awake recorded sleep at " + t + " s");
            }
            if (st == SleepDetector.STATE_ALARM && _prevState != SleepDetector.STATE_ALARM) {
                alarms += 1;
                if (d.getAlarmReason() != SleepDetector.ALARM_DOZE) {
                    return fail("Stay Awake alarm reason " + d.getAlarmReason());
                }
                if (d.testGetSecInMinute() != 0) {
                    return fail("doze alarm off a minute boundary at " + t + " s");
                }
                if (d.getStillMinutes() < 2) {
                    return fail("doze after " + d.getStillMinutes() + " still minutes");
                }
                if (d.getDozeCount() != alarms) {
                    return fail("dozes " + d.getDozeCount() + " vs alarms " + alarms);
                }
            }
        } else {
            var deadline = d.testGetDeadlineSec();
            if (d.isActiveState() && now >= deadline) {
                return fail("still active at the deadline (" + t + " s)");
            }
            if (sleepStart != null) {
                var napEnd = d.testGetNapEndSec();
                var expected = (sleepStart as Number) + d.getNapDurationMin() * 60;
                if (expected > deadline) {
                    expected = deadline;
                }
                if (napEnd != expected) {
                    return fail("planned end " + (napEnd - d.testGetStartSec()) + " s, expected "
                        + (expected - d.testGetStartSec()));
                }
                if (_napEnd != 0 && napEnd != _napEnd) {
                    return fail("planned end moved");
                }
                _napEnd = napEnd;
            }
            if (st == SleepDetector.STATE_ALARM && _prevState != SleepDetector.STATE_ALARM) {
                alarms += 1;
                var reason = d.getAlarmReason();
                if (reason == SleepDetector.ALARM_DEADLINE) {
                    if (sleepStart != null || now != deadline) {
                        return fail("deadline alarm at " + t + " s");
                    }
                } else if (reason == SleepDetector.ALARM_NAP_COMPLETE) {
                    if (sleepStart == null || now != d.testGetNapEndSec()) {
                        return fail("nap-complete alarm at " + t + " s");
                    }
                } else if (reason == SleepDetector.ALARM_SMART_WAKE) {
                    if (sleepStart == null) {
                        return fail("smart wake without onset");
                    }
                    var end = d.testGetNapEndSec();
                    if (now >= end || end - now > d.getSmartWakeWindowSec()
                        || end - (sleepStart as Number) < 900 || d.testGetSecInMinute() != 0) {
                        return fail("smart wake " + (end - now) + " s before the end at " + t + " s");
                    }
                } else {
                    return fail("unexpected alarm reason " + reason);
                }
            }
        }
        var slept = d.getActualNapDurationSec();
        if (slept < 0 || (sleepStart == null && slept != 0)
            || (sleepStart != null && slept > now - (sleepStart as Number))) {
            return fail("time asleep " + slept + " s out of range at " + t + " s");
        }
        var c = d.getPlannedCompletionPct();
        var e = d.getSleepEfficiencyPct();
        if (c < 0 || c > 100 || e < 0 || e > 100) {
            return fail("percentages " + c + "/" + e);
        }
        if (d.getWakeEpisodes() > d.testGetMinutesCompleted()) {
            return fail("more wake episodes than minutes");
        }
        _prevState = st;
        return true;
    }

    private function validTransition(from as Number, to as Number) as Boolean {
        if (from == to) {
            return true;
        }
        if (to == SleepDetector.STATE_ALARM) {
            return from != SleepDetector.STATE_SUMMARY;
        }
        if (from == SleepDetector.STATE_CALIBRATING) {
            return to == SleepDetector.STATE_MONITORING;
        }
        if (from == SleepDetector.STATE_MONITORING) {
            return to == SleepDetector.STATE_SLEEPING;
        }
        if (from == SleepDetector.STATE_SLEEPING) {
            return to == SleepDetector.STATE_MONITORING;
        }
        return false;
    }
}

// Story model -------------------------------------------------------------

//! Next mode: 0 awake, 1 drowsy, 2 asleep.
(:debug)
function invNextMode(rng as InvRng, mode as Number) as Number {
    var r = rng.next(100);
    if (mode == 0) {
        return (r < 30) ? 1 : 0;
    }
    if (mode == 1) {
        if (r < 35) { return 2; }
        if (r < 50) { return 0; }
        return 1;
    }
    if (r < 5) { return 1; }
    if (r < 10) { return 0; }
    return 2;
}

//! Minute behaviour: 0 still, 1 micro (1-5 active s), 2 stir (6-9 s),
//! 3 wake (10-30 s), 4 restless (all 60 s), 5 no accelerometer data.
(:debug)
function invBehaviour(rng as InvRng, mode as Number) as Number {
    var r = rng.next(100);
    if (mode == 0) {
        if (r < 10) { return 0; }
        if (r < 20) { return 1; }
        if (r < 40) { return 2; }
        if (r < 70) { return 3; }
        return 4;
    }
    if (mode == 1) {
        if (r < 50) { return 0; }
        if (r < 80) { return 1; }
        if (r < 95) { return 2; }
        return 3;
    }
    if (r < 74) { return 0; }
    if (r < 89) { return 1; }
    if (r < 95) { return 2; }
    if (r < 98) { return 3; }
    return 5;
}

(:debug)
function invHr(rng as InvRng, mode as Number, base as Number) as Number {
    if (rng.next(100) < 3) {
        return 0;                                   // dropout
    }
    if (mode == 0) { return base + 8 + rng.next(7); }
    if (mode == 1) { return base - 2 + rng.next(6); }
    return base - 6 - rng.next(7);
}

//! Feed one minute second by second, checking after every second. Returns
//! early (true) as soon as the detector leaves the active states.
(:debug)
function invFeedMinute(d as SleepDetector, rng as InvRng, behaviour as Number, hr as Number,
                       checker as InvChecker) as Boolean {
    var active = 0;
    var aLo = 0;
    var aHi = 0;
    var lo = 2;
    var hi = 20;
    if (behaviour == 1) { active = rng.range(1, 5); aLo = 60; aHi = 300; }
    else if (behaviour == 2) { active = rng.range(6, 9); aLo = 100; aHi = 300; }
    else if (behaviour == 3) { active = rng.range(10, 30); aLo = 150; aHi = 400; lo = 5; hi = 30; }
    else if (behaviour == 4) { active = 60; aLo = 110; aHi = 300; }
    var offset = rng.next(60 - active + 1);
    for (var s = 0; s < 60; s++) {
        if (!d.isActiveState()) {
            return true;
        }
        if (hr > 0) {
            d.testFeedHR(hr);
        }
        if (behaviour != 5) {
            var inBurst = (s >= offset && s < offset + active);
            var m = inBurst ? rng.range(aLo, aHi) : rng.range(lo, hi);
            d.testFeedMotionSecond(m.toFloat());
        }
        d.testTick();
        if (!checker.check(d)) {
            return false;
        }
    }
    return true;
}

//! Real alarm manager (vibration) for the quiet onset invariant.
(:debug)
function invAlarm() as AlarmManager {
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
    return a;
}

//! One random nap from start to its alarm and summary.
(:debug)
function invRunNap(seed as Number, logger as Test.Logger) as Boolean {
    var rng = new InvRng(seed);
    var naps = [5, 10, 15, 20, 30, 45] as Array<Number>;
    var allowances = [5, 10, 15, 30] as Array<Number>;
    var thresholds = [30, 50, 80] as Array<Number>;
    var drops = [3, 5, 10] as Array<Number>;
    var nap = naps[rng.next(naps.size())];
    var allow = allowances[rng.next(allowances.size())];
    var thr = thresholds[rng.next(thresholds.size())];
    var drop = drops[rng.next(drops.size())];

    var a = invAlarm();
    var d = new SleepDetector(a);
    d.testStart();
    d.testSetNapDurationMin(nap);
    d.testSetFallAsleepAllowanceMin(allow);
    d.testSetMotionThreshold(thr.toFloat());
    d.testSetHrDropThreshold(drop);
    var ctx = "seed " + seed + " nap " + nap + " allowance " + allow + " mg " + thr + " bpm " + drop;
    var checker = new InvChecker(d, a, ctx);

    var base = rng.range(55, 80);
    var mode = 0;
    var minutes = 0;
    var limit = allow + nap + 2;
    while (d.isActiveState() && minutes < limit) {
        mode = invNextMode(rng, mode);
        if (!invFeedMinute(d, rng, invBehaviour(rng, mode), invHr(rng, mode, base), checker)) {
            logger.debug("" + checker.failure);
            a.stop();
            return false;
        }
        minutes += 1;
    }
    if (d.getState() != SleepDetector.STATE_ALARM || checker.alarms != 1) {
        logger.debug(ctx + ": no alarm by the deadline, state " + d.getState());
        a.stop();
        return false;
    }
    if (!a.isAlarming() || a.testGetRingsFired() != 1 || a.testGetVibrateCount() != 1) {
        logger.debug(ctx + ": the alarm must have rung exactly once at its start, rings "
            + a.testGetRingsFired() + " vib " + a.testGetVibrateCount());
        a.stop();
        return false;
    }
    var alarmAt = d.testNowSec();
    d.testAdvanceClock(rng.range(0, 90));        // the user needs a moment
    a.stop();
    d.finishNap();
    var end = d.getNapEndTime();
    if (d.getState() != SleepDetector.STATE_SUMMARY || end == null || (end as Time.Moment).value() != alarmAt
        || d.testIsRunning()) {
        logger.debug(ctx + ": summary must keep the alarm time as the end");
        return false;
    }
    if (d.hasSleptAtLeastOnce() != (d.getAlarmReason() != SleepDetector.ALARM_DEADLINE)) {
        logger.debug(ctx + ": onset flag and alarm reason disagree");
        return false;
    }
    return true;
}

//! One random Stay Awake session of `minutes` minutes; every doze alarm is
//! dismissed after a few seconds, like a user who wakes up.
(:debug)
function invRunStayAwake(seed as Number, minutes as Number, logger as Test.Logger) as Boolean {
    var rng = new InvRng(seed);
    var thresholds = [30, 50, 80] as Array<Number>;
    var drops = [3, 5, 10] as Array<Number>;
    var thr = thresholds[rng.next(thresholds.size())];
    var drop = drops[rng.next(drops.size())];
    var a = invAlarm();
    var d = new SleepDetector(a);
    d.testStartStayAwake();
    d.testSetMotionThreshold(thr.toFloat());
    d.testSetHrDropThreshold(drop);
    var ctx = "stay seed " + seed + " mg " + thr + " bpm " + drop;
    var checker = new InvChecker(d, a, ctx);
    var base = rng.range(58, 85);
    var mode = 0;
    for (var m = 0; m < minutes; m++) {
        if (d.getState() == SleepDetector.STATE_ALARM) {
            var wait = rng.range(1, 40);
            for (var s = 0; s < wait; s++) {
                d.testTick();
            }
            a.stop();                                // as the delegate does on dismissal
            d.dismissAlarm();
            checker.resync(d);
            mode = 0;                                // the alarm woke the user
        }
        mode = invNextMode(rng, mode);
        if (!invFeedMinute(d, rng, invBehaviour(rng, mode), invHr(rng, mode, base), checker)) {
            logger.debug("" + checker.failure);
            a.stop();
            return false;
        }
    }
    a.stop();
    d.cancel();
    if (d.getState() != SleepDetector.STATE_SUMMARY || d.getDozeCount() != checker.alarms
        || d.hasSleptAtLeastOnce()) {
        logger.debug(ctx + ": summary dozes " + d.getDozeCount() + " vs alarms " + checker.alarms);
        return false;
    }
    return true;
}

// Random naps (split into several tests to stay far from the watchdog) ----

(:test)
function testInv_randomNapsA(logger as Test.Logger) as Boolean {
    for (var seed = 1; seed <= 6; seed++) {
        if (!invRunNap(seed, logger)) { return false; }
    }
    return true;
}

(:test)
function testInv_randomNapsB(logger as Test.Logger) as Boolean {
    for (var seed = 101; seed <= 106; seed++) {
        if (!invRunNap(seed, logger)) { return false; }
    }
    return true;
}

(:test)
function testInv_randomNapsC(logger as Test.Logger) as Boolean {
    for (var seed = 2001; seed <= 2006; seed++) {
        if (!invRunNap(seed, logger)) { return false; }
    }
    return true;
}

(:test)
function testInv_randomNapsD(logger as Test.Logger) as Boolean {
    for (var seed = 30001; seed <= 30006; seed++) {
        if (!invRunNap(seed, logger)) { return false; }
    }
    return true;
}

(:test)
function testInv_randomStayAwakeA(logger as Test.Logger) as Boolean {
    for (var seed = 7; seed <= 9; seed++) {
        if (!invRunStayAwake(seed, 45, logger)) { return false; }
    }
    return true;
}

(:test)
function testInv_randomStayAwakeB(logger as Test.Logger) as Boolean {
    for (var seed = 707; seed <= 709; seed++) {
        if (!invRunStayAwake(seed, 45, logger)) { return false; }
    }
    return true;
}

// Negative tests -----------------------------------------------------------

//! Absurd HR values (1, 255, dropouts) and garbage motion never break the
//! guarantee: a 10 min nap still rings by its deadline.
(:test)
function testInv_absurdSensorValuesStillRing(logger as Test.Logger) as Boolean {
    var a = invAlarm();
    var d = new SleepDetector(a);
    d.testStart();
    d.testSetNapDurationMin(10);
    var checker = new InvChecker(d, a, "absurd values");
    var hrs = [255, 1, 0, 250, 30, 0] as Array<Number>;
    var motions = [0.0f, 5000.0f, 0.0f, 0.0f, 1.0e6f, 3.0f] as Array<Float>;
    var i = 0;
    while (d.isActiveState() && i < 40 * 60) {
        d.testFeedSecond(hrs[i % hrs.size()], motions[i % motions.size()]);
        if (!checker.check(d)) {
            logger.debug("" + checker.failure);
            a.stop();
            return false;
        }
        i += 1;
    }
    a.stop();
    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("no alarm, state " + d.getState());
        return false;
    }
    return true;
}

//! Minutes without any accelerometer data are never still: no onset, the
//! deadline alarm rings (dead accelerometer).
(:test)
function testInv_noAccelerometerRingsAtDeadline(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(5);
    var deadline = d.testGetDeadlineSec();
    while (d.isActiveState() && d.testNowSec() < deadline + 5) {
        d.testFeedHR(55);
        d.testTick();
    }
    var ok = d.getState() == SleepDetector.STATE_ALARM && d.getAlarmReason() == SleepDetector.ALARM_DEADLINE
        && d.testNowSec() == deadline && !d.hasSleptAtLeastOnce();
    if (!ok) {
        logger.debug("state " + d.getState() + " reason " + d.getAlarmReason());
    }
    return ok;
}

//! A wall clock stepping back 10 minutes mid-nap (time sync) does not crash,
//! never rings early, and rings when the clock reaches the planned end again.
(:test)
function testInv_clockStepBackNeverRingsEarly(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(10);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    var napEnd = d.testGetNapEndSec();
    d.testRunMinutes(5, 55, 10.0f);
    d.testAdvanceClock(-600);
    var guard = 0;
    while (d.isActiveState() && guard < 3600) {
        d.testFeedSecond(55, 10.0f);
        if (d.isActiveState() == false && d.testNowSec() < napEnd) {
            logger.debug("rang " + (napEnd - d.testNowSec()) + " s early");
            return false;
        }
        guard += 1;
    }
    var ok = d.getState() == SleepDetector.STATE_ALARM && d.testNowSec() == napEnd;
    if (!ok) {
        logger.debug("state " + d.getState() + " at " + (d.testNowSec() - napEnd) + " s from the end");
    }
    return ok;
}

//! Lifecycle calls in every state are safe and never resurrect a nap:
//! onResume, noteInactive, loadSettings, dismissAlarm, cancel, finishNap,
//! repeated.
(:test)
function testInv_lifecycleCallsInEveryStateAreSafe(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.onResume();
    d.loadSettings();
    var ok = d.getState() == SleepDetector.STATE_CALIBRATING;
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.onResume();
    d.loadSettings();
    ok = ok && d.getState() == SleepDetector.STATE_SLEEPING && d.getNapDurationMin() == 30;
    d.testAdvanceClock(31 * 60);
    d.onResume();
    ok = ok && d.getState() == SleepDetector.STATE_ALARM;
    d.onResume();
    d.noteInactive();
    ok = ok && d.getState() == SleepDetector.STATE_ALARM && !d.wasInactiveDuringNap();
    d.dismissAlarm();
    ok = ok && d.getState() == SleepDetector.STATE_SUMMARY && !d.testIsRunning();
    d.dismissAlarm();
    d.cancel();
    d.finishNap();
    d.onResume();
    d.testTick();
    ok = ok && d.getState() == SleepDetector.STATE_SUMMARY && !d.isCancelled()
        && d.getAlarmReason() == SleepDetector.ALARM_NAP_COMPLETE;
    if (!ok) {
        logger.debug("state " + d.getState() + " cancelled " + d.isCancelled());
    }
    return ok;
}

//! Stored settings of the wrong type (a string where a number belongs) are
//! ignored: the detector keeps its defaults instead of crashing.
(:test)
function testInv_wrongTypeSettingsIgnored(logger as Test.Logger) as Boolean {
    var nap0 = Application.Properties.getValue("napDuration");
    var hr0 = Application.Properties.getValue("hrDropThreshold");
    var ok = true;
    var stored = false;
    try {
        Application.Properties.setValue("napDuration", "forty");
        Application.Properties.setValue("hrDropThreshold", 3.5f);
        stored = true;
    } catch (e instanceof Lang.Exception) {
        // The system refuses the wrong type: that state cannot happen at all.
    }
    if (stored) {
        var d = new SleepDetector(null);
        d.testStartKeepSettings();
        ok = d.getNapDurationMin() == 30 && d.testGetHrDropThreshold() == 5;
        if (!ok) {
            logger.debug("wrong types changed settings: " + d.getNapDurationMin() + " / " + d.testGetHrDropThreshold());
        }
    }
    try {
        Application.Properties.setValue("napDuration", (nap0 != null) ? nap0 as Number : 30);
        Application.Properties.setValue("hrDropThreshold", (hr0 != null) ? hr0 as Number : 5);
    } catch (e instanceof Lang.Exception) {
    }
    return ok;
}
