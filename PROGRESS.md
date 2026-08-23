# Gen1 Co-op — progress tracking

## Goal

Real-time overworld co-op for gen1recomp (two players see each other move
around Kanto together), inspired by seeing
[gamecorner-033/Gen1Online](https://github.com/gamecorner-033/Gen1Online)
(no declared license — used as a feature reference only, not as a code
source; everything here is written from scratch).

Separate project from `translation-qc` — different purpose, different repo.

## Status: Step 1 (v0.0.6) built, awaiting real two-player test

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
