# Thumb Space and palm filtering

Palm rejection is enabled by default with Balanced sensitivity and Pause trackpad
while typing enabled. Open the iPad gear menu to change these settings; they are
saved on that iPad and do not change the photograph or key calibration.

## Space with a thumb

The old input surface discarded every contact with a reported radius of 40
points or more. This could discard a valid thumb even though another finger on
the same Space key worked.

Space now has a separate broad-contact path. A short broad thumb tap types one
space when the thumb lifts. A broad contact held still on Space is ignored so
a resting palm does not insert repeated spaces. A narrower fingertip still
supports normal key-down and held repeat. Pressing harder is not required.

If a light thumb tap does not work, enable Show touch indicators. Red means the
contact is ignored, yellow means it is being checked, and green means accepted.
Try Relaxed sensitivity if valid fingertips are red. Check the Space outline in
photo calibration if a tap lands outside the intended region.

## Palm rejection behavior

- A brief confirmation window allows contact size to settle before key input.
  Short, valid taps still register when lifted before that window ends.
- Large contacts on ordinary keys and the trackpad are ignored. A touch that
  grows into a palm releases any held input and stays ignored until lifted.
- Contacts starting outside the calibrated keyboard and trackpad stay inactive
  even if they slide into an active region.
- With typing protection on, ordinary keys suppress trackpad gestures and
  briefly pause new trackpad contacts after typing. A contact ignored during
  typing cannot wake up and move the pointer later; lift it first.
- Modifier keys alone still allow gestures such as Shift-drag.
- Strict rejects smaller contacts; Relaxed accepts larger ones. Balanced is the
  starting point. Turning Palm rejection off restores immediate, unfiltered
  touch input; Show touch indicators is independent of the filter.

This is a software heuristic using the contact information provided by iPadOS.
It cannot perfectly separate a resting fingertip from an intended keypress and
cannot undo an event already sent to the Mac. It does not provide physical key
travel, pressure sensing, or the same palm classifier as a MacBook trackpad.

The configured defaults include roughly 45 ms of contact confirmation, a 350 ms
typing pause, and a 350 ms maximum broad-Space tap. These are algorithm settings,
not measured end-to-end latency. Validate comfort and rejection on the actual
iPad before relying on this for long typing sessions.

Apple documents the available contact measurements as
[majorRadius](https://developer.apple.com/documentation/uikit/uitouch/majorradius)
and [majorRadiusTolerance](https://developer.apple.com/documentation/uikit/uitouch/majorradiustolerance).
