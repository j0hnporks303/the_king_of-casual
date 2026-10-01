# the_king_of-casual — Fedora edition

A small, auditable security baseline for a personal Fedora KDE workstation.
It keeps Fedora in charge of the machine and gives the administrator explicit
controls instead of running a policy-enforcement daemon.

This is the Fedora translation of the Arch tree in `../Arch(manjaro)/`, rebuilt
in the shape of [the macOS edition](https://github.com/j0hnporks303/the_king_of_maCasual):
one dispatcher over `tools/` and `stages/`, three tiers instead of one fixed
policy, `--dry-run` on everything, and real recovery snapshots.

## Install

Clone it and run `make`. That links one command, `tkoc`, into `~/.local/bin`.
Nothing is downloaded, nothing is chosen for you, and no shell config is edited.

```bash
cd Fedora
make
```

If `~/.local/bin` isn't on your PATH, `make` says so and prints the one line to
add. Install elsewhere with `make BIN_DIR=/somewhere/else`.

```bash
make            # link tkoc into ~/.local/bin
make check      # verify the link resolves, runs, and is not stale
make root-tools # root-owned copies of the privileged tools (optional)
make uninstall  # remove the symlink; the checkout is left alone
make purge      # remove tkoc from this machine
```

Nothing runs on its own. Every change is a command you type, and `--dry-run`
works on all of them.

```bash
tkoc check                   # read-only pre-flight, touches nothing
tkoc help                    # every command
tkoc harden strong --dry-run # see exactly what hardening would do
```

## firewalld

Fedora ships firewalld enabled, and **firewalld owns the nftables ruleset**.
The two cannot both manage it: whichever writes last wins, and neither posture
is then dependable.

So applying a tier disables and masks firewalld — after asking, and after
recording its exact prior state in that run's recovery snapshot:

```bash
tkoc state restore <id>    # firewalld comes back exactly as it was
```

If you would rather keep firewalld, `--keep-firewalld` skips that step. The
tkoc policy is still applied, but firewalld may overwrite it, and
`tkoc audit` will report that as a FAIL rather than pretend otherwise.

Boot persistence needs no daemon of its own: `nftables.service` loads the
policy, and `systemd-sysctl.service` loads the kernel settings. Both are part
of the OS.

## Tiers

```bash
tkoc harden basic
tkoc harden strong                      # the default
tkoc harden lockdown --dns 192.168.1.1
```

`harden` applies a firewall tier and a privacy level together under **one**
recovery snapshot, so a failure in either rolls the whole run back rather than
leaving the machine half-hardened.

| Profile | Privacy | Firewall | IPv6 |
|---|---|---|---|
| basic | basic | vanilla | enabled |
| strong | strong | strong | disabled |
| lockdown | lockdown | lockdown | disabled |

### Firewall tiers

| Tier | Policy |
|---|---|
| vanilla | Default-deny inbound and forwarded, permissive egress, conntrack, loopback, DHCP, rate-limited ICMP |
| strong | + LAN discovery and multicast dropped both directions, + off-host IPv6 blocked, + kernel hardening |
| lockdown | + DNS pinned to one resolver, + DNS-over-TLS and DNS-over-QUIC dropped |

All three come from one template, `config/firewall/tkoc.nft`. Lines carrying a
`# TKOC_NAME:` marker are inert comments until that tier enables them, so
reading the file shows the whole policy surface — including the parts your tier
left off.

```bash
tkoc firewall strong
tkoc firewall lockdown --dns 192.168.1.1
tkoc firewall strong --ssh-source 192.168.8.0/24
tkoc firewall status
tkoc firewall test --local-only
```

To check the inbound default drop from a second device on your LAN, run
`tkoc firewall test --inbound-check` on this machine. It shows a LAN address and
the command to run on the other device, then compares the nftables drop counter
after the probe. This check reads the live rules with sudo but changes no rules.
An increased counter is consistent with the probe reaching the firewall; other
inbound traffic can also increment it.

### Privacy levels

14 category scripts under `stages/hardening/`, each `--dry-run`-clean,
idempotent, and snapshot-backed. A category whose tool or unit is not installed
is skipped, not failed.

| Category | Level | What it covers |
|---|---|---|
| remote-access | basic | sshd, Cockpit, xrdp, VNC, TeamViewer/AnyDesk/RustDesk/Tailscale/ZeroTier |
| telemetry | basic | ABRT crash reporting, `dnf` countme |
| crash-reports | basic | systemd-coredump storage, core pattern, KDE DrKonqi |
| discovery | basic | Avahi/mDNS, cups-browsed, resolved's LLMNR and mDNS |
| geolocation | strong | GeoClue |
| kde-privacy | strong | Plasma User Feedback, Baloo indexing, KRunner web shortcuts, recent documents, session restore |
| package-manager | strong | `gpgcheck`, per-repo overrides, cache retention, flatpak remotes |
| flatpak-portals | strong | reports apps holding whole-home filesystem access |
| firmware | strong | fwupd result reporting to the LVFS |
| bluetooth | lockdown | adapter auto-enable, discoverability, the service |
| network-services | lockdown | Samba, NFS, rpcbind, LPD, sssd |
| selinux | lockdown | reports the mode — **never changes it** |
| resolved | lockdown | resolution policy matching the firewall's DNS pin |
| firewall-extras | lockdown | the kernel half of the network posture |

```bash
tkoc privacy strong
tkoc privacy lockdown --dry-run
tkoc privacy --categories telemetry,discovery
tkoc privacy list
tkoc privacy status
```

### The SSH carve-out

Remote access is off at every tier unless you type `--ssh`. That flag keeps
sshd reachable and adds one scoped nftables accept for TCP/22 — from the
current LAN /24 unless `--ssh-source` names something narrower.

An `TKOC_ALLOW_SSH` variable in your environment is **not** the same as typing
the flag. At the lockdown tier an ambient value is a hard error, because it
would punch an inbound hole through a policy you asked to lock down with
nothing on the command line to show why.

## Recovery

Every mutating command opens a transaction first and records the prior value of
each file, systemd unit, sysctl, kconfig key, NetworkManager setting and
nftables table it is about to change.

```bash
tkoc state list
tkoc state show latest
tkoc state restore <id>
tkoc state restore <id> --dry-run
tkoc state prune --keep 10 --yes
```

Snapshots live under `$XDG_STATE_HOME/tkoc/snapshots` and are never removed by
uninstall. A snapshot from another machine or user is refused unless you pass
`--force`; one from the macOS edition is refused outright, because it records a
different kind of state under the same path.

## Auditing

```bash
sudo "$(command -v tkoc)" audit   # full posture: firewall, boot trust, SELinux, listeners
sudo "$(command -v tkoc)" doctor  # hardware only: filesystems, SMART, drivers, firmware
tkoc status          # one page, read-only, no privilege
tkoc uav show all    # every listener, with its owner
```

`audit` exits non-zero if anything FAILed, so it doubles as the end-to-end gate
after applying a tier. Both are read-only: nothing here repairs a filesystem,
starts a SMART self-test, installs a package, changes a driver, or flips
SELinux.

`doctor` knows the two things that actually strand a Fedora desktop and have no
Arch equivalent: **btrfs** device-error counters and scrub status (Fedora
Workstation's default filesystem), and the **NVIDIA akmod** path — whether the
locally built module is owned by an rpm, whether kernel and userspace versions
match, and whether it is signed by an enrolled MOK under Secure Boot.

## Personal provisioning

`dotfiles`, `theme` and `ice` are opt-in and separate from the security
baseline. `dotfiles` and `theme` run as your normal user and refuse to run as
root: they only ever touch your own `$HOME`, `$XDG_CONFIG_HOME` and
`$XDG_STATE_HOME`.

```bash
tkoc dotfiles                    # link managed shell config into your home
tkoc dotfiles list-themes
tkoc dotfiles set-theme fedora
tkoc theme list
tkoc theme set breeze-dark
tkoc ice                         # optional customization packages via dnf
```

`dotfiles` prefers `~/.bashrc.d/50-tkoc.sh` — Fedora's own drop-in hook, which
its stock `~/.bashrc` already sources. That is one file owned entirely by this
tool, so removing it is a complete uninstall. Force the guarded `~/.bashrc`
block instead with `--bashrc` if your `~/.bashrc` has been rewritten without the
loop.

## Utilities

```bash
tkoc update                      # git + dnf + flatpak + fwupd, one confirmation
tkoc uav 443                     # is this port listening, and does policy allow it
tkoc uav detect forwarding       # NAT and IP-forwarding state
tkoc fs lock ~/Documents         # report file permissions that are too loose
tkoc fs lock ~/Documents --apply
sudo "$(command -v tkoc)" fs lockdown  # the root-owned counterpart
tkoc pgp encrypt ~/notes -r you@example.com
tkoc link ~/scripts/deploy.sh    # symlink onto PATH
tkoc vm net on|off|status        # guest bridges and VirtualBox adapters (off by default)
tkoc wg show                     # WireGuard keypair and tunnel state
tkoc clamav install --daily
tkoc killall                     # close every open graphical app
```

`fs lock` and `fs lockdown` report by default and only change modes with
`--apply`. Neither ever sets the immutable attribute: `chattr +i` is the
nearest Linux equivalent of the macOS edition's `chflags`, and it is a good way
to brick a package upgrade.

## Per-network DNS

```bash
tkoc firewall learn          # capture the network you are on now
tkoc firewall auto           # apply the matching profile
tkoc firewall watch install  # do it automatically on every network change
```

The dispatcher this installs sets **DNS and IPv6 and nothing else** — never the
tier, never the ruleset, never a service. It runs unattended and is triggered by
joining a network, so anything it could change is something an access point can
make it change.

## Development

```bash
make test        # shell suites and Python runtime regressions
```

`tests/regression.sh` checks that everything parses, that every `--help` path
runs without privilege and without touching `$HOME` (a fake `sudo` on PATH turns
any escalation into a failure), that each tier renders and differs from the next
exactly as documented, and that snapshots round-trip.

`tests/test-tkoc.sh` performs an isolated install, tier staging, privacy
preview, and uninstall inside a sandbox, without touching the host.

`tests/test-runtime.py` checks installed symlinks, command defaults, dry-run
safety, update query failures, network profiles and the installed dispatcher
helper. It uses temporary homes and fake system commands; it does not change
the host's services, firewall or drivers. Python 3 is required.

The suites run on a non-Fedora development machine. Where the native validator is
missing — `nft --check` above all — they say so plainly rather than reporting a
pass that nothing actually checked.

## Reading further

- [Threat model](docs/THREAT-MODEL.md) — what this defends against, and what it
  explicitly does not.
- [Trust No One architecture](docs/TRUST-NO-ONE.md) — how the layers relate.
