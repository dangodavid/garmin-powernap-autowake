import Toybox.Test;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Application;

// -----------------------------------------------------------------------------
// Input tests: the real PowerNapDelegate, PowerNapView and SleepDetector
// wired together, driven through handleKey()/handleTap() (the code onKey and
// onTap run). The detector uses the fake runtime: start() opens a session on
// the frozen clock without sensors or timers; the alarm manager is real (it
// vibrates in the simulator) and is stopped by cleanup().
//
// Two presses within the confirmation window come from consecutive calls
// (well inside 4 s); the window itself is covered by testReg_confirmPressRules.
// -----------------------------------------------------------------------------

(:debug)
class DelegateRig {
    var detector as SleepDetector;
    var alarm as AlarmManager;
    var view as PowerNapView;
    var delegate as PowerNapDelegate;
    private var _napProp as Object?;

    function initialize(pending as Number) {
        _napProp = Application.Properties.getValue("napDuration");
        alarm = new AlarmManager();
        alarm.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
        detector = new SleepDetector(alarm);
        detector.testUseFakeRuntime();
        view = new PowerNapView(detector, alarm);
        view.testSetPendingDuration(pending);
        delegate = new PowerNapDelegate(view, detector, alarm);
        delegate.testDisableExit();
    }

    function key(k as Number) as Boolean {
        return delegate.handleKey(k);
    }

    //! Start from the start screen and skip calibration (baseline 70).
    function startNap() as Void {
        key(WatchUi.KEY_ENTER);
        detector.testSetBaseline(70.0f);
    }

    //! Stop everything (including the start screen's refresh timer, which
    //! resetToStart() starts) and restore the stored nap duration.
    function cleanup() as Void {
        alarm.stop();
        detector.stop();
        view.onHide();
        try {
            Application.Properties.setValue("napDuration", (_napProp != null) ? _napProp as Number : 30);
        } catch (e instanceof Lang.Exception) {
        }
    }
}

