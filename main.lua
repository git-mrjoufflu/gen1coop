-- Gen1 Co-op prototype, step 1: prove gen1recomp instances can talk to
-- each other at all, for up to MAX_PLAYERS players at once. No visible
-- remote players yet - the point of this slice is the connection and
-- position sync themselves, shown via in-game textboxes and logged.
--
-- v0.0.6: everything is driven from an in-game menu instead of a
-- hand-edited config.lua. START menu > GEN1COOP > HOST or JOIN. JOIN
-- opens a numeric keypad (built on NamingScreen, the same widget the
-- naming/nickname screens use, with a custom digits-and-dot grid scoped
-- to just this screen via its title) to type in the host's IP. This
-- matters most for the Android side of testing, where hand-editing a
-- text file inside an installed mod's folder isn't practical the way it
-- is on PC.
--
-- v0.0.11: star topology for >2 players - every client still only opens
-- ONE connection (to the host), and the host relays each player's
-- position to everyone else. Not a full mesh (nobody but the host needs
-- to know more than one IP), but it does mean the host's own game
-- process is doing double duty as the relay, so if the host quits,
-- everyone's connection drops.
--
-- v0.0.12: the JOIN screen now also accepts a "host:port" address, not
-- just a bare LAN IP - for connecting through relay_server.py (a
-- standalone script, not part of this mod, that everyone including the
-- would-be "host" connects OUT to over the internet - see that file's
-- docstring for deployment via ngrok, no VPN/port-forwarding needed on
-- any player's end). LAN hosting (this file's HOST option) still works
-- exactly as before for same-network play with no internet dependency.
--
-- v0.0.14: connection polling moved off world.stepped onto input.step
-- (see that hook's wiring below) - a joining player who confirmed an
-- address and then stood still never saw their own connection succeed,
-- since nothing was polling for it until they moved.
--
-- v0.0.15: visible player markers. mod.world:spawnNpc/removeNpc
-- (src/world/WorldAPI.lua) turned out to be a real, documented mod API
-- for exactly this ("scripted and dynamic actors the mod re-spawns on
-- map.entered") - no sandbox reach-around needed here, unlike
-- networking. Each player gets a fixed color (assets/sprites/, one
-- trueColor 16x16 marker per id) shown only while they share the local
-- player's current map; START > GEN1COOP > JOUEURS lists who's known
-- and their color at any time.
--
-- v0.0.16: real pixel-art person markers (was a flat circle) - see
-- assets/sprites/generate_sprites.py. Also: each player can set a name
-- (START > GEN1COOP > MON NOM, vanilla naming-screen alphabet, 8 chars
-- like a Gen1 trainer name) that now rides along on every position update
-- (wire format grew a trailing ",name" field - see hostBroadcastOwn/
-- sendPosition/hostReceiveAndRelay/receivePositions) and shows in the
-- JOUEURS list and disconnect notices. Deliberately NOT drawn floating
-- over each marker in the world: render.hud's viewport (src/core/Game.lua,
-- documented in docs/modding.md) only exposes the UI-canvas/letterbox
-- geometry ("use the letterbox margins without drawing over the
-- playfield") - the world canvas's own camera-relative offset/scale
-- (Renderer:endFrame's wox/woy/sx/sy, src/render/Renderer.lua) that would
-- be needed to project a tile position to the right screen pixel isn't
-- part of the modding API. Doing it anyway would mean reaching into
-- renderer internals with no stability guarantee - exactly the kind of
-- reach-around this project has avoided everywhere else (networking
-- needed a real declared permission; this doesn't even have that door).
-- JOUEURS already solves the actual ask ("se reconnaitre") without that risk.
--
-- v0.0.17: every player-visible string switched from French/joual to US
-- English (menu labels, screen titles, textbox messages, color names) -
-- this repo's working language stays French in comments/commit history,
-- but the mod itself now reads in English.
--
-- v0.0.18: MrJoufflu didn't want an invented sprite - "les meme sprite
-- que l'original" (the same sprites as the original, not made-up ones).
-- Dropped assets/sprites/ (the hand-drawn pixel-art person) entirely and
-- switched each player marker to a real ROM-extracted overworld sprite
-- id (PLAYER_SPRITES: SPRITE_RED/SPRITE_BLUE/etc.) - the exact graphics
-- the game itself uses for the player and its NPCs, confirmed via
-- src/world/FieldDefaults.lua's PLAYER_SPRITES.walk = "SPRITE_RED" (the
-- local player's own sprite id) and tests/mod_world_tests.lua's spawnNpc
-- calls with real SPRITE_* ids. No custom art and no
-- mod.content.sprites:register needed at all - data.sprites already has
-- these seeded by RomExtractor at import time, same as any vanilla NPC.
--
-- v0.0.19: START > GEN1COOP > MY SPRITE lets each player pick which of
-- the ten PLAYER_SPRITES ids they show up as, instead of it being fixed
-- by connection order. Persisted via mod.save (same as MY NAME) so it's
-- a one-time pick, not something to redo every session. Wire format
-- grew a trailing ",sprite" field (after name) on every position update
-- so the choice reaches other players - see hostBroadcastOwn/
-- sendPosition/hostReceiveAndRelay/receivePositions. A received sprite
-- id is validated against PLAYER_SPRITES (isValidSprite) before ever
-- reaching spawnNpc: NPC.new (src/world/NPC.lua) asserts on an unknown
-- sprite id instead of returning a graceful error like spawnNpc's other
-- failure modes do, so an unrecognized id (protocol drift, a future mod
-- version, corruption) falls back to that player's id-based default
-- sprite instead of risking an uncaught error mid-relay.
--
-- v0.0.20: two asks together - "faut ajuster les sprite selon la
-- direction" + "si on peux avoir aussi les mouvement de jambe des autres
-- joureurs" (face the right direction, and walk-cycle their legs too),
-- and "quand on change le choix de sprite est-ce que notre perso de
-- notre cote peux change de sprite aussi" (does picking MY SPRITE change
-- OUR OWN character too).
--
-- Markers no longer despawn/respawn on every update. A same-map,
-- single-tile step now animates via WorldAPI's Handle:scriptMove
-- (updateMarker/snapMarker/directionOf) instead of teleporting - that
-- gets real walk-cycle frames, smooth pixel movement AND facing all at
-- once, for free: NPC:update (src/world/NPC.lua) only gates its
-- self.moving animation path on self.moving itself, not on self.wanders,
-- so a stationary NPC still walks when scripted to move. remoteFacing
-- tracks each player's last known direction so a snap respawn (first
-- sighting on a map, a warp, a lost handle) still spawns facing the
-- right way instead of resetting to down.
--
-- MY SPRITE now also reskins the LOCAL player's own on-screen character,
-- not just what other players see - see applyLocalSprite()'s comment for
-- why that needed reaching past WorldAPI (no method for it there) into
-- the live Player object directly, declared via the new
-- "engine_internals" permission.
--
-- v0.0.21: "panse tu qu'on peu mettre le nom des joueur au dessus de
-- sprite" - the floating name label v0.0.16 turned down. Revisited it
-- now that v0.0.20 already opened the engine_internals door: drawNameLabels
-- (wrapping render.hud) reconstructs the world canvas's on-screen
-- placement itself, mirroring Renderer:endFrame's own math
-- (Renderer:fitScale(), Zoom.scale(), the world canvas's real size,
-- displayMetrics() rebuilt from plain love.graphics.* calls) since
-- render.hud's own viewport is letterbox-only and doesn't expose it.
-- Deliberately skips drawing rather than guessing wrong: only when the
-- overworld is the actual TOP of the state stack (not merely present
-- underneath a menu/battle), and never in Tilt mode (a perspective
-- projection, not a flat map this math could follow). Each label draws
-- inside its own pcall, with love.graphics.push()/pop() kept OUTSIDE
-- that pcall so one failure can't leave the transform/color stack
-- unbalanced for whatever draws next - this is screen-space code with no
-- way for me to watch it run, so it has to fail safe by construction.
--
-- v0.0.22: MrJoufflu's first real screenshot of v0.0.21 - "bcp trop
-- gros" (way too big), the name comically oversized next to the
-- sprite, next to a real (correctly-sized) naming-screen textbox for
-- comparison in the same shot. Root cause: the label's own TEXT SIZE
-- was drawn with the same zoom-scaled sx/sy used for its POSITION
-- (Zoom.scale(fitScale())) - correct for tracking the sprite as the
-- player zooms, but a real UI textbox's font never grows with survey
-- zoom (Renderer:uiScale() deliberately caps at fitScale - "Zooming IN
-- does not scale the UI up"), so a zoomed view made the label balloon
-- while dialogue text stayed put. Split into two scales: position still
-- uses the zoom-aware one (so the label keeps tracking the sprite), the
-- text itself now uses fitScale alone, further scaled down (LABEL_SCALE)
-- so it reads as a small caption rather than full dialogue-text size.
--
-- v0.0.23: "en fait je le veux quand meme petit" - v0.0.22's LABEL_SCALE
-- 0.5 still wasn't small enough. Cut to 0.3.
--
-- v0.0.24: "serais t'il possible de trouvez l'hotes de session sans
-- entré d'ip? (local lan seulement)" - FIND HOST, a new menu item next
-- to JOIN. While hosting, a UDP socket (DISCOVERY_PORT, separate from
-- PORT) broadcasts a small beacon to the LAN roughly once a second
-- (broadcastDiscovery); FIND HOST just opens a UDP socket and listens
-- for one, reading the host's real IP off the packet's own sender
-- address (UDP recvfrom, not anything the payload has to spell out)
-- rather than asking anyone to type it in, then hands off straight into
-- startClient - the exact same connect path manual JOIN already uses.
-- LAN-only on purpose: broadcast packets don't cross the internet, so
-- relay/internet play still needs the manual JOIN flow. Gives up after
-- DISCOVERY_TIMEOUT_SECONDS with a message pointing at JOIN instead, the
-- same shape as pollConnect's own timeout.
--
-- v0.0.25: "les nom quand on est en vox3d bouge et ne sont pas stable
-- sur le dessus du perso" (the names drift/aren't stable above the
-- character in vox3d mode) - a real screenshot in `mods/voxel_world`
-- ("vox3d"), a THIRD-PARTY render pipeline (docs/modding.md's
-- "Rendering pipelines" section) that replaces the whole world pass with
-- its own 3D diorama via Renderer:setWorldOverride - not the same thing
-- as the engine's own Tilt mode (already skipped), and mutually
-- exclusive with it per that same doc. drawNameLabels' flat worldCanvas
-- math is meaningless once a pipeline owns the world pass, so it now
-- also bails out via Pipelines.worldPipeline() (nil = vanilla flat/tilt,
-- the same query src/world/OverworldController.lua itself uses to
-- decide whether to hand the frame to a pipeline). Renderer.worldOverride
-- itself isn't usable for this check - like worldActive, it gets reset
-- to nil at the end of every endFrame, so "was a pipeline active THIS
-- frame" isn't visible by the time render.hud runs; worldPipeline()
-- answers the persistent "is one active right now" question instead.
--
-- v0.0.26: "ca ne fonctionne pas l'auto host" - confirmed (via a
-- follow-up question) that FIND HOST runs correctly end to end
-- ("searching LAN..." then "no host found" after the timeout), so the
-- beacon itself just wasn't reaching the other device. The limited
-- broadcast address (255.255.255.255) is known to be unreliable in
-- practice - plenty of routers/OS network stacks don't forward it the
-- way a directed subnet broadcast (a.b.c.255 for a /24) does. Host now
-- also computes and sends to that address (guessed from its own IP via
-- localIP() - LuaSocket doesn't expose a real netmask, but /24 covers
-- the overwhelming majority of home/guest networks this targets), on
-- top of the original 255.255.255.255 send, not instead of it. Also
-- started checking sendto's own return value (previously ignored
-- entirely) and logging failures, so a still-not-working report has
-- something concrete to go on. If this still doesn't find a host,
-- Windows Firewall blocking the new UDP port outright is the next
-- likely suspect - outside anything this mod's own code can work around.
--
-- Known rough edges, on purpose for a first slice:
-- - Fixed default port 51820 for LAN hosting.
-- - No reconnect handling if a connection drops.
-- - Needs the "network" permission (declared in manifest.json) - mods
--   run in a real sandbox that denies require("socket") without it.

return function(mod)
  local TextBox = require("src.render.TextBox")
  local Menu = require("src.ui.Menu")
  local ListMenu = require("src.ui.ListMenu")
  local NamingScreen = require("src.ui.NamingScreen")
  -- for applyLocalSprite() below - the one other engine-internals
  -- dependency in this mod besides raw sockets, see that function's
  -- comment for why there's no sanctioned alternative
  local SpriteRenderer = require("src.render.SpriteRenderer")
  -- for drawNameLabels() (render.hud) - see that function's long comment
  -- for why this reaches this deep: render.hud's own viewport is
  -- letterbox-only geometry, not the world canvas's placement
  local Renderer = require("src.render.Renderer")
  local Zoom = require("src.render.Zoom")
  local Tilt = require("src.render.Tilt")
  local Font = require("src.render.Font")
  local Pipelines = require("src.render.Pipelines")

  local PORT = 51820
  -- LAN auto-discovery (FIND HOST): a UDP port, deliberately different
  -- from PORT (the TCP game port) to keep the two concerns apart even
  -- though a TCP and a UDP socket could technically share one number.
  -- Host-only: broadcasts a periodic beacon while listening; a client
  -- who picks FIND HOST just listens for one, reading the host's real
  -- IP straight off the packet's sender address (UDP's own recvfrom
  -- return, not anything embedded in the payload) rather than asking
  -- anyone to type it in. Internet/relay play still needs manual JOIN -
  -- broadcast traffic doesn't cross the internet, only the LAN.
  local DISCOVERY_PORT = 51821
  local DISCOVERY_MAGIC = "GEN1COOP_HOST:"
  local DISCOVERY_TIMEOUT_SECONDS = 5
  -- accepts a plain LAN IP or a "host:port" relay address - kept short,
  -- the naming screen's title bar has limited room
  local NAMING_TITLE = "ADDRESS?"
  -- host + up to this many clients. Star topology: every client only
  -- ever opens ONE connection (to the host), and the host relays each
  -- player's position to everyone else - not a full mesh, so this is
  -- one extra "relay" duty for the host's own game process, not a
  -- separate server. Simplest way to get N players without asking
  -- everyone to know everyone else's IP.
  local MAX_PLAYERS = 10

  -- id 0 is always the host; 1..9 are joiners in the order nextPeerId
  -- hands them out. Each id gets a real, ROM-extracted overworld sprite -
  -- the same graphics the game itself uses for the player and its NPCs
  -- (data.sprites, seeded by RomExtractor at import time - see
  -- src/world/FieldDefaults.lua's PLAYER_SPRITES.walk = "SPRITE_RED" for
  -- the exact id the local player's own sprite is loaded under, and
  -- tests/mod_world_tests.lua's spawnNpc calls for confirmation that any
  -- SPRITE_* id from the ROM is valid there). No custom art, no
  -- mod.content.sprites:register needed at all - data.sprites already
  -- has these keyed and ready, the same way every vanilla NPC gets its
  -- sprite. SPRITE_BLUE is the rival's own sprite; the rest are common
  -- recurring trainer-class NPCs (Hiker, Biker, Sailor, Fisher, Nurse,
  -- Granny, Rocket grunt) - real character graphics, not story-unique
  -- ones like Oak or the Elite Four, to keep other players reading as
  -- "some trainer" rather than "the game's villain."
  local PLAYER_SPRITES = {
    [0] = "SPRITE_RED", "SPRITE_BLUE", "SPRITE_GIRL", "SPRITE_HIKER",
    "SPRITE_BIKER", "SPRITE_SAILOR", "SPRITE_FISHER", "SPRITE_NURSE",
    "SPRITE_GRANNY", "SPRITE_ROCKET",
  }

  -- short fallback label per id, shown in JOUEURS/notify messages until a
  -- player's own MY NAME is known - mirrors PLAYER_SPRITES 1:1
  local PLAYER_LABELS = {
    [0] = "RED", "BLUE", "GIRL", "HIKER", "BIKER",
    "SAILOR", "FISHER", "NURSE", "GRANNY", "ROCKET",
  }

  local function spriteIdFor(playerId)
    return PLAYER_SPRITES[playerId]
  end

  -- reverse lookup (sprite id -> short label) for showing what sprite a
  -- REMOTE player is currently using, once their choice is known
  local SPRITE_LABEL_BY_ID = {}
  for id = 0, 9 do SPRITE_LABEL_BY_ID[PLAYER_SPRITES[id]] = PLAYER_LABELS[id] end

  -- only accept a sprite id a client actually offered on MY SPRITE - NPC.new
  -- (src/world/NPC.lua) does `assert(data.sprites[objDef.sprite], ...)`,
  -- an uncaught error, not a graceful nil/err return like spawnNpc's other
  -- failure modes (unknown mapId IS handled gracefully there). A stray or
  -- future-version sprite id from a peer must not be able to throw here.
  local function isValidSprite(id)
    return SPRITE_LABEL_BY_ID[id] ~= nil
  end

  -- persisted like player_name: set once via MY SPRITE, remembered after.
  -- Defaults to SPRITE_RED (id 0's sprite) - same "everyone starts the
  -- same until they customize" default MY NAME already uses.
  local function localSprite()
    local saved = mod.save:get("player_sprite", PLAYER_SPRITES[0])
    return isValidSprite(saved) and saved or PLAYER_SPRITES[0]
  end

  -- keypad grid for the JOIN screen - covers both a plain LAN IP
  -- ("192.168.1.5") and a "host:port" relay address ("0.tcp.ngrok.io:
  -- 14589", see relay_server.py), so it needs letters too, not just
  -- digits+dot. One page only (DNS names are case-insensitive, so
  -- there's no real need for lower/upper here) - single case, no
  -- second page to build. NamingScreen requires an "ED" confirm cell
  -- and a trailing single-cell case-switch row to keep its own
  -- confirm/case-flip logic working (see findMeta in NamingScreen.lua);
  -- the case row is inert filler here since there's only one page.
  local ADDRESS_GRID = {
    { "A", "B", "C", "D", "E", "F", "G", "H", "I" },
    { "J", "K", "L", "M", "N", "O", "P", "Q", "R" },
    { "S", "T", "U", "V", "W", "X", "Y", "Z", "." },
    { "1", "2", "3", "4", "5", "6", "7", "8", "9" },
    { "0", ":", "ED", " ", " ", " ", " ", " ", " " },
    { "lower case" },
  }

  local NAME_TITLE = "YOUR NAME?"
  local DEFAULT_NAME = "PLAYER"
  -- comma is the wire-protocol field separator - typed names can't ever
  -- contain one since NamingScreen only offers whatever's in the active
  -- grid, and this screen uses the vanilla alphabet grid (no
  -- ui.naming.grid override), which has none
  local function localName()
    return mod.save:get("player_name", DEFAULT_NAME)
  end

  local game = nil -- captured from game.ready; needed to push any UI
  -- forward-declared: openConnectMenu's JOUEURS item references these
  -- before their real bodies are defined further down (need
  -- remoteMarkers/remoteNames, which need PLAYER_LABELS et al. to
  -- exist first) - Lua resolves an undeclared name as a global, not "not
  -- yet assigned", so the `local` here has to come before anything that
  -- reads it, even though the assignment comes later
  local showPlayerList

  -- game.ready can fire before the player is actually in control (title
  -- screen, save select, intro) - pushing a textbox right then is
  -- untested territory. That's not a concern for notify() any more,
  -- though: as of v0.0.6 nothing calls startHost/startClient
  -- automatically at boot - they only ever run from a menu selection or
  -- from inside world.stepped (serviceHost/sendPosition), both already
  -- well past any boot-time risk - so this just pushes immediately.
  local function notify(text)
    if not game or not game.stack then return end
    game.stack:push(TextBox.new(game, text, function() end))
  end

  -- MY SPRITE controls what OTHER players see (via the wire protocol),
  -- but MrJoufflu also wants it to change what the LOCAL player looks
  -- like on their own screen. There's no WorldAPI method for that -
  -- src/world/WorldAPI.lua's own header says "Reaching into OverworldState
  -- internals stays unsupported; anything a mod legitimately needs
  -- belongs here", and there's no belongs-here entry for the player's
  -- own sprite - so this reaches directly into the live Player object,
  -- the same way Player.lua itself builds one
  -- (`SpriteRenderer.new(data.sprites[walkId], "player")`,
  -- src/world/Player.lua). Declared via the "engine_internals" permission
  -- (manifest.json) rather than done quietly - the engine's own
  -- undeclared-require warning (src/mods/Loader.lua's scanRequire) exists
  -- exactly to flag this kind of reach, and every src.ui.*/src.render.*
  -- require this mod already made since v0.0.6 was already triggering it
  -- unlabeled. Low blast radius: only replaces what the LOCAL player's
  -- OWN overworld sprite renders as (confirmed via Player:pose() reading
  -- self.sprite fresh - no external cache keyed by the old instance to
  -- go stale), nothing shared or saved to disk.
  local function applyLocalSprite()
    local ow = mod.world and mod.world:overworld()
    local player = ow and ow.player
    if not player or not game or not game.data then return end
    local spriteDef = game.data.sprites[localSprite()]
    if not spriteDef then return end
    player.sprite = SpriteRenderer.new(spriteDef, "player")
  end

  -- state: "idle" -> "listening" (host, waiting for players) or
  -- "connecting"/"discovering" (client) -> "connected" -> "error"
  -- Host and client use different shapes of "who am I talking to":
  -- a client only ever has one connection (to the host), a host has a
  -- growing list as players join.
  local state = "idle"
  local isHost = false
  local master = nil  -- host's listening socket
  local peer = nil     -- client only: the one connection to the host
  local peers = {}     -- host only: list of { socket, id }, one per joined player
  local nextPeerId = 1 -- host only: 0 is the host itself, 1+ for joiners
  local socket = nil   -- set once require("socket") is confirmed to work

  -- host only: UDP socket the periodic FIND HOST beacon goes out on
  local discoveryBeacon = nil
  local discoveryTick = 0 -- frame counter, so the beacon sends roughly once a second, not every input.step
  -- host only: a.b.c.255 guess (see startHost) - sent alongside the
  -- limited broadcast (255.255.255.255), which some networks don't
  -- forward reliably; nil if the host's own IP couldn't be read
  local discoverySubnetBroadcast = nil
  -- client only: UDP socket while state == "discovering", plus when the
  -- search started (for DISCOVERY_TIMEOUT_SECONDS)
  local discoveryListener = nil
  local discoveryStartedAt = nil

  local function ensureSocket()
    if socket then return true end
    local ok, result = pcall(require, "socket")
    if not ok then
      mod.log:error("require('socket') failed: %s", tostring(result))
      notify("Gen1Coop:\nnetwork (socket)\nunavailable\non this build.")
      return false
    end
    socket = result
    return true
  end

  -- classic LuaSocket trick: a UDP "connect" doesn't send anything or
  -- need the peer to be reachable, it just makes the OS pick a local
  -- address for that route - getsockname() then hands back this
  -- machine's LAN IP without needing an actual internet connection.
  -- Falls back to hostname resolution, then nil (caller just omits the
  -- line) if both fail - not fatal either way, the port still works and
  -- ipconfig/Settings is still an option.
  local function localIP()
    local ok, udp = pcall(socket.udp)
    if not ok then
      mod.log:warn("localIP: socket.udp() threw: %s", tostring(udp))
    elseif not udp then
      mod.log:warn("localIP: socket.udp() returned nil")
    else
      local connected, cerr = udp:setpeername("8.8.8.8", 80)
      if connected then
        local ip = udp:getsockname()
        udp:close()
        if ip then return ip end
        mod.log:warn("localIP: getsockname() returned nothing after connect")
      else
        mod.log:warn("localIP: udp:setpeername failed: %s", tostring(cerr))
        udp:close()
      end
    end
    if not (socket.dns and socket.dns.gethostname) then
      mod.log:warn("localIP: socket.dns.gethostname not available")
      return nil
    end
    local hostname = socket.dns.gethostname()
    if not hostname then
      mod.log:warn("localIP: gethostname() returned nothing")
      return nil
    end
    local ip = socket.dns.toip and select(1, socket.dns.toip(hostname))
    if ip and ip ~= "127.0.0.1" then return ip end
    mod.log:warn("localIP: toip(%s) gave %s", tostring(hostname), tostring(ip))
    return nil
  end

  local function startHost()
    if not ensureSocket() then return end
    isHost = true
    local s, err = socket.bind("*", PORT)
    if not s then
      mod.log:error("host bind on port %d failed: %s", PORT, tostring(err))
      state = "error"
      notify(("Error: port\n%d taken or\nblocked."):format(PORT))
      return
    end
    s:settimeout(0)
    master = s
    state = "listening"
    -- best-effort: FIND HOST is a convenience, not the only way to join
    -- (manual JOIN with a typed IP still works even if this fails) - so a
    -- broadcast-socket problem here logs and moves on rather than
    -- blocking hosting over it
    local ok, du = pcall(socket.udp)
    if ok and du then
      du:setsockname("*", 0)
      local bok, berr = du:setoption("broadcast", true)
      if bok then
        discoveryBeacon = du
        discoveryTick = 0
      else
        mod.log:warn("discovery beacon: setoption broadcast failed: %s", tostring(berr))
        du:close()
      end
    else
      mod.log:warn("discovery beacon: socket.udp() failed: %s", tostring(du))
    end
    local ip = localIP()
    -- the *limited* broadcast (255.255.255.255) is the one that's
    -- unreliable in practice - some routers/OS network stacks don't
    -- forward it the way a *directed* subnet broadcast (a.b.c.255 for a
    -- /24, the overwhelmingly common home-network case) does. Sending to
    -- both costs one extra tiny UDP packet a second and meaningfully
    -- raises the odds FIND HOST actually works - assuming a /24 is a
    -- guess, not something LuaSocket exposes a real netmask for, but a
    -- safe one for the home/guest-network setups this is aimed at.
    if ip then
      local a, b, c = ip:match("^(%d+)%.(%d+)%.(%d+)%.%d+$")
      if a then
        discoverySubnetBroadcast = ("%s.%s.%s.255"):format(a, b, c)
        mod.log:info("discovery beacon: also broadcasting to %s", discoverySubnetBroadcast)
      end
    end
    mod.log:info("hosting on port %d (ip %s), waiting for a player to join...",
      PORT, tostring(ip))
    if ip then
      notify(("Gen1Coop: IP\n%s\nport %d\nwaiting..."):format(ip, PORT))
    else
      notify(("Gen1Coop:\nwaiting on\nport %d...\n(IP unknown)"):format(PORT))
    end
  end

  -- textbox lines cap out around 18 safe characters (see translation-qc,
  -- the sister project, for the many bugs that came from ignoring this);
  -- a "host:port" relay address can easily run past that
  -- ("0.tcp.ngrok.io:14589" is 21) where a plain LAN IP mostly wouldn't,
  -- so wrap anything long across two lines instead of assuming it fits.
  local function wrapAddress(addr)
    if #addr <= 18 then return addr end
    local mid = math.ceil(#addr / 2)
    return addr:sub(1, mid) .. "\n" .. addr:sub(mid + 1)
  end

  -- accepts a plain LAN IP ("192.168.1.5", uses the default PORT) or a
  -- "host:port" relay address (relay_server.py's public address via
  -- ngrok or similar - see that file's docstring)
  local function parseAddress(input)
    local host, portStr = input:match("^([^:]+):(%d+)$")
    if host then return host, tonumber(portStr) end
    return input, PORT
  end

  -- socket mid-connect, or nil once resolved either way
  local pendingConnect = nil

  -- non-blocking connect: a 5s *blocking* attempt (the old v0.0.8
  -- behavior) freezes the whole game on the calling frame - reported as
  -- "ca fait rien" was plausibly that freeze reading as nothing
  -- happening, or a fast failure someone didn't wait through. connect()
  -- on a timeout-0 socket returns immediately with "timeout" while the
  -- OS handshake is still in flight (that's success-so-far, not an
  -- error); pollConnect() (called from world.stepped) checks completion.
  local function startClient(address)
    if not ensureSocket() then return end
    isHost = false
    local host, port = parseAddress(address)
    local s = socket.tcp()
    s:settimeout(0)
    local ok, err = s:connect(host, port)
    if ok then
      -- rare, but possible for a same-machine test: connected instantly
      peer = s
      state = "connected"
      mod.log:info("connected to %s:%d", host, port)
      mod.save:set("last_address", address)
      notify(("Gen1Coop:\nconnected to\n%s!"):format(wrapAddress(address)))
      return
    end
    if err ~= "timeout" and err ~= "Operation already in progress" then
      mod.log:error("could not connect to %s:%d - %s", host, port, tostring(err))
      state = "error"
      notify(("Gen1Coop:\nconnection to\n%s\nfailed:\n%s"):format(wrapAddress(address), tostring(err)))
      return
    end
    pendingConnect = { socket = s, address = address, host = host, port = port, startedAt = os.time() }
    state = "connecting"
    mod.log:info("connecting to %s:%d...", host, port)
    notify(("Gen1Coop:\nconnecting to\n%s..."):format(wrapAddress(address)))
  end

  -- a connect() that never resolves (never becomes writable, success or
  -- failure) usually means something outside this mod's control is
  -- silently dropping the attempt - a firewall, or WiFi client/AP
  -- isolation blocking device-to-device traffic on the same network.
  -- Without this, "connecting" would just sit there forever with no
  -- further feedback, same shape of problem as the old blocking connect.
  local CONNECT_TIMEOUT_SECONDS = 10

  local function pollConnect()
    if not pendingConnect then return end
    local s = pendingConnect.socket
    if os.time() - pendingConnect.startedAt > CONNECT_TIMEOUT_SECONDS then
      mod.log:error("connect to %s:%d timed out after %ds - never became " ..
        "writable, likely a firewall/router blocking it (or, for a relay " ..
        "address, the relay server isn't actually running)",
        pendingConnect.host, pendingConnect.port, CONNECT_TIMEOUT_SECONDS)
      state = "error"
      notify(("Gen1Coop:\n%s\nnot responding.\nFirewall or\nserver down?"):format(wrapAddress(pendingConnect.address)))
      s:close()
      pendingConnect = nil
      return
    end
    local _, writable = socket.select(nil, { s }, 0)
    if not writable or #writable == 0 then
      return -- still in progress, check again next step
    end
    -- getpeername only succeeds on an actually-established connection;
    -- a failed non-blocking connect shows up as "writable" too, just
    -- without a real peer on the other end
    local peername = s:getpeername()
    if peername then
      peer = s
      state = "connected"
      mod.log:info("connected to %s:%d", pendingConnect.host, pendingConnect.port)
      mod.save:set("last_address", pendingConnect.address)
      notify(("Gen1Coop:\nconnected to\n%s!"):format(wrapAddress(pendingConnect.address)))
    else
      mod.log:error("connect to %s:%d failed (not established)", pendingConnect.host, pendingConnect.port)
      state = "error"
      notify(("Gen1Coop:\nconnection to\n%s\nfailed."):format(wrapAddress(pendingConnect.address)))
      s:close()
    end
    pendingConnect = nil
  end

  -- client only: FIND HOST - opens a UDP socket bound to DISCOVERY_PORT
  -- and starts listening for a host's beacon, instead of asking for a
  -- typed IP. LAN-only by nature: broadcast packets don't cross the
  -- internet, so a relay-server address still needs the manual JOIN flow.
  -- Defined here (before openConnectMenu, not down by pollDiscovery
  -- below) for the same forward-reference reason showPlayerList is
  -- forward-declared near the top of this file: openConnectMenu's FIND
  -- HOST button references this by name, and Lua resolves an
  -- undeclared-at-that-point name as a global, not "not yet assigned" -
  -- calling this straight from startClient/pollConnect's neighborhood
  -- (rather than forward-declaring it and defining it near pollDiscovery
  -- later) keeps the connect-flow functions together instead of
  -- splitting startDiscovery from the pollDiscovery it hands off to.
  local function startDiscovery()
    if not ensureSocket() then return end
    local u, err = socket.udp()
    if not u then
      mod.log:error("discovery: socket.udp() failed: %s", tostring(err))
      state = "error"
      notify("Gen1Coop:\nnetwork (socket)\nunavailable\non this build.")
      return
    end
    local ok, berr = u:setsockname("*", DISCOVERY_PORT)
    if not ok then
      mod.log:error("discovery: bind on port %d failed: %s", DISCOVERY_PORT, tostring(berr))
      u:close()
      state = "error"
      notify(("Error: port\n%d taken or\nblocked."):format(DISCOVERY_PORT))
      return
    end
    u:settimeout(0)
    discoveryListener = u
    discoveryStartedAt = os.time()
    isHost = false
    state = "discovering"
    notify("Gen1Coop:\nsearching LAN\nfor a host...")
  end

  local function openConnectMenu()
    if not game then return end
    game.stack:push(Menu.new(game, {
      { label = "HOST", onSelect = function() startHost() end },
      { label = "JOIN", onSelect = function()
          -- construction wrapped in pcall (not just for show - this is
          -- how v0.0.13 tracked down the input.step bug): a runtime
          -- error here would otherwise fail silently instead of showing
          -- "erreur clavier"
          local ok, err = pcall(function()
            game.stack:push(NamingScreen.new(game, {
              title = NAMING_TITLE,
              maxLen = 15,
              default = mod.save:get("last_address", ""),
              onDone = function(ip, confirmed)
                mod.log:info("naming onDone: ip=%s confirmed=%s", tostring(ip), tostring(confirmed))
                if not confirmed then
                  return -- B/cancel - normal back-out
                end
                if ip == "" then
                  notify("Gen1Coop:\nempty IP,\ntry again.")
                  return
                end
                startClient(ip)
              end,
            }))
          end)
          if not ok then
            mod.log:error("failed to open naming screen: %s", tostring(err))
            notify(("Gen1Coop:\nkeyboard error:\n%s"):format(wrapAddress(tostring(err))))
          end
        end },
      { label = "FIND HOST", onSelect = function() startDiscovery() end },
      { label = "PLAYERS", onSelect = function() showPlayerList() end },
      { label = "MY NAME", onSelect = function()
          -- no title override here, so ui.naming.grid's hook (scoped to
          -- NAMING_TITLE/ADDRESS_GRID) doesn't touch this screen - it
          -- falls through to the vanilla alphabet grid, which is exactly
          -- what a person's name needs and ADDRESS_GRID doesn't have
          -- (real names want lowercase, no digits/colon clutter)
          game.stack:push(NamingScreen.new(game, {
            title = NAME_TITLE,
            maxLen = 8,
            default = localName(),
            onDone = function(name, confirmed)
              if not confirmed or name == "" then return end
              mod.save:set("player_name", name)
              notify(("Gen1Coop:\nyour name:\n%s"):format(name))
            end,
          }))
        end },
      { label = "MY SPRITE", onSelect = function()
          local items = {}
          for id = 0, 9 do
            items[#items + 1] = { label = PLAYER_LABELS[id], value = PLAYER_SPRITES[id] }
          end
          game.stack:push(ListMenu.new(game, "MY SPRITE", items, {
            onChoose = function(item, menu)
              mod.save:set("player_sprite", item.value)
              applyLocalSprite()
              notify(("Gen1Coop:\nyour sprite:\n%s"):format(item.label))
              menu:close()
            end,
            onCancel = function() end,
          }))
        end },
    }, { title = "GEN1COOP" }))
  end

  -- mod.hooks:wrap, not :on - the mod-facing method really is "wrap" (see
  -- src/mods/Loader.lua: hooks = { wrap = function(_, name, callback, ...) }),
  -- and the callback receives `next` first (src/mods/Hooks.lua:
  -- pcall(entry.callback, nextFn, unpack(args))), same as any wrapper.
  --
  -- scoped by title so this only swaps the grid for OUR naming screen,
  -- never the player's actual name-entry / nickname screens
  mod.hooks:wrap("ui.naming.grid", function(next, base, ctx)
    if ctx.title == NAMING_TITLE then return ADDRESS_GRID end
    return next(base, ctx)
  end)

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    items[#items + 1] = { label = "GEN1COOP", onSelect = openConnectMenu }
    return next(game, items)
  end)

  -- remotePlayerId -> { npcId = <string, only while spawned>, mapId, x, y }
  -- npcId is nil whenever that player isn't on the local player's
  -- current map - spawnNpc silently does nothing visible in that case
  -- anyway, but tracking it explicitly means map.entered can re-sync
  -- (spawn/despawn) cleanly instead of guessing from spawnNpc's result.
  local remoteMarkers = {}

  -- remotePlayerId -> last name they sent, or nil until their first
  -- position update arrives. Separate table from remoteMarkers since a
  -- name is known even for players not currently on the local player's
  -- map (no npcId yet), e.g. for the JOUEURS list.
  local remoteNames = {}

  -- remotePlayerId -> the sprite id they last sent (their MY SPRITE
  -- choice), or nil until their first position update arrives - same
  -- shape/lifecycle as remoteNames. Falls back to PLAYER_SPRITES[id]
  -- (the id-based default) wherever it's still unknown.
  local remoteSprites = {}

  -- remotePlayerId -> last known facing ("down"/"up"/"left"/"right",
  -- lowercase - Handle:scriptMove/:face's casing, NOT spawnNpc's range
  -- field, which wants uppercase - see spawnFacing below). Kept across a
  -- full despawn/respawn (map change, reconnect) so a marker doesn't
  -- reset to facing down every time it reappears; defaults to "down"
  -- (matching the old always-down behavior) until a real step is seen.
  local remoteFacing = {}

  -- "down" -> "DOWN" for spawnNpc's objDef.range (FACING_FROM_RANGE in
  -- src/world/NPC.lua expects the uppercase cardinal names, unlike
  -- Handle:scriptMove/:face which take the lowercase self.facing values
  -- directly - confirmed both casings via tests/mod_world_tests.lua)
  local function spawnFacing(id)
    return (remoteFacing[id] or "down"):upper()
  end

  -- single-tile cardinal step only (dx/dy is a real player step reported
  -- over the wire, always exactly one tile) - anything else (0, >1,
  -- diagonal) isn't a legal scriptMove target and the caller should snap
  -- instead of trying to animate it
  local function directionOf(fromX, fromY, toX, toY)
    local dx, dy = toX - fromX, toY - fromY
    if dx == 1 and dy == 0 then return "right" end
    if dx == -1 and dy == 0 then return "left" end
    if dx == 0 and dy == 1 then return "down" end
    if dx == 0 and dy == -1 then return "up" end
    return nil
  end

  local function localMapId()
    local cur = mod.world and mod.world:current()
    return cur and cur.mapId
  end

  -- despawns and forgets the marker for one player - disconnect, or
  -- about to respawn it fresh at a new position/map
  local function clearMarker(id)
    local m = remoteMarkers[id]
    if m and m.npcId and mod.world then
      mod.world:removeNpc(m.npcId)
      m.npcId = nil
    end
  end

  -- fresh despawn+respawn at (x,y) facing spawnFacing(id) - used for a
  -- player's first appearance on this map, a teleport/warp (a jump that
  -- isn't a single adjacent step), or if the live NPC handle is
  -- otherwise unavailable. A snap, not an animated walk.
  local function snapMarker(id, mapId, x, y)
    clearMarker(id)
    if not mod.world or mapId ~= localMapId() then return end
    local npcId, err = mod.world:spawnNpc(mapId, {
      sprite = remoteSprites[id] or spriteIdFor(id), x = x, y = y,
      range = spawnFacing(id),
    })
    local m = remoteMarkers[id]
    if npcId then
      m.npcId = npcId
    else
      mod.log:warn("spawnNpc for player %d failed: %s", id, tostring(err))
    end
  end

  -- called on every position update for player `id`, and again from the
  -- map.entered resync below. When the update is a legit single-tile
  -- step from the marker's last known position on the SAME map, animates
  -- it there with Handle:scriptMove (real walk-cycle frames, smooth
  -- pixel movement AND facing, all for free from NPC:update's existing
  -- self.moving path - see src/world/NPC.lua, gated only on self.moving,
  -- not on self.wanders, so a stationary/non-wandering NPC still walks
  -- when scripted to). Otherwise (first sighting on this map, a warp, a
  -- lost handle) falls back to snapMarker.
  local function updateMarker(id, mapId, x, y, name, sprite)
    if name and name ~= "" then remoteNames[id] = name end
    if isValidSprite(sprite) then remoteSprites[id] = sprite end
    local m = remoteMarkers[id]
    local sameMap = m and m.mapId == mapId
    local dir = sameMap and directionOf(m.x, m.y, x, y) or nil
    if dir then remoteFacing[id] = dir end
    if not m then
      m = {}
      remoteMarkers[id] = m
    end
    local hadNpc = m.npcId
    m.mapId, m.x, m.y = mapId, x, y
    if not mod.world or mapId ~= localMapId() then
      clearMarker(id)
      return
    end
    if sameMap and dir and hadNpc then
      local handle = mod.world:npc(mapId, hadNpc)
      if handle then
        handle:scriptMove(dir, 1)
        return
      end
      -- handle vanished somehow - fall through to a snap respawn
    end
    snapMarker(id, mapId, x, y)
  end

  local function removeMarker(id)
    clearMarker(id)
    remoteMarkers[id] = nil
    remoteNames[id] = nil
    remoteSprites[id] = nil
    remoteFacing[id] = nil
  end

  -- local player changed maps: every tracked player's marker needs to
  -- either appear (they were already on the new map, just not visible
  -- before) or disappear (they're on whatever map was just left). Always
  -- a snap (never an animated move) - this is the LOCAL player's own map
  -- change, not a remote player taking a step.
  local function resyncMarkers()
    if not mod.world then return end
    for id, m in pairs(remoteMarkers) do
      clearMarker(id)
      if m.mapId == localMapId() then
        snapMarker(id, m.mapId, m.x, m.y)
      end
    end
  end

  -- floating name labels above each visible marker (the ask this project
  -- turned down back in v0.0.16, when only the color-marker version
  -- existed - see PROGRESS.md for the full history of why, and what
  -- changed to make this attempt worth trying now).
  --
  -- render.hud's own viewport (src/core/Game.lua, docs/modding.md) is
  -- explicitly letterbox-only geometry - "use the letterbox margins
  -- without drawing over the playfield" - not the WORLD canvas's own
  -- placement on screen, which isn't exposed to mods anywhere. This
  -- reconstructs that placement itself, mirroring the exact math
  -- Renderer:endFrame uses internally (src/render/Renderer.lua) for its
  -- `elseif self.worldActive then` branch: displayMetrics() (window vs.
  -- framebuffer pixels and per-axis DPI - built entirely from plain
  -- love.graphics.* calls, not engine-private), Renderer:fitScale() (a
  -- real public method), Zoom.scale() (public), and
  -- Renderer.worldCanvas:getWidth/Height() (a real love Canvas -
  -- PixelCanvas.lua's own comment confirms getWidth/Height "always
  -- reported the requested size", so no need to also replicate
  -- worldViewSize()'s own zoom/tilt sizing logic).
  --
  -- Deliberately conservative about when to even attempt this:
  -- - game.stack:top() ~= the live overworld state -> skip. mod.world's
  --   own overworld() resolves the world state even when something is
  --   pushed OVER it (a menu, a battle) - "so a state pushed over the
  --   world still resolves to the world underneath it" - which is right
  --   for spawnNpc/etc, but wrong here: a label must only draw when the
  --   world is actually what's on screen, not guessed to be underneath
  --   something opaque.
  -- - Tilt.active() -> skip. Tilt mode projects the ground through a
  --   perspective mesh (src/render/Tilt.lua's drawTiltedWorld) - not a
  --   flat linear map, so this math would place labels wrong instead of
  --   just not placing them. Skipping is honest; guessing isn't.
  -- Each marker's own draw is wrapped in its own pcall with the
  -- push/pop OUTSIDE the pcall, so one marker's failure can't leave
  -- love.graphics's transform/color stack unbalanced for anything drawn
  -- after it (TouchControls, or next frame) - this is screen-space code
  -- I can't watch run, so it has to fail safely by construction, not by
  -- hoping it doesn't fail.
  local function displayMetrics()
    local ww, wh = love.graphics.getDimensions()
    local pw, ph = ww, wh
    if love.graphics.getPixelDimensions then
      pw, ph = love.graphics.getPixelDimensions()
    end
    local dpiX, dpiY = 1, 1
    if ww > 0 and pw > 0 then dpiX = pw / ww end
    if wh > 0 and ph > 0 then dpiY = ph / wh end
    if (dpiX == 1 and dpiY == 1) and not love.graphics.getPixelDimensions
       and love.graphics.getDPIScale then
      local d = love.graphics.getDPIScale()
      if d and d > 1e-6 then dpiX, dpiY = d, d end
    end
    if dpiX < 1e-6 then dpiX = 1 end
    if dpiY < 1e-6 then dpiY = 1 end
    return pw, ph, dpiX, dpiY
  end

  -- runs already inside love.graphics.push()/pop() from the caller - draws
  -- in a local space where (0,0) is the label's own center point and one
  -- unit is one native GB pixel, matching Font's own glyph metrics
  local function drawOneLabel(screenX, screenY, sx, sy, name)
    love.graphics.translate(screenX, screenY)
    love.graphics.scale(sx, sy)
    local w = Font.width(name)
    -- same white-box/black-text nameplate every textbox/list in this
    -- game already uses (see e.g. src/ui/ListMenu.lua's own draw()) -
    -- guaranteed readable, and it's the game's own established look
    -- rather than an invented style
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.rectangle("fill", -w / 2 - 1, -1, w + 2, 9)
    love.graphics.setColor(0, 0, 0, 1)
    Font.draw(name, -w / 2, 0)
  end

  local function drawNameLabels(g)
    if not mod.world then return end
    local ow = mod.world:overworld()
    if not ow or not ow.camera or not Renderer.worldCanvas then return end
    if not g or not g.stack or g.stack:top() ~= ow then return end
    if Tilt.active() then return end
    -- a mod-supplied world pipeline (e.g. mods/voxel_world, "vox3d")
    -- replaces the whole world pass with its own 3D/diorama render via
    -- Renderer:setWorldOverride - the flat worldCanvas geometry below is
    -- meaningless there (confirmed with a real screenshot: the label
    -- floated free of the sprite and drifted around instead of sitting
    -- still above its head). Renderer.worldOverride itself gets reset to
    -- nil at the end of every endFrame, so it can't be checked from here
    -- ("was a pipeline active THIS frame" isn't visible by the time
    -- render.hud runs) - Pipelines.worldPipeline() answers the
    -- persistent question ("is one active right now") instead, the same
    -- query src/render/Renderer.lua itself uses to decide whether to
    -- call a pipeline's drawWorld this frame.
    if Pipelines.worldPipeline() then return end

    local pw, ph, dpiX, dpiY = displayMetrics()
    local Sp = Renderer:fitScale()
    local sp = Zoom.scale(Sp)
    if not sp or sp <= 0 then return end
    -- sx/sy (zoom-scaled) place the label's ANCHOR POINT - has to match
    -- the world canvas's own scale exactly, or the label drifts off the
    -- sprite as the player zooms. tsx/tsy (fitScale only, NOT
    -- zoom-scaled) size the TEXT ITSELF - a real UI textbox's font never
    -- grows with the survey zoom (Renderer:uiScale() deliberately caps
    -- at fitScale, "Zooming IN does not scale the UI up"), so a label
    -- using the zoomed sx/sy for its own size read as comically
    -- oversized the moment the player zoomed in even a little (reported
    -- with a screenshot: "bcp trop gros" right after this shipped).
    local sx, sy = sp / dpiX, sp / dpiY
    -- a fraction of fitScale, not full: a name tag reads better as a
    -- small caption than as full dialogue-box-sized text. 0.5 (v0.0.22)
    -- still wasn't small enough per MrJoufflu's follow-up ("en fait je
    -- le veux quand meme petit" - I still want it small) - cut further.
    local LABEL_SCALE = 0.3
    local tsx, tsy = Sp * LABEL_SCALE / dpiX, Sp * LABEL_SCALE / dpiY
    local wvw, wvh = Renderer.worldCanvas:getWidth(), Renderer.worldCanvas:getHeight()
    local wox = math.floor((pw - wvw * sp) / 2) / dpiX
    local woy = math.floor((ph - wvh * sp) / 2) / dpiY

    for id, m in pairs(remoteMarkers) do
      if m.npcId then
        -- reaches past Handle's documented surface (:scriptMove/:face/
        -- :position() only) to .npc.px/.py - the live INTERPOLATED pixel
        -- position mid-step, not just the destination cell :position()
        -- would give, so the label doesn't jump ahead of a still-walking
        -- sprite. Falls back to the cell position if that field is ever
        -- gone (a hot-reload, an engine change) rather than erroring.
        local handle = mod.world:npc(m.mapId, m.npcId)
        local npc = handle and handle.npc
        if npc then
          local px = npc.px or (m.x * 16)
          local py = npc.py or (m.y * 16)
          -- +8 centers over the 16px-wide sprite; the sprite itself draws
          -- 4px above its cell (SpriteRenderer:draw's own `- 4`) and the
          -- label sits another 8px above that
          local canvasX = px - ow.camera.x + 8
          local canvasY = py - ow.camera.y - 4 - 8
          local screenX = wox + canvasX * sx
          local screenY = woy + canvasY * sy
          local name = remoteNames[id] or PLAYER_LABELS[id] or "?"
          love.graphics.push()
          local ok, err = pcall(drawOneLabel, screenX, screenY, tsx, tsy, name)
          love.graphics.pop()
          if not ok then
            mod.log:warn("name label draw failed for player %d: %s", id, tostring(err))
          end
        end
      end
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  showPlayerList = function()
    if not game then return end
    local items = {}
    local selfId = isHost and 0 or nil -- a client doesn't know its own id
    if isHost then
      items[#items + 1] = { label = "0 " .. localName() .. " (you)" }
    end
    local ids = {}
    for id in pairs(remoteMarkers) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do
      if id ~= selfId then
        local sprite = remoteSprites[id]
        local fallback = (sprite and SPRITE_LABEL_BY_ID[sprite]) or PLAYER_LABELS[id] or "?"
        local name = remoteNames[id] or fallback
        items[#items + 1] = { label = ("%d %s (%s)"):format(id, name, fallback) }
      end
    end
    if #items == 0 then
      items[#items + 1] = { label = "Nobody yet" }
    end
    game.stack:push(ListMenu.new(game, "GEN1COOP", items, {
      onChoose = function() end,
      onCancel = function() end,
    }))
  end

  -- host only: keeps accepting new players every step, up to capacity,
  -- for as long as hosting is on (unlike the old single-peer version,
  -- this never stops accepting just because someone already joined)
  local function serviceHost()
    if #peers >= MAX_PLAYERS - 1 then return end -- host itself is one slot
    local s = master:accept()
    if s then
      s:settimeout(0)
      local id = nextPeerId
      nextPeerId = nextPeerId + 1
      table.insert(peers, { socket = s, id = id })
      mod.log:info("player %d joined (%d/%d)", id, #peers, MAX_PLAYERS - 1)
      notify(("Gen1Coop:\nplayer %d (%s)\nconnected!\n(%d/%d)"):format(
        id, PLAYER_LABELS[id] or "?", #peers, MAX_PLAYERS - 1))
    end
  end

  -- host only, runs every input.step: sends one UDP broadcast roughly
  -- once a second (DISCOVERY_TICK_FRAMES) so a FIND HOST client picks it
  -- up without either side needing a request/response round trip - a
  -- client just has to be listening when any one beacon lands, and
  -- there's no harm broadcasting to a LAN with nobody listening.
  -- discoveryBeacon can be nil (startHost's UDP setup failed, or hosting
  -- hasn't started) - a no-op then, manual JOIN still works either way.
  -- Skips once full: no point luring a FIND HOST search toward a lobby
  -- that can't accept it.
  local DISCOVERY_TICK_FRAMES = 60
  local function broadcastDiscovery()
    if not discoveryBeacon then return end
    if #peers >= MAX_PLAYERS - 1 then return end
    discoveryTick = discoveryTick + 1
    if discoveryTick < DISCOVERY_TICK_FRAMES then return end
    discoveryTick = 0
    local payload = DISCOVERY_MAGIC .. localName()
    -- both addresses, not just one: the limited broadcast
    -- (255.255.255.255) is the one that turned out unreliable in real
    -- testing ("ca ne fonctionne pas l'auto host") - some routers/OS
    -- network stacks don't forward it the way a directed subnet
    -- broadcast does. Logged on failure (previously not checked at all)
    -- so a still-not-working report has something to go on beyond
    -- "didn't work."
    local ok1, err1 = discoveryBeacon:sendto(payload, "255.255.255.255", DISCOVERY_PORT)
    if not ok1 then
      mod.log:warn("discovery beacon: sendto 255.255.255.255 failed: %s", tostring(err1))
    end
    if discoverySubnetBroadcast then
      local ok2, err2 = discoveryBeacon:sendto(payload, discoverySubnetBroadcast, DISCOVERY_PORT)
      if not ok2 then
        mod.log:warn("discovery beacon: sendto %s failed: %s", discoverySubnetBroadcast, tostring(err2))
      end
    end
  end

  -- Wire format is asymmetric on purpose: a client's outgoing line is
  -- untagged ("mapId,x,y,name,sprite") since the host already knows who
  -- sent it from which socket the data arrived on; everything the host
  -- sends out is tagged ("id,mapId,x,y,name,sprite") since the receiving
  -- client needs to know whose position this is, and it could be the
  -- host's or any peer's. sprite is always the LAST field, name second
  -- to last, so mapId (which can itself contain digits/underscores but
  -- never a comma) stays easy to pattern-match from the front regardless
  -- of what's in the trailing fields.

  -- host only, tied to the host's own movement (world.stepped): sends
  -- the host's own position to every connected player, tagged id 0.
  local function hostBroadcastOwn(payload)
    local hostLine = string.format("0,%s,%d,%d,%s,%s\n",
      tostring(payload.mapId), payload.x, payload.y, localName(), localSprite())
    for _, p in ipairs(peers) do
      p.socket:send(hostLine) -- best-effort; a dead peer gets cleaned up below
    end
  end

  -- host only, runs every input.step (NOT gated on the host's own
  -- movement - see the input.step wiring below for why that matters):
  -- for each player, drains whatever they sent and relays it, tagged
  -- with THAT player's id, to every OTHER player.
  local function hostReceiveAndRelay()
    local dead = {}
    for i, p in ipairs(peers) do
      while true do
        local line, err = p.socket:receive("*l")
        if line then
          local mapId, x, y, name, sprite =
            line:match("^(.-),(%-?%d+),(%-?%d+),(.-),(.*)$")
          if mapId then
            mod.log:info("player %d: map=%s x=%s y=%s name=%s sprite=%s",
              p.id, mapId, x, y, name, sprite)
            updateMarker(p.id, mapId, tonumber(x), tonumber(y), name, sprite)
            local relayLine = string.format("%d,%s,%s,%s,%s,%s\n",
              p.id, mapId, x, y, name, sprite)
            for j, other in ipairs(peers) do
              if j ~= i then other.socket:send(relayLine) end
            end
          end
        elseif err == "timeout" then
          break -- nothing more from this player right now
        else
          mod.log:warn("player %d receive failed: %s - disconnected", p.id, tostring(err))
          table.insert(dead, i)
          break
        end
      end
    end
    for i = #dead, 1, -1 do
      local p = peers[dead[i]]
      local name = remoteNames[p.id] or PLAYER_LABELS[p.id] or "?"
      notify(("Gen1Coop:\n%s\ndisconnected."):format(name))
      removeMarker(p.id)
      table.remove(peers, dead[i])
    end
  end

  -- client only: sends this player's own position to the host, untagged
  -- (see hostRelay's comment on the wire format)
  local function sendPosition(payload)
    if not peer then return end
    local line = string.format("%s,%d,%d,%s,%s\n",
      tostring(payload.mapId), payload.x, payload.y, localName(), localSprite())
    local ok, err = peer:send(line)
    if not ok and err ~= "timeout" then
      mod.log:warn("send failed: %s - peer likely disconnected", tostring(err))
      peer = nil
      state = "error"
      notify("Gen1Coop:\nconnection lost.")
    end
  end

  -- client only: everything the host sends is tagged
  -- "id,mapId,x,y,name,sprite" - id 0 is the host, anything else is a
  -- relayed player
  local function receivePositions()
    if not peer then return end
    while true do
      local line, err = peer:receive("*l")
      if line then
        local id, mapId, x, y, name, sprite =
          line:match("^(%-?%d+),(.-),(%-?%d+),(%-?%d+),(.-),(.*)$")
        if id then
          mod.log:info("player %s: map=%s x=%s y=%s name=%s sprite=%s",
            id, mapId, x, y, name, sprite)
          updateMarker(tonumber(id), mapId, tonumber(x), tonumber(y), name, sprite)
        end
      elseif err == "timeout" then
        break -- nothing more to read right now, try again next step
      else
        mod.log:warn("receive failed: %s - peer likely disconnected", tostring(err))
        peer = nil
        state = "error"
        for id in pairs(remoteMarkers) do removeMarker(id) end
        break
      end
    end
  end

  -- client only, runs every input.step while state == "discovering":
  -- any packet starting with DISCOVERY_MAGIC is a host's beacon - the
  -- host's IP comes from the packet's own sender address (UDP's
  -- receivefrom), not from anything the payload has to spell out.
  -- Gives up after DISCOVERY_TIMEOUT_SECONDS with no beacon seen, same
  -- shape as pollConnect's own timeout - a search that never finds
  -- anything must still tell the player instead of sitting there quiet.
  local function pollDiscovery()
    if not discoveryListener then return end
    local data, ip = discoveryListener:receivefrom()
    if data then
      if data:sub(1, #DISCOVERY_MAGIC) == DISCOVERY_MAGIC then
        mod.log:info("discovery: found host at %s", tostring(ip))
        discoveryListener:close()
        discoveryListener = nil
        discoveryStartedAt = nil
        startClient(ip)
      end
      -- anything else on this port is ignored, not treated as an error -
      -- could be unrelated broadcast traffic on the same LAN
      return
    end
    if ip ~= "timeout" then
      mod.log:warn("discovery: receivefrom failed: %s", tostring(ip))
    end
    if os.time() - discoveryStartedAt > DISCOVERY_TIMEOUT_SECONDS then
      mod.log:info("discovery: timed out after %ds, no host found", DISCOVERY_TIMEOUT_SECONDS)
      discoveryListener:close()
      discoveryListener = nil
      discoveryStartedAt = nil
      state = "error"
      notify("Gen1Coop:\nno host found.\nTry JOIN with\nan IP instead.")
    end
  end

  -- world.stepped only fires when the LOCAL player takes a tile-step, so
  -- it's the right place for sending this player's own position (no
  -- point spamming an unchanged position every frame) but the wrong
  -- place for anything that needs to happen continuously regardless of
  -- whether this specific player is currently moving - accepting new
  -- players, detecting a completed connect, or relaying OTHER players'
  -- updates promptly. Bug found in testing: a joining player who typed
  -- an address and confirmed but then stood still never saw the
  -- "connecte a ...!" textbox, even though the host's side confirmed the
  -- TCP connection had actually succeeded - pollConnect() was only ever
  -- being called from world.stepped, so it silently never ran until the
  -- player happened to move. input.step (Game:step, src/core/Game.lua)
  -- fires every fixed step unconditionally - it's the engine's own
  -- "tool mod" extension point (autoplay/accessibility/input drivers),
  -- vanilla is a bare no-op, so wrapping it here carries none of the
  -- rendering risk a render hook would.
  mod.events:on("world.stepped", function(payload)
    if isHost then
      hostBroadcastOwn(payload)
    elseif state == "connected" then
      sendPosition(payload)
    end
  end)

  mod.hooks:wrap("input.step", function(next, g, dt)
    if isHost then
      serviceHost()
      hostReceiveAndRelay()
      broadcastDiscovery()
    elseif state == "connecting" then
      pollConnect()
    elseif state == "discovering" then
      pollDiscovery()
    elseif state == "connected" then
      receivePositions()
    end
    return next(g, dt)
  end)

  -- see drawNameLabels' own long comment for the geometry reasoning and
  -- the safety rationale for the pcall/push/pop structure - `g` is
  -- Game.lua's own `self`, needed for the g.stack:top() visibility check
  mod.hooks:wrap("render.hud", function(next, g, viewport)
    drawNameLabels(g)
    return next(g, viewport)
  end)

  mod.events:on("game.ready", function(payload)
    game = payload and payload.game
  end)

  -- local player warped/walked onto a new map: every tracked remote
  -- player's marker needs to be re-evaluated against the new map, not
  -- just wait for that player's own next position update. Also
  -- (re-)applies the local player's own MY SPRITE choice here rather
  -- than only from the menu - map.entered is the first point a live
  -- Player object reliably exists (game.ready can fire before one does),
  -- so this covers a saved-but-not-yet-applied choice at session start,
  -- and re-asserts it on every later map load in case anything ever
  -- rebuilds the Player object with the vanilla sprite in between.
  mod.events:on("map.entered", function()
    resyncMarkers()
    applyLocalSprite()
  end)

end
