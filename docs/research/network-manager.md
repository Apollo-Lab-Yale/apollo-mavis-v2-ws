# Programmatic NetworkManager control for the 3-NIC / 3-arm setup (Ubuntu 22.04)

Research note for the apollo-xarm7 stack. Everything below was **verified on the actual
target machine** (NetworkManager 1.36.6, polkitd 0.105-33ubuntu0.1, libnm GIR 1.36.6
installed) and against the **xArm-Python-SDK source** (`xarm/core/config/x_config.py`),
not just docs.

---

## 1. TL;DR / Recommendations

1. **Use `subprocess` + `nmcli -t -g`** from Python. No extra dependencies, stable
   machine-readable output, trivially debuggable. Keep libnm (`gi.repository.NM`,
   already installed) in reserve only if we later need push-style events.
2. **Address profiles by UUID, never by name.** The target machine *right now* has two
   profiles both named `xarm7_1` with different UUIDs and different IPs. Name-based
   `nmcli con up xarm7_1` is a coin flip.
3. **Verify arm connectivity with a plain TCP connect to port 502** (the SDK control
   port), preceded by an interface-bound `ping -I <nic>`. Do not write bytes on 502.
4. **Make boot deterministic once, verify every run**: after auto-matching, write
   `connection.interface-name` (and/or `802-3-ethernet.mac-address`) into each arm
   profile, set `autoconnect yes`, and disable stale/duplicate profiles. Persist the
   `{arm -> (mac, ifname, profile-uuid)}` map to a JSON state file.
5. **Never touch the device that owns the lowest-metric default route** (internet).
   Additionally set `ipv4.never-default yes` and clear `ipv4.gateway` on all arm
   profiles — the machine currently has a bogus
   `default via 192.168.1.1 dev enp36s0f0 proto static metric 20100` route created by
   an arm profile's gateway setting.
6. **Grant rights via a polkit `.pkla` file + `netdev` group** — Ubuntu 22.04's polkit
   is 0.105 (LocalAuthority backend only); JavaScript `.rules` files are **ignored**.
7. **One arm per subnet.** Keep the current scheme (arm N on `192.168.N.0/24`, host at
   `192.168.N.12`, arm at e.g. `192.168.N.2xx`). Two NICs on the same subnet breaks
   Linux routing/ARP in ways that produce false-positive pings.

---

## 2. Ground truth on the target machine (audit, 2026-09-01)

```text
NICs (ethernet):  enp36s0f0, enp36s0f1        # dual-port PCI card
                  enx00e04c683d97              # USB dongle, name derived from MAC (stable)
Internet:         wlp38s0 (Wi-Fi "APOLLO Lab") + tailscale0
Arm profiles:     xarm7_1  192.168.1.x/24   (TWO profiles with this name, different UUIDs!)
                  xarm7_2  192.168.2.12/24  uuid bd3e7da6-...  (ipv4.gateway 192.168.1.1 — wrong subnet!)
                  xarm7_3  192.168.3.12/24  uuid 6753457b-...  (ipv4.gateway 192.168.3.1)
Routes:           default via 192.168.0.1 dev wlp38s0    metric 600     <- real internet
                  default via 192.168.1.1 dev enp36s0f0  metric 20100   <- pollution from arm profile
Device states:    enp36s0f0 connected; enp36s0f1 unavailable (carrier off);
                  enx00e04c683d97 unavailable (carrier off)
```

Every failure mode this note warns about already exists on the machine. The
reconciliation tool described in §7/§8 should clean this up.

---

## 3. xArm control box ports (verified from SDK source)

From `xarm/core/config/x_config.py`, `class SocketConf` (xArm-Python-SDK, master):

