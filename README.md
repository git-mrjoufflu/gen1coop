# Gen1 Co-op (prototype) - step 1

This is the first, deliberately small slice of a co-op mod: prove that
gen1recomp instances - up to 10 players, LAN or internet - can open
connections and exchange data. There is nothing to see on screen yet -
success looks like an in-game textbox, not a sprite. The next step (a
visible remote player) only makes sense once this is confirmed solid.

**Confirmed working** in a real two-device test (PC + the official
Android build) over LAN as of v0.0.10. v0.0.11 (up to 10 players) and
v0.0.12 (internet play via a relay server) aren't confirmed with real
multi-device tests yet.

## Two ways to play

### A) Same-network LAN (no internet needed)

One player **hosts** (opens a TCP port and waits). The host's own game
also relays every other player's position to everyone else - a star
topology, not a full mesh, so nobody but the host needs to know more
than one IP address. Up to 10 players total (1 host + 9 joiners).
Everyone else picks **JOIN** and types the host's LAN IP.

### B) Internet play (viewers/friends not on your network, no VPN)

Nobody hosts from inside the game. Instead, run `relay_server.py` (in
this repo, a small standalone Python script - NOT part of the mod
itself) on any machine that'll stay on, expose it to the internet with
[ngrok](https://ngrok.com/)'s free TCP tunnel (no VPN, no router
port-forwarding), and have everyone - including you - **JOIN** using the
address ngrok gives you instead of a LAN IP.

```
# on the machine running the relay:
python relay_server.py
# in another terminal:
ngrok tcp 51820
```

ngrok prints something like `tcp://0.tcp.ngrok.io:14589` - the
`0.tcp.ngrok.io:14589` part (host:port, no `tcp://`) is what everyone
types into the mod's JOIN screen. Requires a free ngrok account (just an
email) to run `ngrok tcp`. The free-tier address changes every time you
restart ngrok - fine for a one-off stream, annoying for a standing
server (see `relay_server.py`'s docstring for cheap always-on
alternatives if that matters to you later).

Either way, the JOIN screen's keypad now has letters too (not just
digits), since a relay address needs them.

## What this does

- Everything is driven from an in-game menu: open the **START** menu,
  select **GEN1COOP**, then **HOST** or **JOIN**. **MY NAME** sets your
  display name (shown to everyone else in their **PLAYERS** list); it
  defaults to "PLAYER" if you never set one.
- Every time a player takes a step, their map/x/y position is sent to
  whoever they're connected to (the LAN host, or the relay server),
  which forwards it to every other connected player.
- Every outcome - success or failure - shows an in-game textbox. Nothing
  requires the dev console.

## Setup

1. Install this mod on every player's gen1recomp `mods/` folder (same
   way as any other mod - MODS > Import mod .zip, or extract manually).
2. **LAN play**: everyone needs to be on the same LAN/WiFi as the host.
   The host's textbox shows their own LAN IP when they start hosting -
   no need to go find it separately.
   **Internet play**: run `relay_server.py` + `ngrok tcp 51820` (see
   above) and share the resulting address with everyone, including
   yourself.

## Testing it

1. Load into the overworld on every device (past the title/intro).
2. **LAN**: on the host, open START > GEN1COOP > HOST. A textbox
   confirms it's listening and shows the host's IP. **Internet**: skip
   this step, nobody hosts from inside the game.
3. On **every other player** (and, for internet play, yourself too):
   open START > GEN1COOP > JOIN, type the address on the keypad, confirm
   with the ED cell.
4. Walk around on any side (outgoing position updates only send on
   movement - so if nothing seems to happen, take a step). You should
   see, LAN mode: host shows "player N connected! (n/9)" per player,
   each joiner shows "connected to [ip]!"; internet mode: everyone
   who joined shows "connected to [relay address]!".

If nothing shows up at all after a few steps, the mod likely isn't
installed/enabled correctly. If you get a specific error message, that's
useful - it means the mod is running and something concrete went wrong
(send a screenshot). A connection attempt that shows "connecting to
[address]..." and then just sits there for 10+ seconds before erroring
out is usually a problem outside the mod - for LAN, a firewall or WiFi
client/AP isolation blocking device-to-device traffic (common on guest
networks, some routers by default - try `ping <host IP>` first); for a
relay address, check that `relay_server.py` and `ngrok tcp` are actually
still running and you copied the address correctly.

## Known limitations (on purpose, for this first step)

- Other players show up as a small colored pixel-art marker on the map,
  not a real animated character sprite. Their name only shows in the
  **PLAYERS** list, not floating over their marker in the world (the
  engine doesn't expose the world-camera geometry mods would need to
  place it correctly - see `PROGRESS.md`'s v0.0.16 notes for why).
- Fixed default port (51820) for LAN hosting, not configurable in-game
  (yet). Relay addresses can use any port, since they're typed in full.
- LAN star topology: if the host quits, everyone's connection drops (the
  host's own game is the relay, not a separate server). Relay mode
  doesn't have this problem, but does depend on the relay server staying
  up.
- Outgoing position updates (your own movement) only send when you
  actually take a step, not every frame - fine, since there'd be nothing
  new to send anyway. Everything else (accepting joins, receiving/
  relaying other players' updates, detecting a completed connection)
  runs every engine step regardless of your own movement, since v0.0.14.
- No reconnect handling if a connection drops mid-session.
- Requires the gen1recomp mod sandbox's "network" permission (declared
  in manifest.json) - `require("socket")` is denied without it.
- `relay_server.py` is unauthenticated and unencrypted (plain TCP) -
  fine for "share a temporary address with people you trust for a
  session," not meant for anything more exposed than that yet.

## Next steps (not built yet)

Smooth marker movement (interpolation instead of teleporting between
updates) and facing direction; a real animated character sprite instead
of a flat pixel-art marker; internet/relay play confirmed with real
people (still only LAN-tested); more than 2-3 simultaneous players
confirmed.
