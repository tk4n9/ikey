# Photo skin (optional)

Status: **implemented, not verified on a device.** The default deck is the
**drawn**, true-scale MacBook Air (see [true-scale setup](true-scale-setup.md)).
A photo of your own MacBook is an optional skin. It lives in the settings panel
under **Advanced › Photo mode**. Use it only if you prefer your photo to the
drawing, and expect less precision. The photo is fitted to the screen with its
proportions kept. It is **not** drawn at 1:1 physical scale, and key positions
come from your manual alignment, not from millimetre measurements.

In photo mode the same input engine runs as in drawn mode: resting fingers, lazy
modifiers, the trackpad roles and protocol v2. The differences:

- Hit testing uses the aligned regions, with a capture distance of 16% of the
  median letter-key width instead of 3 mm.
- The trackpad millimetres are derived from the aligned trackpad outline,
  assuming the 13.6-inch Air's 128.2 × 80.05 mm trackpad.
- The photo has no Touch ID key. **Hold two fingertips still on the left palm
  rest for 0.8 s** to open the settings panel.

## Take and import the photo

iKey shows the photo you import. It does not reconstruct your MacBook from its
model number.

1. Open the MacBook and photograph its lower deck from directly above, with the
   camera parallel to the keyboard. Include the keyboard, palm rests and
   trackpad; avoid the display, the desk and hands.
2. Use even light and keep the key legends readable. Correct the perspective and
   crop to the lower deck in Photos before importing; iKey has no perspective or
   crop editor.
3. Transfer the picture to Photos on the iPad. In the panel choose **Advanced ›
   Photo mode › Choose a photo**. Imports are limited to 25 MB. iKey keeps a
   display copy of up to 4096 pixels on the longest edge in private app storage.
   The photo is never sent to the Mac.
4. Open **Align keys and trackpad with the photo**. Fit the keyboard outline
   first, then the trackpad. Use **Single key** for individual corrections.
   **Save** checks that the regions lie on the image and do not overlap. If a
   moved key overlaps its neighbour, shrink it first.
5. Set **Deck** to **Photo** at the top of the Photo mode screen (importing does
   not switch it). Close the panel. The outlines disappear, leaving the photo with light
   pressed-key feedback.

The photo and the touch regions use the same aspect-fit rectangle, including any
black bars, so alignment holds across screen sizes. If the photo's aspect ratio
differs from the screen's, some screen area stays unused.

The layout is US ANSI. Alignment moves regions; it does not add keys or change
their meanings.

The photo and alignment persist between launches. Set **Deck** back to
**Drawn MacBook** to return to the drawn deck; the photo is kept. **Remove
imported photo** deletes it; photo mode then shows an approximate practice
layout. **Reset to approximate
US MacBook layout** inside the alignment screen resets the regions when you save;
it keeps the photo.
