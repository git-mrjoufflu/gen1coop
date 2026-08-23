-- Edit this before launching. No in-game UI yet - this is step 1.
--
-- One player is the "host": they pick a port and share their LAN IP with
-- the other player. The other player is the "client": they set role to
-- "client" and put the host's IP in host_ip. Same port on both.
--
-- To find your LAN IP on Windows: open PowerShell, run `ipconfig`, use
-- the "IPv4 Address" under your active adapter (usually 192.168.x.x).
-- This only works over a LAN (or with port forwarding) for now - no
-- relay server yet.
return {
  role = "host",        -- "host" or "client"
  port = 51820,
  host_ip = "192.168.1.100", -- only read when role == "client"
}
