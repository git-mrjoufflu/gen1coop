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
-- Known rough edges, on purpose for a first slice:
-- - LAN/port-forward only, no dedicated relay server. Fixed port 51820.
-- - Polling only happens on world.stepped (the local player has to move
--   for sockets to be serviced), not every frame.
-- - No reconnect handling if a connection drops.
-- - Needs the "network" permission (declared in manifest.json) - mods
--   run in a real sandbox (src/mods/Sandbox.lua) that denies
--   require("socket") without it.

return function(mod)
  local TextBox = require("src.render.TextBox")
  local Menu = require("src.ui.Menu")
  local NamingScreen = require("src.ui.NamingScreen")

  local PORT = 51820
  local NAMING_TITLE = "IP DU HOST?"
  -- host + up to this many clients. Star topology: every client only
  -- ever opens ONE connection (to the host), and the host relays each
  -- player's position to everyone else - not a full mesh, so this is
  -- one extra "relay" duty for the host's own game process, not a
  -- separate server. Simplest way to get N players without asking
  -- everyone to know everyone else's IP.
  local MAX_PLAYERS = 10

  -- numeric keypad grid for IP entry - NamingScreen requires an "ED"
  -- confirm cell and a trailing single-cell case-switch row to keep its
  -- own confirm/case-flip logic working (see findMeta in NamingScreen.lua),
  -- even though case doesn't mean anything for digits; both are inert
  -- filler here.
  local IP_GRID = {
    { "1", "2", "3", "4", "5", "6", "7", "8", "9" },
    { "0", ".", "ED", " ", " ", " ", " ", " ", " " },
    { " ", " ", " ", " ", " ", " ", " ", " ", " " },
    { " ", " ", " ", " ", " ", " ", " ", " ", " " },
    { " ", " ", " ", " ", " ", " ", " ", " ", " " },
    { "lower case" },
  }

  local game = nil -- captured from game.ready; needed to push any UI

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
      notify("Gen1Coop:\nreseau (socket)\nindisponible\nsur ce build.")
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
      notify(("Erreur: port\n%d pris ou\nbloque."):format(PORT))
      return
    end
    s:settimeout(0)
    master = s
    state = "listening"
    local ip = localIP()
    mod.log:info("hosting on port %d (ip %s), waiting for a player to join...",
      PORT, tostring(ip))
    if ip then
      notify(("Gen1Coop: IP\n%s\nport %d\nen attente..."):format(ip, PORT))
    else
      notify(("Gen1Coop: en\nattente sur le\nport %d...\n(IP inconnue)"):format(PORT))
    end
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
  local function startClient(ip)
    if not ensureSocket() then return end
    isHost = false
    local s = socket.tcp()
    s:settimeout(0)
    local ok, err = s:connect(ip, PORT)
    if ok then
      -- rare, but possible for a same-machine test: connected instantly
      peer = s
      state = "connected"
      mod.log:info("connected to host %s:%d", ip, PORT)
      mod.save:set("last_ip", ip)
      notify(("Gen1Coop:\nconnecte a\n%s!"):format(ip))
      return
    end
    if err ~= "timeout" and err ~= "Operation already in progress" then
      mod.log:error("could not connect to %s:%d - %s", ip, PORT, tostring(err))
      state = "error"
      notify(("Gen1Coop:\nconnexion a\n%s\nratee:\n%s"):format(ip, tostring(err)))
      return
    end
    pendingConnect = { socket = s, ip = ip, startedAt = os.time() }
    state = "connecting"
    mod.log:info("connecting to %s:%d...", ip, PORT)
    notify(("Gen1Coop:\nconnexion a\n%s..."):format(ip))
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
        "writable, likely a firewall or WiFi client isolation silently " ..
        "dropping it", pendingConnect.ip, PORT, CONNECT_TIMEOUT_SECONDS)
      state = "error"
      notify(("Gen1Coop:\n%s\nne repond pas.\nPare-feu ou\nisolation WiFi?"):format(pendingConnect.ip))
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
      mod.log:info("connected to host %s:%d", pendingConnect.ip, PORT)
      mod.save:set("last_ip", pendingConnect.ip)
      notify(("Gen1Coop:\nconnecte a\n%s!"):format(pendingConnect.ip))
    else
      mod.log:error("connect to %s:%d failed (not established)", pendingConnect.ip, PORT)
      state = "error"
      notify(("Gen1Coop:\nconnexion a\n%s\nratee."):format(pendingConnect.ip))
      s:close()
    end
    pendingConnect = nil
  end

  local function openConnectMenu()
    if not game then return end
    game.stack:push(Menu.new(game, {
      { label = "HOST", onSelect = function() startHost() end },
      { label = "JOIN", onSelect = function()
          game.stack:push(NamingScreen.new(game, {
            title = NAMING_TITLE,
            maxLen = 15,
            default = mod.save:get("last_ip", ""),
            onDone = function(ip, confirmed)
              mod.log:info("naming onDone: ip=%s confirmed=%s", tostring(ip), tostring(confirmed))
              if not confirmed then
                return -- B/cancel - no message, this is a normal back-out
              end
              if ip == "" then
                notify("Gen1Coop:\nIP vide,\nressaie.")
                return
              end
              startClient(ip)
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
    if ctx.title == NAMING_TITLE then return IP_GRID end
    return next(base, ctx)
  end)

  mod.hooks:wrap("ui.start_menu.items", function(next, game, items)
    items[#items + 1] = { label = "GEN1COOP", onSelect = openConnectMenu }
    return next(game, items)
  end)

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
      notify(("Gen1Coop:\njoueur %d\nconnecte!\n(%d/%d)"):format(id, #peers, MAX_PLAYERS - 1))
    end
  end

  -- host only: sends the host's own position to every connected player
  -- (tagged id 0), then for each player, drains whatever they sent and
  -- relays it (tagged with THAT player's id) to every OTHER player.
  -- Wire format is asymmetric on purpose: a client's outgoing line is
  -- untagged ("mapId,x,y") since the host already knows who sent it from
  -- which socket the data arrived on; everything the host sends out is
  -- tagged ("id,mapId,x,y") since the receiving client needs to know
  -- whose position this is, and it could be the host's or any peer's.
  local function hostRelay(payload)
    local hostLine = string.format("0,%s,%d,%d\n", tostring(payload.mapId), payload.x, payload.y)
    for _, p in ipairs(peers) do
      p.socket:send(hostLine) -- best-effort; a dead peer gets cleaned up below
    end

    local dead = {}
    for i, p in ipairs(peers) do
      while true do
        local line, err = p.socket:receive("*l")
        if line then
          local mapId, x, y = line:match("^(.-),(%-?%d+),(%-?%d+)$")
          if mapId then
            mod.log:info("player %d: map=%s x=%s y=%s", p.id, mapId, x, y)
            local relayLine = string.format("%d,%s,%s,%s\n", p.id, mapId, x, y)
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
      notify(("Gen1Coop:\njoueur %d\ndeconnecte."):format(p.id))
      table.remove(peers, dead[i])
    end
  end

  -- client only: sends this player's own position to the host, untagged
  -- (see hostRelay's comment on the wire format)
  local function sendPosition(payload)
    if not peer then return end
    local line = string.format("%s,%d,%d\n", tostring(payload.mapId), payload.x, payload.y)
    local ok, err = peer:send(line)
    if not ok and err ~= "timeout" then
      mod.log:warn("send failed: %s - peer likely disconnected", tostring(err))
      peer = nil
      state = "error"
      notify("Gen1Coop:\nconnexion perdue.")
    end
  end

  -- client only: everything the host sends is tagged "id,mapId,x,y" -
  -- id 0 is the host, anything else is a relayed player
  local function receivePositions()
    if not peer then return end
    while true do
      local line, err = peer:receive("*l")
      if line then
        local id, mapId, x, y = line:match("^(%-?%d+),(.-),(%-?%d+),(%-?%d+)$")
        if id then
          mod.log:info("player %s: map=%s x=%s y=%s", id, mapId, x, y)
        end
      elseif err == "timeout" then
        break -- nothing more to read right now, try again next step
      else
        mod.log:warn("receive failed: %s - peer likely disconnected", tostring(err))
        peer = nil
        state = "error"
        break
      end
    end
  end

  mod.events:on("game.ready", function(payload)
    game = payload and payload.game
  end)

  mod.events:on("world.stepped", function(payload)
    if isHost then
      serviceHost()
      hostRelay(payload)
      return
    end
    if state == "connecting" then
      pollConnect()
    end
    if state == "connected" then
      sendPosition(payload)
      receivePositions()
    end
  end)
end
