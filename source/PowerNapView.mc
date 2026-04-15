import Toybox.WatchUi;
import Toybox.Graphics;
import Toybox.Time;
import Toybox.Time.Gregorian;
import Toybox.Application;
import Toybox.Lang;

class PowerNapView extends WatchUi.View {

    private var _detector as SleepDetector;
    private var _alarm as AlarmManager;
    private var _alarmTriggered as Boolean = false;

    // Debug label: shows "dev HH:MM" on start screen in debug builds only.
    // Release/store builds show nothing (buildDebugLabel returns "").
    private var _debugLabel as String = "";

    // Start screen state
    private var _started as Boolean = false;
    private var _pendingDuration as Number = 30;

    // Duration options in minutes (step 5, wrap-around)
    private const DURATION_MIN = 5;
    private const DURATION_MAX = 120;


    function initialize(detector as SleepDetector, alarm as AlarmManager) {
        View.initialize();
        _detector = detector;
        _alarm = alarm;
        // Load last used duration from persistent storage
        try {
            var saved = Application.Properties.getValue("napDuration");
            if (saved != null && saved instanceof Number) {
                _pendingDuration = saved as Number;
            }
        } catch (e instanceof Lang.Exception) {
            // Storage corrupt -- use default 30 min.
        }
        _debugLabel = buildDebugLabel();
    }

    function onShow() as Void {
        // Do NOT auto-start  - wait for user to press START on the start screen
    }

    function onHide() as Void {
        // Cleanup is handled by PowerNapApp.onStop() when the app exits.
        // Do NOT stop sensors/timers here: onHide() can be called when a
        // system overlay appears (incoming call, control menu, battery alert).
        // Stopping here would kill an active nap session.
    }

    // -- Public interface for delegate ----------------------------------

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

    //! Confirm duration, persist it, and begin sleep monitoring.
    function startNap() as Void {
        try {
            Application.Properties.setValue("napDuration", _pendingDuration);
        } catch (e instanceof Lang.Exception) {
            // Storage full or corrupt -- proceed with in-memory value.
        }
        _detector.loadSettings();
        _detector.start();
        _started = true;
        WatchUi.requestUpdate();
    }

    //! Reset alarm flag after dismiss.
    function resetAlarmFlag() as Void {
        _alarmTriggered = false;
    }

    //! Cancel the current nap and return to the start screen so the user
    //! can change the duration and start again.
    function resetToStart() as Void {
        _detector.stop();
        _alarm.stop();
        _started = false;
        _alarmTriggered = false;
        WatchUi.requestUpdate();
    }

    // -- Main draw dispatch ---------------------------------------------

    function onUpdate(dc as Graphics.Dc) as Void {
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        if (!_started) {
            drawStartScreen(dc);
            return;
        }

        var state = _detector.getState();

        // Alarm is started by SleepDetector.transitionToAlarm() from the
        // timer callback, so it fires even when the display is off (AMOLED).
        // No need to start it here -- just track the flag for view state.
        if (state == SleepDetector.STATE_ALARM && !_alarmTriggered) {
            _alarmTriggered = true;
        }

        if (state == SleepDetector.STATE_CALIBRATING || state == SleepDetector.STATE_MONITORING) {
            drawMonitoring(dc);
        } else if (state == SleepDetector.STATE_SLEEPING) {
            drawSleeping(dc);
        } else if (state == SleepDetector.STATE_ALARM) {
            drawAlarm(dc);
        } else if (state == SleepDetector.STATE_SUMMARY) {
            drawSummary(dc);
        } else if (state == SleepDetector.STATE_TIMEOUT) {
            drawTimeout(dc);
        }
    }

    // -- Screen 0: Start / Duration Picker -----------------------------

    private function drawStartScreen(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        var titleH = dc.getFontHeight(Graphics.FONT_SMALL);
        var numH   = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
        var minH   = dc.getFontHeight(Graphics.FONT_SMALL);
        var hintH  = dc.getFontHeight(Graphics.FONT_XTINY);
        var arrowH = w * 6 / 100;  // arrow triangle height in px
        var gap    = h * 3 / 100;  // vertical gap between elements

        // Calculate total block height and centre it vertically
        var blockH = titleH + gap + arrowH + gap + numH + minH + gap + arrowH + gap + hintH;
        var y = (h - blockH) / 2;

        // -- Title --
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_SMALL, "POWER NAP",
            Graphics.TEXT_JUSTIFY_CENTER);
        y += titleH + gap;