| Port  | Constant                | Purpose                                             |
|-------|-------------------------|-----------------------------------------------------|
| 502   | `TCP_CONTROL_PORT`      | **Main SDK control port** (Modbus-TCP-framed private protocol; `XArmAPI` command socket) |
| 503   | `TCP_CONTROL_PORT + 1`  | RS-485 transparent-transmission passthrough (only if `use_503_port=True`) |
| 30000 | `TCP_REPORT_RT_PORT`    | External-device / tool-GPIO reporting stream        |
| 30001 | `TCP_REPORT_NORM_PORT`  | "normal" state report stream                        |
| 30002 | `TCP_REPORT_RICH_PORT`  | "rich" state report stream — **SDK default** (`report_type='rich'` in `xarm/x3/base.py:69`) |
| 30003 | `TCP_REPORT_REAL_PORT`  | "real" (high-rate) state report stream              |
| 18333 | (not in SDK)            | UFACTORY Studio web UI (http) — useful secondary probe |

**Connectivity check = TCP connect to `(arm_ip, 502)`.** A successful connect proves
the control box is up and reachable through that NIC. Close immediately; do not send
data (502 is the live control channel). If 502 refuses but ping answers, the box is
still booting (boot takes ~1–2 min; the IP stack comes up before the control service).

---

## 4. nmcli command cheat sheet (v1.36.6 syntax, all verified locally)

Run everything with `LC_ALL=C` for stable output. Exit codes: `0` ok, `3` timeout
(`--wait`), `4` activation failed, `8` NM not running, `10` connection/device not found.

### Enumerate NICs

```bash
# terse: DEVICE:TYPE:STATE:CONNECTION
nmcli -t -f DEVICE,TYPE,STATE,CONNECTION device status

# per-device detail (carrier is the key field for "is a cable plugged in / arm powered")
nmcli -t -f GENERAL.DEVICE,GENERAL.TYPE,GENERAL.STATE,GENERAL.HWADDR,GENERAL.CONNECTION,WIRED-PROPERTIES.CARRIER \
      device show enp36s0f0
# -> GENERAL.STATE:100 (connected) | 30 (disconnected) | 20 (unavailable = NO CARRIER) | 10 (unmanaged)
# -> WIRED-PROPERTIES.CARRIER:on|off       (equivalently: cat /sys/class/net/<if>/carrier)

# runtime IP of a device
nmcli -g IP4.ADDRESS device show enp36s0f0        # -> 192.168.1.11/24
```

### Enumerate profiles + their IPv4 config

```bash
# NAME:UUID:TYPE:DEVICE:ACTIVE  (one line per profile; DEVICE empty if not active)
nmcli -g NAME,UUID,TYPE,DEVICE,ACTIVE connection show

# static config of one profile — ALWAYS address by uuid
nmcli -g connection.interface-name,connection.autoconnect,connection.autoconnect-priority,ipv4.method,ipv4.addresses,ipv4.gateway,ipv4.never-default,802-3-ethernet.mac-address \
      connection show uuid <UUID>
```

`-g` (`--get-values`) = `--terse --mode tabular --fields`, prints one value per line
with no keys — ideal for scripting. `-t -f` keeps `key:value` pairs.

### Create a static-IP arm profile

```bash
nmcli connection add type ethernet \
    con-name arm1 ifname enp36s0f0 \
    connection.autoconnect no \
    ipv4.method manual ipv4.addresses 192.168.1.12/24 \
    ipv4.never-default yes ipv4.gateway "" \
    ipv6.method disabled
# prints: Connection 'arm1' (<uuid>) successfully added   -> parse the uuid, or use:
nmcli -g connection.uuid connection show arm1
```

Notes:
- `ipv4.gateway ""` + `ipv4.never-default yes`: the arm subnet is a stub; a gateway
  here is what created the bogus default route on the machine.
- `ipv6.method disabled` avoids "waiting for router advertisement" delays.
- `ifname` sets `connection.interface-name`. Use `ifname "*"` (or omit) for a
  floating profile during the probing phase; pin it afterwards (§8).
- To pin by MAC instead of interface name: `802-3-ethernet.mac-address AA:BB:CC:DD:EE:FF`.

### Bind / rebind a profile to a device

```bash
nmcli connection modify uuid <UUID> connection.interface-name enp36s0f0
nmcli connection modify uuid <UUID> connection.interface-name ""      # unbind (empty resets)
nmcli connection modify uuid <UUID> 802-3-ethernet.mac-address 08:BF:B8:89:4F:3A
```

### Activate / deactivate

