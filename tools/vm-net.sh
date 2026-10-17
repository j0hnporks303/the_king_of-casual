#!/usr/bin/env bash
# tools/vm-net.sh -- let VM and container guests reach the internet, or not.
#
# The forward chain in config/firewall/tkoc.nft carries a marked block that
# blocks guest bridges before conntrack's established accept when off, and
# permits forwarding when on. VirtualBox's NAT runs in a host process, so its
# virtual cables are toggled separately through VBoxManage.
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
# shellcheck source=../stages/lib/common.sh
source "$REPO_ROOT/stages/lib/common.sh"
# shellcheck source=../stages/lib/state.sh
source "$REPO_ROOT/stages/lib/state.sh"

LIVE_NFT="${TKOC_TEST_ROOT:-}/etc/nftables/tkoc.nft"
BEGIN_MARKER='# TKOC_VM_NET_BEGIN'
END_MARKER='# TKOC_VM_NET_END'

usage() {
  cat <<'HELP'
vm net -- toggle guest network passthrough in the installed firewall policy

Usage:
  tkoc vm net on       Let VM/container guests reach the internet
  tkoc vm net off      Block guest-originated forwarding
  tkoc vm net status   Show the current state

Covers virbr* (libvirt), docker*, podman*, cni-podman*, incusbr*, vboxnet* and
br-* interfaces. The toggle edits the marked block in /etc/nftables/tkoc.nft and
reloads, so it survives a reboot. Re-applying a firewall tier resets it to off.
Registered VirtualBox adapters are disconnected when off and restored to their
previous cable state when on. New VMs must be checked after creation. A VM
whose folder was deleted cannot be managed, so off removes its stale entry; one
on a drive that is not plugged in is left registered and reported.
User-mode QEMU/SLIRP and passt use the host output path and are not covered.
HELP
}

# POLICY_BODY is filled here and reused, so the file is read once and through
# the privileged reader -- /etc/nftables is root-only on Fedora.
POLICY_BODY=""
require_policy() {
  local prompting="${1:-quiet}"
  if [[ "$prompting" == prompting ]]; then
    POLICY_BODY="$(read_root_file "$LIVE_NFT" 2>/dev/null)" || POLICY_BODY=""
  else
    POLICY_BODY="$(read_root_file_quiet "$LIVE_NFT" 2>/dev/null)" || POLICY_BODY=""
  fi
  if [[ -z "$POLICY_BODY" ]]; then
    if root_path_exists "$LIVE_NFT"; then
      die "the firewall policy at $LIVE_NFT needs privilege to read (try: sudo \"\$(command -v tkoc)\" vm net status)"
    fi
    die "no firewall policy is installed at $LIVE_NFT (run: tkoc firewall strong)"
  fi
  grep -Fq "$BEGIN_MARKER" <<<"$POLICY_BODY" \
    || die "the installed policy has no VM block; re-apply a tier to refresh it"
}

require_guard() {
  grep -Fq '# TKOC_VM_GUARD' <<<"$POLICY_BODY" \
    || die "the installed VM policy predates the established-flow guard; re-apply the firewall tier, then retry"
}

# "on" when at least one accept inside the block is live (not commented).
current_state() {
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
    index($0, b) { inside = 1; next }
    index($0, e) { inside = 0; next }
    inside && /^[[:space:]]+iifname.*accept[[:space:]]*$/ { live = 1 }
    END { print (live ? "on" : "off") }
  ' <<<"$POLICY_BODY"
}

# VirtualBox NAT does not pass through the host forward chain. Keep the saved
# adapter state with the VM so the user's existing disconnected adapters stay
# disconnected when the toggle returns to on. VBoxManage must run as the VM's
# owner, even when the firewall part of this command is run through sudo.
vbox_manage() {
  if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != root ]]; then
    sudo -u "$SUDO_USER" -H VBoxManage "$@"
  else
    VBoxManage "$@"
  fi
}

