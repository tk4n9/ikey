# Device validation

Status: **pending. Nothing on this page has been run on a real iPad and Mac
yet**, because no iPad was available. What is verified today:

- the Linux XCTest suite (`scripts/check-linux.sh`);
- a syntax parse of every Apple source file;
- the macOS CI job, which runs the shared tests and builds and typechecks both
  apps.

None of that covers signing, the TLS handshake between two devices, posted
Quartz events, real multitouch or timing.

**XCTest geometry values are regression locks, not fidelity evidence.** Tests
such as `DeckProjectionTests` and `DeckSpecTests` pin the code to the deck
constants. Examples: the Pro 13 esc key at (−22.80, 10.64) pt and 5.18873 pt/mm.
The constants come from Apple's product renders (±0.5 mm placement). Only the
device targets G1 and G2 below show that the drawing matches a real MacBook.
The same holds for the pointer table (`PointerAcceleratorTests`) and the typing
scenarios: they lock behaviour, they do not prove feel.

Run `./scripts/check-macos.sh` first, then launch both apps from Xcode (see
[first run](mac-first-run.md)). Use a disposable TextEdit document.

## Record with every run

Copy this block into the results log at the end and fill it in:

```text
Date:
iPad model / iPadOS:            (e.g. iPad Pro 13-inch M4, iPadOS 26.1)
Mac model (hw.model) / macOS:   (e.g. Mac16,12, macOS 26.1)
Xcode:
Deck preset / finish / tone:    (e.g. air13_2025 auto, Sky Blue, +0.0 EV)
Placement:                      (offset X, offset Y mm, size %; Reference = screen-centred)
Resting fingers / Rest time:    (Home row, 0.30 s; isolated hold off)
Palm protection / sensitivity:
Wi-Fi connection setting / network: (Automatic, infrastructure or peer-to-peer)
Key remap (Mac menu):           (e.g. Left ⌘ → Caps Lock, Caps Lock → Esc, from Karabiner)
Caps Lock mode / Globe action:  (effective modes shown in the Mac menu)
Top-row strategies:             (from Check Top-Row Keys: function → strategy or 'none')
Deck check counts:              (only if the iPad lay on the MacBook)
liveCurves present:             (yes / no / unknown; not shown in the UI yet)
RTT p50 / p95 (panel):
```

## Fidelity targets

Each target is a pass/fail line for "barely notice the difference". **Implemented**
means the code path exists and is unit-tested. **Device result** stays empty
until someone measures it.

