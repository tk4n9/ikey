# Touch behaviour

Status: **implemented and unit-tested; not yet verified on a device.** The rules
below are deterministic code in `Shared/Sources/IKeyCore`:

- `KeyCommitPipeline`: which key touches type.
- `TrackpadRecognizer`: trackpad intent.
- `DeckInputEngine`: routing and palm rules.
- `InjectorCore`: the Mac side.

Every number here is a default in that code. Tuning still needs real-device
traces, so the comfort and accuracy of these values on glass is unmeasured.

Glass has no key travel and no click, and the iPad has no touch haptics. A
MacBook keyboard tells a resting finger from a press by force. On glass, the only
reliable sign of intent is a **short tap**, and the rules follow from that.

## Resting fingers in plain words

The default is **Home row**:

- **Rest anywhere.** Fingers lying on the home row (A S D F J K L ;), a thumb on
  Space and fingers on any modifier never type, however long they stay.
- **Taps type on lift.** A home-row key or Space types when you lift it within
  **0.30 s** (`TypingSettings.tapMax`) without sliding more than **4 mm**
  (`restMaxTravelMM`). A longer or sliding touch is a rest. It never types,
  repeats or posts anything, not even when you lift.
- **Slow chords on home-row keys don't fire.** Holding ⌘ and pressing S slowly
  (longer than 0.30 s) is a rest. Tap the S instead. Quick ⌘S, ⌘⇧Z and fast
  capitals work.
- **Other keys behave like a keyboard.** Number row, top row, the other letters,
  Delete, Return, Tab, the arrows and Escape go down after a **45 ms**
  confirmation (`DeckInputEngine.keyConfirmDelay`; 0 ms with palm protection off)
  and stay down until you lift. The Mac repeats them.
- **Hold-to-repeat on the home row is off.** macOS shows the accent menu for a
  held letter anyway. Space never repeats by holding. **Isolated hold** is an
  opt-in setting, off by default. When on, a home-row letter held alone past
  0.30 s presses, with no other contact on the deck since it landed. It then
  repeats and opens the accent menu. Space and modifiers never do this.

Modes (`RestingFingers`):

