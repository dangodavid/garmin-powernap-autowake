import Toybox.Sensor;
import Toybox.Timer;
import Toybox.Time;
import Toybox.Math;
import Toybox.Application;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

//! Core sleep-detection engine.
//!
//! Timing model
//! ------------
//! Everything is wall-clock based (seconds since epoch via nowSec()). One
//! 1-second tick timer drives the alarm-due check, the UI refresh and, every
//! 60 ticks, the per-minute detection logic. Sensor callbacks (HR at 1 Hz,
//! accelerometer in 1-second batches) feed per-minute accumulators; the
//! minute logic only ever looks at aggregates, never at single samples.
//! One accelerometer batch becomes one motion value (MotionMath.batchMotion:
//! the spread of |a| within that second, independent of the sensor offset).
//!
//! Wake-up guarantee
//! -----------------
//! The deadline is the alarm cap of AlarmCap (start rounded up to the next
//! whole minute + fallAsleepAllowance + napDuration), fixed when the nap
//! starts and shown on screen as "Alarm by HH:MM" - the very time the start
//! screen promised a moment earlier. It is a hard upper bound on the alarm
//! time:
//! * Sleep detected  -> alarm at min(onset + napDuration, deadline).
//!                      Falling asleep late shortens the nap instead of
//!                      pushing the alarm past the promised time.
//! * Never detected  -> alarm at the deadline (ALARM_DEADLINE).
//! Both are checked every second against the wall clock, so the alarm is
//! never more than one second late and never depends on detection working.
//!
//! Sleep onset (MONITORING -> SLEEPING)
//! ------------------------------------
//! A minute is "still" when its mean motion is below the motion threshold AND
//! at most STILL_MAX_ACTIVE_SEC seconds of that minute had motion above the
//! threshold (a 2-second roll-over does not break stillness).
//! * still >= 2 min AND HR dropped >= threshold below the calibration baseline
//! * OR still >= 5 min (HR is an accelerator, never a requirement)
//! * Re-entry after a wake episode: still >= 2 min, no HR condition.
//! The first onset is NOT back-dated: the alarm is never earlier than
//! detection + napDuration. A re-entry segment is back-dated by the two still
//! minutes that confirmed it (this only affects the time-asleep statistics).
//!
//! Wake episode (SLEEPING -> MONITORING, countdown keeps running)
//! --------------------------------------------------------------
//! * >= WAKE_ACTIVE_SEC seconds of motion in the minute, or minute mean
//!   motion above WAKE_MOTION_MEAN, or
//! * minute-mean HR >= WAKE_HR_RISE above the sleep-phase mean for two
//!   consecutive minutes. The sleep-phase mean is rebuilt after every
//!   re-entry, so a steady (but higher) HR cannot trigger a wake every few
//!   minutes.
//!
//! Smart wake (effective nap >= 15 min, last min(5 min, 20 % of it))
//! ------------------------------------------------------------------
//! The effective nap is plannedEnd - onset (shorter than napDuration when the
//! deadline cap applied). Inside the window a restless minute (>= 6 active
//! seconds, i.e. more than a still minute tolerates, or mean motion >= 1.5 x
//! threshold) or a >= LIGHT_HR_RISE BPM rise fires the alarm early.
//!
//! Stay Awake mode (nap duration 0)
//! --------------------------------
//! The same onset rules detect dozing off, but the HR drop is measured
//! against a rolling reference (the mean of the per-minute HR 4-13 minutes
//! ago) because a session can last hours and HR drifts. At 3 still minutes
//! a single gentle nudge vibrates ("Stay alert"); at onset the doze alarm
//! (ALARM_DOZE) rings, starting part-way up the ramp (AlarmManager's 60 %
//! step). Dismissing it goes back on guard, so one session can catch
//! several dozes. There is no deadline and no sleep state; the session ends
//! when the user stops it.
//!
//! Settings
//! --------
//! Settings are read when a nap starts and frozen for that nap. A change made
//! from the phone during a nap applies to the next one.
class SleepDetector {

    // ── Application states ──────────────────────────────────────────────
    enum {
        STATE_CALIBRATING = 0,  // First 2 minutes: building HR baseline
        STATE_MONITORING  = 1,  // Watching for sleep onset (or awake after a wake episode)
        STATE_SLEEPING    = 2,  // Sleep detected, countdown running
        STATE_ALARM       = 3,  // Alarm firing
        STATE_SUMMARY     = 4   // Nap finished, showing summary
    }

    // ── Why the alarm fired ─────────────────────────────────────────────
    enum {
        ALARM_NONE         = 0,
        ALARM_NAP_COMPLETE = 1,  // planned end reached: min(sleepStart + napDuration, deadline)
        ALARM_SMART_WAKE   = 2,  // light-sleep signal inside the smart wake window
        ALARM_DEADLINE     = 3,  // sleep never detected: safety-net timer
        ALARM_DOZE         = 4   // Stay Awake mode: the user dozed off
    }

    // ── Tunables ────────────────────────────────────────────────────────
    private const CALIBRATION_SEC          = 120;
    private const ONSET_STILL_MIN_WITH_HR  = 2;     // still minutes needed when HR dropped
    private const ONSET_STILL_MIN_NO_HR    = 5;     // still minutes needed without HR drop
    private const REENTRY_STILL_MIN        = 2;     // still minutes to resume sleep after a wake
    private const REENTRY_BACKDATE_MAX_SEC = 120;   // re-entry segment back-dated by its still minutes
    private const STILL_MAX_ACTIVE_SEC     = 5;     // seconds of motion tolerated in a "still" minute
    private const WAKE_ACTIVE_SEC          = 10;    // seconds of motion in a minute that mean "awake"
    private const WAKE_MOTION_MEAN         = 100.0f;// minute-mean motion (millig) that means "awake"
    private const WAKE_HR_RISE             = 10.0f; // BPM above sleep mean ...
    private const WAKE_HR_MINUTES          = 2;     // ... for this many consecutive minutes
    private const SMART_WAKE_MIN_NAP_MIN   = 15;
    private const SMART_WAKE_MAX_WINDOW_SEC= 300;
    private const SMART_WAKE_FRACTION      = 5;     // window = napDuration / 5 (20 %), capped above
    private const LIGHT_ACTIVE_SEC         = 6;     // = STILL_MAX_ACTIVE_SEC + 1: "not a still minute"
    private const LIGHT_HR_RISE            = 5.0f;
    private const HR_WINDOW_MINUTES        = 3;
    // Stay Awake mode
    private const NUDGE_STILL_MIN          = 3;     // one gentle nudge after this many still minutes
    private const HR_REF_MINUTES           = 10;    // rolling HR reference: minutes before the window
    private const HR_REF_MIN_MINUTES       = 5;     // ... used once at least this many exist
    private const REACTION_ACTIVE_SEC      = 3;     // moving this long after the nudge = awake

