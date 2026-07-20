# MeshCentral SSH + Files Wire Protocols

Documented from MeshCentral sources: `apprelays.js`, `views/ssh.handlebars`,
`views/default.handlebars`, `agents/meshcore.js`, `meshdevicefile.js`, `webserver.js`.

## SSH (sshterminalrelay.ashx)

The MeshCentral *server* is the SSH client (runs ssh2 internally); our app only speaks
a small JSON + `~` text protocol. Registered only when `domain.ssh === true` in the
server config — connection failure here usually means SSH isn't enabled server-side.

Connect:

```
wss://<server>/sshterminalrelay.ashx?browser=1&p=11&nodeid=<nodeid>&id=<tunnelid>&auth=<authcookie>
```

Requires MESHRIGHT_REMOTECONTROL (8) and not MESHRIGHT_NOTERMINAL (0x200).

Message flow (all text frames):

1. Server immediately sends one of:
   - `{"action":"sshauth"}` — need username+password (or key)
   - `{"action":"sshauth","askkeypass":true}` — stored key; need passphrase only
   - `{"action":"sshautoauth"}` — stored creds exist; just send terminal size
2. Client replies:
   - `{"action":"sshauth","username":u,"password":p,"keep":0|1,"cols":c,"rows":r,"width":w,"height":h}`
   - or `{"action":"sshautoauth","cols":..,"rows":..,"width":..,"height":..}`
   - or `{"action":"sshkeyauth","keypass":..,"cols":..,...}`
3. On success server sends the single character **`c`** — terminal is live.
   On failure: `{"action":"autherror"}`, `{"action":"sessiontimeout"}`, or `{"action":"connectionerror"}`.
4. Terminal data both directions: text frames prefixed with `~` (strip/prepend the first char).
5. Resize: `{"action":"resize","cols":..,"rows":..,"width":..,"height":..}`.
6. Keepalive: reply to `{"ctrlChannel":"102938","type":"ping"}` with `{"ctrlChannel":"102938","type":"pong"}`.

`keep:1` asks the server to store the credentials on the node for next time
(honored unless `domain.allowsavingdevicecredentials` is false). SSH port comes from
`node.sshport` (default 22).

## Files (meshrelay.ashx p=5)

End-to-end with the agent through a transparent relay. Open exactly like desktop
(tunnel msg + relay ws, wait `c`/`cr`, send text `"5"`). After handshake, JSON commands
are sent as **binary** UTF-8 frames starting with `{`; any inbound frame whose first
byte is not `{` (0x7B) is download chunk data.

### Directory listing

```json
→ {"action":"ls","reqid":1,"path":""}
← {"path":"","reqid":1,"dir":[{"n":"C:\\","t":1,"s":..,"f":..,"dt":"FIXED"}, ...]}
```

Entry types `t`: 1=Windows drive (`dt` type, `f` free bytes), 2=directory, 3=file.
Fields: `n` name, `s` size bytes, `d` modified date (ISO string or epoch seconds).
Empty path on Windows = drive list; on other OSes use `/`. `dir:null` = unreadable path.

### Download (relay flow)

```json
→ {"action":"download","sub":"start","id":<rand>,"path":"<full path>"}
← {"action":"download","sub":"start","id":<id>}          (or sub:"cancel" on error)
→ {"action":"download","sub":"startack","id":<id>}        (agent primes 8 chunks)
← binary chunks: 4-byte BE header (0x01000000, final=0x01000001) + ≤16380 payload bytes
→ {"action":"download","sub":"ack","id":<id>}             (after each non-final chunk)
→ {"action":"download","sub":"stop","id":<id>}            (cancel)
```

Check only bit 0 of the header for EOF.

### Upload

```json
→ {"action":"upload","reqid":N,"path":"<dir>","name":"<file>","size":S,"append":false}
← {"action":"uploadstart","reqid":N}    (or "uploaderror")
→ binary chunks ≤65536 bytes; if chunk starts with 0x7B or 0x00, prepend a 0x00 escape byte
← {"action":"uploadack","reqid":N}      (send next chunk on each ack; prime 8 initially)
→ {"action":"uploaddone","reqid":N}
← {"action":"uploaddone","reqid":N}
```

Cancel: `{"action":"uploadcancel","reqid":N}` (agent deletes partial file).

### Management

```json
{"action":"mkdir","reqid":1,"path":"<full path>"}
{"action":"rm","reqid":1,"path":"<dir>","delfiles":["name"],"rec":false}
{"action":"rename","path":"<dir>","oldname":"a","newname":"b"}
{"action":"copy"|"move","reqid":1,"scpath":"<src dir>","dspath":"<dst dir>","names":[..]}
```

Most mutations get no reply — re-list the directory. Agent may push `{"action":"refresh"}`.

### HTTPS download alternative (devicefile.ashx)

`GET https://<server>/devicefile.ashx?c=<authcookie>&m=<meshid part3>&n=<nodeid part3>&f=<urlenc path>`
streams the raw file — no relay needed. Good for simple downloads.
