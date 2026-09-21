#!/usr/bin/env python3
# GPS time: read NMEA from the MTK mnld nmea2socket (127.0.0.1:7000) and print
# the UTC epoch, or exit non-zero. Works offline (satellites carry atomic-clock
# UTC). This unit's stream carries GGA/GSA/GSV but NOT RMC/ZDA, so the date comes
# from the current system date and only the time-of-day is taken from GPS; the
# date is rolled +-1 day so a UTC-midnight crossing still works.
import socket, sys, time, datetime

HOST, PORT = "127.0.0.1", 7000
BUDGET = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0  # seconds to wait for a fix
now = datetime.datetime.now(datetime.timezone.utc)

def ep(y, mo, d, h, mi, s):
    return int(datetime.datetime(y, mo, d, h, mi, s, tzinfo=datetime.timezone.utc).timestamp())

def from_rmc(f):
    if len(f) < 10 or f[2] != "A" or "." not in f[1] or len(f[9]) < 6:
        return None
    return ep(2000 + int(f[9][4:6]), int(f[9][2:4]), int(f[9][0:2]),
              int(f[1][0:2]), int(f[1][2:4]), int(float(f[1][4:])))

def from_zda(f):
    if len(f) < 5 or "." not in f[1]:
        return None
    return ep(int(f[4]), int(f[3]), int(f[2]),
              int(f[1][0:2]), int(f[1][2:4]), int(float(f[1][4:])))

def from_gga(f):
    # $GPGGA,hhmmss.ss,lat,N,lon,E,fix,sats,... ; fix 0 = no fix
    if len(f) < 7 or "." not in f[1]:
        return None
    if f[6] in ("", "0"):
        return None
    hh, mi, ss = int(f[1][0:2]), int(f[1][2:4]), int(float(f[1][4:]))
    best = None
    for dd in (-1, 0, 1):
        d = now.date() + datetime.timedelta(days=dd)
        cand = datetime.datetime(d.year, d.month, d.day, hh, mi, ss, tzinfo=datetime.timezone.utc)
        if best is None or abs(cand - now) < abs(best - now):
            best = cand
    return int(best.timestamp())

def parse(line):
    f = line.split(",")
    tag = f[0] if f else ""
    try:
        if tag.endswith("RMC"):
            return from_rmc(f)
        if tag.endswith("ZDA"):
            return from_zda(f)
        if tag.endswith("GGA"):
            return from_gga(f)
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
        ln = raw.decode("ascii", "ignore").strip()
        if not ln.startswith("$"):
            continue
        e = parse(ln)
        if e and e > 1600000000:
            print(e)
            sys.exit(0)
sys.exit(1)