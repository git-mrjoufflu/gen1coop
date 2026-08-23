-- Gen1 Co-op prototype, step 1: prove two gen1recomp instances can talk
-- to each other at all. No visible remote player yet - the point of this
-- slice is the connection itself, shown via an in-game textbox.
--
-- v0.0.6: everything is driven from an in-game menu now instead of a
-- hand-edited config.lua. START menu > GEN1COOP > HOST or JOIN. JOIN
-- opens a numeric keypad (built on NamingScreen, the same widget the
-- naming/nickname screens use, with a custom digits-and-dot grid scoped
-- to just this screen via its title) to type in the host's IP. This
-- matters most for the Android side of testing, where hand-editing a
-- text file inside an installed mod's folder isn't practical the way it
-- is on PC.
--
-- Known rough edges, on purpose for a first slice:
-- - LAN/port-forward only, no relay server. Fixed port 51820.
-- - Polling only happens on world.stepped (the local player has to move
--   for the socket to be serviced), not every frame.
-- - One peer only. No reconnect handling.
-- - Needs the "network" permission (declared in manifest.json) - mods
--   run in a real sandbox (src/mods/Sandbox.lua) that denies
--   require("socket") without it.

return function(mod)
  local TextBox = require("src.render.TextBox")
  local Menu = require("src.ui.Menu")
  local NamingScreen = require("src.ui.NamingScreen")

  local PORT = 51820
  local NAMING_TITLE = "IP DU HOST?"

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

  -- state: "idle" -> "listening" (host, waiting for a client) or
  -- "connecting" (client) -> "connected" -> "error"
  local state = "idle"
  local isHost = false
  local master = nil -- host's listening socket
  local peer = nil    -- the live connection to the other player, once up
  local socket = nil  -- set once require("socket") is confirmed to work

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
    mod.log:info("hosting on port %d, waiting for a player to join...", PORT)
    notify(("Gen1Coop: en\nattente sur le\nport %d..."):format(PORT))
  end

  local function startClient(ip)
    if not ensureSocket() then return end
    isHost = false
    local s = socket.tcp()
    s:settimeout(5) -- one-time blocking connect attempt, 5s cap
    local ok, err = s:connect(ip, PORT)
    if not ok then
      mod.log:error("could not connect to %s:%d - %s", ip, PORT, tostring(err))
      state = "error"
      notify(("Gen1Coop:\nconnexion a\n%s\nratee."):format(ip))
      return
    end
    s:settimeout(0) -- non-blocking from here on
    peer = s
    state = "connected"
    mod.log:info("connected to host %s:%d", ip, PORT)
    mod.save:set("last_ip", ip)
    notify(("Gen1Coop:\nconnecte a\n%s!"):format(ip))
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
              if confirmed and ip ~= "" then startClient(ip) end
            end,
          }))
        end },
    }, { title = "GEN1COOP" }))
  end

  -- scoped by title so this only swaps the grid for OUR naming screen,
  -- never the player's actual name-entry / nickname screens
  mod.hooks:on("ui.naming.grid", function(base, ctx)
    if ctx.title == NAMING_TITLE then return IP_GRID end
    return base
  end)

  mod.hooks:on("ui.start_menu.items", function(_, items)
    items[#items + 1] = { label = "GEN1COOP", onSelect = openConnectMenu }
    return items
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
      local line, err = peer:receive("*l")
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

  mod.events:on("game.ready", function(payload)
    game = payload and payload.game
  end)

  mod.events:on("world.stepped", function(payload)
    flushNotify()
    if isHost then
      serviceHost()
    end
    if state == "connected" then
      sendPosition(payload)
      receivePositions()
    end
  end)
end
