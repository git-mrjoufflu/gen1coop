# Gen1 Co-op — progress tracking

## Goal

Real-time overworld co-op for gen1recomp (two players see each other move
around Kanto together), inspired by seeing
[gamecorner-033/Gen1Online](https://github.com/gamecorner-033/Gen1Online)
(no declared license — used as a feature reference only, not as a code
source; everything here is written from scratch).

Separate project from `translation-qc` — different purpose, different repo.

## Status: Step 1 CONFIRMED WORKING (v0.0.10)

Real two-device test, PC + the official Android build, over LAN: host
showed "un joueur s'est connecte!", client showed "connecte a [ip]!".
Whatever was blocking the connection before v0.0.10 resolved itself
(network-side, per the ping/firewall/isolation diagnostic suggested in
that release - not confirmed which one it was, but it stopped being a
problem). This is the real milestone: the core networking layer works
end to end across two real devices on two different platforms, not just
in theory. Position sync (`mapId,x,y` on every `world.stepped`) has been
running under the hood since v0.0.1 and should now actually be flowing
between the two connected peers, though nothing renders it yet - that's
step 2.

## Next: Step 2 - visible remote player

Not started. Plan (from the original roadmap): spawn a placeholder
sprite at the peer's last reported position, shown/hidden based on
whether both players currently share a `mapId`. Open question carried
over from the start of this project and still unresolved: gen1recomp's
sanctioned mod API has no obvious "spawn an NPC at runtime" surface (the
`maps` registry's `objects` field is static map data merged at load
time, not a live spawn call) - Gen1Online reached directly into
`src.world.NPC` and `src.render.SpriteRenderer` for this, bypassing the
mod sandbox the same way this project had to for networking. Needs the
same kind of source-reading pass that found `mod.hooks:wrap`,
`ui.start_menu.items`, and the `network` permission - check whether
there's a real spawn API before assuming another sandbox reach-around is
required.

**v0.0.10:** v0.0.9's non-blocking connect worked as designed - MrJoufflu
saw "connexion a 192.168.2.65..." appear instantly (phone hosting, PC
joining) - but it then sat there indefinitely, never resolving to either
"connecte" or an error. A `connect()` that never becomes writable at all
(not success, not failure) is the textbook symptom of something *outside*
the app silently dropping the SYN - most likely candidates: Windows
Firewall on the PC blocking the outbound attempt, or WiFi client/AP
isolation on the router preventing devices from reaching each other on
the same network at all (very common default on home routers' guest
networks, and on some routers generally). This is very likely a network
configuration issue, not a bug in this mod's code - but the mod had no
way to surface that distinction, since `pendingConnect` had no timeout
and would just poll forever in silence.

Added a 10s timeout in `pollConnect()`: if a connect attempt never
resolves, it now gives up and shows "Gen1Coop: [ip] ne repond pas.
Pare-feu ou isolation WiFi?" - turning an indefinite silent hang into an
actionable message. Next real step is a network-level diagnostic (does
`ping 192.168.2.65` from the PC even succeed? is there an "AP isolation"
/ "client isolation" setting in the router's admin panel? does Windows
Firewall have an outbound rule for gen1recomp.exe?), not more mod code -
if it's genuinely isolation/firewall, no amount of retrying from inside
the mod will fix it.

**v0.0.9 - two more issues from testing v0.0.8:** host's textbox showed
"port en attente" with no IP (the `localIP()` UDP trick, or its
hostname-resolution fallback, failed silently on whichever device this
was tested on - added `mod.log:warn` at every failure point inside
`localIP()` so the *reason* is at least visible via the dev console next
time, even though the textbox itself just omits the IP line either way).
More importantly: joining with a typed IP and pressing ED did "rien" -
the real suspect is `startClient`'s old 5-second *blocking* `connect()`
call, which runs on the frame that handles the ED press and would freeze
the whole game for up to 5s with zero feedback until it resolved -
plausibly exactly what read as "nothing happening" (or a fast failure
nobody waited through). Rewrote it non-blocking: `connect()` on a
timeout-0 socket returns immediately (an in-progress attempt looks like
an ordinary "timeout" error, not a real failure), a new `state =
"connecting"` is polled every `world.stepped` via `socket.select`, and
`getpeername()` on the resulting socket distinguishes an actually-
established connection from a completed-but-failed one. Also added a
`Gen1Coop:\nIP vide,\nressaie.` message for an empty confirm (in case
digit entry silently wasn't registering anything), and a log line at the
very top of `onDone` so a future "rien" report can at least confirm
whether the naming screen's confirm callback fires at all.

**v0.0.8 - two fixes from real testing feedback:**
1. v0.0.7 loaded fine (GEN1COOP appeared in the START menu) but choosing
   HOST or JOIN appeared to do "rien" (nothing) - a real UX bug, not a
   crash. `notify()` was still queuing messages for `world.stepped` to
   flush, a leftover from when `game.ready` auto-started a connection
   (pre-v0.0.6) and pushing UI that early was untested. Since v0.0.6
   removed that auto-start, `startHost`/`startClient` only ever run from
   a menu selection or from inside `world.stepped` itself - both already
   safe contexts - so the deferral no longer serves a purpose and just
   made the confirmation textbox wait for the player's next step, which
   read as "nothing happened." `notify()` now pushes immediately.
2. Added the host's own LAN IP to the "hosting" textbox (requested:
   "quad on clique sur host faudrait pouvoir voir son ip") - via the
   classic LuaSocket trick of a UDP `setpeername` + `getsockname` (no
   real packet sent, no internet needed, just asks the OS which local
   address would route to an external IP), falling back to hostname
   resolution. No more alt-tabbing to `ipconfig` to find it.

Also suggested: a lobby/discovery system instead of manual IP entry.
Deliberately not building that yet - bigger scope (LAN broadcast
discovery or a relay-based room code), and manual IP entry needs to be
proven reliable first before replacing it with something more complex.

**v0.0.7 - real bug, caught by the mod manager's error screen:** v0.0.6
crashed on load - `mods/gen1coop/main.lua:139: attempt to call method
'on' (a nil value)`. `mod.hooks:on(...)` is not a real method; the actual
mod-facing API is `mod.hooks:wrap(name, callback, priority)`
(`src/mods/Loader.lua`: `hooks = { wrap = function(...) end }`), and the
callback receives `next` as its *first* argument, same as any
intercept/wrap pattern (`src/mods/Hooks.lua`:
`pcall(entry.callback, nextFn, unpack(args))`). Fixed both hook
registrations (`ui.naming.grid`, `ui.start_menu.items`) to use `:wrap`
and the `(next, ...)` signature, calling `next(...)` to pass through
instead of returning the base value directly.

Notable: this exact wrong pattern (`mod.hooks:on("ui.naming.grid", ...)`)
is also sitting in translation-qc's main.lua, unnoticed because it's
gated behind `if grid.upper then` and `lang/naming.lua` ships an empty
table by default - so it's dead code there, never actually executed.
Worth fixing over there too if that mod ever gets a custom naming grid.

**v0.0.6 - confirmed: sockets work on both PC and the official Android
build.** MrJoufflu's screenshot after v0.0.5 showed "en attente sur le
port 51820..." on the Android device too - meaning `require("socket")`
and `socket.bind()` both succeeded there, not just on Windows. The
remaining blocker was just config: both devices had `role = "host"` in
their hand-edited config.lua, so no client ever dialed in. Rather than
tell MrJoufflu to hand-edit a text file on Android (impractical), moved
the whole flow in-game: `config.lua` is gone. START menu > GEN1COOP >
HOST or JOIN now. JOIN opens a numeric keypad for the host's IP, built by
reusing `NamingScreen` (the same widget behind the actual player-naming
screen) with a custom digits+dot grid, scoped to only this screen via a
title match on the `ui.naming.grid` hook (`ctx.title == "IP DU HOST?"`) -
confirmed via source (`NamingScreen:grid()`) that `ctx.title` is exactly
what gets passed through, so the real name-entry screens are untouched.
The START menu entry comes from the `ui.start_menu.items` hook. Last-used
IP is remembered via `mod.save` so re-joining doesn't mean re-typing.

Confirmed gen1recomp's official Android build is real:
`mobile/ANDROID.md` + a full `mobile/android/` Gradle project exist in
the repo - missed on the first pass because only `docs/` was checked,
not `mobile/`. Also worth knowing: Android's networking for the built-in
mod-index/mod-update feature goes through a *different*, narrower
transport (`love.system.httpDownload` → a Java `HttpsURLConnection`
bridge, since Android ships no `curl`) than desktop's `curl`-based one.
That transport is unrelated to what this mod uses (raw `require("socket")`
TCP, gated by the sandbox's `network` permission) - and the Android test
result confirms raw sockets work fine for mods there too, independent of
that separate mod-index-specific bridge.

**v0.0.5 - real progress:** the v0.0.3 error-reporting fix worked exactly
as intended - it surfaced a genuine bug instead of silence. MrJoufflu got
"reseau (socket) indisponible sur ce build." in a textbox. Root cause
found in `src/mods/Sandbox.lua`: mods run in a real permission-gated
sandbox, and `require("socket")` (along with enet/http/https/ssl/mime/
ltn12) is denied unless the manifest declares `permissions: ["network"]`
(`Sandbox.moduleDenial`, checked against `manifest.permissionSet`). This
completely reverses the "no sanctioned path for networking" conclusion
from earlier research - that was based on the mod-facing `mod` table not
having a `net` field, but never checked for a permission system gating
raw `require()` itself. Full valid permission set, from
`src/mods/Manifest.lua`: `network`, `filesystem`, `engine_internals`,
`steps`, `background`, `compute`. `love.thread` separately needs
`compute` (not used here - the current code polls sockets synchronously
from `world.stepped`, no threading). Added `"permissions": ["network"]`
to manifest.json. Not yet confirmed whether this alone fixes it, or
whether declaring the permission also requires a player-facing consent
prompt somewhere in the mod manager UI that hasn't been checked yet.

**v0.0.4:** added `"github": "git-mrjoufflu/gen1coop"` to manifest.json
so gen1recomp's in-game mod manager can check for updates itself (same
mechanism translation-qc uses) - no CI/release automation set up yet
though, releases are still manual via `gh release create` while this is
in rapid-iteration prototype mode.

Still nothing confirmed working in an actual two-instance test as of
v0.0.3 - MrJoufflu sent a screenshot after loading the game (v0.2.20,
newer than the v0.1.75 this was researched against) but no textbox was
visible in it, and it's not yet confirmed whether the mod was actually
installed/configured at that point or whether this was just a "here's
the game running" check-in.

**v0.0.2:** switched connection confirmation from log-only to an
in-game textbox. The dev console (`POKEPORT_DEV=1`) needs an env var set
before launch, which isn't practical when testing across different
devices/platforms (MrJoufflu is testing PC + phone) - a textbox needs
nothing extra. Also found: gen1recomp has no documented simple Android
build (only Windows/Switch/iOS-via-Xcode-rebuild) - if "phone" means
Android, that needs sorting out before a phone test can work at all.
Pushing the textbox is deferred from `game.ready` to the first
`world.stepped` after it, since `game.ready` can fire before the player
is actually in control (title/save-select/intro) and pushing UI state
then is untested.

**v0.0.3:** found and fixed a real bug in the v0.0.2 design - every
failure path (`require("socket")` failing, `config.lua` missing/invalid,
an unrecognized `role`) returned early *before* `world.stepped` ever got
subscribed, so a broken setup produced zero feedback at all - not even
an error textbox - and would have looked indistinguishable from "the mod
isn't installed." `game.ready`/`world.stepped` are now subscribed
unconditionally first; every failure mode notifies through the same
textbox queue as the success path.

Nothing has been confirmed working in an actual two-instance test yet.
Everything below is "should work based on source research" until MrJoufflu
tests it and reports back.

## Key research findings (why things are built this way)

- **No networking API in gen1recomp's sanctioned mod surface.** Read the
  full `mod` table construction in `src/mods/Loader.lua`: `content`,
  `hooks`, `events`, `input`, `ui`, `save`, `options`, `commands`,
  `migrations`, `log`, `assets`, `find`, `read`. No `net`/`http`/sockets
  anywhere. Any multiplayer mod — this one included — has no choice but
  to reach past the mod sandbox for the networking layer itself, the same
  as Gen1Online does. This isn't a "safer path exists, we chose not to
  take it" situation — there is no sanctioned path for this one piece.
- **LuaSocket is available for free.** gen1recomp's Windows build is a
  standard LÖVE2D distribution (`love.dll`/`lua51.dll`/`SDL2.dll`, no
  separate socket DLL) — LuaSocket ships compiled into `love.dll` on
  every LÖVE2D build, so `require("socket")` works with nothing extra to
  install. No `ssl.dll` present though, so HTTPS (`require("ssl.https")`)
  is NOT available on this build — rules out an HTTPS-based relay/GTS
  server for now, plain TCP only.
- **`world.stepped` is the sync point.** Confirmed via
  `src/world/OverworldController.lua`: fires once per completed tile-step
  (not every frame) via `Runtime.emit("world.stepped", { mapId, x, y,
  tile, tod })`, gated behind `Runtime.wants("world.stepped")` so it costs
  nothing when unused. Available to mods via `mod.events:on("world.stepped",
  fn)` — confirmed the exact calling convention in `src/mods/Events.lua`:
  `pcall(entry.callback, payload)`, single payload table argument.
- **Per-frame tick would need a render hook.** `mod.hooks` can wrap
  engine calls like `render.compose`, but a wrapper has to pass through
  the original args correctly or it risks breaking rendering entirely —
  a much worse failure mode than anything in the text-only translation
  mod. Deliberately not doing this until step 1's plain `world.stepped`
  polling is confirmed working; a step-only tick is a real (if clunky)
  first test.
- **Options menu can't take free-text IP input.** `mod.options` rows are
  cycler-style (Left/Right/A through preset values — see
  `src/ui/OptionRows.lua`), not text fields. Host IP entry needs either a
  hand-edited config file (what step 1 does) or a custom UI built later
  (`mod.ui` widget toolkit, or the naming-screen-style letter grid).

## Built so far (step 1)

- `main.lua`: host (`socket.bind` + non-blocking `accept`) or client
  (`socket.connect`, one-time 5s blocking attempt then non-blocking) TCP
  connection. On every `world.stepped`, sends local `mapId,x,y` to the
  peer and logs whatever the peer last sent. No visuals — success is a
  log line in the dev console (`POKEPORT_DEV=1` env var, backtick key
  in-game).
- `config.lua`: hand-edited per copy — `role` (`"host"`/`"client"`),
  `port`, `host_ip` (client only).
- Known limitations, on purpose for this slice: LAN/port-forward only, no
  relay; polling only on local player movement, not every frame; one
  peer only; no reconnect handling.

## Next steps (not built yet, in likely order)

1. **Confirm step 1 actually works** in a real two-PC LAN test. This is
   the current blocker — nothing past this point should get built until
   it's confirmed, so effort doesn't compound on an unverified base.
2. Visible remote player: spawn a placeholder sprite at the peer's last
   reported position, hide/show it based on whether both players share a
   `mapId`. Needs figuring out gen1recomp's actual NPC/sprite spawn
   surface for mods (Gen1Online required `src.world.NPC` and
   `src.render.SpriteRenderer` directly — no sanctioned spawn API found
   yet, same story as networking).
3. Smooth movement (interpolation) instead of position snapping.
4. Collision between the two real players.
5. PVP link battles — likely the easiest of the remaining pieces, since
   gen1recomp already ships a complete `src/link/LinkBattle.lua` engine;
   this would mainly be wiring a "challenge" interaction into it rather
   than building battle-sync from scratch.
6. A relay server / actual internet play (not LAN-only) — separate
   infrastructure question, deliberately deferred.

## Decisions log

- Built from scratch, not forked from Gen1Online (no license on their
  repo).
- Starting with overworld co-op, not PVP battles first (MrJoufflu's call
  — battles would've been the lower-risk starting point since the engine
  already has `LinkBattle`, but overworld co-op is the actual point of
  the mod).
- New local folder first, GitHub repo once there's something worth
  tracking in version control (this point).
