#!/usr/bin/env bash
# tools/vm-host.sh -- the host half of `tkoc vm`: VM services and kernel modules.
#
# vm-net.sh decides whether guests reach the network. This decides whether the
# host can run a guest at all. Off masks and stops every VM daemon, socket and
# helper (installed or not, so a later install stays blocked), then unloads the
# VM kernel modules and blocks them in /etc/modprobe.d. On reverses all of it
# and returns the units to their distro preset. The block file doubles as the
# record that this side is off.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/state.sh
source "$REPO_ROOT/stages/lib/state.sh"

BLOCK_FILE="${TKOC_TEST_ROOT:-}/etc/modprobe.d/tkoc-vm-block.conf"

# Masking a unit that is not installed is harmless: it just stays blocked if
# the package ever arrives.
UNITS=(
  # libvirt (GNOME Boxes, virt-manager)
  virt{qemu,lxc,vbox,xen,ch,vz,interface,network,nodedev,nwfilter,secret,storage,proxy}d{.service,.socket,-ro.socket,-admin.socket}
  virt{lock,log}d{.service,.socket,-admin.socket}
  virtproxyd-{tcp,tls}.socket
  libvirtd{.service,.socket,-ro.socket,-admin.socket,-tcp.socket,-tls.socket}
  libvirt-guests.service virt-guest-shutdown.target
  # QEMU helpers
  qemu-{pr,vmsr}-helper.{service,socket}
  # VirtualBox
  vboxdrv.service vbox{autostart,balloonctrl,web}-service.service
  # VMware Workstation / Player
  vmware.service vmware-USBArbitrator.service vmware-usbarbitrator.service vmware-networks.service
  vmware-workstation-server.service vmware-hostd.service
  # Xen
  xen{stored,consoled,domains,-watchdog,driverdomain}.service xen-init-dom0.service
  xen-qemu-dom0-disk-backend.service proc-xen.mount
  # LXD / Incus (both run full VMs, not only containers)
  lxd.{service,socket} incus.{service,socket} incus-user.{service,socket} incus-startup.service
  # Guest agents: they only act when this machine is itself a guest
  qemu-guest-agent.service vboxservice.service vboxclient.service
  vmtoolsd.service vgauthd.service 'run-vmblock\x2dfuse.mount'
  hyperv{kvp,vss,fcopy}d.service
  spice-vdagentd.{service,socket} spice-webdavd.service
)

# Unload order matters: dependents before the modules they hold.
MODULES=( vboxnetadp vboxnetflt vboxdrv vmnet vmmon vhost_net vhost_vsock vhost_scsi vfio_pci kvm_amd kvm_intel kvm )

# Left alone on purpose: tun, bridge and vsock (VPNs and ordinary networking),
# systemd-machined (containers register there too), and podman/docker, which
# run containers; their VM modes need KVM, which this blocks.

usage() {
  cat <<'HELP'
vm host -- switch the host's VM services and kernel modules off or on

Usage:
  tkoc vm host off      Mask and stop VM services, unload and block VM modules
  tkoc vm host on       Undo that and return the services to their defaults
  tkoc vm host status   Show what is masked, running and loaded

`tkoc vm on|off` runs this together with `tkoc vm net`. Off refuses while a VM
is running. With KVM blocked a guest can still be emulated in software, very
slowly; only removing the packages stops that.
HELP
}

# awk reads lsmod to the end. `grep -q` would exit at the first match, and
# under pipefail lsmod's SIGPIPE would then turn a hit into a miss.
module_loaded() { lsmod | awk -v m="$1" 'NR > 1 && $1 == m { hit = 1 } END { exit !hit }'; }

running_vms() {
  pgrep -a '^(qemu-system-.*|qemu-kvm|VBoxHeadless|VirtualBoxVM|vmware-vmx|cloud-hypervis.*|firecracker)$'
}

# mask/unmask warn once for every name that is not installed, and --quiet does
# not silence it. Covering uninstalled names is deliberate, so drop that one
# warning and pass every other error through, in order.
root_systemctl_quiet() {
  local err rc=0
  err="$(run_root systemctl --quiet "$@" 2>&1 >/dev/null)" || rc=$?
  [[ -z "$err" ]] || grep -v 'does not exist, proceeding anyway\.$' <<<"$err" >&2 || true
  return "$rc"
}