vbox_vms() {
  local listing line
  listing="$(vbox_manage list vms)" || die "could not list VirtualBox VMs"
  while IFS= read -r line; do
    [[ "$line" =~ \{([[:xdigit:]-]{36})\}$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done <<<"$listing"
}

# A registered VM whose files cannot be opened cannot have its cables managed.
# Usually its folder was deleted and VirtualBox still lists it; sometimes it
# lives on a drive that is not plugged in. Only the first is safe to clean up:
#
#   gone     its VM folder is missing but the folder that held it is present,
#            so the files were deleted -- the entry points at nothing
#   offline  the location itself is missing (an unmounted drive, most often),
#            so the VM may well come back -- leave it registered
#   unknown  anything else: files present but unreadable, or no path at all
vbox_config_file() {
  vbox_manage list vms --long 2>/dev/null | awk -v u="$1" '
    $1 == "UUID:" { found = ($2 == u) }
    found && /^Config file:/ { sub(/^Config file:[[:space:]]*/, ""); print; exit }' || true
}

vbox_inaccessible_kind() {
  local config="$1" vm_dir
  [[ -n "$config" && ! -e "$config" ]] || { printf unknown; return; }
  vm_dir="$(dirname -- "$config")"
  if [[ ! -e "$vm_dir" && -d "$(dirname -- "$vm_dir")" ]]; then
    printf gone
  elif [[ ! -e "$vm_dir" ]]; then
    printf offline
  else
    printf unknown
  fi
}

# Registrations are per-user: run from a root shell, VBoxManage looks at root's
# list and reports the VM as not found. vbox_manage already runs as the owner
# under sudo; the hint says so for anyone doing it by hand.
vbox_inaccessible_hint() {
  local uuid="$1" config="$2" kind="$3" owner="${SUDO_USER:-${USER:-$(id -un)}}"
  case "$kind" in
    gone)    printf 'its folder %s was deleted; tkoc vm off removes the stale entry (by hand, as %s: VBoxManage unregistervm %s)' \
               "$(dirname -- "$config")" "$owner" "$uuid" ;;
    offline) printf 'its location %s is not available (an unplugged drive?); left registered, cables not changed' \
               "$(dirname -- "$(dirname -- "$config")")" ;;
    *)       printf 'its files cannot be opened%s; cables not changed' "${config:+ ($config)}" ;;
  esac
}

# Unregister a VM whose files were deleted. Only the dangling entry goes; there
# is nothing on disk to remove, and nothing a snapshot could put back.
vbox_forget_deleted() {
  local uuid="$1" config="$2"
  if vbox_manage unregistervm "$uuid" >/dev/null 2>&1; then
    tkoc_change off "VirtualBox VM $uuid" "stale entry removed; its folder $(dirname -- "$config") was deleted"
  else
    tkoc_skipped "VirtualBox VM $uuid" "could not remove the stale entry; as $(id -un): VBoxManage unregistervm $uuid"
  fi
}

vbox_field() {
  local info="$1" key="$2"
  awk -F= -v key="$key" '$1 == key { gsub(/^"|"$/, "", $2); print $2; exit }' <<<"$info"
}