    // ── State ───────────────────────────────────────────────────────────
    private var _state as Number = STATE_CALIBRATING;
    private var _alarmReason as Number = ALARM_NONE;
    private var _cancelled as Boolean = false;
    private var _running as Boolean = false;
    private var _wasInactive as Boolean = false;     // app left the foreground during this nap
    private var _stayAwake as Boolean = false;       // Stay Awake mode (frozen per session)
    private var _dozeCount as Number = 0;

    // Live sensor reading
    private var _currentHR as Number = 0;

    // Per-minute accumulators (fed by sensor callbacks, consumed by onMinute)
    private var _accHrSum as Number = 0;
    private var _accHrCount as Number = 0;
    private var _accMotionSum as Float = 0.0f;
    private var _accMotionCount as Number = 0;
    private var _accActiveSec as Number = 0;

    // Last completed minute
    private var _minuteHr as Number = 0;            // whole BPM (display, trace, sleep-phase rise)
    private var _minuteHrExact as Float = 0.0f;     // exact mean (HR drop against the baseline)
    private var _minuteHadMotion as Boolean = false;
    private var _minuteMotionMean as Float = 0.0f;
    private var _minuteActiveSec as Number = 0;
    private var _minuteStill as Boolean = false;
    private var _minutesCompleted as Number = 0;

    // Calibration
    private var _calibHrSum as Number = 0;
    private var _calibHrCount as Number = 0;
    private var _hrBaseline as Float = 0.0f;         // 0 = unknown (HR path disabled)

    // Rolling detection state
    // Exact per-minute HR means: the baseline is an exact mean too, so the
    // HR drop is compared on one scale (whole-BPM means would read ~0.5 BPM
    // more drop than there is).
    private var _hrWindow as Array<Float> = [] as Array<Float>;    // last minutes
    private var _hrHistory as Array<Float> = [] as Array<Float>;   // Stay Awake: last 13 minutes
    private var _stillMinutes as Number = 0;                        // consecutive still minutes
    private var _hrRiseMinutes as Number = 0;                       // consecutive minutes with HR rise
    private var _sleepMinuteHrSum as Number = 0;                    // per-minute HR means during sleep
    private var _sleepMinuteHrCount as Number = 0;

    // Timing (wall clock, seconds since epoch)
    private var _startSec as Number = 0;
    private var _sessionNapSec as Number = 0;        // nap duration frozen at start()
    private var _deadlineSec as Number = 0;
    private var _sleepStartSec as Number? = null;    // first sleep onset (detection time)
    private var _napEndSec as Number = 0;            // min(sleepStart + napDuration, deadline)
    private var _finishSec as Number? = null;        // alarm fired / cancelled
    private var _segmentStartSec as Number? = null;  // current sleep segment start
    private var _actualSleepSec as Number = 0;       // sum of closed sleep segments
    private var _wakeEpisodes as Number = 0;

    // Summary statistics: running sum/count/min over every 1 Hz reading
    // while SLEEPING (exact nap average, constant memory).
    private var _sleepHrSum as Number = 0;
    private var _sleepHrCount as Number = 0;
    private var _sleepHrMin as Number = 0;

    // Tick timer (1 s) and minute boundary
    private var _tickTimer as Timer.Timer? = null;
    private var _secInMinute as Number = 0;
    private var _clockOffsetSec as Number = 0;       // only changed by debug helpers
    private var _frozenBaseSec as Number = 0;        // > 0 only in test sessions
    private var _clockPinned as Boolean = false;     // tests: keep the frozen clock across start()
    private var _fakeRuntime as Boolean = false;     // tests: start() without sensors/timers
    (:debug) private var _lastTrace as String = "";  // debug builds: last trace line (tests)

    // Settings
    private var _napDurationMin as Number = 30;
    private var _hrDropThreshold as Number = 5;
    private var _motionThreshold as Float = 50.0f;   // millig
    private var _fallAsleepAllowanceMin as Number = 15;
    private var _alarm as AlarmManager? = null;

    // ────────────────────────────────────────────────────────────────────
    function initialize(alarm as AlarmManager?) {
        _alarm = alarm;
        loadSettings();
    }

