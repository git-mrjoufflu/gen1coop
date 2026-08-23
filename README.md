# Gen1 Co-op (prototype) - step 1

This is the first, deliberately small slice of a co-op mod: prove that two
gen1recomp instances can open a direct connection and exchange data at all.
There is nothing to see on screen yet - success looks like an in-game
textbox, not a sprite. The next step (a visible remote player) only makes
sense once this works.

## What this does

- Everything is driven from an in-game menu: open the **START** menu,
  select **GEN1COOP**, then **HOST** or **JOIN**.
- One player **hosts** (opens a TCP port and waits).
- The other **joins**: picking JOIN opens a numeric keypad to type in the
  host's LAN IP.
- Every time either player takes a step, their map/x/y position is sent
  to the other side.
- Every outcome - success or failure - shows an in-game textbox. Nothing
  requires the dev console.

## Setup

1. Install this mod on both players' gen1recomp `mods/` folder (same way
   as any other mod - MODS > Import mod .zip, or extract manually).
2. Both players need to be on the same LAN/WiFi (or the host needs to
   forward port 51820 through their router) - there's no relay server in
   this version.
3. Find the host's LAN IP before starting: on Windows, open PowerShell
   and run `ipconfig`, use the "IPv4 Address" under the active network
   adapter (looks like `192.168.x.x`).

## Testing it

1. Load into the overworld on both devices (past the title/intro).
2. On the **host**: open START > GEN1COOP > HOST. A textbox confirms
   it's listening.
3. On the **other player**: open START > GEN1COOP > JOIN, type the
   host's IP on the numeric keypad, confirm.
4. Walk around on either side (the connection is only serviced on
   movement, not every frame - so if nothing seems to happen, take a
   step). You should see:
   - Host: "en attente sur le port..." then "un joueur s'est connecte!"
     once the other player joins.
   - Client: "connecte a [IP]!".

If nothing shows up at all after a few steps, the mod likely isn't
installed/enabled correctly. If you get a specific error message, that's
useful - it means the mod is running and something concrete went wrong
(send me a screenshot).

## Known limitations (on purpose, for this first step)

- No visible avatar for the other player yet - just textboxes.
- LAN/port-forwarding only, no internet relay.
- Fixed port (51820), not configurable in-game (yet).
- The connection is only serviced when the local player takes a step
  (not every frame) - a smoother per-frame tick needs a render hook,
  which isn't worth the risk of breaking rendering before the basic
  connection is even proven.
- One peer only, no reconnect handling if the connection drops.
- Requires the gen1recomp mod sandbox's "network" permission (declared
  in manifest.json) - `require("socket")` is denied without it.

## Next steps (not built yet)

Once this is confirmed working in a real two-player test: spawn a visible
placeholder sprite at the peer's reported position, then look at gen1recomp's
NPC/sprite APIs for something closer to a real avatar.