```bash
nmcli -w 15 connection up   uuid <UUID> ifname enp36s0f0   # -w = timeout seconds (default 90)
nmcli -w 10 connection down uuid <UUID>
nmcli device disconnect enp36s0f1    # also *blocks autoconnect* on that device until
                                     # 'nmcli device connect' / 'con up' — useful to park a NIC
```

Semantics that matter:
- Activating profile B on a device implicitly tears down whatever profile was active
  there. A profile can be active on only **one** device at a time — `con up ... ifname
  <other>` *moves* it.
- If the profile's `connection.interface-name` is set to X, `con up ... ifname Y`
  fails with "device not compatible". During NIC probing use an **unbound** profile.
- If the device has no carrier (state 20 `unavailable`), `con up` fails fast with
  "No suitable device found for this connection". Check carrier first.

### Watch for changes (optional)

```bash
nmcli monitor          # human-oriented event stream (device state, connection changes)
ip monitor link        # kernel-level carrier events
```

---

## 5. Parsing terse output correctly

In `-t`/`-g` mode the separator is `:` and literal colons are escaped as `\:`
(observed: `802-3-ethernet.mac-address` → `08\:BF\:B8\:89\:4F\:3B`). Multi-value
properties (e.g. two `ipv4.addresses`) come back comma-separated on one line for
`connection show`, or as multiple `IP4.ADDRESS[n]` lines for `device show`.

```python
def split_terse(line: str) -> list[str]:
    """Split one line of `nmcli -t` output on unescaped colons."""
    fields, cur, it = [], [], iter(line)
    for ch in it:
        if ch == "\\":
            nxt = next(it, "")
            cur.append(nxt)          # unescape \: \\ etc.
        elif ch == ":":
            fields.append("".join(cur)); cur = []
        else:
            cur.append(ch)
    fields.append("".join(cur))
    return fields
```

Always invoke as `subprocess.run([...], env={**os.environ, "LC_ALL": "C"}, ...)`.

---

## 6. Python integration options

| Option | Package | Verdict |
|---|---|---|
| **subprocess + nmcli** | none (nmcli 1.36.6 ships with OS) | **Recommended.** Terse mode is a stable scripting contract (documented in `nmcli(1)`), exit codes are meaningful, every operation is copy-pasteable for debugging, works over SSH, no C/GLib deps in the uv-managed venv. |
| libnm via PyGObject | `python3-gi` + `gir1.2-nm-1.0` (**already installed**, `NM.Client.new(None)` works, v1.36.6) | The official API; async signals (device added, carrier change) without polling. Cost: GLib main-loop integration, system-site-packages coupling (awkward with uv venvs — needs `--system-site-packages` or `PyGObject` wheel + system girepository). Keep as plan B if we ever need event-driven NIC hotplug handling. |
| `sdbus-networkmanager` (PyPI) | pure D-Bus, `pip install --only-binary ':all:' sdbus-networkmanager` | Works, typed, async or blocking. But small third-party project (few maintainers), and D-Bus paths/flags are far more verbose than nmcli for our 6 operations. Not worth it. |
| `python-dbus` (installed) / `python-networkmanager` | dbus-python | `python-networkmanager` is unmaintained; raw dbus-python is painful. Avoid. |
| `nmcli` PyPI wrapper package | `pip install nmcli` | Just wraps subprocess anyway; adds a dependency for ~50 lines of code we'd rather own. Skip. |

We need exactly: list devices, list connections, show config, add, modify, up/down.
That is six `nmcli` invocations at setup time — subprocess wins on every axis except
event push, which we don't need (we re-verify before each session anyway).

---

## 7. Auto-matching algorithm (arm IP → profile → NIC)

Inputs: user config `[{name: "arm1", ip: "192.168.1.235", prefix: 24}, ...]`,
state file `~/.config/apollo-xarm7/nic_map.json`.

