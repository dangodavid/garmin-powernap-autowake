# Power Nap Auto-Wake

A Garmin Connect IQ watchapp that **automatically detects when you fall asleep and
wakes you gently** after a configurable nap duration. No manual alarm setup required.
Put on the watch, start the app, lie down.

---

## How It Works

1. **Start the app** from your watch menu. Use UP/DOWN or tap to set the nap duration (5–120 min), then press START or tap the centre to begin.
2. **Calibrating (2 min):** The app silently measures your resting heart rate to build a personal baseline.
3. **Monitoring:** It watches for sleep onset: a combination of HR drop and sustained immobility for at least 3 minutes.
4. **Sleep detected:** A countdown starts. The screen shows when you fell asleep and how much time remains.
5. **Smart Wake Window:** In the final 5 minutes, the app checks for light-sleep signals (gentle movement or a slight HR rise). If detected, the alarm fires early at a natural waking moment instead of abruptly mid-cycle.
6. **Wake-up alarm:** An escalating haptic pattern brings you out of sleep gradually, starting with a barely-perceptible feather tap, progressing to gentle pulses, then firm buzzes, and finally a full alarm. Full intensity is reached after approximately 90 seconds.
7. **Dismiss:** Press BACK or tap the screen to stop the alarm and view your nap summary.
8. **Summary screen:** Shows actual sleep duration, efficiency rating, average and minimum HR, and the time window you slept.

---

## Alarm Escalation

The wake-up alarm is designed to ease you out of sleep rather than startle you. Gradual haptic escalation starting at minimal intensity.

| Phase       | Duration | Intensity | Feel                          |
|-------------|----------|-----------|-------------------------------|
| Feather     | 0–36 s   | 15 %      | Barely perceptible taps       |
| Gentle      | 36–64 s  | 30 %      | Soft, clearly felt pulses     |
| Medium      | 64–88 s  | 65 %      | Firm, unmistakable buzzes     |
| Full        | 88 s+    | 100 %     | Standard alarm, stays at max   |

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
| Alarm Type           | Vibration Only   | Vibration / Tone / Vibration + Tone         | How the alarm wakes you                       |
| HR Drop Threshold    | 8 BPM            | 3–20 BPM                                    | HR drop required to detect sleep              |
| Motion Sensitivity   | Medium           | Low / Medium / High                         | Lower = more movement allowed before reset    |

You can also adjust the nap duration directly on the watch start screen without opening the companion app.

---

## Sleep Detection Algorithm

The algorithm is intentionally conservative to minimise false positives.

**Calibration (2 min):** Collects 12 heart-rate samples at 10-second intervals to compute a personal resting HR baseline.

**Sleep onset requires ALL of the following, sustained for ≥ 3 minutes:**
- Heart rate has dropped ≥ threshold BPM below your baseline (default: 8 BPM)
- Accelerometer motion is below the sensitivity threshold (default: 50 millig)

**Spontaneous wake detection (returns to monitoring if either is true):**
- Sustained motion above 200 millig across two consecutive 60-second poll intervals
- Heart rate spike > 10 BPM above the recent sleep-phase average

**Monitoring timeout:** If no sleep is detected within 60 minutes, the app shows a "No sleep detected" screen and stops.

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

23 automated test cases cover state machine transitions, threshold boundary conditions, spontaneous wake detection, Smart Wake Window logic, and multi-cycle sleep accumulation.

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
  PowerNapApp.mc                AppBase: lifecycle, sensor init/teardown
  PowerNapView.mc               UI: 6 screens via state machine
  PowerNapDelegate.mc           Input handler: physical buttons and touch zones
  SleepDetector.mc              Sleep-detection algorithm (6-state machine)
  AlarmManager.mc               4-phase escalating vibration/tone alarm
test/
  SleepDetectorTest.mc          23 unit tests (Toybox.Test framework)
```

---

## Limitations

- Connect IQ does **not** expose Garmin's native sleep-stage data (REM, light, deep). This app builds its own detection algorithm from raw HR and accelerometer signals.
- Battery usage is higher than normal while the app is active due to continuous accelerometer sampling at 25 Hz. For a typical 30-minute nap the impact is minimal.
- Detection accuracy varies by individual. Users with a naturally low resting HR or those who lie very still while awake may benefit from adjusting the HR Drop Threshold and Motion Sensitivity settings.

---

## Privacy

This app does **not** transmit any data outside the watch. Heart rate and accelerometer data are processed in-memory and never written to device storage or saved to a Garmin Connect activity log. The only data persisted between sessions is your chosen nap duration preference.

---

## License

MIT
