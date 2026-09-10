#!/data/data/com.termux/files/usr/bin/bash
# LE1 self-healing root loop (repo copy — deploy to ~/root-loop.sh).
# See post-root/persist.sh for the boot hook that makes re-exploiting unnecessary.
#
#   1. root already works             -> (re)assert boot persistence, exit
#   2. boot hook + sudaemon installed -> do nothing; the hook restores root
#   3. otherwise                      -> up to MAX_ATTEMPTS bounded runs, then stop
LOG="$HOME/root-loop.log"
RUN="$HOME/root_run.log"
PERSIST_DIR="$HOME/.le1"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"

log() { echo "[$(date '+%F %T')] $*" >>"$LOG"; }
su_ok() { /system/xbin/su -c id 2>/dev/null | grep -q 'uid=0'; }
install_persist() {
    [ -x "$PERSIST_DIR/persist.sh" ] || { log "persist.sh not staged — skipped"; return 0; }
    /system/xbin/su -c "sh $PERSIST_DIR/persist.sh $PERSIST_DIR" >>"$LOG" 2>&1
    log "boot persistence asserted (rc=$?)"
}
# Any of the installed autostart hooks counts: vendor rc (primary), the optional
# install-recovery wrapper, or the secondary sudaemon rc.
hook_present() {
    [ -f /vendor/etc/init/le1-boot.rc ] && return 0
    [ -f /system/etc/init/sudaemon.rc ] && return 0
    [ -x /system/bin/install-recovery.sh ] && grep -q 'le1-boot' /system/bin/install-recovery.sh 2>/dev/null && return 0
    return 1
}

log "=== root loop started (pid $$) ==="

if su_ok; then
    log "root already active"
    install_persist
    exit 0
fi

if [ -x /system/bin/sudaemon ] && hook_present; then
    log "boot hook present — waiting for it instead of re-exploiting"
    exit 0
fi

n=0
while [ "$n" -lt "$MAX_ATTEMPTS" ]; do
    n=$((n+1))
    if pgrep -f 'le1_root' >/dev/null 2>&1; then sleep 20; continue; fi
    log "exploit attempt $n/$MAX_ATTEMPTS (timeout 120s)"
    timeout 120 "$HOME/le1_root" >>"$RUN" 2>&1
    log "exploit exit=$?"
    if su_ok; then
        log "root active"
        install_persist
        exit 0
    fi
    sleep 30
done
log "gave up after $MAX_ATTEMPTS attempts"
exit 1
