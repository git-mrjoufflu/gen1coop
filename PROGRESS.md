# Gen1 Co-op — progress tracking

## Goal

Real-time overworld co-op for gen1recomp (two players see each other move
around Kanto together), inspired by seeing
[gamecorner-033/Gen1Online](https://github.com/gamecorner-033/Gen1Online)
(no declared license — used as a feature reference only, not as a code
source; everything here is written from scratch).

Separate project from `translation-qc` — different purpose, different repo.

## v0.0.26: FIND HOST still not finding anything - try the subnet broadcast too

MrJoufflu: "ca ne fonctionne pas l'auto host." Vague on its own, so
asked a follow-up (multiple-choice: did it show "searching..." then
"no host found," did nothing happen at all, a different error, or a
freeze/crash) rather than guess blind - the answer ("Searching LAN..."
puis "no host found") confirmed the FEATURE ITSELF runs correctly end
to end (menu opens, socket binds, timeout fires, error message shows);
the beacon packet just wasn't reaching the other device. That rules out
a logic bug in this mod's own state machine and narrows it to the
UDP broadcast mechanism itself.

The limited broadcast address, `255.255.255.255`, is a known-flaky
choice in practice - plenty of home routers and OS network stacks
don't forward it the way they forward a *directed* subnet broadcast
(`a.b.c.255` for a `/24` network) - this is a well-documented general
UDP-discovery gotcha, not specific to LuaSocket or this engine.
`startHost()` now also computes that address from the host's own
`localIP()` result (assumes a `/24` - LuaSocket doesn't expose a real
netmask, but a `/24` covers the large majority of home/guest-network
setups this feature targets) and `broadcastDiscovery()` sends the
beacon to BOTH addresses every tick, not just the original one. Also
started checking `sendto`'s own return value for the first time
(previously silently ignored) and logging any failure, so if this is
still broken, the next report has an actual error message to go on
instead of just "didn't work."

Flagged honestly: if this STILL doesn't find anything, Windows Firewall
silently blocking the new UDP port (51821) on first use is the next
most likely suspect, and that's outside anything fixable from inside
this mod - same category of issue as the earlier direct-connection
firewall/AP-isolation troubleshooting in v0.0.9/v0.0.10's history.
Manual JOIN with a typed IP remains the guaranteed-to-work fallback
regardless of how FIND HOST behaves.

## v0.0.25: name label unstable in "vox3d" - a third-party pipeline, not Tilt

MrJoufflu, with a screenshot: "les nom quand on est en vox3d bouge et ne
sont pas stable sur le dessus du perso" (the names move around and
aren't stable above the character in vox3d mode). The screenshot showing
the isometric-looking buildings in the v0.0.21/v0.0.22 reports was this
mode the whole time - it just took a name explicitly wrong to place it.

Found via `docs/modding.md`'s "Rendering pipelines" section: "vox3d" is
`mods/voxel_world`, a real example third-party mod that registers a
whole alternate world-rendering pipeline ("a 3D diorama overworld plus a
tilt-shift miniature pass") through `render_pipelines`, which can
replace the normal flat/tilt world pass entirely via
`Renderer:setWorldOverride(canvas)` - and per that same doc, "a world
pipeline and the engine's own TILT are mutually exclusive," so this is a
genuinely separate case from the `Tilt.active()` check already in place,
not a variant of it. `drawNameLabels`'s whole approach - mirroring
`Renderer:endFrame`'s flat `worldCanvas` blit math - has no meaning once
a pipeline owns the world pass instead (a 3D diorama isn't a flat
canvas blitted at a fixed scale/offset at all), which is exactly why the
label was drifting instead of just being positioned wrong: the numbers
it was computing were arbitrary in that mode.

Added a second bail-out, `Pipelines.worldPipeline()` (nil when the
vanilla flat/tilt path owns the frame) - the exact same query
`src/world/OverworldController.lua` itself uses to decide whether a
pipeline gets the frame instead of the normal draw. Confirmed
`Renderer.worldOverride` itself isn't usable for this check: like
`worldActive`, it's unconditionally reset to nil at the end of every
`endFrame`, so by the time `render.hud` fires (after `endFrame` has
already returned) it always reads nil regardless of what actually
happened that frame - `worldPipeline()` is a live, persistent query
instead of a per-frame flag, which is why it works here where
`worldOverride` wouldn't have.

Net effect: the label now simply doesn't draw at all while a
third-party world pipeline (voxel_world or otherwise) is active, the
same "skip rather than guess wrong" choice already made for Tilt mode.
Not yet re-verified against another screenshot.

## v0.0.24: FIND HOST - LAN auto-discovery, no IP typing needed

MrJoufflu: "serais t'il possible de trouvez l'hotes de session sans
entré d'ip? (local lan seulement)" (could we find the session host
without typing an IP - LAN only). Manual JOIN stays exactly as it was
(still the only option for internet/relay play, and still there as a
LAN fallback); FIND HOST is a new, separate menu item next to it.

- Host side: `startHost()` also opens a UDP socket
  (`setoption("broadcast", true)`) once the TCP listener is up.
  `broadcastDiscovery()`, called every `input.step` alongside
  `serviceHost()`/`hostReceiveAndRelay()`, sends one
  `"GEN1COOP_HOST:" .. localName()` packet to `255.255.255.255` on
  `DISCOVERY_PORT` (51821, deliberately a different port from the TCP
  game port 51820) roughly once a second (`DISCOVERY_TICK_FRAMES = 60`,
  a plain frame counter - no need for real timestamps at this
  granularity). Skips broadcasting once the lobby is full, so a search
  doesn't get lured toward a host that can't accept it. Best-effort:
  if the UDP setup fails for any reason, it just logs and hosting
  continues normally - FIND HOST becoming unavailable was never meant
  to block the fallback (manual JOIN with the host's IP still works
  regardless).
- Client side: `startDiscovery()` (new `state = "discovering"`) opens a
  UDP socket bound to `DISCOVERY_PORT` and listens; `pollDiscovery()`
  (wired into `input.step`, same pattern as `pollConnect()`) checks any
  received packet for the `"GEN1COOP_HOST:"` prefix and, on a match,
  reads the sender's IP straight off `receivefrom`'s own return value
  (not anything the payload has to encode) and hands off directly into
  the existing `startClient(ip)` - from that point on it's identical to
  a manual JOIN, same connect/relay code either way. Gives up after
  `DISCOVERY_TIMEOUT_SECONDS` (5s) with a message pointing at JOIN
  instead, mirroring `pollConnect`'s own timeout message.
- Caught a real forward-reference bug before shipping (same class as the
  `showPlayerList` one documented near the top of this file):
  `startDiscovery` was originally written right next to `pollDiscovery`,
  much later in the file than `openConnectMenu`'s new FIND HOST button
  that calls it - since Lua resolves a name used before any `local` with
  that name has been declared (in source order) as a global lookup, that
  button would have called a nil global and errored the moment someone
  pressed it. Moved `startDiscovery` up next to `pollConnect` (before
  `openConnectMenu`), left `pollDiscovery` where it was (only referenced
  from the `input.step` hook at the very bottom, so no ordering issue
  there).
- Real caveats, not yet tested: UDP broadcast reliability varies more
  than TCP does across networks - the same firewall/AP-isolation
  concerns that hit direct connections apply here too, and Android in
  particular sometimes restricts broadcast/multicast traffic at the OS
  level in ways LuaSocket has no lever for from inside this mod. If FIND
  HOST doesn't turn anything up, manual JOIN with the host's IP is
  always still there as the fallback - this was designed as a
  convenience layered on top of the existing path, not a replacement
  for it.

## v0.0.23: name label still too big, cut LABEL_SCALE further

MrJoufflu after v0.0.22: "en fait je le veux quand meme petit" (I still
want it small). `LABEL_SCALE` (introduced in v0.0.22, was 0.5) cut to
0.3 - no other logic changes. Still a guess, not re-verified against a
screenshot.

## v0.0.22: name label was way oversized - first real testing feedback

MrJoufflu's first screenshot of v0.0.21 in actual play: "bcp trop gros"
(way too big) - the floating name genuinely dwarfed the sprite next to
it, with a real naming-screen textbox visible in the same shot for
comparison (much smaller, as expected).

Root cause, reasoned from the screenshot rather than a debugger (still
can't run this myself): `drawOneLabel` was scaled with `sx/sy`, the same
zoom-aware scale used to POSITION the label
(`Zoom.scale(Renderer:fitScale())` - correct for that, since the label
has to track the sprite exactly as the player zooms the world in or
out). But a real UI textbox's font is explicitly NOT zoom-scaled -
`Renderer:uiScale()`'s own comment: "Zooming IN does not scale the UI
up... the letterbox it sits in does not grow either." So the moment
survey zoom was engaged above 1x, the label's text grew right along with
the world while every other piece of UI text on screen stayed put -
reads as "the name is huge" even though the underlying math was
internally consistent.

Fix: split into two scales. Position keeps the zoom-aware one
(`sx/sy`); the text itself now uses `Renderer:fitScale()` alone
(`tsx/tsy`, not zoom-scaled), further multiplied by a `LABEL_SCALE = 0.5`
guess on top - a name tag reading as a small caption rather than
full dialogue-text size felt like the more reasonable target size even
before accounting for the zoom bug, going by how the screenshot looked
oversized by more than just the zoom factor alone could explain. Not
re-verified against a second screenshot yet.

## v0.0.15 through v0.0.20 CONFIRMED WORKING in real play

MrJoufflu, in passing while asking for the name-label feature below:
"tout le reste fonctionne bien" (everything else works fine). Real
confirmation, not just source-verified: connection/relay, real-sprite
markers, MY NAME, MY SPRITE (including the local reskin), and the
animated walk/facing all hold up in actual gameplay. Only the
name-label feature below is new/unverified as of this entry.

## v0.0.21: floating name labels over each marker - the v0.0.16 "no"

MrJoufflu asked again: "panse tu qu'on peu mettre le nom des joueur au
dessus de sprite?" I'd turned this down in v0.0.16 (see that entry) on
the grounds that render.hud's viewport is letterbox-only geometry, not
the world canvas's own screen placement, and that reaching further would
mean reconstructing private renderer math with no stability guarantee
and no way for me to verify it visually. Laid out that same reasoning
again when asked, and MrJoufflu's response was "mais ca serais tellement
wow" (but it'd be so cool) - not an explicit "accept the risk," but read
as wanting the attempt anyway given the enthusiasm and this project's
established pattern of trying things and getting real feedback rather
than stopping to negotiate every risk in the abstract.

What changed since v0.0.16 that made this worth attempting now: v0.0.20
already opened the `engine_internals` door (for the local-sprite reskin),
and on closer inspection the geometry needed - `Renderer:fitScale()`,
`Zoom.scale()`, `Renderer.worldCanvas:getWidth/Height()` - turned out to
be either real public methods or plain `love.graphics.*` calls
(`displayMetrics()`'s own logic), NOT actually private renderer state the
way I'd assumed. The one genuinely private piece,
`Renderer:endFrame`'s internal `displayMetrics()` helper, is itself built
entirely from stable, standard LÖVE window/DPI queries - safe to
reimplement verbatim since it doesn't touch anything renderer-specific.

- `drawNameLabels()` (wraps `render.hud`) reconstructs the world canvas's
  screen placement by mirroring `Renderer:endFrame`'s own
  `elseif self.worldActive then` branch math, then converts each visible
  marker's live world-pixel position (`handle.npc.px/.py` - the
  INTERPOLATED mid-step position, not just the destination cell, so the
  label doesn't jump ahead of a still-walking sprite) into a screen
  coordinate and draws a small white-box/black-text nameplate above it -
  the same visual language every textbox/list in this game already uses
  (`src/ui/ListMenu.lua`'s own draw()), not an invented style.
- Two deliberate bail-outs rather than best-effort guesses: skip
  entirely when the overworld isn't literally `game.stack:top()` (a menu
  or battle covering it - `mod.world:overworld()` would still resolve
  the world state underneath, which is right for `spawnNpc` but wrong
  for "is this actually what's on screen"), and skip in `Tilt.active()`
  mode (the ground is projected through a perspective shader mesh there,
  not flat - this linear math would place labels wrong, not just
  imprecisely).
- Each label's draw runs inside its own `pcall`, with
  `love.graphics.push()`/`pop()` kept OUTSIDE that pcall (bracketing it,
  not inside it) - guarantees the graphics transform/color stack stays
  balanced across frames even if one marker's draw throws, since this is
  screen-space code I have no way to watch run myself. One marker
  failing logs a warning and skips just that label rather than risking
  visual corruption for everything drawn afterward that frame.
- Genuinely the least-verified piece of this whole project: the pixel
  offsets (`+8` centering, `-4` matching `SpriteRenderer:draw`'s own
  above-cell offset, `-8` label gap) are read off the engine source, not
  tuned against a real screenshot - expect this to need adjustment once
  MrJoufflu actually sees it in game.

## v0.0.20: animated movement/facing, and MY SPRITE reskins yourself too

Three asks from MrJoufflu, back to back, right after v0.0.19 shipped:
"ok maintenant faut ajuster les sprite selon la direction et quand on
change le choix de sprite est-ce que notre perso de notre cote peux
change de sprite aussi" (adjust the sprite by direction, and can
changing MY SPRITE also change our own character's sprite), then
mid-implementation "si on peux avoir aussi les mouvement de jambe des
autres joureurs" (leg movement/walk animation for other players too).

**Direction + walk animation, together.** Redesigned `updateMarker` to
stop despawning/respawning on every position update. When the new
position is a legit single-tile step from a marker's last known
position, on the same map, with a live NPC already spawned there
(`directionOf` + the new `remoteFacing` table), it now calls
`mod.world:npc(mapId, npcId):scriptMove(dir, 1)` instead of respawning.
Traced this all the way through `src/world/OverworldController.lua`'s
`scriptMove`/`updateScriptMoves`: queuing a move sets `e.facing = dir`,
computes the target cell, and sets `e.moving = true` - and
`src/world/NPC.lua`'s `NPC:update` gates its ENTIRE moving-animation
path (pixel interpolation + `walkPhase()`'s frame-0/1 alternation) on
`self.moving` alone, completely independent of `self.wanders` (that
only gates the separate autonomous-roaming branch). So a stationary,
non-wandering marker NPC still gets the real walk-cycle frames and
smooth per-pixel movement the moment something scripts it to move - both
asks solved by the same one engine mechanism, no custom animation code
needed at all. Falls back to a snap despawn/respawn (`snapMarker`, kept
as its own function) for a first sighting on a map, a same-map jump
bigger than one tile (a warp), or if the live handle is ever
unexpectedly gone - `directionOf` only returns a direction for an exact
adjacent-tile delta, so anything else routes to the safe snap path
instead of trying to animate an illegal move. `remoteFacing[id]` persists
the last known direction across a full despawn/respawn too, so even a
snap now spawns facing the right way instead of resetting to down.
One known open risk, not yet an issue in practice: if position updates
ever arrived faster than a 16-frame walk-cycle plays out, queued
`scriptMove`s would back up and the visual marker would lag behind the
reported position - shouldn't happen under normal play since updates are
paced by the sender's own step cadence (same speed the animation takes),
but worth watching for once this is tested with real lag/jitter.

**MY SPRITE now reskins the local player too.** `WorldAPI` doesn't
expose a method for changing the player's OWN live sprite - its own file
header is explicit that reaching into `OverworldState` internals beyond
what it offers is unsupported. Weighed this the same way as the
render.hud non-decision (v0.0.16): is there a real door, or none at all?
Here there IS one, just gated: `src/mods/Loader.lua`'s `scanRequire`
warns (`Logger.warn`, not a hard block) on any `require("src.*")` outside
a small whitelist unless the mod declares `"engine_internals"` - and this
mod's `src.ui.Menu`/`src.ui.NamingScreen`/etc. requires had already been
triggering that warning, unlabeled, since v0.0.6. So: declared
`"engine_internals"` in manifest.json (being honest about a debt that
already existed, not just the new reach), and `applyLocalSprite()` now
builds a fresh `SpriteRenderer.new(game.data.sprites[chosenId], "player")`
and assigns it straight to the live `Player` object's `.sprite` field -
the exact same construction `src/world/Player.lua` itself uses at boot.
Confirmed via `Player:pose()` that it reads `self.sprite` fresh every
call, no external cache keyed by the old instance to go stale. Runs
immediately from MY SPRITE's own picker, and again every `map.entered`
(covers a saved-but-not-yet-applied choice at session start, and
re-asserts it defensively on every later map load).
Not yet tested in a real game - everything here is source-verified only.

## v0.0.19: players pick their own sprite (MY SPRITE), saved

MrJoufflu, right after v0.0.18 shipped real ROM sprites but still
assigned them automatically by connection order: "can we let's them
shoose they sprite in the config tab" - then, mid-implementation, added
"faudrait que ca ce sauveguarde aussi question de ne pas le refaire a
chaque fois" (it should save too, so it doesn't have to be redone every
time) - confirming the obvious design (persist via `mod.save`, the exact
mechanism MY NAME already uses) before it was even asked as a separate
question.

- START > GEN1COOP > MY SPRITE: a `ListMenu` of all ten
  `PLAYER_SPRITES` entries (by their `PLAYER_LABELS` name). Picking one
  saves it to `mod.save` under `player_sprite` and closes back to
  GEN1COOP - same shape as MY NAME's flow.
- `localSprite()` reads it back, defaulting to `SPRITE_RED` (id 0's
  sprite - same "everyone starts identical until they customize"
  default MY NAME already has) if nothing's been picked yet.
- Wire protocol grows another trailing field (after name): now
  `mapId,x,y,name,sprite` client->host and `id,mapId,x,y,name,sprite`
  host->client. `remoteSprites[id]` (new table, same lifecycle as
  `remoteNames`) tracks what sprite each remote player last reported;
  `updateMarker`/`resyncMarkers` now spawn with `remoteSprites[id] or`
  the id-based default instead of always the id-based default.
- Added `isValidSprite()`, checked before ever trusting a received
  sprite id: `NPC.new` (`src/world/NPC.lua`) does
  `assert(data.sprites[objDef.sprite], ...)` on spawn - an *uncaught*
  Lua error, unlike `spawnNpc`'s other failure modes (an unknown mapId
  returns `nil, "unknown map"` gracefully instead). Nothing in this
  mod's own UI can produce an invalid sprite id today (the MY SPRITE
  list only ever offers the ten known ones), but the wire format trusts
  whatever a peer sends, and there's no version negotiation anywhere in
  this protocol - so a future version of this mod with more sprite
  choices, or a corrupted line, must not be able to throw mid-relay.
  Falls back to that player's id-based default sprite when the received
  value isn't recognized.
- JOUEURS/PLAYERS list fallback label (shown when a player hasn't set a
  name) now reflects their actual current sprite choice
  (`SPRITE_LABEL_BY_ID`, the reverse of `PLAYER_SPRITES`/`PLAYER_LABELS`)
  instead of always the id-based default.
- Not yet tested in a real game.

## v0.0.18: real ROM sprites instead of invented pixel art

MrJoufflu's ask: "je veux les les meme sprite que l'original pas un
sprite inventer" (I want the same sprites as the original, not an
invented sprite) - rejecting v0.0.16's hand-drawn pixel-art person.

