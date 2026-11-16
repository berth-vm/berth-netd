#!/usr/bin/env bash
# Tests berth-netd's rule generation against fixture container configs.
# Needs only bash, awk and perl; touches no iptables (uses --print / --check).
#
#   bash test/run.sh
set -uo pipefail

here=$(cd "$(dirname "$0")" && pwd)
agent="$here/../berth-netd"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/lxc"

KEY=$(perl -e 'printf "%02x", int(rand(256)) for 1..32')
OTHER_KEY=$(perl -e 'printf "%02x", int(rand(256)) for 1..32')

# The signature, computed independently of the agent: the same formula berth's
# signatureTag() uses.
sig() { # vmid key tags...
  local vmid=$1 key=$2; shift 2
  local joined; joined=$(printf '%s\n' "$@" | LC_ALL=C sort -u | paste -sd';' -)
  printf 'berth-sig-%s' "$(VMID=$vmid TAGS=$joined KEY=$key perl -MDigest::SHA=hmac_sha256_hex -e \
    'print substr(hmac_sha256_hex("berth-netd v1\n$ENV{VMID}\n$ENV{TAGS}", pack("H*", $ENV{KEY})), 0, 32)')"
}
ct() { # vmid ip tags-string [extra lines]
  printf 'hostname: ct%s\nnet0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:00:00:01,ip=%s,gw=10.60.0.1,type=veth\ntags: %s\n%s' \
    "$1" "$2" "$3" "${4:-}" > "$work/lxc/$1.conf"
}

# 3000: two signed forwards, plus an operator's own tag.
ct 3000 10.60.0.2/22 "customer-a;berth-tcp-20000-22;berth-udp-20001-53;$(sig 3000 "$KEY" berth-tcp-20000-22 berth-udp-20001-53)"
# 3001: forged signature.
ct 3001 10.60.0.3/22 "berth-tcp-20010-22;berth-sig-00000000000000000000000000000000"
# 3002: 3000's signature copied onto another container.
ct 3002 10.60.0.4/22 "berth-tcp-20000-22;berth-udp-20001-53;$(sig 3000 "$KEY" berth-tcp-20000-22 berth-udp-20001-53)"
# 3003: unsigned.
ct 3003 10.60.0.5/22 "berth-tcp-20030-22"
# 3004: a forward added after signing.
ct 3004 10.60.0.6/22 "berth-tcp-20040-22;berth-tcp-20041-8006;$(sig 3004 "$KEY" berth-tcp-20040-22)"
# 3005: signed with the wrong key.
ct 3005 10.60.0.7/22 "berth-tcp-20050-22;$(sig 3005 "$OTHER_KEY" berth-tcp-20050-22)"
# 3006: signed, but asks for the host's own SSH port, and a port taken by 3000.
ct 3006 10.60.0.8/22 "berth-tcp-22-22;berth-tcp-20000-80;berth-tcp-20060-80;$(sig 3006 "$KEY" berth-tcp-22-22 berth-tcp-20000-80 berth-tcp-20060-80)"
# 3007: signed, but its address is outside the container network.
ct 3007 192.168.5.9/24 "berth-tcp-20070-22;$(sig 3007 "$KEY" berth-tcp-20070-22)"
# 200: outside the vmid range, signed.
ct 200 10.60.0.50/22 "berth-tcp-20080-22;$(sig 200 "$KEY" berth-tcp-20080-22)"
# 3008: a snapshot section with different settings must be ignored.
ct 3008 10.60.0.9/22 "berth-tcp-20090-22;$(sig 3008 "$KEY" berth-tcp-20090-22)" \
  $'\n[before-upgrade]\nnet0: name=eth0,bridge=vmbr0,ip=10.60.0.99/22,type=veth\ntags: berth-tcp-20099-22\n'
# 3009: tags separated by spaces, which Proxmox also accepts.
ct 3009 10.60.0.10/22 "berth-tcp-20100-22 $(sig 3009 "$KEY" berth-tcp-20100-22)"

printf 'PUBLIC_V4=203.0.113.10\nNETD_KEY=%s\n' "$KEY" > "$work/conf"
out=$(BERTH_NETD_CONF="$work/conf" BERTH_LXC_DIR="$work/lxc" bash "$agent" --print 2>"$work/err")
err=$(cat "$work/err")

