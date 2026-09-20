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
// Key model under test (owner decision 2026-09-19, revised the same night;
// BACK confirmed below the start screen on 2026-09-20): BACK is a normal
// back button. It goes back one level: on a nap, the Stay Awake guard or
// the nap alarm to the start screen (no summary), on the doze alarm back on
// guard, on the summary to the start screen. Wherever that step would END
// something it takes two presses within 4 s, the same pair and window as the
// exit on the start screen, and the first press changes nothing: the nap
// runs on, the alarm keeps ringing as loudly as it had got. Calibrating, the
// summary and the alarm preview act on one press - nothing is lost there.
// START x2 stops the nap or the alarm and shows the summary (the doze alarm
// goes back on guard); a BACK never completes a START pair, nor a START a
// BACK pair. A right swipe is BACK outside a session only: during a nap and
// during its alarm swipes do nothing at all. The 1.5 s input lock after a
// stop is never extended by presses. Two presses within the confirmation
// window come from consecutive calls (well inside 4 s); the window itself is
// covered by testReg_confirmPressRules and
// testDelegate_startScreenBackTwiceExits.
// -----------------------------------------------------------------------------

(:debug)
class DelegateRig {
    var detector as SleepDetector;
    var alarm as AlarmManager;
    var view as PowerNapView;
    var delegate as PowerNapDelegate;
    private var _napProp as Object?;
    private var _lastNap as Number?;
    private var _phoneNap as Number?;