```text
0. SAFETY: internet_devs = devices of all current default routes with the lowest
   metric (`ip -j route show default`). Never activate/deactivate/modify anything
   on those devices, and exclude them from the candidate pool.

1. Fast path: if state file has {arm: {mac, ifname, profile_uuid}}:
     - resolve mac -> current ifname (names can drift; MAC is the stable key)
     - if profile_uuid still exists and is active on that ifname, just probe (step 4)
     - on success: done for this arm.

2. Profile selection per arm:
     subnet = ip_network(f"{arm.ip}/{arm.prefix}", strict=False)
     candidates = ethernet profiles with ipv4.method==manual and
                  static address inside subnet and host-part != arm.ip
     pick by UUID; if none, create one (nmcli connection add ..., §4),
     host address from config (default: .12 in the subnet, matching current lab convention).
     For probing, temporarily clear connection.interface-name (else `ifname` override fails).

3. NIC probing per arm (serialized; one arm at a time):
     pool = ethernet devices, carrier==on, not internet_devs, not already mapped
     for nic in pool:
         nmcli -w 15 con up uuid <UUID> ifname <nic>     -> if rc != 0: continue
         probe(arm.ip, nic)                              -> see below
         if ok: record mapping, break
         else:  nmcli -w 10 con down uuid <UUID>         # release the NIC

4. probe(ip, nic):  (no root needed)
     a) ping -c1 -W1 -I <nic> <ip>        retry ~3x (first packet often lost to ARP resolution)
        cross-check ARP actually resolved:  ip neigh show <ip>  -> REACHABLE/STALE (not FAILED)
     b) socket.create_connection((ip, 502), timeout=1.0); close immediately.
        - connect OK            -> arm reachable and control service up  => MATCH
        - ECONNREFUSED + ping OK-> right NIC, arm still booting          => MATCH (warn)
        - timeout / no ARP      -> wrong NIC                              => NO MATCH

5. Persist mapping keyed by arm name, storing NIC MAC + ifname + profile UUID + arm ip
   + timestamp. Then run the reconciliation step (§8) so the next boot needs no probing.
```

Reference implementation sketch:

```python
import json, os, socket, subprocess, ipaddress, time

ENV = {**os.environ, "LC_ALL": "C"}

def nmcli(*args: str, timeout: float = 20) -> subprocess.CompletedProcess:
    return subprocess.run(["nmcli", *args], capture_output=True, text=True,
                          env=ENV, timeout=timeout)

def ethernet_devices() -> list[dict]:
    out = nmcli("-t", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status")
    devs = []
    for line in out.stdout.splitlines():
        dev, typ, state, conn = split_terse(line)[:4]
        if typ != "ethernet":
            continue
        carrier = open(f"/sys/class/net/{dev}/carrier").read().strip() == "1" \
                  if os.path.exists(f"/sys/class/net/{dev}/carrier") else False
        mac = nmcli("-g", "GENERAL.HWADDR", "device", "show", dev).stdout.strip().replace("\\:", ":")
        devs.append(dict(dev=dev, state=state, conn=conn, carrier=carrier, mac=mac))
    return devs

def internet_devices() -> set[str]:
    routes = json.loads(subprocess.run(["ip", "-j", "route", "show", "default"],
                                       capture_output=True, text=True).stdout or "[]")
    if not routes:
        return set()
    best = min(r.get("metric", 0) for r in routes)
    return {r["dev"] for r in routes if r.get("metric", 0) == best}

def profile_ipv4(uuid: str) -> tuple[str, list[str]]:
    out = nmcli("-g", "ipv4.method,ipv4.addresses", "connection", "show", "uuid", uuid)
    method, addrs = (out.stdout.splitlines() + ["", ""])[:2]
    return method, [a.strip() for a in addrs.split(",") if a.strip()]

def tcp_probe(ip: str, port: int = 502, timeout: float = 1.0) -> str:
    try:
        socket.create_connection((ip, port), timeout=timeout).close()
        return "open"
    except ConnectionRefusedError:
        return "refused"          # host up, xArm service not (yet) listening
    except OSError:
        return "unreachable"

def ping_via(nic: str, ip: str, tries: int = 3) -> bool:
    for _ in range(tries):
        if subprocess.run(["ping", "-c1", "-W1", "-I", nic, ip],
                          stdout=subprocess.DEVNULL).returncode == 0:
            return True
    return False

def activate(uuid: str, nic: str) -> bool:
    return nmcli("-w", "15", "connection", "up", "uuid", uuid, "ifname", nic).returncode == 0

def deactivate(uuid: str) -> None:
    nmcli("-w", "10", "connection", "down", "uuid", uuid)
```

