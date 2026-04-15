import Toybox.Sensor;
import Toybox.Timer;
import Toybox.Time;
import Toybox.Math;
import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

//! Core sleep-detection engine. Reads HR and accelerometer data, computes a
//! rolling baseline, and determines when the user has fallen asleep based on
//! simultaneous HR drop and sustained immobility.
class SleepDetector {

    // ── Application states ──────────────────────────────────────────────
    enum {
        STATE_CALIBRATING = 0,  // First 2 minutes: building HR baseline
        STATE_MONITORING  = 1,  // Actively watching for sleep onset
        STATE_SLEEPING    = 2,  // Sleep detected, countdown running
        STATE_ALARM       = 3,  // Countdown expired, alarm firing
        STATE_SUMMARY     = 4,  // Nap finished, showing summary
        STATE_TIMEOUT     = 5   // 60 min with no sleep detected
    }

    // ── Public observable state ─────────────────────────────────────────
    private var _state as Number = STATE_CALIBRATING;

    // Current sensor readings (updated in callbacks)
    private var _currentHR as Number = 0;
    private var _motionMagnitude as Float = 0.0f;

    // Calibration data
    private var _calibrationSamples as Array<Number> = [] as Array<Number>;
    private var _hrBaseline as Float = 0.0f;

    // Rolling windows for detection
    private var _hrWindow as Array<Number> = [] as Array<Number>;   // Last 3 min of HR
    private var _motionWindow as Array<Float> = [] as Array<Float>; // Last 6 min of motion

    // Immobility tracking
    private var _immobilityStart as Time.Moment? = null;
    private var _immobileDurationSec as Number = 0;

    // Sleep/nap timing
    private var _sleepStartTime as Time.Moment? = null;
    private var _napEndTime as Time.Moment? = null;
    private var _remainingSeconds as Number = 0;

    // Accumulated actual sleep seconds (pauses while user is awake between sleep phases)
    private var _actualSleepSec as Number = 0;

    // Summary statistics
    private var _sleepHrSamples as Array<Number> = [] as Array<Number>;
    private var _avgSleepHR as Number = 0;
    private var _minSleepHR as Number = 0;

    // Timers
    private var _pollTimer as Timer.Timer? = null;
    private var _calibTimer as Timer.Timer? = null;
    private var _calibTickCount as Number = 0;
    private var _startMoment as Time.Moment? = null;

    // Tick interval in seconds — 60 s so the countdown decrements minute by minute.
    private var _tickSec as Number = 60;

    // Settings
    private var _napDurationMin as Number = 30;
    private var _hrDropThreshold as Number = 5;
    private var _motionThreshold as Float = 50.0f;   // millig
    private var _wakeMotionThreshold as Float = 200.0f;
    private var _alarm as AlarmManager? = null;
    private var _immobilityRequiredSec as Number = 120; // 2 minutes

    // Timeout: stop monitoring after 60 min with no sleep detected
    private const MONITORING_TIMEOUT_SEC = 3600;

    // Smart wake window: check for light-sleep signals in the last 5 min
    private const SMART_WAKE_WINDOW_SEC = 300;



    // ────────────────────────────────────────────────────────────────────
    function initialize(alarm as AlarmManager?) {
        _alarm = alarm;
        loadSettings();
    }

    //! Read user settings from application properties.
    //! Wrapped in try/catch because Properties can throw if storage is
    //! corrupt or the companion app sent an invalid value type.
    function loadSettings() as Void {
        try {
            var val;

            val = Application.Properties.getValue("napDuration");
            if (val != null && val instanceof Number) {
                _napDurationMin = val as Number;
                if (_napDurationMin < 5) { _napDurationMin = 5; }
                if (_napDurationMin > 120) { _napDurationMin = 120; }
            }

            val = Application.Properties.getValue("hrDropThreshold");
            if (val != null && val instanceof Number) {
                _hrDropThreshold = val as Number;
                if (_hrDropThreshold < 3) { _hrDropThreshold = 3; }
                if (_hrDropThreshold > 20) { _hrDropThreshold = 20; }
            }

            val = Application.Properties.getValue("motionSensitivity");
            if (val != null && val instanceof Number) {
                var sens = val as Number;
                if (sens == 0) {
                    _motionThreshold = 80.0f;
                } else if (sens == 2) {
                    _motionThreshold = 30.0f;
                } else {
                    _motionThreshold = 50.0f;
                }
            }
        } catch (e instanceof Lang.Exception) {
            // Storage corrupt -- keep current/default values.
        }
    }

