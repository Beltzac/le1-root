#!/system/bin/sh
# install-recovery.sh — OPTIONAL LE1 boot hook (opt-in fallback).
#
# Installed to /system/bin/install-recovery.sh only when persist.sh is run with
# --with-recovery-hook. The stock script is preserved as
# install-recovery.sh.stock.
#
# Why opt-in: this replaces a stock Android system script. The default hook is
# /vendor/etc/init/le1-boot.rc, which init parses unconditionally and which
# touches nothing that shipped with the ROM.
#
# The stock ramdisk init.rc defines:
#     service flash_recovery /system/bin/install-recovery.sh   (class main, oneshot)
# and a oneshot service's process group is SIGKILLed when the main process
# exits — hence the exec into the supervisor, which never exits.
exec /system/bin/le1-boot.sh recovery
