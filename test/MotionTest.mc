import Toybox.Test;
import Toybox.Lang;
import Toybox.Math;

// -----------------------------------------------------------------------------
// Raw accelerometer tests: MotionMath.batchMotion and the detector path that
// turns one sensor batch into one motion second (the same code the sensor
// callback runs). Batches are 25 samples in millig, like the watch delivers.
//
// The key regression: the old measure |a| - 1 g read a watch whose sensor
// offset is +40 mg as 40 mg of permanent "motion", so on the High (30 mg)
// setting a perfectly still sleeper was never still. The new measure is the
// spread of |a| within the second, which no constant offset can change.
// -----------------------------------------------------------------------------

//! n samples of a constant vector.
(:debug)
function motionHelperConst(n as Number, v as Number) as Array<Number> {
    var a = [] as Array<Number>;
    for (var i = 0; i < n; i++) {
        a.add(v);
    }
    return a;
}

//! z-axis samples alternating base+amp / base-amp (x = y = 0).
(:debug)
function motionHelperAlternating(n as Number, base as Number, amp as Number) as Array<Number> {
    var a = [] as Array<Number>;
    for (var i = 0; i < n; i++) {
        a.add((i % 2 == 0) ? base + amp : base - amp);
    }
    return a;
}

//! n samples of v with a missing sample (null) at index nullAt.
(:debug)
function motionHelperWithNull(n as Number, v as Number, nullAt as Number) as Array<Number> {
    var a = new [n];
    for (var i = 0; i < n; i++) {
        if (i != nullAt) {
            a[i] = v;
        }
    }
    return a as Array<Number>;
}

(:debug)
function motionHelperNear(v as Float?, expected as Float, tol as Float) as Boolean {
    return v != null && ((v as Float) - expected).abs() <= tol;
}

//! A resting watch measures 0, whatever the sensor offset (1000, 1040 and
//! 960 mg of gravity, also split across axes).
(:test)
function testMotion_restingIsZeroWithAnyOffset(logger as Test.Logger) as Boolean {
    var zeros = motionHelperConst(25, 0);
    var offsets = [1000, 1040, 960] as Array<Number>;
    for (var i = 0; i < offsets.size(); i++) {
        var m = MotionMath.batchMotion(zeros, zeros, motionHelperConst(25, offsets[i]));
        if (!motionHelperNear(m, 0.0f, 0.01f)) {
            logger.debug("offset " + offsets[i] + ": " + m);
            return false;
        }
    }
    // 1040 mg split over two axes (tilted wrist): still 0.
    var m = MotionMath.batchMotion(zeros, motionHelperConst(25, 600), motionHelperConst(25, 849));
    if (!motionHelperNear(m, 0.0f, 0.01f)) {
        logger.debug("tilted: " + m);
        return false;
    }
    return true;
}

//! The same sensor noise gives the same value at 1000 and at 1040 mg, and it
//! stays below the High (30 mg) threshold. The old measure read the offset
//! as motion: at 1040 mg it would have been ~40 mg, above High.
(:test)
function testMotion_offsetDoesNotChangeNoise(logger as Test.Logger) as Boolean {
    var zeros = motionHelperConst(25, 0);
    var at1000 = MotionMath.batchMotion(zeros, zeros, motionHelperAlternating(25, 1000, 8));
    var at1040 = MotionMath.batchMotion(zeros, zeros, motionHelperAlternating(25, 1040, 8));
    if (at1000 == null || at1040 == null) {
        logger.debug("no value");
        return false;
    }
    if (((at1000 as Float) - (at1040 as Float)).abs() > 0.01f) {
        logger.debug("noise depends on the offset: " + at1000 + " vs " + at1040);
        return false;
    }
    // 25 samples +-8 around the batch mean -> about 8 mg.
    if (!motionHelperNear(at1040, 8.0f, 0.5f) || (at1040 as Float) >= 30.0f) {
        logger.debug("noise measure " + at1040);
        return false;
    }
    return true;
}

//! Real movement is large: |a| swinging 700..1300 mg -> ~300 mg.
(:test)
function testMotion_movementIsLarge(logger as Test.Logger) as Boolean {
    var zeros = motionHelperConst(25, 0);
    var m = MotionMath.batchMotion(zeros, zeros, motionHelperAlternating(25, 1000, 300));
    if (!motionHelperNear(m, 300.0f, 15.0f)) {
        logger.debug("movement measure " + m);
        return false;
    }
    return true;
}

