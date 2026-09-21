# Trust No One architecture

`tkoc` treats boot trust, runtime confinement, controlled egress, external
telemetry, and recovery as independent layers. No single layer is assumed to
cover for a failure in another, and `tkoc` does not run as a background daemon
enforcing any of them — it stages and activates explicit configuration, then
reports on the result. Read [the threat model](THREAT-MODEL.md) for what these
layers are actually defending against.

## Boot trust

Checked by `tkoc audit` / `tkoc doctor`, not installed by `tkoc`:

- Secure Boot state (UEFI `SecureBoot-*` variable).
- A measured unified kernel image (`bootctl status`).
- Kernel lockdown mode (`/sys/kernel/security/lockdown`).
- Kernel module signature enforcement (`sig_enforce`).
- `linux-hardened` as the running kernel.
- TPM device presence.

These require deliberate installation choices (a hardened kernel, a signed
UKI, Secure Boot enrollment) that `tkoc` cannot safely automate without
irreversible, boot-affecting changes. The audit surfaces what's missing so
the administrator can decide.

## Runtime confinement

Applied directly by `tkoc install`/`apply` via
`config/sysctl.d/60-tkoc-hardening.conf`:

- Restricted `kptr`/`dmesg` exposure, unprivileged BPF, and `ptrace` scope.
- No privileged core dumps; hardlink/symlink/FIFO protections.
- IPv6 disabled everywhere except loopback, matching the firewall.

Verified, not applied, by `tkoc audit`:

- A mandatory access control LSM (AppArmor or SELinux) active and enforcing.
- CPU vulnerability mitigations with no unmitigated report.

## Controlled egress

Applied directly by `tkoc install`/`apply` via `config/nftables.conf`:

- Default-deny inbound and forwarded traffic; default-allow outbound.
- DNS restricted to the resolver selected at install time; DNS-over-TLS and
  DNS-over-QUIC blocked outright.
- LAN discovery/multicast noise dropped in both directions.

This layer is intentionally not an application-aware egress firewall — see
the threat model for why DoH-in-HTTPS is out of scope.

## External telemetry

Checked by `tkoc audit`, not installed by `tkoc`:

- A malware scanner present (`clamscan`).
- `auditd` enabled, active, and early-boot auditing (`audit=1`) on the kernel
  command line.
- `dm-verity` root integrity.
- No unexpected listening sockets (`ss -lntu`).
- No known remote-access packages or units installed/active — and if found,
  `tkoc gut` removes them.

## Recovery

Applied by every mutating command:

- `tkoc install` snapshots every file it is about to replace, plus the live
  sysctl values and `nftables.service` state, before writing anything.
- `tkoc backups` lists recovery points; `tkoc rollback [latest|ID]` restores
  both the files and the runtime state from one.
- `tkoc gut` and `tkoc ice` support `--dry-run` to preview changes before
  they run.

No layer here silently enrolls keys, rewrites disks, installs a local TLS
authority, or flips an irreversible kernel control — where that would be the
next step, `tkoc audit` reports it as a gap for the administrator to close
deliberately.
