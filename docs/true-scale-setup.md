# True-scale setup

Status: the geometry is **implemented and locked by XCTests**
(`DeckProjectionTests`, `DeckSpecTests`, `KeyHitTesterTests`). Those tests lock
the code to the deck constants. They do not show that the constants match a real
MacBook. **On-device checks are pending**, because no iPad was available while
this was built. The Fit & Size screen described here is new, and its exact
wording may still change.

## What "true scale" means here

1 mm on the iPad is 1 mm of a MacBook Air 13.6-inch (M4/M5) lower deck. That
holds for:

- each key's width and height, and every gap between keys (1.52 mm);
- the half-height arrows, and the legends;
- the 19.00 mm column pitch and 18.50 mm row pitch;
- the distance from the keyboard to the trackpad (5.29 mm from the trackpad's
  top edge to the space bar);
- the 128.2 × 80.05 mm trackpad, and the palm rests.

The deck is a rigid body. On a supported 13-inch iPad it is **never scaled to
fit**: placement only moves it. The scale is one points-per-millimetre value,
taken from the screen's real width:

| iPad | Active screen (mm) | Points (landscape) | pt per mm |
|---|---|---|---|
| iPad Pro 13-inch (M4, M5) | 265.19 × 199.14 | 1376 × 1032 | 5.18873 |
| iPad Air 13-inch (M2, M3) | 263.27 × 197.61 | 1366 × 1024 | 5.18859 |

The iPad is recognised by its model identifier, then by its native pixels.
2732 × 2048 also matches the older 12.9-inch iPad Pros, which have nearly the
same screen width. **Fit & size** offers a manual override.

Any other iPad, a windowed iKey (Stage Manager, Slide Over) or a portrait screen
gets a scaled **fitting** drawing with a hint at the top of the screen:

- Unknown iPad: "This iPad isn't a 13-inch model — drawing is scaled". The deck
  stays usable.
- Windowed: "Make iKey full screen". Input pauses.
- Rotated: "Turn iPad back to landscape". Input pauses.

Deck presets:

| Preset | MacBook | Notes |
|---|---|---|
| `air13_2025` (default) | MacBook Air 13.6" M4, M5 | Modern legends. The same geometry as 2022. |
| `air13_2022` | MacBook Air 13.6" M2, M3 | Legacy legends. |
| `air13_2020` | MacBook Air 13.3" M1 | **Estimate**: half-height function row; deck 212.4 mm deep instead of 215.0 mm. |

The Mac reports its model (`hw.model`) when it connects. The deck follows it
unless you picked a model by hand. A 15-inch Air is wider than any 13-inch iPad
and has no preset.

## Placement

The iPad is meant to be used on its own, as the MacBook's lower deck. Lying it
on the MacBook is a thought experiment that sets the fidelity yardstick; you do
not have to do it. The default placement is therefore **screen-centred**:

