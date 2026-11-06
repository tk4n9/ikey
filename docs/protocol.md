# Protocol v2

Status: **implemented** in `Shared/Sources/IKeyCore/WireV2.swift`,
`SecureTransport.swift`, `ConnectionSupervisor.swift` and `ReceiverArbiter.swift`.
The pieces are covered by Linux XCTests (`WireV2Tests`, `ConnectionSupervisorTests`,
`ReceiverArbiterTests`, `EndToEndTests`), and the macOS CI job typechecks both apps.
**Not yet verified on devices.** The TLS handshake runs only in
`SecureTransportLoopbackTests` on macOS. No timing below has been measured on a
real network yet.

The iPad sends physical intent: key codes, trackpad millimetres, scroll phases,
click state and gestures, each stamped with the iPad's own clock. The Mac owns
everything that a real MacBook does after the hardware: flags, the fn layer, the
top row, key repeat, Caps Lock, pointer acceleration and scroll momentum. It
answers with its settings and state.

## Transport

- Bonjour service `_ikey._tcp`. The Mac's instance name is its computer name
  (at most 48 UTF-8 bytes) followed by ` — iKey`.
- TXT record: `proto=2` and `id=<Mac UUID>`. The UUID is stored once in the Mac's
  defaults (`iKey.macID`). It identifies the Mac but does not authenticate it;
  only the TLS handshake does.
- TCP with `noDelay`, keepalive after 2 s idle, and service class
  `interactiveVoice`.
