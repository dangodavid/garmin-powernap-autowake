import Toybox.Test;
import Toybox.Lang;
import Toybox.Time;
import Toybox.Attention;
import Toybox.Application;

// -----------------------------------------------------------------------------
// Regression tests for the second review round.
//
// Each test pins one confirmed finding: HR-plateau wake ping-pong, the sleep
// HR mean fold exclusion, frozen settings and clamping, app lifecycle
// (inactive/active), alarm channel fallback, per-phase vibration patterns,
// ringNow(), and the two-press ConfirmPress guard. The detector clock is
// frozen by testStart(), so every value is exact.
// -----------------------------------------------------------------------------

//! Detector already asleep with the default settings: nap napMin, baseline 70.
(:debug)
function regHelperAsleep(napMin as Number) as SleepDetector {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(napMin);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    return d;
}

//! Restore the four detector properties (tests below write them).
(:debug)
function regHelperRestoreProps(nap as Object?, allowance as Object?, hr as Object?, sens as Object?) as Void {
    try {
        Application.Properties.setValue("napDuration", (nap != null) ? nap as Number : 30);
        Application.Properties.setValue("fallAsleepAllowance", (allowance != null) ? allowance as Number : 15);
        Application.Properties.setValue("hrDropThreshold", (hr != null) ? hr as Number : 5);
        Application.Properties.setValue("motionSensitivity", (sens != null) ? sens as Number : 1);
    } catch (e instanceof Lang.Exception) {
        // best effort
    }
}

// ── HR wake behaviour ───────────────────────────────────────────────────────

//! A motionless sleeper whose HR settles 15 BPM above the first sleeping
//! minutes produces ONE wake episode, not a wake every 4 minutes: the sleep
//! HR mean restarts on re-entry. The nap ends with an alarm, never silence.
(:test)
function testReg_hrPlateauWhileStillIsOneWake(logger as Test.Logger) as Boolean {
    var d = regHelperAsleep(30);
    d.testRunMinutes(3, 55, 10.0f);
    var minutes = 3;
    while (d.isActiveState() && minutes < 40) {
        d.testRunMinutes(1, 70, 10.0f);
        minutes += 1;
    }
    var ok = true;
    if (d.getState() != SleepDetector.STATE_ALARM) {
        logger.debug("expected ALARM at the end, got " + d.getState());
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("expected exactly 1 wake episode, got " + d.getWakeEpisodes());
        ok = false;
    }
    var reason = d.getAlarmReason();
    if (reason != SleepDetector.ALARM_NAP_COMPLETE && reason != SleepDetector.ALARM_SMART_WAKE) {
        logger.debug("unexpected alarm reason " + reason);
        ok = false;
    }
    return ok;
}

//! Elevated minutes are not folded into the sleep HR mean, and the rule is
//! ">= 10 BPM": 2 min at 55 then 65, 65 -> wake on the second 65 minute.
//! (With the fold, the mean would become 58.3 and the second rise only 6.7.)
(:test)
function testReg_hrRiseFoldExclusionAtTenBpm(logger as Test.Logger) as Boolean {
    var d = regHelperAsleep(30);
    d.testRunMinutes(2, 55, 10.0f);
    d.testRunMinutes(1, 65, 10.0f);
    var ok = true;
    if (d.getState() != SleepDetector.STATE_SLEEPING || d.getWakeEpisodes() != 0) {
        logger.debug("first +10 minute must not wake yet, state " + d.getState());
        ok = false;
    }
    d.testRunMinutes(1, 65, 10.0f);
    if (d.getState() != SleepDetector.STATE_MONITORING || d.getWakeEpisodes() != 1) {
        logger.debug("second +10 minute must wake, state " + d.getState() + " wakes " + d.getWakeEpisodes());
        ok = false;
    }
    if (d.getStillMinutes() != 0) {
        logger.debug("still minutes must restart after a wake, got " + d.getStillMinutes());
        ok = false;
    }
    // 3 minutes asleep; the wake minute itself counts as awake.
    if (d.getActualNapDurationSec() != 180) {
        logger.debug("actual sleep expected 180 s, got " + d.getActualNapDurationSec());
        ok = false;
    }
    return ok;
}

