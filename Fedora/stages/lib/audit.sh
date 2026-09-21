#!/usr/bin/env bash
# =============================================================================
#  the_king_of-casual (Fedora edition) — posture audit and hardware assessment
# =============================================================================
# Read-only throughout. Nothing in this file repairs a filesystem, starts a
# SMART self-test, installs a package, changes a driver, or flips an SELinux
# mode. It reports evidence and recommendations; closing a gap is a deliberate
# act by the administrator.

[[ -n "${TKOC_AUDIT_LIB_LOADED:-}" ]] && return 0
TKOC_AUDIT_LIB_LOADED=1

AUDIT_PASS=0
AUDIT_WARN=0
AUDIT_FAIL=0

audit_pass() { AUDIT_PASS=$((AUDIT_PASS + 1)); printf 'PASS  %s\n' "$*"; }
audit_warn() { AUDIT_WARN=$((AUDIT_WARN + 1)); printf 'WARN  %s\n' "$*"; }
audit_fail() { AUDIT_FAIL=$((AUDIT_FAIL + 1)); printf 'FAIL  %s\n' "$*"; }
audit_info() { printf 'INFO  %s\n' "$*"; }
audit_say()  { printf '%s\n' "$*"; }

reset_audit_counts() { AUDIT_PASS=0; AUDIT_WARN=0; AUDIT_FAIL=0; }

show_excerpt() {
  local text="$1" limit="${2:-8}"
  [[ -n "$text" ]] || return 0
  printf '%s\n' "$text" | sed -n "1,${limit}s/^/      /p"
}

_audit_test_root() { printf '%s' "${TKOC_TEST_ROOT:-}"; }

# mapfile is bash 4+. The development machine runs bash 3.2, and this library is
# exercised there by the structural tests, so lines are collected the portable
# way. Usage: audit_read_lines <array-name> < <(producer)
audit_read_lines() {
  local _name="$1" _line _i=0
  eval "$_name=()"
  while IFS= read -r _line; do
    eval "${_name}[\$_i]=\$_line"
    _i=$(( _i + 1 ))
  done
}

# ────────────────────────────────────────────────────────────────
# PLATFORM
# ────────────────────────────────────────────────────────────────

audit_platform_identity() {
  local os_name
  audit_say "Platform assessment"
  if [[ -n "$(_audit_test_root)" ]]; then
    audit_info "platform detection skipped inside the isolated test root"
    return
  fi
  os_name="$(tkoc_os_release PRETTY_NAME || printf 'unknown Linux')"
  if is_fedora; then
    audit_pass "Fedora-family operating system detected: $os_name"
  else
    audit_warn "this does not appear to be a Fedora-family system: $os_name"
  fi
  audit_info "running kernel: $(uname -r)"

  # A kernel update that has not been rebooted into is the single most common
  # reason a freshly built akmod or a patched CVE is not actually in effect.
  if command -v rpm >/dev/null 2>&1; then
    local newest running
    newest="$(rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel 2>/dev/null | sort -V | tail -1 || true)"
    running="$(uname -r)"
    if [[ -n "$newest" && "$running" != "$newest" ]]; then
      audit_warn "the newest installed kernel ($newest) is not the running one ($running); reboot to use it"
    elif [[ -n "$newest" ]]; then
      audit_pass "running the newest installed kernel: $running"
    fi
  fi
}

# ────────────────────────────────────────────────────────────────
# FILESYSTEMS
# ────────────────────────────────────────────────────────────────

