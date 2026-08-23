# Gen1 Co-op (prototype) - step 1

This is the first, deliberately small slice of a co-op mod: prove that
gen1recomp instances - up to 10 players - can open connections and
exchange data. There is nothing to see on screen yet - success looks
like an in-game textbox, not a sprite. The next step (a visible remote
player) only makes sense once this is confirmed solid.

**Confirmed working** in a real two-device test (PC + the official
Android build) over LAN as of v0.0.10. v0.0.11 extends the same
connection to more than 2 players - untested at higher counts so far.

## What this does

- Everything is driven from an in-game menu: open the **START** menu,
  select **GEN1COOP**, then **HOST** or **JOIN**.
- One player **hosts** (opens a TCP port and waits). The host's own game
  also relays every other player's position to everyone else - a star
  topology, not a full mesh, so nobody but the host needs to know more
  than one IP address. Up to 10 players total (1 host + 9 joiners).
- Everyone else **joins**: picking JOIN opens a numeric keypad to type in
  the host's LAN IP.
- Every time a player takes a step, their map/x/y position is sent to
  the host, which relays it to every other connected player.
- Every outcome - success or failure - shows an in-game textbox. Nothing
  requires the dev console.

## Setup

1. Install this mod on every player's gen1recomp `mods/` folder (same
   way as any other mod - MODS > Import mod .zip, or extract manually).
2. Everyone needs to be on the same LAN/WiFi as the host (or the host
   needs to forward port 51820 through their router) - there's no
   dedicated relay server in this version.
3. The host's textbox shows their own LAN IP when they start hosting -
   no need to go find it separately.

## Testing it

1. Load into the overworld on every device (past the title/intro).
2. On the **host**: open START > GEN1COOP > HOST. A textbox confirms
   it's listening and shows the host's IP.
3. On **each other player**: open START > GEN1COOP > JOIN, type the
   host's IP on the numeric keypad, confirm with the ED cell.
4. Walk around on any side (the connection is only serviced on movement,
   not every frame - so if nothing seems to happen, take a step). You
   should see:
   - Host: IP + "en attente..." then "joueur N connecte! (n/9)" as each
     player joins.
   - Each joining player: "connecte a [host IP]!".

If nothing shows up at all after a few steps, the mod likely isn't
installed/enabled correctly. If you get a specific error message, that's
useful - it means the mod is running and something concrete went wrong
(send a screenshot). A connection attempt that shows "connexion a
[ip]..." and then just sits there for 10+ seconds before erroring out is
usually a network problem outside the mod - a firewall, or WiFi
client/AP isolation blocking device-to-device traffic on the same
network (common on guest networks, some routers by default). Try
`ping <host IP>` from the joining device first if that happens.

## Known limitations (on purpose, for this first step)

- No visible avatar for other players yet - just textboxes and log lines.
- LAN/port-forwarding only, no internet relay server.
- Fixed port (51820), not configurable in-game (yet).
- Star topology: if the host quits, everyone's connection drops (the
  host's own game is the relay, not a separate server).
- The connection is only serviced when the local player takes a step
  (not every frame) - a smoother per-frame tick needs a render hook,
  which isn't worth the risk of breaking rendering before the basics are
  solid.
- No reconnect handling if a connection drops mid-session.
- Requires the gen1recomp mod sandbox's "network" permission (declared
  in manifest.json) - `require("socket")` is denied without it.

## Next steps (not built yet)

Once >2 players is confirmed working too: spawn a visible placeholder
sprite for each connected player at their last reported position, then
look at gen1recomp's NPC/sprite APIs for something closer to a real
avatar.