vbox_set_state() {
  local want="$1" uuid info vm_name vm_state slot nic cable key saved count=0 config kind
  [[ -n "${TKOC_TEST_ROOT:-}" && "${TKOC_TEST_VBOX:-}" != enabled ]] && return 0
  command -v VBoxManage >/dev/null 2>&1 || return 0
  local vms; vms="$(vbox_vms)" || return 1
  while IFS= read -r uuid; do
    [[ -n "$uuid" ]] || continue
    if ! info="$(vbox_manage showvminfo "$uuid" --machinereadable 2>/dev/null)"; then
      config="$(vbox_config_file "$uuid")"
      kind="$(vbox_inaccessible_kind "$config")"
      if [[ "$want" == off && "$kind" == gone ]]; then
        vbox_forget_deleted "$uuid" "$config"
      else
        tkoc_skipped "VirtualBox VM $uuid" "inaccessible: $(vbox_inaccessible_hint "$uuid" "$config" "$kind")"
      fi
      continue
    fi
    vm_name="$(vbox_field "$info" name)"
    vm_state="$(vbox_field "$info" VMState)"
    for slot in {1..8}; do
      nic="$(vbox_field "$info" "nic$slot")"
      [[ -n "$nic" && "$nic" != none ]] || continue
      cable="$(vbox_field "$info" "cableconnected$slot")"
      key="tkoc/vm-net/restore-cable$slot"
      if [[ "$want" == off && "$cable" == on ]]; then
        vbox_manage setextradata "$uuid" "$key" on
        if [[ "$vm_state" == running || "$vm_state" == paused ]]; then
          vbox_manage controlvm "$uuid" "setlinkstate$slot" off
        else
          vbox_manage modifyvm "$uuid" "--cable-connected$slot" off
        fi
        tkoc_change off "VirtualBox ${vm_name:-$uuid} nic $slot" "cable disconnected"
        ((count+=1))
      elif [[ "$want" == on ]]; then
        saved="$(vbox_manage getextradata "$uuid" "$key" 2>/dev/null)" || saved=""
        if [[ "$saved" == 'Value: on' ]]; then
          if [[ "$cable" != on ]]; then
            if [[ "$vm_state" == running || "$vm_state" == paused ]]; then
              vbox_manage controlvm "$uuid" "setlinkstate$slot" on
            else
              vbox_manage modifyvm "$uuid" "--cable-connected$slot" on
            fi
            tkoc_change on "VirtualBox ${vm_name:-$uuid} nic $slot" "cable reconnected"
            ((count+=1))
          fi
          vbox_manage setextradata "$uuid" "$key"
        fi
      fi
    done
  done <<<"$vms"
  (( count > 0 )) || tkoc_same "VirtualBox adapters" "already $want"
}

vbox_status() {
  [[ -n "${TKOC_TEST_ROOT:-}" && "${TKOC_TEST_VBOX:-}" != enabled ]] && return 0
  command -v VBoxManage >/dev/null 2>&1 || return 0
  local vms uuid info slot nic cable connected=0 configured=0 inaccessible=0 config
  vms="$(vbox_vms)" || return 1
  while IFS= read -r uuid; do
    [[ -n "$uuid" ]] || continue
    info="$(vbox_manage showvminfo "$uuid" --machinereadable 2>/dev/null)" \
      || { ((inaccessible+=1)); config="$(vbox_config_file "$uuid")"
           printf '  inaccessible VM %s: %s\n' "$uuid" \
             "$(vbox_inaccessible_hint "$uuid" "$config" "$(vbox_inaccessible_kind "$config")")"
           continue; }
    for slot in {1..8}; do
      nic="$(vbox_field "$info" "nic$slot")"
      [[ -n "$nic" && "$nic" != none ]] || continue
      ((configured+=1))
      cable="$(vbox_field "$info" "cableconnected$slot")"
      [[ "$cable" == on ]] && ((connected+=1))
    done
  done <<<"$vms"
  printf '  VirtualBox cables: %s connected of %s configured\n' "$connected" "$configured"
  if (( inaccessible > 0 )); then
    printf '  WARNING: %s inaccessible VirtualBox VM(s) could not be checked\n' "$inaccessible"
  fi
  if [[ "$(current_state)" == off && "$connected" -gt 0 ]]; then
    printf '  WARNING: VirtualBox has connected adapters outside the bridge firewall; run tkoc vm off\n'
  fi
}