//! +9 BPM for two minutes never wakes (boundary just below the rule).
(:test)
function testReg_hrRiseNineBpmDoesNotWake(logger as Test.Logger) as Boolean {
    var d = regHelperAsleep(30);
    d.testRunMinutes(2, 55, 10.0f);
    d.testRunMinutes(2, 64, 10.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING || d.getWakeEpisodes() != 0) {
        logger.debug("+9 BPM must not wake, state " + d.getState());
        return false;
    }
    return true;
}

// ── Settings ────────────────────────────────────────────────────────────────

//! Settings changed from the phone during a nap do not touch it; they apply
//! to the next nap.
(:test)
function testReg_settingsFrozenDuringNap(logger as Test.Logger) as Boolean {
    var nap0 = Application.Properties.getValue("napDuration");
    var alw0 = Application.Properties.getValue("fallAsleepAllowance");
    var hr0 = Application.Properties.getValue("hrDropThreshold");
    var sens0 = Application.Properties.getValue("motionSensitivity");
    var ok = true;
    try {
        var d = new SleepDetector(null);
        d.testStart();
        var start = d.testGetStartSec();
        Application.Properties.setValue("napDuration", 60);
        Application.Properties.setValue("fallAsleepAllowance", 30);
        d.loadSettings();
        if (d.getNapDurationMin() != 30 || d.getFallAsleepAllowanceMin() != 15
            || d.testGetDeadlineSec() != start + 45 * 60) {
            logger.debug("running nap must keep 30/15 and its deadline");
            ok = false;
        }
        d.testSetBaseline(70.0f);
        d.testForceSleep();
        if (d.testGetNapEndSec() != d.testNowSec() + 1800) {
            logger.debug("planned end must use the frozen 30 min");
            ok = false;
        }
        d.cancel();
        d.loadSettings();
        d.testStartKeepSettings();
        if (d.getNapDurationMin() != 60 || d.getFallAsleepAllowanceMin() != 30
            || d.testGetDeadlineSec() != d.testGetStartSec() + 90 * 60) {
            logger.debug("next nap must use 60/30, got " + d.getNapDurationMin() + "/" + d.getFallAsleepAllowanceMin());
            ok = false;
        }
    } catch (e instanceof Lang.Exception) {
        logger.debug("exception: " + e.getErrorMessage());
        ok = false;
    }
    regHelperRestoreProps(nap0, alw0, hr0, sens0);
    return ok;
}

//! loadSettings() clamps every numeric setting and maps motion sensitivity.
(:test)
function testReg_loadSettingsClamps(logger as Test.Logger) as Boolean {
    var nap0 = Application.Properties.getValue("napDuration");
    var alw0 = Application.Properties.getValue("fallAsleepAllowance");
    var hr0 = Application.Properties.getValue("hrDropThreshold");
    var sens0 = Application.Properties.getValue("motionSensitivity");
    var ok = true;
    try {
        Application.Properties.setValue("napDuration", 500);
        Application.Properties.setValue("fallAsleepAllowance", 0);
        Application.Properties.setValue("hrDropThreshold", 99);
        Application.Properties.setValue("motionSensitivity", 0);
        var d = new SleepDetector(null);
        d.testStartKeepSettings();
        if (d.getNapDurationMin() != 120 || d.getFallAsleepAllowanceMin() != 5
            || d.testGetHrDropThreshold() != 20 || d.testGetMotionThreshold() != 80.0f) {
            logger.debug("high/low clamp failed: " + d.getNapDurationMin() + " " + d.getFallAsleepAllowanceMin()
                + " " + d.testGetHrDropThreshold() + " " + d.testGetMotionThreshold());
            ok = false;
        }
        Application.Properties.setValue("napDuration", 1);
        Application.Properties.setValue("fallAsleepAllowance", 99);
        Application.Properties.setValue("hrDropThreshold", 1);
        Application.Properties.setValue("motionSensitivity", 2);
        d = new SleepDetector(null);
        d.testStartKeepSettings();
        if (d.getNapDurationMin() != 5 || d.getFallAsleepAllowanceMin() != 30
            || d.testGetHrDropThreshold() != 3 || d.testGetMotionThreshold() != 30.0f) {
            logger.debug("second clamp failed: " + d.getNapDurationMin() + " " + d.getFallAsleepAllowanceMin()
                + " " + d.testGetHrDropThreshold() + " " + d.testGetMotionThreshold());
            ok = false;
        }
        Application.Properties.setValue("motionSensitivity", 7);
        d = new SleepDetector(null);
        if (d.testGetMotionThreshold() != 50.0f) {
            logger.debug("unknown sensitivity must map to 50 mg, got " + d.testGetMotionThreshold());
            ok = false;
        }
    } catch (e instanceof Lang.Exception) {
        logger.debug("exception: " + e.getErrorMessage());
        ok = false;
    }
    regHelperRestoreProps(nap0, alw0, hr0, sens0);
    return ok;
}

