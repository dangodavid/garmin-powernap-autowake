import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.Timer;

//! Draws the start screen and the nap screens (monitoring, sleeping, alarm,
//! summary), the Stay Awake screens and the "peek" card. The detector
//! requests an update every second while a nap is active, so every value on
//! screen is live; the start screen redraws itself right after every minute
//! change, when the clock and the "Alarm by" preview move.
//!
//! Every screen is described as a prioritised list of lines and laid out by
//! ScreenLayout, which drops optional lines and shrinks fonts until the
//! content fits between the top margin and the footer on any display
//! (176 px Instinct to 454 px AMOLED), and keeps each line inside the round
//! bezel / subscreen.
class PowerNapView extends WatchUi.View {

    private var _detector as SleepDetector;
    private var _alarm as AlarmManager;

    // Debug label: shows "dev #<build>" on start screen in debug builds only.
    private var _debugLabel as String = "";

    // Start screen state
    private var _started as Boolean = false;
    private var _pendingDuration as Number = 30;     // 0 = Stay Awake mode
    private var _syncedDuration as Number = 30;      // stored napDuration last taken over
    // Tap zones measured from the last start-screen layout (-1 = not laid out yet)
    private var _tapPlusMaxY as Number = -1;    // y < this        -> +5 min
    private var _tapMinusMinY as Number = -1;   // y > this        -> -5 min ...
    private var _tapStartMinY as Number = -1;   // y >= this       -> ... start ("TAP to begin")
    // Start-screen refresh: one timer object, re-armed for the next minute
    // change (the clock and the "Alarm by" preview move together there).
    private var _uiTimer as Timer.Timer? = null;
    private var _uiTimerArmed as Boolean = false;
    private const UI_POLL_MS = 100;                  // how late a new minute may show

    // The watch remembers the duration of the last nap it started, so the
    // next session opens on it. In Application.Storage, which writes at
    // once, and not in Application.Properties, which is only written to
    // disk when the app stops (a nap that ends on an empty battery would
    // forget the pick). KEY_PHONE_NAP holds the phone's "Nap Duration"
    // setting as it was then, so that changing the setting still wins.
    private const KEY_LAST_NAP = "lastNapMin";
    private const KEY_PHONE_NAP = "lastPhoneNapMin";

    // Two-press confirmation (4 s, in ms): BACK x2 on the start screen
    // leaves the app, START x2 during a session stops with stats.
    private var _confirm as ConfirmPress;
    private const CONFIRM_WINDOW_MS = 4000;

    // Popup hint after the first press of a pair (BACK on the start screen,
    // START on the alarm), drawn as a banner over the screen (on the alarm
    // also repeated by the footer in red) while that press is armed. It
    // says what the second press does. WatchUi.showToast is not used: its
    // look and timing differ per device and the layout tests could not
    // check it.
    static const HINT_EXIT = ["Press BACK again to exit", "BACK again to exit", "BACK again: exit"] as Array<String>;
    static const HINT_STOP = ["Press START again to stop", "START again to stop", "START again: stop"] as Array<String>;
    // The same popup for the BACK pair on a session screen, one text per
    // thing that press would end. These live in strings.xml (the wording a
    // wearer reads belongs in the resources) and are loaded once, on the
    // first BACK of a session.
    enum {
        BACK_HINT_NAP = 0,       // the nap screens and the peek over them
        BACK_HINT_ALARM = 1,     // a ringing alarm, either kind
        BACK_HINT_SESSION = 2    // the Stay Awake guard and its peek
    }
    private var _backHintNap as Array<String>? = null;
    private var _backHintAlarm as Array<String>? = null;
    private var _backHintSession as Array<String>? = null;
    private var _hintTexts as Array<String>? = null;
    private var _hintContext as Number = ConfirmPress.CONTEXT_NONE;
    private var _hintStartMs as Number = 0;          // when the popup was shown
    private var _lastPressContext as Number = ConfirmPress.CONTEXT_NONE;
    // A first press belongs to the screen it was made on: if the alarm starts
    // (or the screen changes) before the second press, that one arms again.
    // Screens: the detector state while a session is shown, SCREEN_START on
    // the start screen.
    private const SCREEN_START = -1;
    private const SCREEN_NONE = -2;
    private var _armedState as Number = SCREEN_NONE;

    // After a confirmed stop or a screen change, input is ignored for a
    // moment: a groggy user who keeps pressing START must not skip the
    // summary and start a new nap. Presses never extend the lock, so a
    // user who keeps pressing is never trapped.
    private var _locked as Boolean = false;
    private var _lockStartMs as Number = 0;
    private const INPUT_LOCK_MS = 1500;

    // Peek: any button during a nap shows the "so far" card for a moment.
    private var _peeking as Boolean = false;
    private var _peekStartMs as Number = 0;
    private const PEEK_MS = 5000;

    // The start screen's footer hint, read from strings.xml on first use
    // (it depends on the watch having a touchscreen, which never changes).
    private var _startHint as Array<String>? = null;

    // The widest "HH:MM" this watch can draw, measured once per 12/24 h
    // format: what the start screen's clock is shown or hidden on.
    private var _clockWidth as Number = -1;
    private var _clockWidth24 as Boolean = false;

    private var _forceBatteryPct as Number = -1;     // tests: >= 0 replaces the battery level
    private var _msOffset as Number = 0;             // tests: moves the millisecond clock

    // Below this battery level (and not charging) the nap screens warn.
    private const LOW_BATTERY_PCT = 10;

    // Duration options in minutes (step 5, no wrap-around). One step below
    // the shortest nap is Stay Awake mode.
    private const STAY_AWAKE = 0;
    private const DURATION_MIN = 5;
    private const DURATION_MAX = 120;

    function initialize(detector as SleepDetector, alarm as AlarmManager) {
        View.initialize();
        _detector = detector;
        _alarm = alarm;
        _confirm = new ConfirmPress(CONFIRM_WINDOW_MS);
        _syncedDuration = readPhoneDuration();
        _pendingDuration = initialDuration();
        _debugLabel = buildDebugLabel();
    }

    function onShow() as Void {
        // Do NOT auto-start  - wait for user to press START on the start screen
        if (!_started) {
            startUiTimer();
        }
    }

    function onHide() as Void {
        // Nap cleanup is handled by PowerNapApp.onStop() when the app exits.
        // Do NOT stop sensors/timers here: onHide() can be called when a
        // system overlay appears (incoming call, control menu, battery alert).
        // Only the start-screen refresh stops; onShow() restarts it.
        stopUiTimer();
    }

    // -- Public interface for delegate / app ----------------------------

    function isStarted() as Boolean {
        return _started;
    }

    //! Increase or decrease the pending nap duration by one step. It stops
    //! at 120 (no wrap to 5), and one step below 5 min is Stay Awake mode.
    function adjustDuration(delta as Number) as Void {
        var d = _pendingDuration + delta;
        if (_pendingDuration == STAY_AWAKE) {
            d = (delta > 0) ? DURATION_MIN : STAY_AWAKE;
        } else if (d < DURATION_MIN) {
            // An odd value from the phone (e.g. 7) stops at 5 first.
            d = (_pendingDuration > DURATION_MIN) ? DURATION_MIN : STAY_AWAKE;
        } else if (d > DURATION_MAX) {
            d = DURATION_MAX;
        }
        _pendingDuration = d;
        WatchUi.requestUpdate();
    }

    //! Settings changed from the phone: follow a new nap duration while the
    //! start screen is showing (a running nap keeps its own settings). Any
    //! other setting leaves the pick on the watch alone, Stay Awake included.
    function onSettingsChanged() as Void {
        if (!_started) {
            var phone = readPhoneDuration();
            if (phone != _syncedDuration) {
                _pendingDuration = phone;
                _syncedDuration = phone;
            }
            WatchUi.requestUpdate();
        }
    }

    //! Confirm duration, remember it for the next session (never Stay
    //! Awake, a choice made for one session), and begin monitoring.
    function startNap() as Void {
        if (_pendingDuration != STAY_AWAKE) {
            rememberDuration(_pendingDuration);
        }
        stopUiTimer();
        _detector.loadSettings();
        _detector.start(_pendingDuration);
        _started = true;
        _peeking = false;
        _confirm.reset();
        _hintTexts = null;
        WatchUi.requestUpdate();
    }

