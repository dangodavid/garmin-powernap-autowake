using Toybox.Sensor;
using Toybox.SensorHistory;
using Toybox.Timer;
using Toybox.Time;
using Toybox.Math;
using Toybox.Application;
using Toybox.Lang;
using Toybox.System;
using Toybox.WatchUi;

//! Core sleep-detection engine. Reads HR, accelerometer, and optionally HRV
//! data, computes a rolling baseline, and determines when the user has fallen
//! asleep based on simultaneous HR drop and sustained immobility.
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
    private var _hrWindow as Array<Number> = [] as Array<Number>;           // Last 30 s of HR
    private var _motionWindow as Array<Float> = [] as Array<Float>;         // Last 60 s of motion
    private var _hrvIntervals as Array<Number> = [] as Array<Number>;       // Recent IBI samples

    // Immobility tracking
    private var _immobilityStart as Time.Moment? = null;
    private var _immobileDurationSec as Number = 0;

    // Sleep/nap timing
    private var _sleepStartTime as Time.Moment? = null;
    private var _napEndTime as Time.Moment? = null;
    private var _remainingSeconds as Number = 0;

    // Summary statistics
    private var _sleepHrSamples as Array<Number> = [] as Array<Number>;
    private var _avgSleepHR as Number = 0;
    private var _minSleepHR as Number = 0;

    // Timers
    private var _pollTimer as Timer.Timer? = null;
    private var _startMoment as Time.Moment? = null;

    // Settings
    private var _napDurationMin as Number = 30;
    private var _hrDropThreshold as Number = 8;
    private var _motionThreshold as Float = 50.0f;   // millig
    private var _wakeMotionThreshold as Float = 200.0f;
    private var _immobilityRequiredSec as Number = 180; // 3 minutes

    // Timeout: stop monitoring after 60 min with no sleep detected
    private const MONITORING_TIMEOUT_SEC = 3600;

    // ────────────────────────────────────────────────────────────────────
    function initialize() {
        loadSettings();
    }

    //! Read user settings from application properties.
    function loadSettings() as Void {
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
            // 0 = low (less sensitive, higher threshold), 1 = medium, 2 = high
            if (sens == 0) {
                _motionThreshold = 80.0f;
            } else if (sens == 2) {
                _motionThreshold = 30.0f;
            } else {
                _motionThreshold = 50.0f;
            }
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
        _hrvIntervals = [] as Array<Number>;
        _sleepHrSamples = [] as Array<Number>;
        _immobilityStart = null;
        _immobileDurationSec = 0;

        // Enable heart rate sensor events
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
        Sensor.enableSensorEvents(method(:onSensor));

        // Register for accelerometer + HRV data
        var options = {
            :period => 1,
            :accelerometer => {
                :enabled => true,
                :sampleRate => 25
            },
            :heartBeatIntervals => {
                :enabled => true
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

        // Main poll loop every 10 seconds
        _pollTimer = new Timer.Timer();
        _pollTimer.start(method(:onPollTick), 10000, true);
    }

    //! Stop all sensors and timers.
    function stop() as Void {
        if (_pollTimer != null) {
            _pollTimer.stop();
            _pollTimer = null;
        }
        Sensor.enableSensorEvents(null);
        try {
            Sensor.unregisterSensorDataListener();
        } catch (e instanceof Lang.Exception) {
            // Ignore if not registered
        }
    }

    // ── Sensor callbacks ────────────────────────────────────────────────

    //! Callback for standard sensor info (HR, SpO2, etc.).
    function onSensor(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heartRate != null) {
            _currentHR = sensorInfo.heartRate as Number;
        }
    }

    //! Callback for high-frequency sensor data (accelerometer, HRV).
    function onSensorData(sensorData as Sensor.SensorData) as Void {
        // Process accelerometer data — compute average magnitude over the batch
        if (sensorData.accelerometerData != null) {
            var accel = sensorData.accelerometerData;
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

        // Process heart-beat intervals for HRV tracking
        if (sensorData.heartRateData != null) {
            var hrData = sensorData.heartRateData;
            if (hrData.heartBeatIntervals != null) {
                var intervals = hrData.heartBeatIntervals;
                for (var i = 0; i < intervals.size(); i++) {
                    if (intervals[i] != null) {
                        _hrvIntervals.add(intervals[i] as Number);
                        // Keep a reasonable window (last ~60 intervals)
                        if (_hrvIntervals.size() > 60) {
                            _hrvIntervals = _hrvIntervals.slice(-60, null) as Array<Number>;
                        }
                    }
                }
            }
        }
    }

    // ── Main poll logic (every 10 s) ────────────────────────────────────

    //! Called every 10 seconds by the poll timer.
    function onPollTick() as Void {
        if (_state == STATE_SUMMARY || _state == STATE_TIMEOUT) {
            return;
        }

        // Push current HR into the rolling window (keep last ~30s = 3 samples at 10s interval)
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

        if (_state == STATE_CALIBRATING) {
            handleCalibration();
        } else if (_state == STATE_MONITORING) {
            handleMonitoring();
        } else if (_state == STATE_SLEEPING) {
            handleSleeping();
        } else if (_state == STATE_ALARM) {
            // Alarm state is handled by AlarmManager; nothing to do here.
        }

        WatchUi.requestUpdate();
    }

    // ── Calibration phase (first 2 minutes) ────────────────────────────

    private function handleCalibration() as Void {
        if (_currentHR > 0) {
            _calibrationSamples.add(_currentHR);
        }

        // After 2 minutes (12 samples at 10s each) switch to monitoring
        if (_calibrationSamples.size() >= 12) {
            _hrBaseline = arrayMeanFloat(_calibrationSamples);
            _state = STATE_MONITORING;
        }
    }

    // ── Monitoring phase: looking for sleep onset ──────────────────────

    private function handleMonitoring() as Void {
        // Check for timeout (60 min without sleep)
        if (_startMoment != null) {
            var elapsed = Time.now().subtract(_startMoment as Time.Moment);
            if (elapsed.value() > MONITORING_TIMEOUT_SEC) {
                _state = STATE_TIMEOUT;
                return;
            }
        }

        // Compute averages from rolling windows
        var hrAvg = arrayMeanFloat(_hrWindow);
        var motionAvg = arrayMeanFloatArr(_motionWindow);

        // Condition 1: HR has dropped enough from baseline
        var hrDrop = _hrBaseline - hrAvg;
        var hrDropMet = (hrDrop >= _hrDropThreshold.toFloat());

        // Condition 2: Motion is below threshold (near immobility)
        var motionMet = (motionAvg < _motionThreshold);

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
        }
    }

    //! Transition from monitoring to the sleeping (countdown) state.
    private function transitionToSleep() as Void {
        _state = STATE_SLEEPING;
        _sleepStartTime = Time.now();
        _remainingSeconds = _napDurationMin * 60;
        _sleepHrSamples = [] as Array<Number>;
    }

    // ── Sleeping phase: countdown active ───────────────────────────────

    private function handleSleeping() as Void {
        // Collect HR samples for summary stats
        if (_currentHR > 0) {
            _sleepHrSamples.add(_currentHR);
        }

        // Decrement countdown (10 seconds per tick)
        _remainingSeconds -= 10;
        if (_remainingSeconds < 0) {
            _remainingSeconds = 0;
        }

        // Check for spontaneous wake-up (sudden movement or HR spike)
        if (detectSpontaneousWake()) {
            finishNap();
            return;
        }

        // Countdown expired → trigger alarm
        if (_remainingSeconds <= 0) {
            _state = STATE_ALARM;
        }
    }

    //! Returns true if the user appears to have woken up on their own.
    private function detectSpontaneousWake() as Boolean {
        // High motion sustained (> 200 millig for at least one full poll cycle)
        if (_motionMagnitude > _wakeMotionThreshold) {
            return true;
        }

        // Sudden HR increase above sleep levels
        if (_sleepHrSamples.size() >= 3) {
            var recentSleepHR = arrayMeanFloat(
                _sleepHrSamples.slice(-3, null) as Array<Number>
            );
            if (_currentHR.toFloat() - recentSleepHR > 15.0f) {
                return true;
            }
        }
        return false;
    }

    // ── Finish / Summary ───────────────────────────────────────────────

    //! Compute summary stats and move to the SUMMARY state.
    function finishNap() as Void {
        _napEndTime = Time.now();
        if (_sleepHrSamples.size() > 0) {
            _avgSleepHR = arrayMeanFloat(_sleepHrSamples).toNumber();
            _minSleepHR = arrayMin(_sleepHrSamples);
        }
        _state = STATE_SUMMARY;
    }

    //! Manually cancel the nap from any active state.
    function cancel() as Void {
        if (_state == STATE_SLEEPING || _state == STATE_ALARM) {
            finishNap();
        } else {
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

    function getHRBaseline() as Float {
        return _hrBaseline;
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

    //! Returns the actual nap duration in seconds (from sleep start to end).
    function getActualNapDurationSec() as Number {
        if (_sleepStartTime == null) {
            return 0;
        }
        var endMoment = (_napEndTime != null) ? (_napEndTime as Time.Moment) : Time.now();
        var dur = endMoment.subtract(_sleepStartTime as Time.Moment);
        return dur.value().toNumber();
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
}
