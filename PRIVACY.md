# Privacy Policy

_Last updated: July 25, 2026_

MeshRemote is a native iOS client for [MeshCentral](https://meshcentral.com)
servers that you or your organization operate. This policy explains how the app
handles your information. In short: **MeshRemote does not collect, transmit, or
sell any of your data.** There is no developer-operated backend — the app talks
only to the MeshCentral server(s) you configure. Also, this is an unofficial
project and is not affiliated with the MeshCentral. No source code from 
MeshCentral is contained within this project.


## Information the app stores

All information you enter stays **on your device**:

- **Server profiles** — the server address, username, and connection options you
  add are saved locally in the app's storage.
- **Credentials and keys** — passwords, session cookies, login tokens, SSH
  credentials, and domain login keys are stored in the **iOS Keychain**, the
  system's encrypted credential store. They are never sent anywhere except,
  where required to authenticate, directly to the MeshCentral server you chose.

None of this is uploaded to the developer or any third party. Deleting a server
profile removes its stored credentials, and deleting the app removes all of it.

## Information sent over the network

MeshRemote communicates **only** with the MeshCentral server addresses you enter.
This includes login requests, the device list, remote desktop, terminal, SSH,
file transfers, and power commands. That traffic goes directly between your device
and your server; it does not pass through any service operated by the developer.

How your MeshCentral server itself handles data is governed by that server's own
configuration and the policy of whoever operates it.

## What the app does NOT do

- No analytics, telemetry, or usage tracking.
- No advertising and no advertising identifiers.
- No third-party tracking SDKs.
- No collection of contacts, location, photos, or browsing history.
- No sale or sharing of personal information.

## Third-party components

The app bundles the open-source [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
library for terminal rendering. It runs entirely on your device and does not
collect or transmit data.

## Children's privacy

MeshRemote is a system-administration tool and is not directed at children under 13.

## Changes to this policy

If this policy changes, the updated version will be posted at this same location
with a revised "Last updated" date.

## Contact

Questions about this policy can be raised via the project's issue tracker:
<https://github.com/HolyHobo-chan/MeshRemote/issues>
