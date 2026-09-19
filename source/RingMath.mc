import Toybox.Lang;

//! Angle math for the summary progress ring, kept separate so it can be
//! unit-tested without a Dc.
//!
//! Dc.drawArc uses 0 deg = 3 o'clock, 90 deg = 12 o'clock, counter-clockwise
//! positive. The ring starts at 12 o'clock and fills clockwise, so the end
//! angle is 90 - pct * 3.6, normalised into [0, 360). A full ring (100 %)
//! must NOT be drawn with drawArc: start == end (mod 360) is undefined and
//! renders nothing on real devices; the view draws a circle instead.
module RingMath {

    //! Clockwise end angle in degrees for a ring filled pct percent
    //! (pct in 1..99). Always in [0, 360).
    function endAngle(pct as Number) as Number {
        var a = 90 - (pct * 360 / 100);
        while (a < 0) { a += 360; }
        while (a >= 360) { a -= 360; }
        return a;
    }

    //! True when pct calls for a full circle rather than an arc.
    function isFullRing(pct as Number) as Boolean {
        return pct >= 100;
    }

    //! Clamp a percentage into 0..100.
    function clampPct(pct as Number) as Number {
        if (pct < 0) { return 0; }
        if (pct > 100) { return 100; }
        return pct;
    }
}
