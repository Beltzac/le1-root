#!/usr/bin/env bash
# =============================================================================
# backup-emmc.sh — pull a full / critical eMMC backup of the LE1 head unit
# to a big disk (Pi SSD/ADATA/pendrive). Reversible-free (read-only on the
# device; it only reads block devices and streams them out).
#
# Run ON the host that has the target disk (the Pi), because data is PULLED
# from the LE1 over Tailscale SSH and written to local storage.
#
# Usage:
#   ./backup-emmc.sh critical          # MTK must-have partitions (default)
#   ./backup-emmc.sh full              # entire eMMC (mmcblk0 + boot regions)
#   ./backup-emmc.sh list              # just show partitions + sizes
#   ./backup-emmc.sh part <name>       # one partition by by-name
#   COMPRESS=1 ./backup-emmc.sh full   # gzip the images on the receiving side
#
# Requirements (all already true):
#   - LE1 reachable via Tailscale SSH (u0_a50@100.124.251.81:8022)
#   - LE1 already rooted (su daemon installed) — pull runs `su -c 'dd ...'`
# =============================================================================
set -euo pipefail

LE1_HOST="${LE1_HOST:-u0_a50@100.124.251.81}"
LE1_PORT="${LE1_PORT:-8022}"
MODE="${1:-critical}"
ARG="${2:-}"

# ---- storage target: first mounted, writable big disk, else $HOME ----------
detect_root() {
    for m in /mnt/ssd /mnt/adata /mnt/pendrive /; do
        if [ -d "$m" ] && [ -w "$m" ] && mountpoint -q "$m" 2>/dev/null; then
            echo "$m/le1-backup"
            return 0
        fi
    done
    echo "$HOME/le1-backup"
}
BACKUP_ROOT="${BACKUP_ROOT:-$(detect_root)}"
TS="$(date +%Y%m%d-%H%M%S)"
DEST="$BACKUP_ROOT/$TS"
mkdir -p "$DEST"
LOG="$DEST/backup.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG"; }

# ssh to LE1 (Termux user)
le1() { ssh -p "$LE1_PORT" "$LE1_HOST" "$@"; }
# run a command as root on the LE1 via the su daemon
le1_su() { ssh -p "$LE1_PORT" "$LE1_HOST" "su -c '$1'"; }

