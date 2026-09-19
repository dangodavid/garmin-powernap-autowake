import Toybox.Test;
import Toybox.Lang;

// -----------------------------------------------------------------------------
// Replays of recorded naps, minute by minute.
//
// Recording a real nap
// --------------------
// 1. Build a DEBUG build (no -r) and copy it to the watch as PowerNap.prg.
// 2. Create an empty file GARMIN/APPS/LOGS/PowerNap.TXT on the watch.
// 3. Nap. Every minute the app writes one line
//      PN,<seconds since start>,m,<state>,<hr>,<motion x100>,<active s>,<still min>,<baseline>
//    plus event lines (PN,<t>,start,... / onset / wake / reentry / alarm,<reason>
//    / nudge / resume / cancel). Release builds never write anything.
// 4. Copy PowerNap.TXT back. Each "m" line becomes one row
//      [<hr>, <motion x100>, <active s>]   (motion in centi-mg; -1: no accelerometer data)
//    and the events tell what the watch decided, which the replay must match.
//
// A replay feeds each minute exactly as the watch aggregated it
// (SleepDetector.testReplayMinute), so the detector logic sees the same
// numbers it saw on the wrist, and any later rule change can be checked
// against real naps.
// -----------------------------------------------------------------------------

//! Replay rows [hr, motion x100, active s] into d until they run out or the
//! alarm fires. Returns the number of minutes replayed.
(:debug)
function traceReplay(d as SleepDetector, rows as Array<Array<Number>>) as Number {
    var i = 0;
    while (i < rows.size() && d.isActiveState()) {
        var r = rows[i];
        var motion = (r[1] < 0) ? -1.0f : r[1].toFloat() / 100.0f;
        d.testReplayMinute(r[0], motion, r[2]);
        i += 1;
    }
    return i;
}

//! A 20 min nap as the watch would log it (defaults: 15 min allowance, 5 BPM,
//! 50 mg): settling in, onset at 5 min when HR has dropped 6.5 BPM, a 4 s
//! roll-over that is not a wake, a real wake at 15 min, re-entry after two
//! still minutes, and a stir inside the 4 min smart-wake window at 22 min.
(:test)
function testTrace_typicalNapReplay(logger as Test.Logger) as Boolean {
    var rows = [
        [74, 14500, 30], [71, 6200, 12],                        // 1-2 settling (calibration)
        [68, 1800, 3], [66, 1200, 1], [64, 900, 0],              // 3-5 still, HR falling -> onset
        [62, 800, 0], [61, 700, 0], [60, 600, 0], [59, 700, 0],   // 6-9 asleep
        [58, 600, 0], [58, 700, 0],                             // 10-11
        [60, 4000, 4],                                         // 12 roll-over: still a still minute
        [58, 700, 0], [57, 600, 0],                             // 13-14
        [70, 12000, 18],                                       // 15 wake episode
        [64, 1500, 2], [60, 800, 0],                            // 16-17 re-entry
        [58, 700, 0], [57, 600, 0], [57, 700, 0], [58, 600, 0],   // 18-21 asleep (window from 21)
        [62, 3000, 7],                                         // 22 stir in the window -> smart wake
        [58, 600, 0], [58, 600, 0], [58, 600, 0]                 // never reached
    ] as Array<Array<Number>>;
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetNapDurationMin(20);
    var minutes = traceReplay(d, rows);
    var ok = true;
    var start = d.testGetStartSec();
    var onset = d.testGetSleepStartSec();
    if (onset == null || (onset as Number) - start != 300) {
        logger.debug("onset expected at 300 s, got " + ((onset != null) ? (onset as Number) - start : -1));
        ok = false;
    }
    if (d.getState() != SleepDetector.STATE_ALARM || d.getAlarmReason() != SleepDetector.ALARM_SMART_WAKE
        || minutes != 22 || d.testNowSec() - start != 1320) {
        logger.debug("expected a smart wake at 1320 s (minute 22), state " + d.getState()
            + " reason " + d.getAlarmReason() + " minutes " + minutes);
        ok = false;
    }
    if (d.getWakeEpisodes() != 1) {
        logger.debug("expected one wake episode (the roll-over is not one), got " + d.getWakeEpisodes());
        ok = false;
    }
    // Segments: 300..840 (closed at the start of the wake minute) and
    // 900..1320 (re-entry back-dated by its two still minutes).
    if (d.getActualNapDurationSec() != 960) {
        logger.debug("time asleep expected 960 s, got " + d.getActualNapDurationSec());
        ok = false;
    }
    return ok;
}

//! A Stay Awake evening: walking in at 78, six minutes of calm reading at 70
//! (the rolling reference settles at ~72), then HR sinks while the wrist is
//! still: the doze is caught at 11 min through the HR path (reference 72 vs
//! 66 over the last three minutes), before the nudge would come.
(:test)
function testTrace_stayAwakeDozeReplay(logger as Test.Logger) as Boolean {
    var rows = [
        [78, 15000, 35], [78, 9000, 20],                        // 1-2 walking in (calibration)
        [70, 1900, 7], [70, 2000, 6], [70, 1800, 7],             // 3-8 reading: 6-7 active s, not still
        [70, 2100, 6], [70, 1900, 7], [70, 2000, 6],
        [69, 900, 1], [66, 700, 0], [63, 600, 0],                // 9-11 still, HR sinking -> doze
        [62, 600, 0]                                           // never reached
    ] as Array<Array<Number>>;
    var a = new AlarmManager();
    a.testSetAlarmType(AlarmManager.ALARM_VIBRATION);
    var d = new SleepDetector(a);
    d.testStartStayAwake();
    var minutes = traceReplay(d, rows);
    var ok = d.getState() == SleepDetector.STATE_ALARM && d.getAlarmReason() == SleepDetector.ALARM_DOZE
        && minutes == 11 && d.testNowSec() - d.testGetStartSec() == 660 && a.testGetNudgeCount() == 0;
    if (!ok) {
        logger.debug("expected the doze at 660 s without a nudge, state " + d.getState()
            + " minutes " + minutes + " nudges " + a.testGetNudgeCount() + " ref " + d.testGetHrReference());
    }
    a.stop();
    return ok;
}

//! A logged minute without accelerometer data (motion -1) is never still.
(:test)
function testTrace_missingMotionMinuteIsNotStill(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    traceReplay(d, [[60, 500, 0], [60, 500, 0], [60, -1, 0]] as Array<Array<Number>>);
    var ok = d.getStillMinutes() == 0 && d.testGetMinutesCompleted() == 3;
    if (!ok) {
        logger.debug("still " + d.getStillMinutes() + " minutes " + d.testGetMinutesCompleted());
    }
    return ok;
}

//! The recorder and the replay agree: a minute without accelerometer data is
//! logged with motion -1 (not 0, which would replay as a perfectly still
//! minute), and a replayed "-1" minute is not still.
(:test)
function testTrace_noMotionMinuteLogsMinusOne(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    for (var s = 0; s < 60; s++) {
        d.testFeedHR(60);
        d.testTick();
    }
    var line = d.testGetLastTrace();
    var ok = line.find(",60,-1,0,0,") != null;
    if (!ok) {
        logger.debug("trace of a minute without motion: '" + line + "'");
    }
    // A still minute is logged at centi-mg resolution: 8.0 mg -> 800.
    d.testRunMinutes(1, 60, 8.0f);
    line = d.testGetLastTrace();
    if (line.find(",60,800,0,1,") == null) {
        logger.debug("trace of a still minute: '" + line + "'");
        ok = false;
    }
    return ok;
}
