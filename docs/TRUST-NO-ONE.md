# Trust No One architecture

`tkoc` treats boot trust, runtime confinement, controlled egress, external
telemetry, and recovery as independent layers. No single layer is assumed to
cover for a failure in another, and `tkoc` does not run as a background daemon
enforcing any of them — it stages and activates explicit configuration, then
reports on the result. Read [the threat model](THREAT-MODEL.md) for what these
layers are actually defending against.

## Boot trust

Checked by `tkoc audit` and `tkoc doctor`, not installed by `tkoc`:

- Secure Boot state, read through `mokutil --sb-state` with the UEFI
  `SecureBoot-*` variable as a fallback.
- Kernel lockdown mode (`/sys/kernel/security/lockdown`). On Fedora this
  engages automatically when Secure Boot is on.
- Kernel module signature enforcement (`sig_enforce`), and for NVIDIA
  specifically, whether the akmod-built module is signed by an enrolled MOK —
  an unsigned one will not load under Secure Boot at all.
- A measured unified kernel image (`bootctl status`). Fedora's default
  GRUB-and-shim path does not produce one; the audit says so rather than
  reporting a bare failure.
- TPM device presence, and LUKS/dm-crypt backing the root filesystem.

These require deliberate installation choices that `tkoc` cannot safely automate
without irreversible, boot-affecting changes. The audit surfaces what is missing
so the administrator can decide.

## Runtime confinement

Applied directly by `tkoc firewall <tier>` through
`config/sysctl.d/60-tkoc-hardening.conf`, and again at runtime by the
`firewall-extras` privacy category so either path alone leaves the kernel in the
intended state:

- Restricted `kptr`/`dmesg` exposure, unprivileged BPF, and `ptrace` scope.
- No privileged core dumps; hardlink, symlink and FIFO protections.
- systemd-coredump storage disabled, so crashes do not leave process memory on
  disk.
- IPv6 disabled off loopback from the strong tier up, matching the firewall.

Verified, not applied, by `tkoc audit`:

- SELinux enforcing. This is the expected mandatory access control on Fedora,
  and it is the one control here that `tkoc` will never change for you.
- CPU vulnerability mitigations with no unmitigated report.
- The running kernel being the newest installed one — a kernel update that has
  not been rebooted into is the most common reason a patched CVE or a freshly
  built akmod is not actually in effect.

## Controlled egress

Applied by `tkoc firewall <tier>` through `config/firewall/tkoc.nft`:

- Default-deny inbound and forwarded traffic at every tier; default-allow
  outbound.
- From strong: LAN discovery and multicast dropped in both directions, off-host
  IPv6 blocked.
- At lockdown: DNS restricted to the resolvers chosen at apply time, with
  DNS-over-QUIC dropped outright and DNS-over-TLS dropped unless opted in to
  those same resolvers.
- Loopback accepted at every tier without exception, because systemd-resolved's
  stub at 127.0.0.53 is what every application actually talks to.

This layer is intentionally not an application-aware egress firewall — see the
threat model for why DoH-in-HTTPS is out of scope.

One Fedora-specific dependency belongs here: firewalld also manages nftables,
so leaving it running alongside this policy means the two overwrite each other.
That is why applying a tier displaces it, why the displacement is recorded in
the snapshot, and why a running firewalld is a FAIL in the audit rather than an
informational note.

## External telemetry

Disabled by named privacy categories, each reversible from a snapshot:

- ABRT crash collection and upload; `dnf` countme; fwupd's LVFS result
  reporting.
- Plasma User Feedback, Baloo content indexing, KRunner web shortcuts, recent
  documents, and session restore.
- GeoClue, so nothing on the machine resolves its own physical location by
  querying a remote service.

Checked by `tkoc audit`, not installed by `tkoc`:

- A malware scanner present (`clamscan`); `tkoc clamav install` is opt-in.
- `auditd` enabled and active, and early-boot auditing (`audit=1`) on the kernel
  command line.
- dm-verity root integrity.
- No unexpected listening sockets, and no known remote-access packages or units
  installed or active.

## Recovery

Applied by every mutating command:

- A transaction opens before anything changes, recording the prior value of each
  file, systemd unit (enabled, active and masked state separately), sysctl,
  kconfig key, NetworkManager DNS and IPv6 setting, nftables table, and
  firewalld state it is about to touch.
- `tkoc harden` covers both stages with **one** transaction, so a failure in
  either rolls the whole run back rather than leaving the machine half-hardened.
  A privacy category that fails rolls back every category in that run, not just
  itself.
- `tkoc state list|show|restore|prune` inspects and replays them. A snapshot
  from another machine or user is refused unless forced; one whose directory is
  group- or world-writable, or not owned by you, is refused outright.
- `--dry-run` previews every command, including restore.

Whether an operation needs root is decided by what the invoking user can
actually do to the path, not by how the path is spelled — so no password is
asked for work that never required one, and nothing is silently skipped that
did.

No layer here silently enrolls keys, rewrites disks, installs a local TLS
authority, flips SELinux, or sets an immutable attribute. Where that would be
the next step, `tkoc audit` reports it as a gap for the administrator to close
deliberately.
