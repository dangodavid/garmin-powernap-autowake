# Changelog

What changed for the person wearing the watch. The manifest carries no version
number - it is typed into the Connect IQ upload form - so the published version
is whatever the store page and the developer dashboard say, and a section here
is only a claim about the code, not about what anyone has installed.

This file starts at 1.1.0; it is not filled in backwards.

## 1.1.0 - unreleased

- **The alarm rings, whatever the nap.** On watches with a burn-in protected
  screen, turning the backlight on could fail in a way that swallowed the
  vibration with it, so the alarm stayed silent. The vibration and the sound
  now come first and the backlight last. Short naps ring too.
- **"Alarm by HH:MM".** The start screen shows the latest minute the alarm can
  ring, with the time of day above it, and the nap screens keep showing it. The
  alarm never rings later than that minute, whether or not you fall asleep.
  Once you are asleep it becomes "Wake at HH:MM", the end of the nap itself.
  A new setting, "Max time to fall asleep" (15 minutes by default), is what
  that promise is made of: fall asleep later than that and the nap is shortened
  rather than the alarm pushed back.
- **A wake-up that starts gently.** The alarm now climbs through nine steps,
  from a light double tap to full strength in about two minutes, holds full
  strength for three minutes and then keeps ringing every 30 seconds until you
  stop it. The screen stays dark and calm until it reaches full strength, so
  being woken early is quiet and being woken late is not.
- **Sound as well as vibration, by default.** New alarms play a short nature
  like melody that grows with each step, joining in partway up the ramp. If you
  had already chosen an alarm type, your choice is kept. On watches with no
  speaker, or with sounds switched off, the vibration carries the alarm alone,
  and the other way round.
- **Test alarm.** Hold UP, or long press the number on a touchscreen, to open
  the menu and feel the whole wake-up ramp once without starting a nap.
- **Stay Awake mode.** Press DOWN below 5 minutes and the watch does the
  opposite of a nap: the same detection nudges you the moment you start dozing
  off, and rings properly if you do. The summary says how many times it caught
  you.
- **Nothing buzzes until the alarm.** Falling asleep, waking up, the end of
  calibration and a sensor dropout are all silent now. The only thing a nap
  makes you feel is the alarm.
- **Stillness is measured properly.** Motion is now how much the reading moves
  within each second instead of how far it sits from 1 g, so a watch whose
  accelerometer reads a little high is no longer seen as permanently moving.
  On the High sensitivity setting that could keep sleep from being detected at
  all.
- **The watch remembers your last nap length** and opens on it, unless you
  change the duration in the phone settings.
- **Live screens.** The nap screens update every second, and the summary
  reports what actually happened: how long you slept, how long it took you to
  fall asleep, and how many times you woke.
- **BACK is a back button.** One press goes back one level and never leaves the
  app, so pressing it again walks back to the start screen. Where a press back
  would end something, it asks first: the first BACK shows "Press BACK again to
  end nap", "...to stop alarm" or "...to end session" and changes nothing at
  all, and the second one does it. Only the start screen closes the app, on a
  second BACK within 4 seconds. In 1.0.2 a single BACK on the start screen
  closed the app with no warning, and BACK on the summary closed it too. During
  a nap and while the alarm is ringing, swiping does nothing: only the buttons
  act, so a sleeve cannot end your nap.
