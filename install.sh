#!/usr/bin/env bash
# Installs berth-netd on a Proxmox host. Run as root from this directory:
#
#   bash install.sh
#
# Safe to run again: it updates the script and unit, keeps an existing
# /etc/berth-netd.conf, and restarts the service.
#
# On first install it writes /etc/berth-netd.conf with the bridge that carries
# the default route and that bridge's public IPv4, detected here, and asks for
# the signing key (BERTH_NETD_KEY from berth's server/.env). Other settings
# can be given on the command line, e.g.
#   PUBLIC_V4=203.0.113.10 BRIDGE=vmbr0 bash install.sh
# API_PORT=<port> turns the API on (see README, "API"); it is off otherwise.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
say() { printf '==> %s\n' "$*"; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root"
[ -d /etc/pve ] || die "/etc/pve not found: this is meant for a Proxmox VE host"
command -v iptables-restore >/dev/null || die "iptables-restore not found"

# Files copied from Windows can arrive with CRLF line endings, which break bash.
for f in berth-netd berth-netd-api berth-netd.service berth-netd.conf.example; do
  [ -f "$here/$f" ] || die "missing $here/$f"
  sed -i 's/\r$//' "$here/$f"
done

install -m 0755 "$here/berth-netd" /usr/local/sbin/berth-netd
install -m 0755 "$here/berth-netd-api" /usr/local/sbin/berth-netd-api
install -m 0644 "$here/berth-netd.service" /etc/systemd/system/berth-netd.service
say "installed /usr/local/sbin/berth-netd, berth-netd-api and berth-netd.service"

if [ -e /etc/berth-netd.conf ]; then
  say "keeping existing /etc/berth-netd.conf"
else
  bridge=${BRIDGE:-$(ip -4 route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')}
  [ -n "$bridge" ] || die "could not find the default-route bridge; run with BRIDGE=vmbr0"
  public=${PUBLIC_V4:-$(ip -4 -o addr show dev "$bridge" scope global | awk '{split($4, a, "/"); print a[1]; exit}')}
  [ -n "$public" ] || die "could not find a public IPv4 on $bridge; run with PUBLIC_V4=<address>"
  conf=$(cat "$here/berth-netd.conf.example")
  set_key() { conf=$(printf '%s\n' "$conf" | sed "s|^$1=.*|$1=$2|"); }
  set_key BRIDGE "$bridge"
  set_key PUBLIC_V4 "$public"
  for k in V4_CIDR V4_GATEWAY PORT_MIN PORT_MAX VMID_MIN VMID_MAX IPV6_FORWARD INTERVAL API_PORT API_BIND; do
    if [ -n "${!k:-}" ]; then set_key "$k" "${!k}"; fi
  done
  ( umask 077; printf '%s\n' "$conf" > /etc/berth-netd.conf )
  say "wrote /etc/berth-netd.conf (bridge $bridge, public IPv4 $public)"
fi

# The signing key. Asked for without echo rather than taken from argv or an
# exported variable, so it stays out of shell history and the process list.
if ! grep -Eq '^NETD_KEY=[0-9a-fA-F]{64}$' /etc/berth-netd.conf; then
  key=${NETD_KEY:-}
  if [ -z "$key" ]; then
    [ -t 0 ] || die "NETD_KEY is not set in /etc/berth-netd.conf; run this interactively to paste it"
    read -rsp "Paste BERTH_NETD_KEY from berth's server/.env: " key; echo
  fi
  [[ $key =~ ^[0-9a-fA-F]{64}$ ]] || die "that is not a 64-hex-digit key"
  if grep -q '^NETD_KEY=' /etc/berth-netd.conf; then
    sed -i "s|^NETD_KEY=.*|NETD_KEY=$key|" /etc/berth-netd.conf
  else
    printf '\nNETD_KEY=%s\n' "$key" >> /etc/berth-netd.conf
  fi
  unset key
  say "saved the signing key"
fi
chown root:root /etc/berth-netd.conf
chmod 0600 /etc/berth-netd.conf

/usr/local/sbin/berth-netd --check || die "fix /etc/berth-netd.conf, then run this again"

# Rules added by hand earlier (the commands in SETUP.md) would now be
# duplicates. They are harmless, since the agent's chains are checked first,
# but are listed so they can be removed.
manual=$(iptables -w -t nat -S | grep -E '^-A (PREROUTING|POSTROUTING) ' | grep -E 'DNAT|MASQUERADE' | grep -v BERTH_ || true)
if [ -n "$manual" ]; then
  say "these NAT rules were not added by berth-netd; if you added them by hand for berth, remove them:"
  printf '%s\n' "$manual" | sed 's/^-A /    iptables -t nat -D /'
fi

systemctl daemon-reload
systemctl enable berth-netd >/dev/null 2>&1
systemctl restart berth-netd
sleep 2
systemctl --no-pager --lines=8 status berth-netd || true
echo
/usr/local/sbin/berth-netd --status
echo
say "this host's API certificate (berth's PROXMOX_TLS_FINGERPRINT must be exactly this):"
echo "    $(/usr/local/sbin/berth-netd --fingerprint)"
api_port=$(sed -n 's/^API_PORT=\([0-9]*\)$/\1/p' /etc/berth-netd.conf | tail -1)
if [ -n "${api_port:-}" ] && [ "$api_port" != 0 ]; then
  api_bind=$(sed -n 's/^API_BIND=\(.*\)$/\1/p' /etc/berth-netd.conf | tail -1)
  say "berth-netd's API is on at https://${api_bind:-$(sed -n 's/^PUBLIC_V4=//p' /etc/berth-netd.conf)}:$api_port/v1/ (same certificate; see 'journalctl -u berth-netd' if it is not)"
else
  say "berth-netd's API is off; set API_PORT in /etc/berth-netd.conf to turn it on (see README, \"API\")"
fi
