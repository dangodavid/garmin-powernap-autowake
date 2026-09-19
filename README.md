# Power Nap Auto-Wake

A Garmin Connect IQ watchapp that **automatically detects when you fall asleep and
wakes you gently** after a configurable nap duration. No manual alarm setup required.
Put on the watch, start the app, lie down.

---

## How It Works

1. **Start the app** from your watch menu. Use UP/DOWN or tap above/below the number to set the nap duration (5–120 min, it stops at both ends), then press START, or tap the number or the "TAP to begin" hint (touchscreen watches; FR255 and Instinct 3 show "START to begin"). The number is minutes **of sleep** ("min of sleep"): they count from the moment you fall asleep. The start screen already shows the latest possible alarm time ("Latest alarm HH:MM"). One step below 5 min is **Stay Awake** mode (see below).
2. **Calibrating (2 min):** The app measures your resting heart rate to build a personal baseline. Stillness already counts from the first second.
3. **Monitoring:** It watches for sleep onset: two still minutes once your heart rate has dropped at least the HR Drop Threshold below the baseline, or five still minutes on stillness alone. Heart rate speeds detection up but is never required. Detection itself is silent: nothing vibrates, sounds or lights up until the alarm (the app's alarm manager refuses any output outside the alarm, and a permanent test file guards it).
4. **Sleep detected:** The alarm time is fixed at detection + nap duration, or at the "Latest alarm" time if that is earlier. The screen shows when you fell asleep, "Wake at HH:MM" and a live countdown. Example: 15 min nap started at 9:00, asleep at 9:10 → alarm at 9:25.
5. **Guaranteed alarm time:** From the start, the screen shows "Latest alarm HH:MM" = start + "max time to fall asleep" + nap duration. The alarm never rings later than that: if sleep is never detected it rings exactly then, and if you fall asleep late the nap is shortened to end by then. You can never sleep through a nap because detection failed.
6. **Smart Wake Window (naps of 15 min or more):** In the last 20 % of the nap before the alarm (at most 5 minutes) a restless minute or a slight HR rise fires the alarm early at a natural waking moment. If the "Latest alarm" cap shortened the nap below 15 minutes, there is no smart wake.
7. **Wake-up alarm:** A slow crescendo brings you out of sleep gradually. It starts with taps so fine you barely feel them (22 % for 120 ms) and grows in nine steps to full strength about two minutes after the first tap (118 s), then keeps ringing at full strength every 5 seconds for three minutes and every 30 seconds after that until you stop it. The screen is gentle too: it stays dark until the taps are clearly felt (the 50 % step) and then shows a calm "Time to wake up"; it only flashes once the alarm is at full strength. By default a soft nature-inspired melody joins the vibration from the 40 % step on watches with a beeper or speaker (see Alarm Escalation). If your alarm type cannot be heard on the watch (for example Nature sound only on a vívoactive, which has no speaker tones, or vibration switched off in the watch settings) the other channel is used. Works with Do Not Disturb on (verified on a fēnix 8 Pro: DND does not mute the vibration).
8. **Woke up early?** Nothing to do: lie still for two minutes and the nap continues, the alarm time stays the same. Every nap screen shows the time of day. Press UP, DOWN or START to peek at the nap so far (time asleep, wakes, alarm time) for a few seconds; this never stops anything.
9. **Stop:** Press BACK (or START) twice within 4 seconds to stop the alarm. Screen taps and swipes are ignored during a nap and during the alarm, and stopping a running nap also needs two BACK presses, so a wrist or sleeve on the pillow cannot silence anything. After the first BACK press the screen says what the second one does ("Again: stop + stats" once sleep was recorded; before that it returns to the start screen). For 2.5 seconds after a stop every press is ignored (each further press extends the pause), so extra presses of a half-asleep hand cannot skip the summary or start a new nap.
10. **Summary screen:** Shows time asleep, how long it took you to fall asleep ("Fell asleep in 10 min"), how much of the planned nap was completed (ring), the number of wake episodes, average and minimum HR, and the time window you slept. START sets up a new nap, BACK exits.

**Warning before you nap:** "Low battery N%" below 10 % (not charging).

**Keep the app open while napping.** On watches with a task switcher (fēnix 8, Venu 3/4, vívoactive 6, ...) an app sent to the background is not allowed to vibrate or play tones. The alarm rings the moment you return to the app, and the nap screens then show "Keep app open for alarm".

---

## Alarm Escalation

The wake-up alarm is designed to ease you out of sleep rather than startle you: one data-driven ramp (`AlarmManager.RAMP`, one row per step) from barely-perceptible taps to full strength, every step a small, noticeable increase.

| Step | Intensity | Pulses | Wait after each ring | First ring at | Feel |
|------|-----------|--------|----------------------|---------------|------|
| 0 | 22 % | 2 × 120 ms | 10 s | 0 s | Barely perceptible taps |
| 1 | 28 % | 2 × 140 ms | 9 s | 20 s | |
| 2 | 35 % | 2 × 160 ms | 8 s | 38 s | Soft taps (the Stay Awake nudge uses this step) |
| 3 | 43 % | 3 × 180 ms | 8 s | 54 s | The melody joins here with "Vibration + nature sound" |
| 4 | 52 % | 3 × 210 ms | 7 s | 70 s | Clearly felt; the screen may light up from here |
| 5 | 63 % | 3 × 240 ms | 6 s | 84 s | Firm (the Stay Awake doze alarm starts here) |
| 6 | 78 % | 3 × 280 ms | 6 s | 96 s | |
| 7 | 92 % | 3 × 320 ms | 5 s | 108 s | |
| 8 | 100 % | 3 × 350 ms | 5 s | 118 s | Full strength for 3 minutes; the screen flashes |
| Persistent | 100 % | 3 × 350 ms | 30 s | 298 s | Until stopped (saves battery if the watch is not on the wrist) |

Each ring is a short burst of pulses; the wait after a ring is that of its step, and each step rings twice before the next one. The screen shows the ramp as "ALARM 1/4" (below 40 %), "2/4" (below 65 %), "3/4" (below 100 %) and "4/4" (full). The ramp can be felt without napping: see "Test alarm" in the start-screen menu.

**Nature sound:** Connect IQ cannot play the watch's own alarm sounds ("Nature Awaits" and the like), audio files, or set the volume, so the app's nature sound is a short synthesized melody per step that grows with the ramp: a distant, low two-note "cuckoo" first, then bird chirps that gain notes, pitch and length (higher pitch sounds louder on the watch beeper), up to a trill at full strength. The default alarm type is **Vibration + nature sound**: the vibration opens the wake-up alone and the melody joins from the 43 % step. **Nature sound only** plays the melody from the first ring; **Vibration only** never plays it. Watches without tones (vívoactive 5/6) vibrate whatever the setting.

---

## Stay Awake Mode

Press DOWN below 5 min on the start screen ("0 stay awake"). The watch then keeps you awake instead of letting you sleep: it shows "Keeping you awake", and

- after 3 still minutes it gives one gentle buzz and shows **"Stay alert! Move a bit"**; moving for a few seconds or pressing any button answers it and the watch starts counting again;
- if you doze off anyway (the same detection as a nap: 2 still minutes with a heart-rate drop, or 5 still minutes) the **doze alarm** rings right away, starting part-way up the ramp (the 63 % step) and shows "You dozed off";
- stopping the doze alarm (two presses) puts the watch back on guard, so one session catches every doze;
- BACK twice ends the session; the summary shows how long you stayed awake and how many dozes were caught.

The heart-rate drop is measured against your own recent heart rate (the 10 minutes before the last three), so sitting calmly for an hour after walking in is not mistaken for dozing. Stay Awake is never remembered: the next start defaults to a nap again. **Not for driving**: detection needs minutes of stillness and cannot catch a microsleep.

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
| Alarm Type           | Vibration + nature sound | Vibration only / Nature sound only / Vibration + nature sound | How the alarm wakes you (watches without tones always vibrate) |
| HR Drop Threshold    | 5 BPM            | 3-20 BPM                                     | HR drop below the baseline that shortens onset to 2 still minutes (otherwise 5) |
| Motion Sensitivity   | Medium           | Low (restless sleepers) / Medium / High (strict stillness) | Low tolerates more movement while asleep; High counts even small movements as awake |

You can also adjust the nap duration directly on the watch start screen without opening the companion app.

---

## Sleep Detection Algorithm

Everything runs on the wall clock and on per-minute aggregates of the sensors, never on single samples.

**Calibration (2 min):** Averages every 1 Hz heart-rate reading into a personal resting baseline.

**Motion per second:** the spread of the acceleration magnitude within each one-second batch of 25 samples (mean absolute deviation, millig). It does not depend on the accelerometer's offset: a resting watch reads about 0 whether its sensor says 1000 or 1040 mg.

**Still minute:** mean motion below the sensitivity threshold (default 50 millig) and at most 5 seconds of the minute above it. A short roll-over does not break stillness; a restless minute resets it.

**Sleep onset (either):**
- 2 consecutive still minutes while the heart rate is at least the threshold (default 5 BPM) below the baseline
- 5 consecutive still minutes regardless of heart rate

The first onset is not back-dated: the alarm is fixed at detection + nap duration, capped at the "Latest alarm" time.

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

The suite under `test/` (210 tests) covers calibration and onset, wake episodes and re-entry, wall-clock alarm and deadline timing for every nap length, the alarm escalation, melodies and channel fallback (including the AMOLED backlight regression), the summary statistics, Stay Awake mode, the buttons (the real delegate, view and detector together), raw accelerometer batches, the quiet onset rule (`test/QuietOnsetTest.mc`: the real alarm manager stays silent after every simulated second of a nap until the alarm is due), and the layout of every screen including the start screen. Tests simulate sensor input second by second against a frozen fake clock.

- **Invariant tests** run seeded random naps (settings and a minute-by-minute story of dozing, stirring, waking and sensor dropouts) and check after every simulated second the rules that must always hold: the alarm always rings and never after the deadline, the planned end never moves, smart wake only inside its window, stats in range. A failure prints the seed to replay it.
- **Negative tests** feed absurd heart rates, missing accelerometer data, a wall clock stepping back, lifecycle calls in every state and wrong-type settings.
- **Trace replays** (`test/TraceTest.mc`) replay recorded naps minute by minute. To record one: install a debug build (no `-r`), create an empty `GARMIN/APPS/LOGS/PowerNap.TXT` on the watch, nap, and copy the file back; each minute line becomes one row of a replay test. The trace also proves the app was silent: it logs `onset`, `reentry`, `wake`, `alarm,<reason>` and `nudge` with the seconds since start, so an `onset` line without an `alarm` or `nudge` line at the same time means the app did not ring; a vibration felt at that moment came from the watch itself (an abnormal-heart-rate alert, a relax reminder, a phone notification, Garmin's own nap detection).

The layout tests measure the real device fonts, so run the suite on a few screen sizes (e.g. `fenix847mm`, `venu3s`, `fenix7s`, `fr255s`, `instinct3solar45mm`).

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
    launcher_icon.png           60×60 app icon (fallback size)
  properties/
    properties.xml              Default property values
  settings/
    settings.xml                Companion-app settings UI
  strings/
    strings.xml                 Localized strings (English)
resources-launcher/             App icon at each watch's native size (monkey.jungle picks it per device)
source/
  PowerNapApp.mc                AppBase: lifecycle (incl. task-switcher active/inactive)
  PowerNapView.mc               UI: start screen, nap, Stay Awake and peek screens as line lists
  PowerNapDelegate.mc           Input handler: buttons, start-screen touch zones, peek
  SleepDetector.mc              Sleep-detection engine (wall clock, per-minute aggregates, Stay Awake)
  AlarmManager.mc               Ramp-table vibration/melody alarm with channel fallback, quiet onset gate, nudge
  MotionMath.mc                 Offset-free motion measure for one accelerometer batch
  ScreenLayout.mc               Fit-any-screen line layout + monochrome palette
  ConfirmPress.mc               Two-press confirmation for stopping a nap or the alarm
  RingMath.mc                   Progress-ring angle math
test/
  OnsetTest.mc                  Calibration, stillness, onset paths
  WakeTest.mc                   Wake episodes, re-entry, sleep accumulation
  TimingTest.mc                 Wall-clock alarm, deadline cap, smart wake
  AlarmManagerTest.mc           Ramp constraints and schedule, melodies, backlight regression
  SummaryTest.mc                Finish/cancel paths, statistics, RingMath
  RegressionTest.mc             HR wake rules, frozen settings, lifecycle, channel fallback
  LayoutTest.mc                 Every screen fits the running device
  StayAwakeTest.mc              Stay Awake: doze rules, rolling HR reference, nudge, guard
  DelegateTest.mc               Buttons and taps through the real delegate and view
  QuietOnsetTest.mc             Quiet onset rule: no output before the alarm, every second, real alarm manager
  MotionTest.mc                 Raw accelerometer batches, offset independence
  InvariantTest.mc              Seeded random naps + negative tests
  TraceTest.mc                  Replays of recorded naps
```

---

## Limitations

- Connect IQ does **not** expose Garmin's native sleep-stage data (REM, light, deep). This app builds its own detection algorithm from raw HR and accelerometer signals.
- Battery usage is higher than normal while the app is active due to continuous accelerometer sampling at 25 Hz. For a typical 30-minute nap the impact is minimal.
- Detection accuracy varies by individual. Lying perfectly still while awake for five minutes counts as sleep onset, and a heart rate that is still settling after activity can meet the HR-drop rule early; restless sleepers may see wake episodes. The Motion Sensitivity, HR Drop Threshold and Max time to fall asleep settings tune this. The alarm rings in every case, never later than the "Latest alarm" time.
- On task-switcher watches the app must stay in the foreground to vibrate (see above).
- In a moving vehicle (train, car, plane) the vibrations count as movement, so sleep is usually not detected; the alarm still rings at the "Latest alarm" time.
- A watch taken off and left on a table looks like a sleeper after five still minutes (no heart rate is needed for onset).


---

## Privacy

This app does **not** transmit any data outside the watch. Heart rate and accelerometer data are processed in-memory and never written to device storage or saved to a Garmin Connect activity log. The only data persisted between sessions is your chosen nap duration preference. (Developer debug builds can write a per-minute log for testing, and only when the developer creates the log file on the watch; store builds never write one.)

---

## License

MIT
