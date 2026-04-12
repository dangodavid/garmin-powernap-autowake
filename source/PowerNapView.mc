using Toybox.WatchUi;
using Toybox.Graphics;
using Toybox.Time;
using Toybox.Time.Gregorian;
using Toybox.Lang;

//! Main view for Power Nap Auto-Wake. Draws one of five screens depending on
//! the current SleepDetector state: Calibrating/Monitoring, Sleep Detected
//! (countdown), Alarm, Summary, or Timeout.
class PowerNapView extends WatchUi.View {

    private var _detector as SleepDetector;
    private var _alarm as AlarmManager;
    private var _alarmTriggered as Boolean = false;
    private var _sleepConfirmed as Boolean = false;

    function initialize(detector as SleepDetector, alarm as AlarmManager) {
        View.initialize();
        _detector = detector;
        _alarm = alarm;
    }

    //! Called when the view becomes visible; start the detector.
    function onShow() as Void {
        _detector.start();
    }

    //! Called when the view is hidden; stop sensors.
    function onHide() as Void {
        _detector.stop();
        _alarm.stop();
    }

    //! Main draw dispatch — delegates to per-state draw methods.
    function onUpdate(dc as Graphics.Dc) as Void {
        // Clear the screen
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();

        var state = _detector.getState();

        // When the detector first enters ALARM state, start the alarm manager
        if (state == SleepDetector.STATE_ALARM && !_alarmTriggered) {
            _alarmTriggered = true;
            _alarm.startAlarm();
        }

        // Give a gentle vibration when sleep is first detected (once)
        if (state == SleepDetector.STATE_SLEEPING && !_sleepConfirmed) {
            _sleepConfirmed = true;
            _alarm.confirmVibration();
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

    //! Access the detector (used by the delegate).
    function getDetector() as SleepDetector {
        return _detector;
    }

    //! Access the alarm manager (used by the delegate).
    function getAlarm() as AlarmManager {
        return _alarm;
    }

    //! Reset state flags (used after dismiss).
    function resetAlarmFlag() as Void {
        _alarmTriggered = false;
        _sleepConfirmed = false;
    }

    // ── Screen 1: Calibrating / Monitoring ─────────────────────────────

    private function drawMonitoring(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var yPos = h * 12 / 100; // ~12% from top

        // Title
        dc.setColor(Graphics.COLOR_BLUE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_MEDIUM, "POWER NAP", Graphics.TEXT_JUSTIFY_CENTER);

        // Divider line
        yPos += dc.getFontHeight(Graphics.FONT_MEDIUM) + 4;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - 50, yPos, cx + 50, yPos);
        yPos += 10;

        // Heart rate
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        var hrText = "HR: " + _detector.getCurrentHR() + " BPM";
        dc.drawText(cx, yPos, Graphics.FONT_SMALL, hrText, Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 6;

        // Status
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var statusText;
        if (_detector.getState() == SleepDetector.STATE_CALIBRATING) {
            statusText = "Calibrating...";
        } else {
            statusText = "Monitoring";
        }
        dc.drawText(cx, yPos, Graphics.FONT_SMALL, "Status: " + statusText, Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 8;

        // Nap duration setting
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_TINY, "Nap duration: " + _detector.getNapDurationMin() + " min", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_TINY) + 10;

        // Immobility progress (only in monitoring state)
        if (_detector.getState() == SleepDetector.STATE_MONITORING) {
            var immSec = _detector.getImmobileDuration();
            var reqSec = _detector.getImmobilityRequired();
            if (immSec > 0) {
                dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
                var pct = (immSec * 100) / reqSec;
                if (pct > 100) { pct = 100; }
                dc.drawText(cx, yPos, Graphics.FONT_TINY,
                    "Stillness: " + pct + "%",
                    Graphics.TEXT_JUSTIFY_CENTER);
                yPos += dc.getFontHeight(Graphics.FONT_TINY) + 4;
            } else {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(cx, yPos, Graphics.FONT_TINY,
                    "Waiting for sleep...",
                    Graphics.TEXT_JUSTIFY_CENTER);
                yPos += dc.getFontHeight(Graphics.FONT_TINY) + 4;
            }
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(cx, yPos, Graphics.FONT_TINY,
                "Building baseline...",
                Graphics.TEXT_JUSTIFY_CENTER);
            yPos += dc.getFontHeight(Graphics.FONT_TINY) + 4;
        }

        // Bottom hint
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - dc.getFontHeight(Graphics.FONT_XTINY) - 10,
            Graphics.FONT_XTINY, "BACK to cancel",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // ── Screen 2: Sleep Detected / Countdown ───────────────────────────

    private function drawSleeping(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var yPos = h * 10 / 100;

        // Title
        dc.setColor(Graphics.COLOR_PURPLE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_MEDIUM, "NAP DETECTED", Graphics.TEXT_JUSTIFY_CENTER);

        yPos += dc.getFontHeight(Graphics.FONT_MEDIUM) + 4;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - 50, yPos, cx + 50, yPos);
        yPos += 10;

        // Fell asleep at time
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var sleepStart = _detector.getSleepStartTime();
        if (sleepStart != null) {
            var info = Gregorian.info(sleepStart as Time.Moment, Time.FORMAT_SHORT);
            var timeStr = formatTime(info.hour, info.min);
            dc.drawText(cx, yPos, Graphics.FONT_SMALL,
                "Fell asleep at " + timeStr,
                Graphics.TEXT_JUSTIFY_CENTER);
        }
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 12;

        // "Wake in:" label
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_SMALL, "Wake in:", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 4;

        // Large countdown
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        var remaining = _detector.getRemainingSeconds();
        var countdownStr = formatCountdown(remaining);
        dc.drawText(cx, yPos, Graphics.FONT_NUMBER_MEDIUM, countdownStr, Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_NUMBER_MEDIUM) + 8;

        // Current HR
        dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_TINY,
            "HR: " + _detector.getCurrentHR() + " BPM",
            Graphics.TEXT_JUSTIFY_CENTER);

        // Bottom hint
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - dc.getFontHeight(Graphics.FONT_XTINY) - 10,
            Graphics.FONT_XTINY, "BACK to cancel",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // ── Screen 3: Alarm / Wake Up ──────────────────────────────────────

    private function drawAlarm(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var yPos = h * 15 / 100;

        // Flashing background effect — alternate color every second
        var now = Time.now().value();
        if (now % 2 == 0) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_RED);
            dc.fillRectangle(0, 0, w, h);
        }

        // Title
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_LARGE, "WAKE UP!", Graphics.TEXT_JUSTIFY_CENTER);

