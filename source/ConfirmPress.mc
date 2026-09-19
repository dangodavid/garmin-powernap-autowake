import Toybox.Lang;

//! Two-press confirmation for actions that must never happen by accident
//! (stopping a nap, stopping the alarm). The first press arms, a second
//! press in the same context within the window confirms. Pressing in a
//! different context (e.g. the alarm started right after a nap press)
//! re-arms instead of confirming. Time is passed in (any unit, the window in
//! the same unit; the view uses System.getTimer() milliseconds) so the guard
//! can be tested and is not rounded to whole seconds. Only the difference
//! of two times is used, which stays correct when System.getTimer() wraps.
class ConfirmPress {

    enum {
        CONTEXT_NONE  = 0,
        CONTEXT_NAP   = 1,
        CONTEXT_ALARM = 2
    }

    private var _window as Number;
    private var _armedAt as Number = 0;
    private var _armedContext as Number = CONTEXT_NONE;

    function initialize(window as Number) {
        _window = window;
    }

    //! Register a press. Returns true when it confirms the action.
    function press(now as Number, context as Number) as Boolean {
        if (isArmed(now, context)) {
            reset();
            return true;
        }
        _armedAt = now;
        _armedContext = context;
        return false;
    }

    //! True while a first press in this context is waiting for confirmation.
    function isArmed(now as Number, context as Number) as Boolean {
        var elapsed = now - _armedAt;
        return _armedContext == context && elapsed >= 0 && elapsed < _window;
    }

    function reset() as Void {
        _armedAt = 0;
        _armedContext = CONTEXT_NONE;
    }
}
