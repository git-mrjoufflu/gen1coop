-- Gen1 Co-op prototype, step 1: prove two gen1recomp instances can talk
-- to each other at all. No visible remote player yet - this just opens a
-- direct TCP connection (LuaSocket, bundled in love.dll on every LOVE2D
-- build, no extra install needed) and shows an in-game textbox when the
-- connection is made, then logs the peer's position every time either
-- side takes a step.
--
-- Confirmation is a textbox, not just a log line, on purpose: the dev
-- console needs an env var set before launch, which isn't practical when
-- testing across different devices/platforms. A textbox needs nothing
-- extra - if you see it, the connection worked.
--
-- Known rough edges, on purpose for a first slice:
-- - LAN/port-forward only, no relay server.
-- - Polling only happens on world.stepped (the local player has to move
--   for the socket to be serviced), not every frame. A per-frame tick
--   needs a render hook, which risks breaking rendering if the
--   passthrough is wrong - not worth that risk before the basic
--   connection is even proven to work.
-- - One peer only. No reconnect handling.
-- - Whichever build you're on needs LuaSocket (require("socket")) to
--   actually work - confirmed present on the Windows LOVE2D build. Not
--   verified on Switch/iOS/other builds.
--
-- Test plan: launch two gen1recomp instances with this mod installed,
-- config.lua set to role="host" on one and role="client" (host_ip set to
-- the host's LAN IP) on the other. Walk around on the host's side after
-- launch (world.stepped only fires on movement) - a textbox should pop
-- up on both sides once the client connects.

return function(mod)
  local TextBox = require("src.render.TextBox")
  local game = nil -- captured from game.ready; needed to push a textbox
  local pendingNotify = nil

  -- game.ready can fire before the player is actually in control (title
  -- screen, save select, intro) - pushing a textbox right then is
  -- untested territory, so notify() just queues the message and
  -- world.stepped (which only ever fires once real overworld movement is
  -- happening) is what actually shows it.
  local function notify(text)
    pendingNotify = text
  end

  local function flushNotify()
    if not pendingNotify or not game or not game.stack then return end
    game.stack:push(TextBox.new(game, pendingNotify, function() end))
    pendingNotify = nil
  end


  local function loadConfig()
    local body = mod:read("config.lua")
    if not body then
      mod.log:warn("no config.lua found, doing nothing")
      return nil
    end
    local chunk, err = loadstring(body, "config.lua")
    if not chunk then
      mod.log:warn("config.lua has a syntax error: %s", tostring(err))
      return nil
    end
    local ok, cfg = pcall(chunk)
    if not ok or type(cfg) ~= "table" then
      mod.log:warn("config.lua did not return a table: %s", tostring(cfg))
      return nil
    end
    return cfg
  end

  local hasSocket, socket = pcall(require, "socket")
  if not hasSocket then
    mod.log:error("require('socket') failed - LuaSocket not available in this build")
    return
  end

  local cfg = loadConfig()
  if not cfg then return end

  -- state: "idle" -> "listening" (host, waiting for a client) or
  -- "connecting" (client) -> "connected" -> "error"
  local state = "idle"
  local master = nil   -- host's listening socket
  local peer = nil      -- the live connection to the other player, once up
  local recvBuffer = ""

  local function startHost()
    local s, err = socket.bind("*", cfg.port)
    if not s then
      mod.log:error("host bind on port %d failed: %s", cfg.port, tostring(err))
      state = "error"
      notify(("Erreur: port\n%d pris ou\nbloque."):format(cfg.port))
      return
    end
    s:settimeout(0)
    master = s
    state = "listening"
    mod.log:info("hosting on port %d, waiting for a player to join...", cfg.port)
    notify(("Gen1Coop: en\nattente sur le\nport %d..."):format(cfg.port))
  end

  local function startClient()
    local s = socket.tcp()
    s:settimeout(5) -- one-time blocking connect attempt, 5s cap
    local ok, err = s:connect(cfg.host_ip, cfg.port)
    if not ok then
      mod.log:error("could not connect to %s:%d - %s", cfg.host_ip, cfg.port, tostring(err))
      state = "error"
      notify(("Gen1Coop:\nconnexion a\n%s\nratee."):format(cfg.host_ip))
      return
    end
    s:settimeout(0) -- non-blocking from here on
    peer = s
    state = "connected"
    mod.log:info("connected to host %s:%d", cfg.host_ip, cfg.port)
    notify(("Gen1Coop:\nconnecte a\n%s!"):format(cfg.host_ip))
  end

  mod.events:on("game.ready", function(payload)
    game = payload and payload.game
    if cfg.role == "host" then
      startHost()
    elseif cfg.role == "client" then
      startClient()
    else
      mod.log:warn("config.lua: role must be 'host' or 'client', got %s", tostring(cfg.role))
    end
  end)

  -- non-blocking accept: keeps trying every step until a client shows up
  local function serviceHost()
    if state ~= "listening" then return end
    local s = master:accept()
    if s then
      s:settimeout(0)
      peer = s
      state = "connected"
      mod.log:info("player joined!")
      notify("Gen1Coop:\nun joueur s'est\nconnecte!")
    end
  end

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

  local function receivePositions()
    if not peer then return end
    while true do
      local line, err, partial = peer:receive("*l")
      if line then
        local mapId, x, y = line:match("^(.-),(%-?%d+),(%-?%d+)$")
        if mapId then
          mod.log:info("peer: map=%s x=%s y=%s", mapId, x, y)
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

  mod.events:on("world.stepped", function(payload)
    flushNotify()
    if cfg.role == "host" then
      serviceHost()
    end
    if state == "connected" then
      sendPosition(payload)
      receivePositions()
    end
  end)
end