current_state() { [[ -f "$BLOCK_FILE" ]] && printf off || printf on; }

# Fill three associative arrays, named by the caller, with each listed unit's
# file state (absent = not installed and not masked), the running units, and
# the loaded modules. A before/after pair is what the change report diffs.
take_snapshot() {
  local -n _states="$1" _running="$2" _loaded="$3"
  local name state m
  _states=() _running=() _loaded=()
  while read -r name state _; do
    [[ -n "$name" ]] && _states["$name"]="$state"
  done < <(systemctl list-unit-files --no-legend -- "${UNITS[@]}" 2>/dev/null || true)
  while read -r name _; do
    [[ -n "$name" ]] && _running["$name"]=1
  done < <(systemctl list-units --state=active --no-legend --plain -- "${UNITS[@]}" 2>/dev/null || true)
  for m in "${MODULES[@]}"; do
    if module_loaded "$m"; then _loaded["$m"]=1; fi
  done
}

declare -A BEFORE_STATES=() BEFORE_RUNNING=() BEFORE_LOADED=()
declare -A AFTER_STATES=() AFTER_RUNNING=() AFTER_LOADED=()

HOST_CHANGES=0

# virtqemud.socket, virtqemud-ro.socket and virtqemud.service all belong to
# virtqemud; the change report groups them under that name.
unit_group() {
  local u="${1%.*}"
  u="${u%-ro}"; u="${u%-admin}"; u="${u%-tcp}"; u="${u%-tls}"
  printf '%s' "$u"
}

