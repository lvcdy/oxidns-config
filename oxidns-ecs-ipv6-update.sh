#!/bin/ash
# ImmortalWrt/OpenWrt: update only the global IPv6 ECS preset for OxiDNS.
# IPv4 is deliberately left untouched until the CPE/CGNAT public IPv4 can be
# discovered through a verified DIRECT path (not accidentally via OpenClash).
set -u

CFG="/etc/oxidns/config.yaml"
INIT="/etc/init.d/oxidns"
LOCK="/var/lock/oxidns-ecs-v6.lock"
TMP=""
CHECKLOG=""

log() {
    logger -t oxidns-ecs-v6 "$*" 2>/dev/null || true
    echo "$*"
}
die() { log "ERROR: $*"; exit 1; }
json_get() { printf '%s\n' "$1" | jsonfilter -e "$2" 2>/dev/null | sed -n '1p'; }

is_global_v6() {
    addr="${1%%/*}"
    [ -n "$addr" ] || return 1
    case "$addr" in
        *%*|*.*|2001:db8:*|2001:db8) return 1 ;;
    esac
    first="${addr%%:*}"
    # Global Unicast Address space: 2000::/3 (first hex digit 2 or 3).
    case "$first" in 2*|3*) return 0 ;; *) return 1 ;; esac
}

[ -r "$CFG" ] || die "Cannot read config: $CFG"
[ -x "$INIT" ] || die "OxiDNS init script not executable: $INIT"
command -v ubus >/dev/null 2>&1 || die "ubus not found"
command -v jsonfilter >/dev/null 2>&1 || die "jsonfilter not found"
command -v oxidns >/dev/null 2>&1 || die "oxidns not found"

mkdir -p /var/lock
if ! mkdir "$LOCK" 2>/dev/null; then
    log "Another ECS update is running; skip."
    exit 0
fi

TMP="${CFG}.ecs-v6-tmp.$$"
CHECKLOG="/tmp/oxidns-ecs-v6-check.$$"
trap 'rm -f "$TMP" "$CHECKLOG"; rmdir "$LOCK" 2>/dev/null || true' 0 HUP INT TERM

# Prefer the ISP-delegated global prefix from wan6, then wan_6, then wan.
WAN6=""
MASK6=""
for iface in wan6 wan_6 wan; do
    status="$(ubus call "network.interface.$iface" status 2>/dev/null)" || continue
    i=0
    while [ "$i" -lt 16 ]; do
        addr="$(json_get "$status" "@.ipv6-prefix[$i].address")"
        mask="$(json_get "$status" "@.ipv6-prefix[$i].mask")"
        if is_global_v6 "$addr"; then
            case "$mask" in ''|*[!0-9]*) mask=0 ;; esac
            if [ "$mask" -ge 32 ] 2>/dev/null && [ "$mask" -le 64 ] 2>/dev/null; then
                WAN6="$addr"
                MASK6="$mask"
                break 2
            fi
        fi
        i=$((i + 1))
    done
done

# If no delegated prefix is exposed, fall back to a global WAN IPv6 address
# and use /64. Never use ULA (fd00::/8), link-local, or documentation addresses.
if [ -z "$WAN6" ]; then
    for iface in wan6 wan_6 wan; do
        status="$(ubus call "network.interface.$iface" status 2>/dev/null)" || continue
        i=0
        while [ "$i" -lt 16 ]; do
            addr="$(json_get "$status" "@.ipv6-address[$i].address")"
            if is_global_v6 "$addr"; then
                WAN6="${addr%%/*}"
                MASK6=64
                break 2
            fi
            i=$((i + 1))
        done
    done
fi

[ -n "$WAN6" ] || die "No global IPv6 address/delegated prefix found on wan6/wan_6/wan. IPv4 ECS was not changed."
[ -n "$MASK6" ] || die "Could not determine IPv6 prefix length."

# Replace preset and mask6 only inside the ecs_wan_v6 plugin block.
if ! awk -v v6="$WAN6" -v mask6="$MASK6" '
    /^  - tag:[[:space:]]*/ {
        tag=$0
        sub(/^  - tag:[[:space:]]*/, "", tag)
        sub(/[[:space:]]*$/, "", tag)
    }
    tag=="ecs_wan_v6" && /^      preset:[[:space:]]*/ {
        print "      preset: \"" v6 "\""
        found_preset=1
        next
    }
    tag=="ecs_wan_v6" && /^      mask6:[[:space:]]*/ {
        print "      mask6: " mask6
        found_mask=1
        next
    }
    { print }
    END {
        if (!found_preset || !found_mask) {
            print "Expected preset and mask6 fields in plugin ecs_wan_v6" > "/dev/stderr"
            exit 42
        }
    }
' "$CFG" > "$TMP"; then
    die "Could not update ECS. Add plugin ecs_wan_v6 with preset and mask6 fields; original config unchanged."
fi

if cmp -s "$CFG" "$TMP"; then
    log "No IPv6 ECS change: prefix=$WAN6/$MASK6. IPv4 ECS remains unchanged."
    exit 0
fi

BACKUP="${CFG}.bak.ecs-v6.$(date +%Y%m%d-%H%M%S)"
cp -p "$CFG" "$BACKUP" || die "Could not back up config to $BACKUP"

# Check the candidate config before replacing the live config.
if ! oxidns check -c "$TMP" >"$CHECKLOG" 2>&1; then
    cat "$CHECKLOG"
    die "OxiDNS check failed; live config unchanged. Backup: $BACKUP"
fi

if ! mv "$TMP" "$CFG"; then
    die "Could not replace config; backup: $BACKUP"
fi

if ! "$INIT" restart; then
    cp -p "$BACKUP" "$CFG"
    "$INIT" restart >/dev/null 2>&1 || true
    die "Restart failed; restored previous config from $BACKUP"
fi

log "Updated IPv6 ECS preset=$WAN6 mask6=$MASK6; backup=$BACKUP. IPv4 ECS was not changed."
exit 0
