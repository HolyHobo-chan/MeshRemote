# MeshRemote

A native iOS management app for [MeshCentral](https://meshcentral.com). Browse your
devices, control them with remote desktop, open SSH terminals, transfer files, and
send power commands — from your iPhone or iPad.

Built with SwiftUI (iOS 17+). The MeshCentral wire protocols (control channel, KVM
remote desktop, SSH relay, file transfer) are implemented natively in Swift; the SSH
terminal renders with [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## Features

- **Servers** — multiple saved servers, passwords in the iOS Keychain, self-signed
  certificate support (opt-in per server), optional 2FA code at login, and an
  optional auto-connect server that signs in as soon as the app launches
- **Devices** — live device list grouped by device group, online/offline status
  updated in realtime, search, online/offline filter
- **Remote Desktop** — native decoding of MeshCentral's tile protocol
  (JPEG/jumbo frames) with trackpad-style control: slide a finger to move the
  on-screen cursor, tap to click at the cursor, double-tap to double-click,
  two-finger tap for right-click, long-press then slide to drag, two-finger
  slide to scroll, pinch to zoom (the view follows the cursor). On-screen
  keyboard with modifier keys (Ctrl/Alt/Shift/Win), F-keys, arrows,
  Ctrl-Alt-Del, quality presets, multi-display switching
- **SSH** — full terminal emulation via the server's SSH relay, with optional
  server-side credential storage
- **Files** — browse drives/folders, download (share sheet), upload from the
  Files app, rename/delete/new folder, transfer progress
- **Power** — Wake-on-LAN, restart, sleep, power off

## Requirements

- Xcode 16 or newer (SwiftTerm's Metal renderer also needs the Metal toolchain:
  `xcodebuild -downloadComponent MetalToolchain` if Xcode asks for it)
- A MeshCentral server. SSH sessions additionally require `"ssh": true` in the
  domain section of the server's `config.json`.

## Building and installing on your iPhone

1. Open `MeshRemote.xcodeproj` in Xcode.
2. Select the **MeshRemote** target → *Signing & Capabilities* → choose your team
   (a free Apple ID works; change the bundle identifier if it collides).
3. Plug in your iPhone, pick it as the run destination, and hit **Run**.
4. On a free provisioning profile the app expires after 7 days — just build again.

First launch: tap **+**, enter your server (e.g. `server.example.com` or
`host:port`), username and password. Toggle *Allow self-signed certificate* if your
server doesn't have a public TLS certificate.

## Tests

`MeshRemoteTests` contains protocol unit tests (KVM tile/jumbo/fragment parsing) and
integration tests that run against a local MeshCentral instance:

```bash
# one-time local server setup (in a scratch directory)
npm install meshcentral
node node_modules/meshcentral --createaccount admin --pass test1234 --email a@b.c
node node_modules/meshcentral --adminaccount admin
node node_modules/meshcentral   # config: port 8443, cert localhost

xcodebuild -project MeshRemote.xcodeproj -scheme MeshRemote \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

Integration tests skip automatically when no local server is running.

## Protocol documentation

The MeshCentral wire formats this app implements are documented in [docs/](docs/):

- [protocol-control.md](docs/protocol-control.md) — auth, device list, events, power
- [protocol-desktop.md](docs/protocol-desktop.md) — KVM remote desktop byte format
- [protocol-ssh-files.md](docs/protocol-ssh-files.md) — SSH relay and file transfer

## Notes & limitations

- 2FA: a code can be entered at connect time; TOTP enrollment/push approval flows
  are not implemented.
- Intel AMT-only devices (no agent) can be woken/powered but not remote-controlled.
- App Transport Security is relaxed (`NSAllowsArbitraryLoads`) because MeshCentral
  servers frequently use self-signed certificates; certificate trust is still
  enforced per-server unless you enable the override.