        yPos += dc.getFontHeight(Graphics.FONT_LARGE) + 8;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - 50, yPos, cx + 50, yPos);
        yPos += 16;

        // Nap duration
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var napSec = _detector.getActualNapDurationSec();
        var napMin = napSec / 60;
        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            "Nap: " + napMin + " min",
            Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 4;

        // Average HR
        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            "Avg HR: " + _detector.getAvgSleepHR() + " BPM",
            Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 16;

        // Vibrating indicator
        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_SMALL, "VIBRATING", Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 16;

        // Dismiss instruction
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - dc.getFontHeight(Graphics.FONT_XTINY) - 10,
            Graphics.FONT_XTINY, "Press any key to dismiss",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // ── Screen 4: Summary ──────────────────────────────────────────────

    private function drawSummary(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;
        var yPos = h * 10 / 100;

        // Title
        dc.setColor(Graphics.COLOR_GREEN, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, yPos, Graphics.FONT_MEDIUM, "NAP COMPLETE", Graphics.TEXT_JUSTIFY_CENTER);

        yPos += dc.getFontHeight(Graphics.FONT_MEDIUM) + 4;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(cx - 50, yPos, cx + 50, yPos);
        yPos += 12;

        // Duration
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        var napSec = _detector.getActualNapDurationSec();
        var durMin = napSec / 60;
        var durSec = napSec % 60;
        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            "Duration: " + durMin + ":" + formatTwoDigits(durSec),
            Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 6;

        // Average HR
        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            "Avg HR: " + _detector.getAvgSleepHR() + " BPM",
            Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 4;

        // Min HR
        dc.drawText(cx, yPos, Graphics.FONT_SMALL,
            "Min HR: " + _detector.getMinSleepHR() + " BPM",
            Graphics.TEXT_JUSTIFY_CENTER);
        yPos += dc.getFontHeight(Graphics.FONT_SMALL) + 6;

        // Time range
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        var sleepStart = _detector.getSleepStartTime();
        var napEnd = _detector.getNapEndTime();
        if (sleepStart != null && napEnd != null) {
            var startInfo = Gregorian.info(sleepStart as Time.Moment, Time.FORMAT_SHORT);
            var endInfo = Gregorian.info(napEnd as Time.Moment, Time.FORMAT_SHORT);
            var timeRange = formatTime(startInfo.hour, startInfo.min)
                + " - " + formatTime(endInfo.hour, endInfo.min);
            dc.drawText(cx, yPos, Graphics.FONT_SMALL,
                "Time: " + timeRange,
                Graphics.TEXT_JUSTIFY_CENTER);
        }

        // Bottom hint
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h - dc.getFontHeight(Graphics.FONT_XTINY) - 10,
            Graphics.FONT_XTINY, "Press BACK to exit",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // ── Screen 5: Timeout ──────────────────────────────────────────────

    private function drawTimeout(dc as Graphics.Dc) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var cx = w / 2;

        dc.setColor(Graphics.COLOR_YELLOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h / 2 - dc.getFontHeight(Graphics.FONT_SMALL) - 4,
            Graphics.FONT_SMALL, "No sleep detected.",
            Graphics.TEXT_JUSTIFY_CENTER);

        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(cx, h / 2 + 4,
            Graphics.FONT_TINY, "Press BACK to exit.",
            Graphics.TEXT_JUSTIFY_CENTER);
    }

    // ── Formatting helpers ─────────────────────────────────────────────

    //! Format seconds as "MM:SS".
    private function formatCountdown(totalSeconds as Number) as String {
        if (totalSeconds < 0) { totalSeconds = 0; }
        var mins = totalSeconds / 60;
        var secs = totalSeconds % 60;
        return mins.toString() + ":" + formatTwoDigits(secs);
    }

    //! Zero-pad a number to two digits.
    private function formatTwoDigits(n as Number) as String {
        if (n < 10) {
            return "0" + n.toString();
        }
        return n.toString();
    }

    //! Format hour and minute as "HH:MM".
    private function formatTime(hour as Number, min as Number) as String {
        return formatTwoDigits(hour) + ":" + formatTwoDigits(min);
    }
}
