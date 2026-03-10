#!/bin/sh
# NAT-PMP port forwarding for qBittorrent via ProtonVPN
# Runs on Unifi Dream Machine (UDM/UDR) as a systemd service
#
# ProtonVPN's NAT-PMP server only responds to the direct WireGuard peer.
# This script runs on the gateway (the WG peer), requests a port mapping,
# sets iptables rules to forward traffic, and updates qBittorrent's
# listening port via the WebUI API.
set -eu

# --- Required env vars (set in natpmp-qbit.env) ---
: "${GATEWAY:?Set GATEWAY in env file (NAT-PMP server IP, e.g. 10.2.0.1)}"
: "${WG_IFACE:?Set WG_IFACE in env file (WireGuard interface, e.g. wgclt1)}"
: "${WG_SRC:?Set WG_SRC in env file (local WireGuard IP, e.g. 10.2.0.2)}"
: "${VLAN_IFACE:?Set VLAN_IFACE in env file (VLAN bridge interface, e.g. br971)}"
: "${QBIT_HOST:?Set QBIT_HOST in env file (qBittorrent IP address)}"

# --- Optional env vars with defaults ---
QBIT_PORT="${QBIT_PORT:-8080}"
QBIT_USER="${QBIT_USER:-admin}"
QBIT_PASS="${QBIT_PASS:-}"
LEASE_TIME="${LEASE_TIME:-60}"
REFRESH_INTERVAL="${REFRESH_INTERVAL:-45}"

# --- Internal state ---
COOKIE_FILE="/tmp/qbt_cookies"
IPTABLES_COMMENT="natpmp-qbit"
PRIMARY_PORT=""    # qBit's listening port (set once, rarely changes)
KNOWN_PORTS=""     # space-separated list of all ports seen from ProtonVPN
LOGIN_TIME=0

log() { logger -t natpmp-qbit "$*"; echo "$(date '+%Y-%m-%d %H:%M:%S') [natpmp] $*"; }

is_known_port() {
    case " $KNOWN_PORTS " in *" $1 "*) return 0 ;; esac
    return 1
}

ensure_route() {
    if ! ip route get "$GATEWAY" 2>/dev/null | grep -q "$WG_IFACE"; then
        ip route replace "$GATEWAY/32" dev "$WG_IFACE" src "$WG_SRC" 2>/dev/null || true
        log "Added host route for $GATEWAY via $WG_IFACE"
    fi
}

qbit_login() {
    local now
    now=$(date +%s)
    # Re-login at most every 5 minutes
    if [ $((now - LOGIN_TIME)) -lt 300 ] && [ -f "$COOKIE_FILE" ]; then
        return 0
    fi
    result=$(curl -sf -c "$COOKIE_FILE" \
        "http://${QBIT_HOST}:${QBIT_PORT}/api/v2/auth/login" \
        -d "username=${QBIT_USER}&password=${QBIT_PASS}" 2>&1) || return 1
    case "$result" in
        Ok*|ok*) LOGIN_TIME=$now; return 0 ;;
        *) log "Login response: $result"; return 1 ;;
    esac
}

set_qbit_port() {
    local port="$1"
    curl -sf -b "$COOKIE_FILE" \
        "http://${QBIT_HOST}:${QBIT_PORT}/api/v2/app/setPreferences" \
        -d "json={\"listen_port\":${port}}" >/dev/null 2>&1
}

get_qbit_port() {
    curl -sf -b "$COOKIE_FILE" \
        "http://${QBIT_HOST}:${QBIT_PORT}/api/v2/app/preferences" 2>/dev/null \
        | sed -n 's/.*"listen_port":\([0-9]*\).*/\1/p'
}

# Remove all iptables rules tagged with our comment
clear_fw_rules() {
    local table chain pair
    for pair in "nat:PREROUTING" "filter:FORWARD"; do
        table="${pair%%:*}"
        chain="${pair##*:}"
        while true; do
            num=$(iptables -t "$table" -L "$chain" -n --line-numbers 2>/dev/null \
                  | grep "$IPTABLES_COMMENT" | head -1 | awk '{print $1}')
            [ -n "$num" ] || break
            iptables -t "$table" -D "$chain" "$num" 2>/dev/null
        done
    done
}

