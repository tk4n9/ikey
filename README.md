# iKey

iKey turns a 13-inch iPad into the lower half of a MacBook Air: the keyboard and
trackpad for your Mac, drawn at true physical size. The yardstick: an iPad lying
on the MacBook's lower deck should be hard to tell from the real one. Sizes,
spacing, look and behaviour should all match.

**Status:** implemented, not yet verified on devices. Both apps build in CI. The
shared logic has a large XCTest suite. Typing, pointing, pairing and timing have
not been checked on a real iPad and Mac with this version. See
[device validation](docs/device-validation.md) for the targets and what is
pending.

## What's implemented

- **True-scale drawn deck.**
  - The MacBook Air 13.6-inch deck is drawn at 1 mm = 1 mm on the iPad Pro 13 and
    the iPad Air 13: every key, gap, legend and the trackpad.
  - The deck is centred on the screen and never scaled. The outermost keys lose
    about 4–5 mm to the screen edges and still work there.
  - Presets: M4/M5 (default), M2/M3, and M1 (an estimate). The deck follows the
    connected Mac's model.
  - Finishes and a tone slider, pressed-key looks, a Caps Lock LED, and a night
    look with backlit legends.
  - Fit & size has rulers, an ID-1 card outline and span checks.
  - See [true-scale setup](docs/true-scale-setup.md).
- **Resting fingers.**
  - Rest your hands anywhere; only taps type. Home-row keys and Space type on
    lift within 0.30 s. Modifiers post only when they are used.
  - Hand placements, resting thumbs and resting modifiers never type. Fast
    capitals and rollover keep their order.
  - Keys are hit by the nearest key within 3 mm.
  - See [touch behavior](docs/touch-behavior.md).
- **Trackpad.**
  - Tap to click, double and triple click, tap-drag (optional drag lock),
    three-finger drag when the Mac uses it.
  - Thumb tap click, thumb tap-hold drag, resting thumbs and palm-heel
    rejection.
  - Two-finger right click and phased scrolling with momentum.
  - Three-finger swipes (Spaces, Mission Control, App Exposé) and Look Up.
  - Typing-aware palm rejection.
