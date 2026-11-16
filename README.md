# berth-netd

The host agent for [berth](https://github.com/berth-vm). It runs on the
Proxmox VE host and keeps the host's NAT in step with berth's containers:

- the containers' private IPv4 gateway (`10.60.0.1` on `vmbr0` by default)
  and IP forwarding
- outbound NAT, so containers reach the internet over IPv4
- one DNAT rule per port forward, so `<host public IPv4>:<port>` reaches a
  container. Each container's SSH port is one of these.
- root password login over SSH, enabled once in each new container, so the
  password berth shows its owner actually works over SSH

When a user adds a forward in berth, it is live on the host within seconds,
and a new container accepts its root password over SSH as soon as it's up.
Nobody has to run `iptables` or edit `sshd_config` by hand.

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
seconds. The agent needs no Proxmox credentials and, unless its [API](#api)
is turned on, listens on no port.

## Security model

Every hop is authenticated, and the agent decides what to trust for itself:

| Hop | Protection |
|---|---|
| berth → Proxmox API | TLS with the host's certificate **pinned** by SHA-256 fingerprint (`PROXMOX_TLS_FINGERPRINT`), checked inside the handshake before the API token is sent. Authenticated with a dedicated least-privilege API token. |
| Proxmox API → container config | Proxmox's own permissions: only users with `VM.Config.Options` on a container can edit its tags. The agent doesn't rely on this; see the next row. |
| container config → berth-netd | Each container's forwards carry an **HMAC-SHA256 signature** under `NETD_KEY`, a 256-bit key that only berth and this host hold. The signature covers the vmid and the exact set of forwards. Unsigned, forged or altered forwards are ignored, and a valid set copied onto another container does not verify. |
| berth → berth-netd's API (optional) | Off by default. When on, it speaks HTTPS with the **same certificate as the Proxmox API**, so berth pins the fingerprint it already pins, and it answers only requests **signed with `NETD_KEY`** (an HMAC over the time, method and path, valid for 60 seconds). It only reads: nothing it serves changes the host. See [API](#api). |
| berth-netd → iptables | Even a correctly signed tag is checked again. The destination address is taken from the container's own `net0`, never from a tag, and must be inside `V4_CIDR`. The public port must be inside `PORT_MIN`–`PORT_MAX`, so nothing can claim the host's SSH (22) or web UI (8006). Containers outside `VMID_MIN`–`VMID_MAX` are never read. |

The agent only ever writes its own two chains, replaced atomically with
`iptables-restore --noflush`, and leaves every other rule on the host alone.
The key is read from a root-only file, and the agent passes it to its verifier
through the environment, never on a command line where `ps` could show it.

### Root password login over SSH

Debian's and Ubuntu's SSH servers refuse root password logins by default, so
the random root password berth sets, and shows on its Password tab, can't be
used over SSH. The agent fixes that once for each container, as soon as the
container is running:

- From the host it runs `pct exec <vmid>`, which needs no network access and
  no credentials inside the container.
- It writes `/etc/ssh/sshd_config.d/00-berth.conf` with
  `PermitRootLogin yes` and `PasswordAuthentication yes`. If the main config
  lacks an `Include` line for that directory, it adds one at the top. The
  same file sets `UseDNS no` and `GSSAPIAuthentication no`, the two sshd
  settings behind the classic "login hangs for seconds before the password
  prompt": a reverse DNS lookup of the client, and a Kerberos attempt that
  some templates (RHEL-family) leave switched on.
- It checks the result with `sshd -t` and removes the file again if sshd
  rejects it. Then it reloads SSH.
- It leaves a marker at `/var/lib/berth/ssh-password-login` and never touches
  that container's SSH configuration again, so the owner can change it freely
  afterwards. A reinstall creates a fresh filesystem without the marker, so it
  is configured again.

It only touches containers whose forwards carry a valid berth signature, and
the command it runs is fixed: nothing from a tag ends up in it. Set
`SSH_PASSWORD_LOGIN=0` to turn this off. `berth-netd --ssh-script` prints
exactly what runs inside the container.

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
| `SSH_PASSWORD_LOGIN` | | `1`: allow root password SSH in each new container, once |
| `INTERVAL` | | `5` seconds between checks |
| `API_PORT` | | empty: the [API](#api) is off. A port outside `PORT_MIN`–`PORT_MAX` turns it on |
| `API_BIND` | | the address the API listens on; `PUBLIC_V4` by default |

After editing, run `systemctl restart berth-netd`.

## Operating it

```bash
journalctl -u berth-netd -f      # what it applied, and what it skipped and why
berth-netd --status              # gateway, forwarding, and both chains (--raw: as records)
berth-netd --print               # the rules it would apply now; changes nothing
berth-netd --check               # validate the config
berth-netd --fingerprint         # this host's API certificate fingerprint
berth-netd --configure-ssh       # run the SSH step now rather than waiting for the loop
berth-netd --diagnose-ssh 3000   # where a slow SSH login to CT 3000 spends its time (--raw: as records)
berth-netd --api                 # serve the two above as JSON in the foreground (the service does this itself)
berth-netd --remove              # take its chains and gateway address away
```

The agent logs each skipped forward once, and logs it again only if the reason
changes. When the agent stops, its rules stay in place, so a restart doesn't
interrupt anyone's connections. To remove them, run `berth-netd --remove`.

The SSH step costs the loop almost nothing: one `lxc-ls` (or `pct list`)
per pass tells it which containers run, and `pct exec` is only ever run once
per container, under a 20-second timeout. A container that doesn't answer is
retried after 1, 2, 4 and 8 minutes, then every 15, and never holds up the
forwards of the others.

### If SSH to a container is slow

The agent's NAT adds no measurable latency: a DNAT rule is a conntrack lookup
per packet. A slow login almost always comes from what runs *after* the TCP
connection, inside the container, or from a network path problem that only
shows up on large packets. Run the diagnosis on the host:

```bash
berth-netd --diagnose-ssh <vmid>
```

It times the TCP path to the container's sshd, the `pct exec` round trip,
and then, inside the container, the things that stand between "connected" and
a shell prompt, and points at whichever is slow:

| Symptom | Where it comes from | What to do in the container |
|---|---|---|
| Seconds pass before the password prompt | `UseDNS` or `GSSAPIAuthentication` on in sshd | Both are off in the agent's drop-in. Containers configured before this version keep their old drop-in; add the two lines to `/etc/ssh/sshd_config.d/00-berth.conf` by hand. |
| Password accepted, then a long wait for the prompt | `systemd-logind` not answering (PAM waits up to 25 s), or a slow resolver | `systemctl restart systemd-logind`; check `/etc/resolv.conf` |
| Same, on Ubuntu | the login messages in `/etc/update-motd.d` (apt and ESM checks, `landscape-sysinfo`) | `chmod -x` the slow ones; they run at every login |
| Each typed character takes a moment to appear | Every keystroke is a round trip, so this is latency on the path, not sshd. The diagnosis's "keystroke path" section measures the three causes the host can see: | |
| … and the container's CPU pressure or throttling is high | the container is waiting for a CPU: its `cores`/`cpulimit` cap, or an overloaded host (`host cpu pressure`) | raise `cores`/`cpulimit` in berth, or move load off the host |
| … and the container's memory pressure is high | it is reclaiming or swapping | raise its memory, or find what fills it |
| … and the uplink runs `pfifo_fast` | no fair queuing: one container's upload fills the NIC's queue and every other packet waits behind it | `sysctl -w net.core.default_qdisc=fq_codel` and `tc qdisc replace dev <nic> root fq_codel` |
| … and none of the above | the client is far from the host, or loses packets on the way | `ping <host>` from the client is the floor for every keystroke; `mtr <host>` shows where delay is added. Nothing on the host lowers it. |
| Typing is fine but output stalls, `cat` of a big file hangs | path MTU: a hop between the client and the host drops ICMP, so TCP can't learn the smaller MTU | On the host: `iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu` (the agent leaves `mangle` alone, so add it to your own rules) |
| Everything is sluggish, `dmesg` says `nf_conntrack: table full` | the host's connection-tracking table | `sysctl -w net.netfilter.nf_conntrack_max=262144`, and persist it in `/etc/sysctl.d/` |

From the client side, `ssh -vvv -p <port> root@<host>` shows the same login
with a timestamp gap at the slow step.

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

## API

berth-netd can serve its status and its SSH diagnosis as JSON, so berth (or
anything else that holds `NETD_KEY`) can show them. It is off until `API_PORT`
is set in `/etc/berth-netd.conf`:

```
API_PORT=8077      # anything outside PORT_MIN-PORT_MAX, and not 22 or 8006
API_BIND=          # PUBLIC_V4 unless set
```

then `systemctl restart berth-netd`. The service starts `berth-netd-api`
(Python, standard library only) and restarts it if it dies. `journalctl -u
berth-netd` shows `listening on https://…` and the certificate fingerprint,
plus one line per request.

### Transport and authentication

- **HTTPS with the host's Proxmox API certificate.** The server loads
  `/etc/pve/local/pveproxy-ssl.pem` (a custom certificate, if one is
  installed) or else `pve-ssl.pem`. The fingerprint is therefore the one berth
  already pins as `PROXMOX_TLS_FINGERPRINT`, and `berth-netd --fingerprint`
  prints it. Pin it; do not verify by name.
- **Every request is signed with `NETD_KEY`.** The header is

  ```
  Authorization: berth-netd-v1 <unix time>:<hex HMAC-SHA256>
  ```

  where the HMAC is over the string
  `"berth-netd api v1\n" + <unix time> + "\n" + <METHOD> + "\n" + <path>`
  under the raw 32-byte key (`NETD_KEY` hex-decoded, the same bytes that sign
  forwards), and `<path>` is the request path without the query string. The
  time must be within 60 seconds of the host's clock, so a captured request is
  useless a minute later. Anything else gets `401` and no other information.
- `API_TLS=0` serves plain HTTP. It exists for the test suite; do not use it
  on a host.

The API only reads. Nothing it serves changes rules, containers or the host.

### Endpoints

All are `GET` and answer `application/json`.

**`/v1/health`**: is the API up and the key right.

```json
{"ok": true, "version": "1"}
```

**`/v1/status`**: what the agent is doing, in one call.

```json
{
  "version": 1,
  "config": {"bridge": "vmbr0", "public_v4": "203.0.113.10", "v4_cidr": "10.60.0.0/22", "v4_gateway": "10.60.0.1",
             "port_min": 20000, "port_max": 29999, "vmid_min": 3000, "vmid_max": 3999, "interval": 5, "ssh_password_login": true},
  "gateway": {"address": "10.60.0.1/22", "present": true},
  "ip_forward": true,
  "ipv6_forward": true,
  "chains": {"prerouting": true, "postrouting": true},
  "forwards": [
    {"proto": "tcp", "public_port": 20000, "ip": "10.60.0.2", "port": 22, "vmid": 3000},
    {"proto": "udp", "public_port": 20001, "ip": "10.60.0.2", "port": 53, "vmid": 3000}
  ]
}
```

`forwards` are the ones the agent applies: signed, in range, and not
conflicting. Forwards it skips are not listed (the journal says why).

**`/v1/containers/<vmid>/ssh-diagnosis`**: everything `berth-netd
--diagnose-ssh <vmid>` measures, for one container. It takes a few seconds
(it pings, connects to sshd, and runs a short script inside the container
through `pct exec`), one runs at a time, and a second request waits up to 30
seconds for its turn before answering `429`.

```json
{
  "container": {"vmid": 3000, "signed": true, "ip": "10.60.0.2", "running": true},
  "forward": {"public": "203.0.113.10:20000", "port": 20000, "packets": 48213},
  "host": {"load1": 0.42, "load5": 0.38, "load15": 0.31, "conntrack_count": 1532, "conntrack_max": 262144,
           "mtu_bridge": 1500, "mtu_veth": 1500, "cpu_pressure10": 0.0},
  "keystroke": {"ping_ms": 0.061, "limits": "cores: 2 memory: 2048",
                "cpu_pressure10": 0.0, "cpu_pressure60": 0.12, "throttled_count": 0, "throttled_s": 0.0,
                "memory_pressure10": 0.0},
  "uplinks": [{"port": "eno1", "qdisc": ["mq", "fq_codel"], "tx_dropped": 0}],
  "login": {"banner_ms": 7, "banner": "SSH-2.0-OpenSSH_9.2p1 Debian-2+deb12u3", "pct_exec_ms": 310,
            "sshd_installed": true,
            "sshd": {"usedns": "no", "gssapiauthentication": "no", "usepam": "yes", "permitrootlogin": "yes", "passwordauthentication": "yes"},
            "logind": "active", "logind_ms": 10, "ssh_unit": "active",
            "dns_ms": 20, "dns": "ok", "nameservers": "10.60.0.1",
            "motd_ms": 0, "motd": ""},
  "hints": [],
  "measured_at": 1794528000
}
```

| Field | Meaning |
|---|---|
| `container.signed` | `false`: no valid berth signature, so no forwards and nothing else measured |
| `container.running` | `false`: stopped, nothing else measured |
| `forward` | the signed tcp forward to port 22, if any; `packets` is the DNAT rule's counter |
| `host` | load averages; conntrack use (full = dropped packets); MTUs; `cpu_pressure10`: % of the last 10 s the host had runnable tasks waiting for a CPU |
| `keystroke` | the per-character round trip: `ping_ms` host → container (missing: no reply); the container's `cores`/`cpulimit`/`memory` caps; its CPU and memory pressure (%, last 10 s / 60 s); how often `cpulimit` throttled it |
| `uplinks` | the physical ports behind the bridge: queue discipline (`pfifo_fast` means no fair queuing) and transmit drops |
| `login` | time to sshd's greeting (no authentication yet); the `pct exec` round trip; sshd's settings from `sshd -T`; systemd-logind's state and answer time; a DNS lookup's time and result; the time the `update-motd.d` scripts take (Ubuntu) |
| `hints` | plain sentences, one per thing that stood out, each naming what to change. Empty: nothing on the host stands out, so compare with `ping <host>` from the client |

Fields are omitted when the host could not measure them (no cgroup files, no
`ping`, no `pct exec`); a hint says so where it matters.

| Status | Meaning |
|---|---|
| `200` | the body is the answer, hints included |
| `401` | missing, wrong or stale signature |
| `404` | unknown path, or no container with that vmid on this host |
| `429` | a diagnosis is already running and did not finish within 30 s |
| `500`, `504` | berth-netd failed or timed out; `error` says what, and the journal has the rest |

### Calling it

From Node.js, as berth would (the key and fingerprint are the ones already in
its `server/.env`):

```js
const crypto = require("node:crypto");
const https = require("node:https");

function netd(host, port, key, fingerprint, path) {
  const ts = Math.floor(Date.now() / 1000);
  const sig = crypto.createHmac("sha256", Buffer.from(key, "hex"))
    .update(`berth-netd api v1\n${ts}\nGET\n${path}`).digest("hex");
  return new Promise((resolve, reject) => {
    const req = https.request({
      host, port, path, method: "GET",
      headers: { Authorization: `berth-netd-v1 ${ts}:${sig}` },
      rejectUnauthorized: false,                       // pinned below instead
      checkServerIdentity: (_, cert) =>
        cert.fingerprint256 === fingerprint ? undefined : new Error("certificate fingerprint mismatch"),
    }, (res) => {
      let body = "";
      res.on("data", (c) => (body += c));
      res.on("end", () => resolve({ status: res.statusCode, body: JSON.parse(body) }));
    });
    req.on("error", reject);
    req.end();
  });
}

// netd("203.0.113.10", 8077, process.env.BERTH_NETD_KEY, process.env.PROXMOX_TLS_FINGERPRINT,
//      "/v1/containers/3000/ssh-diagnosis").then(console.log);
```

From a shell, for a quick look:

```bash
path=/v1/status; ts=$(date +%s); key=$(sed -n 's/^NETD_KEY=//p' /etc/berth-netd.conf)
sig=$(printf 'berth-netd api v1\n%s\nGET\n%s' "$ts" "$path" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$key" | sed 's/^.*= //')
curl -sk -H "Authorization: berth-netd-v1 $ts:$sig" "https://203.0.113.10:8077$path"
```

(`-k` skips verification for the one-off; a real client pins the fingerprint.)

## Requirements

Proxmox VE 8 (any Debian 12 based host with `iptables`, `perl`, `openssl` and
`pct`, all of which Proxmox ships). The API needs `python3`, which Proxmox also
ships. Nothing else needs installing.

## Tests

```bash
bash test/run.sh
```

The tests run against fixture container configs with `--print`, so they need
no Proxmox host and change no iptables rules. The API is tested against a
server started on a free local port, with a generated certificate for the
HTTPS test. CI runs them, plus ShellCheck,
on every push.
