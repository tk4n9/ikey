# First run on your Mac

Each block takes 30 seconds to two minutes of hands-on work. Downloads, first
builds and device preparation take longer; wait for them before the next block.
Skip any block you have already done.

Status: the macOS CI job builds and typechecks both apps on every push. **Neither
app has been run on a device with this version yet.** If a command or build
fails, stop and capture the first error instead of continuing.

## Build

1. **Install Xcode.** Install the newest stable Xcode for your Mac from the Mac App
   Store. Command Line Tools alone are not enough. The project targets macOS 13+
   and iPadOS 17+.

2. **Finish Xcode setup.** Open Xcode once, accept its terms and install the
   components it asks for, including iOS support.

3. **Select full Xcode.** In Terminal:

   ```sh
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   xcodebuild -version
   ```

4. **Enter the source directory.** Type `cd `, drag the outer copied `ikey`
   folder from Finder into Terminal, press Return, then:

   ```sh
   cd repo/ikey
   ls project.yml
   ```

   Later commands assume this directory.

5. **Install XcodeGen.** If `brew --version` fails, install Homebrew from
   https://brew.sh/ first. Then run `brew install xcodegen` and check with
   `xcodegen --version`.

6. **Set up stable signing (once).** Create `Config/Local.xcconfig`. Git ignores
   it, and it survives project regeneration:

   ```text
   DEVELOPMENT_TEAM = ABCDE12345
   CODE_SIGN_IDENTITY = Apple Development
   // Only if com.ikey.* is unavailable to your team:
   // IKEY_BUNDLE_ID_PREFIX = com.yourname.ikey
   ```

   Find your team ID in Xcode › Settings › Apple Accounts (Accounts in older
   versions), or at developer.apple.com. The bundle identifiers are
   `$(IKEY_BUNDLE_ID_PREFIX).mac` and `.pad`, with the prefix `com.ikey` by
   default. **Do not edit the identifier in Xcode's Signing tab.** Xcode shows the
   unexpanded variable there, and a change made there is lost when the project
   is regenerated. With every build signed by the same certificate, macOS keeps
   iKey's Accessibility grant and Keychain access. An ad-hoc signature would
   prompt again after each rebuild.

7. **Run the checks.**

   ```sh
   ./scripts/check-macos.sh
   ```

   This runs the shared tests, generates `iKey.xcodeproj` and builds both apps
   unsigned for checking. Build products stay in `~/Library/Caches/iKey`, outside
   any synced folder. If the iPad build reports that the iOS platform is missing,
   run `xcodebuild -downloadPlatform iOS` once.

8. **Open the project.** Run `open iKey.xcodeproj` and wait for indexing to
   finish. Sign in under Xcode › Settings › Apple Accounts if needed.

## Mac app

9. **Run iKeyMac.** Choose scheme `iKeyMac`, destination **My Mac**, and press
   ⌘R. A keyboard icon appears in the menu bar. iKey has no Dock icon.

10. **Allow input control.** Open the menu and choose **Allow Input Control**.
    Turn on iKeyMac in System Settings › Privacy & Security › Accessibility, then
    choose **Check Again**. If it was already on, quit and reopen iKey. **Show
    This App in Finder** reveals the exact copy to grant.

11. **Allow the Keychain and Local Network.** On first start iKey creates its
    pairing key in the Keychain. If macOS asks whether iKeyMac may use the
    "iKey pairing key" item, choose **Always Allow**. If you deny it, the menu
    shows the Keychain error with **Retry**, and iKey never invents a new key on
    its own. Allow Local Network access if macOS asks.

12. **Check the receiver.** The menu should say **Ready to pair. Copy the pairing
    key and paste it in iKey on your iPad.**

13. **Open at login (recommended).** Turn on **Open at login** in the menu. If
    macOS asks for approval, System Settings › General › Login Items opens; allow
    iKeyMac there. A login item registered from Xcode's DerivedData build moves
    when that folder is cleaned, and the menu shows a hint in that case. Copy
    the built app to /Applications for a durable login item.

## iPad app

14. **Prepare the iPad.** Connect it by USB, unlock it, accept the Trust prompt
    and select it as the run destination in Xcode. If Xcode asks, turn on
    Settings › Privacy & Security › Developer Mode on the iPad and restart.

15. **Run iKeyPad.** Choose scheme `iKeyPad`, your iPad, and press ⌘R. Allow
    Local Network access when asked. Keep the iPad in landscape.

16. **Pair once.** On the Mac choose **Copy Pairing Key** under Pairing; Universal Clipboard
    carries the key over. On the iPad, the pairing card on the left palm rest
    lists nearby Macs. Pick yours, paste the 64-character key and tap
    **Connect**. Without Universal Clipboard, choose **Show** on the Mac and type
    the key. The copied key is hidden from clipboard history and cleared from
    the Mac's clipboard after pairing or after 60 s.