set_state() {
  local want="$1" tmp
  require_guard
  local now; now="$(current_state)"

  if tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    local extra=""
    [[ "$want" == off ]] && extra=", removing entries for deleted VMs"
    log "[dry-run] would turn guest network passthrough $want and reconcile VirtualBox cables$extra"
    return 0
  fi

  tkoc_section "Guest network"
  # Disconnect VirtualBox first when turning off, and restore it last when
  # turning on. Reconcile it even if the bridge policy was already in state.
  [[ "$want" == off ]] && vbox_set_state off
  if [[ "$now" == "$want" ]]; then
    tkoc_same "guest network passthrough" "already $want"
    [[ "$want" == on ]] && vbox_set_state on
    return 0
  fi

  tkoc_state_capture_file "$LIVE_NFT"
  tkoc_state_capture_nftables "inet tkoc_host"

  tmp="$(mktemp "${TMPDIR:-/tmp}/tkoc-vmnet.XXXXXX")"
  awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" -v want="$want" '
    index($0, b) { inside = 1; print; next }
    index($0, e) { inside = 0; print; next }
    inside {
      if (want == "off") {
        if ($0 ~ /^[[:space:]]+(iifname|oifname).*accept[[:space:]]*$/) {
          print "# TKOC_VM_OFF:" $0; next
        }
        if ($0 ~ /^[[:space:]]*# TKOC_VM_ON:/) {
          sub(/^[[:space:]]*# TKOC_VM_ON:/, "", $0); print; next
        }
      } else {
        if ($0 ~ /^[[:space:]]+(iifname|oifname).*drop[[:space:]]*$/) {
          print "# TKOC_VM_ON:" $0; next
        }
        if ($0 ~ /^[[:space:]]*# TKOC_VM_OFF:/) {
          sub(/^[[:space:]]*# TKOC_VM_OFF:/, "", $0); print; next
        }
      }
      print; next
    }
    { print }
  ' <<<"$POLICY_BODY" > "$tmp"

  # A failed check still dies loudly on stderr; only the success line is
  # dropped, since the change report below says the policy went in.
  tkoc_validate_nft "$tmp" privileged >/dev/null
  run_root_path "$LIVE_NFT" install -m 0600 -- "$tmp" "$LIVE_NFT"
  rm -f -- "$tmp"

  local how="guest traffic blocked"
  [[ "$want" == on ]] && how="guests can reach the network"
  if command -v nft >/dev/null 2>&1 && [[ -z "${TKOC_TEST_ROOT:-}" ]]; then
    run_root nft --file "$LIVE_NFT"
    how+=", firewall reloaded"
  fi
  tkoc_change "$want" "guest network passthrough" "$how"
  [[ "$want" == on ]] && vbox_set_state on
  return 0
}

main() {
  local sub="${1:-status}"
  (( $# > 0 )) && shift
  # `tkoc vm on` and `tkoc vm net on` both reach here.
  [[ "$sub" == net ]] && { sub="${1:-status}"; (( $# > 0 )) && shift; }

  while [[ $# -gt 0 ]]; do
    tkoc_parse_safety_flag "$1" || die "vm net: unknown option: $1"
    shift
  done

  case "$sub" in
    on|enable)  require_policy prompting; set_state on ;;
    off|disable) require_policy prompting; set_state off ;;
    status|show)
      # Prompt rather than stay quiet: /etc/nftables is root-only, so without a
      # cached sudo the quiet reader cannot even tell that the policy exists,
      # and reported an installed firewall as missing.
      require_policy prompting
      printf '  guest network passthrough: %s\n' "$(current_state)"
      if ! grep -Fq '# TKOC_VM_GUARD' <<<"$POLICY_BODY"; then
        printf '  warning: installed policy lacks the established-flow guard; re-apply the firewall tier\n'
      fi
      vbox_status
      printf '  policy: %s\n' "$LIVE_NFT"
      ;;
    help|--help|-h) usage ;;
    *) die "Usage: tkoc vm net [on|off|status]" ;;
  esac
}

main "$@"