//! testStart() ignores the simulator's stored properties (deterministic tests).
(:test)
function testReg_testStartUsesDefaults(logger as Test.Logger) as Boolean {
    var nap0 = Application.Properties.getValue("napDuration");
    var alw0 = Application.Properties.getValue("fallAsleepAllowance");
    var hr0 = Application.Properties.getValue("hrDropThreshold");
    var sens0 = Application.Properties.getValue("motionSensitivity");
    var ok = true;
    try {
        Application.Properties.setValue("napDuration", 45);
        var d = new SleepDetector(null);
        d.testStart();
        ok = d.getNapDurationMin() == 30 && d.getFallAsleepAllowanceMin() == 15
            && d.testGetHrDropThreshold() == 5 && d.testGetMotionThreshold() == 50.0f;
        if (!ok) { logger.debug("testStart() must reset to 30/15/5/50"); }
    } catch (e instanceof Lang.Exception) {
        ok = false;
    }
    regHelperRestoreProps(nap0, alw0, hr0, sens0);
    return ok;
}

// ── App lifecycle ───────────────────────────────────────────────────────────

//! Returning to the foreground after the planned end fires the alarm at once,
//! without waiting for the next tick.
(:test)
function testReg_onResumeFiresDueAlarmImmediately(logger as Test.Logger) as Boolean {
    var d = regHelperAsleep(10);
    d.testAdvanceClock(11 * 60);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("setup: no tick yet, expected SLEEPING");
        return false;
    }
    d.onResume();
    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE) {
        logger.debug("onResume must fire the due alarm, state " + d.getState());
        return false;
    }
    return true;
}

//! Leaving the foreground during a nap is remembered for the warning; a new
//! nap starts without it, and a finished nap does not record it.
(:test)
function testReg_inactiveFlagLifecycle(logger as Test.Logger) as Boolean {
    var d = regHelperAsleep(30);
    var ok = true;
    if (d.wasInactiveDuringNap()) { logger.debug("flag must start false"); ok = false; }
    d.noteInactive();
    if (!d.wasInactiveDuringNap()) { logger.debug("flag must be set during a nap"); ok = false; }
    d.cancel();
    d.testStart();
    if (d.wasInactiveDuringNap()) { logger.debug("new nap must clear the flag"); ok = false; }
    d.cancel();
    d.noteInactive();
    if (d.wasInactiveDuringNap()) { logger.debug("summary must not record inactivity"); ok = false; }
    return ok;
}

//! After stop() the tick does nothing and onResume() does not fire an alarm.
(:test)
function testReg_onResumeAfterCancelIsInert(logger as Test.Logger) as Boolean {
    var d = regHelperAsleep(10);
    d.cancel();
    d.testAdvanceClock(3600);
    d.onResume();
    if (d.getState() != SleepDetector.STATE_SUMMARY || d.getAlarmReason() != SleepDetector.ALARM_NONE) {
        logger.debug("cancelled nap must stay in SUMMARY without alarm");
        return false;
    }
    return true;
}

// ── Alarm channels and patterns ─────────────────────────────────────────────