Found that this is actually straightforward and *better* than the
custom-art approach: gen1recomp's NPCs are rendered from `data.sprites`,
a table keyed by sprite id strings extracted straight from the player's
own ROM at import time (`src/import/RomExtractor.lua`). Confirmed the
local player's own walking sprite is loaded under exactly `"SPRITE_RED"`
(`src/world/FieldDefaults.lua`'s `PLAYER_SPRITES.walk = "SPRITE_RED"`,
read by `src/world/Player.lua`), and that `mod.world:spawnNpc`'s
`objDef.sprite` accepts any of these ids directly - confirmed via
`tests/mod_world_tests.lua`'s own spawnNpc calls (`{ sprite =
"SPRITE_OAK", ... }`) and `tools/rom_manifest.json`'s full sprite id
list. So no custom asset, no `mod.content.sprites:register` call, and no
`trueColor` opt-out needed at all - these sprites render through the
game's normal DMG palette pipeline exactly like every other NPC, which
*is* "the same as the original" in the most literal sense.

- Deleted `assets/sprites/` entirely (the v0.0.15/v0.0.16 hand-drawn
  markers and their generator script).
- `PLAYER_SPRITES[id]`: `SPRITE_RED` (id 0, host - literally the
  player's own sprite), `SPRITE_BLUE` (id 1 - the rival's sprite), then
  `SPRITE_GIRL`/`SPRITE_HIKER`/`SPRITE_BIKER`/`SPRITE_SAILOR`/
  `SPRITE_FISHER`/`SPRITE_NURSE`/`SPRITE_GRANNY`/`SPRITE_ROCKET` for ids
  2-9 - common recurring trainer-class NPCs, picked over unique story
  characters (Oak, Giovanni, the Elite Four) so another player reads as
  "some trainer," not as a specific game character.
- `PLAYER_LABELS[id]`: a short (<=6 char) display name per id, mirroring
  `PLAYER_SPRITES` 1:1, used as the JOUEURS/notify fallback wherever a
  player hasn't set (or the game hasn't yet received) their MY NAME -
  same role `PLAYER_COLOR_NAMES` played before, just renamed since
  "color" no longer means anything here.
- Not yet tested in a real game - same caveat as always.

## v0.0.17: all in-game text switched to US English

MrJoufflu's ask: "il faut que les texte du mod soit en anglais USA" - every
player-visible string had been French/joual since v0.0.1 (this repo's
default working language), but the mod itself should read in English.
Translated everything shown to a player: the `ADRESSE?`/`TON NOM?` naming
screen titles (-> `ADDRESS?`/`YOUR NAME?`), the `JOUEURS`/`MON NOM` start
menu items (-> `PLAYERS`/`MY NAME`), the `DEFAULT_NAME` fallback (`JOUEUR`
-> `PLAYER`), the ten `PLAYER_COLOR_NAMES` (ROUGE/BLEU/VERT/JAUNE/MAUVE/
ORANGE/CYAN/ROSE/BRUN/GRIS -> RED/BLUE/GREEN/YELLOW/PURPLE/ORANGE/CYAN/
PINK/BROWN/GRAY), and every `notify()` textbox (connecting/connected/
disconnected/error messages, the empty-IP and keyboard-error messages,
the "(you)"/"Nobody yet" JOUEURS-list entries). `manifest.json`'s
description and `README.md` updated to match the new menu labels (both
were already written in English prose, just referencing the old French
labels in a couple of spots). Re-checked every translated textbox string
against the ~18-safe-char-per-line budget (see `wrapAddress()`'s comment)
since English wording runs different lengths than the French it replaced
- worst case is a color name in a JOUEURS/notify line
(`YELLOW`/`PURPLE`/`ORANGE`/`BROWN`, all 6 chars, same ballpark as the
French set's longest entries) so nothing needed re-wrapping. Source code
comments and this file's own history are left as-is - not player-facing,
and rewriting past entries would erase the actual development record.

## v0.0.16: real sprites + player names - not yet tested

MrJoufflu's ask after confirming v0.0.15 worked: "la ça prend des vrai
sprite, mais surtout la possibilité de mettre un nom en ligne a la
personnes pour ce reconnaitre" (real sprites, but MOSTLY the ability to
set a name so people recognize each other).

- `assets/sprites/generate_sprites.py` (renamed from the throwaway
  `_generate.py` - this is a real, keep-in-repo tool now, not a one-off):
  redrawn from a flat filled circle to an actual little person silhouette
  (skin-toned round head with two eye dots, a colored trapezoid torso, two
  dark feet stubs), same 16x16 `trueColor` single-frame approach as
  v0.0.15 otherwise. Regenerated all 10 `player_N.png`; verified by eye
  via a scaled-up preview render, not in-game yet.
- START > GEN1COOP > MON NOM: a new menu item opening a `NamingScreen`
  with NO custom grid override (uses the vanilla alphabet keypad, not
  `ADDRESS_GRID` - names want letters/lowercase, not digits/colon), 8
  chars max (same ballpark as a Gen1 trainer name). Stored via
  `mod.save:set("player_name", ...)`, read back by `localName()`
  (defaults to "JOUEUR" until set).
- Wire protocol grew a trailing name field on every position update:
  client -> host `mapId,x,y,name`, host -> client `id,mapId,x,y,name`.
  Name is always the LAST field on purpose, so the existing `mapId`
  capture pattern doesn't need to change shape, just extend by one comma
  group. `remoteNames[id]` (separate table from `remoteMarkers`, so a
  name is known even for a player not currently on the local player's
  map) is set from `updateMarker()`'s new optional `name` argument.
  `relay_server.py` needs no code change - it treats each line after the
  sender-tag as opaque text and just re-prepends the id, so the extra
  field rides through untouched (not yet re-tested against the new
  format, but the mechanism doesn't parse fields at all).
- JOUEURS now shows `id name (color)` instead of just the color, falling
  back to the color name if no position update (and therefore no name)
  has arrived from that player yet. Disconnect notices on the host
  ("joueur N deconnecte") now use the last known name too, same fallback.
- **Deliberately did NOT draw the name floating over each marker in the
  world**, even though that's arguably the more obviously "real"
  interpretation of the ask. Checked `render.hud` (`src/core/Game.lua`,
  documented in `docs/modding.md`) in detail: its `viewport` argument is
  explicitly scoped to "the letterbox margins without drawing over the
  playfield" - `gameX/gameY/gameWidth/gameHeight/scale/dpiX/dpiY`
  describe where the UI canvas lands on screen, not the world canvas.
  The world canvas has its OWN separate offset/scale
  (`Renderer:endFrame`'s `wox/woy/sx/sy`, computed from `worldViewSize()`
  and the survey zoom) that isn't part of the viewport handed to mods at
  all, and isn't exposed anywhere else either. Projecting a tracked
  player's tile position to the exact screen pixel their sprite is
  drawn at would mean either duplicating that internal math and hoping
  it stays in sync with the engine (fragile - it already varies with
  zoom, tilt, DPI, FAITHFUL RATIO lock), or reaching directly into
  `Renderer` internals the same way this project has specifically avoided
  doing everywhere else (networking needed a real declared `permissions`
  entry; there's no equivalent sanctioned door here at all). JOUEURS
  already delivers the actual ask - recognizing who's who - without that
  risk. Worth reopening if gen1recomp ever exposes a real world-to-screen
  helper for mods.
- Not yet tested in a real game - same caveat as every version before
  the one MrJoufflu actually confirms.

## Step 2 CONFIRMED WORKING (v0.0.15)

MrJoufflu confirmed the colored marker actually shows up in a real test
("wow ca fonctionne"). Both major milestones of this project are now
verified in real gameplay, not just by reading source: the connection
layer (v0.0.10/v0.0.14) and now a visible representation of another
player (v0.0.15). Still open: >2 simultaneous players untested, smooth
movement/facing direction not built, internet relay mode untested.

## v0.0.15: step 2, visible player markers - build notes

MrJoufflu asked for step 2 as soon as the input.step fix went out (before
it was even retested): colored markers per player, plus a way to see
who's connected and what color. Built on `mod.world:spawnNpc`/`removeNpc`
(`src/world/WorldAPI.lua`), found by reading through `WorldAPI` looking
for exactly this - it's a real, *documented* mod API ("Runtime objects
are not serialized: a permanent NPC belongs in a maps patch, this is for
scripted and dynamic actors the mod re-spawns on map.entered" - a
near-exact description of this use case), so unlike networking there was
no sandbox reach-around needed at all.

- `assets/sprites/player_0.png`..`player_9.png`: 16x16 `trueColor`
  sprites, one flat color per player id (0=host=red, 1-9=joiners in
  connection order), generated by `assets/sprites/generate_sprites.py`
  (Pillow) - a filled circle with a black outline and a highlight dot,
  not a real character sprite. Confirmed via `SpriteRenderer.new`/
  `getFrameGeometry` that `frames=1` is genuinely safe: any requested
  animation frame index gets clamped to what's on the sheet, so a
  1-frame sprite just never animates rather than erroring - no need to
  match Gen1's real 6-frame walker layout for a first pass.
  `trueColor=true` bypasses the DMG 4-shade palette remap pipeline
  entirely (real RGB, no per-zone tinting), which is what makes an
  explicit per-player color possible rather than whatever the terrain
  shader would otherwise apply.
- `remoteMarkers[id] = {npcId, mapId, x, y}` tracks what's known about
  each other player, on BOTH host and client (the host needs to see
  other players too, not just relay for them). `updateMarker()` always
  despawns and, only if that player's `mapId` matches the local player's
  *current* map (`mod.world:current()`), respawns fresh at the new
  position - `WorldAPI`'s NPC handle only exposes scripted step-by-step
  movement (`scriptMove`), not a direct teleport-to-position, so
  respawn-per-update is the simple path for a first pass. Means markers
  pop between positions instead of walking smoothly, and always face
  down - both known, both fine for proving this works at all.
- `map.entered` triggers `resyncMarkers()`: every tracked player's
  marker needs to appear or disappear when the *local* player changes
  maps, not just wait for that remote player's own next update.
- START > GEN1COOP > JOUEURS: a `ListMenu` of everyone currently known
  and their color name, built from `remoteMarkers` (plus the host's own
  "0 ROUGE (toe)" entry when viewed from the host's own device).
- Known gap: a client is never explicitly told its own peer id (the
  wire protocol only tags positions the host relays *to* someone, never
  a "you are player N" message) - harmless for what JOUEURS shows today
  (a client's own entry never appears in its `remoteMarkers` in the
  first place, so there's nothing to wrongly exclude), but would need
  fixing if a client ever needs to know its own color/id for something
  else later.
- Not yet tested in a real game at all - written and validated by
  reading the engine source (schema, `SpriteRenderer`, `WorldAPI`,
  `NPC.new`'s required `objDef` fields), the same way the earlier
  hook/permission fixes were, but nothing here has run yet.

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

## v0.0.11: N players (up to 10), not yet tested past 2

MrJoufflu asked for up to ~10 players before going further into visible
avatars. Restructured from a single 1:1 connection into a star topology:
every client still only ever opens ONE connection (to the host), and the
host's own game process relays each player's position to everyone else -
not a full mesh, so nobody but the host needs to know more than one IP.

- `MAX_PLAYERS = 10` (host + 9 joiners). `serviceHost()` no longer stops
  accepting after the first join - keeps accepting up to capacity.
- Host tracks `peers` (list of `{socket, id}`) instead of a single
  `peer`; joining players get sequential ids from `nextPeerId` (host is
  implicitly id 0).
- Wire format is now asymmetric on purpose: client -> host stays
  untagged (`mapId,x,y`, host knows the sender from which socket the
  data arrived on); host -> client is tagged (`id,mapId,x,y`, since a
  client needs to know whose position this is - the host's own or any
  relayed peer's).
- `hostRelay()` (new, host-only): sends the host's own tagged position to
  every peer, then for each peer drains what they sent and relays it,
  tagged with that peer's id, to every OTHER peer. Also cleans up peers
  whose socket errors out (logs + a "joueur N deconnecte" textbox).
- Not yet tested with more than 2 devices - the 2-device test that
  confirmed step 1 predates this change.

## Requested next: internet play, not just LAN (no VPN)

MrJoufflu wants to play with viewers/friends over the internet, not just
same-network LAN, without requiring a VPN tool (Hamachi/Radmin/Tailscale
etc. explicitly ruled out - wants it built into the mod). Two realistic
paths, not yet decided between:

1. **Host port-forwards manually.** Zero new code - the host already
   listens on a plain TCP port (51820); forwarding that port on their
   router and sharing their *public* IP instead of LAN IP would work
   with the exact same JOIN flow that already exists. Requires the host
   to touch their router's admin panel (port forwarding), which not
   every streamer/host will want or know how to do, but ships with no
   further mod changes - just documentation.
2. **A relay/rendezvous server.** Real infrastructure (a small server
   living outside any player's game, that host and clients connect OUT
   to - outbound connections work almost everywhere without router
   config). Friendlier for hosts (nothing to configure), but a genuinely
   bigger commitment: needs to be built, hosted, and kept running,
   similar in shape to what Gen1Online's GTS server does for trading.
   This is what step 6 of the original roadmap called "relay server /
   actual internet play - deliberately deferred" - still true, this
   would be un-deferring it.

**MrJoufflu picked option 2 (relay server) directly**, skipping the
port-forwarding stopgap - built in v0.0.12.

## v0.0.14: found the real cause - polling was gated on local movement

MrJoufflu's next test result: the HOST showed "joueur 2 connecte!
(2/9)" - real proof the TCP connections were actually succeeding - but
the joining devices themselves never showed a confirmation. That
narrowed it down completely: the connection genuinely works, this was
purely a feedback-timing bug. `pollConnect()` (and `serviceHost()`,
`receivePositions()`, the relay) were only ever invoked from
`world.stepped`, which only fires when the *local* player takes a
tile-step - a joining player who confirmed an address and then stood
still would never see their own "connecte a ...!" even after the
connection had completed on the wire, because nothing was ever polling
for it.

Fix: found `input.step` (`Game:step`, `src/core/Game.lua`) - fires every
fixed step unconditionally, is the engine's own extension point for
"tool mods" (autoplay, accessibility, input drivers), and its vanilla
implementation is a bare no-op, so wrapping it via `mod.hooks:wrap`
carries none of the rendering-corruption risk a render hook would (a
risk that was the whole reason this was left on `world.stepped` for so
long). Split the host-side relay into `hostBroadcastOwn()` (host's own
position, tied to `world.stepped` - no point spamming an unchanged
position every frame) and `hostReceiveAndRelay()` (draining/relaying
peers' updates, now on `input.step` - needs to run continuously
regardless of the host's own movement). Client-side `pollConnect()` and
`receivePositions()` moved to `input.step` too; `sendPosition()` stays
on `world.stepped` (bandwidth-conscious - no reason to send an unchanged
position every frame either). Not yet retested.

## MrJoufflu paused internet play to focus on LAN first

Reasonable call - LAN (>2 players) hadn't been confirmed yet, and now
neither had the relay. Suggested running two gen1recomp installs on one
PC (separate folders, separate saves) to simulate a 3rd player without
needing 3 physical devices, to actually test the v0.0.11 relay logic.

## v0.0.13: JOIN produced no feedback at all after v0.0.12 - still open

Tried the 2-PC-copies + phone test. On BOTH joining devices (a PC copy
and the phone), typing an address and pressing ED did nothing - no
"connexion a..." textbox, no 10s timeout error, nothing. That's a real
regression: even a failing connect should show *something* immediately
via `notify()`, so this points to the naming screen's confirm never
actually reaching `startClient()` at all, not a network problem.

Read through `NamingScreen:update()`'s actual cell-selection code
(hadn't verified this before, only `findMeta()` and `confirm()`):
confirm triggers on `self.row == edRow and self.col == edCol` when A is
pressed, both freshly computed from `findMeta(self:grid())` every frame
- structurally this should work with `ADDRESS_GRID`'s shape (checked
row widths, the case-switch row, "ED" placement) and no bug was found
by inspection alone.

Rather than keep guessing blind, added three diagnostic checkpoints
instead of more speculative fixes:
1. A textbox the instant JOIN is selected ("ouverture du clavier...") -
   confirms the menu path itself still works.
2. The `NamingScreen.new`+push call is now wrapped in `pcall` - if
   something in `ADDRESS_GRID` or the naming screen itself throws, it
   now shows as "erreur clavier: [message]" instead of failing silently
   (a load-time error in main.lua shows as a big FAILED screen in the
   mod manager, per v0.0.6's crash - but this would be a *runtime* error
   during play, which might not surface anywhere without this).
3. `onDone`'s notify now fires unconditionally, even for a cancelled
   (`confirmed=false`) result, showing exactly what was received.

Whichever of these three does or doesn't show up next test narrows this
down a lot: nothing at all means the menu itself broke; "erreur
clavier" means the grid/screen construction is the problem; "onDone
recu" appearing (or not) settles whether confirm is reaching this mod's
code at all. Not yet retested.

## v0.0.12: relay server for internet play, not yet tested with real people

- `relay_server.py` (new file, standalone Python, NOT part of the
  gen1recomp mod - a separate process someone runs and exposes via
  ngrok or similar): implements the exact same wire protocol as
  `hostRelay()` in `main.lua` (client sends untagged `mapId,x,y`,
  server relays tagged `id,mapId,x,y` to everyone else), using Python's
  `selectors` module for non-blocking I/O across N connections. Verified
  correct locally with a two-socket test script (sent from one, checked
  the other received the right tagged line, both directions) - this is
  the one piece of this whole project actually testable without a real
  gen1recomp instance, since it's plain Python.
- Chose ngrok's free TCP tunnel for deployment over a paid VPS or a
  Cloudflare Tunnel: Cloudflare's free "quick tunnels" are HTTP(S)-only
  (fine for Gen1Online's GTS, which is a REST API, but this relay is raw
  TCP), and ngrok's `ngrok tcp <port>` free tier gives a public
  `host:port` TCP endpoint with nothing to buy and nothing to configure
  on a router.
- Mod-side (`main.lua`): the JOIN screen now accepts `"host:port"` (a
  relay address) as well as a bare LAN IP - `parseAddress()` splits on
  `:`, falling back to the default port 51820 for a plain IP so old
  behavior is unchanged. Client-side connect/relay code
  (`startClient`/`pollConnect`/`sendPosition`/`receivePositions`) needed
  no logic changes at all beyond this - from a client's perspective,
  "connected to a LAN host" and "connected to the relay" are identical,
  by design.
- `ADDRESS_GRID` replaces the old digits-only `IP_GRID`: a relay address
  like `0.tcp.ngrok.io:14589` needs letters, not just digits+dot+colon.
  One case only (DNS is case-insensitive), so no second grid page to
  build.
- New `wrapAddress()` helper: a `host:port` string can run well past the
  ~18-char safe textbox width a bare LAN IP mostly wouldn't
  (`0.tcp.ngrok.io:14589` is 21 chars) - learned from translation-qc's
  many overflow bugs to wrap this proactively instead of waiting for a
  screenshot to prove it broke.
- Not yet tested: no real ngrok tunnel has been stood up and joined from
  a second device. The relay server's *protocol* is verified correct in
  isolation; the *mod's* relay-address handling is not yet verified in
  a real game.

## Step 2 (unstarted): visible remote player

Plan (from the original roadmap): spawn a placeholder sprite per
connected player at their last reported position, shown/hidden based on
whether they currently share a `mapId` with the local player. Open
question carried over from the start of this project and still
unresolved: gen1recomp's sanctioned mod API has no obvious "spawn an NPC
at runtime" surface (the `maps` registry's `objects` field is static map
data merged at load time, not a live spawn call) - Gen1Online reached
directly into `src.world.NPC` and `src.render.SpriteRenderer` for this,
bypassing the mod sandbox the same way this project had to for
networking. Needs the same kind of source-reading pass that found
`mod.hooks:wrap`, `ui.start_menu.items`, and the `network` permission -
check whether there's a real spawn API before assuming another sandbox
reach-around is required.

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
