# Threat model

`the_king_of-casual` (`tkoc`) protects a single-user Arch Linux workstation.
It assumes the machine talks to hostile networks, runs software the
administrator did not fully vet, and may sit on a LAN with other untrusted or
compromised devices. It does not assume a targeted, well-resourced physical
attacker.

## In scope

- **Unsolicited inbound network traffic.** The `nftables` policy in
  `config/nftables.conf` default-denies inbound and forwarded traffic, so a
  service accidentally left listening is not reachable from off-host.
- **LAN discovery and fingerprinting noise.** SMB/NetBIOS, SSDP, mDNS,
  KDE Connect, and Steam discovery broadcasts are dropped in both directions,
  so the host neither announces itself nor answers casual LAN probing.
- **DNS exfiltration and unexpected resolvers.** Outbound UDP/TCP 53 is
  permitted only to the resolver selected at install time; everything else on
  port 53, plus DNS-over-TLS/DNS-over-QUIC on port 853, is dropped and
  counted.
- **IPv6 attack surface.** IPv6 is disabled everywhere except loopback, both
  in the firewall and (as of the current sysctl policy) at the kernel level,
  since the host has no reason to expose an IPv6 stack it isn't using.
- **Kernel information leaks and cross-process snooping.** The sysctl policy
  in `config/sysctl.d/60-tkoc-hardening.conf` restricts `kptr`/`dmesg`
  exposure, unprivileged BPF, `ptrace` scope, and unprivileged core dumps.
- **Known remote-access backdoors.** `tkoc audit` and `tkoc gut` detect and
  can remove common remote-access tooling (TeamViewer, AnyDesk, RustDesk,
  Tailscale, ZeroTier, VNC servers) and flag any active TCP/22 `sshd`.
- **Boot and runtime integrity, as evidence.** `tkoc audit` reports on Secure
  Boot, kernel lockdown, module signature enforcement, mandatory access
  control (AppArmor/SELinux), and measured boot, so gaps are visible even
  though `tkoc` does not itself enable these subsystems.
- **Silent state drift and irreversible changes.** Every file `tkoc` replaces
  is snapshotted first (`tkoc backups`, `tkoc rollback`), and `gut`/`ice`
  support `--dry-run` before they touch anything.

## Explicitly out of scope

- **DNS-over-HTTPS and other traffic tunneled inside ordinary HTTPS.** A
  generic host firewall cannot distinguish DoH from any other HTTPS request
  without a controlled proxy or destination allowlist; `tkoc audit` reports
  this as a known gap rather than pretending to close it.
- **A fully compromised OS or root-level attacker.** `tkoc` hardens a trusted
  kernel and userspace; it is not a rootkit detector and cannot protect
  against an adversary who already has root.
- **VPNs, Tor, and proxies.** These are legitimate outbound tools the
  permissive-egress design does not attempt to block.
- **Guest network isolation.** VM/container bridges (`vboxnet*`, `virbr*`,
  `docker*`, `incusbr*`, `br-*`) are forwarded broadly by default; tightening
  guest-to-host or guest-to-internet access is left as an explicit,
  site-specific change (see the comments in `config/nftables.conf`).
- **Desktop applications, malware removal, or ongoing enforcement.** `tkoc`
  reports posture; it does not run as a background policy-enforcement daemon.

See [the Trust No One architecture](TRUST-NO-ONE.md) for how these
protections are layered, and the main [README](../README.md) for usage.
