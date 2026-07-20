# MeshRemote

A native iOS management app for [MeshCentral](https://meshcentral.com). Browse your
devices, control them with remote desktop, open SSH terminals, transfer files, and
send power commands.

Built with SwiftUI. The MeshCentral wire protocols are implemented natively in Swift; the SSH
terminal uses [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

## Features

- **Servers** — Multiple Server Profiles. Have multiple mesh central servers?
  Great! You can add all of them.
- **Devices** — View all of your devices and their online/offline status.
- **Remote Desktop** — Native decoding of MeshCentral's tile protocol
  with trackpad-style controls.
- **SSH** — Full terminal emulation via the server's SSH relay, with optional
  server side credential storage
- **Files** — Browse drives/folders, download files, upload from the
  Files app, rename/delete/new folder, transfer progress
- **Power** — Wake-on-LAN, restart, sleep, power off

## Requirements

- Xcode 16 or newer (SwiftTerm's Metal renderer also needs the Metal toolchain:
  `xcodebuild -downloadComponent MetalToolchain` if Xcode asks for it)
- A MeshCentral server. SSH sessions additionally require `"ssh": true` in the
  domain section of the server's `config.json`.

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


## AI Disclosure
 
A majority of the code in this project was written using Claude AI with a human review. 
Icons and descriptions were human made. I used this project to help me learn the Swift 
language while making something genuinely useful. I personally use this app a lot and 
have found it to be a great tool to manage my homelab. Hope you enjoy!