    function initialize(pending as Number) {
        _napProp = Application.Properties.getValue("napDuration");
        // START remembers the duration in Application.Storage; put back
        // whatever this device had, so one test cannot set up the next.
        _lastNap = delegateHelperStored("lastNapMin");
        _phoneNap = delegateHelperStored("lastPhoneNapMin");
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

    //! Start from the start screen and stay in the first two minutes: no
    //! baseline yet, so the detector is still STATE_CALIBRATING. (startNap()
    //! cannot be used for that: setting the baseline ends calibration.)
    function startCalibrating() as Void {
        key(WatchUi.KEY_ENTER);
    }

    //! Start the nap the rig was built with, force sleep and let the alarm
    //! become due - whatever that duration is.
    function startAndRing() as Void {
        startNap();
        detector.testForceSleep();
        detector.testAdvanceClock(detector.getNapDurationMin() * 60 + 60);
        detector.testTick();
    }

    //! Start a Stay Awake session and let a doze alarm ring.
    function startAndDoze() as Void {
        view.testSetPendingDuration(0);
        key(WatchUi.KEY_ENTER);
        detector.testRunMinutes(5, 70, 10.0f);
    }

    //! BACK as a wearer presses it where the contract asks for a pair: the
    //! press that arms and the press that acts, back to back.
    function backTwice() as Void {
        key(WatchUi.KEY_ESC);
        key(WatchUi.KEY_ESC);
    }

    //! The footer text of the current screen.
    function footer() as String {
        var f = view.testBuildLayout(layoutHelperDc()).getFooterText();
        return (f == null) ? "" : f as String;
    }

    //! Stop everything (including the start screen's refresh timer, which
    //! resetToStart() starts) and restore the stored nap duration, both the
    //! phone setting and the duration remembered on the watch.
    function cleanup() as Void {
        alarm.stop();
        detector.stop();
        view.onHide();
        try {
            Application.Properties.setValue("napDuration", (_napProp != null) ? _napProp as Number : 30);
            delegateHelperRestore("lastNapMin", _lastNap);
            delegateHelperRestore("lastPhoneNapMin", _phoneNap);
        } catch (e instanceof Lang.Exception) {
        }
    }
}

//! A Number kept in Application.Storage, or null.
(:debug)
function delegateHelperStored(key as String) as Number? {
    try {
        var v = Application.Storage.getValue(key);
        if (v != null && v instanceof Number) {
            return v as Number;
        }
    } catch (e instanceof Lang.Exception) {
    }
    return null;
}

//! Put a remembered Storage value back (delete it when there was none).
(:debug)
function delegateHelperRestore(key as String, value as Number?) as Void {
    try {
        if (value == null) {
            Application.Storage.deleteValue(key);
        } else {
            Application.Storage.setValue(key, value as Number);
        }
    } catch (e instanceof Lang.Exception) {
    }
}

//! Whether `text` is one of the given variants.
(:debug)
function delegateHelperIsOneOf(text as String, variants as Array<String>) as Boolean {
    for (var i = 0; i < variants.size(); i++) {
        if (text.equals(variants[i])) {
            return true;
        }
    }
    return false;
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
    if (r.view.isStarted() || r.delegate.testExitRequested()) {
        logger.debug("duration keys must not start a nap or exit");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! START begins a nap with the shown duration. While calibrating one BACK
//! goes back to the start screen at once (the first two minutes have nothing
//! to lose); once the nap proper is running it takes two, and the first press
//! ends nothing: the nap runs on and the popup says what the second one does.
(:test)
function testDelegate_backDuringNapGoesToStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(20);
    r.startCalibrating();
    var ok = true;
    if (!r.view.isStarted() || r.detector.getNapDurationMin() != 20 || r.detector.isStayAwake()
        || r.detector.getState() != SleepDetector.STATE_CALIBRATING) {
        logger.debug("START must begin a 20 min nap, got " + r.detector.getNapDurationMin()
            + " state " + r.detector.getState());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (r.view.isStarted() || r.delegate.testExitRequested() || r.detector.testIsRunning()
        || r.alarm.isAlarming() || !r.view.isInputLocked() || r.view.testIsHintShowing()) {
        logger.debug("calibrating: one BACK must go back to the start screen, started " + r.view.isStarted()
            + " exit " + r.delegate.testExitRequested() + " running " + r.detector.testIsRunning()
            + " hint " + r.view.testIsHintShowing());
        ok = false;
    }
    if (r.detector.getState() == SleepDetector.STATE_SUMMARY) {
        logger.debug("BACK must not show a summary");
        ok = false;
    }
    if (r.view.testBuildLayout(layoutHelperDc()).getBannerText() != null) {
        logger.debug("no popup after BACK while calibrating");
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(20);
    r.startNap();
    r.detector.testRunMinutes(3, 70, 10.0f);     // calibration over: monitoring
    r.key(WatchUi.KEY_ESC);
    if (!r.view.isStarted() || !r.detector.testIsRunning()
        || r.detector.getState() != SleepDetector.STATE_MONITORING || r.view.isInputLocked()) {
        logger.debug("monitoring: the first BACK must end nothing, state " + r.detector.getState()
            + " started " + r.view.isStarted() + " locked " + r.view.isInputLocked());
        ok = false;
    }
    if (!r.view.testIsHintShowing() || !r.view.testHintIsFor(PowerNapView.BACK_HINT_NAP)
        || r.view.testBuildLayout(layoutHelperDc()).getBannerText() == null) {
        logger.debug("monitoring: the first BACK must show the 'end nap' popup, showing "
            + r.view.testIsHintShowing());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (r.view.isStarted() || r.detector.testIsRunning() || r.delegate.testExitRequested()
        || r.detector.getState() == SleepDetector.STATE_SUMMARY || !r.view.isInputLocked()
        || r.view.testIsHintShowing()) {
        logger.debug("monitoring: BACK x2 must go back to the start screen, started " + r.view.isStarted()
            + " state " + r.detector.getState());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! START twice during a nap stops it and shows the summary (with sleep
//! recorded, and also before any sleep: the no-sleep summary), and the
//! input lock follows.
(:test)
function testDelegate_startTwiceDuringNapShowsSummary(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testRunMinutes(3, 55, 10.0f);
    r.key(WatchUi.KEY_ENTER);
    var peeked = r.view.isPeeking() && r.detector.getState() == SleepDetector.STATE_SLEEPING;
    r.key(WatchUi.KEY_ENTER);
    var ok = peeked && r.detector.getState() == SleepDetector.STATE_SUMMARY && r.detector.isCancelled()
        && r.detector.hasSleptAtLeastOnce() && r.view.isStarted() && !r.alarm.isAlarming()
        && r.view.isInputLocked() && !r.delegate.testExitRequested();
    if (!ok) {
        logger.debug("peeked " + peeked + " state " + r.detector.getState() + " locked " + r.view.isInputLocked());
    }
    r.cleanup();

    r = new DelegateRig(20);
    r.startNap();
    r.key(WatchUi.KEY_ENTER);
    r.key(WatchUi.KEY_ENTER);
    if (r.detector.getState() != SleepDetector.STATE_SUMMARY || r.detector.hasSleptAtLeastOnce()
        || !r.detector.isCancelled() || r.delegate.testExitRequested()) {
        logger.debug("START x2 before sleep must show the no-sleep summary, state " + r.detector.getState());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! A START and a BACK never combine, in either direction: START then BACK
//! during the nap peeks and then arms the BACK pair instead of completing
//! the START one, so nothing stops until the second BACK; the armed START
//! does not carry over either - after the lock, START on the start screen
//! begins a new nap. Same on the alarm: a START arms the stop pair, a BACK
//! re-arms for itself and leaves the alarm ringing, and it takes a second
//! BACK to stop it.
(:test)
function testDelegate_startThenBackDoesNotPair(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    r.detector.testRunMinutes(3, 70, 10.0f);     // monitoring: BACK needs its pair
    r.key(WatchUi.KEY_ENTER);
    var ok = r.view.isPeeking() && r.detector.isActiveState();
    r.key(WatchUi.KEY_ESC);                      // must not complete the START pair
    if (!r.view.isStarted() || !r.detector.testIsRunning()
        || r.detector.getState() == SleepDetector.STATE_SUMMARY) {
        logger.debug("START then BACK must stop nothing: started " + r.view.isStarted()
            + " state " + r.detector.getState());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);                      // the BACK pair, on its own
    if (r.view.isStarted() || r.delegate.testExitRequested() || r.detector.testIsRunning()
        || r.detector.getState() == SleepDetector.STATE_SUMMARY) {
        logger.debug("START then BACK x2: started " + r.view.isStarted() + " state " + r.detector.getState());
        ok = false;
    }
    r.view.testExpireInputLock();
    r.key(WatchUi.KEY_ENTER);                    // a new nap, not a confirmed stop
    if (!r.view.isStarted() || !r.detector.isActiveState() || r.detector.getNapDurationMin() != 30) {
        logger.debug("START after BACK must begin a new nap, started " + r.view.isStarted()
            + " state " + r.detector.getState());
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(10);
    r.startAndRing();
    r.key(WatchUi.KEY_ENTER);
    if (r.detector.getState() != SleepDetector.STATE_ALARM || !r.alarm.isAlarming() || !r.view.testIsHintShowing()) {
        logger.debug("one START on the alarm must only arm, state " + r.detector.getState());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);                      // re-arms for BACK, stops nothing
    if (!r.alarm.isAlarming() || r.detector.getState() != SleepDetector.STATE_ALARM
        || !r.view.testHintIsFor(PowerNapView.BACK_HINT_ALARM)) {
        logger.debug("a BACK after a START on the alarm must only re-arm, alarming " + r.alarm.isAlarming());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (r.alarm.isAlarming() || r.view.isStarted() || r.delegate.testExitRequested()
        || r.detector.getState() == SleepDetector.STATE_SUMMARY) {
        logger.debug("BACK x2 after a START on the alarm must stop it and go to the start screen, no summary");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! During a nap UP, DOWN and a single START only peek: the card shows,
//! nothing stops, nothing changes the duration; taps are ignored altogether.
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
    if (r.delegate.testExitRequested()) {
        logger.debug("nothing here may exit");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! On the ringing alarm UP/DOWN do nothing; one BACK stops the alarm and
//! goes back to the start screen: no summary, no popup, no exit, and the
//! lock follows. The first of the two presses neither stops nor quietens
//! the ringing: the ramp is exactly where it was.
(:test)
function testDelegate_backOnAlarmGoesToStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startAndRing();
    var ok = true;
    if (r.detector.getState() != SleepDetector.STATE_ALARM || !r.alarm.isAlarming()) {
        logger.debug("setup: expected the alarm");
        r.cleanup();
        return false;
    }
    r.key(WatchUi.KEY_UP);
    r.key(WatchUi.KEY_DOWN);
    if (r.detector.getState() != SleepDetector.STATE_ALARM || !r.alarm.isAlarming() || r.view.isPeeking()) {
        logger.debug("UP/DOWN on the alarm must do nothing");
        ok = false;
    }
    var phase = r.alarm.getLastRingPhase();
    r.key(WatchUi.KEY_ESC);
    if (!r.alarm.isAlarming() || r.detector.getState() != SleepDetector.STATE_ALARM
        || r.alarm.getLastRingPhase() != phase || r.view.isInputLocked()) {
        logger.debug("the first BACK must leave the alarm ringing exactly as it was, alarming "
            + r.alarm.isAlarming() + " phase " + phase + " -> " + r.alarm.getLastRingPhase());
        ok = false;
    }
    if (!r.view.testIsHintShowing() || !r.view.testHintIsFor(PowerNapView.BACK_HINT_ALARM)) {
        logger.debug("the first BACK on the alarm must show the 'stop alarm' popup");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (r.delegate.testExitRequested() || r.alarm.isAlarming() || r.detector.testIsRunning() || r.view.isStarted()
        || !r.view.isInputLocked() || r.view.testIsHintShowing()
        || r.detector.getState() == SleepDetector.STATE_SUMMARY) {
        logger.debug("BACK x2 on the alarm must go back to the start screen, started " + r.view.isStarted()
            + " exit " + r.delegate.testExitRequested() + " alarming " + r.alarm.isAlarming());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! START twice on the ringing alarm stops it and shows the summary; the
//! first START shows the stop hint and the alarm keeps ringing.
(:test)
function testDelegate_startTwiceOnAlarmShowsSummary(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startAndRing();
    r.key(WatchUi.KEY_ENTER);
    var ok = r.detector.getState() == SleepDetector.STATE_ALARM && r.alarm.isAlarming()
        && r.view.testIsHintShowing() && !r.view.isPeeking();
    if (!ok) {
        logger.debug("one START must only arm and show the hint, state " + r.detector.getState());
    }
    r.key(WatchUi.KEY_ENTER);
    if (r.detector.getState() != SleepDetector.STATE_SUMMARY || r.alarm.isAlarming() || r.detector.isCancelled()
        || r.delegate.testExitRequested() || !r.view.isInputLocked() || r.view.testIsHintShowing()) {
        logger.debug("START x2 must stop the alarm and show the summary, state " + r.detector.getState());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! START twice on the Stay Awake doze alarm stops it and goes back on guard
//! (not the summary), with the doze counted.
(:test)
function testDelegate_startTwiceOnDozeAlarmResumesGuard(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(5);
    r.startAndDoze();
    var alarmed = r.detector.getAlarmReason() == SleepDetector.ALARM_DOZE && r.alarm.isAlarming();
    r.key(WatchUi.KEY_ENTER);
    var stillRinging = r.alarm.isAlarming() && r.detector.getState() == SleepDetector.STATE_ALARM;
    r.key(WatchUi.KEY_ENTER);
    var ok = alarmed && stillRinging && r.detector.getState() == SleepDetector.STATE_MONITORING
        && !r.alarm.isAlarming() && r.detector.getDozeCount() == 1 && r.detector.testIsRunning()
        && !r.delegate.testExitRequested() && r.view.isInputLocked();
    if (!ok) {
        logger.debug("alarmed " + alarmed + " ringing " + stillRinging + " state " + r.detector.getState());
    }
    r.cleanup();
    return ok;
}

//! BACK twice on the Stay Awake guard screen (here during the drowsiness
//! warning) goes back to the start screen: the session ends, no summary, no
//! exit. The first press only shows the "end session" popup - and, as any
//! press in Stay Awake does, counts as proof of being awake.
(:test)
function testDelegate_backInStayAwakeGoesToStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(5);
    r.view.testSetPendingDuration(0);
    r.key(WatchUi.KEY_ENTER);
    r.detector.testRunMinutes(3, 70, 10.0f);
    var warned = r.detector.isDozeWarning();
    r.key(WatchUi.KEY_ESC);
    var ok = warned;
    if (!r.detector.testIsRunning() || !r.view.isStarted() || !r.view.testIsHintShowing()
        || !r.view.testHintIsFor(PowerNapView.BACK_HINT_SESSION)) {
        logger.debug("the first BACK must keep the session and show the 'end session' popup, running "
            + r.detector.testIsRunning() + " hint " + r.view.testIsHintShowing());
        ok = false;
    }
    if (r.detector.getStillMinutes() != 0 || r.detector.isDozeWarning()) {
        logger.debug("a press in Stay Awake must still count as being awake, stillness "
            + r.detector.getStillMinutes());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (r.delegate.testExitRequested() || r.detector.testIsRunning() || r.view.isStarted()
        || r.detector.getState() == SleepDetector.STATE_SUMMARY || r.view.testIsHintShowing()
        || !r.view.isInputLocked()) {
        logger.debug("warned " + warned + " exit " + r.delegate.testExitRequested() + " started " + r.view.isStarted()
            + " state " + r.detector.getState());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! On the summary one BACK goes back to the start screen (it does not leave
//! the app); from there, after the lock, BACK twice leaves.
(:test)
function testDelegate_summaryBackGoesToStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(25);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.cancel();
    var ok = r.detector.getState() == SleepDetector.STATE_SUMMARY;
    r.key(WatchUi.KEY_ESC);
    ok = ok && !r.view.isStarted() && !r.delegate.testExitRequested() && r.view.testGetPendingDuration() == 25
        && r.view.isInputLocked();
    r.view.testExpireInputLock();
    r.key(WatchUi.KEY_ESC);
    ok = ok && !r.delegate.testExitRequested() && r.view.testIsHintShowing();
    r.key(WatchUi.KEY_ESC);
    ok = ok && r.delegate.testExitRequested();
    if (!ok) {
        logger.debug("summary BACK: started " + r.view.isStarted() + " exit " + r.delegate.testExitRequested());
    }
    r.cleanup();
    return ok;
}

//! On the summary START sets up a new nap (start screen, stored duration).
(:test)
function testDelegate_summaryStartBeginsNewNap(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(25);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.cancel();
    var ok = r.detector.getState() == SleepDetector.STATE_SUMMARY;
    r.key(WatchUi.KEY_ENTER);
    ok = ok && !r.view.isStarted() && r.view.testGetPendingDuration() == 25 && !r.delegate.testExitRequested();
    if (!ok) {
        logger.debug("summary START: started " + r.view.isStarted() + " pending " + r.view.testGetPendingDuration());
    }
    r.cleanup();
    return ok;
}

//! Stay Awake end to end: pick 0, START, doze -> doze alarm, START x2 ->
//! back on guard (not the summary), START x2 -> summary even without
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
    r.key(WatchUi.KEY_ENTER);
    r.key(WatchUi.KEY_ENTER);
    if (r.detector.getState() != SleepDetector.STATE_SUMMARY || !r.view.isStarted()) {
        logger.debug("START x2 must show the Stay Awake summary, state " + r.detector.getState());
        ok = false;
    }
    r.view.testExpireInputLock();
    r.key(WatchUi.KEY_ENTER);
    if (r.view.isStarted() || r.view.testGetPendingDuration() == 0) {
        logger.debug("a new session must default to a nap, pending " + r.view.testGetPendingDuration());
        ok = false;
    }
    if (r.delegate.testExitRequested()) {
        logger.debug("nothing in this flow may exit");
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

    // A tap on the "TAP to start" hint itself starts (it must not remove 5 min).
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

//! On the start screen the first BACK shows "Press BACK again to exit" as a
//! banner for the 4 s window and does not leave; a second BACK inside the
//! window leaves the app; after the window a BACK only arms again.
(:test)
function testDelegate_startScreenBackTwiceExits(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    var dc = layoutHelperDc();
    r.key(WatchUi.KEY_ESC);
    var ok = !r.delegate.testExitRequested() && r.view.testIsHintShowing() && !r.view.isStarted();
    var layout = r.view.testBuildLayout(dc);
    var banner = layout.getBannerText();
    if (banner == null || !delegateHelperIsOneOf(banner as String, PowerNapView.HINT_EXIT)) {
        logger.debug("banner after BACK on the start screen: '" + banner + "'");
        ok = false;
    }
    if (!layout.allTextFits()) {
        logger.debug("the exit banner does not fit: " + layout.firstMisfit());
        ok = false;
    }
    r.view.testAdvanceMs(3900);
    if (!r.view.testIsHintShowing()) {
        logger.debug("the hint must last the 4 s window");
        ok = false;
    }
    r.view.testAdvanceMs(200);
    if (r.view.testIsHintShowing() || r.view.testBuildLayout(dc).getBannerText() != null) {
        logger.debug("after 4 s the banner must be gone");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);                       // a late second press only arms again
    if (r.delegate.testExitRequested() || !r.view.testIsHintShowing()) {
        logger.debug("a BACK after the window must not exit");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.delegate.testExitRequested()) {
        logger.debug("BACK twice on the start screen must leave the app");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! BACK on the peek card is BACK on the nap: one press goes back to the
//! start screen, and the first of the two ends nothing. On the Stay Awake
//! doze alarm BACK twice stops the alarm and goes back on guard (the session
//! goes on, the doze is counted).
(:test)
function testDelegate_backOnPeekAndDozeAlarm(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    r.detector.testForceSleep();
    r.key(WatchUi.KEY_UP);                       // peek card
    var peeked = r.view.isPeeking();
    r.key(WatchUi.KEY_ESC);
    var ok = peeked;
    if (!r.view.isStarted() || !r.detector.testIsRunning()
        || !r.view.testHintIsFor(PowerNapView.BACK_HINT_NAP)) {
        logger.debug("peek: the first BACK must end nothing, started " + r.view.isStarted());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!peeked || r.view.isStarted() || r.detector.testIsRunning() || r.delegate.testExitRequested()
        || r.view.isPeeking()) {
        logger.debug("peek then BACK x2: peeked " + peeked + " started " + r.view.isStarted());
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(0);
    r.startAndDoze();
    var alarmed = r.detector.getAlarmReason() == SleepDetector.ALARM_DOZE && r.alarm.isAlarming();
    r.key(WatchUi.KEY_ESC);
    if (!r.alarm.isAlarming() || r.detector.getState() != SleepDetector.STATE_ALARM
        || !r.view.testHintIsFor(PowerNapView.BACK_HINT_ALARM)) {
        logger.debug("doze alarm: the first BACK must leave it ringing, alarming " + r.alarm.isAlarming()
            + " state " + r.detector.getState());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!alarmed || r.alarm.isAlarming() || r.detector.getState() != SleepDetector.STATE_MONITORING
        || !r.detector.testIsRunning() || !r.view.isStarted() || r.detector.getDozeCount() != 1
        || r.delegate.testExitRequested() || !r.view.isInputLocked()) {
        logger.debug("doze alarm BACK x2: alarmed " + alarmed + " state " + r.detector.getState()
            + " started " + r.view.isStarted() + " dozes " + r.detector.getDozeCount());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! A single START during the nap shows the peek card whose footer says that
//! START again stops the nap and shows the stats.
(:test)
function testDelegate_peekFooterTeachesStartTwice(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    r.detector.testForceSleep();
    var unarmed = r.footer();
    r.key(WatchUi.KEY_ENTER);
    var f = r.footer();
    // "START again: stop + stats", "START again: stop" or, on the 176 px
    // Instinct, "Again: stop".
    var ok = r.view.isPeeking() && f.find("gain") != null && f.find("stop") != null
        && !r.view.testIsHintShowing() && r.detector.getState() == SleepDetector.STATE_SLEEPING;
    if (!ok) {
        logger.debug("peek footer '" + f + "' peeking " + r.view.isPeeking());
    }
    if (unarmed.find("BACK x2") == null) {
        logger.debug("the unarmed nap footer must say BACK takes two presses: '" + unarmed + "'");
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
    r.startAndRing();
    for (var i = 0; i < 6; i++) {
        r.key(WatchUi.KEY_ENTER);
    }
    var ok = r.detector.getState() == SleepDetector.STATE_SUMMARY && r.view.isStarted()
        && !r.alarm.isAlarming() && !r.detector.testIsRunning() && !r.delegate.testExitRequested();
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

//! A burst of BACK presses on the Stay Awake doze alarm stops the alarm on
//! the second press and goes back on guard; the lock swallows the rest, so
//! the burst neither ends the session nor leaves the app.
(:test)
function testDelegate_backBurstOnDozeAlarmKeepsGuarding(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(0);
    r.startAndDoze();
    var alarmed = r.detector.getAlarmReason() == SleepDetector.ALARM_DOZE;
    r.key(WatchUi.KEY_ESC);
    var stillRinging = r.alarm.isAlarming() && r.detector.getState() == SleepDetector.STATE_ALARM;
    r.key(WatchUi.KEY_ESC);
    var afterOne = stillRinging && !r.alarm.isAlarming()
        && r.detector.getState() == SleepDetector.STATE_MONITORING && r.view.isInputLocked();
    for (var i = 0; i < 4; i++) {
        r.key(WatchUi.KEY_ESC);                  // inside the lock: swallowed
    }
    var ok = alarmed && afterOne && !r.alarm.isAlarming() && r.detector.getState() == SleepDetector.STATE_MONITORING
        && r.detector.testIsRunning() && r.view.isStarted() && r.detector.getDozeCount() == 1
        && !r.delegate.testExitRequested();
    if (!ok) {
        logger.debug("alarmed " + alarmed + " afterOne " + afterOne + " state " + r.detector.getState()
            + " started " + r.view.isStarted() + " exit " + r.delegate.testExitRequested());
    }
    r.cleanup();
    return ok;
}

//! The input lock never traps the user. BACK every 700 ms from the alarm:
//! the 1st press arms, the 2nd stops the alarm and goes back to the start
//! screen, the 3rd and 4th (0.7 s and 1.4 s into the 1.5 s lock) are
//! swallowed without extending it, the 5th (2.1 s) shows "Press BACK again
//! to exit" and the 6th leaves the app. START every 700 ms: stops at the 2nd
//! press, the 3rd and 4th are swallowed, the 5th starts a new nap set-up.
(:test)
function testDelegate_lockDoesNotTrapRepeatedPresses(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startAndRing();
    var ok = true;
    var exitAt = -1;
    for (var i = 1; i <= 9 && exitAt < 0; i++) {
        r.key(WatchUi.KEY_ESC);
        if (i == 1 && (!r.alarm.isAlarming() || !r.view.testIsHintShowing())) {
            logger.debug("the 1st BACK must only arm, alarming " + r.alarm.isAlarming());
            ok = false;
        }
        if (i == 2 && (r.view.isStarted() || r.alarm.isAlarming())) {
            logger.debug("the 2nd BACK must stop the alarm and go back to the start screen");
            ok = false;
        }
        if ((i == 3 || i == 4) && (r.view.isStarted() || r.view.testIsHintShowing())) {
            logger.debug("BACK " + i + " falls inside the lock and must be swallowed");
            ok = false;
        }
        if (i == 5 && !r.view.testIsHintShowing()) {
            logger.debug("the 5th BACK (after the lock) must show the exit hint");
            ok = false;
        }
        if (r.delegate.testExitRequested()) {
            exitAt = i;
        }
        r.view.testAdvanceMs(700);
    }
    if (exitAt != 6) {
        logger.debug("BACK every 700 ms from the alarm must leave the app at the 6th press, got " + exitAt);
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(10);
    r.startAndRing();
    r.key(WatchUi.KEY_ENTER);
    r.view.testAdvanceMs(700);
    r.key(WatchUi.KEY_ENTER);                    // stops: summary, lock starts
    if (r.detector.getState() != SleepDetector.STATE_SUMMARY || !r.view.isInputLocked()) {
        logger.debug("START every 700 ms must stop at the second press, state " + r.detector.getState());
        ok = false;
    }
    r.view.testAdvanceMs(700);
    r.key(WatchUi.KEY_ENTER);                    // 0.7 s into the lock: swallowed
    r.view.testAdvanceMs(700);
    r.key(WatchUi.KEY_ENTER);                    // 1.4 s: still swallowed
    if (!r.view.isStarted() || r.detector.getState() != SleepDetector.STATE_SUMMARY) {
        logger.debug("presses inside the 1.5 s lock must be swallowed, started " + r.view.isStarted());
        ok = false;
    }
    r.view.testAdvanceMs(700);
    r.key(WatchUi.KEY_ENTER);                    // 2.1 s: the lock is over, acts
    if (r.view.isStarted()) {
        logger.debug("a press after the lock must act (start screen)");
        ok = false;
    }
    if (r.delegate.testExitRequested()) {
        logger.debug("START presses must never exit");
        ok = false;
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
//! that nap but read when the start screen comes back, so the "Alarm by"
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

// -- Start-screen menu and the alarm preview ----------------------------------

//! MENU opens the start-screen menu only on the start screen: during a nap,
//! on the alarm and on the summary the key is consumed and no menu opens.
(:test)
function testDelegate_menuOnlyOnStartScreen(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.key(WatchUi.KEY_MENU);
    var ok = r.delegate.testMenuRequests() == 1 && !r.view.isStarted();
    r.startNap();
    if (!r.key(WatchUi.KEY_MENU) || r.delegate.testMenuRequests() != 1 || !r.detector.isActiveState()) {
        logger.debug("MENU during a nap must be consumed without a menu");
        ok = false;
    }
    r.detector.testForceSleep();
    r.detector.testAdvanceClock(31 * 60);
    r.detector.testTick();
    r.key(WatchUi.KEY_MENU);
    if (r.delegate.testMenuRequests() != 1 || !r.alarm.isAlarming()) {
        logger.debug("MENU on the alarm must be consumed without a menu");
        ok = false;
    }
    r.key(WatchUi.KEY_ENTER);
    r.key(WatchUi.KEY_ENTER);
    r.view.testExpireInputLock();
    r.key(WatchUi.KEY_MENU);
    if (r.delegate.testMenuRequests() != 1 || r.detector.getState() != SleepDetector.STATE_SUMMARY) {
        logger.debug("MENU on the summary must not open the menu");
        ok = false;
    }
    if (r.delegate.testExitRequested()) {
        logger.debug("MENU must never exit");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! "Test alarm": the preview plays on the start screen; while it runs
//! START, UP, DOWN and taps do nothing, and one BACK ends it and returns to
//! the start screen (no exit, no nap). It never starts during a nap.
(:test)
function testDelegate_previewBackReturnsToStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.view.startPreview();
    var ok = r.alarm.isPreviewing() && !r.view.isStarted() && r.alarm.testGetVibrateCount() == 1;
    r.key(WatchUi.KEY_ENTER);
    r.key(WatchUi.KEY_UP);
    r.key(WatchUi.KEY_DOWN);
    r.delegate.handleTap(10);
    if (!r.alarm.isPreviewing() || r.view.isStarted() || r.view.testGetPendingDuration() != 30) {
        logger.debug("keys during the preview must do nothing: started " + r.view.isStarted()
            + " pending " + r.view.testGetPendingDuration());
        ok = false;
    }
    r.alarm.testPreviewTick();
    r.key(WatchUi.KEY_ESC);
    if (r.alarm.isPreviewing() || r.view.isStarted() || r.delegate.testExitRequested()
        || r.alarm.testGetVibrateCount() != 2) {
        logger.debug("BACK must end the preview and show the start screen");
        ok = false;
    }
    r.alarm.testPreviewTick();               // a stale tick after BACK plays nothing
    if (r.alarm.testGetVibrateCount() != 2) {
        logger.debug("no output after the preview was stopped");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);                  // the start screen asks for a second BACK
    if (r.delegate.testExitRequested() || !r.view.testIsHintShowing()) {
        logger.debug("the first BACK on the start screen after the preview must only arm");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.delegate.testExitRequested()) {
        logger.debug("BACK twice on the start screen after the preview must exit");
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(30);
    r.startNap();
    r.view.startPreview();
    if (r.alarm.isPreviewing() || r.alarm.testGetVibrateCount() != 0 || r.alarm.testGetBlockedDeliveries() != 0) {
        logger.debug("the preview must never start during a nap");
        ok = false;
    }
    r.cleanup();
    return ok;
}

// -- Adversarial review of v1.1.0 --------------------------------------------

//! A first START made on the nap screen does not count on the alarm screen:
//! a START (peek) 3 s before the alarm starts, then one START on the alarm,
//! only arms again (the alarm keeps ringing); the pair completes with a
//! second START on the alarm. (Before the fix one press on the alarm screen
//! silenced it.) A BACK 3 s before the alarm ends the nap for good: no
//! alarm ever starts and nothing rings on the start screen.
(:test)
function testDelegate_pressBeforeAlarmDoesNotPairWithAlarmPress(logger as Test.Logger) as Boolean {
    var ok = true;
    var r = new DelegateRig(10);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testAdvanceClock(10 * 60 - 3);
    r.detector.testTick();
    r.key(WatchUi.KEY_ENTER);                    // arms on the nap screen (peek)
    var armedOnNap = r.detector.getState() != SleepDetector.STATE_ALARM && r.view.isPeeking();
    r.detector.testAdvanceClock(2);
    r.detector.testTick();                       // the alarm starts 3 s later
    var alarmed = r.detector.getState() == SleepDetector.STATE_ALARM && r.alarm.isAlarming();
    r.key(WatchUi.KEY_ENTER);                    // one press on the alarm: must only arm
    if (!armedOnNap || !alarmed || !r.alarm.isAlarming() || r.detector.getState() != SleepDetector.STATE_ALARM
        || r.delegate.testExitRequested() || !r.view.testIsHintShowing()) {
        logger.debug("one START on the alarm after a nap START acted: state "
            + r.detector.getState() + " alarming " + r.alarm.isAlarming() + " exit " + r.delegate.testExitRequested());
        ok = false;
    }
    r.key(WatchUi.KEY_ENTER);                    // the pair on the alarm screen
    if (r.alarm.isAlarming() || r.delegate.testExitRequested() || r.detector.getState() != SleepDetector.STATE_SUMMARY) {
        logger.debug("the second START on the alarm must complete the pair, state " + r.detector.getState());
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(10);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testAdvanceClock(10 * 60 - 3);
    r.detector.testTick();
    r.backTwice();                               // ends the nap 3 s before the alarm
    r.detector.testAdvanceClock(5);
    r.detector.testTick();
    if (r.view.isStarted() || r.alarm.isAlarming() || r.detector.testIsRunning() || r.delegate.testExitRequested()
        || r.alarm.testGetVibrateCount() != 0) {
        logger.debug("BACK before the alarm must end the nap for good: alarming " + r.alarm.isAlarming()
            + " vibrations " + r.alarm.testGetVibrateCount());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! The armed footer belongs to the screen of the first press: a START
//! (peek, footer "START again: stop + stats") 2 s before the alarm; once
//! the alarm has started the footer is the alarm's own, with no hint, until
//! a press on the alarm.
(:test)
function testDelegate_armedFooterDoesNotSurviveAlarmStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testAdvanceClock(10 * 60 - 2);
    r.detector.testTick();
    r.key(WatchUi.KEY_ENTER);
    var armed = r.view.isPeeking() && r.footer().find("gain") != null;
    r.detector.testAdvanceClock(1);
    r.detector.testTick();                       // the alarm starts
    var f = r.footer();
    var ok = armed && r.detector.getState() == SleepDetector.STATE_ALARM && !r.view.testIsHintShowing()
        && f.find("gain") == null && f.find("BACK") != null;
    if (!ok) {
        logger.debug("armed " + armed + " hint after alarm " + r.view.testIsHintShowing() + " footer '" + f + "'");
    }
    r.cleanup();
    return ok;
}

//! A peek card from just before a doze alarm does not come back when the
//! alarm is dismissed: the guard screen shows.
(:test)
function testDelegate_peekDoesNotSurviveDozeDismissal(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(0);
    r.key(WatchUi.KEY_ENTER);
    r.detector.testRunMinutes(4, 70, 10.0f);
    r.detector.testRunSeconds(58, 70, 10.0f);
    r.key(WatchUi.KEY_UP);                       // peek (also resets the still run: no doze yet)
    var peeked = r.view.isPeeking();
    r.detector.testRunMinutes(5, 70, 10.0f);     // a doze alarm 5 still minutes later
    var alarmed = r.detector.getAlarmReason() == SleepDetector.ALARM_DOZE;
    r.view.showPeek();                           // as if UP was pressed 1 s before the alarm
    r.key(WatchUi.KEY_ENTER);
    r.key(WatchUi.KEY_ENTER);
    var ok = peeked && alarmed && r.detector.getState() == SleepDetector.STATE_MONITORING && !r.view.isPeeking();
    if (!ok) {
        logger.debug("peeked " + peeked + " alarmed " + alarmed + " state " + r.detector.getState()
            + " peeking after dismissal " + r.view.isPeeking());
    }
    r.cleanup();
    return ok;
}

// -- BACK walks back to the start screen, and only there leaves ---------------

//! The owner's rule end to end, in pairs: from the nap alarm BACK x2 goes to
//! the start screen and BACK x2 there leaves; from the doze alarm BACK x2
//! goes back on guard, BACK x2 to the start screen, BACK x2 leaves. Nothing
//! before the start screen leaves the app, and no single press acts.
(:test)
function testDelegate_backWalksBackToStartThenExits(logger as Test.Logger) as Boolean {
    var ok = true;
    var r = new DelegateRig(10);
    r.startAndRing();
    r.backTwice();
    if (r.view.isStarted() || r.alarm.isAlarming() || r.delegate.testExitRequested() || r.view.testIsHintShowing()) {
        logger.debug("nap alarm: BACK x2 must reach the start screen without leaving");
        ok = false;
    }
    r.view.testExpireInputLock();
    r.key(WatchUi.KEY_ESC);
    if (r.delegate.testExitRequested() || !r.view.testIsHintShowing()) {
        logger.debug("start screen: the first BACK must only show the exit hint");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.delegate.testExitRequested()) {
        logger.debug("nap alarm: BACK x2 on the start screen must leave");
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(0);
    r.startAndDoze();
    r.backTwice();
    if (r.detector.getState() != SleepDetector.STATE_MONITORING || !r.view.isStarted() || r.alarm.isAlarming()
        || r.view.testIsHintShowing()) {
        logger.debug("doze alarm: BACK x2 must go back on guard, state " + r.detector.getState());
        ok = false;
    }
    r.view.testExpireInputLock();
    r.backTwice();
    if (r.view.isStarted() || r.detector.testIsRunning() || r.delegate.testExitRequested() || r.view.testIsHintShowing()) {
        logger.debug("guard: BACK x2 must reach the start screen without leaving");
        ok = false;
    }
    r.view.testExpireInputLock();
    r.key(WatchUi.KEY_ESC);
    if (r.delegate.testExitRequested()) {
        logger.debug("one BACK on the start screen must not leave");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.delegate.testExitRequested()) {
        logger.debug("guard: BACK x2 on the start screen must leave");
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! A right swipe is the touch BACK, but outside a session only: on the start
//! screen the first one shows the exit hint and the second leaves; on the
//! summary it goes back to the start screen. During a nap and on the alarm
//! every swipe does nothing at all - it does not even arm the BACK pair, so
//! no number of swipes can end a nap or stop an alarm. That is the one
//! exception to "a right swipe is BACK".
(:test)
function testDelegate_swipeRightIsBackOutsideTheNap(logger as Test.Logger) as Boolean {
    var ok = true;
    var r = new DelegateRig(30);
    if (!r.delegate.handleSwipe(WatchUi.SWIPE_RIGHT) || r.delegate.testExitRequested() || !r.view.testIsHintShowing()) {
        logger.debug("start screen: the first right swipe must only show the exit hint");
        ok = false;
    }
    r.delegate.handleSwipe(WatchUi.SWIPE_RIGHT);
    if (!r.delegate.testExitRequested()) {
        logger.debug("start screen: a second right swipe must leave");
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(30);
    r.startNap();
    r.detector.testForceSleep();
    for (var i = 0; i < 3; i++) {
        if (!r.delegate.handleSwipe(WatchUi.SWIPE_RIGHT)) {
            logger.debug("nap: a swipe must be consumed");
            ok = false;
        }
    }
    if (!r.view.isStarted() || r.detector.getState() != SleepDetector.STATE_SLEEPING || r.view.testIsHintShowing()) {
        logger.debug("nap: swipes must be ignored, state " + r.detector.getState());
        ok = false;
    }
    r.detector.testAdvanceClock(31 * 60);
    r.detector.testTick();
    for (var i = 0; i < 3; i++) {
        if (!r.delegate.handleSwipe(WatchUi.SWIPE_RIGHT)) {
            logger.debug("alarm: a swipe must be consumed");
            ok = false;
        }
    }
    if (!r.alarm.isAlarming() || !r.view.isStarted()
        || r.detector.getState() != SleepDetector.STATE_ALARM || r.view.testIsHintShowing()) {
        logger.debug("alarm: swipes must do nothing, not even arm the BACK pair; alarming "
            + r.alarm.isAlarming() + " hint " + r.view.testIsHintShowing());
        ok = false;
    }
    r.key(WatchUi.KEY_ENTER);                    // the buttons still work
    r.key(WatchUi.KEY_ENTER);                    // summary
    r.view.testExpireInputLock();
    r.delegate.handleSwipe(WatchUi.SWIPE_RIGHT);
    if (r.view.isStarted() || r.delegate.testExitRequested()) {
        logger.debug("summary: a right swipe must go back to the start screen, started " + r.view.isStarted());
        ok = false;
    }
    r.cleanup();
    return ok;
}

//! Opening the menu or the preview forgets a first BACK: BACK, preview,
//! BACK (ends the preview), BACK only arms, it does not leave.
(:test)
function testDelegate_previewForgetsArmedExit(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.key(WatchUi.KEY_ESC);                      // armed: "Press BACK again to exit"
    r.view.startPreview();
    r.key(WatchUi.KEY_ESC);                      // ends the preview
    r.key(WatchUi.KEY_ESC);                      // must only arm again
    var ok = !r.alarm.isPreviewing() && !r.delegate.testExitRequested() && r.view.testIsHintShowing();
    if (!ok) {
        logger.debug("previewing " + r.alarm.isPreviewing() + " exit " + r.delegate.testExitRequested());
    }
    r.cleanup();
    return ok;
}

// -- The BACK contract, over every screen -------------------------------------
//
// The owner's rule, written down in CLAUDE.md and CONTRIBUTING.md:
//   * BACK goes back one level and never leaves the app below the start
//     screen; pressed again it walks on to the start screen;
//   * wherever that step would END something - a nap, a ringing alarm, a
//     Stay Awake session - it takes two presses inside the 4 s window, after
//     a popup saying what the second one does, and the first press changes
//     nothing at all;
//   * where nothing is lost it acts on one press: the alarm preview, the
//     first two minutes (calibrating) and the summary;
//   * only the start screen leaves, on a second BACK inside that window,
//     after "Press BACK again to exit";
//   * a right swipe is that same BACK outside a session only.
// The tests below walk the rule over EVERY screen rather than one path at a
// time, so a screen added later has to be added to BACK_SCREENS and cannot
// quietly get a BACK of its own. The wording of the pair on the start screen
// is covered by testDelegate_startScreenBackTwiceExits, the swipe by
// testDelegate_swipeRightIsBackOutsideTheNap.

//! Every screen the app can show below the start screen.
(:debug)
const BACK_SCREENS = ["alarm preview", "calibrating", "monitoring", "sleeping", "nap peek",
                      "nap alarm", "stay awake guard", "stay awake peek", "doze alarm",
                      "nap summary", "no-sleep summary", "stay awake summary"] as Array<String>;

//! Which popup that screen's first BACK shows (PowerNapView.BACK_HINT_*),
//! or -1 where BACK acts on a single press.
(:debug)
const BACK_HINTS = [-1, -1, 0, 0, 0, 1, 2, 2, 1, -1, -1, -1] as Array<Number>;

//! How many BACK presses that screen is away from the start screen: one
//! where nothing is lost, two where the pair is asked for, and four from the
//! doze alarm, which sits on top of the Stay Awake guard and so takes the
//! guard's pair too.
(:debug)
const BACK_STEPS = [1, 1, 2, 2, 2, 2, 2, 2, 4, 1, 1, 1] as Array<Number>;

//! A rig sitting on BACK_SCREENS[i], with the input lock already expired so
//! the next press is the one under test.
(:debug)
function delegateHelperOpenScreen(i as Number) as DelegateRig {
    var r = new DelegateRig((i >= 6 && i <= 8) || i == 11 ? 0 : 30);
    if (i == 0) {                                     // alarm preview ("Test alarm")
        r.view.startPreview();
    } else if (i == 1) {                              // calibrating
        r.startCalibrating();
    } else if (i == 2) {                              // monitoring
        r.startNap();
        r.detector.testRunMinutes(3, 70, 10.0f);
    } else if (i == 3) {                              // sleeping
        r.startNap();
        r.detector.testForceSleep();
    } else if (i == 4) {                              // peek card over the nap
        r.startNap();
        r.detector.testForceSleep();
        r.key(WatchUi.KEY_UP);
    } else if (i == 5) {                              // the nap alarm, ringing
        r.startAndRing();
    } else if (i == 6) {                              // Stay Awake, on guard
        r.key(WatchUi.KEY_ENTER);
        r.detector.testRunMinutes(2, 70, 10.0f);
    } else if (i == 7) {                              // peek card over the guard
        r.key(WatchUi.KEY_ENTER);
        r.detector.testRunMinutes(2, 70, 10.0f);
        r.key(WatchUi.KEY_UP);
    } else if (i == 8) {                              // the doze alarm, ringing
        r.startAndDoze();
    } else if (i == 9) {                              // summary of a finished nap
        r.startAndRing();
        r.key(WatchUi.KEY_ENTER);
        r.key(WatchUi.KEY_ENTER);
    } else if (i == 10) {                             // summary without any sleep
        r.startNap();
        r.key(WatchUi.KEY_ENTER);
        r.key(WatchUi.KEY_ENTER);
    } else {                                          // Stay Awake summary
        r.key(WatchUi.KEY_ENTER);
        r.detector.testRunMinutes(2, 70, 10.0f);
        r.key(WatchUi.KEY_ENTER);
        r.key(WatchUi.KEY_ENTER);
    }
    r.view.testExpireInputLock();
    return r;
}

//! True when the rig is back on the start screen (no session, no preview).
(:debug)
function delegateHelperOnStartScreen(r as DelegateRig) as Boolean {
    return !r.view.isStarted() && !r.alarm.isPreviewing();
}

//! No screen below the start screen may leave the app on one BACK. Where the
//! contract asks for a pair, that one press must also have ENDED nothing -
//! the session is still running and the popup names what would be lost;
//! where it does not, BACK acts at once and shows no popup. Only the start
//! screen shows the exit popup.
(:test)
function testDelegate_backNeverLeavesBelowTheStartScreen(logger as Test.Logger) as Boolean {
    var ok = true;
    for (var i = 0; i < BACK_SCREENS.size(); i++) {
        var r = delegateHelperOpenScreen(i);
        if (delegateHelperOnStartScreen(r) && i != 0) {
            logger.debug(BACK_SCREENS[i] + ": the test did not reach that screen");
            ok = false;
        }
        var running = r.detector.testIsRunning();
        var alarming = r.alarm.isAlarming();
        r.key(WatchUi.KEY_ESC);
        if (r.delegate.testExitRequested()) {
            logger.debug(BACK_SCREENS[i] + ": one BACK left the app");
            ok = false;
        }
        if (BACK_HINTS[i] < 0) {
            if (r.view.testIsHintShowing()) {
                logger.debug(BACK_SCREENS[i] + ": BACK must act at once, not ask for a second press");
                ok = false;
            }
        } else {
            if (!r.view.testIsHintShowing() || !r.view.testHintIsFor(BACK_HINTS[i])) {
                logger.debug(BACK_SCREENS[i] + ": the first BACK must show the popup for "
                    + BACK_HINTS[i] + ", showing " + r.view.testIsHintShowing());
                ok = false;
            }
            if (r.detector.testIsRunning() != running || r.alarm.isAlarming() != alarming
                || !r.view.isStarted() || r.view.isInputLocked()) {
                logger.debug(BACK_SCREENS[i] + ": the first BACK must end nothing - running " + running
                    + " -> " + r.detector.testIsRunning() + ", alarming " + alarming
                    + " -> " + r.alarm.isAlarming() + ", started " + r.view.isStarted());
                ok = false;
            }
        }
        r.cleanup();
    }
    return ok;
}

//! From every screen, BACK pressed again and again walks to the start screen
//! in the documented number of presses, without leaving on the way; and once
//! there it takes two more presses to leave, never one.
(:test)
function testDelegate_backReachesTheStartScreenFromEveryScreen(logger as Test.Logger) as Boolean {
    var ok = true;
    for (var i = 0; i < BACK_SCREENS.size(); i++) {
        var r = delegateHelperOpenScreen(i);
        var steps = 0;
        while (!delegateHelperOnStartScreen(r) && steps < 8) {
            r.key(WatchUi.KEY_ESC);
            steps++;
            r.view.testExpireInputLock();
            if (r.delegate.testExitRequested()) {
                logger.debug(BACK_SCREENS[i] + ": left the app after " + steps + " BACK press(es)");
                ok = false;
                break;
            }
        }
        if (!delegateHelperOnStartScreen(r)) {
            logger.debug(BACK_SCREENS[i] + ": BACK never reached the start screen");
            ok = false;
        } else if (steps != BACK_STEPS[i]) {
            logger.debug(BACK_SCREENS[i] + ": took " + steps + " BACK press(es), expected " + BACK_STEPS[i]);
            ok = false;
        }
        if (!r.delegate.testExitRequested()) {
            r.key(WatchUi.KEY_ESC);               // on the start screen: arms only
            if (r.delegate.testExitRequested()) {
                logger.debug(BACK_SCREENS[i] + ": the first BACK on the start screen left the app");
                ok = false;
            } else if (!r.view.testIsHintShowing()) {
                logger.debug(BACK_SCREENS[i] + ": the start screen must show the exit hint");
                ok = false;
            }
            r.key(WatchUi.KEY_ESC);               // and the second one leaves
            if (!r.delegate.testExitRequested()) {
                logger.debug(BACK_SCREENS[i] + ": BACK twice on the start screen did not leave");
                ok = false;
            }
        }
        r.cleanup();
    }
    return ok;
}
