#!/system/bin/sh
# install-recovery.sh — LE1 boot hook.
#
# The stock MediaTek ramdisk init.rc defines:
#
#     service flash_recovery /system/bin/install-recovery.sh
#         class main
#         oneshot
#
# and that ramdisk init.rc is always parsed (unlike /system/etc/init/*.rc on
# this build), so replacing this file with a one-line launcher gives us a
# guaranteed root process at every boot.
#
# The original stock script is preserved as install-recovery.sh.stock by the
# installer, so the stock recovery-restore behaviour can be replayed if needed.
#
# Do NOT add logic here and exit: `oneshot` makes init kill the whole process
# group when this exits. All the real work (which must outlive the launch) lives
# in le1-boot.sh, which never exits.
exec /system/bin/le1-boot.sh