# Fedora Workstation installs to Btrfs by default, so a health check that only
# reads /sys/fs/ext4 reports nothing at all on a stock system. Both are checked.
audit_btrfs_health() {
  local mountpoint stats errors scrub
  local -a btrfs_mounts=()
  command -v btrfs >/dev/null 2>&1 || return 0
  audit_read_lines btrfs_mounts < <(findmnt -rn -t btrfs -o TARGET 2>/dev/null | awk '!seen[$0]++')
  (( ${#btrfs_mounts[@]} > 0 )) || return 0

  for mountpoint in "${btrfs_mounts[@]}"; do
    stats="$(btrfs device stats "$mountpoint" 2>/dev/null || true)"
    if [[ -z "$stats" ]]; then
      audit_warn "btrfs device stats for $mountpoint are unavailable; run tkoc doctor as root"
      continue
    fi
    # Every counter reads "...device_name.write_io_errs    0" when healthy.
    errors="$(printf '%s\n' "$stats" | awk '($NF + 0) > 0 { print }')"
    if [[ -z "$errors" ]]; then
      audit_pass "btrfs on $mountpoint reports zero device errors"
    else
      audit_fail "btrfs on $mountpoint reports non-zero device error counters"
      show_excerpt "$errors" 8
      audit_info "investigate before writing more data; 'btrfs device stats -z' only resets the counter"
    fi

    scrub="$(btrfs scrub status "$mountpoint" 2>/dev/null || true)"
    if grep -Eqi 'no stats available|never' <<<"$scrub"; then
      audit_warn "btrfs on $mountpoint has never been scrubbed; consider enabling btrfs-scrub@.timer"
    elif grep -Eqi 'Error summary:[[:space:]]*no errors' <<<"$scrub"; then
      audit_pass "the last btrfs scrub of $mountpoint found no errors"
    elif [[ -n "$scrub" ]]; then
      audit_warn "the last btrfs scrub of $mountpoint reported errors"
      show_excerpt "$scrub" 6
    fi
  done
}

audit_filesystem_health() {
  local source fstype target verification findings count ext4_dir ext4_errors ext4_name
  local -a filesystem_findings=()

  audit_say "Filesystem assessment"
  if [[ -n "$(_audit_test_root)" ]]; then
    audit_warn "filesystem assessment unavailable inside the isolated test root"
    return
  fi

  if command -v findmnt >/dev/null 2>&1; then
    while read -r source fstype target; do
      case "$fstype" in
        ext2|ext3|ext4|btrfs|xfs|f2fs|vfat|exfat|ntfs|ntfs3)
          audit_info "$source on $target uses $fstype"
          ;;
      esac
    done < <(findmnt -rn -o SOURCE,FSTYPE,TARGET)

    if verification="$(findmnt --verify --verbose 2>&1)"; then
      audit_pass "fstab sources, targets, types, and options passed findmnt verification"
    else
      audit_warn "fstab verification reported a problem"
      show_excerpt "$verification"
    fi
  else
    audit_warn "findmnt is unavailable; install util-linux to inventory filesystems"
  fi

  for ext4_dir in /sys/fs/ext4/*; do
    [[ -r "$ext4_dir/errors_count" ]] || continue
    ext4_name="${ext4_dir##*/}"
    ext4_errors="$(<"$ext4_dir/errors_count")"
    if [[ "$ext4_errors" =~ ^[0-9]+$ ]] && (( ext4_errors == 0 )); then
      audit_pass "mounted ext4 device $ext4_name reports zero kernel errors"
    else
      audit_fail "mounted ext4 device $ext4_name reports ${ext4_errors:-unknown} kernel error(s)"
    fi
  done

  audit_btrfs_health

  if ! command -v journalctl >/dev/null 2>&1; then
    audit_warn "journalctl is unavailable; filesystem errors could not be searched"
    return
  fi

  audit_read_lines filesystem_findings < <(
    journalctl --no-pager --all --since '30 days ago' 2>/dev/null \
      | grep -Ei \
        'Dirty bit is set|not properly unmounted|journal.*(corrupt|uncleanly shut down)|Buffer I/O error|blk_update_request|critical medium error|EXT[234]-fs.*(error|warning)|BTRFS.*(error|corrupt|checksum)|XFS.*(error|corrupt)|F2FS-fs.*error|exFAT-fs.*(error|corrupt)|NTFS.*(error|corrupt)|Remounting filesystem read-only' \
      | awk '!seen[$0]++' || true
  )
  count="${#filesystem_findings[@]}"
  if (( count == 0 )); then
    audit_pass "no filesystem corruption or block-I/O warnings found in the last 30 days"
  else
    audit_warn "$count filesystem or unclean-shutdown warning(s) found in the last 30 days"
    findings="$(printf '%s\n' "${filesystem_findings[@]}")"
    show_excerpt "$findings" 10
    (( count <= 10 )) || audit_info "$((count - 10)) additional warning(s) omitted"
    audit_info "do not run a repairing fsck against a mounted filesystem"
  fi
}

# ────────────────────────────────────────────────────────────────
# STORAGE
# ────────────────────────────────────────────────────────────────

audit_storage_health() {
  local disk output status
  local -a disks=()

  audit_say "Storage-device assessment"
  if [[ -n "$(_audit_test_root)" ]]; then
    audit_warn "storage-device assessment unavailable inside the isolated test root"
    return
  fi
  if ! command -v lsblk >/dev/null 2>&1; then
    audit_warn "lsblk is unavailable; block devices could not be inventoried"
    return
  fi

  audit_read_lines disks < <(lsblk -dn -o NAME,TYPE | awk '$2 == "disk" { print "/dev/" $1 }')
  if (( ${#disks[@]} == 0 )); then
    audit_warn "no physical block devices were found"
    return
  fi

  while read -r disk; do
    [[ -n "$disk" ]] && audit_info "$disk"
  done < <(lsblk -dn -o NAME,TRAN,SIZE,MODEL \
    | awk '{ name=$1; $1=""; sub(/^[[:space:]]+/, ""); print "/dev/" name " " $0 }')

  if ! command -v smartctl >/dev/null 2>&1; then
    audit_warn "SMART health was not checked; install it with: sudo dnf install smartmontools"
    command -v nvme >/dev/null 2>&1 \
      || audit_info "sudo dnf install nvme-cli adds further NVMe diagnostics"
    return
  fi

  for disk in "${disks[@]}"; do
    status=0
    output="$(smartctl -H -A -n standby "$disk" 2>&1)" || status=$?
    if grep -Eiq 'device is in (STANDBY|SLEEP) mode' <<<"$output"; then
      audit_info "$disk is asleep; SMART query did not wake it"
    elif grep -Eiq 'overall-health.*(FAILED|FAILING)|SMART Health Status:[[:space:]]*(FAILED|BAD)|Critical Warning:[[:space:]]+0x0*[1-9a-f]' <<<"$output"; then
      audit_fail "$disk reports failing SMART/NVMe health"
      show_excerpt "$(printf '%s\n' "$output" | grep -Ei 'overall-health|SMART Health Status|Critical Warning|Media and Data Integrity Errors|Error Information Log Entries' || true)"
    elif grep -Eiq 'overall-health.*PASSED|SMART Health Status:[[:space:]]*OK|Critical Warning:[[:space:]]+0x0+$' <<<"$output"; then
      audit_pass "$disk reports healthy SMART/NVMe status"
      if printf '%s\n' "$output" | awk '
        /Current_Pending_Sector|Offline_Uncorrectable/ && ($NF + 0) > 0 { bad=1 }
        /Media and Data Integrity Errors:/ {
            value=$NF; gsub(/,/, "", value); if ((value + 0) > 0) bad=1
        }
        END { exit !bad }
      '; then
        audit_warn "$disk has non-zero pending, uncorrectable, or media-error counters"
      fi
    elif grep -Eiq 'Permission denied|Operation not permitted' <<<"$output"; then
      audit_warn "$disk SMART data is inaccessible; run tkoc doctor as root"
    elif (( status != 0 )); then
      audit_warn "$disk did not provide a conclusive SMART health result"
      show_excerpt "$output" 4
    else
      audit_warn "$disk supports smartctl but returned no recognizable health verdict"
    fi
  done
}

# ────────────────────────────────────────────────────────────────
# DRIVERS
# ────────────────────────────────────────────────────────────────

audit_pci_driver_bindings() {
  local description driver modules count=0

  audit_say "Kernel-driver assessment"
  if [[ -n "$(_audit_test_root)" ]]; then
    audit_warn "driver assessment unavailable inside the isolated test root"
    return
  fi
  if ! command -v lspci >/dev/null 2>&1; then
    audit_warn "PCI drivers were not checked; install it with: sudo dnf install pciutils"
    return
  fi

  while IFS='|' read -r description driver modules; do
    case "$description" in
      *"VGA compatible controller"*|*"3D controller"*|*"Display controller"*|\
      *"Ethernet controller"*|*"Network controller"*|\
      *"Non-Volatile memory controller"*|*"SATA controller"*|\
      *"RAID bus controller"*|*"Mass storage controller"*|\
      *"Audio device"*|*"USB controller"*) ;;
      *) continue ;;
    esac
    count=$((count + 1))
    if [[ "$driver" == vfio-pci ]]; then
      audit_warn "vfio-pci owns $description (expected only for intentional device passthrough)"
    elif [[ -n "$driver" ]]; then
      audit_pass "$driver is bound to $description"
    elif [[ -n "$modules" ]]; then
      audit_warn "no active driver is bound to $description; candidate module(s): $modules"
    else
      audit_fail "no kernel driver or candidate module was found for $description"
    fi
  done < <(lspci -Dnnk | awk '
    function emit() {
        if (description != "") print description "|" driver "|" modules
    }
    /^[[:xdigit:]]{4}:/ {
        emit(); description=$0; driver=""; modules=""; next
    }
    /^[[:space:]]+Kernel driver in use:/ {
        driver=$0; sub(/^[^:]+:[[:space:]]*/, "", driver); next
    }
    /^[[:space:]]+Kernel modules:/ {
        modules=$0; sub(/^[^:]+:[[:space:]]*/, "", modules); next
    }
    END { emit() }
  ')
  (( count > 0 )) \
    || audit_warn "lspci found no display, network, storage, audio, or USB controllers"
}

# NVIDIA on Fedora is akmod-based: the module is rebuilt locally against each
# new kernel, and under Secure Boot that locally built module must be signed
# with an enrolled MOK or it will not load. Those are the two failure modes
# that actually strand a Fedora desktop, and neither exists on Arch.
audit_nvidia_stack() {
  local module_path module_package module_version user_version signer taints
  local nvidia_output nvidia_status=0 findings
  local -a graphics_findings=()

  if ! modinfo nvidia >/dev/null 2>&1; then
    audit_fail "NVIDIA hardware is present but the nvidia kernel module is unavailable"
    audit_info "Fedora installs it from RPM Fusion: akmod-nvidia plus xorg-x11-drv-nvidia-cuda"
    if command -v akmods >/dev/null 2>&1; then
      audit_info "an akmod build may still be pending; check: sudo akmods --force && sudo dracut --force"
    fi
    return
  fi

  module_path="$(modinfo -n nvidia 2>/dev/null || true)"
  module_package="$(rpm -qf "$module_path" 2>/dev/null || true)"
  module_version="$(modinfo -F version nvidia 2>/dev/null || true)"
  if [[ -n "$module_package" && "$module_package" != *"not owned"* ]]; then
    audit_pass "the NVIDIA module for $(uname -r) is owned by $module_package"
  else
    audit_warn "no rpm owns the NVIDIA module used by $(uname -r): $module_path"
    audit_info "an akmod-built module is normally owned by kmod-nvidia-$(uname -r)"
  fi

  if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia_output="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>&1)" \
      || nvidia_status=$?
    user_version="$(printf '%s\n' "$nvidia_output" | sed -n '1p' | tr -d '[:space:]')"
    if (( nvidia_status != 0 )) || [[ -z "$user_version" ]]; then
      audit_fail "nvidia-smi cannot communicate with the NVIDIA driver"
      show_excerpt "$nvidia_output" 3
    elif [[ "$user_version" == "$module_version" ]]; then
      audit_pass "NVIDIA kernel and userspace versions match: $module_version"
    else
      audit_fail "NVIDIA version mismatch: kernel=$module_version userspace=${user_version:-unavailable}"
      audit_info "on Fedora this usually means a dnf upgrade replaced the userspace half; reboot after the akmod rebuilds"
    fi
  else
    audit_warn "nvidia-smi is unavailable; install xorg-x11-drv-nvidia-cuda"
  fi

  signer="$(modinfo -F signer nvidia 2>/dev/null || true)"
  if [[ -n "$signer" ]]; then
    audit_pass "the NVIDIA kernel module is signed by $signer"
  elif command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    audit_fail "Secure Boot is on but the NVIDIA module is unsigned; it will not load"
    audit_info "enroll a MOK and sign it: sudo kmodgenca && sudo mokutil --import /etc/pki/akmods/certs/public_key.der"
  else
    audit_warn "the NVIDIA kernel module is unsigned (Secure Boot is off, so it still loads)"
  fi

  taints="$(cat /sys/module/nvidia/taint 2>/dev/null || true)"
  [[ -z "$taints" ]] \
    || audit_warn "the loaded NVIDIA module carries kernel taint flag(s): $taints"

  if command -v journalctl >/dev/null 2>&1; then
    audit_read_lines graphics_findings < <(
      journalctl --no-pager --all --since '30 days ago' _TRANSPORT=kernel 2>/dev/null \
        | grep -Ei 'NVRM:.*Xid|nvidia.*failed|WARNING:.*drm_modeset|nv_drm.*failed|GPU has fallen off the bus' \
        | grep -Eiv 'module verification failed' \
        | awk '!seen[$0]++' || true
    )
    if (( ${#graphics_findings[@]} == 0 )); then
      audit_pass "no NVIDIA Xid, DRM warning, or GPU-failure messages found in the last 30 days"
    else
      audit_warn "${#graphics_findings[@]} NVIDIA/DRM warning(s) found in the last 30 days"
      findings="$(printf '%s\n' "${graphics_findings[@]}")"
      show_excerpt "$findings" 8
    fi
  fi
}

audit_graphics_driver_stack() {
  local gpu_info known_gpu=0

  [[ -z "$(_audit_test_root)" ]] || return 0
  command -v lspci >/dev/null 2>&1 || return 0
  gpu_info="$(lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"
  [[ -n "$gpu_info" ]] || return 0

  if grep -Fqi NVIDIA <<<"$gpu_info"; then
    known_gpu=1
    audit_info "NVIDIA GPU detected: $(printf '%s\n' "$gpu_info" | grep -Fi NVIDIA | sed -n '1p')"
    audit_nvidia_stack
  fi

  # Fedora ships one Mesa Vulkan package covering both AMD and Intel, unlike
  # Arch's split vulkan-radeon / vulkan-intel.
  if grep -Eqi '(^|[^[:alnum:]_])(AMD|ATI)([^[:alnum:]_]|$)' <<<"$gpu_info"; then
    known_gpu=1
    rpm_installed mesa-dri-drivers \
      && audit_pass "mesa-dri-drivers is installed for the AMD graphics stack" \
      || audit_warn "install mesa-dri-drivers for AMD OpenGL support"
    rpm_installed mesa-vulkan-drivers \
      && audit_pass "mesa-vulkan-drivers is installed" \
      || audit_warn "install mesa-vulkan-drivers if Vulkan support is needed"
  fi

  if grep -Fqi Intel <<<"$gpu_info"; then
    known_gpu=1
    rpm_installed mesa-dri-drivers \
      && audit_pass "mesa-dri-drivers is installed for the Intel graphics stack" \
      || audit_warn "install mesa-dri-drivers for Intel OpenGL support"
    rpm_installed mesa-vulkan-drivers \
      && audit_pass "mesa-vulkan-drivers is installed" \
      || audit_warn "install mesa-vulkan-drivers if Vulkan support is needed"
  fi

  if (( known_gpu == 0 )); then
    audit_warn "graphics hardware was found but its userspace driver recommendation is unknown"
    show_excerpt "$gpu_info" 4
  fi

  rpm_installed linux-firmware \
    && audit_pass "linux-firmware is installed" \
    || audit_warn "install linux-firmware for common hardware firmware"
}

audit_driver_load_errors() {
  local findings
  local -a driver_findings=()

  [[ -z "$(_audit_test_root)" ]] || return 0
  if ! command -v journalctl >/dev/null 2>&1; then
    audit_warn "journalctl is unavailable; driver and firmware load errors were not searched"
    return
  fi

  audit_read_lines driver_findings < <(
    journalctl --no-pager --all --since '30 days ago' _TRANSPORT=kernel 2>/dev/null \
      | grep -Ei 'Direct firmware load for .* failed|firmware: failed to load|failed to load firmware|no suitable firmware|Unknown symbol|probe with driver .* failed' \
      | awk '!seen[$0]++' || true
  )
  if (( ${#driver_findings[@]} == 0 )); then
    audit_pass "no kernel driver or firmware-load failures found in the last 30 days"
  else
    audit_warn "${#driver_findings[@]} driver or firmware-load failure(s) found in the last 30 days"
    findings="$(printf '%s\n' "${driver_findings[@]}")"
    show_excerpt "$findings" 8
  fi
}

# fwupd is Fedora's firmware-update path and takes the place of Manjaro's mhwd
# hardware-profile report. Pending firmware updates are reported, never applied:
# a firmware flash is not something a posture audit should initiate.
audit_firmware_updates() {
  local devices updates

  [[ -z "$(_audit_test_root)" ]] || return 0
  if ! command -v fwupdmgr >/dev/null 2>&1; then
    audit_info "fwupdmgr is unavailable; install it with: sudo dnf install fwupd"
    return
  fi

  devices="$(fwupdmgr get-devices --no-unreported-check 2>/dev/null | grep -c 'Device ID' || true)"
  [[ "$devices" =~ ^[0-9]+$ ]] && (( devices > 0 )) \
    && audit_info "fwupd sees $devices updatable firmware device(s)"

  updates="$(fwupdmgr get-updates --no-unreported-check 2>&1 || true)"
  if grep -Eqi 'No updates available|No releases found|Devices with no available firmware updates' <<<"$updates"; then
    audit_pass "no pending firmware updates were reported by fwupd"
  elif grep -Eqi 'Upgrades? available|→' <<<"$updates"; then
    audit_warn "fwupd reports pending firmware updates; review with: fwupdmgr get-updates"
  fi
}

run_system_health_assessment() {
  audit_platform_identity
  audit_say ""
  audit_filesystem_health
  audit_say ""
  audit_storage_health
  audit_say ""
  audit_pci_driver_bindings
  audit_graphics_driver_stack
  audit_driver_load_errors
  audit_firmware_updates
}

# ────────────────────────────────────────────────────────────────
# SECURITY POSTURE
# ────────────────────────────────────────────────────────────────

audit_secure_boot() {
  local variable value

  # mokutil is the Fedora-idiomatic reading and also covers the Shim path that
  # akmod module signing depends on. The efivar read stays as a fallback for
  # systems where mokutil is not installed.
  if command -v mokutil >/dev/null 2>&1; then
    value="$(mokutil --sb-state 2>/dev/null || true)"
    if grep -qi 'SecureBoot enabled' <<<"$value"; then
      audit_pass "Secure Boot is enabled"
      return
    elif grep -qi 'SecureBoot disabled' <<<"$value"; then
      audit_warn "Secure Boot is not enabled"
      return
    fi
  fi

  variable="$(find /sys/firmware/efi/efivars -maxdepth 1 \
    -name 'SecureBoot-*' -print -quit 2>/dev/null || true)"
  if [[ -z "$variable" ]]; then
    audit_warn "Secure Boot state is unavailable (legacy boot or unsupported firmware)"
    return
  fi

  value="$(od -An -t u1 "$variable" 2>/dev/null \
    | awk '{ for (i = 1; i <= NF; i++) value=$i } END { print value }')"
  if [[ "$value" == 1 ]]; then
    audit_pass "Secure Boot is enabled"
  else
    audit_warn "Secure Boot is not enabled"
  fi
}

audit_root_encryption() {
  local root_source
  root_source="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
  # Btrfs reports the source as /dev/mapper/x[/subvol]; strip the subvolume.
  root_source="${root_source%%\[*}"
  if [[ -n "$root_source" ]] \
    && lsblk -s -n -o TYPE "$root_source" 2>/dev/null | grep -Fxq crypt; then
    audit_pass "the root filesystem is backed by a LUKS/dm-crypt device"
  else
    audit_warn "encrypted root could not be verified"
  fi
}

audit_kernel_lockdown() {
  local state
  if [[ ! -r /sys/kernel/security/lockdown ]]; then
    audit_warn "kernel lockdown state is unavailable"
    return
  fi
  state="$(< /sys/kernel/security/lockdown)"
  if [[ "$state" == *'[integrity]'* || "$state" == *'[confidentiality]'* ]]; then
    audit_pass "kernel lockdown is enforced: $state"
  else
    audit_warn "kernel lockdown is not enforced: $state"
    audit_info "on Fedora, lockdown engages automatically when Secure Boot is on"
  fi
}

# SELinux is the expected mandatory access control on Fedora; AppArmor is kept
# as a fallback branch for derivatives that ship it instead. This audit reports
# the mode and never changes it: switching SELinux to enforcing on a system that
# has been running permissive can make it unbootable without a relabel.
audit_mac() {
  local modules="" mode
  [[ -r /sys/kernel/security/lsm ]] && modules="$(< /sys/kernel/security/lsm)"

  if [[ ",$modules," == *,selinux,* ]] || command -v getenforce >/dev/null 2>&1; then
    mode="$(getenforce 2>/dev/null || printf unknown)"
    case "$mode" in
      Enforcing)  audit_pass "SELinux is enforcing" ;;
      Permissive) audit_warn "SELinux is permissive; policy violations are logged, not blocked"
                  audit_info "review denials first (ausearch -m AVC -ts recent), then set enforcing deliberately" ;;
      Disabled)   audit_fail "SELinux is disabled on a Fedora system"
                  audit_info "re-enabling needs a full filesystem relabel; plan it, do not flip it live" ;;
      *)          audit_warn "SELinux mode could not be determined" ;;
    esac
    return
  fi

  if [[ ",$modules," == *,apparmor,* ]]; then
    if command -v aa-enabled >/dev/null 2>&1 && aa-enabled >/dev/null 2>&1; then
      audit_pass "AppArmor is active"
    else
      audit_warn "AppArmor LSM is present but userspace enforcement was not verified"
    fi
    return
  fi

  audit_warn "no SELinux or AppArmor mandatory-access-control LSM is active"
}

audit_sysctl_policy() {
  local file="$1" key expected actual mismatches=0 checked=0
  [[ -r "$file" ]] || { audit_warn "managed sysctl policy is not installed: $file"; return; }
  while IFS=$'\t' read -r key expected; do
    checked=$((checked + 1))
    actual="$(sysctl -n "$key" 2>/dev/null || true)"
    if [[ "$actual" != "$expected" ]]; then
      mismatches=$((mismatches + 1))
      printf '      %s expected=%s actual=%s\n' "$key" "$expected" "${actual:-unavailable}"
    fi
  done < <(awk -F= '/^[[:space:]]*[A-Za-z0-9_.]+[[:space:]]*=/ {
      key=$1; value=$2
      gsub(/[[:space:]]/, "", key)
      sub(/^[[:space:]]+/, "", value); sub(/[[:space:]]+$/, "", value)
      printf "%s\t%s\n", key, value
  }' "$file")

  if (( checked == 0 )); then
    audit_warn "the managed sysctl policy contains no assignments to verify"
  elif (( mismatches == 0 )); then
    audit_pass "all $checked managed sysctl values match policy"
  else
    audit_fail "$mismatches of $checked managed sysctl values differ from policy"
  fi
}

audit_cpu_mitigations() {
  local report
  if [[ ! -d /sys/devices/system/cpu/vulnerabilities ]]; then
    audit_warn "CPU vulnerability reports are unavailable"
    return
  fi
  report="$(grep -H -E 'Vulnerable|SMT vulnerable' \
    /sys/devices/system/cpu/vulnerabilities/* 2>/dev/null || true)"
  if [[ -n "$report" ]]; then
    audit_warn "one or more CPU vulnerability reports require review"
    printf '%s\n' "$report" | sed 's/^/      /'
  else
    audit_pass "kernel reports no unmitigated CPU vulnerability state"
  fi
}

audit_listeners() {
  local count
  if ! command -v ss >/dev/null 2>&1; then
    audit_warn "ss is unavailable; listening sockets were not inspected"
    return
  fi
  count="$(ss -H -lntu 2>/dev/null | wc -l)"
  count="${count//[[:space:]]/}"
  if [[ "$count" == 0 ]]; then
    audit_pass "no TCP or UDP listening sockets were found"
  else
    audit_warn "$count TCP/UDP listening sockets require owner review (run: ss -lntup)"
  fi
}

audit_remote_access() {
  local package unit found=0

  if command -v rpm >/dev/null 2>&1; then
    while read -r package; do
      if rpm_installed "$package"; then
        audit_warn "remote-access package is installed: $package"
        found=1
      fi
    done < <(tkoc_remote_access_packages)
  fi
  if command -v systemctl >/dev/null 2>&1; then
    while read -r unit; do
      # Template units ("vncserver@.service") cannot be active themselves.
      [[ "$unit" == *@.service ]] && continue
      if unit_active "$unit" || unit_enabled "$unit"; then
        audit_warn "remote-access unit is enabled or active: $unit"
        found=1
      fi
    done < <(tkoc_remote_access_units)
  fi
  # sshd-unix-local.socket is generated by systemd-ssh-generator and listens on
  # an AF_UNIX path under /run, not on TCP/22. It lets you `ssh` to this machine
  # from this machine; nothing off-host can reach it. It shows up as "active
  # listening" in systemctl and looks alarming, so say what it is rather than
  # leaving the operator to work it out. The Arch edition called this out
  # explicitly and it belongs here too.
  if command -v systemctl >/dev/null 2>&1 \
    && systemctl list-unit-files sshd-unix-local.socket --no-legend 2>/dev/null \
      | grep -q '^sshd-unix-local\.socket'; then
    audit_pass "sshd-unix-local.socket is local AF_UNIX activation, not a TCP/22 listener"
  fi

  (( found != 0 )) || audit_pass "no known remote-access packages or active services were detected"
}

audit_firewall_state() {
  if ! command -v nft >/dev/null 2>&1; then
    audit_fail "nft is not installed; there is no tkoc firewall policy to verify"
    return
  fi
  if nft list table inet tkoc_host >/dev/null 2>&1; then
    audit_pass "tkoc_host firewall table is loaded"
  else
    audit_fail "tkoc_host firewall table is not loaded"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    if unit_enabled nftables.service; then
      audit_pass "nftables.service is enabled, so the policy is restored at boot"
    else
      audit_fail "nftables.service is not enabled; the policy will not survive a reboot"
    fi

    # firewalld competing for the ruleset is the Fedora-specific failure that
    # silently undoes this policy, so it is a FAIL rather than a note.
    if unit_active firewalld.service; then
      audit_fail "firewalld is running and also manages nftables; the tkoc policy may be overwritten"
    else
      audit_pass "firewalld is not running, so nothing competes for the nftables ruleset"
    fi
  fi
}

audit_telemetry_tooling() {
  if command -v clamscan >/dev/null 2>&1; then
    audit_pass "ClamAV tooling is installed"
  else
    audit_warn "no malware scanner was detected"
  fi

  if command -v systemctl >/dev/null 2>&1 \
    && unit_enabled auditd.service && unit_active auditd.service; then
    audit_pass "auditd is enabled and active"
  else
    audit_warn "auditd is not both enabled and active"
  fi

  if [[ -r /proc/cmdline ]] && grep -qw 'audit=1' /proc/cmdline; then
    audit_pass "early-boot kernel auditing is enabled"
  else
    audit_warn "kernel command line does not contain audit=1"
  fi

  if command -v dmsetup >/dev/null 2>&1 \
    && dmsetup status --target verity 2>/dev/null | grep -q .; then
    audit_pass "an active dm-verity integrity target was detected"
  else
    audit_warn "dm-verity root integrity was not detected"
  fi
}

audit_boot_trust() {
  audit_secure_boot
  audit_root_encryption

  if [[ -e /sys/class/tpm/tpm0 ]]; then
    audit_pass "TPM device is available"
  else
    audit_warn "no TPM device was detected"
  fi

  # Fedora boots through GRUB with a shim by default; a measured UKI is an
  # opt-in setup (systemd-boot or a UKI-producing kernel-install plugin).
  if command -v bootctl >/dev/null 2>&1 \
    && LC_ALL=C bootctl status 2>/dev/null | grep -Eq 'Measured UKI:[[:space:]]+yes'; then
    audit_pass "a measured unified kernel image was reported"
  else
    audit_warn "a measured unified kernel image was not verified"
    audit_info "Fedora's default GRUB+shim path does not produce one; this is expected unless you set up a UKI"
  fi

  audit_kernel_lockdown

  if [[ -r /sys/module/module/parameters/sig_enforce ]] \
    && grep -Eq '^(Y|1)$' /sys/module/module/parameters/sig_enforce; then
    audit_pass "kernel module signature enforcement is active"
  else
    audit_warn "kernel module signature enforcement was not verified"
  fi
}

# The full posture audit. "$1" is the installed sysctl policy to compare the
# live kernel against.
run_posture_audit() {
  local live_sysctl="${1:-/etc/sysctl.d/60-tkoc-hardening.conf}"

  audit_say "Trust No One posture audit"
  audit_say ""

  audit_firewall_state
  audit_sysctl_policy "$live_sysctl"
  audit_boot_trust
  audit_mac
  audit_telemetry_tooling
  audit_cpu_mitigations
  audit_listeners
  audit_remote_access
  audit_warn "DoH inside HTTPS is not distinguishable without a controlled proxy or destination policy"
}