pass=0 fail=0
ok()  { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
has()  { grep -qF -- "$2" <<< "$out" && ok "$1" || bad "$1"; }
lacks() { grep -qF -- "$2" <<< "$out" && bad "$1" || ok "$1"; }
warns() { grep -qF -- "$2" <<< "$err" && ok "$1" || bad "$1"; }

has   'signed forward is applied'              '--dport 20000 -m comment --comment "berth CT 3000" -j DNAT --to-destination 10.60.0.2:22'
has   'udp forward is applied'                 '-p udp -m udp --dport 20001'
has   'outbound NAT for the container network' '-s 10.60.0.0/22 ! -d 10.60.0.0/22 -j MASQUERADE'
has   'hairpin NAT'                            '--ctstate DNAT -j MASQUERADE'
lacks 'forged signature is ignored'            '--dport 20010'
lacks 'copied signature is ignored'            'berth CT 3002'
lacks 'unsigned forwards are ignored'          '--dport 20030'
lacks 'a tag added after signing voids all'    '--dport 20040'
lacks 'nor is the added tag applied'           '--dport 20041'
lacks 'wrong key is ignored'                   '--dport 20050'
lacks 'host port 22 cannot be claimed'         '--dport 22 '
lacks 'a taken port is not reassigned'         'berth CT 3006" -j DNAT --to-destination 10.60.0.8:80 '
has   'the rest of that container still works' '--dport 20060 -m comment --comment "berth CT 3006"'
lacks 'address outside the network ignored'    '192.168.5.9'
lacks 'vmid outside the range ignored'         '--dport 20080'
has   'main section is used'                   '--to-destination 10.60.0.9:22'
lacks 'snapshot section is ignored'            '--dport 20099'
has   'space-separated tags are read'          '--dport 20100'
warns 'forgery is logged'                      'CT 3001: forwards are unsigned or the signature is wrong'
warns 'port outside the range is logged'       'public port 22 is outside'
warns 'port conflict is logged'                'tcp port 20000 already goes to CT 3000'
[ "$(grep -c -- '-j DNAT' <<< "$out")" = 5 ] && ok 'exactly five forwards' || bad "exactly five forwards (got $(grep -c -- '-j DNAT' <<< "$out"))"

# Configuration is refused rather than half-applied.
printf 'PUBLIC_V4=203.0.113.10\n' > "$work/nokey"
BERTH_NETD_CONF="$work/nokey" BERTH_LXC_DIR="$work/lxc" bash "$agent" --check >/dev/null 2>&1 && bad 'missing key is refused' || ok 'missing key is refused'
printf 'PUBLIC_V4=203.0.113.10\nNETD_KEY=%s\nPORT_MIN=22\n' "$KEY" > "$work/lowport"
BERTH_NETD_CONF="$work/lowport" BERTH_LXC_DIR="$work/lxc" bash "$agent" --check >/dev/null 2>&1 && bad 'privileged port range is refused' || ok 'privileged port range is refused'
printf 'PUBLIC_V4=10.60.0.5\nNETD_KEY=%s\n' "$KEY" > "$work/badpub"
BERTH_NETD_CONF="$work/badpub" BERTH_LXC_DIR="$work/lxc" bash "$agent" --check >/dev/null 2>&1 && bad 'public address inside the container network is refused' || ok 'public address inside the container network is refused'

# ---- SSH password login --------------------------------------------------------

# The in-container script, against a fake root filesystem.
script=$(bash "$agent" --ssh-script)
root="$work/root-a"; mkdir -p "$root/etc/ssh"
printf '#PermitRootLogin prohibit-password\nPasswordAuthentication no\n' > "$root/etc/ssh/sshd_config"
r1=$(R=$root sh -c "$script")
[ "$r1" = changed ] && ok 'ssh: first run configures' || bad "ssh: first run configures (got '$r1')"
[ "$(head -1 "$root/etc/ssh/sshd_config")" = 'Include /etc/ssh/sshd_config.d/*.conf' ] \
  && ok 'ssh: drop-ins are included before the main settings' || bad 'ssh: drop-ins are included before the main settings'
grep -qx 'PermitRootLogin yes' "$root/etc/ssh/sshd_config.d/00-berth.conf" \
  && grep -qx 'PasswordAuthentication yes' "$root/etc/ssh/sshd_config.d/00-berth.conf" \
  && ok 'ssh: drop-in allows root password login' || bad 'ssh: drop-in allows root password login'
rm "$root/etc/ssh/sshd_config.d/00-berth.conf"   # the owner changes their mind
r2=$(R=$root sh -c "$script")
[ "$r2" = already ] && [ ! -e "$root/etc/ssh/sshd_config.d/00-berth.conf" ] \
  && ok 'ssh: never touched again once done' || bad "ssh: never touched again once done (got '$r2')"
root="$work/root-b"; mkdir -p "$root/etc/ssh"
printf 'Include /etc/ssh/sshd_config.d/*.conf\nPermitRootLogin no\n' > "$root/etc/ssh/sshd_config"
R=$root sh -c "$script" >/dev/null
[ "$(grep -c '^Include' "$root/etc/ssh/sshd_config")" = 1 ] && ok 'ssh: an existing Include is not duplicated' || bad 'ssh: an existing Include is not duplicated'
r3=$(R="$work/root-c" sh -c "$script")
[ "$r3" = no-sshd ] && ok 'ssh: a container without sshd is left alone' || bad "ssh: a container without sshd is left alone (got '$r3')"

grep -qx 'UseDNS no' "$work/root-b/etc/ssh/sshd_config.d/00-berth.conf" \
  && grep -qx 'GSSAPIAuthentication no' "$work/root-b/etc/ssh/sshd_config.d/00-berth.conf" \
  && ok 'ssh: drop-in turns off the two classic login delays' || bad 'ssh: drop-in turns off the two classic login delays'

# The agent's pass, with stand-ins for pct and lxc-ls that record what they
# were asked. RUNNING lists the running vmids; every call of either is counted.
mkdir -p "$work/bin" "$work/roots"
cat > "$work/bin/pct" <<'PCT'
#!/bin/sh
echo "pct $1" >> "$PCT_CALLS"
case "$1" in
  list) echo "VMID       Status     Lock         Name"; for v in $RUNNING; do echo "$v         running                 ct$v"; done ;;
  status) for v in $RUNNING; do [ "$v" = "$2" ] && { echo "status: running"; exit 0; }; done; echo "status: stopped" ;;
  exec)
    vmid=$2; shift 3
    [ "$1" = sh ] && [ "$2" = -c ] || exit 9
    echo "$vmid" >> "$PCT_LOG"
    [ -n "${HANG:-}" ] && [ "$vmid" = "$HANG" ] && sleep 5
    mkdir -p "$FAKE_ROOTS/$vmid/etc/ssh"
    [ -f "$FAKE_ROOTS/$vmid/etc/ssh/sshd_config" ] || printf 'PermitRootLogin prohibit-password\n' > "$FAKE_ROOTS/$vmid/etc/ssh/sshd_config"
    R="$FAKE_ROOTS/$vmid" sh -c "$3" ;;
