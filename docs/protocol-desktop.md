# MeshCentral Remote Desktop (KVM) Wire Protocol

Documented from MeshCentral sources: `public/scripts/agent-desktop-0.0.2.js`,
`public/scripts/agent-redir-ws-0.1.1.js`, `meshrelay.js`, `meshdesktopmultiplex.js`.

All multi-byte integers are **big-endian**. Every KVM command has a 4-byte header:
`command: u16` + `size: u16` where size is the total length including the header.

## Opening a session

Viewer WebSocket:

```
wss://<host>/meshrelay.ashx?browser=1&p=2&nodeid=<nodeid>&id=<tunnelid>&auth=<authCookie>
```

- `id` — random client-generated tunnel id (e.g. random base36 string). Both ends use the same id.
- `p` — relay usage: 1=terminal, **2=KVM desktop**, 5=files, 6=admin PowerShell, 8=user shell.
- `auth` — server-issued auth cookie.

Then ask the control channel to make the agent dial the other end:

```json
{ "action": "msg", "type": "tunnel", "nodeid": "<nodeid>",
  "value": "*/meshrelay.ashx?p=2&nodeid=<nodeid>&id=<tunnelid>&rauth=<rcookie>",
  "usage": 2 }
```

`rauth` is the relay cookie (`rcookie` from serverinfo/logincookie).

### Handshake

1. Wait for a **text** frame `"c"` (connected) or `"cr"` (connected + session being recorded).
2. Send optional options JSON (text), then send the protocol number as **text**: `"2"`.
3. Binary KVM data now flows both ways.

### Framing on receive

- Text frames: JSON control channel (`ctrlChannel: 102938`) — handle `rtt` echo, `ping`→`pong`, `console`, `metadata`.
- Binary frames: `cmd = u16[0]`, `cmdsize = u16[2]`.
  - **Jumbo (27):** if `cmd==27 && cmdsize==8`, real size = `u32[4]`, then drop the 8-byte
    wrapper; the rest is a normal command (own 4-byte header) processed with the real size.
  - If `cmdsize != frame length` accumulate fragments until complete.

## Server → client commands

| Cmd | Meaning | Payload after header |
|----|---------|----------------------|
| 3  | Tile | `x:u16, y:u16`, then a complete JPEG/PNG/WebP image drawn at (x,y) |
| 7  | Screen size | `width:u16, height:u16` — reset framebuffer |
| 11 | Displays | `count:u16`, count×`id:u16`, `selected:u16` (65535 = all) |
| 12 | SetDisplay ack | — |
| 17 | Console message | UTF-8 string |
| 18 | Keyboard LED state | `u8` bitmask 1=Num 2=Scroll 4=Caps |
| 65 | Alert/error | string (leading '.' = quiet log) |
| 82 | Display geometry | 10-byte records: `id,x,y,w,h` (u16 each) |
| 87 | Input lock state | `u8` locked |
| 88 | Cursor shape | `u8` cursor index |

## Client → server commands

| Cmd | Meaning | Layout (after 4-byte header) |
|----|---------|------------------------------|
| 1  | Key | `action:u8` (0=down,1=up,3=ext-up,4=ext-down), `vk:u8` (Windows VK codes) |
| 2  | Mouse | `0x00:u8, buttons:u8, x:u16, y:u16` (size 10); wheel adds `delta:i16` (size 12, buttons=0) |
| 5  | Compression | `type:u8` (1=JPEG,4=WebP), `quality:u8` (1-100), `scaling:u16` (1024=100%), `frameTimer:u16` ms |
| 6  | Refresh | — (server resends all tiles) |
| 8  | Pause | `u8` 1=pause 0=unpause |
| 10 | Ctrl-Alt-Del | — |
| 11 | Get displays | — |
| 12 | Set display | `display:u16` |
| 85 | Unicode key | `action:u8` (0=down,1=up), `codepoint:u16` — preferred for printable chars |
| 87 | Input lock | `u8` 0=unlock 1=lock 2=query |

Mouse button flags: left down 0x02 / up 0x04, right down 0x08 / up 0x10,
middle down 0x20 / up 0x40, move 0x00, double-click 0x88.
Coordinates are absolute framebuffer pixels. Wheel delta is a signed 16-bit value
(±120 per notch, browser sends ×3).

## After the first screen-size (cmd 7), the client sends

1. cmd 5 (compression settings), 2. cmd 8 unpause, 3. cmd 87 query,
4. cmd 1 key-up for VK 16,17,18,91,92,16 (clear stuck modifiers), 5. cmd 14 (`00 0E 00 04`).

## Flow control

No tile acks exist. Backpressure is TCP-level: drain the socket promptly.
Client levers: cmd 5 (quality/scaling/frame timer), cmd 8 pause when backgrounded,
cmd 6 refresh on foreground. Keep the `rtt` control-channel timer running every 10 s
as the app-level keepalive; before closing send `{"ctrlChannel":"102938","type":"close"}`.
