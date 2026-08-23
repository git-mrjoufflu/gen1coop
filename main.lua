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
-- Known rough edges, on purpose for a first slice:
-- - Fixed default port 51820 for LAN hosting.
-- - No reconnect handling if a connection drops.
-- - Needs the "network" permission (declared in manifest.json) - mods
--   run in a real sandbox (src/mods/Sandbox.lua) that denies
--   require("socket") without it.
-- - Markers teleport to each update rather than walking smoothly (no
--   interpolation yet), and always face down (no direction inference
--   from movement yet either).

return function(mod)
  local TextBox = require("src.render.TextBox")
  local Menu = require("src.ui.Menu")
  local ListMenu = require("src.ui.ListMenu")
  local NamingScreen = require("src.ui.NamingScreen")

  local PORT = 51820
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

  -- state: "idle" -> "listening" (host, waiting for players) or
  -- "connecting" (client) -> "connected" -> "error"
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
    local ip = localIP()
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

  -- called on every position update for player `id`, and again from the
  -- map.entered resync below. Always despawns and (if the player is on
  -- the local player's current map) respawns fresh, rather than trying
  -- to move an existing NPC - WorldAPI's Handle only offers scripted
  -- step-by-step movement (scriptMove), not a direct teleport-to-position,
  -- and a respawn-per-update is simplest for a first pass. Means markers
  -- pop between positions instead of walking smoothly - known, fine for
  -- proving this works at all.
  local function updateMarker(id, mapId, x, y, name)
    if name and name ~= "" then remoteNames[id] = name end
    local m = remoteMarkers[id]
    if not m then
      m = {}
      remoteMarkers[id] = m
    end
    m.mapId, m.x, m.y = mapId, x, y
    clearMarker(id)
    if not mod.world or mapId ~= localMapId() then return end
    local npcId, err = mod.world:spawnNpc(mapId, {
      sprite = spriteIdFor(id), x = x, y = y,
    })
    if npcId then
      m.npcId = npcId
    else
      mod.log:warn("spawnNpc for player %d failed: %s", id, tostring(err))
    end
  end

  local function removeMarker(id)
    clearMarker(id)
    remoteMarkers[id] = nil
    remoteNames[id] = nil
  end

  -- local player changed maps: every tracked player's marker needs to
  -- either appear (they were already on the new map, just not visible
  -- before) or disappear (they're on whatever map was just left)
  local function resyncMarkers()
    if not mod.world then return end
    for id, m in pairs(remoteMarkers) do
      clearMarker(id)
      if m.mapId == localMapId() then
        local npcId, err = mod.world:spawnNpc(m.mapId, {
          sprite = spriteIdFor(id), x = m.x, y = m.y,
        })
        if npcId then
          m.npcId = npcId
        else
          mod.log:warn("spawnNpc (resync) for player %d failed: %s", id, tostring(err))
        end
      end
    end
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
        local fallback = PLAYER_LABELS[id] or "?"
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

  -- Wire format is asymmetric on purpose: a client's outgoing line is
  -- untagged ("mapId,x,y,name") since the host already knows who sent it
  -- from which socket the data arrived on; everything the host sends out
  -- is tagged ("id,mapId,x,y,name") since the receiving client needs to
  -- know whose position this is, and it could be the host's or any
  -- peer's. name is always the LAST field specifically so mapId (which
  -- can itself contain digits/underscores but never a comma) stays easy
  -- to pattern-match without worrying about name's contents shifting
  -- field positions.

  -- host only, tied to the host's own movement (world.stepped): sends
  -- the host's own position to every connected player, tagged id 0.
  local function hostBroadcastOwn(payload)
    local hostLine = string.format("0,%s,%d,%d,%s\n",
      tostring(payload.mapId), payload.x, payload.y, localName())
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
          local mapId, x, y, name = line:match("^(.-),(%-?%d+),(%-?%d+),(.*)$")
          if mapId then
            mod.log:info("player %d: map=%s x=%s y=%s name=%s", p.id, mapId, x, y, name)
            updateMarker(p.id, mapId, tonumber(x), tonumber(y), name)
            local relayLine = string.format("%d,%s,%s,%s,%s\n", p.id, mapId, x, y, name)
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
    local line = string.format("%s,%d,%d,%s\n",
      tostring(payload.mapId), payload.x, payload.y, localName())
    local ok, err = peer:send(line)
    if not ok and err ~= "timeout" then
      mod.log:warn("send failed: %s - peer likely disconnected", tostring(err))
      peer = nil
      state = "error"
      notify("Gen1Coop:\nconnection lost.")
    end
  end

  -- client only: everything the host sends is tagged "id,mapId,x,y" -
  -- id 0 is the host, anything else is a relayed player
  local function receivePositions()
    if not peer then return end
    while true do
      local line, err = peer:receive("*l")
      if line then
        local id, mapId, x, y, name = line:match("^(%-?%d+),(.-),(%-?%d+),(%-?%d+),(.*)$")
        if id then
          mod.log:info("player %s: map=%s x=%s y=%s name=%s", id, mapId, x, y, name)
          updateMarker(tonumber(id), mapId, tonumber(x), tonumber(y), name)
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
    elseif state == "connecting" then
      pollConnect()
    elseif state == "connected" then
      receivePositions()
    end
    return next(g, dt)
  end)

  mod.events:on("game.ready", function(payload)
    game = payload and payload.game
  end)

  -- local player warped/walked onto a new map: every tracked remote
  -- player's marker needs to be re-evaluated against the new map, not
  -- just wait for that player's own next position update
  mod.events:on("map.entered", function()
    resyncMarkers()
  end)

end