---

## 8. Making boot deterministic (one-time reconciliation)

After a successful mapping run, freeze it so NM autoconnect does the right thing at
boot and the Python layer only *verifies*:

```bash
# for each mapped (arm, nic, uuid):
nmcli connection modify uuid <UUID> \
    connection.interface-name <nic> \
    802-3-ethernet.mac-address <nic-mac> \
    connection.autoconnect yes connection.autoconnect-priority 50 \
    ipv4.never-default yes ipv4.gateway "" ipv6.method disabled

# stale / duplicate profiles found in the same subnets:
nmcli connection modify uuid <STALE_UUID> connection.autoconnect no   # or: connection delete uuid <STALE_UUID>
```

On this machine that means: dedupe the two `xarm7_1` profiles, strip
`ipv4.gateway 192.168.1.1` from `xarm7_1`/`xarm7_2` (the xarm7_2 gateway is even in
the wrong subnet), and pin each surviving profile to its NIC by MAC.
Binding by MAC beats binding by ifname: `enp36s0f*` names shift if PCI topology
changes, and the USB dongle already carries a MAC-derived name (`enx00e04c683d97`).

---

## 9. Not disrupting the internet NIC

- **Identify, then denylist.** `ip -j route show default` → device(s) of the
  lowest-metric default route (here: `wlp38s0`, plus `tailscale0` as `connected
  (externally)`). Exclude them and any `tun`/`bridge`/`wifi` device from every
  enumerate/activate/deactivate path. Only ever operate on `TYPE == ethernet` devices
  that are not internet devices.
- **Keep arm profiles route-inert**: `ipv4.never-default yes`, empty `ipv4.gateway`,
  no `ipv4.dns`. A stub subnet needs neither. This is not hypothetical — the machine
  currently has a second default route (metric 20100) via an arm NIC; if Wi-Fi drops,
  all internet traffic would black-hole into the arm subnet.
- **Never** call `nmcli networking off`, `nmcli radio wifi off`, or
  `nmcli device disconnect <internet-dev>` from tooling.
- Activation of profile X on NIC A cannot affect NIC B in NM — per-device operations
  are isolated — so the only cross-contamination vectors are routes/DNS, both closed
  by the profile settings above.

---

## 10. Permissions: sudo-less NetworkManager control on Ubuntu 22.04

Verified on the machine: `polkitd 0.105-33ubuntu0.1` uses the **LocalAuthority
(`.pkla`) backend only**. The JS file NetworkManager ships at
`/usr/share/polkit-1/rules.d/org.freedesktop.NetworkManager.rules` (grants
`settings.modify.system` to local+active `sudo`/`netdev` members) is **inert on
22.04** — `polkitd` here contains no JS engine (confirmed via binary strings +
Debian changelog). Don't cargo-cult `.rules` advice from Arch/Fedora wikis.

Current implicit defaults (`pkaction --verbose`):

| Action | any (SSH / services) | inactive | active (local GUI) |
|---|---|---|---|
| `org.freedesktop.NetworkManager.network-control` (con up/down) | `auth_admin` | yes | yes |
| `org.freedesktop.NetworkManager.settings.modify.system` (add/modify profiles) | `auth_admin_keep` | `auth_admin_keep` | `auth_admin_keep` |

So: from the local desktop session, `con up`/`down` already works unprivileged, but
creating/modifying profiles pops a polkit auth dialog; **from SSH or a systemd
service, everything requires admin auth**. Since the runtime will run headless/SSH,
install this once:

```ini
# /etc/polkit-1/localauthority/50-local.d/46-apollo-networkmanager.pkla
[apollo: let netdev group manage NetworkManager]
Identity=unix-group:netdev
Action=org.freedesktop.NetworkManager.network-control;org.freedesktop.NetworkManager.settings.modify.system
ResultAny=yes
ResultInactive=yes
ResultActive=yes
```