    //! Read user settings from application properties.
    //! Wrapped in try/catch because Properties can throw if storage is
    //! corrupt or the companion app sent an invalid value type.
    function loadSettings() as Void {
        if (_running || _fakeRuntime) {
            // A nap is in progress: its settings are frozen. The new values
            // are read again by the next start() (see PowerNapView.startNap).
            // (Fake-runtime test sessions keep their documented defaults.)
            return;
        }
        try {
            var val;

            val = Application.Properties.getValue("napDuration");
            if (val != null && val instanceof Number) {
                _napDurationMin = clampNumber(val as Number, 5, 120);
            }

            val = Application.Properties.getValue("hrDropThreshold");
            if (val != null && val instanceof Number) {
                _hrDropThreshold = clampNumber(val as Number, 3, 20);
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

            val = Application.Properties.getValue("fallAsleepAllowance");
            if (val != null && val instanceof Number) {
                _fallAsleepAllowanceMin = clampNumber(val as Number, 5, 30);
            }
        } catch (e instanceof Lang.Exception) {
            // Storage corrupt -- keep current/default values.
        }
    }

    // ── Session lifecycle ───────────────────────────────────────────────

    //! Reset all per-session state. Shared by start() and the test entry point.
    private function beginSession() as Void {
        var now = nowSec();
        _state = STATE_CALIBRATING;
        _alarmReason = ALARM_NONE;
        _cancelled = false;
        _running = true;
        _wasInactive = false;
        _stayAwake = (_napDurationMin == 0);
        _dozeCount = 0;

        _currentHR = 0;
        resetAccumulators();
        _minuteHr = 0;
        _minuteHrExact = 0.0f;
        _minuteHadMotion = false;
        _minuteMotionMean = 0.0f;
        _minuteActiveSec = 0;
        _minuteStill = false;
        _minutesCompleted = 0;

        _calibHrSum = 0;
        _calibHrCount = 0;
        _hrBaseline = 0.0f;

        _hrWindow = [] as Array<Float>;
        _hrHistory = [] as Array<Float>;
        _stillMinutes = 0;
        _hrRiseMinutes = 0;
        _sleepMinuteHrSum = 0;
        _sleepMinuteHrCount = 0;

        _startSec = now;
        _sessionNapSec = _napDurationMin * 60;
        // Stay Awake has no deadline: nothing rings unless the user dozes.
        // The cap comes from AlarmCap, the same formula the start screen
        // showed as "Alarm by HH:MM" a moment ago (previewDeadlineSec).
        _deadlineSec = _stayAwake ? 0 : AlarmCap.deadlineSec(now, _fallAsleepAllowanceMin, _napDurationMin);
        _sleepStartSec = null;
        _napEndSec = 0;
        _finishSec = null;
        _segmentStartSec = null;
        _actualSleepSec = 0;
        _wakeEpisodes = 0;

        _sleepHrSum = 0;
        _sleepHrCount = 0;
        _sleepHrMin = 0;
        _secInMinute = 0;
        // Quiet onset rule: the alarm manager may nudge only in Stay Awake
        // sessions; a nap session gets no output before the alarm.
        if (_alarm != null) {
            (_alarm as AlarmManager).setStayAwake(_stayAwake);
        }
        trace("start," + _napDurationMin + "," + _fallAsleepAllowanceMin + ","
            + _hrDropThreshold + "," + _motionThreshold.toNumber());
    }

    //! Start a session of napMin minutes (0 = Stay Awake mode): sensors and
    //! the 1-second tick timer. The other settings come from loadSettings().
    function start(napMin as Number) as Void {
        _napDurationMin = (napMin <= 0) ? 0 : clampNumber(napMin, 5, 120);
        if (_fakeRuntime) {
            if (!_clockPinned) {
                // Test sessions run on a clock frozen at a whole minute (see
                // testStartKeepSettings); testPinClock() picks its own second.
                _frozenBaseSec = Time.now().value() / 60 * 60;
                _clockOffsetSec = 0;
            }
            beginSession();
            return;
        }
        beginSession();

        // Enable heart rate sensor events (1 Hz).
        // Can throw if Battery Saver is active or another activity owns the sensor.
        try {
            Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE]);
            Sensor.enableSensorEvents(method(:onSensor));
        } catch (e instanceof Lang.Exception) {
            // HR unavailable: the stillness-only onset path and the deadline
            // alarm keep the app fully functional without HR.
        }

        // Accelerometer: 25 Hz samples delivered in 1-second batches.
        try {
            Sensor.registerSensorDataListener(method(:onSensorData), {
                :period => 1,
                :accelerometer => {
                    :enabled => true,
                    :sampleRate => 25
                }
            });
        } catch (e instanceof Lang.Exception) {
            // No accelerometer data: stillness can never be established, so
            // the nap ends with the deadline alarm. Still better than silence.
        }