esac
PCT
cat > "$work/bin/lxc-ls" <<'LS'
#!/bin/sh
echo "lxc-ls $1" >> "$PCT_CALLS"
for v in $RUNNING; do echo "$v"; done
LS
chmod +x "$work/bin/pct" "$work/bin/lxc-ls"
pass_ssh() { # conf roots [extra env...]
  local conf=$1 roots=$2; shift 2
  env "$@" PATH="$work/bin:$PATH" PCT_LOG="$work/pct.log" PCT_CALLS="$work/calls.log" FAKE_ROOTS="$roots" \
    BERTH_NETD_CONF="$conf" BERTH_LXC_DIR="$work/lxc" bash "$agent" --configure-ssh 2>&1
}
: > "$work/pct.log"; : > "$work/calls.log"
ssh_log=$(pass_ssh "$work/conf" "$work/roots" RUNNING="3000 3001 3002 3003 3004 3005 3006 3007 3008 3009")
touched=$(sort -n "$work/pct.log" | paste -sd' ' -)
[ "$touched" = "3000 3006 3008 3009" ] && ok 'ssh: only containers with signed forwards are touched' \
  || bad "ssh: only containers with signed forwards are touched (got '$touched')"
grep -q 'CT 3000: allowed root password login over SSH' <<< "$ssh_log" && ok 'ssh: the change is logged' || bad 'ssh: the change is logged'
[ "$(grep -c . "$work/calls.log")" = 5 ] && ! grep -q 'pct status' "$work/calls.log" \
  && ok 'ssh: one process asks which containers run, not one pct status each' \
  || bad "ssh: one process asks which containers run, not one pct status each (got $(sort "$work/calls.log" | uniq -c | tr -s ' \n' ' '))"