//! Tone Only on a device without tones (vivoactive 5/6) vibrates instead.
(:test)
function testReg_toneOnlyFallsBackToVibration(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_TONE);
    a.testForceChannelsUnavailable(false, true);
    a.startAlarm();
    a.testFireRing();
    var ok = a.testGetVibrateCount() == 2 && a.testGetToneCount() == 0;
    if (!ok) { logger.debug("vib " + a.testGetVibrateCount() + " tone " + a.testGetToneCount()); }
    a.stop();
    return ok;
}

//! Vibration Only on a device (or setting) without vibration uses tones.
//! (Skipped on devices that have no tones at all, e.g. vivoactive 5/6.)
(:test)
function testReg_vibrationOnlyFallsBackToTone(logger as Test.Logger) as Boolean {
    if (!(Attention has :playTone)) {
        return true;
    }
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
    a.testForceChannelsUnavailable(true, false);
    a.startAlarm();
    a.testFireRing();
    var ok = a.testGetToneCount() == 2 && a.testGetVibrateCount() == 0;
    if (!ok) { logger.debug("vib " + a.testGetVibrateCount() + " tone " + a.testGetToneCount()); }
    a.stop();
    return ok;
}

//! No channel at all: the alarm keeps running (screen + backlight) without crashing.
(:test)
function testReg_noChannelKeepsAlarmRunning(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_BOTH);
    a.testForceChannelsUnavailable(true, true);
    a.startAlarm();
    a.testFireRing();
    var ok = a.isAlarming() && a.testGetRingCount() == 2
        && a.testGetVibrateCount() == 0 && a.testGetToneCount() == 0;
    a.stop();
    return ok;
}

//! An unknown alarmType value vibrates instead of staying silent.
(:test)
function testReg_unknownAlarmTypeVibrates(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    a.testSetAlarmType(7);
    a.startAlarm();
    var ok = a.testGetVibrateCount() == 1;
    if (!ok) { logger.debug("vib " + a.testGetVibrateCount()); }
    a.stop();
    return ok;
}

//! Every phase has its own, stronger vibration pattern within the SDK limit
//! of 8 profiles: first pulse 15/30/65/100 % for 80/120/200/300 ms.
(:test)
function testReg_vibePatternEscalatesPerPhase(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    var sizes = [3, 5, 5, 5] as Array<Number>;
    var duty = [15, 30, 65, 100] as Array<Number>;
    var len = [80, 120, 200, 300] as Array<Number>;
    for (var p = 0; p < 4; p++) {
        var pat = a.testGetVibePattern(p);
        if (pat.size() != sizes[p] || pat.size() > 8) {
            logger.debug("phase " + p + " size " + pat.size());
            return false;
        }
        if (pat[0].dutyCycle != duty[p] || pat[0].length != len[p]) {
            logger.debug("phase " + p + " first pulse " + pat[0].dutyCycle + "%/" + pat[0].length + "ms");
            return false;
        }
    }
    return true;
}

//! Tones escalate ALERT_LO, ALERT_LO, ALERT_HI, ALARM.
(:test)
function testReg_tonePerPhase(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    return a.testGetToneForPhase(0) == Attention.TONE_ALERT_LO
        && a.testGetToneForPhase(1) == Attention.TONE_ALERT_LO
        && a.testGetToneForPhase(2) == Attention.TONE_ALERT_HI
        && a.testGetToneForPhase(3) == Attention.TONE_ALARM;
}

//! ringNow() rings immediately while alarming and does nothing otherwise.
(:test)
function testReg_ringNow(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
    a.ringNow();
    var ok = (a.testGetRingCount() == 0);
    a.startAlarm();
    a.ringNow();
    ok = ok && a.testGetRingCount() == 2 && a.testGetVibrateCount() == 2 && a.isAlarming();
    a.stop();
    return ok;
}

// ── Two-press guard ─────────────────────────────────────────────────────────

