# Threat model

`the_king_of-casual` (`tkoc`) protects a single-user Fedora KDE workstation. It
assumes the machine talks to hostile networks, runs software the administrator
did not fully vet, and may sit on a LAN with other untrusted or compromised
devices. It does not assume a targeted, well-resourced physical attacker.

## In scope

- **Unsolicited inbound network traffic.** The nftables policy in
  `config/firewall/tkoc.nft` default-denies inbound and forwarded traffic at
  every tier, so a service accidentally left listening is not reachable from
  off-host.
- **firewalld overwriting that policy.** On Fedora this is the most likely way
  the firewall silently stops being what you think it is: firewalld also
  manages nftables, and whichever tool writes last wins. Applying a tier
  disables and masks firewalld after asking, and `tkoc audit` reports a running
  firewalld as a FAIL rather than a note.
- **LAN discovery and fingerprinting noise.** From the strong tier up,
  SMB/NetBIOS, SSDP, mDNS, LLMNR, KDE Connect and Steam discovery are dropped
  in both directions, so the host neither announces itself nor answers casual
  LAN probing. Avahi and cups-browsed are disabled at the userspace level too.
- **DNS exfiltration and unexpected resolvers.** At the lockdown tier, outbound
  UDP/TCP 53 is permitted only to the resolver chosen at apply time; everything
  else on 53, plus DNS-over-TLS and DNS-over-QUIC on 853, is dropped and
  counted. The `resolved` privacy category makes systemd-resolved agree with
  that, so the two cannot disagree into a machine that resolves nothing.
- **IPv6 attack surface.** From the strong tier up, IPv6 is disabled off
  loopback both in the firewall and at the kernel level, so the guarantee
  survives a firewall reload or failure rather than depending on nftables alone.
- **Kernel information leaks and cross-process snooping.** The sysctl policy
  restricts `kptr`/`dmesg` exposure, unprivileged BPF, `ptrace` scope, and
  privileged core dumps. `unprivileged_bpf_disabled` is set to 2, not 1,
  specifically so the change remains reversible without a reboot.
- **Crash dumps as a data-at-rest problem.** systemd-coredump writes full
  process memory into the journal by default — a copy of whatever a process had
  in RAM, readable by anyone who can read the journal. The `crash-reports`
  category turns that off at both the handler and the kernel level.
- **Telemetry and usage reporting.** ABRT, `dnf` countme, Plasma User Feedback,
  GeoClue, and fwupd's LVFS result reporting are each disabled by an explicit,
  named category rather than as a side effect of something else.
- **Known remote-access surfaces.** sshd, Cockpit, xrdp, VNC servers, and
  third-party agents (TeamViewer, AnyDesk, RustDesk, Tailscale, ZeroTier) are
  detected by `tkoc audit` and disabled by the `remote-access` category.
- **Boot and runtime integrity, as evidence.** `tkoc audit` reports on Secure
  Boot (through both `mokutil` and the efivar), LUKS-backed root, TPM presence,
  kernel lockdown, module signature enforcement, SELinux mode, auditd, and CPU
  mitigations — so gaps are visible even though tkoc does not enable these
  subsystems itself.
- **Hardware failures that look like software ones.** `tkoc doctor` reads btrfs
  device-error counters and scrub status, ext4 kernel error counts, SMART and
  NVMe health, PCI driver bindings, and 30 days of journal evidence for
  filesystem, driver and firmware failures.
- **The Fedora NVIDIA failure mode.** An akmod-built module that no rpm owns, a
  kernel/userspace version mismatch after a partial upgrade, or an unsigned
  module under Secure Boot each leave a machine without working graphics.
  `tkoc doctor` names which one it is and what to do about it.
- **Silent state drift and irreversible changes.** Every mutating command opens
  a transaction first and records the prior value of each file, unit, sysctl,
  kconfig key, NetworkManager setting and nftables table it touches. Every
  command supports `--dry-run`.

## Explicitly out of scope

- **DNS-over-HTTPS and other traffic tunneled inside ordinary HTTPS.** A generic
  host firewall cannot distinguish DoH from any other HTTPS request without a
  controlled proxy or a destination allowlist. `tkoc audit` reports this as a
  known gap rather than pretending to close it.
- **A fully compromised OS or root-level attacker.** tkoc hardens a trusted
  kernel and userspace. It is not a rootkit detector and cannot protect against
  an adversary who already has root.
- **Changing SELinux mode.** The `selinux` category reports the mode and how to
  change it. Moving a permissive system to enforcing can make it unbootable if
  the filesystem is mislabelled or a service has been running unconfined, and
  moving a disabled one requires a full relabel and a reboot. Both are real
  decisions, taken after reading the denials.
- **VPNs, Tor, and proxies.** These are legitimate outbound tools the
  permissive-egress design does not attempt to block.
- **Guest network isolation.** VM and container bridges (`virbr*`, `docker*`,
  `podman*`, `cni-podman*`, `incusbr*`, `vboxnet*`, `br-*`) start blocked in the
  forward chain. `tkoc vm net on` permits them; `off` blocks existing and new
  forwarded connections. Re-applying a firewall tier returns the toggle to
  off. VirtualBox NAT uses the host output path, so `tkoc vm` also disconnects
  registered VirtualBox adapters and restores their prior cable states on `on`.
  New VirtualBox VMs need an `off` reconciliation after creation. QEMU user-mode
  networking (SLIRP or passt) is still outside this toggle. Guest-to-host
  traffic also needs separate review. Tightening access selectively is a
  site-specific change.
- **Container-published ports.** A container runtime inserts its own DNAT rules,
  which bypass expectations set by the host firewall. `tkoc uav show containers`
  reports what is published and flags anything bound to all interfaces, but does
  not rewrite the runtime's rules.
- **Flatpak sandbox escapes.** `flatpak-portals` reports which applications hold
  whole-home filesystem access. It does not revoke them: an app that genuinely
  needs home access simply stops working, with nothing on screen saying why.
- **Firmware updates.** `tkoc doctor` and `tkoc update` report pending firmware,
  and `tkoc update --firmware` applies it only when you select that source. A
  firmware flash is never initiated by an audit.
- **Desktop applications, malware removal, or ongoing enforcement.** tkoc
  reports posture; it does not run as a background policy-enforcement daemon.
  The one thing it can install that runs unattended is the NetworkManager
  dispatcher, which sets DNS and IPv6 and nothing else.

See [the Trust No One architecture](TRUST-NO-ONE.md) for how these protections
are layered, and the main [README](../README.md) for usage.
