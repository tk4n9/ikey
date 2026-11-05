# iKey

Use a landscape iPad as a MacBook-style keyboard and trackpad. Import a photograph
of **your own MacBook's lower deck**, then align invisible touch regions with its
keys and trackpad. The photo is displayed with its proportions preserved.

This is an initial native implementation, not a device-tested release. Shared
Swift logic has automated tests; Apple SDK compilation, pairing, and physical
touch behavior still need verification on a Mac and iPad.

## What's implemented

- iPad photo import, local storage, full-screen landscape surface, and keyboard,
  trackpad, and individual-key calibration.
- An approximate US ANSI practice layout until you import your photograph.
- Multitouch keys and modifiers, key repeat, pointer movement, tap to click,
  two-finger right click/scroll, and hold to drag.
- Mac menu-bar receiver with explicit Start/Stop and input-control permission.
- Bonjour discovery and authenticated, encrypted TCP using a per-session pairing
  key. No account or cloud relay; no plaintext connection mode.
- Release of held keys/buttons when disconnected, suspended, or stopped, plus a
  three-second receiver watchdog.

## Build on your Mac

For small, sequential setup steps, follow the [first-run checklist](docs/mac-first-run.md).

Requirements: macOS 13+, iPadOS 17+, Xcode 15+ with iOS support, and XcodeGen 2.38+.
Newer iPads may need a newer Xcode version to run on the device. The repository
contains a project specification; the generated Xcode project is ignored.

```sh
# From this repository, not the containing local workspace:
brew install xcodegen
./scripts/generate-project.sh
open iKey.xcodeproj
```

In Xcode:

1. Select **iKeyMac**, choose **My Mac**, and run. Open the keyboard icon in the
   menu bar. Allow input control in System Settings when requested; choose
   **Check Again**, then **Start Receiver**.
2. Select **iKeyPad**. In Signing & Capabilities, select your development team;
   use a unique bundle identifier if signing requires one. Choose your connected
   iPad as the destination and run. Enable Developer Mode on the iPad if Xcode
   requests it.
3. Allow Local Network access. Keep both devices on the same Wi-Fi network.
4. On the Mac, choose **Copy Pairing Key**. On the iPad, select your Mac, paste
   the 64-character key, and choose **Connect**. You can transfer the key with
   Universal Clipboard when available. Treat it as a credential.
5. Choose a photo and align the controls, then choose **Use touch surface**.

If **Connect** is disabled, the iPad must first discover and select the Mac.
**Refresh nearby Macs** shows search progress, then a count or a no-results
message after five seconds; it continues listening for Macs started later.
The Mac must say **Ready. Connect from iKey on your iPad.** If it still asks for
input control, resolve that permission and choose **Start Receiver** first.
**Show This App in Finder** helps locate the exact Mac app to grant access to.

The Mac key changes when the app quits or when you stop the receiver and choose
**New Key**. The iPad clears the key after pairing and does not save it. Reconnect
explicitly after leaving the iPad app. The Mac build is an unsandboxed development
app using authorized input posting; App Store distribution is not configured.

## Match your MacBook

See [photo setup](docs/photo-setup.md). A specific MacBook photograph is not
bundled. Camera perspective, the crop, and screen aspect ratio determine how
closely physical dimensions match. The app does not stretch the photo to hide
differences. Import and alignment do not change the key meanings: the starting
layout is US ANSI. Keyboard input follows the Mac's active input source.

## Verify

```sh
xcrun swift test --package-path Shared --scratch-path "$HOME/Library/Caches/iKey/swift"
./scripts/check-macos.sh
```

The second command runs shared tests, generates the project, and builds both
native targets without signing (iPad simulator destination). It does not install
or launch the apps. Use the [device checklist](docs/device-validation.md) before
relying on iKey for everyday input.

Build products contain absolute paths. When sharing this source folder through
Dropbox between Macs, keep generated products outside Dropbox. The commands
above use each account's `~/Library/Caches/iKey` for Swift products and Xcode
DerivedData. The build script accepts an `IKEY_BUILD_ROOT` override if needed;
choose a local, unsynced directory. Git's `.gitignore` does not control Dropbox.
If XCTest cannot be found, select full Xcode on that Mac with
`sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.

## Source layout

```text
Apps/Mac/       menu-bar UI, receiver lifecycle, Quartz input posting
Apps/iPad/      photo surface, touch handling, calibration, connection UI
Shared/         Swift package: layout, geometry, event protocol, TLS transport
docs/           photograph guide, protocol notes, device validation
scripts/        project generation and native build checks
project.yml     XcodeGen specification for both applications
```

Limitations: glass has no physical key travel; the basic large-contact filter is
not full palm rejection. Touch ID, power, system trackpad gestures, pressure
clicks, media-key behavior, USB transport, and Bluetooth HID are not implemented.
Function keys send F1–F12 virtual keycodes. Caps Lock is session-scoped; Fn sends
a modifier flag and is not guaranteed to reproduce hardware Fn/Globe actions.