//! One press only arms; a second press in the same context within the window
//! confirms; a late press re-arms; a press in another context re-arms.
(:test)
function testReg_confirmPressRules(logger as Test.Logger) as Boolean {
    var c = new ConfirmPress(4);
    var ok = true;
    if (c.press(100, ConfirmPress.CONTEXT_ALARM)) { logger.debug("first press confirmed"); ok = false; }
    if (!c.isArmed(103, ConfirmPress.CONTEXT_ALARM)) { logger.debug("must be armed within window"); ok = false; }
    if (!c.press(103, ConfirmPress.CONTEXT_ALARM)) { logger.debug("second press must confirm"); ok = false; }
    if (c.isArmed(103, ConfirmPress.CONTEXT_ALARM)) { logger.debug("confirm must disarm"); ok = false; }

    c.press(200, ConfirmPress.CONTEXT_NAP);
    if (c.press(204, ConfirmPress.CONTEXT_NAP)) { logger.debug("press after window must not confirm"); ok = false; }
    if (!c.press(205, ConfirmPress.CONTEXT_NAP)) { logger.debug("re-armed press must confirm"); ok = false; }

    c.press(300, ConfirmPress.CONTEXT_NAP);
    if (c.press(301, ConfirmPress.CONTEXT_ALARM)) { logger.debug("other context must not confirm"); ok = false; }
    c.reset();
    if (c.isArmed(301, ConfirmPress.CONTEXT_ALARM)) { logger.debug("reset must disarm"); ok = false; }
    return ok;
}

// ── Smart wake on a deadline-capped nap ────────────────────────────────────

//! Onset at 40 min of a 30 min nap with a 15 min allowance: the cap leaves a
//! 5 min nap, so there is no smart-wake window; a stir minute is ignored and
//! the alarm rings at the 45 min deadline with NAP_COMPLETE.
(:test)
function testReg_cappedShortNapHasNoSmartWake(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetBaseline(70.0f);
    var start = d.testGetStartSec();
    d.testRunMinutes(40, 70, 200.0f);
    d.testForceSleep();
    var ok = true;
    if (d.testGetNapEndSec() != start + 45 * 60 || d.getSmartWakeWindowSec() != 0) {
        logger.debug("capped 5 min nap: end " + (d.testGetNapEndSec() - start) + " window " + d.getSmartWakeWindowSec());
        ok = false;
    }
    d.testRunSeconds(54, 55, 10.0f);
    d.testRunSeconds(6, 55, 100.0f);
    if (d.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("stir must not end a capped short nap, state " + d.getState());
        ok = false;
    }
    d.testRunMinutes(4, 55, 10.0f);
    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_NAP_COMPLETE
        || d.testNowSec() != start + 45 * 60) {
        logger.debug("expected NAP_COMPLETE exactly at the deadline, state " + d.getState()
            + " reason " + d.getAlarmReason());
        ok = false;
    }
    return ok;
}

//! A 60 min nap capped to 20 min (allowance 5, onset at 45 min) gets a window
//! of 20 % of the real 20 min (240 s), not of the configured 60 min (300 s).
(:test)
function testReg_cappedNapWindowUsesEffectiveLength(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(60);
    d.testSetFallAsleepAllowanceMin(5);
    d.testSetBaseline(70.0f);
    d.testRunMinutes(45, 70, 200.0f);
    d.testForceSleep();
    if (d.getSmartWakeWindowSec() != 240) {
        logger.debug("window expected 240 s, got " + d.getSmartWakeWindowSec());
        return false;
    }
    return true;
}

// ── Third review round ─────────────────────────────────────────────────────

//! Coming back to the app exactly when the alarm becomes due starts it with
//! ONE ring (onResume starts it; no extra ringNow on top of the first ring).
(:test)
function testReg_resumeWhenDueRingsOnce(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
    var d = new SleepDetector(a);
    d.testStart();
    d.testSetNapDurationMin(10);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testAdvanceClock(11 * 60);
    Lifecycle.resume(d, a);
    var ok = d.getState() == SleepDetector.STATE_ALARM && a.isAlarming()
        && a.testGetRingsFired() == 1 && a.testGetVibrateCount() == 1;
    if (!ok) {
        logger.debug("state " + d.getState() + " rings " + a.testGetRingsFired() + " vib " + a.testGetVibrateCount());
    }
    a.stop();
    return ok;
}

