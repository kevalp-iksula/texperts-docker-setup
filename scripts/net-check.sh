#!/usr/bin/env bash

# Requires real bash: arrays, [[ ]], ${var:0:12} substring expansion and
# `set -o pipefail` are not POSIX sh. On Debian and Ubuntu /bin/sh is dash, which
# fails on these in confusing ways. Re-exec under bash so how it is invoked
# cannot matter.
if [ -z "${BASH_VERSION:-}" ]; then
    exec bash "$0" "$@"
fi
################################################################################
# Container network egress diagnostic
#
# Answers one question: can the php container reach the internet, and if not,
# which link in the chain is broken?
#
# Written after a real incident where `make composer-validate` hung for five
# minutes and then reported "credentials rejected". The keys were fine. The
# container had no egress at all: Docker had left several stale bridges behind
# on the SAME subnet, and the live bridge had no `-i br-<id> -j ACCEPT` rule in
# DOCKER-FORWARD and no MASQUERADE rule in nat/POSTROUTING. Outbound SYNs fell
# through to ufw and died on the FORWARD chain's default DROP policy.
#
# That failure is invisible from inside the container (DNS still works, because
# Docker's embedded resolver at 127.0.0.11 answers from the daemon's own network
# stack and never crosses the FORWARD chain) and invisible from the host (the
# host's own traffic does not traverse FORWARD either). Hence this script.
#
# Usage:  ./scripts/net-check.sh        (or: make net-check)
#
# iptables inspection needs root. Without a passwordless sudo the script still
# runs every non-privileged check and tells you which ones it had to skip.
################################################################################

# Deliberately NO `set -e`: almost every check here runs a command that is
# EXPECTED to fail on a broken host, and `-e` would abort at the first finding
# instead of printing the full picture.
set -uo pipefail

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'; NC=$'\033[0m'

# Probed with an 8s connect timeout, never the libcurl default of 300s.
PROBE_URL="https://repo.magento.com/packages.json"   # 401 unauthenticated = reachable
NEUTRAL_URL="https://packagist.org/packages.json"    # tells targeted block from total block
CONNECT_TIMEOUT=8

problems=0
warnings=0
skipped_root=0

say()  { echo -e "$*"; }
ok()   { say "  ${GREEN}✓${NC} $*"; }
bad()  { say "  ${RED}✗${NC} $*"; problems=$((problems + 1)); }
note() { say "  ${YELLOW}⚠${NC} $*"; warnings=$((warnings + 1)); }
info() { say "    $*"; }
step() { say ""; say "${BLUE}[$1]${NC} $2"; }

# iptables needs root. Use `sudo -n` (never prompt) so this stays safe to run
# unattended; report the gap rather than hanging on a password prompt.
if [[ $EUID -eq 0 ]]; then
    ipt() { iptables "$@" 2>/dev/null; }
    HAVE_ROOT=1
elif sudo -n true 2>/dev/null; then
    ipt() { sudo -n iptables "$@" 2>/dev/null; }
    HAVE_ROOT=1
else
    ipt() { return 127; }
    HAVE_ROOT=0
fi

# Any HTTP status at all means the TCP connection completed. 000 means it never
# did — that is the signature we care about, and it is what a dropped SYN looks
# like. 401/403 are SUCCESS for reachability purposes.
http_code_from_container() {
    docker compose exec -T -u www-data php \
        curl -sS -o /dev/null --connect-timeout "$CONNECT_TIMEOUT" \
        -w '%{http_code}' "$1" 2>/dev/null
}

say "╔════════════════════════════════════════════════════════════════╗"
say "║           Container network egress diagnostic                  ║"
say "╚════════════════════════════════════════════════════════════════╝"

################################################################################
step 1 "Is the php container running?"
################################################################################
CID="$(docker compose ps -q php 2>/dev/null)"
if [[ -z "$CID" ]]; then
    bad "php container is not running — start it with: make up"
    say ""
    say "${RED}Cannot diagnose networking without a running container.${NC}"
    exit 1
fi
ok "php container is up ($(docker inspect -f '{{.Name}}' "$CID" 2>/dev/null | sed 's|^/||'))"

################################################################################
step 2 "Which network and bridge is it on?"
################################################################################
NET_ID="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$v.NetworkID}} {{end}}' "$CID" 2>/dev/null | awk '{print $1}')"
NET_NAME="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$CID" 2>/dev/null | awk '{print $1}')"

if [[ -z "$NET_ID" ]]; then
    bad "could not determine the container's network"
    BRIDGE=""
    SUBNET=""
