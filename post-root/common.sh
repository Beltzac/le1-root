# le1-common.sh — shared helpers, logging, and REVERSIBLE ops for LE1 post-root scripts.
# POSIX sh compatible (mksh / toybox / busybox ash). Sourced by every module.
#
# REVERSIBILITY PRINCIPLE (followed everywhere):
#   - never delete /system files -> rename to *.disabled, or pm disable-user (freeze)
#   - always backup() before editing a file
#   - every mutation is appended to MANIFEST so restore.sh can undo it exactly
#
# Logging writes to stdout + logfile + logcat (best-effort).

LOG_FILE="${LOG_FILE:-/data/local/tmp/le1-postroot.log}"
MANIFEST="${MANIFEST:-/data/local/tmp/le1-manifest.log}"
TAG="${TAG:-LE1}"

# ---- logging ----------------------------------------------------------------
log() {
    _level="$1"; shift
    _msg="$*"
    _ts="$(date '+%F %T')"
    _line="$_ts [$_level] $_msg"
    echo "$_line"
    echo "$_line" >> "$LOG_FILE" 2>/dev/null
    command log -t "$TAG" "$_msg" 2>/dev/null   # 'command' bypasses this function
    return 0
}
info() { log INFO "$@"; }
warn() { log WARN "$@"; }
err()  { log ERROR "$@"; }
ok()   { log OK "$@"; }
die()  { err "$@"; exit 1; }
banner() { log "====" "==== $* ===="; }

# ---- manifest (reversibility audit trail) -----------------------------------
# record <action> <detail...>  ->  "timestamp|action|detail"
record() {
    _action="$1"; shift
    echo "$(date '+%F %T')|$_action|$*" >> "$MANIFEST" 2>/dev/null
    info "[manifest] $_action $*"
}

# ---- guards / mounts --------------------------------------------------------
require_root() {
    _uid="$(id -u 2>/dev/null)"
    # init-service context may lack `id`: fall back to whoami check
    if [ -z "$_uid" ]; then
        _uid="$(whoami 2>/dev/null)"
        [ "$_uid" = "root" ] && _uid=0
    fi
    [ "$_uid" = "0" ] || die "not root (uid=$_uid) — run: su -c 'sh $0'"
}
# remount helpers: try modern syntax first, fall back to legacy (Android 8 toybox varies)
sys_rw() {
    mount -o rw,remount /system /system 2>/dev/null \
        || mount -o rw,remount /system 2>/dev/null \
        || die "remount /system rw failed"
}
sys_ro() {
    mount -o ro,remount /system /system 2>/dev/null \
        || mount -o ro,remount /system 2>/dev/null \
        || warn "remount /system ro failed"
}

# ---- reversible file ops ----------------------------------------------------
backup() {
    [ -e "$1" ] || return 0
    # backups go to /data (big) — /system is ~90% full, never write .bak next to originals there
    _bdir="${BACKUP_DIR:-/data/misc/le1-time/backups}"
    mkdir -p "$_bdir" 2>/dev/null
    _bname="$(echo "$1" | tr '/' '_').prele1.$(date +%s)"
    if cp -a "$1" "$_bdir/$_bname" 2>/dev/null; then
        info "backed up: $1 -> $_bdir/$_bname"
    else
        warn "backup failed: $1"
    fi
    return 0
}

# disable_rc <path.rc>  -> rename to <path.rc>.disabled (reversible; recorded)
disable_rc() {
    _rc="$1"
    [ -f "$_rc" ] || { warn "not found: $_rc"; return 1; }
    if [ -f "$_rc.disabled" ]; then warn "already disabled: $_rc"; return 0; fi
    backup "$_rc"
    mv "$_rc" "$_rc.disabled" && { ok "disabled: $_rc -> .disabled"; record "disable_rc" "$_rc"; }
    return 0
}

# enable_rc <path.rc>  -> restore from <path.rc>.disabled
enable_rc() {
    _rc="$1"
    [ -f "$_rc.disabled" ] || { warn "no .disabled for: $_rc"; return 1; }
    mv "$_rc.disabled" "$_rc" && { ok "re-enabled: $_rc"; record "enable_rc" "$_rc"; }
    return 0
}

# ---- reversible app ops (freeze, never delete) ------------------------------
disable_app() {
    _pkg="$1"
    pm disable-user --user 0 "$_pkg" >/dev/null 2>&1 \
        && { ok "frozen app: $_pkg"; record "disable_app" "$_pkg"; } \
        || warn "freeze failed (already frozen?): $_pkg"
}
enable_app() {
    _pkg="$1"
    pm enable --user 0 "$_pkg" >/dev/null 2>&1 \
        && { ok "unfrozen app: $_pkg"; record "enable_app" "$_pkg"; } \
        || warn "unfreeze failed: $_pkg"
}

# record_create <path> — mark a file we created (so restore.sh may remove it)
record_create() {
    record "create_file" "$1"
}

# ---- misc -------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }

run() {
    info "run: $*"
    "$@"
    _rc=$?
    if [ "$_rc" = 0 ]; then ok "ok: $*"; else warn "failed (rc=$_rc): $*"; fi
    return "$_rc"
}

# source_common — locate + source this library (deployed path or repo-relative)
source_common() {
    if [ -f /system/bin/le1-common.sh ]; then
        . /system/bin/le1-common.sh
    elif [ -f "$(dirname "$0")/common.sh" ]; then
        . "$(dirname "$0")/common.sh"
    else
        echo "ERROR: cannot find common.sh" >&2
        exit 1
    fi
}
