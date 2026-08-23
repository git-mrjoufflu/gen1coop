#!/usr/bin/env python3
"""Gen1Coop relay server - standalone, not part of the mod itself.

Runs OUTSIDE gen1recomp entirely. Every player (including whoever would
otherwise be "host" on a LAN) connects OUT to this server as a plain
client - no player needs to accept incoming connections or forward a
router port, since outbound connections work almost everywhere. This
server does the relaying instead of one player's game process.

Wire protocol matches lang-side main.lua exactly, so the mod's existing
client code (sendPosition/receivePositions) works against this server
unchanged - it can't tell the difference between "connected to a LAN
host" and "connected to this relay":

  client -> server:  "mapId,x,y\n"                 (untagged - server
                      knows the sender from which socket it arrived on)
  server -> client:   "id,mapId,x,y\n"              (tagged - the client
                      needs to know whose position this is)

id 1..N is assigned per connection in join order (no id 0 reserved for
a "host" here - nobody's game is special on this server, everyone is a
plain client of the relay).

Usage:
    python relay_server.py [--port 51820] [--max-players 10]

Deployment (no VPS, no port forwarding, no VPN):
    1. Run this script on any machine that stays on while people play
       (your own PC is fine for testing/streaming).
    2. In a separate terminal, expose it with ngrok's free TCP tunnel:
           ngrok tcp 51820
       ngrok prints a public address like "0.tcp.ngrok.io:14589" - THAT
       whole "host:port" string is what players type into the mod's
       JOIN RELAY screen (not your LAN IP, not the bare port).
    3. Free ngrok URLs change every time you restart ngrok. For a
       stable address across sessions, ngrok also has paid static
       domains, or this same script can be deployed on any always-on
       host with an open port (a small VPS, Railway, Fly.io, etc.) -
       see the README for details.
"""

import argparse
import selectors
import socket
import sys

sel = selectors.DefaultSelector()


class Peer:
    __slots__ = ("sock", "addr", "id", "buf")

    def __init__(self, sock, addr, id_):
        self.sock = sock
        self.addr = addr
        self.id = id_
        self.buf = b""


def main():
    ap = argparse.ArgumentParser(description="Gen1Coop position relay server")
    ap.add_argument("--port", type=int, default=51820)
    ap.add_argument("--max-players", type=int, default=10)
    ap.add_argument("--host", default="0.0.0.0")
    args = ap.parse_args()

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((args.host, args.port))
    listener.listen(args.max_players)
    listener.setblocking(False)
    sel.register(listener, selectors.EVENT_READ, data=None)

    peers = {}  # fileobj -> Peer
    next_id = 1

    print(f"[gen1coop-relay] listening on {args.host}:{args.port} "
          f"(max {args.max_players} players)", flush=True)

    def broadcast(line: bytes, except_peer=None):
        dead = []
        for p in peers.values():
            if p is except_peer:
                continue
            try:
                p.sock.sendall(line)
            except OSError:
                dead.append(p)
        for p in dead:
            drop(p, "send failed")

    def drop(peer: Peer, reason: str):
        print(f"[gen1coop-relay] player {peer.id} ({peer.addr}) left: {reason}",
              flush=True)
        try:
            sel.unregister(peer.sock)
        except (KeyError, ValueError):
            pass
        try:
            peer.sock.close()
        except OSError:
            pass
        peers.pop(peer.sock, None)

    try:
        while True:
            for key, _mask in sel.select(timeout=1):
                if key.data is None:
                    # listener socket: accept
                    try:
                        conn, addr = listener.accept()
                    except OSError:
                        continue
                    if len(peers) >= args.max_players:
                        try:
                            conn.close()
                        except OSError:
                            pass
                        print(f"[gen1coop-relay] rejected {addr}: server full",
                              flush=True)
                        continue
                    conn.setblocking(False)
                    peer = Peer(conn, addr, next_id)
                    next_id += 1
                    peers[conn] = peer
                    sel.register(conn, selectors.EVENT_READ, data=peer)
                    print(f"[gen1coop-relay] player {peer.id} joined from "
                          f"{addr} ({len(peers)}/{args.max_players})", flush=True)
                    continue

                peer: Peer = key.data
                try:
                    chunk = peer.sock.recv(4096)
                except OSError as e:
                    drop(peer, str(e))
                    continue
                if not chunk:
                    drop(peer, "closed")
                    continue
                peer.buf += chunk
                while b"\n" in peer.buf:
                    line, peer.buf = peer.buf.split(b"\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    # untagged "mapId,x,y" in, tagged "id,mapId,x,y" out
                    out = f"{peer.id},".encode() + line + b"\n"
                    broadcast(out, except_peer=peer)
    except KeyboardInterrupt:
        print("\n[gen1coop-relay] shutting down", flush=True)
    finally:
        for p in list(peers.values()):
            drop(p, "server shutdown")
        listener.close()


if __name__ == "__main__":
    sys.exit(main())