# Masks are bookkeeping, so they are counted: installed units on one line,
# never-installed ones on another. What was actually running and got stopped,
# or started, gets one line per daemon, so every live change is named.
report_unit_changes() {
  local want="$1" u was is ran runs base installed=0 absent=0
  local -A members=()
  local order=()
  for u in "${UNITS[@]}"; do
    was="${BEFORE_STATES[$u]:-}" is="${AFTER_STATES[$u]:-}"
    ran="${BEFORE_RUNNING[$u]:-}" runs="${AFTER_RUNNING[$u]:-}"
    if [[ "$want" == off && "$was" != masked && "$is" == masked ]]; then
      if [[ -z "$was" ]]; then ((absent+=1)); else ((installed+=1)); fi
    elif [[ "$want" == on && "$was" == masked && "$is" != masked ]]; then
      if [[ -z "$is" ]]; then ((absent+=1)); else ((installed+=1)); fi
    fi
    if [[ ( "$want" == off && -n "$ran" && -z "$runs" ) || ( "$want" == on && -z "$ran" && -n "$runs" ) ]]; then
      base="$(unit_group "$u")"
      [[ -n "${members[$base]:-}" ]] || order+=("$base")
      members["$base"]+="$u "
    fi
  done

  local masked_word=masked
  [[ "$want" == on ]] && masked_word=unmasked
  if (( installed > 0 )); then
    tkoc_change "$want" "$installed installed VM units" "$masked_word"
    ((HOST_CHANGES+=1))
  fi
  if (( absent > 0 )); then
    if [[ "$want" == off ]]; then
      tkoc_change off "$absent more VM units" "masked; not installed here, blocked if they ever are"
    else
      tkoc_change on "$absent more VM units" "unmasked; not installed here"
    fi
    ((HOST_CHANGES+=1))
  fi

  local verb=stopped units=() sockets other kinds
  [[ "$want" == on ]] && verb=started
  for base in "${order[@]}"; do
    read -r -a units <<<"${members[$base]}"
    if (( ${#units[@]} == 1 )); then
      tkoc_change "$want" "${units[0]}" "$verb"
    else
      sockets=0 other=0
      for u in "${units[@]}"; do
        if [[ "$u" == *.socket ]]; then ((sockets+=1)); else ((other+=1)); fi
      done
      kinds=""
      (( other == 0 )) || kinds="$other service$( (( other > 1 )) && printf s)"
      (( sockets == 0 )) || kinds="${kinds:+$kinds + }$sockets socket$( (( sockets > 1 )) && printf s)"
      tkoc_change "$want" "$base" "$verb ($kinds)"
    fi
    ((HOST_CHANGES+=1))
  done
}

report_module_changes() {
  local want="$1" m
  for m in "${MODULES[@]}"; do
    if [[ "$want" == off && -n "${BEFORE_LOADED[$m]:-}" && -z "${AFTER_LOADED[$m]:-}" ]]; then
      tkoc_change off "$m" "kernel module unloaded"
    elif [[ "$want" == on && -z "${BEFORE_LOADED[$m]:-}" && -n "${AFTER_LOADED[$m]:-}" ]]; then
      tkoc_change on "$m" "kernel module loaded"
    else
      continue
    fi
    ((HOST_CHANGES+=1))
  done
}

host_status() {
  printf '  host VM services and modules: %s\n' "$(current_state)"
  [[ -z "${TKOC_TEST_ROOT:-}" ]] || return 0
  local masked active=() loaded=() m
  # list-unit-files exits 1 when nothing matches, which pipefail would turn into
  # an abort; no masked units is an answer here, not an error.
  masked="$( { systemctl list-unit-files --no-legend --state=masked -- "${UNITS[@]}" || true; } | wc -l)"
  mapfile -t active < <(systemctl list-units --state=active --no-legend --plain -- "${UNITS[@]}" | awk '{ print $1 }')
  for m in "${MODULES[@]}"; do module_loaded "$m" && loaded+=("$m"); done
  printf '  VM units masked: %s of %s\n' "$masked" "${#UNITS[@]}"
  printf '  VM units running: %s\n' "${#active[@]}"
  printf '  VM kernel modules loaded: %s\n' "${loaded[*]:-none}"
  printf '  /dev/kvm: %s\n' "$([[ -e /dev/kvm ]] && printf present || printf absent)"
  if [[ "$(current_state)" == off ]] && (( ${#active[@]} + ${#loaded[@]} > 0 )); then
    printf '  WARNING: the host side is off but the above is still live; run tkoc vm off\n'
  fi
}

host_off() {
  local vms
  if [[ -z "${TKOC_TEST_ROOT:-}" ]] && vms="$(running_vms)"; then
    printf '%s\n' "$vms" >&2
    die "VMs are still running; shut them down, then run tkoc vm off again"
  fi

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    log "[dry-run] would block VM kernel modules in $BLOCK_FILE, mask and stop ${#UNITS[@]} VM units, and unload the modules"
    return 0
  fi

  tkoc_section "VM services and kernel modules"
  [[ -n "${TKOC_TEST_ROOT:-}" ]] || take_snapshot BEFORE_STATES BEFORE_RUNNING BEFORE_LOADED

  # Write the block before unloading, so nothing can load a module back in
  # between.
  local had_block=no
  [[ -f "$BLOCK_FILE" ]] && had_block=yes
  tkoc_state_capture_file "$BLOCK_FILE"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-vmhost.XXXXXX")"
  {
    printf '# Written by tkoc vm off. Remove with: tkoc vm on\n'
    printf 'install %s /bin/false\n' "${MODULES[@]}"
  } > "$tmp"
  run_root_path "$BLOCK_FILE" install -D -m 0644 -- "$tmp" "$BLOCK_FILE"
  rm -f -- "$tmp"
  if [[ "$had_block" == no ]]; then
    tkoc_change off "module block" "written to $BLOCK_FILE"
    ((HOST_CHANGES+=1))
  fi

  if [[ -n "${TKOC_TEST_ROOT:-}" ]]; then
    tkoc_same "units and modules" "untouched in a test root"
    return 0
  fi

  # A real unit file in /etc is somebody's own; masking would have to delete it.
  local to_mask=() u f
  for u in "${UNITS[@]}"; do
    f="/etc/systemd/system/$u"
    if [[ -e "$f" || -L "$f" ]] && [[ "$(readlink -- "$f")" != /dev/null ]]; then
      tkoc_skipped "$u" "has its own file in /etc/systemd/system; left alone"
    else
      to_mask+=("$u")
    fi
  done
  root_systemctl_quiet mask -- "${to_mask[@]}" || warn "some VM units could not be masked"

  local active=()
  mapfile -t active < <(systemctl list-units --state=active --no-legend --plain -- "${UNITS[@]}" | awk '{ print $1 }')
  (( ${#active[@]} == 0 )) || run_root systemctl stop -- "${active[@]}" || warn "some VM units did not stop"

  # Per-user libvirt and VirtualBox daemons (GNOME Boxes starts one) are plain
  # processes, not units, so stopping units does not reach them.
  local ended
  ended="$(run_root pkill -e '^(virt[a-z]+d|libvirtd|VBoxSVC|VBoxXPCOMIPCD)$' 2>/dev/null || true)"

  local m
  for m in "${MODULES[@]}"; do
    module_loaded "$m" || continue
    run_root modprobe -r -- "$m" || tkoc_skipped "$m" "could not unload; stays loaded until reboot"
  done

  take_snapshot AFTER_STATES AFTER_RUNNING AFTER_LOADED
  report_unit_changes off
  # pkill -e prints "<name> killed (pid <n>)" per process.
  local line
  while read -r line; do
    [[ -n "$line" ]] || continue
    tkoc_change off "${line%% *}" "process ended (${line##*(})"
    ((HOST_CHANGES+=1))
  done <<<"$ended"
  report_module_changes off
  (( HOST_CHANGES > 0 )) || tkoc_same "VM services and kernel modules" "already off"
}

host_on() {
  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    log "[dry-run] would remove $BLOCK_FILE, unmask ${#UNITS[@]} VM units, return them to their presets, and load KVM"
    return 0
  fi

  tkoc_section "VM services and kernel modules"
  [[ -n "${TKOC_TEST_ROOT:-}" ]] || take_snapshot BEFORE_STATES BEFORE_RUNNING BEFORE_LOADED

  tkoc_state_capture_file "$BLOCK_FILE"
  if [[ -e "$BLOCK_FILE" ]]; then
    run_root_path "$BLOCK_FILE" rm -f -- "$BLOCK_FILE"
    tkoc_change on "module block" "removed $BLOCK_FILE"
    ((HOST_CHANGES+=1))
  fi

  if [[ -n "${TKOC_TEST_ROOT:-}" ]]; then
    tkoc_same "units and modules" "untouched in a test root"
    return 0
  fi

  root_systemctl_quiet unmask -- "${UNITS[@]}"

  # Back to the distro's enable/disable defaults, whatever happened in between.
  local presettable=() sockets=()
  mapfile -t presettable < <(systemctl list-unit-files --no-legend --state=enabled,disabled -- "${UNITS[@]}" | awk '{ print $1 }')
  (( ${#presettable[@]} == 0 )) || run_root systemctl --quiet preset -- "${presettable[@]}"

  # libvirt starts on demand through its sockets; VirtualBox needs its driver.
  mapfile -t sockets < <(systemctl list-unit-files --no-legend --type=socket --state=enabled -- "${UNITS[@]}" | awk '{ print $1 }')
  (( ${#sockets[@]} == 0 )) || run_root systemctl start -- "${sockets[@]}"
  if systemctl is-enabled --quiet vboxdrv.service 2>/dev/null; then
    run_root systemctl start vboxdrv.service
  fi

  local kvm=kvm_intel
  grep -q AuthenticAMD /proc/cpuinfo && kvm=kvm_amd
  run_root modprobe -- "$kvm" || tkoc_skipped "$kvm" "could not load; is virtualization enabled in the firmware?"

  take_snapshot AFTER_STATES AFTER_RUNNING AFTER_LOADED
  report_unit_changes on
  report_module_changes on
  (( HOST_CHANGES > 0 )) || tkoc_same "VM services and kernel modules" "already on"
}

main() {
  local sub="${1:-status}"
  (( $# > 0 )) && shift

  while [[ $# -gt 0 ]]; do
    tkoc_parse_safety_flag "$1" || die "vm host: unknown option: $1"
    shift
  done

  case "$sub" in
    on|enable)   host_on ;;
    off|disable) host_off ;;
    status|show) host_status ;;
    help|--help|-h) usage ;;
    *) die "Usage: tkoc vm host [on|off|status]" ;;
  esac
}

main "$@"