- **Horizontally** the key field is centred. It is 273.98 mm wide, wider than
  the screen, so the outermost keys are clipped equally on both sides: **4.4 mm**
  per side on an iPad Pro 13 and **5.4 mm** on an iPad Air 13. The clipped keys
  (esc, \`, tab, caps lock, left shift and fn on the left; Touch ID, delete,
  backslash, return, right shift and → on the right) still respond right up to
  the screen edge. Most of the Caps Lock LED falls outside the screen.
- **Vertically** the span from the top of the function row to the bottom of the
  trackpad (194.79 mm) is centred. The whole function row and the whole trackpad
  are visible, with about **2.05 mm** to spare at the top and bottom on the Pro
  and **1.28 mm** on the Air. On the M1 preset the span is shorter and the
  margins larger. If a span ever does not fit, the function row stays fully
  visible and the trackpad bottom is clipped.

Nudges move the deck relative to this default:

- left/right ±5 mm;
- up/down ±8 mm (±12 mm for the M1 estimate);
- size ±1%, a small calibration (0.99–1.01). This is the only change of size.

## Fit & size

Open the settings panel by holding the Touch ID key for 0.6 s, then choose
**Fit & size…**. The panel covers the deck, and input is paused while it is
open.

1. **Your MacBook and iPad.** Check the model (Auto shows the detected one), the
   finish and the detected iPad.
2. **Scale check.** This is the important part, and it works at any placement.
   - Hold a ruler against the on-screen **150 mm** (vertical) and **200 mm**
     (horizontal) rulers. They should agree within 0.3 mm.
   - Lay a bank or ID card (ID-1, 85.60 × 53.98 mm) on its outline on the
     trackpad. Answer **Matches**, **Card is bigger** or **Card is smaller**. The
     last two reveal the **Size** control: adjust in 0.05% steps until it
     matches.
   - The highlighted spans should measure **190.00 mm** from the left edge of A
     to the left edge of ', and **228.00 mm** from \` to =.
3. **Nudge** if you want the deck slightly elsewhere: the arrow pad moves it
   0.1 mm per tap and 0.5 mm per repeat when held; **Reset** returns to centre.
   Changes are saved 250 ms after the last one and when you tap **Done**.
4. **Tone.** Adjust the slider (−0.5 to +0.5 EV) until the drawn aluminium
   matches your MacBook's in the same light.
5. **Done** returns to the deck. Everything that was held is released once.

The footer states where the preset's numbers come from. The key grid was
measured from Apple's orthographic M4 render scaled to the 304.1 mm width. The
placement of the key field, keyboard well and trackpad is ±0.5 mm. Corner radii
are approximate.

### Advanced: position check and peek check (optional)

These two checks compare the drawing with a real MacBook. They matter only if
you actually lay the iPad on the MacBook. They are collapsed by default.

**Position check: measure before covering the keyboard.** Measure these on your
MacBook with a ruler, then enter them:

| Distance | 2022/2025 preset | M1 estimate |
|---|---|---|
| Front edge to trackpad front edge | 5.08 mm | 6.00 mm |
| Front edge to space bar bottom edge | 90.42 mm | 90.42 mm |
| Left side to A key left edge | 48.31 mm | 48.31 mm |
| Left side to trackpad left edge | 87.95 mm | 92.05 mm |

**Apply** shifts the deck by the average disagreement on each axis, and shows
what remains. The shift corrects only the difference between the preset and
your MacBook; it does not know where the iPad lies. So on a MacBook that matches
the preset, Apply moves nothing. Before Apply, nudge in the front-flush offset
described under [Laying the iPad on the MacBook](#laying-the-ipad-on-the-macbook-optional).
The residual measures how well the preset agrees with your MacBook, not where
the iPad lies. A residual above 1 mm means your MacBook differs from the preset,
so check the model picker. Apply is repeatable: it always starts from the
placement you had before the first Apply. The measurements are kept on the iPad.

**Peek check.** Tap **Start peek check** and slide the iPad toward you by the
distance shown: 10 mm, or less near the end of the nudge range (8 mm from the
default placement on the 2022/2025 presets). Tick marks for the function-row
gaps appear at the iPad's top edge. Nudge left/right until they line up with
the real gaps visible behind the iPad, then slide back and tap **I slid it
back**.

### Laying the iPad on the MacBook (optional)

If you do try the physical overlay:

- Open the lid. Lay the iPad screen up, centred left-right, with its front edge
  flush with the MacBook's front edge. Equal aluminium strips should show on
  both sides: about **11.3 mm** with an iPad Pro 13 and **11.7 mm** with an iPad
  Air 13. The 2022/2025 deck is 215.0 mm deep; the M1 deck is 212.4 mm.
- The screen-centred drawing sits higher than the front-flush registration:
  **5.29 mm** (Pro) or **5.02 mm** (Air) with the 2022/2025 presets, and about
  **8.2 mm** (Pro) or **8.0 mm** (Air) with the M1 estimate (within its ±12 mm
  range). Nudge the deck down by that much first (**Move deck down**, +Y). The
  position check cannot do this for you: it corrects only the difference
  between the preset and your MacBook, after the nudge.
- **Touch ID corner:** the real Touch ID / power key sits under the iPad's
  top-right corner. Pressing hard there can lock or sleep the Mac. Hold the
  drawn Touch ID key gently.
- **Lid sensor:** the iPad's magnets can trigger the MacBook's lid sensor and
  sleep the Mac. No software can prevent that. Try **Flip 180°** in the panel's
  Advanced section, or a few millimetres of offset. Result: not tested. The
  physical checks planned before development (Gate 0) were dropped, because the
  overlay is not used physically.
- Whether the real keys or trackpad register presses through the glass is
  unknown. The Mac's **Deck check** measures it (see
  [first run](mac-first-run.md#optional-deck-check-and-input-monitoring)).

## Recommended iPad settings

- **True Tone** on and **Auto-Brightness** on, so the deck's colour and
  brightness follow the room. Set **Keyboard glow** to Auto: in a dim room
  (screen brightness below 0.3), the deck darkens and its legends light up like
  the backlit keys.
- Settings › Multitasking & Gestures: turn off the **four- and five-finger
  gestures**, so hands on the deck do not switch apps.
- Optional: **Guided Access** (Settings › Accessibility) locks the iPad to iKey
  and blocks the edge gestures completely.
- A **matte screen protector** reduces glare and makes the glass feel less
  slippery. Check touch accuracy again after fitting one.
- Keep the iPad in landscape. iKey asks iPadOS to lock the orientation while it
  is connected. If the deck still rotates, input pauses until you turn it back.

## What glass cannot do

Glass has no key travel and no click, and the iPad has no touch haptics. You can
see where every key is and feel its exact size and spacing in your hand
movements, but you cannot feel a key's edge or its press. iKey makes up for it
in behaviour: resting fingers do not type, the trackpad clicks by tapping, and
the Mac repeats keys with its own timing. The parts that can be measured (size,
position, look, timing) are listed in [device validation](device-validation.md).
