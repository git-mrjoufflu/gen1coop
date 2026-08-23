# Gen1 Co-op (prototype) - step 1

This is the first, deliberately small slice of a co-op mod: prove that two
gen1recomp instances can open a direct connection and exchange data at all.
There is nothing to see on screen yet - success looks like a log line, not
a sprite. The next step (a visible remote player) only makes sense once
this works.

## What this does

- One player is the **host** (opens a TCP port and waits).
- The other is the **client** (connects to the host's LAN IP).
- Every time either player takes a step, their map/x/y position is sent to
  the other side and logged.

## Setup

1. Install this mod folder into both players' gen1recomp `mods/` folder
   (same way as any other mod).
2. On the **host**'s copy, edit `config.lua`: `role = "host"`, pick a
   `port` (default 51820 is fine unless something else uses it).
3. Find the host's LAN IP: on Windows, open PowerShell and run
   `ipconfig`, use the "IPv4 Address" under the active network adapter
   (looks like `192.168.x.x`).
4. On the **client**'s copy, edit `config.lua`: `role = "client"`,
   `host_ip = "<the host's IP from step 3>"`, same `port`.
5. Both players need to be on the same LAN (or the host needs to forward
   the port through their router) - there's no relay server in this
   version.

## Testing it

1. Launch gen1recomp on both machines with `POKEPORT_DEV=1` set as an
   environment variable (enables the dev console).
2. Load into the overworld on both.
3. Press the backtick key (`` ` ``) in-game to open the dev console and
   watch the log scroll by.
4. Walk around on either side. You should see:
   - Host: `hosting on port 51820, waiting for a player to join...` then
     `player joined!` once the client connects.
   - Client: `connected to host <ip>:<port>`.
   - Both sides: `peer: map=... x=... y=...` lines updating as either
     player moves.

If you don't see the connection happen, the most likely cause is Windows
Firewall blocking the port on the host - it'll usually prompt to allow it
the first time, but check the firewall settings if not.

## Known limitations (on purpose, for this first step)

- No visible avatar for the other player yet - just log lines.
- LAN/port-forwarding only, no internet relay.
- The connection is only serviced when the local player takes a step
  (not every frame) - a smoother per-frame tick needs a render hook,
  which isn't worth the risk of breaking rendering before the basic
  connection is even proven.
- One peer only, no reconnect handling if the connection drops.

## Next steps (not built yet)

Once this is confirmed working in a real two-player test: spawn a visible
placeholder sprite at the peer's reported position, then look at gen1recomp's
NPC/sprite APIs for something closer to a real avatar.