//! Samples with a missing axis are skipped instead of read as 0 (which used
//! to fake a 1000 mg jolt); arrays of different lengths use the shortest.
(:test)
function testMotion_nullAndRaggedSamples(logger as Test.Logger) as Boolean {
    var x = motionHelperWithNull(25, 0, 7);
    var y = motionHelperConst(25, 0);
    var z = motionHelperWithNull(25, 1000, 3);
    var m = MotionMath.batchMotion(x, y, z);
    if (!motionHelperNear(m, 0.0f, 0.01f)) {
        logger.debug("null samples must be skipped, got " + m);
        return false;
    }
    var shortY = motionHelperConst(10, 0);
    var mixed = motionHelperConst(25, 1000);
    mixed[15] = 3000;                        // beyond the shortest array: ignored
    m = MotionMath.batchMotion(motionHelperConst(25, 0), shortY, mixed);
    if (!motionHelperNear(m, 0.0f, 0.01f)) {
        logger.debug("ragged arrays must stop at the shortest, got " + m);
        return false;
    }
    return true;
}

//! No usable data -> null (the second counts as "no data", never as still).
(:test)
function testMotion_tooLittleDataIsNull(logger as Test.Logger) as Boolean {
    var one = [1000] as Array<Number>;
    var zero1 = [0] as Array<Number>;
    var empty = [] as Array<Number>;
    var ok = MotionMath.batchMotion(null, empty, empty) == null
        && MotionMath.batchMotion(empty, empty, empty) == null
        && MotionMath.batchMotion(zero1, zero1, one) == null;
    if (!ok) {
        logger.debug("expected null for missing, empty and single-sample batches");
    }
    return ok;
}

//! The detector path: a raw batch becomes one motion second in the current
//! minute; an unusable batch adds nothing; batches after the nap are ignored.
(:test)
function testMotion_detectorFeedsRawBatches(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    var zeros = motionHelperConst(25, 0);
    d.testFeedAccelBatch(zeros, zeros, motionHelperAlternating(25, 1040, 300));
    if (d.testGetAccMotionCount() != 1 || !motionHelperNear(d.testGetAccMotionSum(), 300.0f, 15.0f)) {
        logger.debug("one batch -> one motion second, got count " + d.testGetAccMotionCount()
            + " sum " + d.testGetAccMotionSum());
        return false;
    }
    d.testFeedAccelBatch(zeros, zeros, [1000] as Array<Number>);
    d.testFeedAccelBatch(null, null, null);
    if (d.testGetAccMotionCount() != 1) {
        logger.debug("unusable batches must add nothing, count " + d.testGetAccMotionCount());
        return false;
    }
    d.cancel();
    var before = d.testGetAccMotionCount();
    d.testFeedAccelBatch(zeros, zeros, motionHelperAlternating(25, 1000, 300));
    if (d.testGetAccMotionCount() != before) {
        logger.debug("batches after the nap must be ignored");
        return false;
    }
    return true;
}

//! End to end on High sensitivity (30 mg) with a +40 mg sensor offset: five
//! minutes of raw resting batches (+-8 mg noise) are five still minutes and
//! the stillness-only onset fires, exactly as on a perfect sensor.
(:test)
function testMotion_highSensitivityOffsetSleeperFallsAsleep(logger as Test.Logger) as Boolean {
    var d = new SleepDetector(null);
    d.testStart();
    d.testSetMotionThreshold(30.0f);
    var zeros = motionHelperConst(25, 0);
    var resting = motionHelperAlternating(25, 1040, 8);
    for (var s = 0; s < 300 && d.getState() != SleepDetector.STATE_SLEEPING; s++) {
        d.testFeedHR(62);
        d.testFeedAccelBatch(zeros, zeros, resting);
        d.testTick();
    }
    if (d.getState() != SleepDetector.STATE_SLEEPING || d.getStillMinutes() != 5) {
        logger.debug("expected sleep after 5 still minutes, state " + d.getState()
            + " still " + d.getStillMinutes() + " motion " + d.testGetMinuteMotionMean());
        return false;
    }
    return true;
}
