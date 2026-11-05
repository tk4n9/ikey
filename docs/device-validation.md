# Device validation

Status: **not yet performed on Apple devices**. Linux checks cover shared
geometry/protocol tests and Swift syntax parsing, not Apple API typechecking,
signing, TLS handshakes, Quartz effects, or physical multitouch.

Run `./scripts/check-macos.sh` on a Mac first, then launch both apps from Xcode.
Use a disposable document for the first input tests.

- Permission handling: deny input control and local network access, then grant
  them and retry. The UI should explain the missing access and recover.
- Pairing: correct key connects; a different 64-character key fails; malformed
  text is rejected. A second iPad must not replace the active connection.
- Discovery feedback: with the Mac receiver stopped, Refresh should show a
  spinner, then a no-results message after five seconds. Start the receiver
  afterward and confirm it appears without another refresh. Deny Local Network
  access and confirm the denial message; grant it and refresh again. Refresh
  must not erase an unrelated photo-import or pairing error.
- Disabled Connect: show a hint when no Mac is discovered, none is selected, or
  the pairing key is empty. Whitespace alone should not enable the button.
- Mac permission feedback: after granting input control, Check Again should
  say to start the receiver; it should not retain the old permission request.
- Photo: import an upright and a rotated camera image. Compare every key center
  in alignment mode against where a touch is recognized. Verify after relaunch.
- Keyboard: letters, space, Return, Delete, arrows, held repeat, Shift+A,
  Command+A/C/V, Option and Control combinations. Test both left/right modifiers
  held together. Caps Lock should reset at session end.
- Trackpad: pointer motion, click, double-click, two-finger right click,
  two-finger scroll, hold then drag and release. Test all attached Mac displays.
- Interruptions: hold Shift or a drag, then open settings, leave the app, lock
  the iPad, disable Wi-Fi, stop the receiver, or sleep the Mac. Verify no held
  input remains after the watchdog interval; reconnect without stale presses.
- Thumb Space: compare ten short thumb taps with ten fingertip taps. Broad
  thumb taps should type on lift; a broad contact held on Space should not type
  or repeat. A normal fingertip hold should still repeat. Check near key edges
  as well as the center to distinguish alignment from contact-size filtering.
- Palm/comfort: enable Palm rejection, start at Balanced, and type with resting
  palms. Check accidental characters and pointer motion. Turn on touch indicators
  to see pending/accepted/ignored contacts; try Relaxed if valid fingertips are
  rejected and Strict if palms pass through. Record the iPad model and profile.
- Typing lockout: start a trackpad contact while typing, stop typing, and keep
  that contact down. It should remain ignored even after the pause expires.
  Lift it and place a new finger to resume. A modifier-only Shift-drag should
  work. Start typing during a drag and verify the mouse button is released.
- Growing palm: let a finger contact spread into a broad palm before and after
  its first accepted input; ensure held keys/buttons release and do not resume
  until lift. Already-posted characters cannot be retracted by the filter.
- Settings: turn Palm rejection off and back on, change sensitivity, and restart
  the app. Verify preferences persist and active input is released on changes.
- Limit: an ordinary-sized resting fingertip can resemble an intended press;
  software filtering is not equivalent to a physical keyboard or hardware trackpad.
- Responsiveness: measure touch-to-output latency on the actual Wi-Fi network;
  no latency or typing-speed claim has been measured yet.

Record Xcode, macOS, iPadOS, hardware models, keyboard input source, results,
and failures. Passing automated tests alone does not close this checklist.