# Add DNAT + FORWARD rules for a single external port → qBit's primary port
# No MASQUERADE — qBit's default route (via gateway) handles return traffic,
# and preserving real peer IPs avoids qBit deduplicating all inbound as one peer.
# Rules accumulate (not cleared) so all known ports stay forwarded.
add_fw_rules() {
    local ext_port="$1" int_port="$2"

    # DNAT: external port on WG tunnel → qBit's primary listening port
    iptables -t nat -I PREROUTING -i "$WG_IFACE" -p tcp --dport "$ext_port" \
        -j DNAT --to-destination "${QBIT_HOST}:${int_port}" \
        -m comment --comment "$IPTABLES_COMMENT"
    iptables -t nat -I PREROUTING -i "$WG_IFACE" -p udp --dport "$ext_port" \
        -j DNAT --to-destination "${QBIT_HOST}:${int_port}" \
        -m comment --comment "$IPTABLES_COMMENT"

    # FORWARD: allow WG -> VLAN (int_port since DNAT already translated)
    iptables -I FORWARD -i "$WG_IFACE" -o "$VLAN_IFACE" -d "$QBIT_HOST" \
        -p tcp --dport "$int_port" -j ACCEPT \
        -m comment --comment "$IPTABLES_COMMENT"
    iptables -I FORWARD -i "$WG_IFACE" -o "$VLAN_IFACE" -d "$QBIT_HOST" \
        -p udp --dport "$int_port" -j ACCEPT \
        -m comment --comment "$IPTABLES_COMMENT"

    log "Firewall rules added: external $ext_port -> qBit $int_port"
}

# Clean up firewall rules on exit
cleanup() {
    log "Stopping — clearing firewall rules"
    clear_fw_rules
    exit 0
}
trap cleanup INT TERM

log "Starting NAT-PMP port forwarding (gateway=$GATEWAY, qbit=$QBIT_HOST:$QBIT_PORT)"

while true; do
    # Ensure route to VPN gateway goes through WireGuard
    ensure_route

    # Request NAT-PMP mappings (both UDP and TCP)
    natpmpc -a 1 0 udp "$LEASE_TIME" -g "$GATEWAY" >/dev/null 2>&1 || true
    TCP_OUT=$(natpmpc -a 1 0 tcp "$LEASE_TIME" -g "$GATEWAY" 2>&1) || {
        log "ERROR: natpmpc TCP request failed"
        sleep "$REFRESH_INTERVAL"
        continue
    }

    # Parse: "Mapped public port 58540 protocol TCP"
    PORT=$(echo "$TCP_OUT" | sed -n 's/.*Mapped public port \([0-9]*\).*/\1/p' | head -1)
    if [ -z "$PORT" ]; then
        log "ERROR: Could not parse port from natpmpc output"
        sleep "$REFRESH_INTERVAL"
        continue
    fi

    if [ -z "$PRIMARY_PORT" ]; then
        # First port assignment — set qBit listening port and iptables
        PRIMARY_PORT="$PORT"
        KNOWN_PORTS="$PORT"
        log "Primary port set: $PORT"
        clear_fw_rules
        add_fw_rules "$PORT" "$PORT"
        if qbit_login; then
            set_qbit_port "$PORT"
            log "Updated qBittorrent listening port to $PORT"
        fi
    elif is_known_port "$PORT"; then
        # Known port rotated back — iptables rules already exist, nothing to do
        # Just verify fw rules and qBit port haven't been lost
        if ! iptables -t nat -L PREROUTING -n 2>/dev/null | grep -q "$IPTABLES_COMMENT"; then
            log "Firewall rules missing, re-adding all known ports"
            for p in $KNOWN_PORTS; do
                add_fw_rules "$p" "$PRIMARY_PORT"
            done
        fi
        if qbit_login; then
            ACTUAL=$(get_qbit_port)
            if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "$PRIMARY_PORT" ]; then
                log "qBit port mismatch ($ACTUAL != $PRIMARY_PORT), fixing"
                set_qbit_port "$PRIMARY_PORT"
            fi
        fi
    else
        # Genuinely new port — add DNAT to primary port, don't touch qBit
        log "New port discovered: $PORT (known: $KNOWN_PORTS)"
        KNOWN_PORTS="$KNOWN_PORTS $PORT"
        add_fw_rules "$PORT" "$PRIMARY_PORT"
    fi

    sleep "$REFRESH_INTERVAL"
done