17. **Test.** Open a new TextEdit document on the Mac. Tap a few letters, a
    ⇧ capital and ⌘Z. Slide one finger on the drawn trackpad, then tap to click.
    A resting hand should type nothing; see
    [touch behavior](touch-behavior.md).

18. **Check the scale.** Hold the Touch ID key (top right) for 0.6 s to open
    the settings panel, then choose **Fit & size…** and follow
    [true-scale setup](true-scale-setup.md).

From now on, the iPad reconnects by itself: after relaunches, Control Center,
the app switcher, iPad lock and Mac sleep. You never paste the key again unless
you choose **New Key** on the Mac or **Forget this Mac** on the iPad.

## The receiver is always on

The Mac app listens whenever it runs, unless one of these applies:

- it is paused;
- the Mac is asleep;
- input permission is missing;
- the Keychain cannot be read.

**Pause iKey** stops it for this session only; relaunching iKey always starts
it. While an iPad is connected, the menu shows its name and **Disconnect iPad**.
After a disconnect, the iPad waits until its deck is touched. While a session is
active and for 10 minutes after it, iKey keeps the Mac from idle sleep and itself
from App Nap. iKey input also counts as user activity, so the display stays
awake while you type only on the iPad.

## Pairing key and Keychain

- The key stays the same until you choose **New Key**. Paired iPads are then
  told to unpair and need the new key.
- **Pair another iPad…** shows Copy and Show again while one iPad is paired.
  The newest iPad that connects takes over. The previous one shows **In use by
  another iPad — touch to switch**.
