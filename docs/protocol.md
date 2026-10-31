# Local input connection

The Mac advertises `_ikey._tcp` using Bonjour while the receiver is enabled.
Discovery communicates a service name and endpoint, never the pairing key. The
iPad selects that endpoint, and both apps configure the same TLS pre-shared key.
No remote command execution, screen capture, or global keyboard monitoring is
part of this protocol.

## Pairing and encryption

A new Mac app session generates 32 random bytes with Swift's system random
generator, displayed as 64 hexadecimal characters. The iPad accepts exactly this
format. Network.framework uses that secret directly for TLS-PSK authentication
and AES-128-GCM encryption. Authentication precedes `.ready`, so application
input cannot be accepted from a connection that lacks the key. There is no
plaintext fallback or certificate-verification bypass.

TLS is fixed to 1.2 because Apple's Network.framework does not support PSK in
TLS 1.3. The PSK cipher suite lacks forward secrecy; rotating the session key
limits its lifetime. This is a prototype pairing mechanism, not a completed
security audit or persistent trust system. Bonjour discovery does not establish
trust; the shared key does.

Only one pending or authenticated connection is retained. Pending handshakes
expire after eight seconds; iPad attempts expire after twelve. The iPad sends a
heartbeat every half-second; the receiver closes an inactive session after
three seconds. Timers use monotonic uptime. A lost connection, app suspension,
Stop, and explicit disconnect release held keys and mouse buttons.

## Framing

TCP carries UTF-8 JSON envelopes terminated by a newline. Each envelope has
`version: 1` and a Swift Codable `InputEvent`. For example:

```json
{"version":1,"event":{"key":{"code":0,"down":true}}}
```

Event cases: `key(code:down:)`, `pointer(dx:dy:)`, `button(button:down:)`,
`scroll(dx:dy:)`, `releaseAll`, and `heartbeat`. Button values are `left` and
`right`. Keyboard events carry physical macOS keycodes, including independent
modifier press/release events. Ordered TCP delivery preserves chord ordering.

Frames are capped at 8192 bytes. The decoder handles fragmentation/coalescing,
rejects unknown versions, invalid keycodes, nonfinite values, and movement beyond
4096 units per axis per event. Invalid input closes the connection. Pending send
data is capped at 64 KiB; backpressure closes the stream rather than dropping a
key release. Applications serialize callbacks on the main queue.

## Apple references consulted

- [Quartz events](https://developer.apple.com/documentation/coregraphics/cgevent)
- [Request permission to post events](https://developer.apple.com/documentation/coregraphics/cgrequestposteventaccess())
- [Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Building a custom peer-to-peer protocol](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol)
- [TLS-PSK limitations in Network.framework](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework)
- [UIKit touch handling](https://developer.apple.com/documentation/uikit/handling-touches-in-your-view)
