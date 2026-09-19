import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Lang;

//! Main application entry point for Power Nap Auto-Wake.
//! Manages the lifecycle of the app: initializes the sleep detector and alarm
//! manager, provides them to the view/delegate, and cleans up on exit.
class PowerNapApp extends Application.AppBase {

    private var _sleepDetector as SleepDetector?;
    private var _alarmManager as AlarmManager?;
    private var _view as PowerNapView?;

    function initialize() {
        AppBase.initialize();
    }

    //! Called when the application starts. Creates the sleep detector and alarm
    //! manager; the view and delegate come from getInitialView().
    function onStart(state as Dictionary?) as Void {
        _alarmManager = new AlarmManager();
        _sleepDetector = new SleepDetector(_alarmManager);
    }

    //! Returns the initial view and its input delegate.
    function getInitialView() as [Views] or [Views, InputDelegates] {
        if (_alarmManager == null) {
            _alarmManager = new AlarmManager();
        }
        if (_sleepDetector == null) {
            _sleepDetector = new SleepDetector(_alarmManager);
        }
        var view = new PowerNapView(_sleepDetector as SleepDetector, _alarmManager as AlarmManager);
        _view = view;
        var delegate = new PowerNapDelegate(view, _sleepDetector as SleepDetector, _alarmManager as AlarmManager);
        return [view, delegate];
    }

    //! Called when the application is stopping. Releases sensor resources.
    function onStop(state as Dictionary?) as Void {
        if (_sleepDetector != null) {
            (_sleepDetector as SleepDetector).stop();
        }
        if (_alarmManager != null) {
            (_alarmManager as AlarmManager).stop();
        }
    }

    //! Task-switcher devices (fenix 8, Venu 3/4, vivoactive 6, ...): the app
    //! was sent to the background. The system now denies vibration and tones
    //! and limits sensors; the view warns the user once they come back.
    function onInactive(state as Dictionary?) as Void {
        if (_sleepDetector != null) {
            (_sleepDetector as SleepDetector).noteInactive();
        }
    }

    //! Back in the foreground: check the alarm immediately and, if it is
    //! already ringing (silently, while we were hidden), ring right now.
    function onActive(state as Dictionary?) as Void {
        if (_sleepDetector != null && _alarmManager != null) {
            Lifecycle.resume(_sleepDetector as SleepDetector, _alarmManager as AlarmManager);
        }
    }

    //! Called when a setting changes in the companion app. A running nap
    //! keeps its settings (the detector ignores the reload); the start
    //! screen follows a new nap duration.
    function onSettingsChanged() as Void {
        if (_sleepDetector != null) {
            (_sleepDetector as SleepDetector).loadSettings();
        }
        if (_alarmManager != null) {
            (_alarmManager as AlarmManager).loadSettings();
        }
        if (_view != null) {
            (_view as PowerNapView).onSettingsChanged();
        }
        WatchUi.requestUpdate();
    }
}

//! App lifecycle steps that tests can drive without an AppBase.
module Lifecycle {

    //! Back in the foreground. An alarm that was already ringing while the
    //! app was hidden (the system denied it) rings again at once. An alarm
    //! that only becomes due now is started by onResume() itself, so it must
    //! not get a second, immediate ring on top of its first one.
    function resume(detector as SleepDetector, alarm as AlarmManager) as Void {
        var wasAlarming = alarm.isAlarming();
        detector.onResume();
        if (wasAlarming) {
            alarm.ringNow();
        }
    }
}