| ID | Target | Procedure | Device result |
|---|---|---|---|
| G1 | Drawn A-to-' span 190.0 ± 0.3 mm; 150 mm ruler error ≤ 0.3 mm; ID-1 card outline within ± 0.3 mm | [Scale check](#g1-scale-check) | pending |
| G2 | Position check residual ≤ 0.5 mm against distances measured on **your** MacBook (optional) | [Position check](#g2-position-check-optional) | pending |
| T1 | 0 characters in 2 min of resting hands | [Resting hands](#t1-resting-hands) | pending |
| T2 | Chords 50/50, including fast capitals | [Chords](#t2-chords) | pending |
| L1 | Immediate keys touch → post p50 ≤ 55 ms; rest keys lift → post p95 ≤ 25 ms; RTT p95 ≤ 30 ms | [Latency](#l1-latency) | pending |
| S1 | Cold launch → live ≤ 2 s; Control Center round trip ≤ 0.2 s; Mac wake → live ≤ 5 s; 0 key entries after pairing | [Session](#s1-session-continuity) | pending |
| S2 | No chrome while live | [Screenshot](#s2-no-chrome) | pending |
| P1 | 0 accidental drags in 10 min; pointer and scroll within 10% of the real trackpad at 3 speeds; scroll direction matches with natural scrolling on and off | [Trackpad](#p1-trackpad) | pending |
| K1 | ⌃ arrows, fn arrows, F10–F12, Caps Lock and input-source switching behave as on the MacBook | [Mac keys](#k1-mac-keyboard-semantics) | pending |
| M1 | Key-repeat interval jitter < 5 ms after 10 min with no iKey window open (App Nap) | [Repeat jitter](#m1-repeat-jitter) | pending |
| X1 | The macOS lock-screen password can be typed with iKey | [Lock screen](#x1-lock-screen) | **open question** |

### G1 Scale check

Fit & size › scale check (see [true-scale setup](true-scale-setup.md#fit--size)).

1. Lay a steel ruler on the 150 mm vertical and the 200 mm horizontal on-screen
   rulers. Record the error at the far end.
2. Measure from the left edge of A to the left edge of ' on the drawn keys.
   Record it. The expected value is 190.00 mm.
3. Lay an ID-1 card (85.60 × 53.98 mm) on its outline. Record Matches / bigger /
   smaller, and the Size value after any correction.

Pass: all three are within 0.3 mm with Size within 0.99–1.01.

### G2 Position check (optional)

This applies only if the iPad is actually laid on the MacBook. Before covering
the keyboard, measure the four reference distances (see
[true-scale setup](true-scale-setup.md#advanced-position-check-and-peek-check-optional)).
First nudge in the front-flush offset (+5.29 mm Pro or +5.02 mm Air with the
2022/2025 presets; see
[true-scale setup](true-scale-setup.md#laying-the-ipad-on-the-macbook-optional)).
Then enter the distances, press Apply once, and record the residual shown.
Pass: ≤ 0.5 mm. The residual measures how well the preset agrees with your
MacBook, not where the iPad lies; the peek check below and the drawn key edges
against the real ones show the registration.
Also record the peek-check alignment of the function-row gaps (aligned / off by
_x_ mm).

### T1 Resting hands

With the default Home row mode, open TextEdit. Do each of these for 30 s
(2 minutes in total):

- rest all eight fingers on the home row and a thumb on Space;
- also rest a thumb on left ⌘;
- lift the hands and put them down again every few seconds;
- rest the hands slightly off the home row.

Pass: 0 characters, no input-source switch, no ⌘ shortcut. Record anything that
appears and which contact caused it (touch indicators help).

### T2 Chords

Type each 10 times, 50 in total:

- ⌘Z
- ⌘⇧Z
- ⌘Tab with the other hand resting
- fast capitals "La", "As" and "Jad" with ⇧ overlapping the letter at 50–60 ms
  spacing
- ⌘S tapped quickly

Pass: 50/50 with the right modifiers and case. Also check that a ⌘ held for 3 s
and then Tab gives ⌘Tab.

### L1 Latency

- **RTT:** after 2 minutes of typing, read **RTT p50/p95** in the settings
  panel's diagnostics. Pass: p95 ≤ 30 ms on infrastructure Wi-Fi. Record the
  Wi-Fi setting and whether the session used peer-to-peer.
- **Touch → post:** film the iPad and the Mac's screen together in 240 fps slow
  motion, with a key-event viewer open on the Mac, for example
  Karabiner-EventViewer. For 20 presses of a non-home key such as G, count frames
  from first contact to the event appearing. Pass: p50 ≤ 55 ms. That budget is
  the 45 ms confirmation plus the network.
- **Lift → post:** in the same way, for 20 taps of a home-row key such as J,
  count from lift to the event. Pass: p95 ≤ 25 ms.

The video method has about 4 ms resolution. The display refresh of the event
viewer adds up to one frame; note the refresh rate.

### S1 Session continuity

After pairing once:

- 20 cold launches of the iPad app. Time each from the icon tap until a key
  types. Pass: every one ≤ 2 s and 0 times asked for the key.
- 10 Control Center open/close round trips while typing. Pass: typing resumes
  within 0.2 s without reconnecting. The ring never shows connecting.
- Sleep the Mac, wake it and start typing on the iPad. Pass: live within 5 s with
  no interaction.

Also record what happens after an iPad lock/unlock, an app switch, and turning
Wi-Fi off and on.

### S2 No chrome

Take a screenshot of a healthy live session. Pass: deck pixels only (no status
bar, buttons, ring or hint). An upward swipe from the trackpad's front edge
should keep iKey in front, 10 times out of 10. The panel opens after holding Touch
ID for 0.6 s (± 0.05 s), also while disconnected.

### P1 Trackpad

- Use the trackpad normally for 10 minutes, including typing pauses with thumbs
  resting on the trackpad's top edge and the palm heels on its bottom corners.
  Pass: 0 drags or clicks that you did not intend.
- Make edge-to-edge swipes at slow, medium and fast speed on iKey and on the
  MacBook's real trackpad, and compare the pointer travel. Do the same with
  scrolling a long page. Pass: within 10% at every speed.
- Check the scroll direction with natural scrolling on and off; it must match
  the real trackpad both times. Flick-scroll in Safari: the page glides, and
  touching the trackpad stops it.
- Check tap, double-tap, tap-drag, a two-finger tap (right click), thumb tap
  click, thumb tap-hold drag, and three-finger swipes (Spaces both ways, Mission
  Control open and close, App Exposé) and the three-finger tap (Look Up).

### K1 Mac keyboard semantics

- ⌃← / ⌃→ switch Spaces (or move by word where an app binds them).
- fn ← → ↑ ↓ give Home, End, Page Up and Page Down; fn Delete gives Forward
  Delete.
- F10–F12 change the volume and show the HUD; F7–F9 control media; F1/F2 change
  brightness. Run **Check Top-Row Keys** and record the strategy that works for
  every function, or 'none'.
- Caps Lock in the mode you use, and the Mac's indicator matching the iPad LED
  within 150 ms. For the remapped setup: a tap of the drawn **caps lock** key
  sends Escape.
- Input sources: a tap of the drawn left ⌘ (remapped to Caps Lock) switches
  between, for example, Korean and English, also with ⌃Space turned off in
  Keyboard Shortcuts. A long hold does nothing (accepted). A Globe tap does the
  configured action.
- Holding Delete or E repeats at the Mac's key-repeat speed. Turn Wi-Fi off
  while holding: the repeat stops within 0.25 s and the held key is released
  within 1.1 s.

### M1 Repeat jitter

Close the iKey menu and any iKey window, and use the Mac for 10 minutes so iKey
is in the background. Then hold a key in a text field for 10 s while an event
viewer that shows timestamps runs. Compute the spread of the repeat intervals.
Pass: every interval is within 5 ms of the Mac's setting.

### X1 Lock screen

Lock the Mac (⌃⌘Q) and type the password with iKey. Record whether the
characters reach the password field. This is an open question. If posted input
does not reach the lock screen, the deferred fallback is a Karabiner VirtualHID
keyboard backend; it is not implemented.

## Functional checklist

- **Permissions:** deny Accessibility and Local Network, then grant them. The Mac
  menu explains what is missing and recovers without a relaunch.
- **Pairing:** the correct key connects. A different 64-character key fails.
  Malformed text is rejected. A failed paste leaves a visible error, also when
  the iPad then reconnects to its previous Mac.
- **Keychain:** deny the Keychain prompt once. The menu shows the error with
  **Retry**, and no new key is created. After 20 relaunches of each app no key
  is pasted again.
- **A second iPad replaces the first.** The newest authenticated iPad wins. The
  first one's held keys are released before the switch. It then shows **In use
  by another iPad — touch to switch** and takes the Mac back when its deck is
  touched. (This replaces the old rule that a second iPad must not replace the
  active connection.)
- **New Key** on the Mac unpairs every iPad. They ask for the new key, and the
  copied key leaves the clipboard after pairing or after 60 s.
- **Caps Lock is the Mac's own state.** It is not reset when a session ends,
  because it lives on the Mac, as with the real key. The Mac's dead-man and
  heartbeat release held keys, but they never change the Caps Lock state. (This
  replaces the old "Caps Lock should reset at session end".)
- **Interruptions:** hold ⇧ or a drag, then open the panel, leave the app, lock
  the iPad, turn off Wi-Fi, pause the receiver, or sleep the Mac. No held input
  remains on the Mac after 1 s. Reconnecting brings no stale presses.
- **Key remap:** with the user's remap (left ⌘ → Caps Lock, Caps Lock → Esc), the
  Mac menu shows both pairs and the tap-only line. Turn **Apply my Mac's key
  remapping** off and on; the keys follow at once. Change the Karabiner profile
  and see the menu update within about 2 s.
- **Windowed or rotated:** on iPadOS 26 and later, make iKey windowed. Input
  pauses with "Make iKey full screen" and resumes in full screen. Tilting the
  iPad 45° keeps the orientation or pauses with "Turn iPad back to landscape".
- **Settings:** every setting is reachable within 2 taps from the Touch ID hold,
  and persists across a relaunch. Nudges persist too.
- **Photo mode** (optional): import a photo, align it, and check that touches land
  where the photo shows each key (see [photo setup](photo-setup.md)).
- **Discovery:** with the Mac receiver paused, the pairing card shows no Mac.
  Resume it, and the Mac appears without another refresh.

## Accepted limitations

These were decided during development and should not be filed as failures:

- No key travel, no click and no touch haptics (see
  [true-scale setup](true-scale-setup.md#what-glass-cannot-do)).
- The edge keys are clipped by about 4.4 mm (Pro) or 5.4 mm (Air) on each side,
  and the Caps Lock LED is mostly off screen. The deck is never shrunk to show
  them.
- With resting fingers on (Home row or All typing keys), the remapped left ⌘
  only taps. A long hold posts nothing, so the macOS long-press Caps Lock toggle
  cannot come from it. With resting fingers Off it holds like a real key.
- When the Mac refuses a hardware Caps Lock change:
  - In **Turns caps lock on** mode, iKey falls back to Virtual and that one
    press is lost; press again.
  - In **Switches input source** mode, only the long-press toggle is lost.
- Typing heuristics with known residuals are listed in
  [touch behavior](touch-behavior.md#known-residuals-accepted-to-tune-on-a-device).
- A swipe up while Mission Control is taken to be open (within 15 s, no other
  input) does nothing.
- The Mac's Tap to click setting is not mirrored: iKey always clicks on tap.
- US ANSI only; ISO and JIS key shapes are not drawn. No 15-inch Air preset. The
  M1 preset is an estimate.
- The forward-secret cipher suite is not offered yet (see
  [protocol](protocol.md#threat-model)).
- Pinch, rotate, smart zoom and the Safari back swipe are not implemented.

## Results log

Add one entry per session with the block above and a line per target:
`ID: pass/fail, measured value, notes`.