        try {
            _tickTimer = new Timer.Timer();
            _tickTimer.start(method(:onTick), 1000, true);
        } catch (e instanceof Lang.Exception) {
            _tickTimer = null;
        }
    }

    //! Stop all sensors and timers. Safe to call more than once.
    function stop() as Void {
        _running = false;
        if (_tickTimer != null) {
            _tickTimer.stop();
            _tickTimer = null;
        }
        if (_alarm != null) {
            (_alarm as AlarmManager).setStayAwake(false);
        }
        if (_fakeRuntime) {
            return;
        }
        try {
            Sensor.enableSensorEvents(null);
        } catch (e instanceof Lang.Exception) {
            // Sensor already released by system
        }
        try {
            // Release the optical HR sensor requested in start(); without
            // this it keeps running at app rate until the app exits.
            Sensor.setEnabledSensors([] as Array<Sensor.SensorType>);
        } catch (e instanceof Lang.Exception) {
            // Already disabled
        }
        try {
            Sensor.unregisterSensorDataListener();
        } catch (e instanceof Lang.Exception) {
            // Ignore if not registered
        }
    }

    // ── App lifecycle (task switcher devices) ───────────────────────────

    //! The app left the foreground (AppBase.onInactive). While inactive the
    //! system denies vibration/tones and limits sensors, so the view warns
    //! the user to stay in the app for the rest of the nap.
    function noteInactive() as Void {
        // A Stay Awake doze alarm is part of a session that goes on after it.
        if (isActiveState() || (_stayAwake && _running && _state == STATE_ALARM)) {
            _wasInactive = true;
        }
    }

    //! Stay Awake: the user just showed they are awake (a button press, or a
    //! clear movement after the nudge). The still run ends at once and a
    //! clean minute starts, so the drowsiness warning clears right away.
    function noteUserAwake() as Void {
        if (!_stayAwake || !_running || !isActiveState()) {
            return;
        }
        _stillMinutes = 0;
        resetAccumulators();
        _secInMinute = 0;
        trace("awake");
    }

    //! The app is back in the foreground (AppBase.onActive): check the alarm
    //! immediately instead of waiting for the next tick.
    function onResume() as Void {
        if (_running && isActiveState()) {
            checkAlarmDue();
        }
        WatchUi.requestUpdate();
    }

    function wasInactiveDuringNap() as Boolean {
        return _wasInactive;
    }

    // ── Sensor callbacks ────────────────────────────────────────────────

    //! Standard sensor info callback (1 Hz).
    function onSensor(sensorInfo as Sensor.Info) as Void {
        if (sensorInfo.heartRate != null) {
            feedHR(sensorInfo.heartRate as Number);
        }
    }

    //! High-frequency sensor data callback (one 1-second accelerometer batch).
    function onSensorData(sensorData as Sensor.SensorData) as Void {
        if (sensorData.accelerometerData == null) {
            return;
        }
        var accel = sensorData.accelerometerData as Sensor.AccelerometerData;
        feedAccelBatch(accel.x, accel.y, accel.z);
    }

    //! One accelerometer batch (millig per axis) -> one motion second.
    private function feedAccelBatch(x as Array<Number>?, y as Array<Number>?, z as Array<Number>?) as Void {
        if (!isActiveState()) {
            return;
        }
        var motion = MotionMath.batchMotion(x, y, z);
        if (motion != null) {
            feedMotionSecond(motion as Float);
        }
    }

    //! One HR reading (1 Hz).
    private function feedHR(hr as Number) as Void {
        if (hr <= 0) {
            return;
        }
        _currentHR = hr;
        if (!isActiveState()) {
            return;
        }
        _accHrSum += hr;
        _accHrCount += 1;
        if (_state == STATE_CALIBRATING) {
            _calibHrSum += hr;
            _calibHrCount += 1;
        } else if (_state == STATE_SLEEPING) {
            _sleepHrSum += hr;
            _sleepHrCount += 1;
            if (_sleepHrMin == 0 || hr < _sleepHrMin) {
                _sleepHrMin = hr;
            }
        }
    }

    //! One second of motion (millig, see MotionMath).
    private function feedMotionSecond(magnitude as Float) as Void {
        if (!isActiveState()) {
            return;
        }
        _accMotionSum += magnitude;
        _accMotionCount += 1;
        if (magnitude > _motionThreshold) {
            _accActiveSec += 1;
            // Stay Awake: moving for a few seconds after the nudge answers it
            // ("Move a bit"); the nudge's own buzz is shorter than this.
            if (_accActiveSec >= REACTION_ACTIVE_SEC && isDozeWarning()) {
                noteUserAwake();
            }
        }
    }

    private function resetAccumulators() as Void {
        _accHrSum = 0;
        _accHrCount = 0;
        _accMotionSum = 0.0f;
        _accMotionCount = 0;
        _accActiveSec = 0;
    }

    // ── Tick (1 s) and minute logic ─────────────────────────────────────

    //! Called every second by the tick timer.
    function onTick() as Void {
        if (!_running) {
            return;
        }
        if (isActiveState()) {
            checkAlarmDue();
        }
        if (isActiveState()) {
            _secInMinute += 1;
            if (_secInMinute >= 60) {
                _secInMinute = 0;
                onMinute();
            }
        } else if (_state == STATE_ALARM && _alarm != null) {
            // Safety net: rings from this tick if the alarm's own repeat
            // timer could not be started.
            (_alarm as AlarmManager).onSecond();
        }
        WatchUi.requestUpdate();
    }

    //! Wall-clock alarm check. Runs every second so the alarm is never more
    //! than one second late, and never depends on the detector. Stay Awake
    //! mode has no timed alarm.
    private function checkAlarmDue() as Void {
        if (_stayAwake) {
            return;
        }
        var now = nowSec();
        if (_sleepStartSec != null) {
            if (now >= _napEndSec) {
                transitionToAlarm(ALARM_NAP_COMPLETE);
            }
        } else if (now >= _deadlineSec) {
            transitionToAlarm(ALARM_DEADLINE);
        }
    }

    //! Consume the per-minute accumulators and run the detection logic.
    private function onMinute() as Void {
        _minuteHr = (_accHrCount > 0) ? (_accHrSum / _accHrCount) : 0;
        _minuteHrExact = (_accHrCount > 0) ? (_accHrSum.toFloat() / _accHrCount.toFloat()) : 0.0f;
        if (_accHrCount == 0) {
            // No reading for a whole minute (sensor lost contact): the screens
            // show "HR --" instead of the last value as if it were live.
            _currentHR = 0;
        }
        _minuteHadMotion = (_accMotionCount > 0);
        if (_accMotionCount > 0) {
            _minuteMotionMean = _accMotionSum / _accMotionCount.toFloat();
            _minuteActiveSec = _accActiveSec;
            _minuteStill = (_minuteMotionMean < _motionThreshold)
                        && (_minuteActiveSec <= STILL_MAX_ACTIVE_SEC);
        } else {
            // No accelerometer data at all this minute: we cannot claim
            // stillness. (The deadline alarm covers a dead accelerometer.)
            _minuteMotionMean = 0.0f;
            _minuteActiveSec = 0;
            _minuteStill = false;
        }
        resetAccumulators();
        _minutesCompleted += 1;

        if (_minuteHr > 0) {
            _hrWindow.add(_minuteHrExact);
            if (_hrWindow.size() > HR_WINDOW_MINUTES) {
                _hrWindow = _hrWindow.slice(-HR_WINDOW_MINUTES, null) as Array<Float>;
            }
            if (_stayAwake) {
                _hrHistory.add(_minuteHrExact);
                if (_hrHistory.size() > HR_REF_MINUTES + HR_WINDOW_MINUTES) {
                    _hrHistory = _hrHistory.slice(-(HR_REF_MINUTES + HR_WINDOW_MINUTES), null) as Array<Float>;
                }
            }
        }
        _stillMinutes = _minuteStill ? (_stillMinutes + 1) : 0;
        // Motion in centi-mg (-1: no accelerometer data), so a replay sees
        // the same still/wake decisions the watch made.
        trace("m," + _state + "," + _minuteHr + ","
            + (_minuteHadMotion ? (_minuteMotionMean * 100.0f + 0.5f).toNumber() : -1)
            + "," + _minuteActiveSec + "," + _stillMinutes + "," + _hrBaseline.toNumber());

        if (_state == STATE_CALIBRATING) {
            if (nowSec() - _startSec >= CALIBRATION_SEC) {
                completeCalibration();
            }
        }
        if (_state == STATE_MONITORING) {
            handleMonitoring();
        } else if (_state == STATE_SLEEPING) {
            handleSleeping();
        }
    }

    private function completeCalibration() as Void {
        // Baseline = mean of every HR reading during calibration. Unknown (0)
        // if the sensor never delivered anything: the HR onset path is then
        // simply disabled and the stillness-only path carries the nap.
        _hrBaseline = (_calibHrCount > 0)
            ? (_calibHrSum.toFloat() / _calibHrCount.toFloat())
            : 0.0f;
        _state = STATE_MONITORING;
    }

    // ── Monitoring: looking for sleep onset ─────────────────────────────

    private function handleMonitoring() as Void {
        if (_stillMinutes >= requiredStillMinutes()) {
            if (_stayAwake) {
                dozeDetected();
            } else {
                enterSleep();
            }
            return;
        }
        if (_stayAwake && _stillMinutes == NUDGE_STILL_MIN) {
            // Drowsy but not asleep yet: one gentle reminder, once per still run.
            trace("nudge");
            try {
                if (_alarm != null) {
                    (_alarm as AlarmManager).nudge();
                }
            } catch (e instanceof Lang.Exception) {
                // The on-screen warning still shows.
            }
        }
    }

    //! Still minutes needed before declaring sleep in the current situation.
    private function requiredStillMinutes() as Number {
        if (_sleepStartSec != null) {
            return REENTRY_STILL_MIN;
        }
        if (hrDropMet()) {
            return ONSET_STILL_MIN_WITH_HR;
        }
        return ONSET_STILL_MIN_NO_HR;
    }

    //! HR (mean of the last minutes) has dropped >= threshold below the
    //! reference: the calibration baseline, or in Stay Awake mode the rolling
    //! reference once enough minutes exist.
    private function hrDropMet() as Boolean {
        var reference = _hrBaseline;
        if (_stayAwake) {
            var rolling = rollingHrReference();
            if (rolling > 0.0f) {
                reference = rolling;
            }
        }
        if (reference <= 0.0f || _hrWindow.size() < 2) {
            return false;
        }
        var drop = reference - arrayMeanFloat(_hrWindow);
        return drop >= _hrDropThreshold.toFloat();
    }

    //! Stay Awake: mean per-minute HR of the minutes before the last three
    //! (up to 10 of them), 0 until at least 5 exist. Long sessions drift
    //! (walking in, then sitting for an hour), so a fixed baseline would read
    //! a calm, awake reader as "HR dropped".
    private function rollingHrReference() as Float {
        var older = _hrHistory.size() - HR_WINDOW_MINUTES;
        if (older < HR_REF_MIN_MINUTES) {
            return 0.0f;
        }
        var sum = 0.0f;
        for (var i = 0; i < older; i++) {
            sum += _hrHistory[i];
        }
        return sum / older.toFloat();
    }

    //! MONITORING -> SLEEPING.
    //! First onset: sleep starts now (no back-dating) and fixes the alarm at
    //! min(now + napDuration, deadline).
    //! Re-entry after a wake episode: opens a new sleep segment back-dated by
    //! the still minutes that confirmed it, and restarts the sleep-phase HR
    //! mean so the new segment is judged against its own HR.
    private function enterSleep() as Void {
        var now = nowSec();
        if (_sleepStartSec == null) {
            _sleepStartSec = now;
            _napEndSec = now + _sessionNapSec;
            if (_napEndSec > _deadlineSec) {
                _napEndSec = _deadlineSec;
            }
            _segmentStartSec = now;
            trace("onset");
        } else {
            var backdate = _stillMinutes * 60;
            if (backdate > REENTRY_BACKDATE_MAX_SEC) {
                backdate = REENTRY_BACKDATE_MAX_SEC;
            }
            _segmentStartSec = now - backdate;
            _sleepMinuteHrSum = 0;
            _sleepMinuteHrCount = 0;
            trace("reentry");
        }
        _hrRiseMinutes = 0;
        _state = STATE_SLEEPING;
    }

    //! Stay Awake: the user dozed off -> doze alarm.
    private function dozeDetected() as Void {
        _dozeCount += 1;
        transitionToAlarm(ALARM_DOZE);
    }

    // ── Sleeping: wake episodes and smart wake ──────────────────────────

    private function handleSleeping() as Void {
        var hrRise = sleepHrRise();
        if (hrRise >= WAKE_HR_RISE) {
            _hrRiseMinutes += 1;
        } else {
            _hrRiseMinutes = 0;
        }
        var motionWake = (_minuteActiveSec >= WAKE_ACTIVE_SEC)
                      || (_minuteMotionMean > WAKE_MOTION_MEAN);
        var hrWake = (_hrRiseMinutes >= WAKE_HR_MINUTES);

        if (isSmartWakeActive()) {
            // Inside the window any minute that is not still (more active
            // seconds than a still minute tolerates, or clearly raised mean
            // motion), a slight HR rise, or of course a full wake, ends the
            // nap at a natural moment.
            var stir = (_minuteActiveSec >= LIGHT_ACTIVE_SEC)
                    || (_minuteMotionMean >= _motionThreshold * 1.5f);
            if (motionWake || hrWake || stir || hrRise >= LIGHT_HR_RISE) {
                transitionToAlarm(ALARM_SMART_WAKE);
                return;
            }
        } else if (motionWake || hrWake) {
            leaveSleep();
            return;
        }

        // Still asleep: fold this minute's HR into the sleep-phase mean,
        // unless it is an elevated minute (a candidate wake). Folding those
        // in would drag the mean up and dampen the second-minute check.
        if (_minuteHr > 0 && hrRise < WAKE_HR_RISE) {
            _sleepMinuteHrSum += _minuteHr;
            _sleepMinuteHrCount += 1;
        }
    }

    //! Minute-mean HR minus the sleep-phase mean so far (0 if unknown).
    private function sleepHrRise() as Float {
        if (_sleepMinuteHrCount < 2 || _minuteHr <= 0) {
            return 0.0f;
        }
        var sleepMean = _sleepMinuteHrSum.toFloat() / _sleepMinuteHrCount.toFloat();
        return _minuteHr.toFloat() - sleepMean;
    }

    //! SLEEPING -> MONITORING after a wake episode. The alarm time is
    //! unchanged; the sleep segment closes at the START of the minute that
    //! showed the wake, so that minute counts as awake.
    private function leaveSleep() as Void {
        closeSleepSegmentAt(nowSec() - 60);
        _wakeEpisodes += 1;
        _stillMinutes = 0;
        _hrRiseMinutes = 0;
        _state = STATE_MONITORING;
        trace("wake");
    }

    private function closeSleepSegment() as Void {
        closeSleepSegmentAt(nowSec());
    }

    //! Close the open sleep segment at endSec (never before its start).
    private function closeSleepSegmentAt(endSec as Number) as Void {
        if (_segmentStartSec != null) {
            var d = endSec - (_segmentStartSec as Number);
            if (d > 0) {
                _actualSleepSec += d;
            }
            _segmentStartSec = null;
        }
    }

    //! Smart wake window length: 20 % of the effective nap (capped at 5 min),
    //! none for naps under 15 min. Once asleep the effective nap is the real
    //! countdown, which the deadline cap may have shortened.
    function getSmartWakeWindowSec() as Number {
        var napSec = (_sessionNapSec > 0) ? _sessionNapSec : (_napDurationMin * 60);
        if (_sleepStartSec != null) {
            napSec = _napEndSec - (_sleepStartSec as Number);
        }
        if (napSec < SMART_WAKE_MIN_NAP_MIN * 60) {
            return 0;
        }
        var w = napSec / SMART_WAKE_FRACTION;
        if (w > SMART_WAKE_MAX_WINDOW_SEC) {
            w = SMART_WAKE_MAX_WINDOW_SEC;
        }
        return w;
    }

    //! True while asleep inside the smart wake window.
    function isSmartWakeActive() as Boolean {
        if (_state != STATE_SLEEPING || _sleepStartSec == null) {
            return false;
        }
        var window = getSmartWakeWindowSec();
        if (window <= 0) {
            return false;
        }
        var remaining = _napEndSec - nowSec();
        return remaining > 0 && remaining <= window;
    }

    // ── Alarm / finish ──────────────────────────────────────────────────

    //! Fire the alarm from the tick timer so it works with the display off.
    private function transitionToAlarm(reason as Number) as Void {
        closeSleepSegment();
        _alarmReason = reason;
        _finishSec = nowSec();
        _state = STATE_ALARM;
        trace("alarm," + reason);
        try {
            if (_alarm != null) {
                // The doze alarm starts part-way up the ramp (the manager
                // knows where); a nap alarm starts from the first, finest step.
                if (reason == ALARM_DOZE) {
                    (_alarm as AlarmManager).startDozeAlarm();
                } else {
                    (_alarm as AlarmManager).startAlarm();
                }
            }
        } catch (e instanceof Lang.Exception) {
            // Alarm start failed -- state is ALARM so the WAKE UP screen
            // still displays on the next onUpdate().
        }
    }

    //! The user stopped the alarm (two presses). A nap moves to its summary;
    //! Stay Awake mode goes back on guard for the next doze.
    function dismissAlarm() as Void {
        if (_stayAwake && _running && _state == STATE_ALARM) {
            resumeGuard();
            return;
        }
        finishNap();
    }

    //! Stay Awake: ALARM -> MONITORING. The minute restarts clean, so the
    //! alarm's own motion is not judged, and stillness counts from zero.
    private function resumeGuard() as Void {
        _state = STATE_MONITORING;
        _alarmReason = ALARM_NONE;
        _finishSec = null;
        _stillMinutes = 0;
        _hrWindow = [] as Array<Float>;
        resetAccumulators();
        _secInMinute = 0;
        trace("resume");
    }

    //! Alarm dismissed: move to SUMMARY and release sensors/timers.
    //! From an active state this is a manual stop, so it routes to cancel().
    function finishNap() as Void {
        if (isActiveState()) {
            cancel();
            return;
        }
        closeSleepSegment();
        if (_finishSec == null || (_stayAwake && _state == STATE_ALARM)) {
            _finishSec = nowSec();
        }
        _state = STATE_SUMMARY;
        stop();
    }

    //! Manually stop the nap from any state.
    function cancel() as Void {
        if (_state == STATE_ALARM || _state == STATE_SUMMARY) {
            finishNap();
            return;
        }
        _cancelled = true;
        closeSleepSegment();
        _finishSec = nowSec();
        _state = STATE_SUMMARY;
        trace("cancel");
        stop();
    }

    // ── Getters for the view layer ─────────────────────────────────────

    function getState() as Number { return _state; }
    function getAlarmReason() as Number { return _alarmReason; }
    function isCancelled() as Boolean { return _cancelled; }
    function getCurrentHR() as Number { return _currentHR; }
    //! Nap length of the running session in minutes (frozen at start so a
    //! settings change from the phone cannot skew a nap in progress).
    function getNapDurationMin() as Number {
        return (_sessionNapSec > 0 || _stayAwake) ? (_sessionNapSec / 60) : _napDurationMin;
    }
    function getFallAsleepAllowanceMin() as Number { return _fallAsleepAllowanceMin; }

    //! The alarm cap a nap of napMin minutes would get if it started right
    //! now, with the settings the next start() will use: what the start
    //! screen shows as "Alarm by HH:MM". Same formula, same clock and same
    //! allowance as beginSession(), so pressing START inside the minute the
    //! preview was drawn in keeps that time.
    function previewDeadlineSec(napMin as Number) as Number {
        return AlarmCap.deadlineSec(nowSec(), _fallAsleepAllowanceMin, napMin);
    }

    //! The wall clock the app runs on, in seconds since the epoch (the
    //! screens read the time of day from here, so tests can freeze it).
    function getNowSec() as Number { return nowSec(); }
    function getWakeEpisodes() as Number { return _wakeEpisodes; }
    function getStillMinutes() as Number { return _stillMinutes; }
    function getAvgSleepHR() as Number {
        return (_sleepHrCount > 0) ? (_sleepHrSum / _sleepHrCount) : 0;
    }
    function getMinSleepHR() as Number { return _sleepHrMin; }
    function hasSleptAtLeastOnce() as Boolean { return _sleepStartSec != null; }

    //! Seconds from pressing START to the first sleep onset, -1 if none.
    function getFallAsleepSec() as Number {
        return (_sleepStartSec == null) ? -1 : (_sleepStartSec as Number) - _startSec;
    }

    //! Stay Awake mode (nap duration 0) for the current session.
    function isStayAwake() as Boolean { return _stayAwake; }

    //! Stay Awake: dozes caught in this session.
    function getDozeCount() as Number { return _dozeCount; }

    //! Stay Awake: the wrist has been still long enough for the nudge, the
    //! doze alarm follows if it stays still.
    function isDozeWarning() as Boolean {
        return _stayAwake && _state == STATE_MONITORING && _stillMinutes >= NUDGE_STILL_MIN;
    }

    //! Seconds from start to the end of the session (or to now while active).
    function getSessionSec() as Number {
        var end = (_finishSec != null) ? (_finishSec as Number) : nowSec();
        var d = end - _startSec;
        return (d < 0) ? 0 : d;
    }

    //! True in CALIBRATING / MONITORING / SLEEPING.
    function isActiveState() as Boolean {
        return _state == STATE_CALIBRATING
            || _state == STATE_MONITORING
            || _state == STATE_SLEEPING;
    }

    //! Seconds until the planned alarm (0 if sleep not yet detected or due).
    function getRemainingSeconds() as Number {
        if (_sleepStartSec == null) {
            return 0;
        }
        var r = _napEndSec - nowSec();
        return (r < 0) ? 0 : r;
    }

    //! Seconds until the deadline alarm (only meaningful before sleep onset).
    function getSecondsUntilDeadline() as Number {
        var r = _deadlineSec - nowSec();
        return (r < 0) ? 0 : r;
    }

    function getStartTime() as Time.Moment {
        return new Time.Moment(_startSec);
    }

    function getDeadlineTime() as Time.Moment {
        return new Time.Moment(_deadlineSec);
    }

    function getSleepStartTime() as Time.Moment? {
        if (_sleepStartSec == null) {
            return null;
        }
        return new Time.Moment(_sleepStartSec as Number);
    }

    //! Planned alarm time (null before sleep onset).
    function getPlannedEndTime() as Time.Moment? {
        if (_sleepStartSec == null) {
            return null;
        }
        return new Time.Moment(_napEndSec);
    }

    //! When the nap actually ended (alarm fired or cancelled); null while active.
    function getNapEndTime() as Time.Moment? {
        if (_finishSec == null) {
            return null;
        }
        return new Time.Moment(_finishSec as Number);
    }

    //! Total seconds actually asleep, including the open segment.
    function getActualNapDurationSec() as Number {
        var total = _actualSleepSec;
        if (_segmentStartSec != null) {
            var d = nowSec() - (_segmentStartSec as Number);
            if (d > 0) {
                total += d;
            }
        }
        return total;
    }

    //! Progress towards sleep onset, 0-100 (still minutes vs required).
    function getOnsetProgressPct() as Number {
        var required = requiredStillMinutes();
        if (required <= 0) {
            return 100;
        }
        var pct = _stillMinutes * 100 / required;
        return (pct > 100) ? 100 : pct;
    }

    //! How much of the configured nap elapsed between onset and the end, 0-100.
    //! 100 when the whole nap fitted before the deadline; lower after a cancel,
    //! a smart wake, or a late onset capped by the deadline.
    function getPlannedCompletionPct() as Number {
        if (_sleepStartSec == null) {
            return 0;
        }
        var endSec = (_finishSec != null) ? (_finishSec as Number) : nowSec();
        var planned = _sessionNapSec;
        if (planned <= 0) {
            return 0;
        }
        var pct = (endSec - (_sleepStartSec as Number)) * 100 / planned;
        return clampNumber(pct, 0, 100);
    }

    //! Share of the time between onset and the end that was spent asleep.
    function getSleepEfficiencyPct() as Number {
        if (_sleepStartSec == null) {
            return 0;
        }
        var endSec = (_finishSec != null) ? (_finishSec as Number) : nowSec();
        var span = endSec - (_sleepStartSec as Number);
        if (span <= 0) {
            return 0;
        }
        return clampNumber(getActualNapDurationSec() * 100 / span, 0, 100);
    }

    // ── Utilities ──────────────────────────────────────────────────────

    //! Wall clock in seconds. Test sessions freeze the base so that only
    //! the fake offset moves time (fully deterministic tests).
    private function nowSec() as Number {
        if (_frozenBaseSec > 0) {
            return _frozenBaseSec + _clockOffsetSec;
        }
        return Time.now().value() + _clockOffsetSec;
    }

    private function clampNumber(v as Number, lo as Number, hi as Number) as Number {
        if (v < lo) { return lo; }
        if (v > hi) { return hi; }
        return v;
    }

    private function arrayMeanFloat(arr as Array<Float>) as Float {
        if (arr.size() == 0) { return 0.0f; }
        var sum = 0.0f;
        for (var i = 0; i < arr.size(); i++) {
            sum += arr[i];
        }
        return sum / arr.size().toFloat();
    }

    //! Debug builds record the session to the watch log, one line per minute
    //! plus events, as "PN,<seconds since start>,<fields>". The watch writes
    //! it only when GARMIN/APPS/LOGS/<prg name>.TXT exists; test/TraceTest.mc
    //! explains how to replay a recorded nap. Never in unit tests (frozen
    //! clock) and never in release builds (no health data is stored).
    (:debug)
    private function trace(line as String) as Void {
        _lastTrace = line;
        if (_frozenBaseSec == 0) {
            System.println("PN," + (nowSec() - _startSec) + "," + line);
        }
    }

    (:release)
    private function trace(line as String) as Void {
    }

    // ── Test helpers (debug builds only) ───────────────────────────────

    //! Begin a deterministic test session: documented default settings
    //! (30 min nap, 15 min allowance, 5 BPM, 50 mg), frozen clock, no
    //! sensors or timers. Independent of the simulator's stored properties.
    //! Tests drive time with testRunSeconds()/testAdvanceClock().
    (:debug)
    function testStart() as Void {
        _napDurationMin = 30;
        _fallAsleepAllowanceMin = 15;
        _hrDropThreshold = 5;
        _motionThreshold = 50.0f;
        testStartKeepSettings();
    }

    //! Like testStart() but in Stay Awake mode (nap duration 0).
    (:debug)
    function testStartStayAwake() as Void {
        testStart();
        _napDurationMin = 0;
        beginSession();
    }

    //! Like testStart() but keeps whatever loadSettings() last read.
    //! The frozen clock starts on a whole minute, so the cap (AlarmCap
    //! rounds the start up to the next minute) lands exactly one minute
    //! after start + allowance + nap and every expectation stays exact.
    (:debug)
    function testStartKeepSettings() as Void {
        if (!_clockPinned) {
            _frozenBaseSec = Time.now().value() / 60 * 60;
            _clockOffsetSec = 0;
        }
        beginSession();
    }

    //! Pin the frozen clock to an exact second and keep it there across
    //! start() / testStart*(): tests of the minute boundary (the start
    //! screen's live preview and the cap of a nap started from it).
    //! testAdvanceClock() moves it as usual.
    (:debug)
    function testPinClock(sec as Number) as Void {
        _frozenBaseSec = sec;
        _clockOffsetSec = 0;
        _clockPinned = true;
    }

    //! Make start() (called by the view) run without sensors or timers, on a
    //! frozen clock, with the documented default settings. Used by tests
    //! that drive the real delegate and view.
    (:debug)
    function testUseFakeRuntime() as Void {
        _fakeRuntime = true;
        _fallAsleepAllowanceMin = 15;
        _hrDropThreshold = 5;
        _motionThreshold = 50.0f;
    }

    (:debug)
    function testGetHrDropThreshold() as Number { return _hrDropThreshold; }

    (:debug)
    function testGetMotionThreshold() as Float { return _motionThreshold; }

    //! Advance the fake clock without ticking.
    (:debug)
    function testAdvanceClock(seconds as Number) as Void {
        _clockOffsetSec += seconds;
    }

    //! Simulate one second: an HR reading, one accelerometer batch with the
    //! given mean magnitude (millig), then the 1-second tick.
    (:debug)
    function testFeedSecond(hr as Number, motion as Float) as Void {
        if (hr > 0) {
            feedHR(hr);
        }
        feedMotionSecond(motion);
        _clockOffsetSec += 1;
        onTick();
    }

    //! Simulate n seconds of constant HR and motion.
    (:debug)
    function testRunSeconds(n as Number, hr as Number, motion as Float) as Void {
        for (var i = 0; i < n; i++) {
            testFeedSecond(hr, motion);
        }
    }

    //! Simulate n minutes of constant HR and motion.
    (:debug)
    function testRunMinutes(n as Number, hr as Number, motion as Float) as Void {
        testRunSeconds(n * 60, hr, motion);
    }

    //! Feed one accelerometer second without ticking (build a mixed minute).
    (:debug)
    function testFeedMotionSecond(motion as Float) as Void {
        feedMotionSecond(motion);
    }

    //! Feed one raw accelerometer batch through the same path as the sensor
    //! callback (MotionMath), without ticking.
    (:debug)
    function testFeedAccelBatch(x as Array<Number>?, y as Array<Number>?, z as Array<Number>?) as Void {
        feedAccelBatch(x, y, z);
    }

    //! Feed one HR reading without ticking.
    (:debug)
    function testFeedHR(hr as Number) as Void {
        feedHR(hr);
    }

    //! Advance the clock one second and run the tick, without sensor input.
    (:debug)
    function testTick() as Void {
        _clockOffsetSec += 1;
        onTick();
    }

    //! Replay one recorded minute (a "PN,<t>,m,..." trace line): HR every
    //! second, and on the minute's last second the motion aggregates exactly
    //! as the watch measured them (motionMean < 0 = no accelerometer data).
    //! Stops early if the alarm fires inside the minute.
    (:debug)
    function testReplayMinute(hr as Number, motionMean as Float, activeSec as Number) as Void {
        for (var s = 0; s < 60 && isActiveState(); s++) {
            if (hr > 0) {
                feedHR(hr);
            }
            if (_secInMinute == 59) {
                if (motionMean >= 0.0f) {
                    _accMotionSum = motionMean * 60.0f;
                    _accMotionCount = 60;
                    _accActiveSec = activeSec;
                } else {
                    _accMotionSum = 0.0f;
                    _accMotionCount = 0;
                    _accActiveSec = 0;
                }
            }
            _clockOffsetSec += 1;
            onTick();
        }
    }

    //! Skip calibration: set the HR baseline and jump to MONITORING.
    (:debug)
    function testSetBaseline(baseline as Float) as Void {
        _hrBaseline = baseline;
        if (_state == STATE_CALIBRATING) {
            _state = STATE_MONITORING;
        }
    }

    //! Force sleep onset now (as if stillness had just been satisfied).
    (:debug)
    function testForceSleep() as Void {
        if (_state == STATE_CALIBRATING) {
            _state = STATE_MONITORING;
        }
        enterSleep();
    }

    (:debug)
    function testSetNapDurationMin(min as Number) as Void {
        _napDurationMin = min;
        _sessionNapSec = min * 60;
        _deadlineSec = AlarmCap.deadlineSec(_startSec, _fallAsleepAllowanceMin, min);
    }

    (:debug)
    function testSetFallAsleepAllowanceMin(min as Number) as Void {
        _fallAsleepAllowanceMin = min;
        _deadlineSec = AlarmCap.deadlineSec(_startSec, min, _sessionNapSec / 60);
    }

    (:debug)
    function testSetHrDropThreshold(bpm as Number) as Void {
        _hrDropThreshold = bpm;
    }

    (:debug)
    function testSetMotionThreshold(millig as Float) as Void {
        _motionThreshold = millig;
    }

    (:debug)
    function getHRBaseline() as Float { return _hrBaseline; }

    //! The HR reference the onset check uses right now (Stay Awake: rolling).
    (:debug)
    function testGetHrReference() as Float {
        if (_stayAwake) {
            var rolling = rollingHrReference();
            if (rolling > 0.0f) {
                return rolling;
            }
        }
        return _hrBaseline;
    }

    (:debug)
    function testGetMinuteMotionMean() as Float { return _minuteMotionMean; }

    //! The last trace line (debug builds), e.g. "m,1,62,812,0,3,70".
    (:debug)
    function testGetLastTrace() as String { return _lastTrace; }

    (:debug)
    function testGetMinuteActiveSec() as Number { return _minuteActiveSec; }

    (:debug)
    function testGetMinutesCompleted() as Number { return _minutesCompleted; }

    //! Motion seconds fed into the current (unfinished) minute.
    (:debug)
    function testGetAccMotionCount() as Number { return _accMotionCount; }

    //! Motion sum of the current (unfinished) minute.
    (:debug)
    function testGetAccMotionSum() as Float { return _accMotionSum; }

    (:debug)
    function testNowSec() as Number { return nowSec(); }

    (:debug)
    function testGetDeadlineSec() as Number { return _deadlineSec; }

    (:debug)
    function testGetNapEndSec() as Number { return _napEndSec; }

    (:debug)
    function testGetStartSec() as Number { return _startSec; }

    (:debug)
    function testGetSleepStartSec() as Number? { return _sleepStartSec; }

    (:debug)
    function testGetSecInMinute() as Number { return _secInMinute; }

    (:debug)
    function testIsRunning() as Boolean { return _running; }
}
