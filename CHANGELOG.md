# Changelog

What changed for the person wearing the watch. The manifest carries no version
number - it is typed into the Connect IQ upload form - so the published version
is whatever the store page and the developer dashboard say, and a section here
is only a claim about the code, not about what anyone has installed.

This file starts at 1.1.0; it is not filled in backwards.

## 1.1.0 - unreleased

The five notes the store page carries, and then the rest of what changed for
the person wearing the watch.

- **Stay Awake**: set the time below 5 minutes and, instead of timing a nap,
  the watch nudges you when you start to doze off. It rings properly if you
  doze off anyway, and the summary says how many times it caught you.
- **A gentler wake-up**: vibration and a soft melody inspired by nature start
  quietly and build to full strength over about two minutes, then keep going
  until you stop them. The screen stays dark and calm until full strength, so
  being woken early is quiet. If you had already chosen an alarm type, your
  choice is kept; on watches with no speaker, or with sounds switched off, the
  vibration carries the alarm alone, and the other way round.
- **The start screen shows "Alarm by HH:MM"**: the latest time the alarm will
  ring, whether or not you fall asleep. The nap screens keep showing it, and
  once you are asleep it becomes "Wake at HH:MM", the end of the nap itself. A
  new setting, "Max time to fall asleep" (15 minutes by default), is what that
  promise is made of: fall asleep later than that and the nap is shortened
  rather than the alarm pushed back.
- **Test alarm**: feel the whole wake-up from the menu, without starting a nap.
  Hold UP, or long press the number on a touchscreen.
- **Fixes**: the alarm could stay silent on some AMOLED watches. On some
  watches, falling asleep could go undetected. BACK now works like everywhere
  else on your watch, one screen at a time, and asks before it ends a nap or
  Stay Awake, or stops the alarm.

Also in this release:

- Nothing buzzes until the alarm. Falling asleep, waking up, the end of the
  first two minutes and a sensor dropout are all silent now.
- The watch remembers your last nap length and opens on it, unless you change
  the duration in the phone settings.
- The nap screens update every second, and the summary reports what actually
  happened: how long you slept, how long it took you to fall asleep, and how
  many times you woke.
- While a nap or the alarm is running, swiping does nothing: only the buttons
  act, so a sleeve cannot end your nap.
