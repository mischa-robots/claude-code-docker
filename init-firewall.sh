#!/bin/bash
# init-firewall.sh
# Configures a default-deny egress firewall with an allowlist for Claude Code.
# Adapted from the official anthropics/claude-code devcontainer.
# Requires: NET_ADMIN and NET_RAW capabilities (set in docker-compose.yml).
set -e

echo "==> Initializing Claude Code firewall..."

# ── 1. Preserve Docker's internal DNS NAT rules before flushing ──────────────
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# ── 2. Flush all existing rules ───────────────────────────────────────────────
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# ── 3. Restore Docker internal DNS resolution ─────────────────────────────────
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore."
fi

# ── 4. Allow DNS and loopback before any restrictions ─────────────────────────
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT   # outbound DNS queries
iptables -A INPUT  -p udp --sport 53 -j ACCEPT   # inbound DNS responses
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT   # DNS over TCP
iptables -A INPUT  -p tcp --sport 53 -j ACCEPT
iptables -A INPUT  -i lo -j ACCEPT               # loopback
iptables -A OUTPUT -o lo -j ACCEPT

# ── 5. Create IP allowlist set ────────────────────────────────────────────────
ipset destroy allowed-domains 2>/dev/null || true
ipset create allowed-domains hash:net maxelem 1048576 -exist

# ── 6. Add GitHub IP ranges (fetched dynamically from GitHub meta API) ────────
echo "Fetching GitHub IP ranges..."
GITHUB_META=$(curl -s https://api.github.com/meta)
if [ -z "$GITHUB_META" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

for range in $(echo "$GITHUB_META" | jq -r '.web[], .api[], .git[], .packages[], .actions[]' 2>/dev/null | sort -u | aggregate -q 2>/dev/null || echo "$GITHUB_META" | jq -r '.web[], .api[], .git[]' | sort -u); do
    ipset add allowed-domains "$range" 2>/dev/null || true
done
echo "GitHub ranges added."

# ── 7. Resolve and add allowed domains ───────────────────────────────────────
ALLOWED_DOMAINS=(
    # Anthropic / Claude
    "api.anthropic.com"
    "claude.ai"
    "statsig.anthropic.com"
    "sentry.io"

    # npm registry
    "registry.npmjs.org"
    "npmjs.org"

    # GitHub (direct, in addition to ranges above)
    "github.com"
    "raw.githubusercontent.com"
    "objects.githubusercontent.com"
    "codeload.github.com"
    "api.github.com"

    # Package downloads & CDN
    "nodejs.org"
    "deb.nodesource.com"
    "archive.ubuntu.com"
    "security.ubuntu.com"
)

for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '/\tA\t/ {print $5}')
    if [ -z "$ips" ]; then
        echo "WARNING: Could not resolve $domain, skipping."
        continue
    fi
    while IFS= read -r ip; do
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            ipset add allowed-domains "$ip" -exist
        else
            echo "WARNING: Invalid IP '$ip' for $domain, skipping."
        fi
    done < <(echo "$ips")
done

# ── 8. Allow host network (for Docker networking) ─────────────────────────────
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected: $HOST_NETWORK"
iptables -A INPUT  -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# ── 9. Default DROP policies ──────────────────────────────────────────────────
iptables -P INPUT   DROP
iptables -P FORWARD DROP
iptables -P OUTPUT  DROP

# ── 10. Allow established connections ─────────────────────────────────────────
iptables -A INPUT  -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# ── 11. Allow outbound to whitelisted IPs ─────────────────────────────────────
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# ── 12. Reject (not drop) everything else — fast feedback for Claude ──────────
iptables -A OUTPUT -j REJECT --reject-with icmp-net-unreachable

# ── 13. Verify the firewall ───────────────────────────────────────────────────
echo "Verifying firewall..."

# Should FAIL (not in allowlist)
if curl -s --max-time 5 https://example.com > /dev/null 2>&1; then
    echo "ERROR: example.com should be blocked but is reachable!"
    exit 1
else
    echo "OK: example.com is blocked."
fi

# Should SUCCEED (in allowlist)
if ! curl -s --max-time 10 https://api.github.com > /dev/null 2>&1; then
    echo "ERROR: api.github.com should be reachable but is blocked!"
    exit 1
else
    echo "OK: api.github.com is reachable."
fi

echo "==> Firewall initialized successfully."