    //! Back to the start screen (nap stopped before any sleep, or a new nap
    //! from the summary) so the user can change the duration and start again.
    function resetToStart() as Void {
        _detector.stop();
        _alarm.stop();
        // Settings changed from the phone during the nap were ignored by the
        // running detector; read them now so the "Alarm by" preview is right.
        _detector.loadSettings();
        _started = false;
        _peeking = false;
        _confirm.reset();
        _hintTexts = null;
        // The duration this nap ran with (remembered at START), or one
        // changed from the phone during the nap. Stay Awake is never
        // remembered: the next session defaults to a nap.
        _syncedDuration = readPhoneDuration();
        _pendingDuration = initialDuration();
        startUiTimer();
        WatchUi.requestUpdate();
    }

    //! Ignore input for a moment (after a confirmed stop or screen change).
    //! A peek card from before the change does not carry over.
    function lockInput() as Void {
        _locked = true;
        _lockStartMs = nowMs();
        _peeking = false;
    }

    //! Input is being ignored (elapsed time: safe across the timer wrap).
    function isInputLocked() as Boolean {
        if (!_locked) {
            return false;
        }
        var elapsed = nowMs() - _lockStartMs;
        return elapsed >= 0 && elapsed < INPUT_LOCK_MS;
    }

    //! Register a press in the given ConfirmPress context (CONTEXT_EXIT for
    //! BACK, CONTEXT_STOP for START). Returns true when it is the confirming
    //! second press; the hint of a confirmed pair disappears.
    function pressConfirm(context as Number) as Boolean {
        var screen = screenId();
        if (_armedState != screen) {
            // The screen changed since the first press (e.g. the alarm
            // started right after a peek): that press no longer counts.
            _confirm.reset();
        }
        var confirmed = _confirm.press(nowMs(), context);
        _lastPressContext = context;
        _armedState = screen;
        if (confirmed) {
            _hintTexts = null;
        }
        WatchUi.requestUpdate();
        return confirmed;
    }

    //! The screen a first press belongs to: the detector state while a
    //! session is shown, SCREEN_START on the start screen.
    private function screenId() as Number {
        return _started ? _detector.getState() : SCREEN_START;
    }

    //! A first press in `context`, made on the current screen, is waiting
    //! for its second press.
    private function isArmed(context as Number) as Boolean {
        return _armedState == screenId() && _confirm.isArmed(nowMs(), context);
    }

    //! Forget a first press and its hint (the menu or the preview opened).
    function cancelConfirm() as Void {
        _confirm.reset();
        _hintTexts = null;
        _armedState = SCREEN_NONE;
    }

    //! Show a popup hint (see the HINT_* texts) for as long as the press
    //! just registered stays armed: a banner over the current screen. The
    //! start screen has no 1 Hz refresh, so its own timer takes the banner
    //! off when the window is over (and still catches the minute change).
    function showHint(texts as Array<String>) as Void {
        _hintTexts = texts;
        _hintContext = _lastPressContext;
        _hintStartMs = nowMs();
        if (!_started) {
            armUiTimer(uiWakeMs(clockSec()));
        }
        WatchUi.requestUpdate();
    }

    //! The popup hint is showing (its press is still armed on this screen).
    function isHintShowing() as Boolean {
        return _hintTexts != null && isArmed(_hintContext);
    }

    //! Show the "so far" card for a few seconds (the nap keeps running).
    function showPeek() as Void {
        _peeking = true;
        _peekStartMs = nowMs();
        WatchUi.requestUpdate();
    }

    //! The peek card is showing (only while a nap or session is active).
    //! Elapsed time, not an end time: stays correct when the timer wraps.
    function isPeeking() as Boolean {
        if (!_peeking || !_started || !_detector.isActiveState()) {
            return false;
        }
        var elapsed = nowMs() - _peekStartMs;
        return elapsed >= 0 && elapsed < PEEK_MS;
    }

    //! "Test alarm" from the start-screen menu: play the wake-up ramp once
    //! (AlarmManager.startPreview) on the preview screen. Never during a nap.
    function startPreview() as Void {
        if (_started || _alarm.isAlarming()) {
            return;
        }
        cancelConfirm();
        _alarm.startPreview();
        WatchUi.requestUpdate();
    }

    //! End the preview (BACK); the start screen comes back.
    function stopPreview() as Void {
        _alarm.stopPreview();
        WatchUi.requestUpdate();
    }

    //! Start-screen tap: +1 = add 5 min, -1 = remove 5 min, 0 = start.
    //! Above the number adds, the number and its label start, below them
    //! removes, and the "TAP to begin" hint at the bottom starts again (a
    //! tap on the words that say "tap" must not shorten the nap).
    function tapActionAt(y as Number) as Number {
        var plusMax = _tapPlusMaxY;
        var minusMin = _tapMinusMinY;
        if (plusMax < 0 || minusMin < 0) {
            var h = System.getDeviceSettings().screenHeight;
            plusMax = h * 35 / 100;
            minusMin = h * 65 / 100;
        }
        if (y < plusMax) { return 1; }
        if (y <= minusMin) { return 0; }
        if (_tapStartMinY >= 0 && y >= _tapStartMinY) { return 0; }
        return -1;
    }