```bash
sudo usermod -aG netdev $USER    # netdev group exists (gid 120); re-login required
# polkitd watches the directory; no restart needed
```

`Action=` accepts a `;`-separated glob list; `org.freedesktop.NetworkManager.*` also
works if we prefer blanket access. Alternative (coarser): a sudoers drop-in
`youruser ALL=(root) NOPASSWD: /usr/bin/nmcli` — works, but the pkla route keeps
commands unprefixed and auditable. For Ubuntu 24.04+ (polkit ≥ 123) the same grant
moves to a JS rule in `/etc/polkit-1/rules.d/`.

Probing needs no privileges at all: `ping` works via `net.ipv4.ping_group_range`/caps,
TCP connect is unprivileged, and use `ip neigh show` instead of `arping`
(iputils `arping` needs `cap_net_raw`).

---

## 11. Pitfalls checklist

1. **Duplicate profile names** — exists on the machine today (two `xarm7_1`). Always
   `uuid <UUID>`, and have the reconciler flag/merge duplicates per subnet.
2. **No carrier ⇒ device `unavailable` (state 20)** — `con up` fails immediately.
   Check carrier before probing; when an arm control box is powering on, carrier
   appears seconds before ping works and ~1–2 min before TCP 502 opens. Treat
   "ping OK, 502 refused" as *right NIC, arm booting* — poll 502, don't re-probe NICs.
3. **`connection.interface-name` vs `ifname` override** — a profile pinned to devA
   cannot be activated on devB; unpin (`connection.interface-name ""`) before probing.
4. **Profiles are single-active** — probing a profile on NIC2 silently detaches it
   from NIC1. Probe serially and deactivate between attempts.
5. **First ping lost to ARP** — always retry ping ≥3× and/or confirm with
   `ip neigh show <ip>` (`REACHABLE/STALE` good, `FAILED/INCOMPLETE` bad).
6. **Same subnet on two NICs = ARP flux / false positives.** `ping -I` binds the
   egress interface but the kernel's weak host model answers ARP on any interface.
   Enforce one subnet per arm (change arm IPs in UFACTORY Studio if needed).
7. **DHCP fallback** — an `ipv4.method auto` profile on an arm NIC hangs ~45 s
   (`ipv4.dhcp-timeout`) and then cycles; reconciler must force `manual`.
8. **Gateway/default-route pollution** — arm profiles must have
   `ipv4.never-default yes` + no gateway (live bug on the machine, §2).
9. **IPv6 autoconf delays** — `ipv6.method disabled` on arm profiles.
10. **Interface renaming** — persist mapping by **MAC**, resolve to ifname at runtime.
11. **`nmcli` name/uuid vs localized output** — run with `LC_ALL=C`; parse `-t`
    escaping (`\:`) per §5; never parse the human-formatted tables.
12. **Autoconnect races at boot** — NM may pick a different same-NIC profile by
    `connection.autoconnect-priority`; the reconciler pins priorities (arm profiles
    50, stale profiles `autoconnect no`).
13. **Timeouts** — `nmcli con up` default wait is 90 s; always pass `-w 10..15` so a
    dead NIC doesn't stall the whole matching loop.

---

## 12. Sources

- `nmcli(1)` NetworkManager 1.36.6 (local) and https://networkmanager.dev/docs/api/latest/nmcli.html
  (exit codes, `-t/-f/-g`, `--wait`, `connection add/modify/up` grammar)
- https://networkmanager.dev/docs/api/latest/nmcli-examples.html (static-IP add,
  terse-mode escaping, dispatcher scripts)
- xArm-Python-SDK source @ github.com/xArm-Developer/xArm-Python-SDK —
  `xarm/core/config/x_config.py` (`SocketConf`), `xarm/x3/base.py` (default
  `report_type='rich'`, 503 passthrough)
- Local machine audit: `nmcli device/connection show`, `pkaction --verbose`,
  `dpkg -l polkitd`, `/usr/libexec/polkitd` strings, `ip route`
- https://github.com/python-sdbus/python-sdbus-networkmanager (evaluated, not chosen)
