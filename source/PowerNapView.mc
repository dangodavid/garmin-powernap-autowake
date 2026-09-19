import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;

//! Draws the start screen and the four nap screens (monitoring, sleeping,
//! alarm, summary). The detector requests an update every second while a
//! nap is active, so every value on screen is live.
//!
//! Every nap screen is described as a prioritised list of lines and laid out
//! by ScreenLayout, which drops optional lines and shrinks fonts until the
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
    private var _pendingDuration as Number = 30;
    // Tap zones measured from the last start-screen draw (-1 = not drawn yet)
    private var _tapPlusMaxY as Number = -1;    // y < this        -> +5 min
    private var _tapMinusMinY as Number = -1;   // y > this        -> -5 min

    // Two-press confirmation for stopping a nap or the alarm (4 s, in ms).
    private var _confirm as ConfirmPress;
    private const CONFIRM_WINDOW_MS = 4000;

    // Duration options in minutes (step 5, wrap-around)
    private const DURATION_MIN = 5;
    private const DURATION_MAX = 120;

    function initialize(detector as SleepDetector, alarm as AlarmManager) {
        View.initialize();
        _detector = detector;
        _alarm = alarm;
        _confirm = new ConfirmPress(CONFIRM_WINDOW_MS);
        _pendingDuration = readStoredDuration();
        _debugLabel = buildDebugLabel();
    }

    function onShow() as Void {
        // Do NOT auto-start  - wait for user to press START on the start screen
    }

    function onHide() as Void {
        // Cleanup is handled by PowerNapApp.onStop() when the app exits.
        // Do NOT stop sensors/timers here: onHide() can be called when a
        // system overlay appears (incoming call, control menu, battery alert).
    }

    // -- Public interface for delegate / app ----------------------------

    function isStarted() as Boolean {
        return _started;
    }

    //! Increase or decrease the pending nap duration by one step.
    function adjustDuration(delta as Number) as Void {
        _pendingDuration += delta;
        if (_pendingDuration < DURATION_MIN) {
            _pendingDuration = DURATION_MAX;
        } else if (_pendingDuration > DURATION_MAX) {
            _pendingDuration = DURATION_MIN;
        }
        WatchUi.requestUpdate();
    }

    //! Settings changed from the phone: follow a new nap duration while the
    //! start screen is showing (a running nap keeps its own settings).
    function onSettingsChanged() as Void {
        if (!_started) {
            _pendingDuration = readStoredDuration();
            WatchUi.requestUpdate();
        }
    }

    //! Confirm duration, persist it (only if changed), and begin monitoring.
    function startNap() as Void {
        if (readStoredDuration() != _pendingDuration) {
            try {
                Application.Properties.setValue("napDuration", _pendingDuration);
            } catch (e instanceof Lang.Exception) {
                // Storage full or corrupt -- proceed with in-memory value.
            }
        }
        _detector.loadSettings();
        _detector.start();
        _started = true;
        _confirm.reset();
        WatchUi.requestUpdate();
    }

    //! Cancel the current nap and return to the start screen so the user
    //! can change the duration and start again.
    function resetToStart() as Void {
        _detector.stop();
        _alarm.stop();
        _started = false;
        _confirm.reset();
        // Pick up a duration changed from the phone during the aborted nap.
        _pendingDuration = readStoredDuration();
        WatchUi.requestUpdate();
    }

    //! Register a stop press in the given ConfirmPress context. Returns true
    //! when it is the confirming second press.
    function pressStop(context as Number) as Boolean {
        var confirmed = _confirm.press(nowMs(), context);
        WatchUi.requestUpdate();
        return confirmed;
    }

    //! Start-screen tap: +1 = add 5 min, -1 = remove 5 min, 0 = start.
    function tapActionAt(y as Number) as Number {
        var plusMax = _tapPlusMaxY;
        var minusMin = _tapMinusMinY;
        if (plusMax < 0 || minusMin < 0) {
            var h = System.getDeviceSettings().screenHeight;
            plusMax = h * 35 / 100;
            minusMin = h * 65 / 100;
        }
        if (y < plusMax) { return 1; }
        if (y > minusMin) { return -1; }
        return 0;
    }

    // -- Main draw dispatch ---------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (!_started) {
            drawStartScreen(dc);
            return;
        }

        var invert = false;
        var state = _detector.getState();
        if (state == SleepDetector.STATE_ALARM && (Time.now().value() % 2 == 0)) {
            // 1 Hz flash (the detector refreshes the view every second).
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

        var layout = buildLayout(dc);
        if (layout != null) {
            (layout as ScreenLayout).draw(dc, invert);
        }
    }

    //! Solved layout for the current nap state (null on the start screen).
    private function buildLayout(dc as Graphics.Dc) as ScreenLayout? {
        if (!_started) {
            return null;
        }
        var state = _detector.getState();
        var layout;
        if (state == SleepDetector.STATE_CALIBRATING || state == SleepDetector.STATE_MONITORING) {
            layout = monitoringLayout(dc);
        } else if (state == SleepDetector.STATE_SLEEPING) {
            layout = sleepingLayout(dc);
        } else if (state == SleepDetector.STATE_ALARM) {
            layout = alarmLayout(dc);
        } else {
            layout = _detector.hasSleptAtLeastOnce() ? summaryLayout(dc) : noSleepLayout(dc);
        }
        layout.solve(dc);
        return layout;
    }

    // -- Screen 0: Start / Duration Picker -----------------------------

    //! Start-screen geometry: the block is centred vertically. Also records
    //! the tap zones so they always match what is drawn: everything above
    //! the number adds 5 min, everything below the "min" label removes 5 min,
    //! the number and the label start the nap.
    //! Returns [titleY, upArrowY, numberY, minLabelY, downArrowY, hintY].
    private function measureStartScreen(dc as Graphics.Dc) as Array<Number> {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        // With a subscreen (Instinct) the title goes into the lens instead.
        var titleH = hasSubscreen() ? 0 : dc.getFontHeight(Graphics.FONT_SMALL);
        var numH   = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
        var minH   = dc.getFontHeight(Graphics.FONT_SMALL);
        var hintH  = dc.getFontHeight(Graphics.FONT_XTINY);
        var arrowH = w * 6 / 100;
        var gap    = h * 3 / 100;

        var titleGap = (titleH > 0) ? gap : 0;
        var blockH = titleH + titleGap + arrowH + gap + numH + minH + gap + arrowH + gap + hintH;
        var titleY = (h - blockH) / 2;
        var upY    = titleY + titleH + titleGap;
        var numY   = upY + arrowH + gap;
        var minY   = numY + numH;
        var downY  = minY + minH + gap;
        var hintY  = downY + arrowH + gap;
        _tapPlusMaxY = numY;
        _tapMinusMinY = minY + minH;
        return [titleY, upY, numY, minY, downY, hintY] as Array<Number>;
    }

    private function drawStartScreen(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;
        var arrowH = w * 6 / 100;  // arrow triangle height in px
        var pos = measureStartScreen(dc);
        var y = pos[0];

        dc.setColor(Palette.fg(Graphics.COLOR_BLUE, false), Graphics.COLOR_TRANSPARENT);
        var sub = subscreenBox();
        if (sub != null) {
            var box = sub as Array<Number>;
            var fh = dc.getFontHeight(Graphics.FONT_XTINY);
            dc.drawText(box[0] + box[2] / 2, box[1] + (box[3] - fh) / 2, Graphics.FONT_XTINY, "NAP",
                Graphics.TEXT_JUSTIFY_CENTER);
        } else {
            dc.drawText(cx, y, Graphics.FONT_SMALL, "POWER NAP", Graphics.TEXT_JUSTIFY_CENTER);
        }

        y = pos[1];
        dc.setColor(Palette.fg(Graphics.COLOR_GREEN, false), Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i <= arrowH; i++) {
            dc.drawLine(cx - i, y + (arrowH - i), cx + i, y + (arrowH - i));
        }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, pos[2], Graphics.FONT_NUMBER_MEDIUM, _pendingDuration.toString(),
            Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Palette.fg(Graphics.COLOR_LT_GRAY, false), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, pos[3], Graphics.FONT_SMALL, "min", Graphics.TEXT_JUSTIFY_CENTER);

        y = pos[4];
        dc.setColor(Palette.fg(Graphics.COLOR_GREEN, false), Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i <= arrowH; i++) {
            dc.drawLine(cx - i, y + i, cx + i, y + i);
        }

        dc.setColor(Palette.fg(Graphics.COLOR_LT_GRAY, false), Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, pos[5], Graphics.FONT_XTINY, "START to begin", Graphics.TEXT_JUSTIFY_CENTER);

        if (_debugLabel.length() > 0) {
            dc.drawText(cx, h - dc.getFontHeight(Graphics.FONT_XTINY) - 2,
                Graphics.FONT_XTINY, _debugLabel, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // -- Screen 1: Calibrating / Monitoring / Awake ---------------------

    private function monitoringLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        var calibrating = (_detector.getState() == SleepDetector.STATE_CALIBRATING);
        var awake = _detector.hasSleptAtLeastOnce();   // after a wake episode

        L.addText(["POWER NAP"], fontsTitle(), Graphics.COLOR_BLUE, 60);
        L.addDivider(14, Graphics.COLOR_DK_GRAY, 10);
        L.addText(["HR " + hrString(_detector.getCurrentHR())], fontsBody(), Graphics.COLOR_RED, 70);

        var status = calibrating ? "Calibrating..." : (awake ? "Awake" : "Monitoring");
        L.addText([status], fontsBody(), Graphics.COLOR_WHITE, ScreenLayout.KEEP);

        if (awake) {
            // The alarm time is fixed; the countdown keeps running while awake.
            L.addText(["Alarm in " + formatCountdown(_detector.getRemainingSeconds())],
                fontsDetail(), Graphics.COLOR_YELLOW, 95);
        } else if (calibrating) {
            L.addText(["Building baseline...", "Baseline..."], fontsDetail(), Graphics.COLOR_LT_GRAY, 95);
        } else if (_detector.getStillMinutes() > 0) {
            L.addText(["Stillness " + _detector.getOnsetProgressPct() + "%"],
                fontsDetail(), Graphics.COLOR_YELLOW, 95);
        } else {
            L.addText(["Waiting for sleep...", "Waiting..."], fontsDetail(), Graphics.COLOR_LT_GRAY, 95);
        }

        if (!awake) {
            // The guaranteed latest alarm time, rounded UP to the minute so
            // the alarm is never later than the time shown.
            // Ranked above the stillness line: on the smallest screens the
            // alarm promise is the line that must survive.
            var byStr = formatMoment(new Time.Moment(_detector.getDeadlineTime().value() + 59));
            L.addText(["Alarm by " + byStr, "By " + byStr], fontsDetail(), Graphics.COLOR_LT_GRAY, 96);
        }
        addInactiveWarning(L);
        L.addText(["Nap " + _detector.getNapDurationMin() + " min"], fontsDetail(), Graphics.COLOR_LT_GRAY, 30);
        L.setFooter(stopHint(ConfirmPress.CONTEXT_NAP), footerColor(ConfirmPress.CONTEXT_NAP));
        return L;
    }

    // -- Screen 2: Sleep Detected / Countdown --------------------------

    private function sleepingLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        var smartWake = _detector.isSmartWakeActive();

        L.addText(["NAP DETECTED", "ASLEEP"], fontsTitle(), Graphics.COLOR_PURPLE, 60);
        L.addDivider(14, Graphics.COLOR_DK_GRAY, 10);
        var sleepStart = _detector.getSleepStartTime();
        if (sleepStart != null) {
            // First onset of this nap (not reset by a wake episode).
            var t = formatMoment(sleepStart as Time.Moment);
            L.addText(["Nap from " + t, "From " + t], fontsBody(), Graphics.COLOR_LT_GRAY, 50);
        }
        var label = L.addText([smartWake ? "Smart Wake" : "Wake in"], fontsBody(), Graphics.COLOR_WHITE, 80);
        label.gapAfter = 2;
        L.addText([formatCountdown(_detector.getRemainingSeconds())],
            [Graphics.FONT_NUMBER_MEDIUM, Graphics.FONT_NUMBER_MILD, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]
                as Array<Graphics.FontDefinition>,
            smartWake ? Graphics.COLOR_YELLOW : Graphics.COLOR_GREEN, ScreenLayout.KEEP);
        addInactiveWarning(L);
        L.addText(["HR " + hrString(_detector.getCurrentHR())], fontsDetail(), Graphics.COLOR_RED, 40);
        L.setFooter(stopHint(ConfirmPress.CONTEXT_NAP), footerColor(ConfirmPress.CONTEXT_NAP));
        return L;
    }

    // -- Screen 3: Alarm / Wake Up -------------------------------------

    private function alarmLayout(dc as Graphics.Dc) as ScreenLayout {
        var L = new ScreenLayout(dc.getWidth(), dc.getHeight(), 14);
        var reason = _detector.getAlarmReason();
        var deadline = (reason == SleepDetector.ALARM_DEADLINE);

        L.addText([deadline ? "TIME'S UP" : "WAKE UP!"],
            [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL] as Array<Graphics.FontDefinition>,
            Graphics.COLOR_WHITE, ScreenLayout.KEEP);
        L.addDivider(14, Graphics.COLOR_WHITE, 10);
        if (deadline) {
            L.addText(["No sleep detected", "No sleep"], fontsBody(), Graphics.COLOR_WHITE, 85);
        } else if (reason == SleepDetector.ALARM_SMART_WAKE) {
            L.addText(["Smart wake"], fontsBody(), Graphics.COLOR_WHITE, 85);
        }

        if (deadline) {
            L.addText(["Waited " + (sessionSeconds() / 60) + " min"], fontsBody(), Graphics.COLOR_WHITE, 80);
        } else {
            L.addText(["Slept " + formatCountdown(_detector.getActualNapDurationSec())],
                fontsBody(), Graphics.COLOR_WHITE, 80);
        }
        var avgHR = _detector.getAvgSleepHR();
        if (avgHR > 0) {
            L.addText(["Avg HR " + avgHR + " BPM", "Avg " + avgHR], fontsBody(), Graphics.COLOR_WHITE, 30);
        }
        L.addText(["ALARM " + (_alarm.getCurrentPhase() + 1) + "/4"], fontsBody(), Graphics.COLOR_YELLOW, 40);
        L.setFooter(stopHint(ConfirmPress.CONTEXT_ALARM), Graphics.COLOR_WHITE);
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

        L.addText(cancelled ? ["NAP STOPPED", "STOPPED", "STOP"] : ["NAP COMPLETE", "COMPLETE", "DONE"],
            fontsBody(), accent, ScreenLayout.KEEP);
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
        L.setFooter("BACK to exit", Graphics.COLOR_LT_GRAY);
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
        L.setFooter("BACK to exit", Graphics.COLOR_LT_GRAY);
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

    private function stopHint(context as Number) as String {
        if (_confirm.isArmed(nowMs(), context)) {
            return "Press again to stop";
        }
        return "BACK x2 to stop";
    }

    private function footerColor(context as Number) as Graphics.ColorType {
        return _confirm.isArmed(nowMs(), context) ? Graphics.COLOR_RED : Graphics.COLOR_LT_GRAY;
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

    private function readStoredDuration() as Number {
        var d = _pendingDuration;
        try {
            var saved = Application.Properties.getValue("napDuration");
            if (saved != null && saved instanceof Number) {
                d = saved as Number;
            }
        } catch (e instanceof Lang.Exception) {
            // Storage corrupt -- keep the current value.
        }
        if (d < DURATION_MIN) { d = DURATION_MIN; }
        if (d > DURATION_MAX) { d = DURATION_MAX; }
        return d;
    }

    //! Millisecond clock for the two-press window (not rounded to seconds).
    private function nowMs() as Number {
        return System.getTimer();
    }

    private function hrString(hr as Number) as String {
        return (hr > 0) ? (hr.toString() + " BPM") : "--";
    }

    private function formatCountdown(totalSeconds as Number) as String {
        if (totalSeconds < 0) { totalSeconds = 0; }
        return (totalSeconds / 60).toString() + ":" + formatTwoDigits(totalSeconds % 60);
    }

    private function formatTwoDigits(n as Number) as String {
        return (n < 10) ? "0" + n.toString() : n.toString();
    }

    private function formatMoment(moment as Time.Moment) as String {
        var info = Gregorian.info(moment, Time.FORMAT_SHORT);
        return formatTwoDigits(info.hour as Number) + ":" + formatTwoDigits(info.min as Number);
    }

    // Debug builds: show "dev #<build>" on the start screen so you can tell
    // a fresh sideload from a cached one. Bump the string when building for
    // the watch. Release builds show nothing.
    (:debug)
    private function buildDebugLabel() as String {
        return "dev #0919b";
    }

    (:release)
    private function buildDebugLabel() as String {
        return "";
    }

    // -- Test hooks (debug builds only) -----------------------------------

    //! Build and solve the layout for the current detector state against the
    //! given Dc (tests pass a screen-sized buffered bitmap).
    (:debug)
    function testBuildLayout(dc as Graphics.Dc) as ScreenLayout? {
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

    //! Measure the start screen on dc and return [plusMaxY, minusMinY].
    (:debug)
    function testMeasureTapZones(dc as Graphics.Dc) as Array<Number> {
        measureStartScreen(dc);
        return [_tapPlusMaxY, _tapMinusMinY] as Array<Number>;
    }
}
