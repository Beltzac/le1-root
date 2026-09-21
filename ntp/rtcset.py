#!/usr/bin/env python3
# Write the current system time to the RTC. The vendor keeps re-enabling
# auto_time=1, so Android re-reads the RTC; with a dead RTC that reverts the
# clock to 2007 and breaks TLS. Keeping the RTC correct makes auto_time=1 harmless.
import os, fcntl, struct, time, sys
RTC_SET_TIME = 0x4024700a
dev = "/dev/rtc0" if os.path.exists("/dev/rtc0") else "/dev/rtc"
try:
    fd = os.open(dev, os.O_RDWR)
except Exception as e:
    sys.stderr.write("rtcset: open fail: %s\n" % e); sys.exit(1)
t = time.gmtime(int(time.time()))
buf = struct.pack("9i", t.tm_sec, t.tm_min, t.tm_hour, t.tm_mday, t.tm_mon - 1,
                  t.tm_year - 1900, t.tm_wday, t.tm_yday, t.tm_isdst)
try:
    fcntl.ioctl(fd, RTC_SET_TIME, buf)
    print("rtc set " + time.strftime("%F %T", t) + " utc")
except Exception as e:
    sys.stderr.write("rtcset: ioctl fail: %s\n" % e); sys.exit(1)
finally:
    os.close(fd)
