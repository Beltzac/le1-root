#!/usr/bin/env python3
# GPS time: read NMEA from the MTK mnld nmea2socket (127.0.0.1:7000) and print
# the UTC epoch from the first valid RMC/ZDA sentence, or exit non-zero.
# Works offline (satellites carry atomic-clock UTC) -- needs a sky fix.
import socket, sys, time, datetime

HOST, PORT = "127.0.0.1", 7000
BUDGET = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0  # seconds to wait for a fix

def epoch(y, mo, d, h, mi, s):
    dt = datetime.datetime(y, mo, d, h, mi, s, tzinfo=datetime.timezone.utc)
    return int(dt.timestamp())

def parse(line):
    f = line.split(",")
    tag = f[0] if f else ""
    try:
        if tag.endswith("RMC"):
            # $xxRMC,hhmmss.ss,A,lat,N,lon,E,spd,cog,ddmmyy,...
            if len(f) < 10 or f[2] != "A" or "." not in f[1] or len(f[9]) < 6:
                return None
            hh, mi = int(f[1][0:2]), int(f[1][2:4])
            ss = int(float(f[1][4:]))
            dd, mo, yy = int(f[9][0:2]), int(f[9][2:4]), int(f[9][4:6])
            return epoch(2000 + yy, mo, dd, hh, mi, ss)
        if tag.endswith("ZDA"):
            # $xxZDA,hhmmss.ss,dd,mm,yyyy,...
            if len(f) < 5 or "." not in f[1]:
                return None
            hh, mi = int(f[1][0:2]), int(f[1][2:4])
            ss = int(float(f[1][4:]))
            return epoch(int(f[4]), int(f[3]), int(f[2]), hh, mi, ss)
    except Exception:
        return None
    return None

deadline = time.time() + BUDGET
try:
    s = socket.create_connection((HOST, PORT), timeout=5)
except Exception as e:
    sys.stderr.write("gps: cannot connect to %s:%d: %s\n" % (HOST, PORT, e))
    sys.exit(1)

buf = b""
while time.time() < deadline:
    try:
        s.settimeout(max(1.0, deadline - time.time()))
        chunk = s.recv(4096)
    except socket.timeout:
        break
    except Exception:
        break
    if not chunk:
        break
    buf += chunk
    while b"\n" in buf:
        raw, buf = buf.split(b"\n", 1)
        line = raw.decode("ascii", "ignore").strip()
        if not line.startswith("$"):
            continue
        e = parse(line)
        if e and e > 1600000000:
            print(e)
            sys.exit(0)
sys.exit(1)