else
    # A network can override its interface name; only fall back to the
    # br-<first 12 of id> convention when that option is unset.
    BRIDGE="$(docker network inspect "$NET_ID" \
        -f '{{index .Options "com.docker.network.bridge.name"}}' 2>/dev/null)"
    [[ -z "$BRIDGE" || "$BRIDGE" == "<no value>" ]] && BRIDGE="br-${NET_ID:0:12}"
    SUBNET="$(docker network inspect "$NET_ID" \
        -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)"
    ok "network ${NET_NAME} (${NET_ID:0:12})"
    info "bridge: ${BRIDGE}   subnet: ${SUBNET:-unknown}"
fi

################################################################################
step 3 "Can the container resolve DNS?"
################################################################################
# Not proof of working egress — Docker's embedded resolver answers via the
# daemon's stack, so DNS succeeds even when all forwarded traffic is dropped.
if docker compose exec -T php getent hosts repo.magento.com >/dev/null 2>&1; then
    ok "DNS resolves inside the container"
    info "(this does NOT prove egress works — the embedded resolver bypasses FORWARD)"
else
    bad "DNS does not resolve inside the container"
    info "check /etc/resolv.conf on the host and the daemon's --dns settings"
fi

################################################################################
step 4 "Can the container actually reach the internet?"
################################################################################
CODE="$(http_code_from_container "$PROBE_URL")"
if [[ "$CODE" =~ ^[1-5][0-9][0-9]$ ]]; then
    ok "egress works — repo.magento.com returned HTTP ${CODE}"
    [[ "$CODE" == "401" ]] && info "401 is expected unauthenticated; it proves connectivity, not credentials"
    EGRESS_OK=1
else
    bad "no egress — could not connect to repo.magento.com (${CONNECT_TIMEOUT}s timeout)"
    EGRESS_OK=0
    NEUTRAL="$(http_code_from_container "$NEUTRAL_URL")"
    if [[ "$NEUTRAL" =~ ^[1-5][0-9][0-9]$ ]]; then
        info "packagist.org DOES respond (HTTP ${NEUTRAL}) — a targeted block, not a total one"
        info "suspect a firewall/proxy policy; the php service has no HTTP(S)_PROXY set"
    else
        info "packagist.org also unreachable — ALL container egress is down"
    fi
fi

################################################################################
step 5 "Does the host itself have egress? (isolates host from container)"
################################################################################
HOST_CODE="$(curl -sS -o /dev/null --connect-timeout "$CONNECT_TIMEOUT" \
    -w '%{http_code}' "$PROBE_URL" 2>/dev/null)"
if [[ "$HOST_CODE" =~ ^[1-5][0-9][0-9]$ ]]; then
    ok "host reaches repo.magento.com (HTTP ${HOST_CODE})"
    if [[ "$EGRESS_OK" -eq 0 ]]; then
        info "${YELLOW}host OK + container blocked = the fault is in Docker networking, below${NC}"
    fi
else
    note "the host cannot reach repo.magento.com either — this is upstream network/DNS,"
    info "not a Docker problem. Check your VPN, proxy or corporate firewall first."
fi

################################################################################
step 6 "Is IP forwarding enabled?"
################################################################################
FWD="$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"
if [[ "$FWD" == "1" ]]; then
    ok "net.ipv4.ip_forward = 1"
else
    bad "net.ipv4.ip_forward = ${FWD:-unknown} (must be 1)"
    info "Docker sets this at daemon start; a later 'sysctl --system', VPN client or"
    info "hardening policy can reset it. Fix:"
    info "  sudo sysctl -w net.ipv4.ip_forward=1"
    info "  echo 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/99-docker-forward.conf"
fi

################################################################################
step 7 "Are Docker's iptables rules present for the LIVE bridge?"
################################################################################
# This is the check that would have caught the original incident in seconds.
if [[ "$HAVE_ROOT" -eq 0 ]]; then
    note "skipped — needs root. Re-run with: sudo ./scripts/net-check.sh"
    skipped_root=1
elif [[ -z "$BRIDGE" ]]; then
    note "skipped — the container's bridge could not be determined"
