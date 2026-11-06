# Top row and Globe key

Status: the semantics are **implemented and unit-tested**
(`Shared/Sources/IKeyCore/Injection/TopRow.swift`, `MacKeyboardModel.swift`,
`InjectorCore.swift`). **No strategy has been confirmed on a device yet.** Use
the Mac's **Check Top-Row Keys** window (below) to confirm each one once, and
record the results in [device validation](device-validation.md).

The drawn keys show the MacBook Air's icons, so they should do what the icons
show. A posted plain F-key only reaches apps as F1–F12. The keyboard driver that
turns a real top-row key into brightness or volume never sees posted events. iKey
therefore performs each function itself, on the Mac.

## Functions

| Key | Key code | Function | Default strategy chain (first usable wins) | Repeats |
|---|---|---|---|---|
| F1 | 122 | Brightness down | aux 3 (`NX_KEYTYPE_BRIGHTNESS_DOWN`) → key 145 + fn → shortcut 53 | yes |
| F2 | 120 | Brightness up | aux 2 (`NX_KEYTYPE_BRIGHTNESS_UP`) → key 144 + fn → shortcut 54 | yes |
| F3 | 99 | Mission Control | key 160 + fn → shortcut 32 → open Mission Control.app | no |
| F4 | 118 | Spotlight | key 129 → shortcut 64 | no |
| F5 | 96 | Dictation | key 176 → none | no |
| F6 | 97 | Do Not Disturb | key 178 → none | no |
| F7 | 98 | Rewind / previous | aux 20 (`REWIND`) → aux 18 (`PREVIOUS`) | no |
| F8 | 100 | Play / pause | aux 16 (`PLAY`) | no |
| F9 | 101 | Fast forward / next | aux 19 (`FAST`) → aux 17 (`NEXT`) | no |
| F10 | 109 | Mute | aux 7 (`MUTE`) | no |
| F11 | 103 | Volume down | aux 1 (`SOUND_DOWN`) | yes |
| F12 | 111 | Volume up | aux 0 (`SOUND_UP`) | yes |

The strategies are:

- **aux _n_**: a system-defined media/brightness key event (`NX_KEYTYPE_*`).
- **key _c_**: a plain key code, sent with the SecondaryFn flag where it says
  "+ fn".
- **shortcut _n_**: the Mac's current keyboard shortcut for symbolic hot key _n_,
  read from System Settings › Keyboard Shortcuts. A shortcut that is disabled or
  unassigned there is skipped.
- **open app**: launches an application.
- **none**: does nothing.

Every preset draws these icons (only the mute glyph differs between the M4/M5 and
the older legend styles) and uses the same function table. The Touch ID key is not part of the top row; it is inert and opens the iPad's
settings when held.

## fnState

macOS's **Use F1, F2, etc. keys as standard function keys** (`fnState`) is read
from the Mac and applied exactly like the real keyboard does:

| fnState | F*n* alone | fn + F*n* |
|---|---|---|
| off (default) | the function above | standard F*n* (key code with SecondaryFn) |
| on | standard F*n* | the function above |

The decision is made at the key's down. The repeat and the up reuse it, even if
fn is released in between. Only brightness and volume auto-repeat, as on the
MacBook. Standard F-keys repeat like other keys.

The fn layer on the other keys is also produced on the Mac:

- fn + ← → ↑ ↓: Home, End, Page Up, Page Down.
- fn + Delete: Forward Delete.
- fn + Return: keypad Enter.

## Choosing strategies: Check Top-Row Keys

Each function uses the first usable strategy in its chain. A choice the user
confirmed comes first, ahead of the chain. Which strategy actually works can
depend on the macOS version, so the Mac menu has **Check Top-Row Keys…**. It
opens a window with one row per function. Each row shows:

- the function and what it does under the current fnState;
- a **Try** button for every strategy in the chain, which posts that strategy
  once as a down and an up;
- a **Works** choice, which saves that strategy.

Choices are stored on the Mac (`TopRowChoices`, defaults key `iKey.topRow.v1`)
and apply immediately. A stored strategy this build does not know is ignored.
Without a choice, the chain head is used. Note for the check: Option+F11/F12
should open Sound settings on a real Mac; confirm it on yours.

## Globe (fn) key

A **tap** on fn means pressing and releasing it alone, with no other key in
between. The Mac accepts presses up to 0.5 s. With resting fingers on, though,
the deck sends a lone fn only when it was tapped within 0.30 s (see
[modifiers are lazy](touch-behavior.md#modifiers-are-lazy)). A tap performs the
Globe action:

- **Change Input Source**: switches to the previously used input source, as a
  real Globe tap does. The Mac selects the source directly (`TISSelectInputSource`).
  Only when that fails does it post the "Select the previous input source"
  shortcut (symbolic hot key 60), lifting any held modifiers around it.
- **Emoji & Symbols**: ⌃⌘Space.
- **Do nothing**.

The Mac menu's **Globe key** setting chooses one:

- **Automatic** (default): follows the Mac's own **Press 🌐 key to** setting.
  If that is unset, it uses Change Input Source when more than one input source
  is enabled, and Do nothing otherwise. Dictation cannot be posted, so a Mac set
  to Dictation gets Do nothing.
- **Change Input Source**, **Emoji & Symbols** or **Do nothing**.

Held fn still works as a modifier: for fn + arrows, fn + F-keys and fn-click.

Caps Lock and input-source switching are described in
[first run on your Mac](mac-first-run.md#caps-lock-and-input-sources).