- **Home row** (default): A S D F J K L ; and Space are rest-capable.
- **All typing keys**: every letter, digit and punctuation key, Space and `
  are rest-capable.
- **Off**: nothing rests. Every key goes down after the 45 ms confirmation. This
  is the old behaviour and has the lowest latency. Modifiers and tap-only keys
  also go down after the 45 ms confirmation and stay down while held, so the
  lazy-modifier and tap-only rules below do not apply. The remapped left ⌘ then
  behaves like a held Caps Lock key: a long hold can trigger the macOS
  long-press Caps Lock toggle.

`tapMax` is clamped to 0.15–0.35 s. The panel's **Rest time** setting changes
it.

The latency trade-off is accepted: home-row letters and Space reach the Mac at
lift, which is the tap's duration plus the network. Other keys reach it 45 ms
after touch.

The executable specification of this policy is
`Shared/Tests/IKeyCoreTests/TypingScenarioTests.swift`. It holds about 100 test
methods and about 1,000 scripted scenarios: resting hands, thumbs and modifiers,
fast capitals, rollover at 100–140 wpm, chords and placement bursts.
`RestingFingersTests` and `KeyPipelineTests` cover the pipeline's invariants. If
this page and those tests disagree, the tests win.

## Modifiers are lazy

This section and the next two apply in the **Home row** (default) and **All
typing keys** modes. With resting fingers **Off**, a held modifier goes down
after the 45 ms confirmation and stays down until its contact lifts, placement
bursts are not detected, and tap-only keys hold like ordinary keys.

Touching ⇧ ⌃ ⌥ ⌘ or fn posts nothing at first. A modifier posts its down only
when one of these happens:

1. **A key commits while it is held.** The modifier goes down right before the
   key, in chord order, and stays down until its own contact lifts.
2. **It is tapped alone** (within 0.30 s, not during a hand placement, and no
   key committed during it). It then posts down and up. That is how a lone ⇧ or
   ⌘ tap, and the remapped left ⌘ input-source switch, reach the Mac.
3. **A trackpad action starts while it is held.** Before a click, a drag, a
   scroll, a swipe or a Look Up tap, the held modifiers are committed (`commitHeldModifiers(at:)`). So
   ⌘-click, ⇧-click, ⌥-drag (copy) and ⌥-scroll work as on a Mac. Plain pointer
   motion does not commit them.

A modifier that rests without any of these posts nothing, ever.

**Modifier timeline.** A modifier that lands up to **30 ms** after a key
(`chordTolerance`) still applies to it. A key that lands before its modifier
outside that window stays lowercase. Rollover keeps landing order. A tap queued
behind another contact's pending decision still commits in landing order.

**Settling.** A held modifier that was never posted or used starts resting
silently in these cases:

- It lands together with a hand that comes to rest.
- A key starts resting beside it, as when a thumb settles with the hands.
- It lies unused for **2 s** while at least **3** other contacts rest (the
  narrow stale rule: `staleModifier`, `staleRestingContacts`).

A modifier that has already posted stays down until its contact lifts. ⌘ held
3 s alone and then Tab still gives ⌘Tab.

## Placement bursts

When a hand is put down, several fingers land almost at once. That is a
**placement burst** when either of these lands within **0.12 s**
(`burstWindow`) and is still undecided:

- at least **3** rest-capable keys (`burstMinRestCapable`);
- at least **4** keys of any kind (`burstMinKeys`).

Modifiers and thumbs touched during a burst become **suspect**. They resolve
lazily:

- A suspect becomes an ordinary modifier again as soon as keys of its burst type
  as a roll (fast typing that happened to look like a burst).
- A suspect rests if every partner rests (a hand put down).

So a burst never produces a lone-modifier tap, or a letter from a finger that
then rests, and fast capitals keep their ⇧. A typing key that was already down
when a burst forms within 0.12 s of its landing is released at once, so a hand
put down one key off does not repeat a key.

## Tap-only keys

The Mac can remap a modifier to something that is not a modifier. The user's own
Mac maps **left ⌘ → Caps Lock**, and Caps Lock switches input source. Such a key
must type only as a **tap**:

- It never chords, never acts as a pointer modifier and, in the Home row and
  All typing keys modes, never presses when rested on. (With resting fingers
  Off it goes down after 45 ms and stays down while held.)
- Down and up are posted at lift when the tap took ≤ 0.30 s and slid ≤ 4 mm.

The Mac computes these keys from its remap (`KeyRemap.tapOnlyPadCodes`) and
sends them in `MacState.tapOnly`. The iPad adds them to its own setting
(`TypingSettings.tapOnlyCodes`). It also remembers the last list per Mac, so the
deck is right before the first message arrives. See
[key remapping](mac-first-run.md#key-remapping).

A tap-only or Space tap that overlaps a hand landing types only when a key of
that burst types too. One exception: a tap that led the burst while you were
typing (a key committed within 0.3 s before it) types, unless a thumb settles on
the thumb row within 0.15 s after its lift. That is the other thumb striking
while the typing hand returns home. A tap of at most 50 ms is a graze and posts
nothing when, within the next 50 ms, the thumb lands again on it or on Space, ⌘
or ⌥ and stays there. If that next contact is itself a tap, both type.

## Key repeat happens on the Mac

The iPad never repeats. While a key is held, the Mac repeats it with **its own**
settings (`KeyRepeat` and `InitialKeyRepeat`, sent in `prefs`):

- Only the last key pressed repeats.
- Among top-row keys, only brightness and volume repeat.
- Repeats fire only while a frame from the iPad arrived within the last
  **0.25 s** (`lease`). The iPad sends a heartbeat every 0.1 s while a contact
  is on the deck or any key or button is held (every 1 s otherwise), so a Wi-Fi
  stall stops repeat within 0.25 s instead of typing a run of characters. A
  drag-locked button with no finger on the deck keeps the 0.1 s beat too, so the
  Mac's 1 s dead-man does not drop the drag.

## Where a touch lands

- **Nearest key with 3 mm capture.** A touch in a gap still hits the nearest
  key. A touch up to 3 mm outside the outermost key edge hits that key
  (`KeyHitTester.defaultCaptureRadius`). Keys on the clipped screen edges stay
  hittable to the last pixel.
- **Touch ID is inert.** It never types Delete or F12; it opens the settings
  panel (below).
- **The trackpad wins** where its outline overlaps a key's capture area.
- A contact keeps the region it landed in, even when it slides out.

### Thumbs on Space and palm protection

**Palm protection** is on by default with **Balanced** sensitivity. Contact size
is the touch radius iPadOS reports, in points:

| Sensitivity | Largest fingertip | Largest thumb (Space, trackpad bottom) |
|---|---|---|
| Strict | 26 pt | 65 pt |
| Balanced | 32 pt | 75 pt |
| Relaxed | 40 pt | 90 pt |

- A contact larger than a fingertip is ignored on keys, except a **broad thumb
  on Space**. That types once on lift when it is lifted within 0.35 s and moved
  less than 3.5 mm.
- A contact that grows into a palm releases what it held and stays ignored until
  it lifts.
- With palm protection off, every touch is accepted at once.
- **Show touch indicators** draws each contact: yellow = checking, green =
  accepted, blue = resting, red = ignored.

## Trackpad

The trackpad is drawn at its real size, 128.2 × 80.05 mm on the 13.6-inch Air.
The recognizer works in those millimetres. The Mac applies its own tracking speed
and acceleration. It uses the live `HIDAccelCurves` of the built-in trackpad when
it can read them, and a built-in table otherwise. The Mac menu offers a
fine-tune of 0.75–1.25.

Glass cannot be pressed, so **tap to click is always on**. The Mac's own
**Tap to click** setting is not used.

| Action | How |
|---|---|
| Point | One finger slides. |
| Click | One-finger tap: lifted within 0.30 s, moved < 1.5 mm. |
| Double/triple click | The next tap lands within the Mac's double-click interval and within 1.5 mm. Click state goes up to 3. |
| Tap-drag | Tap, then touch again within 0.30 s and 6 mm and slide; lift to drop. With **drag lock** the drag stays until the next tap. |
| Three-finger drag | When the Mac uses it, three fingers drag, and swipes move to four fingers. |
| Thumb tap click | A thumb in the bottom 20 mm (click zone) tapped within 0.25 s and moved < 1.5 mm clicks. |
| Thumb tap-hold drag | Thumb tap, then put the thumb down again within 0.30 s and keep it there: the button stays down while the index finger moves, lifts and re-lands. |
| Resting thumb | A thumb lying in the click zone does nothing: no click and no scroll. A contact there counts as a thumb when it is broad or lands at least 12 mm below a finger. |
| Palm heels | A broad contact in the click zone within 25 mm of the left or right edge is always ignored. Two broad contacts in the bottom 20 mm at once are a resting hand, and both are ignored. |
| Right click | Two-finger tap within 0.3 s, both fingers moved < 1.5 mm. |
| Scroll | Two fingers slide; scrolling starts after 1 mm. A swipe in from the right edge also scrolls (no Notification Center). |

A touch-down never presses the button. Presses come only from lifts, motion or
deadlines. The old "hold still 0.38 s to drag" is no longer the default. It is
still available as the **hold to drag** drag style when **Follow Mac** is off.

With **Follow Mac** on (the default), the drag style, double-click interval and
three-finger gestures come from the Mac's trackpad settings, read every 2 s.

### Scroll and momentum

The iPad sends scroll travel in mm with its phases: may-begin, began, changed,
ended and cancelled. On ended it adds the release velocity. The Mac turns that
into a phased, accelerated pixel scroll and follows **its** natural-scrolling
setting. A flick released faster than 20 mm/s glides: the Mac generates the
momentum frames at 120 Hz until the glide drops below 1 pt/s. Touching the
trackpad again stops the glide, as it does on a MacBook.

### Three-finger gestures

Swipes use three fingers, or four while three-finger drag is on (the Mac moves
its swipes there too). With **Follow Mac** on, they run when the Mac has "Swipe
between full-screen applications" on at that finger count. "Swipe between
pages" does not switch Spaces, so a Mac set to it gets no swipes from iKey.

- **Swipe**: at least 18 mm of travel, or a flick of at least 8 mm at 150 mm/s
  or faster.
  - Left / right: switch Space (the Mac's "Move left/right a space" shortcuts).
  - Up: Mission Control.
  - Down: App Exposé, but only when the Mac's own **App Exposé** gesture is on
    (Trackpad › More Gestures; off on a new Mac) at the same finger count.
    Otherwise a swipe down does nothing, as on the Mac.
- **Tap**: three fingers within 0.3 s, moved < 2 mm: **Look Up**.

**Mission Control open state.** iKey cannot read whether Mission Control is
open, so the Mac app tracks it. A swipe up or the Mission Control key (F3) opens it.
While it is taken to be open (up to 15 s after it opened):

- pointer motion, scrolling and Spaces swipes keep it open, as when you hover
  over windows on a MacBook;
- a swipe down closes it (instead of App Exposé), and another swipe up does
  nothing, because it is already open (it restarts the 15 s);
- a key press, a click or a Look Up tap may have closed it (Escape, Return, a
  click on a window), so the next swipe up opens Mission Control again and the
  next swipe down is App Exposé (when on);
- F3 toggles it: pressed while it is taken to be open, it closes it.

While iKey is live, the deck turns off iPadOS's own three-finger editing
gestures (the undo/redo HUD, the shortcut bar and the copy/paste pinches), so
they do not appear over the trackpad. This is not yet confirmed on a device.

iKey posts the Mac's own keyboard shortcuts for these actions, read from System
Settings. A shortcut that is disabled there does nothing.

These default MacBook trackpad gestures are not implemented:

- **Notification Center**: a two-finger swipe left from the right edge. iKey
  has no edge-swipe path, so this motion is an ordinary two-finger scroll and
  goes to the app under the pointer.
- **Launchpad** (a pinch with thumb and three fingers) and **Show Desktop**
  (a spread with thumb and three fingers).
- Pinch to zoom, rotate, smart zoom and the Safari back swipe.

### Typing-aware rejection

A deck the size of a MacBook puts thumbs and palm heels close to the trackpad.
With **Pause trackpad while typing** on:

- No new trackpad contact starts for **0.35 s** after an ordinary key, or while
  one is held. A modifier alone does not pause it, so ⇧-drag still works.
- A key going down ends any scroll or drag. Fingers already on the trackpad stay
  inert until they lift.
- For **1.5 s** after typing, contacts landing in the trackpad's top **10 mm**
  band are ignored, and broad contacts within **6 mm** of its sides are ignored.
- A tap within **0.6 s** of typing moves the pointer but does not click.
- Strict sensitivity multiplies the 10 mm and 6 mm bands and the 0.6 s click
  window by 1.5; Relaxed multiplies them by 0.7.

## Opening the settings panel

Hold **one fingertip still on the Touch ID key for 0.6 s** (moving at most
4 mm). This works while connected and while disconnected. It is the only way
in, because the deck has no gear button. A second touch on Touch ID cancels the
hold. The alternative trigger, **two fingertips held for 0.8 s on the left palm
rest**, is chosen in the panel. Photo mode always uses it, because the photo
has no Touch ID key. While the pairing card covers the left palm rest, the card
has a settings button for that trigger.

While the panel or Fit & Size is open, the deck sends nothing. Everything held
is released once when it opens.

**Pause input** in the panel's header keeps the connection but stops the deck
after the panel closes, for example while you wipe the screen. Touching the
deck does not resume it. The Touch ID ring shows paused, and a hint says how to
resume: the settings gesture above (it then resumes instead of opening the
panel), or **Resume input** in the panel. A relaunch or **Forget this Mac**
also ends the pause.

## Known residuals (accepted, to tune on a device)

These come from adversarial test rounds. Each one is a heuristic edge, not a
crash:

- A lone left-⇧ graze while the hands are being put down can still post ⇧.
- A 50–60 ms modifier graze together with a bouncing finger can chord.
- A modifier landing within 30 ms after a home-row or Space tap can delay that
  tap by up to about 0.3 s.
- A thumb grazing Space while typing is in flow types a space.
- A thumb held on ⌘ for seconds without settling, followed by a click, is a
  ⌘-click. A MacBook does the same.
- With resting fingers on (Home row or All typing keys), the remapped left ⌘
  only ever **taps**. A long hold posts nothing, so the macOS "long-press Caps
  Lock toggles Caps Lock" cannot come from that key. With resting fingers Off it
  holds like a real key.