//! An alarm that was already ringing while the app was hidden rings again
//! at once when the app comes back.
(:test)
function testReg_resumeWhileRingingRingsAgain(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
    var d = new SleepDetector(a);
    d.testStart();
    d.testSetNapDurationMin(10);
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testAdvanceClock(10 * 60);
    d.testTick();                            // alarm starts: ring 1
    Lifecycle.resume(d, a);                  // back from the background: ring 2
    var ok = a.isAlarming() && a.testGetRingsFired() == 2;
    if (!ok) {
        logger.debug("rings " + a.testGetRingsFired());
    }
    a.stop();
    return ok;
}

//! Resuming a nap that is not due changes nothing and never rings.
(:test)
function testReg_resumeBeforeDueIsSilent(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    var d = new SleepDetector(a);
    d.testStart();
    d.testSetBaseline(70.0f);
    d.testForceSleep();
    d.testAdvanceClock(60);
    Lifecycle.resume(d, a);
    var ok = d.getState() == SleepDetector.STATE_SLEEPING && !a.isAlarming() && a.testGetRingsFired() == 0;
    a.stop();
    return ok;
}

//! start() clamps the chosen duration: 0 is Stay Awake, 1-4 become 5,
//! anything above 120 becomes 120 (fake runtime: no sensors, frozen clock).
(:test)
function testReg_startClampsDuration(logger as Test.Logger) as Boolean {
    var inputs   = [0, 3, 5, 45, 120, 500] as Array<Number>;
    var expected = [0, 5, 5, 45, 120, 120] as Array<Number>;
    for (var i = 0; i < inputs.size(); i++) {
        var d = new SleepDetector(null);
        d.testUseFakeRuntime();
        d.start(inputs[i]);
        var stay = d.isStayAwake();
        if (d.getNapDurationMin() != expected[i] || stay != (expected[i] == 0)) {
            logger.debug("start(" + inputs[i] + "): " + d.getNapDurationMin() + " min, stay awake " + stay);
            return false;
        }
        if (!stay && d.testGetDeadlineSec() != d.testGetStartSec() + (15 + expected[i]) * 60) {
            logger.debug("start(" + inputs[i] + "): deadline must use the documented 15 min allowance");
            return false;
        }
        d.stop();
    }
    return true;
}

//! The persistent phase keeps the full-intensity pattern and trill.
(:test)
function testReg_persistentPhaseKeepsFullPattern(logger as Test.Logger) as Boolean {
    var a = new AlarmManager();
    var p3 = a.testGetVibePattern(3);
    var p4 = a.testGetVibePattern(4);
    if (p3.size() != p4.size()) { return false; }
    for (var i = 0; i < p3.size(); i++) {
        if (p3[i].dutyCycle != p4[i].dutyCycle || p3[i].length != p4[i].length) { return false; }
    }
    if (!(Attention has :ToneProfile)) {
        return true;                         // vivoactive 5/6: no melodies to compare
    }
    return a.testGetToneProfile(4).size() == a.testGetToneProfile(3).size();
}

//! System.getTimer() wraps after ~24.8 days of uptime. A press 3 s after the
//! wrap still confirms one made just before it, and a press 10 s later does
//! not: the guard uses elapsed time, so a stale arm can never let a single
//! BACK stop a nap.
(:test)
function testReg_confirmPressAcrossTimerWrap(logger as Test.Logger) as Boolean {
    var c = new ConfirmPress(4000);
    var beforeWrap = 2147483000;             // 647 ms before the 32-bit maximum
    var plus3s = -2147481296;                // beforeWrap + 3000 after the wrap
    var plus10s = -2147474296;               // beforeWrap + 10000 after the wrap
    c.press(beforeWrap, ConfirmPress.CONTEXT_NAP);
    if (!c.isArmed(plus3s, ConfirmPress.CONTEXT_NAP)) {
        logger.debug("3 s after the wrap the first press must still be armed");
        return false;
    }
    if (c.isArmed(plus10s, ConfirmPress.CONTEXT_NAP)) {
        logger.debug("10 s after the wrap the first press must have expired");
        return false;
    }
    if (c.press(plus10s, ConfirmPress.CONTEXT_NAP)) {
        logger.debug("a stale arm across the wrap must not confirm");
        return false;
    }
    return true;
}
