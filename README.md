# Power Nap Auto-Wake

A Garmin Connect IQ watchapp that **automatically detects when you fall asleep and
wakes you gently** after a configurable nap duration. No manual alarm setup required.
Put on the watch, start the app, lie down.

---

## How It Works

1. **Start the app** from your watch menu. Use UP/DOWN or tap to set the nap duration (5–120 min), then press START or tap the centre to begin.
2. **Calibrating (2 min):** The app measures your resting heart rate to build a personal baseline. Stillness already counts from the first second.
3. **Monitoring:** It watches for sleep onset: two still minutes once your heart rate has dropped at least the HR Drop Threshold below the baseline, or five still minutes on stillness alone. Heart rate speeds detection up but is never required.
4. **Sleep detected:** The alarm time is fixed at detection + nap duration, or at the "Alarm by" time if that is earlier. The screen shows when the nap started and a live countdown.
5. **Guaranteed alarm time:** From the start, the screen shows "Alarm by HH:MM" = start + "max time to fall asleep" + nap duration. The alarm never rings later than that: if sleep is never detected it rings exactly then, and if you fall asleep late the nap is shortened to end by then. You can never sleep through a nap because detection failed.
6. **Smart Wake Window (naps of 15 min or more):** In the last 20 % of the nap before the alarm (at most 5 minutes) a restless minute or a slight HR rise fires the alarm early at a natural waking moment. If the "Alarm by" cap shortened the nap below 15 minutes, there is no smart wake.
7. **Wake-up alarm:** An escalating haptic pattern brings you out of sleep gradually, from a barely-perceptible feather tap to full intensity after 84 seconds. It keeps ringing until you stop it. If your alarm type cannot be heard on the watch (for example Tone Only on a vívoactive, which has no speaker tones, or vibration switched off in the watch settings) the other channel is used.
8. **Stop:** Press BACK (or START) twice within 4 seconds to stop the alarm. Screen taps and swipes are ignored during a nap and during the alarm, and stopping a running nap also needs two BACK presses, so a wrist or sleeve on the pillow cannot silence anything.
9. **Summary screen:** Shows time asleep, how much of the planned nap was completed (ring), the number of wake episodes, average and minimum HR, and the time window you slept.

**Keep the app open while napping.** On watches with a task switcher (fēnix 8, Venu 3/4, vívoactive 6, ...) an app sent to the background is not allowed to vibrate or play tones. The alarm rings the moment you return to the app, and the nap screens then show "Keep app open for alarm".

---

## Alarm Escalation

The wake-up alarm is designed to ease you out of sleep rather than startle you. Gradual haptic escalation starting at minimal intensity.

| Phase       | Duration | Intensity | Feel                          |
|-------------|----------|-----------|-------------------------------|
| Feather     | 0–34 s   | 15 %      | Barely perceptible taps       |
| Gentle      | 34–61 s  | 30 %      | Soft, clearly felt pulses     |
| Medium      | 61–84 s  | 65 %      | Firm, unmistakable buzzes     |
| Full        | 84 s+    | 100 %     | Standard alarm, stays at max   |

---

## Supported Devices

| Series          | Models |
|-----------------|--------|
| **fēnix 8**     | 43 mm, 47 mm, 8 Pro 47 mm, 8 Solar 47 mm / 51 mm |
| **fēnix 7**     | 7, 7 Pro, 7S, 7S Pro, 7X, 7X Pro, fēnix E |
| **Epix 2**      | Epix 2, Pro 42 mm / 47 mm / 51 mm |
| **Forerunner**  | 255 / 255M / 255S / 255SM, 265 / 265S, 570 42 mm / 47 mm, 955, 965, 970 |
| **Enduro**      | Enduro 3 |
| **Instinct 3**  | AMOLED 45 mm / 50 mm, Solar 45 mm |
| **Venu**        | Venu 3 / 3S, Venu 4 41 mm / 45 mm |
| **vívoactive**  | vívoactive 5, vívoactive 6 |
| **MARQ Gen 2**  | MARQ Gen 2, MARQ Aviator Gen 2 |
| **D2**          | D2 Mach 1, D2 Mach 2 |
| **Descent**     | Descent MK3 43 mm / 51 mm |

Minimum Connect IQ API level: **4.0.0**

---

## Configurable Settings

These appear in the **Garmin Connect companion app** on your phone under the app's settings.

| Setting              | Default          | Range / Options                             | Description                                   |
|----------------------|------------------|---------------------------------------------|-----------------------------------------------|
| Nap Duration         | 30 min           | 5–120 min                                   | Target nap length                             |
| Max time to fall asleep | 15 min        | 5–30 min                                    | The alarm rings at the latest this long plus the nap duration after start |
| Alarm Type           | Vibration Only   | Vibration / Tone / Vibration + Tone         | How the alarm wakes you                       |
| HR Drop Threshold    | 5 BPM            | 3-20 BPM                                     | HR drop below the baseline that shortens onset to 2 still minutes (otherwise 5) |
| Motion Sensitivity   | Medium           | Low / Medium / High                         | Lower = more movement allowed before reset    |

You can also adjust the nap duration directly on the watch start screen without opening the companion app.

---

## Sleep Detection Algorithm

Everything runs on the wall clock and on per-minute aggregates of the sensors, never on single samples.

**Calibration (2 min):** Averages every 1 Hz heart-rate reading into a personal resting baseline.

**Still minute:** mean accelerometer deviation from 1 g below the sensitivity threshold (default 50 millig) and at most 5 seconds of the minute above it. A short roll-over does not break stillness; a restless minute resets it.

