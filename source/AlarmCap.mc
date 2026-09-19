import Toybox.Lang;

//! The alarm cap: the latest moment a nap may ring, shown as "Alarm by
//! HH:MM" on the start screen (as a preview of the nap about to start) and
//! on the nap screens until sleep is detected.
//!
//! One formula for both, so the time promised before START is exactly the
//! time the nap keeps: `SleepDetector.beginSession()` fixes the running
//! nap's deadline with it and `SleepDetector.previewDeadlineSec()` answers
//! the start screen with it.
//!
//! cap = the start rounded UP to the next whole minute
//!       + the fall-asleep allowance + the nap duration.
//!
//! Rounding the start up (never down) keeps the whole allowance, and
//! rounding it to a minute makes the cap depend only on the minute the nap
//! was started in: every second of the minute the preview was drawn in
//! gives the same cap, so the preview and the nap screen can never differ
//! by a minute. A start at 14:03:00 and one at 14:03:59 both count from
//! 14:04. The cap itself falls on a whole minute, so the alarm rings at the
//! latest exactly at the HH:MM on screen, never seconds after it.
module AlarmCap {

    //! The cap in seconds since the epoch for a nap of napMin minutes
    //! started at startSec with the given fall-asleep allowance (both in
    //! whole minutes). Stay Awake sessions have no cap and never ask.
    function deadlineSec(startSec as Number, allowanceMin as Number, napMin as Number) as Number {
        return (startSec / 60 + 1 + allowanceMin + napMin) * 60;
    }
}