    // ── Sensor initialization ───────────────────────────────────────────

    //! Start sensors and begin the 10-second poll timer.
    function start() as Void {
        _state = STATE_CALIBRATING;
        _startMoment = Time.now();
        _calibrationSamples = [] as Array<Number>;
        _hrWindow = [] as Array<Number>;
        _motionWindow = [] as Array<Float>;
        _sleepHrSamples = [] as Array<Number>;
        _actualSleepSec = 0;
        _sleepStartTime = null;
        _napEndTime = null;
        _remainingSeconds = 0;
        _immobilityStart = null;
        _immobileDurationSec = 0;
        _avgSleepHR = 0;
        _minSleepHR = 0;
        _tickSec = 60;
        _calibTickCount = 0;

        // Enable heart rate sensor events.
        // Can throw if Battery Saver is active or another activity owns the sensor.
        try {
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
            Sensor.enableSensorEvents(method(:onSensor));
        } catch (e instanceof Lang.Exception) {
            // HR sensor unavailable -- app will run with _currentHR stuck at 0.
            // Calibration will fall back to 70 BPM baseline after 2 min.
        }

        // Register for accelerometer data
        var options = {
            :period => 1,
            :accelerometer => {
                :enabled => true,
                :sampleRate => 25
            }
        };

        try {
            Sensor.registerSensorDataListener(method(:onSensorData), options);
        } catch (e instanceof Lang.Exception) {
            // Some devices may not support all sensor options; fall back to
            // accelerometer only.
            var fallback = {
                :period => 1,
                :accelerometer => {
                    :enabled => true,
                    :sampleRate => 25
                }
            };
            try {
                Sensor.registerSensorDataListener(method(:onSensorData), fallback);
            } catch (e2 instanceof Lang.Exception) {
                // Unable to register sensor data listener; HR-only mode
            }
        }

        // Calibration timer: 10-second ticks to collect 12 HR samples over 2 minutes.
        // Stopped automatically once calibration completes.
        // Timer creation can throw if the system timer limit is reached.
        try {
            _calibTimer = new Timer.Timer();
            _calibTimer.start(method(:onCalibTick), 10000, true);
        } catch (e instanceof Lang.Exception) {
            _calibTimer = null;
        }

        // Production poll loop: 60-second ticks -> countdown goes minute by minute.
        try {
            _pollTimer = new Timer.Timer();
            _pollTimer.start(method(:onPollTick), 60000, true);
        } catch (e instanceof Lang.Exception) {
            _pollTimer = null;
        }

    }

    //! Stop all sensors and timers.
    function stop() as Void {
        if (_calibTimer != null) {
            _calibTimer.stop();
            _calibTimer = null;
        }
        if (_pollTimer != null) {
            _pollTimer.stop();
            _pollTimer = null;
        }
        try {
            Sensor.enableSensorEvents(null);
        } catch (e instanceof Lang.Exception) {
            // Sensor already released by system
        }
        try {
            Sensor.unregisterSensorDataListener();
        } catch (e instanceof Lang.Exception) {
            // Ignore if not registered
        }
    }

    // ── Sensor callbacks ────────────────────────────────────────────────

