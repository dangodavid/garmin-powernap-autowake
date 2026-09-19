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
// Key model under test (v1.1.0): BACK x2 within 4 s exits from every nap and
// alarm screen (no summary), START x2 stops the nap or the alarm and shows
// the summary (the doze alarm goes back on guard), a BACK and a START never
// form a pair, the first press shows a hint, the summary's BACK exits with
// one press, and the 1.5 s input lock after a stop is never extended by
// presses. Two presses within the confirmation window come from consecutive
// calls (well inside 4 s); the window itself is covered by
// testReg_confirmPressRules and testDelegate_firstBackShowsExitHint.
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

    //! Start a 10 min nap, force sleep and let the alarm become due.
    function startAndRing() as Void {
        startNap();
        detector.testForceSleep();
        detector.testAdvanceClock(10 * 60);
        detector.testTick();
    }

    //! Start a Stay Awake session and let a doze alarm ring.
    function startAndDoze() as Void {
        view.testSetPendingDuration(0);
        key(WatchUi.KEY_ENTER);
        detector.testRunMinutes(5, 70, 10.0f);
    }

    //! The footer text of the current screen.
    function footer() as String {
        var f = view.testBuildLayout(layoutHelperDc()).getFooterText();
        return (f == null) ? "" : f as String;
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

//! START begins a nap with the shown duration; one BACK only arms (the nap
//! goes on); a second BACK within the window leaves the app: nap ended, no
//! summary.
(:test)
function testDelegate_backTwiceDuringNapExits(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(20);
    r.startNap();
    var ok = true;
    if (!r.view.isStarted() || r.detector.getNapDurationMin() != 20 || r.detector.isStayAwake()) {
        logger.debug("START must begin a 20 min nap, got " + r.detector.getNapDurationMin());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.view.isStarted() || !r.detector.isActiveState() || r.delegate.testExitRequested()) {
        logger.debug("one BACK must not stop the nap");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.delegate.testExitRequested() || r.detector.testIsRunning() || r.alarm.isAlarming()) {
        logger.debug("second BACK must leave the app, exit " + r.delegate.testExitRequested()
            + " running " + r.detector.testIsRunning());
        ok = false;
    }
    if (r.detector.getState() == SleepDetector.STATE_SUMMARY) {
        logger.debug("BACK x2 must not show a summary");
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

//! A BACK and a START never combine into a pair: BACK then START neither
//! exits nor stops (the START re-arms for its own pair), START then BACK on
//! the alarm neither stops nor exits.
(:test)
function testDelegate_backThenStartIsNotAPair(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    r.key(WatchUi.KEY_ESC);
    r.key(WatchUi.KEY_ENTER);
    var ok = !r.delegate.testExitRequested() && r.detector.isActiveState() && r.view.isPeeking();
    if (!ok) {
        logger.debug("BACK then START: exit " + r.delegate.testExitRequested() + " state " + r.detector.getState());
    }
    r.key(WatchUi.KEY_ENTER);                    // the START pair completes on its own
    if (r.detector.getState() != SleepDetector.STATE_SUMMARY || r.delegate.testExitRequested()) {
        logger.debug("START after BACK+START must complete the START pair, state " + r.detector.getState());
        ok = false;
    }
    r.cleanup();

    r = new DelegateRig(10);
    r.startAndRing();
    r.key(WatchUi.KEY_ENTER);
    r.key(WatchUi.KEY_ESC);
    if (r.detector.getState() != SleepDetector.STATE_ALARM || !r.alarm.isAlarming() || r.delegate.testExitRequested()) {
        logger.debug("START then BACK on the alarm must neither stop nor exit, state " + r.detector.getState());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.delegate.testExitRequested() || r.alarm.isAlarming()) {
        logger.debug("BACK after START+BACK must complete the BACK pair");
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

//! On the ringing alarm UP/DOWN do nothing and one BACK only arms (the alarm
//! keeps ringing, the exit hint shows); the second BACK stops the alarm and
//! leaves the app without a summary.
(:test)
function testDelegate_backTwiceOnAlarmExits(logger as Test.Logger) as Boolean {
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
    r.key(WatchUi.KEY_ESC);
    if (r.detector.getState() != SleepDetector.STATE_ALARM || !r.alarm.isAlarming()
        || !r.view.testIsHintShowing() || r.delegate.testExitRequested()) {
        logger.debug("one BACK must not stop the alarm, hint " + r.view.testIsHintShowing());
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);
    if (!r.delegate.testExitRequested() || r.alarm.isAlarming() || r.detector.testIsRunning()
        || r.detector.getState() == SleepDetector.STATE_SUMMARY) {
        logger.debug("BACK x2 on the alarm must exit without a summary, state " + r.detector.getState());
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

//! BACK twice on the Stay Awake guard screen leaves the app (the press also
//! counts as being awake first).
(:test)
function testDelegate_backTwiceInStayAwakeExits(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(5);
    r.view.testSetPendingDuration(0);
    r.key(WatchUi.KEY_ENTER);
    r.detector.testRunMinutes(3, 70, 10.0f);
    var warned = r.detector.isDozeWarning();
    r.key(WatchUi.KEY_ESC);
    var ok = warned && !r.detector.isDozeWarning() && r.detector.testIsRunning() && !r.delegate.testExitRequested();
    r.key(WatchUi.KEY_ESC);
    ok = ok && r.delegate.testExitRequested() && !r.detector.testIsRunning()
        && r.detector.getState() != SleepDetector.STATE_SUMMARY;
    if (!ok) {
        logger.debug("warned " + warned + " exit " + r.delegate.testExitRequested() + " state " + r.detector.getState());
    }
    r.cleanup();
    return ok;
}

//! On the summary BACK exits with a single press.
(:test)
function testDelegate_summaryBackExitsWithOnePress(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(25);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.cancel();
    var ok = r.detector.getState() == SleepDetector.STATE_SUMMARY;
    r.key(WatchUi.KEY_ESC);
    ok = ok && r.delegate.testExitRequested();
    if (!ok) {
        logger.debug("summary BACK must exit at once");
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

//! The first BACK shows the exit hint as a banner and in the footer, for the
//! 4 s window: after it the hint is gone, the footer is back to normal, and
//! a BACK then only arms again (no exit).
(:test)
function testDelegate_firstBackShowsExitHint(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(30);
    r.startNap();
    var dc = layoutHelperDc();
    var before = r.footer();
    r.key(WatchUi.KEY_ESC);
    var ok = r.view.testIsHintShowing();
    var layout = r.view.testBuildLayout(dc);
    var banner = layout.getBannerText();
    if (banner == null || !delegateHelperIsOneOf(banner as String, PowerNapView.HINT_EXIT)) {
        logger.debug("banner after BACK: '" + banner + "'");
        ok = false;
    }
    if (!delegateHelperIsOneOf(r.footer(), PowerNapView.HINT_EXIT)) {
        logger.debug("footer after BACK: '" + r.footer() + "'");
        ok = false;
    }
    if (!layout.allTextFits()) {
        logger.debug("banner or footer does not fit: " + layout.firstMisfit());
        ok = false;
    }
    r.view.testAdvanceMs(3900);
    if (!r.view.testIsHintShowing()) {
        logger.debug("the hint must last the 4 s window");
        ok = false;
    }
    r.view.testAdvanceMs(200);
    if (r.view.testIsHintShowing() || r.view.testBuildLayout(dc).getBannerText() != null
        || !r.footer().equals(before)) {
        logger.debug("after 4 s: hint " + r.view.testIsHintShowing() + " footer '" + r.footer() + "'");
        ok = false;
    }
    r.key(WatchUi.KEY_ESC);                       // a late second press only arms again
    if (r.delegate.testExitRequested() || !r.detector.isActiveState() || !r.view.testIsHintShowing()) {
        logger.debug("a BACK after the window must not exit");
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
        logger.debug("unarmed nap footer must teach BACK x2: '" + unarmed + "'");
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

//! A burst of BACK presses on the Stay Awake doze alarm leaves the app at
//! the second press (BACK x2 exits everywhere); the alarm is stopped.
(:test)
function testDelegate_backBurstOnDozeAlarmExits(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(0);
    r.startAndDoze();
    var alarmed = r.detector.getAlarmReason() == SleepDetector.ALARM_DOZE;
    r.key(WatchUi.KEY_ESC);
    var afterOne = !r.delegate.testExitRequested() && r.alarm.isAlarming();
    for (var i = 0; i < 4; i++) {
        r.key(WatchUi.KEY_ESC);
    }
    var ok = alarmed && afterOne && r.delegate.testExitRequested() && !r.alarm.isAlarming()
        && !r.detector.testIsRunning();
    if (!ok) {
        logger.debug("alarmed " + alarmed + " afterOne " + afterOne + " exit " + r.delegate.testExitRequested());
    }
    r.cleanup();
    return ok;
}

//! The input lock never traps the user: on the alarm, BACK every 700 ms
//! exits at the second press; START every 700 ms stops at the second, the
//! third and fourth (0.7 s and 1.4 s into the 1.5 s lock) are swallowed
//! without extending it, and the fifth (2.1 s) starts a new nap set-up.
(:test)
function testDelegate_lockDoesNotTrapRepeatedPresses(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startAndRing();
    r.key(WatchUi.KEY_ESC);
    r.view.testAdvanceMs(700);
    r.key(WatchUi.KEY_ESC);
    var ok = r.delegate.testExitRequested() && !r.alarm.isAlarming();
    if (!ok) {
        logger.debug("BACK every 700 ms must exit at the second press");
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
    r.key(WatchUi.KEY_ESC);                  // the start screen's BACK exits as usual
    if (!r.delegate.testExitRequested()) {
        logger.debug("BACK on the start screen after the preview must exit");
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

//! A first press made on the nap screen does not count on the alarm screen:
//! a START (peek) or a BACK 3 s before the alarm starts, then one press on
//! the alarm, only arms again (the alarm keeps ringing); the pair completes
//! with a second press on the alarm. (Before the fix one press on the alarm
//! screen silenced it or closed the app.)
(:test)
function testDelegate_pressBeforeAlarmDoesNotPairWithAlarmPress(logger as Test.Logger) as Boolean {
    var ok = true;
    var keys = [WatchUi.KEY_ENTER, WatchUi.KEY_ESC] as Array<Number>;
    for (var i = 0; i < keys.size(); i++) {
        var r = new DelegateRig(10);
        r.startNap();
        r.detector.testForceSleep();
        r.detector.testAdvanceClock(10 * 60 - 3);
        r.detector.testTick();
        r.key(keys[i]);                          // arms on the nap screen (peek / exit hint)
        var armedOnNap = r.detector.getState() != SleepDetector.STATE_ALARM;
        r.detector.testAdvanceClock(2);
        r.detector.testTick();                   // the alarm starts 3 s later
        var alarmed = r.detector.getState() == SleepDetector.STATE_ALARM && r.alarm.isAlarming();
        r.key(keys[i]);                          // one press on the alarm: must only arm
        if (!armedOnNap || !alarmed || !r.alarm.isAlarming() || r.detector.getState() != SleepDetector.STATE_ALARM
            || r.delegate.testExitRequested() || !r.view.testIsHintShowing()) {
            logger.debug("key " + keys[i] + ": one press on the alarm after a nap press acted: state "
                + r.detector.getState() + " alarming " + r.alarm.isAlarming() + " exit " + r.delegate.testExitRequested());
            ok = false;
        }
        r.key(keys[i]);                          // the pair on the alarm screen
        var stopped = !r.alarm.isAlarming()
            && ((keys[i] == WatchUi.KEY_ESC) ? r.delegate.testExitRequested()
                                             : r.detector.getState() == SleepDetector.STATE_SUMMARY);
        if (!stopped) {
            logger.debug("key " + keys[i] + ": the second press on the alarm must complete the pair");
            ok = false;
        }
        r.cleanup();
    }
    return ok;
}

//! The armed footer and the hint belong to the screen of the first press:
//! once the alarm has started they are gone until a press on the alarm.
(:test)
function testDelegate_armedHintDoesNotSurviveAlarmStart(logger as Test.Logger) as Boolean {
    var r = new DelegateRig(10);
    r.startNap();
    r.detector.testForceSleep();
    r.detector.testAdvanceClock(10 * 60 - 2);
    r.detector.testTick();
    r.key(WatchUi.KEY_ESC);
    var shown = r.view.testIsHintShowing() && delegateHelperIsOneOf(r.footer(), PowerNapView.HINT_EXIT);
    r.detector.testAdvanceClock(1);
    r.detector.testTick();                       // the alarm starts
    var ok = shown && r.detector.getState() == SleepDetector.STATE_ALARM && !r.view.testIsHintShowing()
        && r.footer().find("BACK x2") != null;
    if (!ok) {
        logger.debug("shown " + shown + " hint after alarm " + r.view.testIsHintShowing() + " footer '" + r.footer() + "'");
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
