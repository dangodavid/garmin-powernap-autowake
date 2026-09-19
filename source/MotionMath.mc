import Toybox.Lang;
import Toybox.Math;

//! Motion measure for one accelerometer batch (one second of 25 Hz samples).
//!
//! The measure is the mean absolute deviation of |a| (millig) around the
//! batch's own mean |a|. It does not depend on the sensor's static offset:
//! a resting watch whose accelerometer reads 1040 mg instead of 1000 mg
//! measures ~0 here, while the previous "|a| - 1 g" measure read a constant
//! 40 mg and could never count as still on the High (30 mg) setting.
//! Movement shows up as |a| changing within the second, exactly as before.
module MotionMath {

    //! Mean |(|a_i| - mean |a|)| over the usable samples, in millig, or null
    //! when fewer than two samples have all three axes (no data this second).
    //! Samples with a missing axis are skipped; arrays of different lengths
    //! are read up to the shortest one.
    function batchMotion(x as Array<Number>?, y as Array<Number>?, z as Array<Number>?) as Float? {
        if (x == null || y == null || z == null) {
            return null;
        }
        var n = x.size();
        if (y.size() < n) { n = y.size(); }
        if (z.size() < n) { n = z.size(); }

        var mags = [] as Array<Float>;
        var sum = 0.0f;
        for (var i = 0; i < n; i++) {
            var xv = x[i] as Number?;
            var yv = y[i] as Number?;
            var zv = z[i] as Number?;
            if (xv == null || yv == null || zv == null) {
                continue;
            }
            var fx = xv.toFloat();
            var fy = yv.toFloat();
            var fz = zv.toFloat();
            var m = Math.sqrt(fx * fx + fy * fy + fz * fz).toFloat();
            mags.add(m);
            sum += m;
        }
        var count = mags.size();
        if (count < 2) {
            return null;
        }
        var mean = sum / count.toFloat();
        var dev = 0.0f;
        for (var i = 0; i < count; i++) {
            dev += (mags[i] - mean).abs();
        }
        return dev / count.toFloat();
    }
}