        // -- Up arrow --
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i <= arrowH; i++) {
            dc.drawLine(cx - i, y + (arrowH - i), cx + i, y + (arrowH - i));
        }
        y += arrowH + gap;

        // -- Duration number --
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_NUMBER_MEDIUM, _pendingDuration.toString(),
            Graphics.TEXT_JUSTIFY_CENTER);
        y += numH;

        // -- "min" label (tight below number) --
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_SMALL, "min",
            Graphics.TEXT_JUSTIFY_CENTER);
        y += minH + gap;

        // -- Down arrow --
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        for (var i = 0; i <= arrowH; i++) {
            dc.drawLine(cx - i, y + i, cx + i, y + i);
        }
        y += arrowH + gap;

        // -- START hint --
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_XTINY, "START to begin",
            Graphics.TEXT_JUSTIFY_CENTER);

        // -- Debug label (bottom edge, only in debug builds) --
        if (_debugLabel.length() > 0) {
            dc.drawText(cx, h - dc.getFontHeight(Graphics.FONT_XTINY) - 2,
                Graphics.FONT_XTINY, _debugLabel, Graphics.TEXT_JUSTIFY_CENTER);
        }
    }

    // -- Screen 1: Calibrating / Monitoring ----------------------------

    private function drawMonitoring(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        // All gaps and widths proportional to screen size
        var gap    = (h / 40).toNumber(); if (gap < 4) { gap = 4; }
        var gapS   = (gap / 2).toNumber(); if (gapS < 2) { gapS = 2; }
        var divW   = (w * 14) / 100;
        var fMed   = dc.getFontHeight(Graphics.FONT_MEDIUM);
        var fSmall = dc.getFontHeight(Graphics.FONT_SMALL);
        var fTiny  = dc.getFontHeight(Graphics.FONT_TINY);
        var fXtiny = dc.getFontHeight(Graphics.FONT_XTINY);

        // Total content block height (title + divider + HR + status + nap + state)
        var blockH = fMed + gap + 1 + gapS + fSmall + gap + fSmall + gap + fTiny + gap + fTiny;
        // Centre block in safe zone (below 18%, above footer)
        var footerY = h - fXtiny - gap;
        var safeTop = (h * 18) / 100;
        var yPos = safeTop;
        var avail = footerY - gap - safeTop;
        if (blockH < avail) { yPos = safeTop + (avail - blockH) / 2; }

        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_MEDIUM, "POWER NAP", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fMed + gap;

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - divW, yPos, cx + divW, yPos);
        yPos += 1 + gapS;

        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            "HR: " + _detector.getCurrentHR() + " BPM", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fSmall + gap;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var statusText = (_detector.getState() == SleepDetector.STATE_CALIBRATING)
            ? "Calibrating..." : "Monitoring";
        dc.drawText(cx, yPos, Graphics.FONT_SMALL, "Status: " + statusText,
            Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fSmall + gap;

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_TINY,
            "Nap: " + _detector.getNapDurationMin() + " min", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fTiny + gap;

        if (_detector.getState() == SleepDetector.STATE_MONITORING) {
            var immSec = _detector.getImmobileDuration();
            var reqSec = _detector.getImmobilityRequired();
            if (immSec > 0) {
                var pct = (immSec * 100) / reqSec;
                if (pct > 100) { pct = 100; }
                dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, yPos, Graphics.FONT_TINY,
                    "Stillness: " + pct + "%", Graphics.TEXT_JUSTIFY_CENTER);
            } else {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, yPos, Graphics.FONT_TINY,
                    "Waiting for sleep...", Graphics.TEXT_JUSTIFY_CENTER);
            }
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, yPos, Graphics.FONT_TINY,
                "Building baseline...", Graphics.TEXT_JUSTIFY_CENTER);
        }

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, footerY, Graphics.FONT_XTINY, "BACK to cancel",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // -- Screen 2: Sleep Detected / Countdown --------------------------

    private function drawSleeping(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        var gap    = (h / 40).toNumber(); if (gap < 4) { gap = 4; }
        var gapS   = (gap / 2).toNumber(); if (gapS < 2) { gapS = 2; }
        var divW   = (w * 14) / 100;
        var fMed    = dc.getFontHeight(Graphics.FONT_MEDIUM);
        var fNumMed = dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM);
        var fSmall  = dc.getFontHeight(Graphics.FONT_SMALL);
        var fTiny   = dc.getFontHeight(Graphics.FONT_TINY);
        var fXtiny  = dc.getFontHeight(Graphics.FONT_XTINY);

        // Safe zone: 20% from top keeps title in the wider part of a round display.
        var footerY = h - fXtiny - gap;
        var safeTop = (h * 20) / 100;
        var avail   = footerY - gap - safeTop;

        // Try full block (with optional HR line); fall back to core block without it.
        // Trailing gap is included so the last element never kisses the footer.
        var fullBlockH = fMed + gap + 1 + gapS + fSmall + gap + fSmall + gapS + fNumMed + gap + fTiny + gap;
        var coreH      = fullBlockH - fTiny - gap;
        var showHR     = (fullBlockH <= avail);
        var blockH     = showHR ? fullBlockH : coreH;
        var yPos = safeTop;
        if (blockH < avail) { yPos = safeTop + (avail - blockH) / 2; }

        dc.setColor(Graphics.COLOR_PURPLE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_MEDIUM, "NAP DETECTED", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fMed + gap;

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - divW, yPos, cx + divW, yPos);
        yPos += 1 + gapS;

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var sleepStart = _detector.getSleepStartTime();
        if (sleepStart != null) {
            var info = Gregorian.info(sleepStart as Time.Moment, Time.FORMAT_SHORT);
            dc.drawText(cx, yPos, Graphics.FONT_SMALL,
                "Fell asleep at " + formatTime(info.hour, info.min),
                Graphics.TEXT_JUSTIFY_CENTER);
        }
        yPos += fSmall + gap;

        var remaining = _detector.getRemainingSeconds();
        var smartWakeActive = (remaining <= 300 && remaining > 0
            && _detector.getNapDurationMin() >= 30);

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            smartWakeActive ? "Smart Wake" : "Wake in:",
            Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fSmall + gapS;

        dc.setColor(smartWakeActive ? Graphics.COLOR_YELLOW : Graphics.COLOR_GREEN,
            Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_NUMBER_MEDIUM,
            formatCountdown(remaining), Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fNumMed + gap;

        if (showHR) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, yPos, Graphics.FONT_TINY,
                "HR: " + _detector.getCurrentHR() + " BPM", Graphics.TEXT_JUSTIFY_CENTER);
        }

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, footerY, Graphics.FONT_XTINY, "BACK to cancel",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // -- Screen 3: Alarm / Wake Up -------------------------------------

    private function drawAlarm(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        var gap    = (h / 40).toNumber(); if (gap < 4) { gap = 4; }
        var gapS   = (gap / 2).toNumber(); if (gapS < 2) { gapS = 2; }
        var divW   = (w * 14) / 100;
        var fLarge = dc.getFontHeight(Graphics.FONT_LARGE);
        var fSmall = dc.getFontHeight(Graphics.FONT_SMALL);

        // Flashing red background on even seconds
        var now = Time.now().value();
        if (now % 2 == 0) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_RED);
            dc.fillRectangle(0, 0, w, h);
        }

        // Block: title + divider + nap-duration + avg-HR + vibrating label
        var blockH = fLarge + gap + 1 + gap + fSmall + gapS + fSmall + gap + fSmall;
        // Footer raised to 85 % of height so it sits in the wider part of the ring.
        // At y≈h the circular bezel narrows to ~100 px half-width which clips the text;
        // at 85 % the half-width is ~150 px  - enough for "BACK to dismiss".
        var footerY = (h * 85) / 100;
        var safeTop = (h * 18) / 100;
        var yPos = safeTop;
        var avail = footerY - gap - safeTop;
        if (blockH < avail) { yPos = safeTop + (avail - blockH) / 2; }

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_LARGE, "WAKE UP!", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fLarge + gap;

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - divW, yPos, cx + divW, yPos);
        yPos += 1 + gap;

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var napMin = _detector.getActualNapDurationSec() / 60;
        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            "Nap: " + napMin + " min", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fSmall + gapS;

        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            "Avg HR: " + _detector.getAvgSleepHR() + " BPM", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += fSmall + gap;

        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_SMALL, "VIBRATING", Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, footerY, Graphics.FONT_XTINY, "BACK to dismiss",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // -- Screen 4: Summary (compact layout, guaranteed to fit any device) --

    private function drawSummary(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;
        var cy = h / 2;

        // -- Completion metrics -----------------------------------------
        var napSec = _detector.getActualNapDurationSec();

        // Sleep efficiency = actual sleep time / planned nap duration.
        // Using the planned duration (not wall-clock) as denominator ensures
        // the percentage reflects "how much of your planned nap did you sleep",
        // regardless of the 1-2 mechanical tick gaps at wake/re-sleep boundaries
        // that would otherwise inflate the wall-clock and deflate the percentage.
        // Example: 110 s actual sleep out of 120 s planned -> 91.6 % (correct),
        // vs 110/140 s wall-clock -> 78 % (misleading due to gap ticks).
        var sleepStart = _detector.getSleepStartTime();
        var napEnd     = _detector.getNapEndTime();
        var targetSec  = _detector.getNapDurationMin() * 60;
        var pct = 0;
        if (targetSec > 0) { pct = napSec * 100 / targetSec; }
        if (pct > 100) { pct = 100; }

        // -- 5-step quality scale ---------------------------------------
        // 95–100 %  Perfect      bright green   uninterrupted full nap
        //  80– 94 %  Excellent    green          minor interruption
        //  65– 79 %  Good         yellow         moderate interruption
        //  50– 64 %  Fair         orange         significant interruption
        //   0– 49 %  Interrupted  red            heavily fragmented
        var accentColor = 0x00FF55;       // bright green   - Perfect
        var qualityLabel = "Perfect";
        if (pct < 95) { accentColor = Graphics.COLOR_GREEN;  qualityLabel = "Excellent";   }
        if (pct < 80) { accentColor = Graphics.COLOR_YELLOW; qualityLabel = "Good";        }
        if (pct < 65) { accentColor = Graphics.COLOR_ORANGE; qualityLabel = "Fair";        }
        if (pct < 50) { accentColor = Graphics.COLOR_RED;    qualityLabel = "Interrupted"; }

        // -- Progress ring ----------------------------------------------
        var ringR = (w / 2) - 6;
        dc.setPenWidth(5);
        dc.setColor(0x222222, Graphics.COLOR_TRANSPARENT);
        dc.drawArc(cx, cy, ringR, Graphics.ARC_CLOCKWISE, 90, -270);
        if (pct > 0) {
            var endAngle = 90 - (pct * 360 / 100);
            dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
            dc.drawArc(cx, cy, ringR, Graphics.ARC_CLOCKWISE, 90, endAngle);
        }
        dc.setPenWidth(1);

        // -- Fonts: deliberately smaller than other screens so content fits
        //    FONT_NUMBER_MILD is roughly half the height of FONT_NUMBER_MEDIUM,
        //    which is critical on devices where NUMBER_MEDIUM is 120–150 px tall.
        var fSmall  = dc.getFontHeight(Graphics.FONT_SMALL);
        var fNumMil = dc.getFontHeight(Graphics.FONT_NUMBER_MILD);
        var fXtiny  = dc.getFontHeight(Graphics.FONT_XTINY);

        var gap  = (h / 50).toNumber(); if (gap < 3) { gap = 3; }
        var gapS = (gap / 2).toNumber(); if (gapS < 2) { gapS = 2; }

        // -- Layout ----------------------------------------------------
        // Safe zone: 22 % from top to stay in the wide part of the ring.
        // Footer pinned near the bottom inside the ring.
        // Footer raised to 88 % so it sits in the wider part of the ring;
        // near the very bottom the circular bezel narrows enough to clip text.
        var footerY = (h * 88) / 100;
        var safeTop = (h * 22) / 100;
        var avail   = footerY - gap - safeTop;

        // Core block (always shown).  One trailing gap keeps the last
        // element from kissing the footer.
        // Elements: title / duration / sub-line / divider / avg HR / min HR
        var coreH = fSmall  + gapS     // title
                  + fNumMil + gapS     // duration
                  + fXtiny  + gap      // "X% · Quality"
                  + 1       + gap      // divider
                  + fXtiny  + gapS     // "Avg HR  XX BPM"
                  + fXtiny  + gap;     // "Min HR  XX BPM" + trailing gap

        // Time range only if there is room left
        var showTimeRange = (coreH + fXtiny + gap <= avail);
        var blockH = showTimeRange ? (coreH + fXtiny + gap) : coreH;
        var y = safeTop;
        if (blockH < avail) { y = safeTop + (avail - blockH) / 2; }

        // -- Title ------------------------------------------------------
        dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_SMALL, "NAP COMPLETE",
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fSmall + gapS;

        // -- Duration ---------------------------------------------------
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var durationStr = (napSec > 0)
            ? (napSec / 60).toString() + ":" + formatTwoDigits(napSec % 60)
            : "--:--";
        dc.drawText(cx, y, Graphics.FONT_NUMBER_MILD, durationStr,
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fNumMil + gapS;

        // -- Sub-line: completion % and quality -------------------------
        dc.setColor(accentColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_XTINY,
            pct.toString() + "%  \u2022  " + qualityLabel,
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fXtiny + gap;

        // -- Divider ----------------------------------------------------
        var divW = (w * 22) / 100;
        dc.setColor(0x444444, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - divW, y, cx + divW, y);
        y += 1 + gap;

        // -- HR: two stacked lines -------------------------------------
        var avgHR = _detector.getAvgSleepHR();
        var minHR = _detector.getMinSleepHR();
        var avgStr = (avgHR > 0) ? avgHR.toString() + " BPM" : "--";
        var minStr = (minHR > 0) ? minHR.toString() + " BPM" : "--";

        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_XTINY,
            "Avg HR  " + avgStr,
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fXtiny + gapS;

        dc.setColor(0x4488FF, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_XTINY,
            "Min HR  " + minStr,
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fXtiny + gap;

        // -- Time range (optional, FONT_XTINY to stay narrow at bottom) -
        // sleepStart and napEnd are already fetched above for the pct calculation.
        if (showTimeRange) {
            if (sleepStart != null && napEnd != null) {
                var s = Gregorian.info(sleepStart as Time.Moment, Time.FORMAT_SHORT);
                var e = Gregorian.info(napEnd     as Time.Moment, Time.FORMAT_SHORT);
                dc.setColor(0x666666, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, y, Graphics.FONT_XTINY,
                    formatTime(s.hour, s.min) + "  -  " + formatTime(e.hour, e.min),
                    Graphics.TEXT_JUSTIFY_CENTER);
            }
        }

        // -- Footer (pinned) --------------------------------------------
        dc.setColor(0x555555, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, footerY, Graphics.FONT_XTINY, "BACK to exit",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // -- Screen 5: Timeout ---------------------------------------------

    private function drawTimeout(dc as Graphics.Dc) as Void {
        var w  = dc.getWidth();
        var h  = dc.getHeight();
        var cx = w / 2;

        var fSmall = dc.getFontHeight(Graphics.FONT_SMALL);
        var fTiny  = dc.getFontHeight(Graphics.FONT_TINY);
        var gap    = (h / 40).toNumber(); if (gap < 4) { gap = 4; }

        // Two lines centred vertically
        var blockH = fSmall + gap + fTiny;
        var y = (h - blockH) / 2;

        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_SMALL, "No sleep detected.",
            Graphics.TEXT_JUSTIFY_CENTER);
        y += fSmall + gap;

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, y, Graphics.FONT_TINY, "Press BACK to exit.",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // -- Helpers -------------------------------------------------------

    private function formatCountdown(totalSeconds as Number) as String {
        if (totalSeconds < 0) { totalSeconds = 0; }
        return (totalSeconds / 60).toString() + ":" + formatTwoDigits(totalSeconds % 60);
    }

    private function formatTwoDigits(n as Number) as String {
        return (n < 10) ? "0" + n.toString() : n.toString();
    }

    private function formatTime(hour as Number, min as Number) as String {
        return formatTwoDigits(hour) + ":" + formatTwoDigits(min);
    }

    // Debug builds: show "dev HH:MM" (app start time) on start screen.
    // Release builds: return empty string, nothing is displayed.
    // Increment this number each time you build for testing on the watch.
    // It confirms you are running the latest build, not a cached version.
    private const DEBUG_BUILD = "12:23";

    (:debug)
    private function buildDebugLabel() as String {
        return "dev #" + DEBUG_BUILD;
    }

    (:release)
    private function buildDebugLabel() as String {
        return "";
    }
}
