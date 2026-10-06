> **Historical document - the store texts of 1.2.0.**
>
> Written on 2026-10-06 for the Connect IQ upload form, from the 1.2.0
> section of `CHANGELOG.md`. The store page is the only record of what was
> actually published. **`CLAUDE.md` takes precedence over everything below**,
> and `CHANGELOG.md` holds the full list of changes.

# Power Nap 1.2.0 - store texts

## Version

`1.2.0`, typed into the upload form: the manifest carries no version number.
The package is `bin/PowerNap-1.2.0.iq`, built from `main` at the commit tagged
`v1.2.0`.

## What's new

- **The alarm only vibrates.** The nature melody and the Alarm Type setting
  are gone: the sound did not play the same on every watch, and a wrong sound
  is worse than none.
- **A gentler start to the alarm.** It opens with two faint pulses and climbs
  step by step, each a little stronger than the last, to full strength in just
  under three minutes. Test alarm plays every step and shows when it comes in
  the real alarm.
- **"Vibration off" on the start screen** when vibration is switched off in
  the watch settings, and START (or a tap) asks once more before the nap
  begins.
- **Fixes**: the time at the top of the start screen no longer runs into the
  title, and the "Press BACK again" popup no longer cuts a line in half.
- **The Test alarm menu** is titled POWER NAP, and its one item is no longer
  cut short.

## Description

The description on the store page was written for 1.1.0, whose alarm was
vibration and a soft melody. If it mentions a melody, a sound or the Alarm Type
setting, those words go: 1.2.0 wakes you with vibration only.