else
    POLICY="$(ipt -L FORWARD -n | head -1)"
    info "FORWARD chain: ${POLICY}"
    if [[ "$POLICY" == *"policy DROP"* ]]; then
        info "(policy DROP is normal on a ufw host — Docker's chains must ACCEPT first)"
    fi

    # The filter-side rule that lets container traffic OUT.
    if ipt -S DOCKER-FORWARD 2>/dev/null | grep -q -- "-i ${BRIDGE} -j ACCEPT"; then
        ok "DOCKER-FORWARD has an ACCEPT for ${BRIDGE}"
    elif ipt -S FORWARD 2>/dev/null | grep -q -- "-i ${BRIDGE} -j ACCEPT"; then
        ok "FORWARD has an ACCEPT for ${BRIDGE} (pre-28 chain layout)"
    else
        bad "NO ACCEPT rule for ${BRIDGE} — outbound packets fall through to the DROP policy"
        info "${YELLOW}This is the classic cause. Fix: sudo systemctl restart docker${NC}"
    fi

    # The NAT-side rule that makes replies routable back.
    if [[ -n "$SUBNET" ]] && ipt -t nat -S POSTROUTING 2>/dev/null \
        | grep -q -- "-s ${SUBNET} ! -o ${BRIDGE} -j MASQUERADE"; then
        ok "nat/POSTROUTING has a MASQUERADE for ${SUBNET} via ${BRIDGE}"
    else
        bad "NO MASQUERADE rule for ${BRIDGE} — replies cannot route back to the container"
        info "${YELLOW}Fix: sudo systemctl restart docker${NC}"
    fi

    # An explicit drop that someone added by hand is a different fix entirely.
    if ipt -S DOCKER-USER 2>/dev/null | grep -qE -- '-j (DROP|REJECT)'; then
        bad "DOCKER-USER contains a DROP/REJECT rule — something is blocking on purpose"
        ipt -S DOCKER-USER | grep -E -- '-j (DROP|REJECT)' | sed 's/^/      /'
        info "often added by a 'Docker bypasses UFW' recipe in /etc/ufw/after.rules."
        info "Restarting Docker will NOT clear this — remove the rule at its source."
    fi
fi

################################################################################
step 8 "Stale bridges and duplicate-subnet routes"
################################################################################
# Leftover bridges are what let the ruleset drift out of sync in the first
# place: every recreated network claims the SAME hardcoded subnet, and Docker
# ends up installing rules for only one of them.
if [[ -n "$SUBNET" ]]; then
    mapfile -t SUBNET_ROUTES < <(ip -4 route show 2>/dev/null | grep -F "$SUBNET ")
    if [[ "${#SUBNET_ROUTES[@]}" -gt 1 ]]; then
        bad "${#SUBNET_ROUTES[@]} bridges are all claiming ${SUBNET}:"
        printf '      %s\n' "${SUBNET_ROUTES[@]}"
        info "only one can hold Docker's rules; the rest are leftovers"
    elif [[ "${#SUBNET_ROUTES[@]}" -eq 1 ]]; then
        ok "exactly one route for ${SUBNET}"
    fi
fi

# `linkdown` = a bridge with no container attached. Harmless for routing (the
# kernel skips linkdown routes) but a reliable fingerprint of the drift above.
mapfile -t DOWN < <(ip -4 route show 2>/dev/null | grep 'br-' | grep 'linkdown')
if [[ "${#DOWN[@]}" -gt 0 ]]; then
    note "${#DOWN[@]} stale linkdown bridge route(s) — no container attached:"
    printf '      %s\n' "${DOWN[@]}"
    info "clean up with:  docker compose down && docker network prune -f"
fi

# A bridge interface can outlive its Docker network. Then no docker command can
# remove it and `ip link delete` is the only way out.
mapfile -t HOST_BRIDGES < <(ip -o link show 2>/dev/null \
    | awk -F': ' '{print $2}' | cut -d'@' -f1 | grep '^br-')
if [[ "${#HOST_BRIDGES[@]}" -gt 0 ]]; then
    KNOWN="$(docker network ls -q --no-trunc 2>/dev/null)"
    for b in "${HOST_BRIDGES[@]}"; do
        if ! grep -q "^${b#br-}" <<<"$KNOWN"; then
            note "orphan bridge ${b} — interface exists but its Docker network does not"
            info "docker cannot remove it; use:  sudo ip link delete ${b}"
        fi
    done
fi

################################################################################
# Verdict
################################################################################
say ""
say "╔════════════════════════════════════════════════════════════════╗"
if [[ "$problems" -eq 0 && "$EGRESS_OK" -eq 1 ]]; then
    say "${GREEN}║  Container egress is HEALTHY ✓                                 ║${NC}"
    say "╚════════════════════════════════════════════════════════════════╝"
    [[ "$warnings" -gt 0 ]] && say "" && say "${YELLOW}${warnings} cosmetic warning(s) above — not affecting connectivity.${NC}"
    exit 0
fi
say "${RED}║  Container egress is BROKEN ✗                                  ║${NC}"
say "╚════════════════════════════════════════════════════════════════╝"
say ""
say "${problems} problem(s), ${warnings} warning(s)."
if [[ "$skipped_root" -eq 1 ]]; then
    say "${YELLOW}Re-run with sudo to check the iptables rules — the most common cause"
    say "lives there and was not inspected.${NC}"
fi
say ""
say "Most container-egress faults are fixed by reinstalling Docker's rules:"
say "  ${GREEN}docker compose down && sudo systemctl restart docker && docker compose up -d${NC}"
say ""
say "Then re-run this script. Full walkthrough: docs/TROUBLESHOOTING.md"
exit 1