    //! Callback for standard sensor info (HR, SpO2, etc.).
    //! In the SLEEPING state every valid reading is added to _sleepHrSamples so
    //! that AVG and MIN HR are computed from the full sensor stream (~1–5 s
    //! resolution) rather than from one sample per 60-second poll tick.
    function onSensor(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heartRate != null) {
            _currentHR = sensorInfo.heartRate as Number;

            if (_state == STATE_SLEEPING && _currentHR > 0) {
                _sleepHrSamples.add(_currentHR);
                // Trim in chunks: keep the last 720 samples but only allocate
                // a new array every 60 additions (every ~5 min at 5 s/sample).
                // This avoids a GC allocation on every sample after the cap,
                // which would cause ~720 allocations during a 120-min nap.
                if (_sleepHrSamples.size() > 780) {
                    _sleepHrSamples = _sleepHrSamples.slice(-720, null) as Array<Number>;
                }
            }
        }
    }

    //! Callback for high-frequency sensor data (accelerometer).
    function onSensorData(sensorData as Sensor.SensorData) as Void {
        // Motion data is only needed during active nap phases.
        // Skip the 25 sqrt() calls per second once the nap has ended.
        if (_state == STATE_ALARM ||
            _state == STATE_SUMMARY ||
            _state == STATE_TIMEOUT) {
            return;
        }

        // Process accelerometer data — compute average magnitude over the batch
        if (sensorData.accelerometerData != null) {
            var accel = sensorData.accelerometerData as Sensor.AccelerometerData;
            var xArr = accel.x;
            var yArr = accel.y;
            var zArr = accel.z;
            if (xArr != null && yArr != null && zArr != null) {
                var count = xArr.size();
                if (count > 0) {
                    var sum = 0.0f;
                    for (var i = 0; i < count; i++) {
                        var xv = (xArr[i] != null) ? (xArr[i] as Number).toFloat() : 0.0f;
                        var yv = (yArr[i] != null) ? (yArr[i] as Number).toFloat() : 0.0f;
                        var zv = (zArr[i] != null) ? (zArr[i] as Number).toFloat() : 0.0f;
                        // Remove gravity (~1000 millig) by using deviation from 1g
                        var mag = Math.sqrt(xv * xv + yv * yv + zv * zv) as Float;
                        var deviation = (mag - 1000.0f).abs();
                        sum += deviation;
                    }
                    _motionMagnitude = sum / count.toFloat();
                }
            }
        }

    }

    // ── Main poll logic ─────────────────────────────────────────────────

    //! Called every 60 s by the poll timer.
    function onPollTick() as Void {
        if (_state == STATE_SUMMARY || _state == STATE_TIMEOUT) {
            return;
        }

        // Push current HR into the rolling window (keep last 3 minutes = 3 samples)
        if (_currentHR > 0) {
            _hrWindow.add(_currentHR);
            if (_hrWindow.size() > 3) {
                _hrWindow = _hrWindow.slice(-3, null) as Array<Number>;
            }
        }

        // Push motion magnitude into the rolling window (keep last ~60s = 6 samples)
        _motionWindow.add(_motionMagnitude);
        if (_motionWindow.size() > 6) {
            _motionWindow = _motionWindow.slice(-6, null) as Array<Float>;
        }

        if (_state == STATE_MONITORING) {
            handleMonitoring();
        } else if (_state == STATE_SLEEPING) {
            handleSleeping();
        } else if (_state == STATE_CALIBRATING) {
            // Pre-track motion immobility during calibration so the clock
            // starts earlier. Only motion is checked (no HR baseline yet).
            // When monitoring begins, handleMonitoring() validates both HR
            // and motion before making any detection decision.
            var motionLow;
            if (_motionWindow.size() >= 2) {
                var recentMotion = arrayMeanFloatArr(
                    _motionWindow.slice(-2, null) as Array<Float>
                );
                motionLow = (recentMotion < _motionThreshold);
            } else {
                motionLow = (_motionMagnitude < _motionThreshold);
            }
            if (motionLow) {
                if (_immobilityStart == null) {
                    _immobilityStart = Time.now();
                }
            } else {
                _immobilityStart = null;
                _immobileDurationSec = 0;
            }
        } else if (_state == STATE_ALARM) {
            // Alarm state is handled by AlarmManager; nothing to do here.
        }

        WatchUi.requestUpdate();
    }

    // ── Calibration phase (first 2 minutes, 10-second ticks) ──────────

    //! Called every 10 s by _calibTimer. Collects 12 HR samples (= 2 minutes),
    //! computes the baseline, then stops itself and hands control to _pollTimer.
    function onCalibTick() as Void {
        if (_currentHR > 0) {
            _calibrationSamples.add(_currentHR);
        }
        _calibTickCount += 1;

        // 12 ticks × 10 s = 120 s = 2 minutes.
        // Transition regardless of whether HR data arrived — if the sensor never
        // delivered a valid reading, fall back to 70 BPM so the app keeps running.
        if (_calibTickCount >= 12) {
            _hrBaseline = (_calibrationSamples.size() > 0)
                ? arrayMeanFloat(_calibrationSamples)
                : 70.0f;
            _state = STATE_MONITORING;
            if (_calibTimer != null) {
                _calibTimer.stop();
                _calibTimer = null;
            }
            WatchUi.requestUpdate();
        }
    }

    // ── Monitoring phase: looking for sleep onset ──────────────────────

    private function handleMonitoring() as Void {
        // Timeout: if the user never fell asleep after 60 min, give up.
        // Do NOT apply once sleep has been detected at least once —
        // a 120-min nap with a spontaneous wake would otherwise be cut
        // short when the elapsed time crosses 60 min during re-monitoring.
        if (_sleepStartTime == null && _startMoment != null) {
            var elapsed = Time.now().subtract(_startMoment as Time.Moment);
            if (elapsed.value() > MONITORING_TIMEOUT_SEC) {
                _state = STATE_TIMEOUT;
                return;
            }
        }

        // Require at least 2 HR samples before making sleep-detection decisions.
        // This avoids false positives in the first poll tick after calibration,
        // when the rolling window may still contain only one reading.
        // However, the countdown must still tick down even without HR data, so
        // we handle that case separately before returning.
        if (_hrWindow.size() < 2) {
            if (_sleepStartTime != null) {
                _remainingSeconds -= _tickSec;
                if (_remainingSeconds < 0) { _remainingSeconds = 0; }
                if (_remainingSeconds <= 0) {
                    transitionToAlarm();
                }
            }
            return;
        }

        // HR: smooth over the rolling window to filter single-sample sensor noise.
        var hrAvg = arrayMeanFloat(_hrWindow);

        // Condition 1: HR has dropped enough from baseline
        var hrDrop = _hrBaseline - hrAvg;
        var hrDropMet = (hrDrop >= _hrDropThreshold.toFloat());

        // Condition 2: Motion is below threshold (near immobility).
        // Use the average of the last 2 motion window entries rather than the
        // instantaneous reading. A single brief movement at poll time would
        // otherwise reset the entire immobility counter, making detection
        // unreliable in practice (any micro-shift during a 60s poll resets
        // 2+ minutes of accumulated stillness).
        var motionMet;
        if (_motionWindow.size() >= 2) {
            var recentMotion = arrayMeanFloatArr(
                _motionWindow.slice(-2, null) as Array<Float>
            );
            motionMet = (recentMotion < _motionThreshold);
        } else {
            motionMet = (_motionMagnitude < _motionThreshold);
        }

        // Track immobility duration
        if (hrDropMet && motionMet) {
            if (_immobilityStart == null) {
                _immobilityStart = Time.now();
            }
            var immDuration = Time.now().subtract(_immobilityStart as Time.Moment);
            _immobileDurationSec = immDuration.value().toNumber();
        } else {
            // Reset immobility counter when conditions break
            _immobilityStart = null;
            _immobileDurationSec = 0;
        }

        // Condition 3: All conditions sustained for required duration
        if (_immobileDurationSec >= _immobilityRequiredSec) {
            transitionToSleep();
            return;
        }

        // ── Countdown continues during a spontaneous wake ───────────────
        // If the user has already fallen asleep at least once (_sleepStartTime
        // is set), the nap timer keeps running in the background even during
        // brief awake periods.  This ensures the alarm fires at the correct
        // wall-clock time regardless of short interruptions.
        if (_sleepStartTime != null) {
            _remainingSeconds -= _tickSec;
            if (_remainingSeconds < 0) { _remainingSeconds = 0; }
            if (_remainingSeconds <= 0) {
                transitionToAlarm();
            }
        }
    }

    //! Transition from monitoring to the sleeping (countdown) state.
    //! On the first call (initial sleep detection) the start time and countdown
    //! are initialised.  On re-entry after a spontaneous wake they are preserved
    //! so the countdown resumes from where it paused.
    private function transitionToSleep() as Void {
        _state = STATE_SLEEPING;
        if (_sleepStartTime == null) {
            // First sleep detection: initialise everything
            _sleepStartTime = Time.now();
            _remainingSeconds = _napDurationMin * 60;
            _sleepHrSamples = [] as Array<Number>;
        }
        // Re-entry after a wake: _sleepStartTime, _remainingSeconds, and
        // _sleepHrSamples are preserved — the countdown resumes from the
        // paused position and HR samples continue accumulating.
    }

    //! Transition to alarm state and start the alarm immediately from the
    //! timer callback. This ensures the alarm fires even when the display
    //! is off (onUpdate is not called with display off on AMOLED devices).
    private function transitionToAlarm() as Void {
        computeSleepStats();
        _state = STATE_ALARM;
        try {
            if (_alarm != null) {
                (_alarm as AlarmManager).startAlarm();
            }
        } catch (e instanceof Lang.Exception) {
            // Alarm start failed -- state is already ALARM so the WAKE UP
            // screen will still display on the next onUpdate().
        }
    }

    // ── Sleeping phase: countdown active ───────────────────────────────

    private function handleSleeping() as Void {
        // HR samples are now collected in onSensor() at full sensor resolution
        // (~1–5 s), not here at the coarse 60-second poll tick.

        // Check for spontaneous wake-up before counting this tick as sleep time.
        // On wake: go back to monitoring so the app keeps running.  The countdown
        // continues running in handleMonitoring() so the alarm fires at the
        // correct wall-clock time.  _actualSleepSec is NOT incremented during
        // the awake period, but resumes accumulating as soon as the user falls
        // back to sleep (next call to handleSleeping() with no wake detected).
        if (detectSpontaneousWake()) {
            _state = STATE_MONITORING;
            _immobilityStart = null;
            _immobileDurationSec = 0;
            return;
        }

        // Smart wake window: in the last 5 minutes, fire the alarm early if
        // light-sleep signals appear (gentle motion or slight HR rise).
        // Only active for naps >= 30 min. For shorter naps the window covers
        // too large a fraction of the total sleep (e.g. 50% of a 10-min nap)
        // and could wake the user far earlier than intended.
        if (_napDurationMin >= 30 &&
            _remainingSeconds <= SMART_WAKE_WINDOW_SEC &&
            _remainingSeconds > 0) {
            if (detectLightSleep()) {
                _actualSleepSec += _tickSec; // this tick counts as sleep
                transitionToAlarm();
                return;
            }
        }

        // User is still asleep — accumulate actual sleep time and tick countdown.
        _actualSleepSec += _tickSec;
        _remainingSeconds -= _tickSec;
        if (_remainingSeconds < 0) { _remainingSeconds = 0; }

        if (_remainingSeconds <= 0) {
            transitionToAlarm();
        }
    }

    //! Returns true if the user appears to have woken up on their own.
    private function detectSpontaneousWake() as Boolean {
        // ── Signal 1: Motion ────────────────────────────────────────────
        // Require motion sustained across at least 2 consecutive poll ticks so
        // that a single brief roll-over doesn't end the nap.
        // In production (60 s ticks) that is 2 minutes; in debug (1 s ticks)
        // it is 2 seconds — proportional to the tick rate either way.
        if (_motionWindow.size() >= 2) {
            var recentMotion = arrayMeanFloatArr(
                _motionWindow.slice(-2, null) as Array<Float>
            );
            if (recentMotion > _wakeMotionThreshold) {
                return true;
            }
        }

        // ── Signal 2: HR spike ──────────────────────────────────────────
        // Compare the LIVE current HR (updated every 1–5 s by onSensor) against
        // the mean of the last 3 sleep-phase samples.  Using _currentHR here is
        // critical: _hrWindow only gets one sample per 60-second poll tick, so
        // using it would introduce up to a 60-second lag before a waking HR spike
        // is detected — long enough for the user to fall back to sleep unnoticed.
        // Threshold 10 BPM: low enough to catch gentle awakenings (HR barely
        // rises), but high enough to ignore normal sleep-phase fluctuations (~3–5
        // BPM noise).
        if (_sleepHrSamples.size() >= 3 && _currentHR > 0) {
            var recentSleepHR = arrayMeanFloat(
                _sleepHrSamples.slice(-3, null) as Array<Number>
            );
            if (_currentHR.toFloat() - recentSleepHR > 10.0f) {
                return true;
            }
        }
        return false;
    }

    //! Returns true when gentle light-sleep signals appear inside the smart
    //! wake window.  Uses softer thresholds than detectSpontaneousWake():
    //!   Motion: mean of last 2 ticks > 1.5× motion threshold (stirring,
    //!           not yet a full roll-over)
    //!   HR:     current HR > recent sleep average + 5 BPM (vs 10 BPM for
    //!           a confirmed wake)
    private function detectLightSleep() as Boolean {
        if (_motionWindow.size() >= 2) {
            var recentMotion = arrayMeanFloatArr(
                _motionWindow.slice(-2, null) as Array<Float>
            );
            if (recentMotion > _motionThreshold * 1.5f) {
                return true;
            }
        }

        // Baseline excludes _currentHR (which is always _sleepHrSamples[-1]).
        // Comparing current against a mean that includes itself damps the
        // threshold: a 8 BPM spike reads as only ~5.3 BPM difference.
        // Using slice(-4, -1) gives a truly independent 3-sample baseline,
        // so the 5 BPM threshold applies cleanly to the actual HR delta.
        if (_sleepHrSamples.size() >= 4 && _currentHR > 0) {
            var baseline = arrayMeanFloat(
                _sleepHrSamples.slice(-4, -1) as Array<Number>
            );
            if (_currentHR.toFloat() - baseline > 5.0f) {
                return true;
            }
        }

        return false;
    }

    // ── Finish / Summary ───────────────────────────────────────────────

    //! Snapshot end-time and HR stats. Safe to call multiple times —
    //! subsequent calls simply refresh the values with any new samples.
    private function computeSleepStats() as Void {
        _napEndTime = Time.now();
        if (_sleepHrSamples.size() > 0) {
            _avgSleepHR = arrayMeanFloat(_sleepHrSamples).toNumber();
            _minSleepHR = arrayMin(_sleepHrSamples);
        }
    }

    //! Compute summary stats and move to the SUMMARY state.
    function finishNap() as Void {
        computeSleepStats();
        _state = STATE_SUMMARY;
    }

    //! Manually cancel the nap from any active state.
    function cancel() as Void {
        if (_state == STATE_SLEEPING || _state == STATE_ALARM) {
            finishNap();
        } else {
            // Even when cancelled from MONITORING or CALIBRATING, snapshot stats
            // if any sleep has occurred (_sleepStartTime is set).  This ensures
            // _napEndTime is always non-null in the SUMMARY screen when the user
            // did sleep at some point, preventing null-dereference in the view.
            if (_sleepStartTime != null) {
                computeSleepStats();
            }
            _state = STATE_SUMMARY;
        }
    }

    // ── Getters for the view layer ─────────────────────────────────────

    function getState() as Number {
        return _state;
    }

    function getCurrentHR() as Number {
        return _currentHR;
    }

    function getRemainingSeconds() as Number {
        return _remainingSeconds;
    }

    function getSleepStartTime() as Time.Moment? {
        return _sleepStartTime;
    }

    function getNapEndTime() as Time.Moment? {
        return _napEndTime;
    }

    function getAvgSleepHR() as Number {
        return _avgSleepHR;
    }

    function getMinSleepHR() as Number {
        return _minSleepHR;
    }

    function getNapDurationMin() as Number {
        return _napDurationMin;
    }

    function getImmobileDuration() as Number {
        return _immobileDurationSec;
    }

    function getImmobilityRequired() as Number {
        return _immobilityRequiredSec;
    }

    //! Returns the total seconds the user was actually asleep (excludes any
    //! awake periods between sleep phases within the same nap session).
    function getActualNapDurationSec() as Number {
        return _actualSleepSec;
    }

    function getTickSec() as Number {
        return _tickSec;
    }

    // ── Utility: array math ────────────────────────────────────────────

    //! Mean of an Array<Number>, returned as Float.
    private function arrayMeanFloat(arr as Array<Number>) as Float {
        if (arr.size() == 0) { return 0.0f; }
        var sum = 0;
        for (var i = 0; i < arr.size(); i++) {
            sum += arr[i];
        }
        return sum.toFloat() / arr.size().toFloat();
    }

    //! Mean of an Array<Float>.
    private function arrayMeanFloatArr(arr as Array<Float>) as Float {
        if (arr.size() == 0) { return 0.0f; }
        var sum = 0.0f;
        for (var i = 0; i < arr.size(); i++) {
            sum += arr[i];
        }
        return sum / arr.size().toFloat();
    }

    //! Minimum of an Array<Number>.
    private function arrayMin(arr as Array<Number>) as Number {
        if (arr.size() == 0) { return 0; }
        var minVal = arr[0];
        for (var i = 1; i < arr.size(); i++) {
            if (arr[i] < minVal) {
                minVal = arr[i];
            }
        }
        return minVal;
    }

    // ── Test helpers ────────────────────────────────────────────────────

    //! Expose HR baseline for test assertions.
    (:debug)
    function getHRBaseline() as Float {
        return _hrBaseline;
    }

    //! Inject an HR value directly into the current reading and rolling window.
    (:debug)
    function testInjectHR(hr as Number) as Void {
        _currentHR = hr;
        _hrWindow.add(hr);
        if (_hrWindow.size() > 3) {
            _hrWindow = _hrWindow.slice(-3, null) as Array<Number>;
        }
    }

    //! Inject a motion magnitude value into the current reading and rolling window.
    (:debug)
    function testInjectMotion(motion as Float) as Void {
        _motionMagnitude = motion;
        _motionWindow.add(motion);
        if (_motionWindow.size() > 6) {
            _motionWindow = _motionWindow.slice(-6, null) as Array<Float>;
        }
    }

    //! Set the HR baseline and jump directly to MONITORING state.
    (:debug)
    function testSetBaseline(baseline as Float) as Void {
        _hrBaseline = baseline;
        _state = STATE_MONITORING;
    }

    //! Simulate that immobility has been sustained for the given number of seconds.
    //! Sets _immobilityStart far enough in the past so handleMonitoring() sees it.
    (:debug)
    function testSetImmobilityStart(secondsAgo as Number) as Void {
        _immobilityStart = Time.now().subtract(new Time.Duration(secondsAgo)) as Time.Moment;
    }

    //! Directly transition to SLEEPING state for countdown/alarm testing.
    (:debug)
    function testTransitionToSleep() as Void {
        transitionToSleep();
    }

    //! Set _motionMagnitude without touching _motionWindow.
    //! Use this when you want to simulate a sensor reading for the NEXT tick
    //! only, without pre-populating the rolling window.
    (:debug)
    function testSetMotionMagnitude(magnitude as Float) as Void {
        _motionMagnitude = magnitude;
    }

    //! Run one tick manually. Routes to the calibration or poll handler
    //! depending on the current state, mirroring real timer behaviour.
    (:debug)
    function testTick() as Void {
        if (_state == STATE_CALIBRATING) {
            onCalibTick();
        } else {
            onPollTick();
        }
    }

    //! Override _remainingSeconds directly so tests can set an arbitrary countdown
    //! without having to drive the full number of ticks to drain it.
    (:debug)
    function testSetRemainingSeconds(seconds as Number) as Void {
        _remainingSeconds = seconds;
    }

    //! Inject a single HR sample directly into _sleepHrSamples so that the
    //! HR-spike branch of detectSpontaneousWake() can be exercised without
    //! requiring a real onSensor() callback.
    (:debug)
    function testAddSleepHrSample(hr as Number) as Void {
        _sleepHrSamples.add(hr);
    }

    //! Returns true if the immobility clock is currently running (i.e.
    //! _immobilityStart has been set by either pre-tracking or monitoring).
    (:debug)
    function testIsImmobilityTracking() as Boolean {
        return _immobilityStart != null;
    }

    //! Run one poll tick manually, regardless of state. Needed to simulate
    //! the poll timer firing during calibration (testTick only calls onCalibTick
    //! during CALIBRATING, but in production both timers run in parallel).
    (:debug)
    function testPollTick() as Void {
        onPollTick();
    }

    //! Override _napDurationMin so tests can exercise duration-dependent guards
    //! (e.g. Smart Wake Window disabled for naps <= 5 min).
    (:debug)
    function testSetNapDurationMin(min as Number) as Void {
        _napDurationMin = min;
    }

    //! Set _startMoment to a given number of seconds in the past so timeout
    //! logic can be tested without waiting 60 real minutes.
    (:debug)
    function testSetStartMoment(secondsAgo as Number) as Void {
        _startMoment = Time.now().subtract(new Time.Duration(secondsAgo)) as Time.Moment;
    }
}
