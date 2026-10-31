# First run on your Mac

Each block aims for 30 seconds to two minutes of hands-on work. Downloads, first
builds, device preparation, and restarts can take longer; wait for them to finish
before the next dependent block. Skip prerequisites already completed.

This prototype has not yet been built against Apple's SDKs. If a command/build
fails, stop and capture the first error rather than proceeding through the rest.

1. **Install Xcode.** Install the newest stable Xcode compatible with your Mac
   from the Mac App Store. Start the download, then wait. Command Line Tools alone
   are not enough. The project targets macOS 13+ and iPadOS 17+.

2. **Finish Xcode setup.** Open Xcode from Applications. Review/accept its terms
   and install requested components, including iOS support. Wait for completion.

3. **Select full Xcode.** In Terminal, run:

   ```sh
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   xcodebuild -version
   ```

   Expected: an Xcode version. Adjust the application path if yours differs.

4. **Enter the copied source directory.** In Terminal, type `cd `, drag the outer
   copied `ikey` folder from Finder into Terminal, and press Return. Then run:

   ```sh
   cd repo/ikey
   ls project.yml
   ```

   Keep this terminal open. Later commands assume this directory.

5. **Check Homebrew.** Run `brew --version`. If missing, install using the command
   from https://brew.sh/ and follow its printed Next steps. Wait for completion.

6. **Install XcodeGen.** Run `brew install xcodegen`, then wait. Verify with
   `xcodegen --version`.

7. **Run the shared tests.** Run `swift test --package-path Shared`. Expect
   11 XCTest tests and zero failures. The first compile may take longer.

8. **Generate the project.** Run `sh scripts/generate-project.sh`.
   Expected: `iKey.xcodeproj` appears in the current directory.

9. **Check native compilation.** Run `sh scripts/check-macos.sh`, then wait.
   It builds the Mac and iPad-simulator targets without installing them. Expect
   both builds to succeed. If they fail, capture the first error.

10. **Open the project.** Run `open iKey.xcodeproj`. Wait for Xcode to finish
    resolving/indexing the local package.

11. **Add your Apple account.** In Xcode Settings, open Apple Accounts (Accounts
    in older versions), and sign in if needed.

12. **Configure iPad signing.** Select the blue project icon, target `iKeyPad`,
    then Signing & Capabilities. Enable automatic signing and choose your team
    (Personal Team if available). If the identifier is unavailable, replace
    `com.ikey.pad` with a unique identifier such as `com.yourname.ikey.pad`.

13. **Configure Mac signing.** Select target `iKeyMac` and choose the same signing
    team. Resolve any identifier conflict in the same way. Do not regenerate the
    project after these UI changes unless you record them in `project.yml` first.

14. **Pair the iPad with Xcode.** Connect it with a data-capable USB cable, unlock
    it, and accept Trust/Allow prompts. Select it in Xcode's run-destination menu
    to initiate pairing. Wait for device preparation if requested.

15. **Enable Developer Mode.** On the iPad, open Settings → Privacy & Security →
    Developer Mode. Enable it, restart, then confirm enabling it after restart.
    If the setting is missing, complete Xcode pairing first.

16. **Run the Mac app.** In Xcode's top toolbar choose scheme `iKeyMac`, destination
    My Mac, and press Command-R. Look for the keyboard icon in the Mac menu bar.
    The first build may take longer.

17. **Allow Mac input control.** Open that icon and choose Allow Input Control.
    Enable iKeyMac in System Settings → Privacy & Security → Accessibility
    (or the input-control category named by your macOS prompt). Return to iKey
    and choose Check Again; relaunch if macOS requests it.

18. **Start the receiver.** Click Start Receiver. Allow Local Network access if
    prompted. Expected: a message saying the receiver is ready.

19. **Run the iPad app.** In Xcode choose scheme `iKeyPad`, select your physical
    iPad, and press Command-R. Allow Local Network access when asked. Wait for
    installation/device preparation. Follow any developer-trust prompt shown.

20. **Connect the two apps.** Keep both on the same Wi-Fi network. In the Mac
    menu-bar app choose Copy Pairing Key. On iPad select your Mac, paste the key,
    and tap Connect. Universal Clipboard can transfer the key when configured;
    otherwise use Show on the Mac and enter the 64 hexadecimal characters.

21. **Test before adding the photo.** On iPad tap Use touch surface. On Mac open
    a new TextEdit document. Test a few letters, Shift plus a letter, trackpad
    movement, and a tap. Expected: text/pointer responses on the Mac.

22. **Prepare the photograph.** Take one straight-down photograph of the desired
    MacBook's lower deck. Keep keyboard, trackpad, and palm rests in frame. Crop
    away the screen and desk. Leave fine photo adjustments for another block.

23. **Put the photo in iPad Photos.** Transfer it, for example with AirDrop, and
    save it to Photos. If leaving iKey disconnects it, that is expected; reconnect
    after returning.

24. **Import it.** Open iKey's gear button → Choose a photo. Select your image.
    Settings pause input; the photo stays stored locally on the iPad.

25. **Align the keyboard.** Open Align keys and trackpad with the photo. Choose
    Keyboard and adjust Left, Top, Width, and Height until the outline fits.

26. **Align the trackpad.** Choose Trackpad and adjust its outline. Tap Save.
    If validation reports an overlap, separate the keyboard and trackpad bounds.

27. **Correct one key at a time.** Reopen alignment, choose Single key, select a
    misaligned key, adjust its rectangle, and save. Repeat this block only as
    needed. Exact whole-keyboard calibration may require several blocks.

28. **Use and check cleanup.** Reconnect if necessary and tap Use touch surface.
    Test typing and clicking over the photograph. Hold Shift, open settings,
    then type normally again; the modifier should have been released.

Your first useful milestone is block 21. Photo fidelity comes afterward. Aspect
ratio differences may leave black bars; the app preserves the photo rather than
stretching it. Calibration starts from US ANSI key meanings.

Sources: [XcodeGen installation](https://github.com/yonaskolb/XcodeGen),
[Homebrew](https://brew.sh/),
[Apple signing guidance](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices),
[Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device),
[Mac accessibility permission](https://support.apple.com/guide/mac-help/allow-accessibility-apps-to-access-your-mac-mh43185/mac).