- **Mac-side semantics.** Posted events bypass macOS's keyboard and trackpad
  drivers, so the Mac app reproduces what they do:
  - left/right modifier flags and the fn layer (Home, End, Page Up/Down,
    Forward Delete);
  - top-row brightness, volume, media, Mission Control and Spotlight, following
    the Mac's F-key setting;
  - key repeat at the Mac's own rate, with a liveness lease;
  - Caps Lock with its activation delay, or as an input-source switch, and the
    Globe key action;
  - pointer acceleration from the Mac's own tracking speed and curves, and
    natural scrolling and momentum;
  - the Mac's **key remapping**: hidutil, Modifier Keys and Karabiner are
    mirrored, because posted events bypass them. See
    [key remapping](docs/mac-first-run.md#key-remapping) and
    [top row](docs/top-row.md).
- **Protocol v2.**
  - Two-way messages over TLS-PSK. The iPad sends physical intent with its own
    timestamps; the Mac sends its settings and state.
  - Heartbeats release stuck keys after 1 s. Round-trip time is measured.
  - Peer-to-peer Wi-Fi is used only when needed.
  - See [protocol](docs/protocol.md).
- **Persistent pairing.**
  - You paste the pairing key once. Both devices keep it in their Keychain
    (device-only, never synced), as the user chose. If the Mac's key changes,
    the pairing card returns; the panel's pairing section also takes a new key.
  - The copied key is hidden from clipboard history and cleared after pairing.
  - The iPad reconnects by itself after relaunches, Control Center, iPad lock
    and Mac sleep. The newest iPad wins.
  - The Mac receiver is always on (with **Open at login**), keeps the Mac awake
    while in use and avoids App Nap.
- **No chrome.**
  - While connected the iPad shows only the deck. Problems show as a ring on
    the Touch ID key and a quiet hint: above the function row when there is
    room, otherwise at the top of the right palm rest (as at the default
    placement).
  - Hold Touch ID for 0.6 s to open settings, also while disconnected.
    **Pause input** there keeps the connection but ignores the deck until you
    hold Touch ID again or tap **Resume input**.
  - Edge swipes are deferred. A windowed or rotated iKey shows a scaled
    drawing and pauses input until it is full screen and in landscape again.
- **CI.** GitHub Actions runs the shared tests and an Apple syntax parse on Linux,
  and the shared tests plus a typecheck of both apps on macOS.

## What glass cannot do

Glass has no key travel and no click, and the iPad has no touch haptics. You
see and reach every key at its real size and spacing, but you cannot feel a key's
edge or its press. "Barely notice" is therefore measured by position, look and
behaviour; the [fidelity targets](docs/device-validation.md#fidelity-targets) are
numeric. Synthetic click sounds are not planned.

## Build on your Mac

Follow the [first-run checklist](docs/mac-first-run.md). Requirements: macOS 13+,
iPadOS 17+, Xcode with iOS support, and XcodeGen. The repository contains a
project specification; the generated Xcode project is ignored.

```sh
brew install xcodegen
# once: Config/Local.xcconfig with DEVELOPMENT_TEAM = <your team ID>
./scripts/generate-project.sh
open iKey.xcodeproj
```

Run **iKeyMac**, allow input control, then run **iKeyPad** on the iPad. Copy the
pairing key from the Mac menu and paste it into the pairing card on the iPad's
left palm rest. That is the only time you paste it.

## Match your MacBook

The default deck is **drawn**: model, finish and tone are chosen in the settings
panel (hold Touch ID), and the model follows the Mac automatically. Check the
size once with **Fit & size** ([true-scale setup](docs/true-scale-setup.md)).
A photo of your own MacBook is an optional skin under **Advanced**
([photo setup](docs/photo-setup.md)). It is not drawn at 1:1 scale.

The key meanings are US ANSI. Typing follows the Mac's active input source.

## Verify

```sh
./scripts/check-macos.sh          # on a Mac: shared tests + both app builds
sh scripts/check-linux.sh         # in swift:6.2-noble: shared tests + Apple parse
```

`check-macos.sh` builds both apps unsigned and does not install them. Build
products go to `~/Library/Caches/iKey`, outside any synced folder; override with
`IKEY_BUILD_ROOT`. The [device checklist](docs/device-validation.md) covers what
automated checks cannot.

## Documentation

- [First run on your Mac](docs/mac-first-run.md): build, signing, permissions,
  pairing, Caps Lock modes, key remapping.
- [True-scale setup](docs/true-scale-setup.md): placement, Fit & size, iPad
  settings.
- [Touch behaviour](docs/touch-behavior.md): resting fingers, modifiers,
  trackpad.
- [Top row and Globe key](docs/top-row.md).
- [Protocol v2](docs/protocol.md): frames, timing, pairing, threat model.
- [Device validation](docs/device-validation.md): fidelity targets and
  checklist.
- [Photo skin](docs/photo-setup.md).

## Source layout

```text
Apps/Mac/        menu-bar receiver: sessions, Keychain, preferences and remap
                 reading, Quartz event posting (EventInjector; v1 via
                 LegacyEventInjector), Caps Lock, power/App Nap
Apps/iPad/       deck surface (true-scale layers, touch glue), session model,
                 Keychain, shell, settings panel, Fit & size, pairing card,
                 photo calibration
Shared/          Swift package IKeyCore (Linux-tested):
  Sources/IKeyCore/            deck spec and projection, palette and legends,
                               DeckScene, KeyCommitPipeline, DeckInputEngine,
                               WireV2, transport, ConnectionSupervisor,
                               ReceiverArbiter, preferences
  Sources/IKeyCore/Trackpad/   TrackpadRecognizer and settings
  Sources/IKeyCore/Injection/  InjectorCore, Mac keyboard model, top row, Caps
                               Lock, pointer acceleration, scroll, gestures,
                               key remap
  Tests/IKeyCoreTests/         XCTests (TypingScenarioTests is the typing spec)
Config/          Base.xcconfig (+ your ignored Local.xcconfig for signing)
docs/            user and developer documentation
scripts/         check-linux.sh, check-macos.sh, generate-project.sh
.github/         CI workflow (Linux + macOS)
project.yml      XcodeGen specification for both apps
```

## Limitations

- **Not device-verified yet.** Everything above is implemented and tested in
  code only. Latency, the feel of the resting-finger rules and the trackpad
  heuristics need tuning on a real iPad.
- **Top row:** the brightness, volume and media strategies are implemented but
  unconfirmed. Until **Check Top-Row Keys** confirms them on your Mac, a function
  may do nothing. Standard F1–F12 always work: with fn by default, or alone when
  the Mac uses F1, F2, etc. as standard function keys (see
  [top row](docs/top-row.md)).
- **Lock screen:** whether posted input reaches the macOS login and lock screen
  is unknown.
- With resting fingers on (Home row, the default, or All typing keys), the
  remapped left ⌘ (Caps Lock / input switch) only taps, and holding it does not
  toggle Caps Lock. With resting fingers Off it presses after 45 ms and holds
  like a real Caps Lock key.
- The edge keys are clipped about 4–5 mm per side, and the Caps Lock LED is
  mostly off screen.
- Software heuristics separate rests from taps and palms from fingers. The known
  residuals are listed in [touch behavior](docs/touch-behavior.md).
- US ANSI only. The M1 preset is an estimate, and there is no 15-inch Air
  preset. Other iPads get a scaled drawing.
- Not implemented:
  - pinch, rotate, smart zoom and the Safari back swipe;
  - Touch ID and the power key;
  - force click;
  - USB or Bluetooth HID transport;
  - forward secrecy (the ECDHE-PSK suite is prepared but off).
- The Mac app is an unsandboxed development build that posts input with your
  permission. App Store distribution is not configured.
