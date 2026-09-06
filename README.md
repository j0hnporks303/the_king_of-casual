# the_king_of-casual

`the_king_of-casual` is a small, auditable security baseline for a personal
Arch Linux workstation. It keeps Arch in charge of the machine and gives the
administrator explicit controls instead of running a policy-enforcement
daemon.

The first release intentionally contains only the foundation:

- a default-deny `nftables` host firewall;
- conservative kernel and network hardening through `sysctl`;
- one command for validation, installation, activation, health checks, and
  rollback;
- a Trust No One posture audit covering boot trust, disk encryption, kernel
  integrity, mandatory access control, telemetry, malware tooling, and exposed
  services;
- timestamped backups of every system file it replaces.

It does **not** install desktop applications, themes, containers, virtual
machines, or background agents as part of the security baseline. Optional,
explicit customization is kept separate under the `ice`, `dotfiles`, and
`theme` commands.

## Security model

The baseline assumes a single-user workstation facing hostile networks,
software, services, and potentially physical access. The larger design follows
a [Trust No One architecture](docs/TRUST-NO-ONE.md): boot trust, runtime
confinement, controlled egress, external telemetry, and recovery are independent
layers. Read [the threat model](docs/THREAT-MODEL.md) before deploying it.

The firewall permits conventional DNS only to the IPv4 resolver selected during
installation. `tkoc install` detects the system resolver automatically. If it
cannot, it asks on an interactive terminal; for unattended or explicit setup,
set `TKOC_DNS4`:

```sh
sudo TKOC_DNS4=172.16.2.40 ./bin/tkoc install
```

`TKOC_DNS4` is the address of the DNS resolver (for example a local Pi-hole),
not necessarily this workstation's own address. DNS over HTTPS cannot be
identified reliably by a generic host firewall because it uses ordinary HTTPS.

## Use

Review everything first:

```sh
./bin/tkoc check
less config/nftables.conf
less config/sysctl.d/60-tkoc-hardening.conf
```

On the target Arch system, stage the files and preserve the previous state:

```sh
sudo ./bin/tkoc install
```

Nothing is activated by `install`. Apply the staged policy explicitly:

```sh
sudo tkoc apply
sudo tkoc status
sudo tkoc audit
```

Installation now runs a non-blocking, read-only system assessment before it
stages anything. Run that assessment separately at any time with:

```sh
sudo tkoc doctor
```

`doctor` inventories mounted filesystems, verifies `fstab`, checks live ext4
error counters, searches the last 30 days of the journal for filesystem and
block-I/O warnings, queries drive SMART/NVMe health when `smartmontools` is
installed, and checks whether important PCI devices have kernel drivers bound.
For NVIDIA hardware it also checks the running kernel module's pacman owner,
kernel/userspace version match, signature and taint state, and recent NVIDIA/DRM
errors. Kernel driver and firmware-load failures are searched too; on Manjaro,
installed `mhwd` hardware profiles are reported. `audit` includes the same
assessment.

The assessment never repairs a filesystem, starts a SMART self-test, installs a
package, or changes a driver. Filesystem repair generally requires an unmounted
filesystem, and driver selection can affect boot and graphics availability, so
tkoc reports evidence and recommendations for administrator review.

To suppress common LAN discovery traffic and remove known remote-access tools,
preview and then run the explicit destructive step:

```sh
sudo tkoc gut --dry-run
sudo tkoc gut
sudo tkoc apply
```

`gut` targets TeamViewer, AnyDesk, RustDesk, Tailscale, ZeroTier, common VNC
servers, and network SSH activation. It deliberately preserves DHCP and
`sshd-unix-local.socket`: DHCP is required for dynamic addressing, while that
socket is local AF_UNIX IPC and does not expose TCP/22.

The audit reports missing higher-assurance layers; it does not silently enroll
keys, rewrite disks, install a local TLS authority, or enable irreversible
kernel controls.

## Optional customization (`ice`)

`ice` is the opt-in customization layer. Its package list lives in
`config/ice/packages.conf`, keeping the choices reviewable and easy to extend.
Preview the package set without changing the system, then apply it:

```sh
./bin/tkoc ice --dry-run
sudo ./bin/tkoc ice
```

The command validates package names, skips packages that are already installed,
and asks `pacman` to install only those still missing. It never runs as part of
`check`, `install`, `apply`, or `audit`; `install` only stages the manifest for
later use by the installed `tkoc` command.

## Personal provisioning (opt-in, user-scoped)

`dotfiles` and `theme` are opt-in like `ice`, but unlike every other tkoc
command they run as your normal user and refuse to run under `sudo` or as
root: they only ever touch your own `$HOME`, `$XDG_CONFIG_HOME`, and
`$XDG_STATE_HOME`, never system files. For a broader app inventory, add
packages to `config/ice/packages.conf`; `dotfiles` and `theme` do not install
packages themselves.

### Shell environment (`dotfiles`)

`dotfiles` symlinks a managed shell-snippet directory, an environment-variable
file, and a library of named prompt themes from `config/dotfiles/` into
`$XDG_CONFIG_HOME/tkoc/dotfiles/`, and appends a small guarded block to
`~/.bashrc` that sources those snippets. Re-running it is a no-op once
everything is linked; anything it would replace is backed up first.

```sh
tkoc dotfiles --dry-run
tkoc dotfiles
tkoc dotfiles list-themes
tkoc dotfiles set-theme nord
```

If a hand-written prompt-theme system is still present in `~/.bashrc`,
`dotfiles` offers to migrate it: it always removes the old section, but asks
an explicit `[Y/n]` question at runtime to decide whether to back it up first
(set `TKOC_DOTFILES_BACKUP=yes` or `TKOC_DOTFILES_BACKUP=no` to answer
non-interactively). The theme you had selected is carried over automatically.

### Desktop theme (`theme`)

`theme` applies the KDE Plasma color scheme, icon theme, cursor theme, global
theme ("look and feel"), and fonts, using `plasma-apply-lookandfeel`,
`plasma-apply-colorscheme`, `plasma-apply-cursortheme`, and `kwriteconfig6`.
Settings whose tool isn't installed are skipped, not treated as an error.
Font changes take effect after logging out and back in (or restarting
`plasmashell`); everything else applies immediately to the running session.

Plain `tkoc theme` applies your own hand-edited profile at
`config/theme/kde.conf`. `tkoc theme list`/`tkoc theme set <name>` apply one
of the named presets shipped under `config/theme/presets/` instead
(`breeze-dark`, `breeze-light`, `manjaro`, `nord`, `sweet`).

```sh
tkoc theme --dry-run
tkoc theme
tkoc theme list
tkoc theme set nord
```

### Detailed help

Every command accepts `--help` for a longer description, its exact usage, and
examples:

```sh
tkoc --help
tkoc install --help
tkoc theme --help
```

List recovery points or restore one:

```sh
sudo tkoc backups
sudo tkoc rollback latest
```

Keep a root shell open when applying a firewall remotely. The default policy
does not allow inbound SSH unless you add and validate an explicit rule.

## Development

The test suite performs an isolated installation and rollback without touching
the host:

```sh
./tests/test-tkoc.sh
```

`nft --check` is used automatically when `nft` is installed. On non-Linux
development machines, structural checks still run and the missing native
validator is reported clearly.