- TLS 1.2 with a 32-byte pre-shared key (PSK identity `ikey-v1`) and the suite
  `TLS_PSK_WITH_AES_128_GCM_SHA256`. Session resumption and tickets are off.
  `SecureParameters.make(secret:peerToPeer:offerForwardSecrecy:)` can also
  offer `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC) first. Both apps
  currently pass `offerForwardSecrecy: false`
  (`offerForwardSecrecyEnabled`). That changes only after the macOS loopback
  test shows the suite negotiates.
- The Mac remembers its last listening port (`iKey.listenerPort`), so a
  relaunched receiver usually comes back on the same port. If that port is busy,
  it falls back to any port. Listener restarts back off 0.5, 1, 2, then 5 s.

## Framing

Each frame is one JSON object followed by `\n`. The body is at most 8192 bytes; a
trailing `\n` or `\r\n` does not count. Every v2 frame has `"v": 2` and a kind
in `"m"`. Input, heartbeat and ping frames carry `"t"`, the sender's monotonic
clock in microseconds. Key order inside an object has no meaning.

A sender writes each batch of messages as one write. If any message in a batch
fails validation, the whole batch is dropped and the link closes with a protocol
error. Senders therefore clamp values before encoding. More than 64 KiB waiting
to be sent closes the link (`overflow`).

### iPad → Mac

| `m` | Fields | Meaning |
|---|---|---|
| `hello` | `proto`, `client` (UUID), `app`, `device`, `features` | First frame of every v2 link. |
| `key` | `t`, `code`, `down` | Physical key on the drawn deck (macOS virtual key code). |
| `button` | `t`, `button` (`left`/`right`), `down`, `cs` | Trackpad click; `cs` is the click state 1–3. |
| `motion` | `t`, `dx`, `dy`, `dt`, `sp` | Finger travel in trackpad mm over `dt` s; `sp` in mm/s. |
| `scroll` | `t`, `ph`, `dx`, `dy`, `dt`, `sp`, optional `vx`, `vy` | Two-finger scroll; `ph` is `mayBegin`, `began`, `changed`, `ended` or `cancelled`; release velocity (mm/s) on `ended`. |
| `contacts` | `t`, `n` | Fingers counted on the trackpad, 0–10. |
| `gesture` | `t`, `kind` (`swipe`/`tap`), `fingers`, optional `dir` | Three-finger swipe (`left`, `right`, `up`, `down`) or tap. |
| `releaseAll` | `t` | Release every key, button and scroll. |
| `hb` | `t`, `seq`, `held`, `buttons`, `active`, optional `confirm` | Heartbeat: what the iPad holds. `active` means a contact is on the deck. `confirm` is the iPad's key confirmation delay in seconds (0.045 with palm protection on, 0 with it off); the Mac adds it back when it times a Caps Lock press, so the thresholds count from the touch. |
| `ping` | `t`, `id` | Round-trip probe. |
| `bye` | `reason` | Goodbye; the link closes after it. |

Trackpad millimetres use trackpad axes: +x is right and +y is toward the user.
The Mac applies acceleration, natural scrolling and momentum. The iPad sends raw
travel only.

### Mac → iPad

| `m` | Fields | Meaning |
|---|---|---|
| `welcome` | `proto`, `mac` (UUID), `name`, `model` (`hw.model`), `keyboard` (`ansi`/`iso`/`jis`), optional `displayMM`, `prefs`, `caps`, `features` | Answer to `hello`. |
| `state` | optional `caps`, `prefs`, `asleep`, `tapOnly` | A change; absent fields are unchanged. |
| `pong` | `id`, `echo` (the ping's `t`), `macT` | Answer to `ping`. |
| `bye` | `reason` | Goodbye. |

`prefs` mirrors the Mac's settings (`MacInputPreferences`): `keyRepeatDelay`
(seconds, or `null` when repeat is off), `keyRepeatInterval`,
`naturalScrolling`, `trackingIndex`, `fnKeysStandard`, `doubleClickInterval`,
`threeFingerDrag`, `dragLock`, `tapToClick`, `threeFingerSwipes` and optional
`appExposeGesture`.

- `threeFingerSwipes` means the Mac's "Swipe between full-screen applications"
  swipes at iKey's swipe finger count: four fingers while `threeFingerDrag` is
  on, otherwise three. The Mac reads its horizontal swipe setting for that
  count (the vertical one only when the horizontal one is absent). Only "swipe
  between full-screen applications" counts; "swipe between pages" does not
  switch Spaces, so it reads as off. Despite the name, it can describe
  four-finger swipes. While the iPad follows the Mac, it sends swipes and the
  three-finger Look Up tap only when this is true.
- `appExposeGesture` is the Mac's App Exposé gesture (Trackpad › More Gestures),
  which is off on a new Mac. It is true only when that switch is on and the
  Mac's vertical swipe at iKey's swipe finger count is not off (macOS puts App
  Exposé on Mission Control's finger count). Absent means off. Only the Mac uses
  it: a swipe down shows App Exposé only while it is true.

`tapOnly` lists the deck modifier keys that the Mac's key remap turns into
something other than a modifier, for example `[55]` when left Command is mapped
to Caps Lock. The iPad types those keys as taps only (see
[touch behavior](touch-behavior.md#tap-only-keys)). `tapOnly` is optional:
absent leaves the iPad's set unchanged, and `[]` clears it. The Mac omits it
until its first key-remap read has finished (so the iPad keeps the set it saved
for that Mac), then sends it in every `state`, including the one right after
`welcome`.

Features (`WireFeature.all`, sent by both sides): `macRepeat`, `mmMotion`,
`scrollPhases`, `gestures`, `capsSync`, `clickState`.

Example frames:

```json
{"v":2,"m":"key","t":81234567,"code":38,"down":true}
{"v":2,"m":"scroll","t":81240000,"ph":"ended","dx":0,"dy":0,"dt":0.016,"sp":0,"vx":0,"vy":-412.5}
{"v":2,"m":"state","caps":false,"tapOnly":[55]}
```

### Validation limits

Out-of-range values make a frame invalid. The encoder refuses them and the
decoder drops the link.

- Strings (`app`, `device`, `name`, `model`, `dir`, feature names): at most 64 UTF-8 bytes.
- Lists (`features`, `held`, `buttons`, `tapOnly`): at most 32 entries.
- Key codes (`code`, `held`, `tapOnly`): only the supported macOS virtual key codes (`InputEvent.supportedKeyCodes`).
- `motion`, and `scroll` with `began`/`changed`: |`dx`|, |`dy`| ≤ 300 mm and 0 < `dt` ≤ 0.5 s.
  The other scroll phases carry no motion: `dt` only has to be finite and ≥ 0.
- `sp` 0–5000 mm/s; |`vx`|, |`vy`| ≤ 5000 mm/s.
- `cs` 1–3; `contacts` 0–10; gesture `fingers` 3–5.
- `displayMM`: two values, each > 0 and ≤ 5000.
- `prefs`: `keyRepeatDelay` 0.1–2.0 s (or `null`), `keyRepeatInterval`
  0.015–2.0 s, `trackingIndex` 0–3, `doubleClickInterval` 0.1–5 s. The Mac clamps
  what it reads from its defaults (`MacInputPreferences.clamped()`) before
  sending, so a value set with `defaults write` cannot block the handshake.
- `confirm` 0–0.25 s.
- `proto` ≥ 1.

Consecutive `motion` frames, and consecutive `scroll`/`changed` frames, may be
merged before sending (`PadInput.coalesced`). Merging never crosses any other
input and never exceeds the limits above.

### Forward compatibility

- An unknown `m` decodes as `.unknown` and is ignored. The kind name is cut to 64 bytes.
- A `bye` with an unknown reason counts as `receiverStopping`: an ordinary
  reconnect that never unpairs.
- An unknown `keyboard` value is drawn as ANSI.
- `prefs` keys that are absent keep their defaults, so either side can add settings.
- `tapOnly` is encoded only when present, and older iPads ignore it.
- `confirm` (in `hb`) is encoded only when present. Absent (an older iPad)
  leaves the Mac's value unchanged (0.045 s until an iPad states one), and older
  Macs ignore it.
- `appExposeGesture` (in `prefs`) is optional; absent means off, so an older
  Mac's `prefs` never turns App Exposé on.
- An unknown scroll phase or gesture kind is still invalid. Adding one needs a
  new feature name or a protocol bump.
- `"v"` other than 2 is `unsupportedVersion`. A frame without `"v"` but with
  `"version": 1` is a protocol v1 frame (below).

## Negotiation

1. The iPad browses Bonjour only while it is not connected. It reads the paired
   Mac's TXT `proto`. If `proto` is missing or 1, the Mac runs an old iKey, so the
   iPad shows **Update iKey on your Mac** without connecting. It retries every
   10 s, and at once when an advert with `proto=2` appears.
2. TCP and TLS must finish within 2.5 s. When TLS is ready, the PSK matched; the
   iPad sends `hello`.
3. The Mac's first frame from a connection decides its protocol:
   - A v2 `hello` promotes the session. The Mac answers at once with `welcome`
     and a `state` carrying `tapOnly`.
   - A v1 frame promotes a v1 session (below).
   - A `hello` with `proto` < 2, or any other first frame, gets
     `bye(protocolMismatch)`.
   An accepted connection that sends no promoted frame within 3 s is cancelled.
   At most 4 handshakes may be pending, and at most 2 per remote host; ports and
   interface scope are ignored, so a flood from one host cannot evict another.
4. The iPad waits 3 s for `welcome`. A missing welcome is an ordinary failure,
   never evidence of an old Mac. A link closed without a welcome less than 1 s
   after `hello` is how a v1 receiver refuses v2. Two of those in a row are
   treated as an old Mac.
5. On `welcome` the iPad adopts the Mac's settings and its Caps Lock state, and
   switches the drawn deck to the Mac's model (`hw.model`) unless the user chose
   a model by hand. If this attempt used a pasted key, the iPad saves the pairing
   now.

Protocol v1 (`{"version":1,"event":...}`) is still accepted by the Mac. A v1 iPad
build is promoted on its first v1 frame and handled by `LegacyEventInjector`
unchanged, with a 3 s silence timeout and no welcome. The current iPad app
speaks only v2. It needs a v2 Mac.

## Liveness

| Item | Cadence / limit | Where |
|---|---|---|
| Heartbeat `hb` | every 0.1 s while a contact is on the deck or any key or button is held, else every 1 s | iPad |
| `ping` | about every 1 s while connected | iPad |
| Round-trip time | p50/p95 of the last 64 pongs, in the settings panel | iPad |
| Mac silence | link closed when nothing arrives from the Mac for 2.5 s | iPad (`LinkTiming.macSilence`) |
| Dead-man | held input released when nothing arrives for 1 s while input is held | Mac (`ArbiterTiming.deadMan`) |
| Link timeout | 4 s for v2, 3 s for v1 without a frame: release and close | Mac (`linkTimeoutV2`/`V1`) |
| Repeat lease | key repeat fires only while a frame arrived within 0.25 s | Mac (`MacKeyboardConfig.lease`) |
| Caps Lock state | polled every 0.1 s; a change is sent as `state` | Mac |
| Settings | polled every 2 s while listening; a change is sent as `state` | Mac |

The heartbeat's `held` and `buttons` let the Mac reconcile. It **releases** any
key or button it holds that the iPad no longer holds. It never presses anything
and never changes the Caps Lock state. A key remapped to Caps Lock whose up was
lost is let go without switching the input source.

The 0.1 s heartbeat while touching or holding keeps the 0.25 s repeat lease
alive. A button held with no finger on the deck (drag lock) also beats every
0.1 s, so the Mac's 1 s dead-man does not drop the drag. If Wi-Fi stalls,
repeat stops within 0.25 s, and held keys are released after 1 s.

## Reconnection (iPad)

`ConnectionSupervisor` reconnects the way a built-in keyboard behaves:

- Retries follow the backoff 0, 0.1, 0.25, 0.5, 1, 1, 2, 2, then 4 s repeating. A
  link that stayed up for 5 s restarts the schedule. Coming back to the
  foreground, a network path change or a user Connect skips the wait.
- Control Center and other `.inactive` moments only release held input. The
  link stays up. Going to the background sends `bye(background)`, and returning
  reconnects.
- Goodbye reasons from the Mac:
  - `replaced` (another iPad took over) and `user` (Disconnect on the Mac) park
    the iPad until its deck is touched or the user connects.
  - `macSleeping` and `receiverStopping` retry on the backoff schedule.
  - `protocolMismatch` retries every 10 s.
  - `unpaired` (the Mac chose **New Key**) deletes the pairing.
- Repeated TLS failures against a Mac that handshook before (at least 3 failures
  spanning at least 60 s) show **Can't reach <Mac> — the pairing key may have
  changed**. The iPad keeps retrying every 10 s and keeps the pairing.
- Only **Forget this Mac** or the Mac's authenticated `bye(unpaired)` deletes a
  pairing. Failed handshakes never do.

## Sessions on the Mac

The receiver listens whenever iKey runs, unless it is paused, the Mac is asleep,
the input permission is missing or the Keychain is unavailable. The newest
authenticated session wins. Promoting a new iPad first releases everything the
old one held, then sends the old one `bye(replaced)`; its hint reads **In use by
another iPad — touch to switch**. Two failed TLS handshakes from one host show a
pairing hint in the Mac menu. Mac sleep sends `bye(macSleeping)`, and quitting
sends `bye(receiverStopping)`.

## Pairing key

The user chose to keep the key (Gate 0). Both devices store it in the Keychain,
device-only and never synced:

- **Mac:** a generic password (service `com.ikey.pairing`, account `psk`) in the
  data-protection keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
  A build without the keychain entitlement uses the login keychain instead.
  A new key is generated only when no item exists (`errSecItemNotFound`). Any
  other error leaves the receiver down with a **Retry** line, because inventing
  a key would lock out every paired iPad. An item that exists but cannot be
  decoded offers **Retry** or **New Key**.
- **iPad:** one item per Mac (service `com.ikey.pairing.v2`, account = Mac UUID),
  with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and not synchronizable.
  It is saved only after the first `welcome` with a pasted key. The iPad's
  pairing fields set no password content type, so the key is never offered to
  Passwords or iCloud Keychain AutoFill.
- The key changes only when the user chooses **New Key** on the Mac. Paired iPads
  then get `bye(unpaired)` and must be paired again.

Pasteboard hardening on the Mac: **Copy Pairing Key** writes the key with the
`org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType` markers,
so clipboard managers skip it. It is cleared when the next iPad session is
promoted, after 60 s, on **New Key** and when iKey quits, but only if nothing
else was copied in the meantime.

## Threat model

- Anyone who has the key and is on the same local network can type and click on
  the Mac. Treat the key as a credential. The key is 256 random bits, and TLS-PSK
  authenticates both ends. There is no plaintext mode, account or cloud relay.
- **No forward secrecy** with the plain PSK suite. Someone who records the
  traffic and later obtains the key can decrypt it. Forward secrecy comes only
  when the ECDHE-PSK suite is negotiated, which is currently off.
- The Bonjour name and TXT `id` can be spoofed. They only choose whom to try. A
  spoofed Mac without the key fails TLS. When several adverts claim the paired
  Mac's `id`, the iPad tries the service name remembered from the last
  successful handshake first, then one advertising `proto` ≥ 2, then the first
  one (by name); an advert without an `id` is used only when it carries the
  remembered name. The remembered name changes only after a `welcome`. A stray
  advert with `proto` 1 or none therefore cannot hold the iPad on **Update iKey
  on your Mac** while the real Mac is also advertised. Authentication failures
  never delete the pairing and count only against a host that handshook before.
- The Mac posts only events from the authenticated active session, and tags each
  one with `eventSourceUserData` 0x694B6579 ("iKey"). It never records local
  typing. The optional Deck check counts event **types** only.
- The pairing key on disk is protected only by the Keychain classes above. A
  device backup does not carry it to another device.

## Adaptive peer-to-peer

Some networks need Apple's peer-to-peer Wi-Fi (AWDL). AWDL hopping adds latency
spikes on networks that do not need it. The iPad's **Wi-Fi connection** setting
(`PeerToPeerSetting`) chooses:

- **Automatic** (default): peer-to-peer is allowed until one session over
  ordinary Wi-Fi is confirmed. After that, only ordinary Wi-Fi is used. Three
  consecutive ordinary-Wi-Fi failures allow peer-to-peer again. Authentication
  failures do not count, because they prove the path reached the Mac.
- **Always allow direct** / **Never direct**.

The Mac listener allows peer-to-peer unless its own setting is **Never direct**.
The iPad runs no Bonjour browser while connected.