**Sleep onset (either):**
- 2 consecutive still minutes while the heart rate is at least the threshold (default 5 BPM) below the baseline
- 5 consecutive still minutes regardless of heart rate

The first onset is not back-dated: the alarm is fixed at detection + nap duration, capped at the "Alarm by" time.

**Wake episode (returns to monitoring, countdown keeps running):**
- 10 or more seconds of motion in a minute, or a minute mean above 100 millig
- or a heart rate at least 10 BPM above the sleep-phase average for two consecutive minutes

Going back to sleep needs 2 still minutes, no heart-rate condition, and restarts the sleep-phase heart-rate average (so a steady, slightly higher heart rate is not reported as a wake every few minutes). Time awake, including the minute that showed the wake, is excluded from the time asleep.

**Deadline alarm:** If sleep is never detected, the alarm rings at start + max time to fall asleep + nap duration. The summary then says "No sleep detected".

**Settings:** nap duration, max time to fall asleep, HR drop threshold and motion sensitivity are read when a nap starts; a change made from the phone during a nap applies to the next nap. A change of Alarm Type applies immediately, also to a nap or alarm in progress.

---

## Building

### Prerequisites

- [Garmin Connect IQ SDK](https://developer.garmin.com/connect-iq/sdk/) 4.0.0 or later (SDK Manager 8.x recommended)
- Visual Studio Code with the [Monkey C extension](https://marketplace.visualstudio.com/items?itemName=garmin.monkey-c)
- A developer key (`developer_key.der`): generate one via the SDK Manager or Garmin's online keytool

### Build from VS Code

1. Open this folder in VS Code.
2. Press `Ctrl+Shift+P` -> *Monkey C: Build for Device*.
3. Select a target device (e.g. `fenix847mm`).
4. The `.prg` file appears in `bin/`.

### Build from the command line

```bash
export CIQ_HOME=~/connectiq-sdk

$CIQ_HOME/bin/monkeyc \
  -o bin/PowerNap.prg \
  -f monkey.jungle \
  -d fenix847mm \
  -y /path/to/developer_key.der
```

### Run in the simulator

```bash
$CIQ_HOME/bin/connectiq &
$CIQ_HOME/bin/monkeydo bin/PowerNap.prg fenix847mm
```

### Run unit tests

```
Ctrl+Shift+P -> Monkey C: Run Tests
```

The suite under `test/` (123 tests) covers calibration and onset, wake episodes and re-entry, wall-clock alarm and deadline timing for every nap length, the alarm escalation and channel fallback (including the AMOLED backlight regression), the summary statistics, and the layout of every nap screen (the start screen's tap zones only). Tests simulate sensor input second by second against a frozen fake clock. The layout tests measure the real device fonts, so run the suite on a few screen sizes (e.g. `fenix847mm`, `venu3s`, `fenix7s`, `fr255s`, `instinct3solar45mm`).

---

## Installing on a Watch

1. Build the `.prg` for your specific device.
2. Connect the watch to your computer via USB.
3. Copy `bin/PowerNap.prg` to the `GARMIN/APPS/` folder on the watch.
4. Eject and unplug. The app appears in your watch's app list immediately.

---

## Project Structure

```
manifest.xml                    App metadata, supported devices, permissions
monkey.jungle                   Build configuration
resources/
  drawables/
    drawables.xml               Drawable resource definitions
    launcher_icon.png           60×60 app icon
  properties/
    properties.xml              Default property values
  settings/
    settings.xml                Companion-app settings UI
  strings/
    strings.xml                 Localized strings (English)
source/
  PowerNapApp.mc                AppBase: lifecycle (incl. task-switcher active/inactive)
  PowerNapView.mc               UI: start screen + 4 nap screens described as line lists
  PowerNapDelegate.mc           Input handler: buttons, start-screen touch zones
  SleepDetector.mc              Sleep-detection engine (wall clock, per-minute aggregates)
  AlarmManager.mc               4-phase escalating vibration/tone alarm with channel fallback
  ScreenLayout.mc               Fit-any-screen line layout + monochrome palette
  ConfirmPress.mc               Two-press confirmation for stopping a nap or the alarm
  RingMath.mc                   Progress-ring angle math
test/
  OnsetTest.mc                  Calibration, stillness, onset paths
  WakeTest.mc                   Wake episodes, re-entry, sleep accumulation
  TimingTest.mc                 Wall-clock alarm, deadline cap, smart wake
  AlarmManagerTest.mc           Escalation phases, backlight regression
  SummaryTest.mc                Finish/cancel paths, statistics, RingMath
  RegressionTest.mc             HR wake rules, frozen settings, lifecycle, channel fallback
  LayoutTest.mc                 Every screen fits the running device
```

---

## Limitations

- Connect IQ does **not** expose Garmin's native sleep-stage data (REM, light, deep). This app builds its own detection algorithm from raw HR and accelerometer signals.
- Battery usage is higher than normal while the app is active due to continuous accelerometer sampling at 25 Hz. For a typical 30-minute nap the impact is minimal.
- Detection accuracy varies by individual. Lying perfectly still while awake for five minutes counts as sleep onset, and a heart rate that is still settling after activity can meet the HR-drop rule early; restless sleepers may see wake episodes. The Motion Sensitivity, HR Drop Threshold and Max time to fall asleep settings tune this. The alarm rings in every case, never later than the "Alarm by" time.
- On task-switcher watches the app must stay in the foreground to vibrate (see above).

---

## Privacy

This app does **not** transmit any data outside the watch. Heart rate and accelerometer data are processed in-memory and never written to device storage or saved to a Garmin Connect activity log. The only data persisted between sessions is your chosen nap duration preference.

---

## License

MIT
