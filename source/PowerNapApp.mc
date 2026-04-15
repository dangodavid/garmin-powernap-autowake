import Toybox.Application;
import Toybox.WatchUi;
import Toybox.Lang;

//! Main application entry point for Power Nap Auto-Wake.
//! Manages the lifecycle of the app: initializes the sleep detector and alarm
//! manager, provides them to the view/delegate, and cleans up on exit.
class PowerNapApp extends Application.AppBase {

    private var _sleepDetector as SleepDetector?;
    private var _alarmManager as AlarmManager?;

    function initialize() {
        AppBase.initialize();
    }

    //! Called when the application starts. Creates the sleep detector and alarm
    //! manager instances, then pushes the main view.
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

    //! Called when a setting changes in the companion app.
    function onSettingsChanged() as Void {
        if (_sleepDetector != null) {
            (_sleepDetector as SleepDetector).loadSettings();
        }
        if (_alarmManager != null) {
            (_alarmManager as AlarmManager).loadSettings();
        }
        WatchUi.requestUpdate();
    }
}