    // -- Main draw dispatch ---------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (!_started) {
            if (_alarm.isPreviewing()) {
                buildLayout(dc).draw(dc, false);
                return;
            }
            drawStartScreen(dc);
            return;
        }

        var invert = false;
        var state = _detector.getState();
        if (isFlashPhase() && (Time.now().value() % 2 == 0)) {
            // 1 Hz flash once the alarm is at full intensity (the detector
            // refreshes the view every second). The gentle phases stay calm.
            var fill = Palette.isMono() ? Graphics.COLOR_WHITE : Graphics.COLOR_RED;
            dc.setColor(fill, fill);
            dc.fillRectangle(0, 0, dc.getWidth(), dc.getHeight());
            invert = Palette.isMono();
        }
        if (state == SleepDetector.STATE_SUMMARY && _detector.hasSleptAtLeastOnce() && isRoundScreen()) {
            // Only round screens get the ring (it follows the bezel); the
            // completion % is also shown as text on every screen.
            drawRing(dc, RingMath.clampPct(_detector.getPlannedCompletionPct()),
                summaryAccent(RingMath.clampPct(_detector.getPlannedCompletionPct())));
        }

        buildLayout(dc).draw(dc, invert);
        if (showsClock() && hasSubscreen()) {
            drawInLens(dc, clockString(), Palette.TEXT_SECONDARY, invert);
        }
    }

    //! The alarm is ringing at full intensity: the screen may flash.
    private function isFlashPhase() as Boolean {
        return _detector.getState() == SleepDetector.STATE_ALARM && _alarm.isFullIntensity();
    }

    //! Screens that show the time of day: everything live during a nap or
    //! session (the summary is static, a clock there would go stale).
    private function showsClock() as Boolean {
        return _started && _detector.getState() != SleepDetector.STATE_SUMMARY;
    }

    //! Solved layout for the current screen. The start screen also records
    //! its tap zones from where the number and its label were placed.
    private function buildLayout(dc as Graphics.Dc) as ScreenLayout {
        if (!_started) {
            if (_alarm.isPreviewing()) {
                var P = previewLayout(dc);
                P.solve(dc);
                return P;
            }
            return solveStartScreen(dc, [] as Array<LayoutLine>);
        }
        var state = _detector.getState();
        var layout;
        if (isPeeking()) {
            layout = peekLayout(dc);
        } else if (state == SleepDetector.STATE_CALIBRATING || state == SleepDetector.STATE_MONITORING) {
            layout = _detector.isStayAwake() ? stayAwakeLayout(dc) : monitoringLayout(dc);
        } else if (state == SleepDetector.STATE_SLEEPING) {
            layout = sleepingLayout(dc);
        } else if (state == SleepDetector.STATE_ALARM) {
            layout = alarmLayout(dc);
        } else if (_detector.isStayAwake()) {
            layout = stayAwakeSummaryLayout(dc);
        } else {
            layout = _detector.hasSleptAtLeastOnce() ? summaryLayout(dc) : noSleepLayout(dc);
        }
        if (isHintShowing() && state != SleepDetector.STATE_SUMMARY) {
            layout.setBanner(_hintTexts as Array<String>, bannerFonts());
        }
        layout.solve(dc);
        return layout;
    }

    //! Fonts the popup banner may use, largest first.
    private function bannerFonts() as Array<Graphics.FontDefinition> {
        return [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY]
            as Array<Graphics.FontDefinition>;
    }

    // -- Screen 0: Start / Duration Picker -----------------------------

    //! Start screen: the time of day, arrows around the duration ("min of
    //! sleep": counted from falling asleep), the guaranteed alarm time
    //! ("Alarm by", or what Stay Awake does) and the low-battery warning. Adds the
    //! arrow spacers, the number and its label to `lines` for the caller.
    //! Everything above the number adds 5 min, everything below the label
    //! removes 5 min, the number and the label start.
    private function startLayout(dc as Graphics.Dc, lines as Array<LayoutLine>) as ScreenLayout {
        var w = dc.getWidth();
        var L = new ScreenLayout(w, dc.getHeight(), 8);
        var stayAwake = (_pendingDuration == STAY_AWAKE);
        var arrowH = w * 6 / 100;

        // The time of day is not a line of this block: drawStartScreen
        // draws it in the margin above (startClockBox), or in the Instinct
        // lens, so it never competes with the number for height.
        if (!hasSubscreen()) {
            // With a subscreen (Instinct) the lens holds the clock; the
            // title is left out there.
            L.addText(["POWER NAP"], fontsBody(), Graphics.COLOR_BLUE, 50);
        }
        lines.add(L.addSpacer(arrowH + 1, ScreenLayout.KEEP));
        // The big number shrinks one size only when a warning needs the room.
        var number = L.addText([_pendingDuration.toString()],
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD] as Array<Graphics.FontDefinition>,
            Palette.TEXT_PRIMARY, ScreenLayout.KEEP);
        number.gapAfter = 0;
        lines.add(number);
        // "min of sleep": the minutes count from falling asleep, not from now.
        lines.add(L.addText(stayAwake ? ["stay awake"] : ["min of sleep", "min"],
            [Graphics.FONT_SMALL, Graphics.FONT_TINY] as Array<Graphics.FontDefinition>,
            stayAwake ? Graphics.COLOR_ORANGE : Palette.TEXT_SECONDARY, ScreenLayout.KEEP));
        if (stayAwake) {
            L.addText(["Buzzes if you doze", "Buzz if you doze"],
                [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, Palette.TEXT_SECONDARY, 90);
        } else {
            // The same promise the nap screens show, from the same formula
            // (AlarmCap): a nap started in this minute keeps this time.
            // Recomputed on every draw, and the start screen redraws itself
            // at each minute change (startUiTimer).
            addAlarmByLine(L, _detector.previewDeadlineSec(_pendingDuration),
                [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, 90);
        }
        lines.add(L.addSpacer(arrowH + 1, ScreenLayout.KEEP));
        addWarnings(L, 97);
        if (_debugLabel.length() > 0) {
            L.addText([_debugLabel], [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>,
                Graphics.COLOR_LT_GRAY, 10);
        }
        L.setFooterTexts(startHintTexts(), Palette.TEXT_TERTIARY);
        return L;
    }

    //! Solve the start screen and record its tap zones from the number and
    //! label lines (`lines` receives [upArrow, number, label, downArrow]).
    private function solveStartScreen(dc as Graphics.Dc, lines as Array<LayoutLine>) as ScreenLayout {
        var L = startLayout(dc, lines);
        if (isHintShowing()) {
            // "Press BACK again to exit" over the start screen.
            L.setBanner(_hintTexts as Array<String>, bannerFonts());
        }
        L.solve(dc);
        _tapPlusMaxY = lines[1].y;
        _tapMinusMinY = lines[2].y + lines[2].slotH;
        _tapStartMinY = L.getFooterY();
        return L;
    }

    private function drawStartScreen(dc as Graphics.Dc) as Void {
        var lines = [] as Array<LayoutLine>;
        var L = solveStartScreen(dc, lines);

        // The time of day, as on the live screens: in the Instinct lens,
        // elsewhere in the margin above the block (see startClockBox).
        if (subscreenBox() != null) {
            drawInLens(dc, clockString(), Palette.TEXT_SECONDARY, false);
        } else {
            var box = startClockBox(dc, L, lines[0].y);
            if (box != null) {
                var b = box as Array<Number>;
                dc.setColor(Palette.fg(Palette.TEXT_SECONDARY, false), Graphics.COLOR_TRANSPARENT);
                dc.drawText(b[0] + b[2] / 2, b[1], Graphics.FONT_XTINY, clockString(), Graphics.TEXT_JUSTIFY_CENTER);
            }
        }

        // Arrows: filled triangles centred in their spacer slots, drawn
        // before the lines so the exit banner covers them. Same size and
        // same centres as ever (the tap zones are measured off these
        // slots), one step down in brightness so the duration leads.
        // Each one points the way its own zone moves the number: the top
        // arrow is drawn apex-up (a row of 1 px at its top growing to the
        // full width at its bottom), the bottom arrow apex-down.
        var cx = dc.getWidth() / 2;
        dc.setColor(Palette.fg(Palette.ACCENT_DIM, false), Graphics.COLOR_TRANSPARENT);
        var up = lines[0];
        var down = lines[3];
        var arrowH = up.slotH - 1;
        for (var i = 0; i <= arrowH; i++) {
            dc.drawLine(cx - i, up.y + i, cx + i, up.y + i);
            dc.drawLine(cx - i, down.y + (arrowH - i), cx + i, down.y + (arrowH - i));
        }
        L.draw(dc, false);
    }

    // -- Alarm preview ("Test alarm") --------------------------------------

    //! What the wrist feels right now: the step just played (1-based) of
    //! the ramp and its intensity; BACK ends the preview.
    private function previewLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        var step = _alarm.getPreviewStep();
        var steps = _alarm.getPreviewSteps();
        var pct = _alarm.getPreviewPct();
        L.addText(["ALARM PREVIEW", "PREVIEW"], fontsTitle(), Graphics.COLOR_BLUE, 60);
        L.addDivider(14, Graphics.COLOR_DK_GRAY, 10);
        L.addText(["Step " + step + " of " + steps, step + "/" + steps], fontsBody(), Graphics.COLOR_WHITE,
            ScreenLayout.KEEP);
        L.addText([pct + "%"],
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]
                as Array<Graphics.FontDefinition>,
            (pct >= 100) ? Graphics.COLOR_RED : ((pct >= 50) ? Graphics.COLOR_YELLOW : Graphics.COLOR_GREEN),
            ScreenLayout.KEEP);
        L.addText(["Feel the wake-up ramp", "Wake-up ramp"], fontsDetail(), Graphics.COLOR_LT_GRAY, 70);
        L.setFooterTexts(["BACK to stop", "BACK"] as Array<String>, Graphics.COLOR_LT_GRAY);
        return L;
    }

    // -- Screen 1: Calibrating / Monitoring / Awake ---------------------

    private function monitoringLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        var calibrating = (_detector.getState() == SleepDetector.STATE_CALIBRATING);
        var awake = _detector.hasSleptAtLeastOnce();   // after a wake episode

        addClock(L);
        L.addText(["POWER NAP"], fontsTitle(), Graphics.COLOR_BLUE, 60);
        L.addDivider(14, Graphics.COLOR_DK_GRAY, 10);
        L.addText(hrTexts(), fontsBody(), Graphics.COLOR_RED, 70);

        // "Calibrating" (no dots) fits the narrow row next to the Instinct lens.
        var status = calibrating ? ["Calibrating...", "Calibrating"] : [awake ? "Awake" : "Monitoring"];
        L.addText(status as Array<String>, fontsBody(), Graphics.COLOR_WHITE, ScreenLayout.KEEP);

        if (awake) {
            // The alarm time is fixed; the countdown keeps running while awake.
            var left = formatCountdown(_detector.getRemainingSeconds());
            L.addText(["Alarm in " + left, "In " + left],
                fontsDetail(), Graphics.COLOR_YELLOW, 95);
        } else if (calibrating) {
            L.addText(["Building baseline...", "Baseline..."], fontsDetail(), Graphics.COLOR_LT_GRAY, 95);
        } else if (_detector.getStillMinutes() > 0) {
            L.addText(["Stillness " + _detector.getOnsetProgressPct() + "%"],
                fontsDetail(), Graphics.COLOR_YELLOW, 95);
        } else {
            L.addText(["Waiting for sleep...", "Waiting..."], fontsDetail(), Graphics.COLOR_LT_GRAY, 95);
        }

        // Before sleep: the guaranteed latest alarm time (the cap fixed at
        // start, the very minute the start screen promised), in the two
        // colours the start screen gave it. After a wake episode: the fixed
        // alarm time. Ranked above the stillness line: on the smallest
        // screens the alarm promise must survive.
        addAlarmLine(L, fontsDetail(), 96);
        if (!awake) {
            // Below the promise: on the smallest screens "Alarm by" wins;
            // the start screen already showed the warnings with room to spare.
            addWarnings(L, 94);
        }
        addInactiveWarning(L);
        if (!awake) {
            // How the alarm is set: the nap counts from falling asleep. After
            // a wake episode the alarm time is fixed, so the rule no longer
            // applies (falling asleep again does not add another N minutes).
            var n = _detector.getNapDurationMin();
            L.addText(["Alarm " + n + " min after sleep", n + " min after sleep", "Nap " + n + " min"],
                fontsDetail(), Graphics.COLOR_LT_GRAY, 75);
        }
        setNapFooter(L, false, Graphics.COLOR_LT_GRAY);
        return L;
    }

    // -- Screen 2: Sleep Detected / Countdown --------------------------

    private function sleepingLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        var smartWake = _detector.isSmartWakeActive();

        addClock(L);
        L.addText(["NAP DETECTED", "ASLEEP"], fontsTitle(), Graphics.COLOR_PURPLE, 60);
        L.addDivider(14, Graphics.COLOR_DK_GRAY, 10);
        var sleepStart = _detector.getSleepStartTime();
        if (sleepStart != null) {
            // First onset of this nap (not reset by a wake episode).
            var t = formatMoment(sleepStart as Time.Moment);
            L.addText(["Asleep since " + t, "Since " + t], fontsBody(), Graphics.COLOR_LT_GRAY, 70);
        }
        // Above the countdown: the time the alarm now rings at (it moved with
        // sleep onset). Inside the smart-wake window it may ring earlier.
        var at = alarmAtString();
        var label = L.addText(smartWake ? ["Smart Wake", "Smart"] : ["Wake at " + at, "At " + at, "Wake in"],
            fontsBody(), Graphics.COLOR_WHITE, 90);
        label.gapAfter = 2;
        L.addText([formatCountdown(_detector.getRemainingSeconds())],
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]
                as Array<Graphics.FontDefinition>,
            smartWake ? Graphics.COLOR_YELLOW : Graphics.COLOR_GREEN, ScreenLayout.KEEP);
        addInactiveWarning(L);
        L.addText(hrTexts(), fontsDetail(), Graphics.COLOR_RED, 40);
        setNapFooter(L, false, Graphics.COLOR_LT_GRAY);
        return L;
    }

    // -- Screen 3: Alarm / Wake Up -------------------------------------

    //! Gentle phases: calm colours and words on a dark screen (the backlight
    //! only comes on from the ramp's 50 % step). From full strength, and
    //! always for the Stay Awake doze alarm, the loud screen: white text,
    //! flashing.
    private function alarmLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        var reason = _detector.getAlarmReason();
        var deadline = (reason == SleepDetector.ALARM_DEADLINE);
        var loud = (reason == SleepDetector.ALARM_DOZE) || _alarm.isFullIntensity();
        var text = loud ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY;

        addClock(L);
        var title;
        if (deadline) {
            title = loud ? ["TIME'S UP"] : ["Time's up"];
        } else {
            title = loud ? ["WAKE UP!"] : ["Time to wake up", "Wake up"];
        }
        L.addText(title as Array<String>,
            [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL] as Array<Graphics.FontDefinition>,
            loud ? Graphics.COLOR_WHITE : Graphics.COLOR_ORANGE, ScreenLayout.KEEP);
        L.addDivider(14, loud ? Graphics.COLOR_WHITE : Graphics.COLOR_DK_GRAY, 10);
        if (reason == SleepDetector.ALARM_DOZE) {
            L.addText(["You dozed off", "Dozed off"], fontsBody(), text, 85);
            L.addText(["Doze #" + _detector.getDozeCount()], fontsBody(), text, 60);
        } else {
            if (deadline) {
                L.addText(["No sleep detected", "No sleep"], fontsBody(), text, 85);
            } else if (reason == SleepDetector.ALARM_SMART_WAKE) {
                L.addText(["Smart wake"], fontsBody(), text, 85);
            }

            if (deadline) {
                L.addText(["Waited " + (sessionSeconds() / 60) + " min"], fontsBody(), text, 80);
            } else {
                L.addText(["Slept " + formatCountdown(_detector.getActualNapDurationSec())],
                    fontsBody(), text, 80);
            }
            var avgHR = _detector.getAvgSleepHR();
            if (avgHR > 0) {
                L.addText(["Avg HR " + avgHR + " BPM", "Avg " + avgHR], fontsBody(), text, 30);
            }
        }
        // The phase of the ring the user just felt (the style above follows it too).
        L.addText(["ALARM " + (_alarm.getLastRingPhase() + 1) + "/4"], fontsBody(),
            loud ? Graphics.COLOR_YELLOW : Graphics.COLOR_LT_GRAY, 40);
        setNapFooter(L, true, text);
        return L;
    }

    // -- Screen 4: Summary ---------------------------------------------

    private function summaryLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 18);
        if (isRoundScreen()) {
            // Text stays inside the progress ring: ring at r = w/2 - 6, pen 5.
            L.setClipRadius(dc.getWidth() / 2 - 6 - 3 - 2);
            L.setEdgeMargin(2);
        }

        var sleptSec   = _detector.getActualNapDurationSec();
        var completion = RingMath.clampPct(_detector.getPlannedCompletionPct());
        var efficiency = RingMath.clampPct(_detector.getSleepEfficiencyPct());
        var wakes      = _detector.getWakeEpisodes();
        var cancelled  = _detector.isCancelled();
        var accent     = summaryAccent(completion);

        // Without the ring (the Instinct) the title carries the completion %.
        var pct = isRoundScreen() ? "" : (" " + completion + "%");
        var titles = cancelled ? ["NAP STOPPED" + pct, "STOPPED" + pct, "STOP" + pct]
                               : ["NAP COMPLETE" + pct, "COMPLETE" + pct, "DONE" + pct];
        if (pct.length() > 0) {
            titles.add(pct.substring(1, pct.length()) as String);   // next to the lens: just "100%"
        }
        L.addText(titles as Array<String>, fontsBody(), accent, ScreenLayout.KEEP);
        L.addText([(sleptSec > 0) ? formatCountdown(sleptSec) : "--:--"],
            [Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL] as Array<Graphics.FontDefinition>,
            Graphics.COLOR_WHITE, ScreenLayout.KEEP);

        // What actually happened, never a threshold on a ratio.
        var quality;
        if (cancelled) {
            quality = ["Stopped early"];
        } else if (wakes > 0) {
            var w = wakes + ((wakes == 1) ? " wake" : " wakes");
            quality = [w + ", " + efficiency + "% asleep", w];
        } else if (_detector.getAlarmReason() == SleepDetector.ALARM_SMART_WAKE) {
            quality = ["Smart wake"];
        } else {
            quality = ["Uninterrupted"];
        }
        L.addText([completion + "% of " + _detector.getNapDurationMin() + " min", completion + "%"],
            [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, accent, 85);
        L.addText(quality as Array<String>, [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, accent, 90);
        var fallSec = _detector.getFallAsleepSec();
        if (fallSec >= 0) {
            // How long it took to fall asleep: the alarm moved by this much.
            var m = (fallSec + 30) / 60;
            L.addText(["Fell asleep in " + m + " min", "Asleep in " + m + " min", m + " min to sleep"],
                [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, Graphics.COLOR_LT_GRAY, 86);
        }
        L.addDivider(20, Graphics.COLOR_DK_GRAY, 20);

        var avgHR = _detector.getAvgSleepHR();
        var minHR = _detector.getMinSleepHR();
        if (avgHR > 0) {
            L.addText(["Avg " + avgHR + "  Min " + minHR + " BPM", "HR " + avgHR + "/" + minHR],
                [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, Graphics.COLOR_RED, 50);
        }
        var sleepStart = _detector.getSleepStartTime();
        var napEnd = _detector.getNapEndTime();
        if (sleepStart != null && napEnd != null) {
            L.addText([formatMoment(sleepStart as Time.Moment) + " - " + formatMoment(napEnd as Time.Moment)],
                [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, Graphics.COLOR_LT_GRAY, 40);
        }
        L.setFooterChoices(summaryFooter(), Graphics.COLOR_LT_GRAY);
        return L;
    }

    //! Summary when the nap ended without any detected sleep.
    private function noSleepLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 18);
        L.addText(["No sleep detected", "No sleep"], fontsBody(), Graphics.COLOR_YELLOW, ScreenLayout.KEEP);
        L.addText(_detector.isCancelled() ? ["Stopped early", "Stopped"] : ["Timer alarm rang", "Timer alarm"],
            fontsDetail(), Graphics.COLOR_WHITE, 90);
        L.addText(["Waited " + (sessionSeconds() / 60) + " min"], fontsDetail(), Graphics.COLOR_LT_GRAY, 80);
        var napEnd = _detector.getNapEndTime();
        var endStr = (napEnd != null) ? formatMoment(napEnd as Time.Moment) : "--:--";
        L.addText([formatMoment(_detector.getStartTime()) + " - " + endStr],
            fontsDetail(), Graphics.COLOR_LT_GRAY, 50);
        L.setFooterChoices(summaryFooter(), Graphics.COLOR_LT_GRAY);
        return L;
    }

    // -- Stay Awake screens ------------------------------------------------

    //! Guarding: a short message that the watch keeps the user awake, the
    //! drowsiness warning once the wrist has been still for a while, and
    //! how long the session has run.
    private function stayAwakeLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        var calibrating = (_detector.getState() == SleepDetector.STATE_CALIBRATING);

        addClock(L);
        L.addText(["STAY AWAKE"], fontsTitle(), Graphics.COLOR_ORANGE, 60);
        L.addDivider(14, Graphics.COLOR_DK_GRAY, 10);
        if (_detector.isDozeWarning()) {
            L.addText(["Stay alert!"], fontsBody(), Graphics.COLOR_YELLOW, ScreenLayout.KEEP);
            L.addText(["Move a bit", "Move"], fontsDetail(), Graphics.COLOR_YELLOW, 96);
        } else {
            L.addText(["Keeping you awake", "Keeping awake", "On guard"], fontsBody(),
                Graphics.COLOR_WHITE, ScreenLayout.KEEP);
            if (calibrating) {
                L.addText(["Building baseline...", "Baseline..."], fontsDetail(), Graphics.COLOR_LT_GRAY, 95);
            } else if (_detector.getStillMinutes() > 0) {
                L.addText(["Stillness " + _detector.getOnsetProgressPct() + "%"],
                    fontsDetail(), Graphics.COLOR_YELLOW, 95);
            } else {
                L.addText(["Buzzes if you doze", "Buzz if you doze", "Buzz if doze"], fontsDetail(),
                    Graphics.COLOR_LT_GRAY, 95);
            }
        }
        L.addText(["Awake " + formatLong(_detector.getSessionSec())], fontsDetail(), Graphics.COLOR_LT_GRAY, 80);
        var dozes = _detector.getDozeCount();
        if (dozes > 0) {
            L.addText(dozesText(dozes), fontsDetail(), Graphics.COLOR_ORANGE, 85);
        }
        addWarnings(L, 97);
        addInactiveWarning(L);
        L.addText(hrTexts(), fontsDetail(), Graphics.COLOR_RED, 40);
        setNapFooter(L, false, Graphics.COLOR_LT_GRAY);
        return L;
    }

    //! Stay Awake summary: session length and dozes caught.
    private function stayAwakeSummaryLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 18);
        var dozes = _detector.getDozeCount();
        var accent = (dozes == 0) ? Graphics.COLOR_GREEN : Graphics.COLOR_ORANGE;
        L.addText(["STAY AWAKE", "AWAKE"], fontsBody(), accent, ScreenLayout.KEEP);
        L.addText([formatLong(sessionSeconds())],
            [Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL] as Array<Graphics.FontDefinition>,
            Graphics.COLOR_WHITE, ScreenLayout.KEEP);
        L.addText((dozes == 0) ? ["No dozes"] : dozesText(dozes), fontsDetail(), accent, 90);
        L.addDivider(20, Graphics.COLOR_DK_GRAY, 20);
        var napEnd = _detector.getNapEndTime();
        var endStr = (napEnd != null) ? formatMoment(napEnd as Time.Moment) : "--:--";
        L.addText([formatMoment(_detector.getStartTime()) + " - " + endStr],
            [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, Graphics.COLOR_LT_GRAY, 40);
        L.setFooterChoices(summaryFooter(), Graphics.COLOR_LT_GRAY);
        return L;
    }

    // -- Peek -----------------------------------------------------------

    //! "So far" card shown for a few seconds after UP/DOWN/START during a
    //! nap: time asleep, wakes and the alarm time. Nothing stops.
    private function peekLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        addClock(L);
        if (_detector.isStayAwake()) {
            L.addText(["STAY AWAKE"], fontsTitle(), Graphics.COLOR_ORANGE, 60);
            L.addDivider(14, Graphics.COLOR_DK_GRAY, 10);
            var awakeFor = formatLong(_detector.getSessionSec());
            L.addText(["Awake " + awakeFor, awakeFor], fontsBody(),
                Graphics.COLOR_WHITE, ScreenLayout.KEEP);
            var dozes = _detector.getDozeCount();
            L.addText((dozes == 0) ? ["No dozes"] : dozesText(dozes), fontsDetail(),
                Graphics.COLOR_LT_GRAY, 90);
            var since = formatMoment(_detector.getStartTime());
            L.addText(["Since " + since], fontsDetail(), Graphics.COLOR_LT_GRAY, 70);
        } else {
            L.addText(["NAP SO FAR", "SO FAR"], fontsTitle(), Graphics.COLOR_BLUE, 60);
            L.addDivider(14, Graphics.COLOR_DK_GRAY, 10);
            if (_detector.hasSleptAtLeastOnce()) {
                L.addText(["Slept " + formatCountdown(_detector.getActualNapDurationSec())], fontsBody(),
                    Graphics.COLOR_WHITE, ScreenLayout.KEEP);
                var wakes = _detector.getWakeEpisodes();
                L.addText([(wakes == 0) ? "No wakes" : (wakes + ((wakes == 1) ? " wake" : " wakes"))],
                    fontsDetail(), Graphics.COLOR_LT_GRAY, 80);
            } else {
                L.addText(["No sleep yet"], fontsBody(), Graphics.COLOR_WHITE, ScreenLayout.KEEP);
            }
            addAlarmLine(L, fontsDetail(), 95);
        }
        setNapFooter(L, false, Graphics.COLOR_LT_GRAY);
        return L;
    }

    // -- Drawing helpers -----------------------------------------------

    //! Progress ring: full track underneath, accent arc on top.
    //! 100 % is drawn as a circle because drawArc with start == end (mod
    //! 360) is undefined and renders nothing on real devices. On the 1-bit
    //! Instinct the track is a thin line so the thick arc stays readable.
    private function drawRing(dc as Graphics.Dc, pct as Number, color as Graphics.ColorType) as Void {
        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;
        var r = (dc.getWidth() / 2) - 6;
        var mono = Palette.isMono();
        dc.setPenWidth(mono ? 1 : 5);
        dc.setColor(Palette.fg(Graphics.COLOR_DK_GRAY, false), Graphics.COLOR_TRANSPARENT);
        dc.drawCircle(cx, cy, r);
        dc.setPenWidth(5);
        dc.setColor(Palette.fg(color, false), Graphics.COLOR_TRANSPARENT);
        if (RingMath.isFullRing(pct)) {
            dc.drawCircle(cx, cy, r);
        } else if (pct > 0) {
            dc.drawArc(cx, cy, r, Graphics.ARC_CLOCKWISE, 90, RingMath.endAngle(pct));
        }
        dc.setPenWidth(1);
    }

    //! Colour follows how much of the planned nap was completed.
    private function summaryAccent(completion as Number) as Graphics.ColorType {
        if (completion < 50) { return Graphics.COLOR_RED; }
        if (completion < 65) { return Graphics.COLOR_ORANGE; }
        if (completion < 80) { return Graphics.COLOR_YELLOW; }
        if (completion < 95) { return Graphics.COLOR_GREEN; }
        return 0x00FF55;
    }

    //! Shown for the rest of the nap once the app has left the foreground:
    //! while inactive the watch blocks vibration, so the alarm cannot wake
    //! the user unless the app stays open.
    private function addInactiveWarning(L as ScreenLayout) as Void {
        if (_detector.wasInactiveDuringNap()) {
            L.addText(["Keep app open for alarm", "Keep app open"],
                [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, Graphics.COLOR_ORANGE, 97);
        }
    }

    //! Warning the user can still act on (start and before sleep): a nearly
    //! empty battery may not last until the alarm. (Do Not Disturb needs no
    //! warning: verified on a fenix 8 Pro, the alarm vibrates with DND on.)
    private function addWarnings(L as ScreenLayout, priority as Number) as Void {
        var pct = lowBatteryPct();
        if (pct >= 0) {
            L.addText(["Low battery " + pct + "%", "Battery " + pct + "%"] as Array<String>,
                [Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>, Graphics.COLOR_RED, priority);
        }
    }

    //! Footer of the nap, Stay Awake, peek and alarm screens (longest first,
    //! shorter variants for narrow screens and wide fonts). Unarmed it says
    //! what one BACK does (back to the start screen, or the alarm off) and
    //! teaches the START pair (stop with stats); once a first START is armed
    //! it repeats that hint in red: what the second START does.
    private function setNapFooter(L as ScreenLayout, alarm as Boolean, color as Graphics.ColorType) as Void {
        if (isArmed(ConfirmPress.CONTEXT_STOP)) {
            L.setFooterTexts(alarm ? HINT_STOP
                : (["START again: stop + stats", "START again: stop", "Again: stop"] as Array<String>),
                Graphics.COLOR_RED);
        } else if (alarm) {
            // Either pair stops the ringing: BACK x2 (a nap goes back to the
            // start screen, the doze alarm back on guard) or START x2, which
            // also shows a nap's stats. Kept short: a longer hint climbs over
            // "ALARM x/4" on the 260 px round screens.
            L.setFooterTexts(["BACK x2 or START x2: stop", "BACK x2: stop"] as Array<String>, color);
        } else {
            // On the smallest screens only "BACK x2: end" fits; there the
            // first START press teaches its pair (the peek card's footer).
            L.setFooterTexts(["BACK x2: end, START x2: stats", "BACK x2 end, START x2 stats", "BACK x2: end"]
                as Array<String>, color);
        }
    }

    //! START sets up a new nap; BACK goes back to the start screen too, as
    //! BACK does everywhere, so the footer only needs the START hint.
    private function summaryFooter() as Array<String> {
        return ["START: new nap", "START: new"] as Array<String>;
    }

    //! The alarm promise. Before sleep: the latest possible alarm (the cap
    //! fixed at start). Once asleep: the minute the alarm now rings in.
    private function alarmLineTexts() as Array<String> {
        if (_detector.getPlannedEndTime() != null) {
            var at = alarmAtString();
            return ["Alarm at " + at, "At " + at] as Array<String>;
        }
        return alarmByTexts(_detector.getDeadlineTime().value());
    }

    //! The alarm cap as the start screen and the nap screens both word it.
    //! The cap falls on a whole minute (AlarmCap), so the alarm rings at
    //! the latest exactly at the time shown, never after it.
    private function alarmByTexts(capSec as Number) as Array<String> {
        var by = formatMoment(new Time.Moment(capSec));
        return ["Alarm by " + by, "By " + by] as Array<String>;
    }

    //! The "Alarm by HH:MM" promise, added with the two colours it carries
    //! everywhere it is shown: the words in secondary grey, the time itself
    //! in primary white, so the time reads at a glance and the promise looks
    //! the same on the start screen as during the nap.
    private function addAlarmByLine(L as ScreenLayout, capSec as Number,
                                    fonts as Array<Graphics.FontDefinition>,
                                    priority as Number) as LayoutLine {
        var line = L.addText(alarmByTexts(capSec), fonts, Palette.TEXT_SECONDARY, priority);
        line.tailColor = Palette.TEXT_PRIMARY;
        return line;
    }

    //! The alarm line every session screen shows, in the colours the start
    //! screen gave the promise: before sleep the guaranteed cap ("Alarm by"
    //! in secondary grey, the time itself in primary white), once asleep the
    //! minute the alarm now rings in. The monitoring screen and the peek card
    //! both take it from here, so the card cannot drift into a colour of its
    //! own again.
    private function addAlarmLine(L as ScreenLayout, fonts as Array<Graphics.FontDefinition>,
                                  priority as Number) as Void {
        if (_detector.getPlannedEndTime() != null) {
            L.addText(alarmLineTexts(), fonts, Palette.TEXT_SECONDARY, priority);
        } else {
            addAlarmByLine(L, _detector.getDeadlineTime().value(), fonts, priority);
        }
    }

    //! What a second BACK does on this screen, longest variant first (the
    //! banner falls back to a shorter one on a narrow screen). Loaded from
    //! strings.xml on first use and kept, like the start hint.
    function backHintTexts(kind as Number) as Array<String> {
        if (kind == BACK_HINT_ALARM) {
            if (_backHintAlarm == null) {
                _backHintAlarm = [loadText(Rez.Strings.BackAgainAlarm),
                    loadText(Rez.Strings.BackAgainAlarmShort),
                    loadText(Rez.Strings.BackAgainAlarmTiny),
                    loadText(Rez.Strings.BackAgainAlarmTiniest)] as Array<String>;
            }
            return _backHintAlarm as Array<String>;
        }
        if (kind == BACK_HINT_SESSION) {
            if (_backHintSession == null) {
                _backHintSession = [loadText(Rez.Strings.BackAgainSession),
                    loadText(Rez.Strings.BackAgainSessionShort),
                    loadText(Rez.Strings.BackAgainSessionTiny),
                    loadText(Rez.Strings.BackAgainSessionTiniest)] as Array<String>;
            }
            return _backHintSession as Array<String>;
        }
        if (_backHintNap == null) {
            _backHintNap = [loadText(Rez.Strings.BackAgainNap),
                loadText(Rez.Strings.BackAgainNapShort),
                loadText(Rez.Strings.BackAgainNapTiny),
                    loadText(Rez.Strings.BackAgainNapTiniest)] as Array<String>;
        }
        return _backHintNap as Array<String>;
    }

    //! The start screen's footer: what starts a nap on this watch. Loaded
    //! once from strings.xml (the wording lives in the resources, not here)
    //! and listed longest first, so the layout can fall back to the short
    //! variant on a narrow screen.
    private function startHintTexts() as Array<String> {
        if (_startHint == null) {
            _startHint = hasTouch()
                ? [loadText(Rez.Strings.StartHintTouch), loadText(Rez.Strings.StartHintTouchShort)]
                    as Array<String>
                : [loadText(Rez.Strings.StartHintButton), loadText(Rez.Strings.StartHintButtonShort)]
                    as Array<String>;
        }
        return _startHint as Array<String>;
    }

    private function loadText(id as Lang.ResourceId) as String {
        return WatchUi.loadResource(id) as String;
    }

    //! The minute the planned alarm rings in ("--:--" before onset).
    private function alarmAtString() as String {
        var planned = _detector.getPlannedEndTime();
        return (planned != null) ? formatMoment(planned as Time.Moment) : "--:--";
    }

    //! The time of day as the top line of a live screen. On the Instinct it
    //! goes into the round lens instead (see onUpdate).
    private function addClock(L as ScreenLayout) as Void {
        if (!hasSubscreen()) {
            L.addText([clockString()], [Graphics.FONT_TINY, Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>,
                Palette.TEXT_SECONDARY, 92);
        }
    }

    //! Where the start screen's clock goes (owner request: "Alarm by HH:MM"
    //! reads against it): [x, y, w, h] at FONT_XTINY, centred in the room
    //! above the first line of the block (`firstY`), or null when that room
    //! is too small or the WIDEST time of day this watch can show does not
    //! fit the visible width at those rows (the narrow top of a round
    //! screen). Sized and decided on that widest time, never on the current
    //! one, so the clock cannot appear at 9:59 and vanish at 10:00; the
    //! time is drawn centred in the box, so it sits where it always did. Not a line
    //! of the block on purpose: on the 454 px fenix 8 the band's slack is
    //! 26 px and a clock line would need 47, so the engine dropped it (or
    //! would have shrunk the number). The round-screen analogue of the
    //! Instinct lens, which shows the clock on every screen.
    private function startClockBox(dc as Graphics.Dc, L as ScreenLayout, firstY as Number) as Array<Number>? {
        if (hasSubscreen()) {
            return null;
        }
        var font = Graphics.FONT_XTINY;
        var fh = dc.getFontHeight(font);
        var room = firstY - 2;                       // 2 px clear of the first line
        if (room < fh) {
            return null;
        }
        var y = (room - fh) / 2;
        // The widest time of day, not the current one: the clock must not
        // come and go with the hour. The box is centred on the same point
        // either way, so the time itself is drawn exactly where it was.
        var tw = widestClockWidth(dc, font);
        var b = L.visibleInkBounds(y, fh);
        if (tw > b[1] - b[0]) {
            return null;
        }
        return [(b[0] + b[1]) / 2 - tw / 2, y, tw, fh] as Array<Number>;
    }

    private function clockString() as String {
        return formatMoment(new Time.Moment(_detector.getNowSec()));
    }

    //! A short text centred in the Instinct's subscreen lens.
    private function drawInLens(dc as Graphics.Dc, text as String, color as Graphics.ColorType,
                                invert as Boolean) as Void {
        var sub = subscreenBox();
        if (sub == null) {
            return;
        }
        var box = sub as Array<Number>;
        var fh = dc.getFontHeight(Graphics.FONT_XTINY);
        dc.setColor(Palette.fg(color, invert), Graphics.COLOR_TRANSPARENT);
        dc.drawText(box[0] + box[2] / 2, box[1] + (box[3] - fh) / 2, Graphics.FONT_XTINY, text,
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    //! Battery percentage when it is below LOW_BATTERY_PCT and the watch is
    //! not charging, else -1.
    private function lowBatteryPct() as Number {
        if (_forceBatteryPct >= 0) {
            return (_forceBatteryPct < LOW_BATTERY_PCT) ? _forceBatteryPct : -1;
        }
        try {
            var stats = System.getSystemStats();
            if ((stats has :charging) && stats.charging) {
                return -1;
            }
            var pct = stats.battery.toNumber();
            return (pct < LOW_BATTERY_PCT) ? pct : -1;
        } catch (e instanceof Lang.Exception) {
            return -1;
        }
    }

    private function dozesText(dozes as Number) as Array<String> {
        if (dozes == 1) {
            return ["1 doze caught", "1 doze"] as Array<String>;
        }
        return [dozes + " dozes caught", dozes + " dozes"] as Array<String>;
    }

    //! A touchscreen that is switched on (FR255 and Instinct 3 have none).
    private function hasTouch() as Boolean {
        try {
            return System.getDeviceSettings().isTouchScreen;
        } catch (e instanceof Lang.Exception) {
            return false;
        }
    }

    private function isRoundScreen() as Boolean {
        try {
            return System.getDeviceSettings().screenShape == System.SCREEN_SHAPE_ROUND;
        } catch (e instanceof Lang.Exception) {
            return true;
        }
    }

    private function hasSubscreen() as Boolean {
        return subscreenBox() != null;
    }

    //! [x, y, width, height] of the subscreen (Instinct lens), or null.
    private function subscreenBox() as Array<Number>? {
        if (!(WatchUi has :getSubscreen)) {
            return null;
        }
        try {
            var sub = WatchUi.getSubscreen();
            if (sub != null && sub.x != null && sub.y != null && sub.width != null && sub.height != null
                && (sub.width as Number) > 0) {
                return [sub.x as Number, sub.y as Number, sub.width as Number, sub.height as Number] as Array<Number>;
            }
        } catch (e instanceof Lang.Exception) {
        }
        return null;
    }

    private function fontsTitle() as Array<Graphics.FontDefinition> {
        return [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY] as Array<Graphics.FontDefinition>;
    }

    private function fontsBody() as Array<Graphics.FontDefinition> {
        return [Graphics.FONT_SMALL, Graphics.FONT_TINY, Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>;
    }

    private function fontsDetail() as Array<Graphics.FontDefinition> {
        return [Graphics.FONT_TINY, Graphics.FONT_XTINY] as Array<Graphics.FontDefinition>;
    }

    //! Seconds from start to the end of the nap (frozen once it ended).
    private function sessionSeconds() as Number {
        var napEnd = _detector.getNapEndTime();
        var end = (napEnd != null) ? (napEnd as Time.Moment).value() : Time.now().value();
        var d = end - _detector.getStartTime().value();
        return (d < 0) ? 0 : d;
    }

    //! The duration the start screen opens on: the nap this watch started
    //! last (clamped to the valid range), the setting from the phone when
    //! that changed since, and the setting itself on the first run. Stay
    //! Awake is never remembered, so this is always a nap duration.
    private function initialDuration() as Number {
        var phone = readPhoneDuration();
        var saved = storedNumber(KEY_LAST_NAP);
        if (saved == null) {
            return phone;                            // first run
        }
        var phoneThen = storedNumber(KEY_PHONE_NAP);
        if (phoneThen != null && (phoneThen as Number) != phone) {
            return phone;                            // changed on the phone since
        }
        return clampDuration(saved as Number);
    }

    //! Remember the duration a nap just started with, together with the
    //! phone setting it was picked against (see KEY_LAST_NAP).
    private function rememberDuration(minutes as Number) as Void {
        try {
            Application.Storage.setValue(KEY_LAST_NAP, minutes);
            Application.Storage.setValue(KEY_PHONE_NAP, _syncedDuration);
        } catch (e instanceof Lang.Exception) {
            // Storage full or unavailable -- the nap runs with the pick anyway.
        }
    }

    //! A Number kept in the app's own storage, or null when it is absent,
    //! of another type, or unreadable.
    private function storedNumber(key as String) as Number? {
        try {
            var v = Application.Storage.getValue(key);
            if (v != null && v instanceof Number) {
                return v as Number;
            }
        } catch (e instanceof Lang.Exception) {
            // Storage corrupt -- fall back to the phone setting.
        }
        return null;
    }

    //! The nap duration configured from the phone (Application.Properties),
    //! clamped; the value last taken over if it cannot be read.
    private function readPhoneDuration() as Number {
        var d = _syncedDuration;
        try {
            var saved = Application.Properties.getValue("napDuration");
            if (saved != null && saved instanceof Number) {
                d = saved as Number;
            }
        } catch (e instanceof Lang.Exception) {
            // Storage corrupt -- keep the current value.
        }
        return clampDuration(d);
    }

    private function clampDuration(minutes as Number) as Number {
        if (minutes < DURATION_MIN) { return DURATION_MIN; }
        if (minutes > DURATION_MAX) { return DURATION_MAX; }
        return minutes;
    }

    //! Keep the start screen live: the time of day and the "Alarm by"
    //! preview both move when the clock reaches a new minute (AlarmCap
    //! counts from the minute the nap starts in), so the screen is redrawn
    //! right after every minute change while it is open, with no press
    //! needed. The wall clock has whole seconds only, so the timer wakes
    //! UI_POLL_MS into the minute's last second and then looks again every
    //! UI_POLL_MS: the new minute is on screen at most that late. The same
    //! timer takes the exit popup off when its window is over.
    private function startUiTimer() as Void {
        if (!_uiTimerArmed) {
            armUiTimer(uiWakeMs(clockSec()));
        }
    }

    //! Start-screen refresh: redraw if the minute has changed or the popup
    //! hint has expired, then wait for whichever comes first.
    function onUiTimer() as Void {
        _uiTimerArmed = false;
        if (_started) {
            return;
        }
        var sec = clockSec();
        var redraw = (sec != 59);                    // woken after a minute change
        if (_hintTexts != null && !isHintShowing()) {
            _hintTexts = null;                       // the popup's window is over
            redraw = true;
        }
        if (redraw) {
            WatchUi.requestUpdate();
        }
        armUiTimer(uiWakeMs(sec));
    }

    //! Milliseconds until the next look of the start-screen refresh (see
    //! startUiTimer): into the last second of the minute, or every
    //! UI_POLL_MS while already in it, and never past the popup's end.
    private function uiWakeMs(sec as Number) as Number {
        var ms = (sec >= 59) ? UI_POLL_MS : ((59 - sec) * 1000 + UI_POLL_MS);
        if (_hintTexts != null) {
            var left = CONFIRM_WINDOW_MS + UI_POLL_MS - (nowMs() - _hintStartMs);
            if (left < ms) {
                ms = (left < UI_POLL_MS) ? UI_POLL_MS : left;
            }
        }
        return ms;
    }

    //! The second within the current minute (0-59) of the wall clock.
    private function clockSec() as Number {
        return _detector.getNowSec() % 60;
    }

    private function armUiTimer(ms as Number) as Void {
        stopUiTimer();
        try {
            if (_uiTimer == null) {
                _uiTimer = new Timer.Timer();
            }
            (_uiTimer as Timer.Timer).start(method(:onUiTimer), ms, false);
            _uiTimerArmed = true;
        } catch (e instanceof Lang.Exception) {
            // Timer limit: the start screen refreshes on the next key press.
            _uiTimerArmed = false;
        }
    }

    private function stopUiTimer() as Void {
        if (_uiTimer != null && _uiTimerArmed) {
            (_uiTimer as Timer.Timer).stop();
        }
        _uiTimerArmed = false;
    }

    //! Millisecond clock for the two-press window (not rounded to seconds).
    private function nowMs() as Number {
        return System.getTimer() + _msOffset;
    }

    //! "HR 62 BPM" / "HR 62", or "HR --" while no reading arrives.
    private function hrTexts() as Array<String> {
        var hr = _detector.getCurrentHR();
        if (hr <= 0) {
            return ["HR --"] as Array<String>;
        }
        return ["HR " + hr + " BPM", "HR " + hr] as Array<String>;
    }

    private function formatCountdown(totalSeconds as Number) as String {
        if (totalSeconds < 0) { totalSeconds = 0; }
        return (totalSeconds / 60).toString() + ":" + formatTwoDigits(totalSeconds % 60);
    }

    //! m:ss below an hour, h:mm:ss from an hour on (Stay Awake sessions).
    private function formatLong(totalSeconds as Number) as String {
        if (totalSeconds < 3600) {
            return formatCountdown(totalSeconds);
        }
        var h = totalSeconds / 3600;
        var rest = totalSeconds % 3600;
        return h.toString() + ":" + formatTwoDigits(rest / 60) + ":" + formatTwoDigits(rest % 60);
    }

    private function formatTwoDigits(n as Number) as String {
        return (n < 10) ? "0" + n.toString() : n.toString();
    }

    //! HH:MM, or h:mm when the watch is set to the 12-hour clock.
    private function formatMoment(moment as Time.Moment) as String {
        var info = Gregorian.info(moment, Time.FORMAT_SHORT);
        return formatHourMin(info.hour as Number, info.min as Number);
    }

    //! A time of day in the watch's own format (12 h: "h:mm", no am/pm).
    //! Takes the hour and minute rather than a Moment, so the start screen
    //! can also ask how wide the widest time of day would be.
    private function formatHourMin(hour as Number, min as Number) as String {
        var mm = formatTwoDigits(min);
        if (is24Hour()) {
            return formatTwoDigits(hour) + ":" + mm;
        }
        var h = hour % 12;
        return ((h == 0) ? 12 : h).toString() + ":" + mm;
    }

    //! How wide the WIDEST time of day this watch can show is, in `font`.
    //! The start screen decides whether the clock fits on this, never on the
    //! time it happens to be: deciding on the current time would show the
    //! clock at 9:59 and take it away at 10:00, in front of someone who is
    //! looking at the screen. Widths add up, so the widest "HH:MM" is the
    //! widest hour beside the widest minute; measured once per 12/24 h
    //! format and kept (the Instinct never gets here - its clock is in the
    //! lens).
    private function widestClockWidth(dc as Graphics.Dc, font as Graphics.FontDefinition) as Number {
        var is24 = is24Hour();
        if (_clockWidth >= 0 && _clockWidth24 == is24) {
            return _clockWidth;
        }
        var minute = 0;
        var widest = -1;
        for (var m = 0; m < 60; m++) {
            var w = dc.getTextWidthInPixels(formatTwoDigits(m), font);
            if (w > widest) {
                widest = w;
                minute = m;
            }
        }
        widest = -1;
        for (var h = 0; h < 24; h++) {
            var w = dc.getTextWidthInPixels(formatHourMin(h, minute), font);
            if (w > widest) {
                widest = w;
            }
        }
        _clockWidth = widest;
        _clockWidth24 = is24;
        return widest;
    }

    private function is24Hour() as Boolean {
        try {
            return System.getDeviceSettings().is24Hour;
        } catch (e instanceof Lang.Exception) {
            return true;
        }
    }

    // Debug builds: show "dev #<build>" on the start screen so you can tell
    // a fresh sideload from a cached one. Bump the string when building for
    // the watch. Release builds show nothing.
    (:debug)
    private function buildDebugLabel() as String {
        return "dev #0920a";
    }

    (:release)
    private function buildDebugLabel() as String {
        return "";
    }

    // -- Test hooks (debug builds only) -----------------------------------

    //! Build and solve the layout for the current state (start screen when
    //! not started) against the given Dc (tests pass a screen-sized bitmap).
    (:debug)
    function testBuildLayout(dc as Graphics.Dc) as ScreenLayout {
        return buildLayout(dc);
    }

    (:debug)
    function testSetStarted(started as Boolean) as Void {
        _started = started;
    }

    (:debug)
    function testGetPendingDuration() as Number {
        return _pendingDuration;
    }

    (:debug)
    function testSetPendingDuration(minutes as Number) as Void {
        _pendingDuration = minutes;
    }


    //! Pretend the battery is at pct % (-1: use the real level).
    (:debug)
    function testForceBattery(pct as Number) as Void {
        _forceBatteryPct = pct;
    }

    (:debug)
    function testIsFlashPhase() as Boolean {
        return isFlashPhase();
    }

    (:debug)
    function testClockString() as String {
        return clockString();
    }

    //! The alarm cap the start screen promises for the current pick.
    (:debug)
    function testPreviewCapSec() as Number {
        return _detector.previewDeadlineSec(_pendingDuration);
    }

    //! Milliseconds the start-screen refresh waits when the wall clock is
    //! at second `sec` of a minute.
    (:debug)
    function testUiWakeMs(sec as Number) as Number {
        return uiWakeMs(sec);
    }

    //! Whether the start-screen refresh timer is waiting for its next look.
    (:debug)
    function testUiTimerArmed() as Boolean {
        return _uiTimerArmed;
    }

    //! Format a moment exactly like the screens do (12/24 h).
    (:debug)
    function testFormatMoment(moment as Time.Moment) as String {
        return formatMoment(moment);
    }

    (:debug)
    function testHasSubscreen() as Boolean {
        return hasSubscreen();
    }

    //! Move the view's millisecond clock (confirm window, input lock, peek).
    (:debug)
    function testAdvanceMs(ms as Number) as Void {
        _msOffset += ms;
    }

    //! End the input lock now (tests of deliberate follow-up presses).
    (:debug)
    function testExpireInputLock() as Void {
        _locked = false;
    }

    //! Whether the popup showing is the BACK hint of `kind` (BACK_HINT_*).
    //! Compared against the resource, so a reworded string does not have to
    //! be repeated in a test.
    (:debug)
    function testHintIsFor(kind as Number) as Boolean {
        if (_hintTexts == null) {
            return false;
        }
        return (_hintTexts as Array<String>)[0].equals(backHintTexts(kind)[0]);
    }

    (:debug)
    function testIsHintShowing() as Boolean {
        return isHintShowing();
    }

    //! Lay out the start screen on dc and return [plusMaxY, minusMinY,
    //! number slot height, label slot height, hint (start) min Y].
    (:debug)
    function testMeasureTapZones(dc as Graphics.Dc) as Array<Number> {
        var lines = [] as Array<LayoutLine>;
        solveStartScreen(dc, lines);
        return [_tapPlusMaxY, _tapMinusMinY, lines[1].slotH, lines[2].slotH, _tapStartMinY] as Array<Number>;
    }

    //! The start screen's clock box [x, y, w, h, firstLineY] (drawn in the
    //! top margin on devices without a lens), or null when it is not drawn.
    (:debug)
    function testStartClockBox(dc as Graphics.Dc) as Array<Number>? {
        var lines = [] as Array<LayoutLine>;
        var L = solveStartScreen(dc, lines);
        var box = startClockBox(dc, L, lines[0].y);
        if (box == null) {
            return null;
        }
        var b = box as Array<Number>;
        return [b[0], b[1], b[2], b[3], lines[0].y] as Array<Number>;
    }
}