- The key lives in the Mac's Keychain (device-only, never synced) and in each
  iPad's Keychain (device-only). Details:
  [protocol](protocol.md#pairing-key).
- A Keychain error shows a line with **Retry**. An item that exists but cannot
  be read also offers **New Key** to reset pairing.

## Caps Lock and input sources

A real MacBook applies Caps Lock behaviour in its keyboard driver, which posted
events bypass. iKey therefore implements it on the Mac. The **Caps Lock** setting is under
**Settings** in the menu, with an **In effect** line below it:

| Choice | Behaviour |
|---|---|
| **Automatic** (default) | **Switches input source** when the Mac's "Use the Caps Lock key to switch to and from ABC" is on and more than one input source is enabled; otherwise **Turns caps lock on**. |
| **Turns caps lock on** | The real system lock. A press shorter than 75 ms is ignored, like the hardware key; the time counts from the touch (the iPad's key confirmation delay, sent in its heartbeats, is added back). A tap of a deck modifier remapped to Caps Lock, such as this user's left ⌘, toggles Caps Lock, like the remapped hardware key's ordinary tap: with resting fingers on, the deck sends that tap's down and up together at the lift, so iKey counts it as a full press. Each change is read back. If the Mac refuses it, iKey falls back to Virtual and the In effect line reads "virtual (permission needed)". |
| **Switches input source** | A tap shorter than 0.5 s switches to the previous input source (by posting the "Select the previous input source" shortcut when it is on; `TISSelectInputSource` only when it is off or unassigned). A hold of 0.5 s or longer toggles Caps Lock. If the Mac refuses a Caps Lock change, the mode is kept and only the hold is lost: the menu says "Long-press Caps Lock toggle unavailable; input switching still works" until a later change succeeds or you change the setting. |
| **Virtual** | An iKey-only lock carried in the event flags; the system indicator does not change. |

The iPad's Caps Lock LED follows the Mac's state within about 0.1 s (Virtual
mode: the virtual lock). At the default 1:1 placement the left edge of the deck
is clipped by the screen edge, so the LED is mostly off screen; see
[true-scale setup](true-scale-setup.md#placement).

Setting up the remapped left ⌘ as an input switch:

1. Turn on "Use the Caps Lock key to switch to and from ABC" in System Settings ›
   Keyboard › Text Input › Input Sources › Edit.
2. Map left ⌘ to Caps Lock (see [key remapping](#key-remapping)).
3. Keep "Select the previous input source" (⌃Space, on by default) turned on in
   System Settings › Keyboard › Keyboard Shortcuts › Input Sources.
4. Leave **Caps Lock** on Automatic. A tap of the drawn left ⌘ then switches
   between, for example, Korean and English (not yet confirmed on a device).

How iKey switches: while the "Select the previous input source" shortcut is on,
iKey posts it (lifting any modifiers you hold and pressing them again after), so
macOS switches the input source of the app you are typing in, Korean 2-Set and
other CJKV input methods included. Only when the shortcut is off or unassigned
does iKey select the source itself with `TISSelectInputSource`. From iKey, a
background app, that can change the menu-bar icon while the focused app keeps
typing with the old source, and nothing can detect it. When such a switch lands
on a source that cannot type ASCII (Korean, Chinese, Japanese), the menu shows
"Korean, Chinese or Japanese input may not switch in the app you type in" with
where to turn the shortcut on. The line goes away once the shortcut is on.

The **Globe key** setting is described in [top row](top-row.md#globe-fn-key).

## Key remapping

Many people remap keys on the Mac. This user, for example, maps **left ⌘ → Caps
Lock** and **Caps Lock → Escape**. macOS applies remapping only to events from
real keyboards: hidutil `UserKeyMapping`, System Settings › Keyboard › Keyboard
Shortcuts › Modifier Keys, and Karabiner-Elements all act on the hardware event
stream. **Events that iKey posts bypass every one of them.** Without help, the
iPad's left ⌘ would act as ⌘ and its Caps Lock as Caps Lock, so a deck that
looks like your MacBook would behave differently. iKey therefore mirrors your
remap itself.

What it reads, every 2 s while the receiver listens:

- `hidutil property --get UserKeyMapping` (2 s timeout);
- the **Modifier Keys** settings for the **built-in** keyboard only. Settings
  for external keyboards never apply;
- Karabiner-Elements `~/.config/karabiner/karabiner.json`: the selected
  profile's simple modifications, plus the per-device entries for the built-in
  keyboard. Only one-to-one key mappings are mirrored. Complex modifications,
  pointing buttons and multi-key outputs are not.

The layers merge per key, last one wins, in this order: hidutil, Modifier Keys,
Karabiner, then iKey's manual pairs. A layer whose read fails keeps its last
good pairs, so one failed read never drops your remap.

The Mac applies the remap to every key from the iPad **first**, before
modifiers, the fn layer, the top row, Caps Lock and repeat. A key is released
with the same mapping it was pressed with, even if the remap changes in
between. The iPad keeps **drawing** the real legends (command, caps lock),
because those are the keys under your fingers.

The menu's **Key remapping** section shows:

- **Apply my Mac's key remapping** (on by default). Off sends every key as
  printed on the iPad.
- **Detected:** where the remap came from (for example "From
  Karabiner-Elements") and one line per pair, such as "Left ⌘ → Caps Lock" and
  "Caps Lock → Esc". Until the first read it says "Read while iKey is on" (the
  receiver is not listening) or "Reading this Mac's key remapping…".
- **In effect:** the pairs actually applied, plus a tap-only line such as
  "Left ⌘ acts as Caps Lock / input switch (tap only)". The "/ input switch"
  part appears when the Caps Lock mode in effect is Switches input source.
- **Extra pairs:** pick a key, a target (any editable key or **No Action**)
  and **Add**; **Remove** deletes a pair. Extra pairs override detected ones and
  apply only while remapping is on. A key mapped to itself cancels a detected
  remap.

**Tap-only keys.** When a modifier is remapped to something that is not a
modifier, the Mac tells the iPad, and the deck types that key **only as a tap**.
It never chords. With resting fingers on (Home row, the default, or All typing
keys) it never presses when rested on. A tap of the user's left ⌘ switches input
source as on the real MacBook. Holding it does nothing, so the macOS long-press
Caps Lock toggle is not available from that key. With resting fingers Off, the
key goes down after 45 ms and stays down while held, like a real Caps Lock key,
so a long hold can toggle Caps Lock. The Mac sends the tap-only list after its
first remap read, within about 2 s of the receiver starting to listen. Until
then the iPad uses the list it saved for that Mac. See
[touch behavior](touch-behavior.md#tap-only-keys).

## Optional: Deck check and Input Monitoring

**Deck check…** in the menu opens a window that counts input events on the
Mac **not** posted by iKey, for 2 minutes, by type only. It was meant to show
whether the real keyboard and trackpad register through an iPad lying on them.
iKey's own events carry a tag and are not counted. Any other device, such as an
external keyboard or mouse, would be counted, so keep them still. The check
needs **Input Monitoring** (System Settings › Privacy & Security); iKey asks when
you start it. Nothing is recorded except the counts, and **Copy result** copies
them for [device validation](device-validation.md). The everyday setup does not
need this.

**Check Top-Row Keys…** is described in [top row](top-row.md).

## Troubleshooting

- **The iPad says "Update iKey on your Mac".** The Mac runs an older iKey (protocol
  v1). Build and run the current iKeyMac. To use another Mac instead, paste its
  key in the pairing card or the panel's **Pair with another Mac** section.
- **"Can't reach <Mac> — the pairing key may have changed".** The Mac's key was
  replaced, or it is a different Mac. Copy the key again and paste it in the
  pairing card. The old pairing is kept until the new one works. If you tapped
  **Keep waiting**, the card is hidden while iKey keeps retrying; open the
  settings panel and use its **Pair again** section, which can show the card
  again or take the key directly.
- **No Mac in the pairing card.** Keep both devices on the same Wi-Fi, check
  Local Network access on both, and make sure the Mac menu says Ready.
- **Prompts after every rebuild.** Signing is ad hoc; set up `Config/Local.xcconfig`
  (block 6).

Sources: [XcodeGen](https://github.com/yonaskolb/XcodeGen),
[Homebrew](https://brew.sh/),
[Apple signing guidance](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices),
[Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device),
[Mac accessibility permission](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac).
