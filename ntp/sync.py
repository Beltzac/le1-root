#!/usr/bin/env python3
# Minimal NTP client: prints the current UTC epoch, or exits non-zero.
import socket, struct, sys
SERVERS = ["a.st1.ntp.br", "pool.ntp.org", "time.google.com", "200.160.7.186", "162.159.200.1"]
PKT = b'\x1b' + 47 * b'\0'
for srv in SERVERS:
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(4)
        s.sendto(PKT, (srv, 123))
        d, _ = s.recvfrom(1024)
        sec = struct.unpack('!I', d[40:44])[0] - 2208988800
        if sec > 1600000000:
            print(sec)
            sys.exit(0)
    except Exception:
        continue
sys.exit(1)
