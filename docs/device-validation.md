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
- Palm/comfort: type with resting fingers and palms. Record accidental touches,
  missed keys, and whether the layout fits physically. This is an experiment;
  the basic large-contact filter is not equivalent to a hardware trackpad.
- Responsiveness: measure touch-to-output latency on the actual Wi-Fi network;
  no latency or typing-speed claim has been measured yet.

Record Xcode, macOS, iPadOS, hardware models, keyboard input source, results,
and failures. Passing automated tests alone does not close this checklist.