//! Start screen: UP/DOWN step by 5 and stop at 120 (no wrap); one step below
//! 5 is Stay Awake (0), which DOWN cannot go below; UP from 0 goes to 5.
(:test)
function testDelegate_startScreenDurationSteps(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(115);
    var ok = true;
    r.key(WatchUi.KEY_UP);
    r.key(WatchUi.KEY_UP);
    if (r.view.testGetPendingDuration() != 120) {
        logger.debug("UP past 120 must stop at 120, got " + r.view.testGetPendingDuration());
        ok = false;
    }
    r.view.testSetPendingDuration(10);
    r.key(WatchUi.KEY_DOWN);
    r.key(WatchUi.KEY_DOWN);
    if (r.view.testGetPendingDuration() != 0) {
        logger.debug("10 -> 5 -> Stay Awake expected, got " + r.view.testGetPendingDuration());
        ok = false;
    }
    r.key(WatchUi.KEY_DOWN);
    if (r.view.testGetPendingDuration() != 0) {
        logger.debug("DOWN at Stay Awake must stay there");
        ok = false;
    }
    r.key(WatchUi.KEY_UP);
    if (r.view.testGetPendingDuration() != 5) {
        logger.debug("UP from Stay Awake must give 5, got " + r.view.testGetPendingDuration());
        ok = false;
    }
    r.view.testSetPendingDuration(7);             // odd value from the phone
    r.key(WatchUi.KEY_DOWN);
    if (r.view.testGetPendingDuration() != 5) {
        logger.debug("7 must step down to 5 first, got " + r.view.testGetPendingDuration());
        ok = false;
    }
    if (r.view.isStarted()) {
        logger.debug("duration keys must not start a nap");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! START begins a nap with the shown duration; one BACK only arms; a second
//! BACK before any sleep returns to the start screen (nothing to report).
(:test)
function testDelegate_backTwiceBeforeSleepReturnsToStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(20);
    r.startNap();
    var ok = true;
    if (!r.view.isStarted() || r.detector.getNapDurationMin() != 20 || r.detector.isStayAwake()) {
        logger.debug("START must begin a 20 min nap, got " + r.detector.getNapDurationMin());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.view.isStarted() || !r.detector.isActiveState()) {
        logger.debug("one BACK must not stop the nap");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (r.view.isStarted() || r.detector.testIsRunning()) {
        logger.debug("second BACK before sleep must return to the start screen");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! With sleep recorded, BACK twice stops the nap and shows its summary.
(:test)
function testDelegate_backTwiceAfterSleepShowsSummary(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testRunMinutes(3, 55, 10.0f);
    r.key(WatchUi.KEY_ESC);
    var armed = r.detector.getState() == SleepDetector.STATE_SLEEPING;
    r.key(WatchUi.KEY_ESC);
    var ok = armed && r.detector.getState() == SleepDetector.STATE_SUMMARY && r.detector.isCancelled()
        && r.view.isStarted() && !r.alarm.isAlarming();
    if (!ok) {
        logger.debug("armed " + armed + " state " + r.detector.getState());
    }
    r.cleanup();
    return ok;
}

//! During a nap UP, DOWN and START only peek: the card shows, nothing stops,
//! nothing changes the duration; taps are ignored altogether.
(:test)
function testDelegate_buttonsPeekTapsIgnored(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    r.detector.testForceSleep();
    var ok = true;
    var keys = [WatchUi.KEY_UP, WatchUi.KEY_DOWN, WatchUi.KEY_ENTER] as Array<Number>;
    for (var i = 0; i < keys.size(); i++) {
        if (!r.key(keys[i]) || !r.view.isPeeking()) {
            logger.debug("key " + keys[i] + " must be consumed and peek");
            ok = false;
        }
        if (r.detector.getState() != SleepDetector.STATE_SLEEPING || r.detector.getNapDurationMin() != 30) {
            logger.debug("key " + keys[i] + " changed the nap");
            ok = false;
        }
    }
    if (!r.delegate.handleTap(10) || !r.delegate.handleTap(200)
        || r.detector.getState() != SleepDetector.STATE_SLEEPING) {
        logger.debug("taps must be consumed and ignored");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! The alarm needs two presses (START or BACK); UP/DOWN do nothing; the
//! second press stops it and shows the summary.
(:test)
function testDelegate_alarmNeedsTwoPresses(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testAdvanceClock(10 * 60);
    r.detector.testTick();
    var ok = true;
    if (r.detector.getState() != SleepDetector.STATE_ALARM || !r.alarm.isAlarming()) {
        logger.debug("setup: expected the alarm");
        r.cleanup();
        return false;
    }
    r.key(WatchUi.KEY_UP);
    r.key(WatchUi.KEY_DOWN);
    r.key(WatchUi.KEY_ENTER);
    if (r.detector.getState() != SleepDetector.STATE_ALARM || !r.alarm.isAlarming() || r.view.isPeeking()) {
        logger.debug("one press must not stop the alarm, state " + r.detector.getState());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (r.detector.getState() != SleepDetector.STATE_SUMMARY || r.alarm.isAlarming()) {
        logger.debug("START then BACK must stop the alarm, state " + r.detector.getState());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! On the summary START sets up a new nap (start screen, stored duration)
//! and BACK exits (exit is switched off in tests).
(:test)
function testDelegate_summaryStartBeginsNewNap(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(25);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.cancel();
    var ok = r.detector.getState() == SleepDetector.STATE_SUMMARY;
    r.key(WatchUi.KEY_ENTER);
    ok = ok && !r.view.isStarted() && r.view.testGetPendingDuration() == 25;
    if (!ok) {
        logger.debug("summary START: started " + r.view.isStarted() + " pending " + r.view.testGetPendingDuration());
    }
    r.cleanup();
    return ok;
}

//! Stay Awake end to end: pick 0, START, doze -> doze alarm, two presses ->
//! back on guard (not the summary), BACK twice -> summary even without
//! sleep; START there -> start screen with a nap duration again.
(:test)
function testDelegate_stayAwakeFlow(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(5);
    r.key(WatchUi.KEY_DOWN);
    r.key(WatchUi.KEY_ENTER);
    var ok = true;
    if (!r.view.isStarted() || !r.detector.isStayAwake()) {
        logger.debug("expected a Stay Awake session");
        r.cleanup();
        return false;
    }
    r.detector.testRunMinutes(5, 70, 10.0f);
    if (r.detector.getAlarmReason() != SleepDetector.ALARM_DOZE || !r.alarm.isAlarming()) {
        logger.debug("expected the doze alarm, reason " + r.detector.getAlarmReason());
        ok = false;
    }
    r.key(WatchUi.KEY_ENTER);
    r.key(WatchUi.KEY_ENTER);
    if (r.detector.getState() != SleepDetector.STATE_MONITORING || r.alarm.isAlarming()
        || r.detector.getDozeCount() != 1) {
        logger.debug("dismiss must go back on guard, state " + r.detector.getState());
        ok = false;
    }
    r.view.testExpireInputLock();            // the user deliberately continues later
    r.key(WatchUi.KEY_ESC);
    r.key(WatchUi.KEY_ESC);
    if (r.detector.getState() != SleepDetector.STATE_SUMMARY || !r.view.isStarted()) {
        logger.debug("BACK x2 must show the Stay Awake summary, state " + r.detector.getState());
        ok = false;
    }
    r.view.testExpireInputLock();
    r.key(WatchUi.KEY_ENTER);
    if (r.view.isStarted() || r.view.testGetPendingDuration() == 0) {
        logger.debug("a new session must default to a nap, pending " + r.view.testGetPendingDuration());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! Start-screen taps follow the measured zones: above the number +5, below
//! the label -5, the number itself starts.
(:test)
function testDelegate_startScreenTaps(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    var zones = r.view.testMeasureTapZones(layoutHelperDc());
    r.delegate.handleTap(zones[0] - 1);
    var ok = r.view.testGetPendingDuration() == 35;
    r.delegate.handleTap(zones[1] + 1);
    ok = ok && r.view.testGetPendingDuration() == 30 && !r.view.isStarted();
    r.delegate.handleTap((zones[0] + zones[1]) / 2);
    ok = ok && r.view.isStarted() && r.detector.getNapDurationMin() == 30;
    if (!ok) {
        logger.debug("taps: pending " + r.view.testGetPendingDuration() + " started " + r.view.isStarted());
    }
    r.cleanup();

    // A tap on the "TAP to begin" hint itself starts (it must not remove 5 min).
    r = new DelegateRig(30);
    zones = r.view.testMeasureTapZones(layoutHelperDc());
    r.delegate.handleTap(zones[4] + 3);
    if (!r.view.isStarted() || r.detector.getNapDurationMin() != 30) {
        logger.debug("tap on the hint: started " + r.view.isStarted() + " nap " + r.detector.getNapDurationMin());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! A groggy burst of START presses on the nap alarm stops it and then does
//! nothing more: the summary stays (no new nap, no start screen). Before
//! the input lock, presses 3 and 4 skipped the summary and started a nap.
(:test)
function testDelegate_pressBurstAfterAlarmStopsAtSummary(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testAdvanceClock(10 * 60);
    r.detector.testTick();
    for (var i = 0; i < 6; i++) {
        r.key(WatchUi.KEY_ENTER);
    }
    var ok = r.detector.getState() == SleepDetector.STATE_SUMMARY && r.view.isStarted()
        && !r.alarm.isAlarming() && !r.detector.testIsRunning();
    if (!ok) {
        logger.debug("after 6 START presses: state " + r.detector.getState() + " started " + r.view.isStarted());
    }
    // Once the lock is over, START on the summary works as usual.
    r.view.testExpireInputLock();
    r.key(WatchUi.KEY_ENTER);
    if (r.view.isStarted()) {
        logger.debug("a deliberate START after the lock must open the start screen");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! A burst of BACK presses on the Stay Awake doze alarm stops the alarm but
//! does not end the session: the watch stays on guard.
(:test)
function testDelegate_backBurstOnDozeAlarmKeepsGuarding(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(0);
    r.key(WatchUi.KEY_ENTER);
    r.detector.testRunMinutes(5, 70, 10.0f);
    var alarmed = r.detector.getAlarmReason() == SleepDetector.ALARM_DOZE;
    for (var i = 0; i < 5; i++) {
        r.key(WatchUi.KEY_ESC);
    }
    var ok = alarmed && r.detector.getState() == SleepDetector.STATE_MONITORING
        && r.detector.testIsRunning() && !r.alarm.isAlarming() && r.detector.getDozeCount() == 1;
    if (!ok) {
        logger.debug("alarmed " + alarmed + " state " + r.detector.getState() + " running " + r.detector.testIsRunning());
    }
    r.cleanup();
    return ok;
}

//! Stopping a nap before any sleep (BACK x2 -> start screen) is followed by
//! the lock too: a third BACK does not exit the app, a START does not start.
(:test)
function testDelegate_lockAfterReturnToStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(20);
    r.startNap();
    r.key(WatchUi.KEY_ESC);
    r.key(WatchUi.KEY_ESC);
    r.key(WatchUi.KEY_ENTER);
    var ok = !r.view.isStarted() && r.view.isInputLocked();
    if (!ok) {
        logger.debug("START right after the stop must be ignored, started " + r.view.isStarted());
    }
    r.cleanup();
    return ok;
}

//! Changing an unrelated setting on the phone (alarm type) keeps the pick on
//! the watch, Stay Awake included; changing the nap duration is followed.
(:test)
function testDelegate_phoneSettingsKeepWatchPick(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    var ok = true;
    try {
        Application.Properties.setValue("napDuration", 30);
        r.view.onSettingsChanged();              // sync to 30
        r.view.testSetPendingDuration(0);        // user picks Stay Awake
        r.view.onSettingsChanged();              // e.g. alarm type changed
        if (r.view.testGetPendingDuration() != 0) {
            logger.debug("an unrelated setting must keep Stay Awake, got " + r.view.testGetPendingDuration());
            ok = false;
        }
        Application.Properties.setValue("napDuration", 45);
        r.view.onSettingsChanged();
        if (r.view.testGetPendingDuration() != 45) {
            logger.debug("a new nap duration from the phone must be followed, got " + r.view.testGetPendingDuration());
            ok = false;
        }
    } catch (e instanceof Lang.Exception) {
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! A fall-asleep allowance changed on the phone during a nap is ignored by
//! that nap but read when the start screen comes back, so the "Latest alarm"
//! preview matches the next nap.
(:test)
function testDelegate_resetToStartReloadsSettings(logger as Test.Logger) as Boolean {
    var alw0 = Application.Properties.getValue("fallAsleepAllowance");
    var ok = true;
    var d = new SleepDetector(null);
    var a = new AlarmManager();
    var v = new PowerNapView(d, a);
    try {
        Application.Properties.setValue("fallAsleepAllowance", 15);
        d.loadSettings();
        d.testStartKeepSettings();               // running: settings frozen
        Application.Properties.setValue("fallAsleepAllowance", 25);
        d.loadSettings();
        var frozen = d.getFallAsleepAllowanceMin();
        v.testSetStarted(true);
        v.resetToStart();
        if (frozen != 15 || d.getFallAsleepAllowanceMin() != 25) {
            logger.debug("allowance during the nap " + frozen + ", after " + d.getFallAsleepAllowanceMin());
            ok = false;
        }
    } catch (e instanceof Lang.Exception) {
        ok = false;
    }
    v.onHide();
    d.stop();
    try {
        Application.Properties.setValue("fallAsleepAllowance", (alw0 != null) ? alw0 as Number : 15);
    } catch (e instanceof Lang.Exception) {
    }
    return ok;
}

//! Stay Awake: pressing a button during the drowsiness warning answers it:
//! the still run starts over and no doze alarm follows.
(:test)
function testDelegate_stayAwakePressEndsStillRun(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(0);
    r.key(WatchUi.KEY_ENTER);
    r.detector.testRunMinutes(3, 70, 10.0f);
    var warned = r.detector.isDozeWarning();
    r.key(WatchUi.KEY_UP);
    var cleared = !r.detector.isDozeWarning() && r.view.isPeeking();
    r.detector.testRunMinutes(2, 70, 10.0f);
    var ok = warned && cleared && r.detector.getState() == SleepDetector.STATE_MONITORING
        && r.detector.getDozeCount() == 0;
    if (!ok) {
        logger.debug("warned " + warned + " cleared " + cleared + " state " + r.detector.getState());
    }
    r.cleanup();
    return ok;
}

//! A nap button press never touches detection (only Stay Awake resets on it).
(:test)
function testDelegate_napPressKeepsStillness(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    r.detector.testRunMinutes(2, 70, 10.0f);
    var still = r.detector.getStillMinutes();
    r.key(WatchUi.KEY_UP);
    var ok = still > 0 && r.detector.getStillMinutes() == still;
    if (!ok) {
        logger.debug("still " + still + " -> " + r.detector.getStillMinutes());
    }
    r.cleanup();
    return ok;
}

//! The input lock lasts while presses keep coming: 2 s after the stop a
//! press is ignored and extends it; only after a 2.5 s pause does a press act.
(:test)
function testDelegate_lockExtendsWhilePressesContinue(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testAdvanceClock(10 * 60);
    r.detector.testTick();
    r.key(WatchUi.KEY_ENTER);
    r.key(WatchUi.KEY_ENTER);                    // alarm stopped -> summary, locked
    var ok = r.detector.getState() == SleepDetector.STATE_SUMMARY;
    r.view.testAdvanceMs(2000);
    r.key(WatchUi.KEY_ENTER);                    // ignored, extends the lock
    r.view.testAdvanceMs(2000);                  // 4 s after the stop, 2 s after the press
    r.key(WatchUi.KEY_ENTER);                    // still ignored
    ok = ok && r.view.isStarted() && r.detector.getState() == SleepDetector.STATE_SUMMARY;
    r.view.testAdvanceMs(2600);                  // a real pause
    r.key(WatchUi.KEY_ENTER);                    // acts: new nap set-up (start screen)
    ok = ok && !r.view.isStarted();
    if (!ok) {
        logger.debug("state " + r.detector.getState() + " started " + r.view.isStarted());
    }
    r.cleanup();
    return ok;
}
