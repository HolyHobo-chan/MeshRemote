# MeshCentral Control Channel Protocol (control.ashx)

Documented from MeshCentral sources: `meshctrl.js`, `webserver.js`, `meshuser.js`.

## Transport

`wss://<server>/control.ashx` — JSON text frames, one object per frame, each with an
`action` field. No version handshake; capabilities come via `serverinfo.features*`.

## Authentication (recommended: x-meshauth header)

```
x-meshauth: base64(username),base64(password)[,base64(2fa-token)]
```

Alternatives: `?user=&pass=` query params, `?auth=<encrypted cookie>` (requires the
server's 80-byte loginCookieEncryptionKey — not practical for an app), login tokens
(username starting `~t:`, minted via `{action:'createLoginToken'}`, usable like a
user/pass pair — ideal for Keychain storage).

If the domain configures a URL access key, `?key=<value>` must be on the URL.
Send no `Origin` header (server enforces an origin/host check on browsers).

### Failure signals — `{action:'close', cause, msg}` then socket close

- `cause:'noauth', msg:'noauth*'` — bad credentials
- `cause:'noauth', msg:'tokenrequired'` — 2FA required (extra booleans: email2fa, sms2fa, msg2fa)
- `cause:'noauth', msg:'nokey'` — missing `?key=`
- `cause:'banned'` — IP banned; `cause:'notools'` — account may not use API clients
- `cause:'emailvalidation'` — email verification required

To request the server email/SMS a 2FA code, pass token `**email**` or `**sms**`.

## After connect, server pushes (in order)

1. `{action:'serverinfo', serverinfo:{ domain, name, port, serverTime, features, features2, features3, tlshash, ... }}`
2. `{action:'userinfo', userinfo:{ _id:'user/<domain>/<name>', name, siteadmin, links:{...}, ... }}`

Device list is NOT pushed — request it:

```json
{"action":"meshes"}
{"action":"nodes"}
```

- meshes → `{action:'meshes', meshes:[{_id:'mesh/<dom>/<hash>', name, desc, mtype, links:{userid:{rights}}}]}`
  - mtype: 1=AMT-only, 2=agent group, 3=local/relay, 4=IP-KVM
  - rights bits: 8=RemoteControl, 64=WakeDevice, 256=ViewOnly, 512=NoTerminal, 1024=NoFiles, 0xFFFFFFFF=full
- nodes → `{action:'nodes', nodes:{ '<meshid>': [node, ...] }}` (grouped by meshid; meshid absent inside node)
  - node: `_id`, `name`, `rname`, `host`, `icon` (int, default 1), `conn` (bitmask: 1=agent, 2=CIRA, 4=AMT local, 8=relay, 16=MQTT; 0/absent=offline), `pwr` (0 unknown, 1 powered, 2-4 sleep, 5 hibernate, 6 soft-off), `osdesc`, `ip`, `users[]`, `mtype` (3=agent device, 1=AMT), `agent:{id, ver, caps}`, `sshport`, `rdpport`, `desc`, `tags[]`

## Realtime events — `{action:'event', event:{...}}`

- `nodeconnect` — `{nodeid, conn, pwr}` update connectivity/power (primary online/offline signal)
- `changenode` — `{node}` partial node to merge
- `addnode` / `removenode` — add (event.node) / remove (event.nodeid)
- `nodemeshchange` — device moved groups
- `meshchange`/`createmesh`/`deletemesh` — re-request meshes+nodes

## Power actions

```json
{"action":"wakedevices","nodeids":["node/..."],"responseid":"x"}       // WoL (right 64)
{"action":"poweraction","nodeids":["node/..."],"actiontype":N}         // 2=off, 3=reboot, 4=sleep
```

AMT: 302=on, 308=off, 310=reset. Response `{action:'poweraction', result:'ok'}` only means accepted.

## Relay cookies

```json
{"action":"authcookie"}
→ {"action":"authcookie","cookie":"<use as relay ?auth=>","rcookie":"<use as agent tunnel rauth=>"}
```

Refresh every ~30 minutes (browser does). To open a tunnel (p: 1=terminal, 2=desktop, 5=files):

1. `{"action":"msg","nodeid":id,"type":"tunnel","usage":P,"value":"*/meshrelay.ashx?p=P&nodeid=<id>&id=<12hex>&rauth=<rcookie>"}`
2. Connect `wss://server/meshrelay.ashx?browser=1&p=P&nodeid=<id>&id=<same>&auth=<cookie>`

## Keepalive

Client may send `{"action":"ping"}` (server replies pong). If the server sends
`{"action":"ping"}`, reply `{"action":"pong"}`.
