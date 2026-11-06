# True-scale setup

Status: the geometry is **implemented and locked by XCTests**
(`DeckProjectionTests`, `DeckSpecTests`, `KeyHitTesterTests`). Those tests lock
the code to the deck constants. They do not show that the constants match a real
MacBook. **On-device checks are pending**, because no iPad was available while
this was built. The Fit & size screen described here may still change after device
testing.

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
gets a scaled **fitting** drawing with a quiet hint:

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
**Fit & size…** (under **Your MacBook**). It covers the deck, and input is
paused while it is open. If the deck shows a photo, Fit & size offers **Use the
drawn deck** instead, because only the drawn deck is true to scale.

1. **Pickers** (left panel). **MacBook** (Auto shows the detected model),
   **Finish**, and **iPad** (Auto shows the recognised iPad).
2. **Scale check.** This is the important part, and it works at any placement.
   - Hold a ruler against the drawn **200 mm** ruler (under the home row, zero
     at the left edge of A) and the **150 mm** ruler (beside the trackpad). They
     should agree within 0.3 mm.
   - Lay a bank or ID card (ID-1, 85.60 × 53.98 mm) on its outline on the
     trackpad. Answer **Matches**, **Card is bigger** or **Card is smaller**.
     The last two reveal **Size −** and **Size +**, which change the size in
     0.05% steps (99–101%) until the outline meets the card's edges.
   - The orange spans should measure **190.00 mm** from the left edge of A to
     the left edge of ', and **228.00 mm** from \` to =.
3. **Nudge** if you want the deck slightly elsewhere. The arrow buttons on the
   trackpad move it 0.1 mm per tap and 0.5 mm per repeat while held. The readout
   shows the shift (→ right, ↑ up) and the size.
   - **Reset** moves the deck back to the centre, sets Size back to 100%, clears
     the card answer and removes the correction of any earlier position-check
     **Apply**. Measured distances are kept.
   - Changes are saved 250 ms after the last one and when you tap **Done**.
4. **Tone** (right panel). Move the slider (−0.5 to +0.5 EV) until the drawn
   aluminium matches your MacBook's in the same light.
5. **Done** returns to the deck. Everything that was held is released once.

The footer of the left panel states where the preset's numbers come from. The
key grid was measured from Apple's orthographic M4 render scaled to the
304.1 mm width. The placement of the key field, keyboard well and trackpad is
±0.5 mm. Corner radii are approximate.

### Compare with your MacBook (optional)

This collapsed group at the bottom of Fit & size's left panel compares the
drawing with a real MacBook. It matters only if you actually lay the iPad on
the MacBook; everyday use does not need it. While it is open, blue lines show
the preset's reference distances, with your measurements next to them. Work
through it in this order:

1. **Measure before covering the keyboard.** Measure these with a ruler:

   | Distance | 2022/2025 preset | M1 estimate |
   |---|---|---|
   | Front edge to trackpad front edge | 5.08 mm | 6.00 mm |
   | Front edge to space bar bottom edge | 90.42 mm | 90.42 mm |
   | Left side to A key left edge | 48.31 mm | 48.31 mm |
   | Left side to trackpad left edge | 87.95 mm | 92.05 mm |

2. **Lay the iPad on the MacBook.** Open the lid. Lay the iPad screen up,
   centred left-right, with its front edge flush with the MacBook's front edge.
   Equal aluminium strips should show on both sides: about **11.3 mm** with an
   iPad Pro 13 and **11.7 mm** with an iPad Air 13.
3. **Tap Nudge in the front-flush offset.** The default drawing is screen-centred,
   so it sits higher than an iPad lying front-flush: by **5.29 mm** (Pro) or
   **5.02 mm** (Air) with the 2022/2025 presets, and about **8.2 mm** (Pro) or
   **8.0 mm** (Air) with the M1 estimate. The button moves the deck down by
   exactly that amount and then reads **Front-flush offset is in**. It replaces
   your own nudges but keeps the correction of an earlier Apply. The position
   check cannot do this step for you.
4. **Position check…** Enter your measurements and tap **Apply**. Apply shifts
   the deck by the average disagreement on each axis and shows the largest
   disagreement left. It corrects only the difference between the preset and
   your MacBook, not where the iPad lies, so on a MacBook that matches the
   preset it moves nothing. Above 1 mm, your MacBook probably differs from the
   preset, and the model picker appears. Apply is repeatable: each Apply first
   removes the previous Apply's correction, and nudges you made before or after
   it are kept. The size is never changed. The measurements stay on the iPad.
5. **Peek check.** Tap **Start peek check** and slide the iPad toward you by the
   distance shown: 10 mm, or less near the end of the up/down range (for
   example 8 mm from the default placement on the 2022/2025 presets; the full
   10 mm once the front-flush offset is in). Red marks for the function-row gaps
   appear at the iPad's top edge. Nudge ◀ ▶ until they line up with the real
   gaps behind the iPad, then slide the iPad back and tap **I slid it back**.

To start over, tap **Reset**, then begin again at step 3.

Things to know about the physical overlay:

- **Touch ID corner:** the real Touch ID / power key sits under the iPad's
  top-right corner. Pressing hard there can lock or sleep the Mac. Hold the
  drawn Touch ID key gently.
- **Lid sensor:** the iPad's magnets may trigger the MacBook's lid sensor and
  sleep the Mac. Try **Flip 180°** in the panel's Advanced section, or a few
  millimetres of offset. Not tested.
- Whether the real keys or trackpad register presses through the glass is
  unknown. The Mac's **Deck check** counts them (see
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
