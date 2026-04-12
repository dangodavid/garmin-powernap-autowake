# Power Nap Auto-Wake Garmin Connect IQ App

A Garmin watch application that **automatically detects when you fall asleep and wakes you up** after a configurable nap duration (default 30 minutes). No manual alarm setting required.

## How It Works

1. Start the app from your watch menu.
2. Lie down and relax — the app monitors your heart rate and movement.
3. During the first **2 minutes** it calibrates your resting heart-rate baseline.
4. Once calibration is done it watches for simultaneous:
   - Heart-rate drop (default ≥ 8 BPM below baseline)
   - Near-zero motion (sustained ≥ 3 minutes)
5. When sleep is detected a countdown starts (default 30 min).
6. At countdown expiry the watch **vibrates strongly** to wake you.
7. If you wake on your own (sudden movement or HR spike) the alarm auto-cancels.
8. A summary screen shows nap duration, average and minimum HR.

## Supported Devices

- Garmin fēnix 8 / 8 Solar / 8 Pro
- Garmin fēnix 7 Pro / 7X Pro / 7S Pro
- Garmin Forerunner 965 / 955
- Garmin Enduro 3
- Garmin Venu 3 / 3S
- Garmin MARQ Gen 2 / MARQ Aviator Gen 2
- Garmin Tactix 8

Minimum Connect IQ API level: **4.0.0**

## Project Structure

```
├── manifest.xml                    # App metadata, devices, permissions
├── monkey.jungle                   # Build configuration
├── resources/
│   ├── drawables/
│   │   ├── drawables.xml           # Drawable resource definitions
│   │   └── launcher_icon.png       # 60×60 app icon
│   ├── layouts/
│   │   └── MainLayout.xml          # Base layout
│   ├── properties/
│   │   └── properties.xml          # Default property values
│   ├── settings/
│   │   └── settings.xml            # Companion-app settings UI
│   └── strings/
│       └── strings.xml             # Localized strings (EN)
└── source/
    ├── PowerNapApp.mc              # AppBase — lifecycle management
    ├── PowerNapView.mc             # UI — 5 screens via state machine
    ├── PowerNapDelegate.mc         # Input handler (buttons / touch)
    ├── SleepDetector.mc            # Sleep-detection algorithm
    └── AlarmManager.mc             # Vibration / tone alarm manager
```

## Configurable Settings

These appear in the Garmin Connect IQ companion app on your phone:

| Setting             | Default | Range       | Description                          |
|---------------------|---------|-------------|--------------------------------------|
| Nap Duration        | 30 min  | 5–120 min   | How long the nap should last         |
| Alarm Type          | Vibration Only | Vibration / Tone / Both | Wake-up method      |
| HR Drop Threshold   | 8 BPM   | 3–20 BPM    | HR drop required to detect sleep     |
| Motion Sensitivity  | Medium  | Low/Med/High| Lower = more motion allowed          |
| Auto-Save Summary   | On      | On/Off      | Save nap data automatically          |

## Building

### Prerequisites

- [Connect IQ SDK 8.x](https://developer.garmin.com/connect-iq/sdk/)
- Visual Studio Code with the [Monkey C extension](https://marketplace.visualstudio.com/items?itemName=garmin.monkey-c)
- A developer key (`developer_key.der`) — generate one via the SDK Manager

### Build from VS Code

1. Open this folder in VS Code.
2. Press **Ctrl+Shift+P** → *Monkey C: Build for Device*.
3. Select a target device (e.g. `fenix847mm`).
4. The `.prg` file appears in `bin/`.

### Build from command line

```bash
# Set the SDK path
export CIQ_HOME=~/connectiq-sdk

# Build for fenix 8 47mm
$CIQ_HOME/bin/monkeyc \
  -o bin/PowerNap.prg \
  -f monkey.jungle \
  -d fenix847mm \
  -y /path/to/developer_key.der
```

### Run in simulator

```bash
$CIQ_HOME/bin/connectiq &            # Start the simulator
$CIQ_HOME/bin/monkeydo bin/PowerNap.prg fenix847mm
```

## Installing on a Watch

1. Build the `.prg` file for your device.
2. Connect your watch via USB.
3. Copy `bin/PowerNap.prg` to `GARMIN/APPS/` on the watch.
4. Eject and unplug — the app appears in your watch's app list.

## Sleep Detection Algorithm

The algorithm uses a conservative approach to minimize false positives:

- **Calibration** (2 min): averages your HR to establish a personal baseline.
- **Detection** requires ALL of these simultaneously for ≥ 3 minutes:
  - HR is ≥ threshold BPM below your baseline
  - Accelerometer motion is below the sensitivity threshold
- **Spontaneous wake** is detected when motion exceeds 200 millig or HR spikes > 15 BPM above sleep levels.

The algorithm intentionally errs on the side of delayed detection (1–2 min late) rather than false positives.

## Limitations

- Connect IQ does **not** expose Garmin's native sleep-stage data (REM, light, deep). This app builds its own detection from raw sensor signals.
- Accelerometer data at 25 Hz increases battery usage. The app uses a 10-second poll interval to balance responsiveness with power consumption.
- Detection accuracy varies by individual — users with naturally low resting HR or those who stay very still while awake may need to adjust the HR Drop Threshold and Motion Sensitivity settings.

## Privacy

This app does **not** transmit any data outside the watch. All sensor data is processed locally and discarded when the app exits.

## License

MIT