: > "$work/pct.log"
pass_ssh "$work/conf" "$work/roots3" RUNNING="3006" >/dev/null
[ "$(cat "$work/pct.log")" = 3006 ] && ok 'ssh: stopped containers are left for a later pass' || bad "ssh: stopped containers are left for a later pass (got '$(paste -sd' ' "$work/pct.log")')"
: > "$work/pct.log"
hang_log=$(pass_ssh "$work/conf" "$work/roots4" RUNNING="3000 3006" HANG=3000 SSH_EXEC_TIMEOUT=1)
grep -q 'CT 3000: pct exec did not finish within 1s; retrying in 1 min' <<< "$hang_log" && grep -q 'CT 3006: allowed' <<< "$hang_log" \
  && ok 'ssh: a container that hangs pct exec is timed out and the others still get done' \
  || bad "ssh: a container that hangs pct exec is timed out and the others still get done (got '$hang_log')"
# Without lxc-ls (CI runners have none), pct list is the one-process fallback.
if ! command -v lxc-ls >/dev/null 2>&1; then
  mv "$work/bin/lxc-ls" "$work/lxc-ls.off"; : > "$work/calls.log"; : > "$work/pct.log"
  pass_ssh "$work/conf" "$work/roots5" RUNNING="3008" >/dev/null
  [ "$(cat "$work/pct.log")" = 3008 ] && [ "$(grep -c 'pct list' "$work/calls.log")" = 1 ] && ! grep -q 'pct status' "$work/calls.log" \
    && ok 'ssh: without lxc-ls, one pct list stands in' || bad "ssh: without lxc-ls, one pct list stands in (got $(sort "$work/calls.log" | uniq -c | tr -s ' \n' ' '))"
  mv "$work/lxc-ls.off" "$work/bin/lxc-ls"
fi
printf 'PUBLIC_V4=203.0.113.10\nNETD_KEY=%s\nSSH_PASSWORD_LOGIN=0\n' "$KEY" > "$work/nossh"
: > "$work/pct.log"
pass_ssh "$work/nossh" "$work/roots2" RUNNING="3000" >/dev/null
[ ! -s "$work/pct.log" ] && ok 'ssh: SSH_PASSWORD_LOGIN=0 leaves containers alone' || bad 'ssh: SSH_PASSWORD_LOGIN=0 leaves containers alone'

# --diagnose-ssh runs its in-container probe through pct exec and reports.
diag=$(RUNNING="3000" PATH="$work/bin:$PATH" PCT_LOG="$work/pct.log" PCT_CALLS="$work/calls.log" FAKE_ROOTS="$work/roots6" \
  BERTH_NETD_CONF="$work/conf" BERTH_LXC_DIR="$work/lxc" bash "$agent" --diagnose-ssh 3000 2>&1)
grep -q 'CT 3000: 10.60.0.2, SSH forward 203.0.113.10:20000' <<< "$diag" && grep -q 'pct exec round trip' <<< "$diag" && grep -q 'keystroke path' <<< "$diag" \
  && grep -q 'inside CT 3000' <<< "$diag" \
  && ok 'diagnose-ssh: reports the forward and times the hops' || bad "diagnose-ssh: reports the forward and times the hops (got '$diag')"
diag=$(RUNNING="3000" PATH="$work/bin:$PATH" PCT_CALLS="$work/calls.log" BERTH_NETD_CONF="$work/conf" BERTH_LXC_DIR="$work/lxc" bash "$agent" --diagnose-ssh 3003 2>&1)
grep -q 'CT 3003: no signed forwards' <<< "$diag" && ok 'diagnose-ssh: an unsigned container is named as such' || bad "diagnose-ssh: an unsigned container is named as such (got '$diag')"

echo
echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