# ---- deploy a tiny remote helper that lists partitions + sizes --------------
deploy_helper() {
    le1_su 'cat > /data/local/tmp/le1-partlist.sh' <<'HELPER'
#!/system/bin/sh
for n in /dev/block/by-name/*; do
    b=$(basename "$n")
    d=$(readlink -f "$n" 2>/dev/null)
    bd=$(basename "$d")
    s=$(cat "/sys/class/block/$bd/size" 2>/dev/null)
    echo "$b|$d|${s:-0}"
done
for r in /dev/block/mmcblk0boot0 /dev/block/mmcblk0boot1 /dev/block/mmcblk0; do
    [ -e "$r" ] || continue
    bd=$(basename "$r")
    s=$(cat "/sys/class/block/$bd/size" 2>/dev/null)
    echo "$bd|$r|${s:-0}"
done
HELPER
    le1_su 'chmod 755 /data/local/tmp/le1-partlist.sh' >/dev/null 2>&1 || true
}

# fetch inventory: "name|device|sectors" lines (sectors are 512-byte units)
inventory() {
    le1_su 'sh /data/local/tmp/le1-partlist.sh' 2>/dev/null | grep '|'
}

# size in bytes from inventory name
name_bytes() {
    echo "$INV" | awk -F'|' -v n="$1" '$1==n {print $3*512}'
}

pull() {
    # pull <name> <device> [bytes]
    local name="$1" dev="$2" bytes="${3:-0}"
    local out="$DEST/$name.img"
    log "pull: $name ($dev, $((bytes/1024/1024)) MiB)"
    if [ "${COMPRESS:-0}" = "1" ]; then
        le1_su "dd if=$dev bs=1048576 2>/dev/null" | gzip -1 > "$out.gz"
        if gzip -t "$out.gz"; then
            log "  ok: $name.img.gz ($(du -h "$out.gz" | cut -f1))"
        else
            log "  ERROR: gzip -t failed for $name"
        fi
    else
        le1_su "dd if=$dev bs=1048576 2>/dev/null" > "$out"
        local got
        got=$(stat -c %s "$out" 2>/dev/null || wc -c < "$out")
        log "  wrote $(du -h "$out" | cut -f1) ($got bytes)"
        if [ "$bytes" != "0" ] && [ "$got" != "$bytes" ]; then
            log "  WARNING: size mismatch — got $got, expected $bytes"
        fi
    fi
}

banner() { log "=== $* ==="; }

# =============================================================================
banner "LE1 eMMC backup — mode=$MODE"
banner "target: $DEST"
log "checking LE1 reachable..."
if ! le1 'id' >/dev/null 2>&1; then
    log "ERROR: LE1 offline ($LE1_HOST:$LE1_PORT) — power it on and retry"
    exit 1
fi
log "LE1 online: $(le1 'whoami')"

banner "inventory"
deploy_helper
INV="$(inventory)"
echo "$INV" | while IFS='|' read -r n d s; do
    printf '  %-18s %-28s %6d MiB\n' "$n" "$d" "$((s*512/1024/1024))"
done | tee -a "$LOG"

# ---- free-space check ------------------------------------------------------
need_bytes() {
    # critical: sum of the listed partitions; full: mmcblk0 + boot regions
    if [ "$MODE" = "full" ]; then
        echo "$INV" | awk -F'|' '$1=="mmcblk0"||$1=="mmcblk0boot0"||$1=="mmcblk0boot1" {s+=$3*512} END{print s}'
    else
        echo "$INV" | awk -F'|' -v list="$CRITICAL_LIST" 'BEGIN{split(list,a," "); for(i in a)want[a[i]]=1} $1 in want {s+=$3*512} END{print s}'
    fi
}
CRITICAL_LIST="mmcblk0boot0 mmcblk0boot1 preloader lk boot recovery logo tee1 tee2 nvram nvdata nvcfg proinfo protect1 protect2 seccfg frp para expdb metadata oemkeystore md1img md1dsp md1arm7 md3img cache"
NEED=$(need_bytes)
FREE=$(df -k "$BACKUP_ROOT" | tail -1 | awk '{print $4*1024}')
log "need ~$((NEED/1024/1024)) MiB, free $((FREE/1024/1024)) MiB on $BACKUP_ROOT"
if [ "$NEED" -gt "$FREE" ]; then
    log "ERROR: not enough space — point BACKUP_ROOT at a bigger disk"
    exit 1
fi

# =============================================================================
case "$MODE" in
    list)
        log "inventory shown above. done."
        exit 0 ;;
    full)
        banner "full eMMC dump"
        for n in mmcblk0 mmcblk0boot0 mmcblk0boot1; do
            d=$(echo "$INV" | awk -F'|' -v n="$n" '$1==n {print $2}')
            b=$(echo "$INV" | awk -F'|' -v n="$n" '$1==n {print $3*512}')
            [ -n "$d" ] && pull "$n" "$d" "$b"
        done ;;
    part)
        [ -z "$ARG" ] && { echo "usage: $0 part <name>"; exit 1; }
        d=$(echo "$INV" | awk -F'|' -v n="$ARG" '$1==n {print $2}')
        [ -z "$d" ] && { log "ERROR: no partition named $ARG"; exit 1; }
        b=$(echo "$INV" | awk -F'|' -v n="$ARG" '$1==n {print $3*512}')
        pull "$ARG" "$d" "$b" ;;
    critical|*)
        banner "critical partitions"
        for n in $CRITICAL_LIST; do
            d=$(echo "$INV" | awk -F'|' -v n="$n" '$1==n {print $2}')
            b=$(echo "$INV" | awk -F'|' -v n="$n" '$1==n {print $3*512}')
            if [ -z "$d" ]; then
                log "skip: $n (not present)"
                continue
            fi
            pull "$n" "$d" "$b"
        done ;;
esac

banner "done"
log "images in: $DEST"
log "restore notes:"
log "  - individual partition:  dd if=<name>.img of=/dev/block/by-name/<name>"
log "  - full eMMC (SP Flash Tool / mtkclient): use mmcblk0.img"
log "  - NEVER write these images back without first re-checking the partition table"
log "backup manifest + log: $LOG"
