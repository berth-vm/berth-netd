# berth-netd

The host agent for [berth](https://github.com/berth-vm). It runs on the
Proxmox VE host and keeps the host's NAT in step with berth's containers:

- the containers' private IPv4 gateway (`10.60.0.1` on `vmbr0` by default)
  and IP forwarding
- outbound NAT, so containers reach the internet over IPv4
- one DNAT rule per port forward, so `<host public IPv4>:<port>` reaches a
  container. Each container's SSH port is one of these.

When a user adds a forward in berth, it is live on the host within seconds.
Nobody has to run `iptables` by hand.

## How it works

```
berth (control panel)                       Proxmox host
─────────────────────                       ────────────────────────────────
records the forward                          berth-netd (this)
signs it with NETD_KEY            ──TLS──▶   reads /etc/pve/lxc/*.conf
writes it as tags on the CT        API       verifies each signature
  berth-tcp-20000-22               token     rewrites BERTH_PREROUTING /
  berth-sig-6a9df8e9…              pinned    BERTH_POSTROUTING (nat table)
```

berth never talks to the agent directly. It writes tags through the Proxmox
API, and the agent reads them from the local cluster filesystem every few
seconds. The agent listens on no port and needs no Proxmox credentials.

## Security model

Every hop is authenticated, and the agent decides what to trust for itself:

| Hop | Protection |
|---|---|
| berth → Proxmox API | TLS with the host's certificate **pinned** by SHA-256 fingerprint (`PROXMOX_TLS_FINGERPRINT`), checked inside the handshake before the API token is sent. Authenticated with a dedicated least-privilege API token. |
| Proxmox API → container config | Proxmox's own permissions: only users with `VM.Config.Options` on a container can edit its tags. The agent doesn't rely on this; see the next row. |
| container config → berth-netd | Each container's forwards carry an **HMAC-SHA256 signature** under `NETD_KEY`, a 256-bit key that only berth and this host hold. The signature covers the vmid and the exact set of forwards. Unsigned, forged or altered forwards are ignored, and a valid set copied onto another container does not verify. |
| berth-netd → iptables | Even a correctly signed tag is checked again. The destination address is taken from the container's own `net0`, never from a tag, and must be inside `V4_CIDR`. The public port must be inside `PORT_MIN`–`PORT_MAX`, so nothing can claim the host's SSH (22) or web UI (8006). Containers outside `VMID_MIN`–`VMID_MAX` are never read. |

The agent only ever writes its own two chains, replaced atomically with
`iptables-restore --noflush`, and leaves every other rule on the host alone.
The key is read from a root-only file, and the agent passes it to its verifier
through the environment, never on a command line where `ps` could show it.

### The wire format

A forward is a Proxmox tag:

```
berth-<tcp|udp>-<public port>-<container port>        e.g. berth-tcp-20000-22
```

The signature is one more tag:

```
berth-sig-<first 32 hex digits of HMAC-SHA256(key, message)>
message = "berth-netd v1\n" + <vmid> + "\n" + <the forward tags, sorted bytewise, joined with ";">
```

Tags that don't start with `berth-` are left alone, so operators can tag
berth's containers for their own purposes.

## Install

On the Proxmox host, as root:

```bash
git clone https://github.com/berth-vm/berth-netd.git
cd berth-netd
bash install.sh
```

The installer:

1. installs `/usr/local/sbin/berth-netd` and `berth-netd.service`
2. writes `/etc/berth-netd.conf` (mode 600). It detects the bridge that
   carries the default route and that bridge's public IPv4.
3. asks for the signing key. Paste `BERTH_NETD_KEY` from berth's
   `server/.env`. The input is not echoed.
4. lists any NAT rules you added by hand earlier, so you can remove them
5. starts the service and prints its status
6. prints this host's API certificate fingerprint. **Check that it matches
   `PROXMOX_TLS_FINGERPRINT` in berth's `server/.env`.** If it doesn't,
   something is intercepting berth's connection to Proxmox.

Running it again updates the agent and keeps your configuration.

## Configuration

`/etc/berth-netd.conf`. These values must match berth's `server/.env`:

| Setting | berth's name | Default |
|---|---|---|
| `BRIDGE` | `PROXMOX_BRIDGE` | `vmbr0` |
| `PUBLIC_V4` | `BERTH_PUBLIC_V4` | detected |
| `V4_CIDR` | `BERTH_V4_CIDR` | `10.60.0.0/22` |
| `V4_GATEWAY` | `BERTH_V4_GATEWAY` | `10.60.0.1` |
| `PORT_MIN`, `PORT_MAX` | `BERTH_NAT_PORT_MIN`, `_MAX` | `20000`, `29999` |
| `VMID_MIN`, `VMID_MAX` | `PROXMOX_VMID_MIN`, `_MAX` | `3000`, `3999` |
| `NETD_KEY` | `BERTH_NETD_KEY` | required |
| `IPV6_FORWARD` | | `1`: containers use the host as their IPv6 gateway |
| `INTERVAL` | | `5` seconds between checks |

After editing, run `systemctl restart berth-netd`.

## Operating it

```bash
journalctl -u berth-netd -f      # what it applied, and what it skipped and why
berth-netd --status              # gateway, forwarding, and both chains
berth-netd --print               # the rules it would apply now; changes nothing
berth-netd --check               # validate the config
berth-netd --fingerprint         # this host's API certificate fingerprint
berth-netd --remove              # take its chains and gateway address away
```

The agent logs each skipped forward once, and logs it again only if the reason
changes. When the agent stops, its rules stay in place, so a restart doesn't
interrupt anyone's connections. To remove them, run `berth-netd --remove`.

`ifreload -a` removes addresses that aren't in `/etc/network/interfaces`,
including the gateway. The agent adds it back within `INTERVAL` seconds.

**Rotating the key:** generate a new one with `openssl rand -hex 32`. Put it in
berth's `BERTH_NETD_KEY` and this host's `NETD_KEY`, then restart both. berth
re-signs every container within its sync interval (10 minutes, or immediately
on its next start). Until it does, forwards signed with the old key stop
working.

**If the host's certificate is renewed,** the fingerprint changes and berth
refuses to connect until you update `PROXMOX_TLS_FINGERPRINT`. Check the new
value here with `berth-netd --fingerprint`.

## Requirements

Proxmox VE 8 (any Debian 12 based host with `iptables`, `perl` and
`openssl`, all of which Proxmox ships). Nothing else needs installing.

## Tests

```bash
bash test/run.sh
```

The tests run against fixture container configs with `--print`, so they need
no Proxmox host and change no iptables rules. CI runs them, plus ShellCheck,
on every push.
