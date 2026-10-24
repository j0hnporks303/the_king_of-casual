#!/usr/bin/env bash
# tests/test-tkoc.sh -- isolated install and rollback, touching nothing real.
#
# Everything happens inside TKOC_TEST_ROOT (a sandbox tree) and a throwaway
# HOME/XDG. The firewall stage detects TKOC_TEST_ROOT and stages files without
# activating anything, so this exercises the real rendering, validation,
# install, and snapshot paths on a machine that has no nft, dnf, or systemd.
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$TEST_DIR/.." && pwd -P)"
TEST_AREA="$(mktemp -d "${TMPDIR:-/tmp}/tkoc-test.XXXXXX")"
trap 'rm -rf -- "$TEST_AREA"' EXIT

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
ok()   { printf 'ok - %s\n' "$*"; }

assert_file()  { [[ -f "$1" ]] || fail "missing file: $1"; }
assert_grep()  { grep -qE "$1" "$2" || fail "$3"; }
refute_grep()  { grep -qE "$1" "$2" && fail "$3"; return 0; }

export TKOC_TEST_ROOT="$TEST_AREA/root"
# The user-scoped commands (dotfiles, theme, state) never consult
# TKOC_TEST_ROOT, so they are sandboxed by overriding HOME and both XDG
# variables. An ambient XDG_CONFIG_HOME in the developer's own shell must never
# leak through into this run.
export HOME="$TEST_AREA/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
export TKOC_STATE_HOME="$XDG_STATE_HOME/tkoc"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$TKOC_TEST_ROOT"

TKOC="$PROJECT_ROOT/tools/tkoc.sh"

# ── Help and dispatch ───────────────────────────────────────────

bash "$TKOC" help > "$TEST_AREA/help.out"
assert_grep 'tkoc harden <level>' "$TEST_AREA/help.out" "top-level help does not list harden"
assert_grep 'tkoc state list' "$TEST_AREA/help.out" "top-level help does not list state"
assert_grep 'tkoc privacy <level>' "$TEST_AREA/help.out" "top-level help does not list privacy"
ok "top-level help lists the main commands"

bash "$TKOC" firewall help > "$TEST_AREA/fw-help.out"
assert_grep 'tkoc firewall lockdown' "$TEST_AREA/fw-help.out" "firewall help does not show the lockdown tier"
assert_grep '\-\-ssh-source' "$TEST_AREA/fw-help.out" "firewall help does not document --ssh-source"
assert_grep '\-\-keep-firewalld' "$TEST_AREA/fw-help.out" "firewall help does not document --keep-firewalld"
ok "firewall help documents the flags the stage accepts"

bash "$TKOC" privacy help > "$TEST_AREA/pr-help.out"
assert_grep '\-\-categories' "$TEST_AREA/pr-help.out" "privacy help does not document --categories"
ok "privacy help documents --categories"

if bash "$TKOC" bogus >/dev/null 2>&1; then
  fail "an unknown command should exit non-zero"
fi
ok "an unknown command fails"

# ── Dispatcher routing ──────────────────────────────────────────
#
# Every command the help text advertises must actually reach its
# implementation. This exists because `tkoc wireguard` did not: the `wg`
# status alias shared a case arm with the stage name and silently swallowed
# it, so a documented command answered with a usage error instead of running.

routes_to() {
  local expected="$1"; shift
  local out="$TEST_AREA/route.out"
  if ! bash "$TKOC" "$@" --dry-run --allow-unsupported > "$out" 2>&1; then
    sed 's/^/    /' "$out" >&2
    fail "tkoc $* exited non-zero"
  fi
  grep -qF "$expected" "$out" || {
    sed 's/^/    /' "$out" >&2
    fail "tkoc $* did not reach $expected"
  }
}

# Bare stage names.
routes_to 'Running stage: base'      base
routes_to 'Firewall tier'            hardening
routes_to 'WireGuard'                wireguard
routes_to 'ClamAV'                   antivirus
routes_to 'theme'                    ricing
# ... and the same stages through `tkoc install`.
routes_to 'Running stage: base'      install base
routes_to 'Firewall tier'            install hardening
routes_to 'WireGuard'                install wireguard
routes_to 'ClamAV'                   install antivirus
routes_to 'Privacy hardening'        install privacy
ok "every stage is reachable both bare and through 'install'"

# `wg` must remain the status command, not the stage.
bash "$TKOC" wg show > "$TEST_AREA/wg.out" 2>&1 || fail "tkoc wg show failed"
assert_grep 'WireGuard status' "$TEST_AREA/wg.out" "tkoc wg show did not reach the status command"
ok "tkoc wg is the status command, distinct from the wireguard stage"

# Every command named in the top-level help must be dispatchable: it may fail
# for an environmental reason, but it must never answer "Unknown command".
while IFS= read -r verb; do
  out="$(bash "$TKOC" "$verb" --help 2>&1 || true)"
  grep -q "Unknown command: $verb" <<<"$out" && fail "tkoc $verb is advertised but not dispatched"
done < <(bash "$TKOC" help | awk '$1 == "tkoc" && $2 ~ /^[a-z]+$/ { print $2 }' | sort -u)
ok "every command in the help text is dispatched"

# ── Policy content ──────────────────────────────────────────────

NFT="$PROJECT_ROOT/config/firewall/tkoc.nft"
assert_grep 'udp dport \{ 137, 138, 1716, 1900, 27036, 5353, 5355 \}' "$NFT" \
  "LAN discovery ports are not in the template"
assert_grep 'ip protocol igmp' "$NFT" "IGMP is not in the template"
assert_grep 'policy drop;' "$NFT" "the template has no default-drop chain"
ok "the firewall template covers the documented surface"

# ── Staged install at each tier ─────────────────────────────────

stage_tier() {
  local tier="$1"; shift
  rm -rf "$TKOC_TEST_ROOT"; mkdir -p "$TKOC_TEST_ROOT"
  bash "$PROJECT_ROOT/stages/40-hardening.sh" "$tier" --yes --allow-unsupported "$@" \
    > "$TEST_AREA/$tier.out" 2>&1 \
    || { sed 's/^/    /' "$TEST_AREA/$tier.out" >&2; fail "staging tier $tier failed"; }
}

stage_tier vanilla
assert_file "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft"
assert_file "$TKOC_TEST_ROOT/etc/sysctl.d/60-tkoc-hardening.conf"
assert_file "$TKOC_TEST_ROOT/etc/sysconfig/nftables.conf"
assert_grep 'include "/etc/nftables/tkoc.nft"' "$TKOC_TEST_ROOT/etc/sysconfig/nftables.conf" \
  "the boot include was not wired up"
refute_grep '^\s+udp dport \{ 137, 138' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "vanilla must not drop LAN discovery"
ok "vanilla stages a policy and wires up the boot include"

stage_tier strong
assert_grep '^\s+udp dport \{ 137, 138' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "strong must drop LAN discovery"
assert_grep '^net\.ipv6\.conf\.all\.disable_ipv6 = 1' \
  "$TKOC_TEST_ROOT/etc/sysctl.d/60-tkoc-hardening.conf" \
  "strong must disable IPv6 at the kernel level"
refute_grep '^\s+ip daddr \$ALLOWED_DNS4' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "strong must not pin DNS"
ok "strong drops LAN discovery and disables IPv6"

stage_tier lockdown --dns 192.0.2.53
assert_grep '^define ALLOWED_DNS4 = \{ 192\.0\.2\.53 \}' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "the resolver was not rendered into the policy"
assert_grep '^\s+ip daddr \$ALLOWED_DNS4 udp dport 53 accept' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "lockdown must pin DNS"
assert_grep 'th dport 853' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "lockdown must drop DNS-over-TLS/QUIC"
ok "lockdown pins the resolver and drops encrypted DNS"

stage_tier lockdown --ipv6 enabled --dns '192.0.2.53#dns.example, 192.0.2.54,2001:db8::53#dns.example' \
  --dns-over-tls yes
assert_grep '^define ALLOWED_DNS4 = \{ 192\.0\.2\.53, 192\.0\.2\.54 \}' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "the IPv4 resolvers were not rendered into the policy"
assert_grep '^define ALLOWED_DNS6 = \{ 2001:db8::53 \}' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "the IPv6 resolver was not rendered into the policy"
assert_grep '^\s+ip6 daddr \$ALLOWED_DNS6 udp dport 53 accept' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "lockdown must pin IPv6 DNS"
assert_grep '^\s+ip daddr \$ALLOWED_DNS4 tcp dport 853 accept' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "--dns-over-tls must open 853 to the pinned resolvers"
ok "lockdown pins a dual-stack resolver list, with DNS-over-TLS to it on request"

# A resolver the firewall cannot pin must be refused before anything is staged.
for bad_dns in 1.1.1.1:53 'not-an-ip' '1.1.1.1#'; do
  if bash "$PROJECT_ROOT/stages/40-hardening.sh" lockdown --dns "$bad_dns" \
      --yes --allow-unsupported >/dev/null 2>&1; then
    fail "a malformed --dns was accepted: $bad_dns"
  fi
done
if bash "$PROJECT_ROOT/stages/40-hardening.sh" lockdown --dns 2001:db8::53 \
    --yes --allow-unsupported >/dev/null 2>&1; then
  fail "IPv6-only resolvers were accepted with IPv6 off"
fi
ok "resolvers the firewall cannot reach or pin are refused"

stage_tier strong --ssh-source 192.168.8.0/24
assert_grep '^define SSH_SOURCE = \{ 192\.168\.8\.0/24 \}' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "the SSH source was not rendered"
assert_grep '^\s+ip saddr \$SSH_SOURCE tcp dport 22' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "the SSH carve-out was not rendered"
ok "the SSH carve-out renders with an explicit source"

# A malformed source must be rejected at parse time, before anything is staged.
if bash "$PROJECT_ROOT/stages/40-hardening.sh" strong --ssh-source 'not-an-ip' \
    --yes --allow-unsupported >/dev/null 2>&1; then
  fail "a malformed --ssh-source was accepted"
fi
ok "a malformed --ssh-source is rejected"

# An ambient TKOC_ALLOW_SSH must not open SSH at the lockdown tier.
if TKOC_ALLOW_SSH=enabled bash "$PROJECT_ROOT/stages/40-hardening.sh" lockdown \
    --dns 192.0.2.53 --yes --allow-unsupported >/dev/null 2>&1; then
  fail "an ambient TKOC_ALLOW_SSH opened SSH at the lockdown tier"
fi
ok "an ambient TKOC_ALLOW_SSH is refused at the lockdown tier"

# ── an unreadable /etc/sysconfig/nftables.conf ──────────────────
#
# This is the exact failure that reached a real machine: that file is
# 0600 root:root on Fedora, a plain grep/awk on it as an ordinary user fails
# with "Permission denied", and under `set -e` the run died *after* installing
# the policy and *before* wiring up the boot include or applying anything.

rm -rf "$TKOC_TEST_ROOT"; mkdir -p "$TKOC_TEST_ROOT/etc/sysconfig"
printf 'flush ruleset\ninclude "/etc/nftables/main.nft"\n' \
  > "$TKOC_TEST_ROOT/etc/sysconfig/nftables.conf"
chmod 000 "$TKOC_TEST_ROOT/etc/sysconfig/nftables.conf"

if [[ -r "$TKOC_TEST_ROOT/etc/sysconfig/nftables.conf" ]]; then
  # Running as root (or an fs that ignores modes) makes this case untestable.
  printf 'skip - unreadable-file case needs a non-root user\n'
else
  bash "$PROJECT_ROOT/stages/40-hardening.sh" strong --dry-run --allow-unsupported \
    > "$TEST_AREA/unreadable-dry.out" 2>&1 \
    || { sed 's/^/    /' "$TEST_AREA/unreadable-dry.out" >&2
         fail "a dry run aborted on an unreadable /etc/sysconfig/nftables.conf"; }
  assert_grep 'contents are unknown' "$TEST_AREA/unreadable-dry.out" \
    "the dry run did not say it could not read the file"
  ok "a dry run survives an unreadable /etc/sysconfig/nftables.conf and says so"

  # The real run must reach the end rather than dying half way. It cannot
  # rewrite the file without privilege, so it is expected to fail -- but it
  # must fail *loudly*, marking the snapshot and saying what to do.
  chmod 000 "$TKOC_TEST_ROOT/etc/sysconfig/nftables.conf"
  set +e
  bash "$PROJECT_ROOT/stages/40-hardening.sh" strong --yes --allow-unsupported \
    > "$TEST_AREA/unreadable-real.out" 2>&1
  real_rc=$?
  set -e
  if (( real_rc != 0 )); then
    assert_grep 'tkoc state restore' "$TEST_AREA/unreadable-real.out" \
      "a failed run did not tell the user how to roll back"
    ok "a run that cannot finish marks the snapshot and names the rollback command"
  else
    ok "the run completed despite the unreadable file"
  fi
fi
chmod 644 "$TKOC_TEST_ROOT/etc/sysconfig/nftables.conf" 2>/dev/null || true

# ── vm net toggles the staged policy ────────────────────────────

stage_tier strong
# Capture to a file rather than piping into `grep -q`. grep -q exits on the
# first match and closes the pipe; with `set -o pipefail` the writer's EPIPE
# then fails the whole pipeline, intermittently, depending on whether it had
# finished writing. That race made this step flap.
vm_state() {
  bash "$PROJECT_ROOT/tools/vm-net.sh" status > "$TEST_AREA/vmnet.out" 2>&1 \
    || { sed 's/^/    /' "$TEST_AREA/vmnet.out" >&2; fail "vm net status failed"; }
  grep -q "passthrough: $1" "$TEST_AREA/vmnet.out" \
    || { sed 's/^/    /' "$TEST_AREA/vmnet.out" >&2; fail "$2"; }
}

vm_state off "guest passthrough should start off"
bash "$PROJECT_ROOT/tools/vm-net.sh" on --yes >/dev/null
vm_state on "vm net on did not restore the rules"
refute_grep '^\s+iifname "virbr\*" counter drop' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "vm net on left the bridge guard active"
assert_grep '^\s+iifname "virbr\*" ct state new.*accept' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "vm net on did not permit new guest connections"
bash "$PROJECT_ROOT/tools/vm-net.sh" off --yes >/dev/null
vm_state off "vm net off did not take effect"
assert_grep '^\s+iifname "virbr\*" counter drop' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "vm net off did not restore the early bridge drop"
refute_grep '^\s+iifname "virbr\*" ct state new.*accept' "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" \
  "vm net off left new guest connections accepted"
awk '/iifname "virbr\*" counter drop/ { blocked = NR } /ct state established,related accept/ && blocked && NR > blocked { guarded = 1 } END { exit !guarded }' \
  "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" || fail "vm net off must block guests before established connections"
stage_tier strong
vm_state off "re-applying a firewall tier should return guest passthrough to off"
ok "vm net round-trips the guest passthrough block"

# VirtualBox NAT uses host sockets, so a bridge firewall cannot disconnect it.
# Exercise the CLI integration with a fake VM, including its saved prior state.
mkdir -p "$TEST_AREA/fakebin"
printf 'on\n' > "$TEST_AREA/vbox-cable"
cat > "$TEST_AREA/fakebin/VBoxManage" <<'FAKE_VBOX'
#!/usr/bin/env bash
set -e
case "$1" in
  list) printf '"test" {11111111-1111-1111-1111-111111111111}\n' ;;
  showvminfo)
    printf 'VMState="poweroff"\nnic1="nat"\ncableconnected1="%s"\n' "$(cat "$FAKE_VBOX_CABLE")"
    ;;
  getextradata)
    if [[ -f "$FAKE_VBOX_RESTORE" ]]; then printf 'Value: on\n'; else printf 'No value set!\n'; fi
    ;;
  setextradata)
    if [[ "${4:-}" == on ]]; then printf 'on\n' > "$FAKE_VBOX_RESTORE"; else rm -f "$FAKE_VBOX_RESTORE"; fi
    ;;
  modifyvm) printf '%s\n' "$4" > "$FAKE_VBOX_CABLE" ;;
  *) exit 1 ;;
esac
FAKE_VBOX
chmod +x "$TEST_AREA/fakebin/VBoxManage"
export FAKE_VBOX_CABLE="$TEST_AREA/vbox-cable"
export FAKE_VBOX_RESTORE="$TEST_AREA/vbox-restore"
export TKOC_TEST_VBOX=enabled
export PATH="$TEST_AREA/fakebin:$PATH"
bash "$PROJECT_ROOT/tools/vm-net.sh" off --yes >/dev/null
[[ "$(cat "$FAKE_VBOX_CABLE")" == off && -f "$FAKE_VBOX_RESTORE" ]] \
  || fail "vm net off did not disconnect and remember the VirtualBox adapter"
bash "$PROJECT_ROOT/tools/vm-net.sh" on --yes >/dev/null
[[ "$(cat "$FAKE_VBOX_CABLE")" == on && ! -f "$FAKE_VBOX_RESTORE" ]] \
  || fail "vm net on did not restore the VirtualBox adapter"
unset TKOC_TEST_VBOX FAKE_VBOX_CABLE FAKE_VBOX_RESTORE
ok "vm net controls VirtualBox NAT adapters"

# `tkoc vm on|off` drives both halves; `vm net` alone must leave the host alone.
VM_BLOCK="$TKOC_TEST_ROOT/etc/modprobe.d/tkoc-vm-block.conf"
bash "$TKOC" vm net off --yes >/dev/null
[[ -e "$VM_BLOCK" ]] && fail "tkoc vm net off touched the host module block"
bash "$TKOC" vm off --yes >/dev/null
vm_state off "tkoc vm off did not cut guest networking"
assert_grep '^install kvm /bin/false$' "$VM_BLOCK" "tkoc vm off did not block the KVM module"
assert_grep '^install vboxdrv /bin/false$' "$VM_BLOCK" "tkoc vm off did not block the VirtualBox driver"
bash "$TKOC" vm status > "$TEST_AREA/vm-status.out" 2>&1
assert_grep 'passthrough: off' "$TEST_AREA/vm-status.out" "tkoc vm status left out the network half"
assert_grep 'host VM services and modules: off' "$TEST_AREA/vm-status.out" "tkoc vm status left out the host half"
bash "$TKOC" vm on --yes >/dev/null
vm_state on "tkoc vm on did not restore guest networking"
[[ -e "$VM_BLOCK" ]] && fail "tkoc vm on left the module block in place"
ok "tkoc vm on|off switches guest networking and the host's VM modules together"

# ── dotfiles into the throwaway HOME ────────────────────────────

bash "$PROJECT_ROOT/tools/dotfiles.sh" --dry-run > "$TEST_AREA/dotfiles-dry.out"
assert_grep 'would link' "$TEST_AREA/dotfiles-dry.out" "dotfiles --dry-run described no work"
[[ -e "$XDG_CONFIG_HOME/tkoc" ]] && fail "dotfiles --dry-run created files"
ok "dotfiles --dry-run changes nothing"

bash "$PROJECT_ROOT/tools/dotfiles.sh" > "$TEST_AREA/dotfiles.out"
[[ -L "$XDG_CONFIG_HOME/tkoc/dotfiles/shell.d" ]] || fail "shell.d was not linked"
[[ -L "$XDG_CONFIG_HOME/tkoc/dotfiles/prompt-themes" ]] || fail "prompt-themes was not linked"
[[ "$(cat "$XDG_STATE_HOME/tkoc/prompt-theme")" == fedora ]] \
  || fail "the default prompt theme should be fedora on the Fedora edition"
ok "dotfiles links the managed config and defaults to the fedora prompt"

bash "$PROJECT_ROOT/tools/dotfiles.sh" > "$TEST_AREA/dotfiles2.out"
assert_grep 'already linked' "$TEST_AREA/dotfiles2.out" "re-running dotfiles was not a no-op"
ok "re-running dotfiles is a no-op"

bash "$PROJECT_ROOT/tools/dotfiles.sh" set-theme terminal >/dev/null
[[ "$(cat "$XDG_STATE_HOME/tkoc/prompt-theme")" == terminal ]] || fail "set-theme did not take"
if bash "$PROJECT_ROOT/tools/dotfiles.sh" set-theme no-such-theme >/dev/null 2>&1; then
  fail "an unknown prompt theme was accepted"
fi
ok "set-theme switches themes and rejects unknown ones"

# ── privacy previews at every level ─────────────────────────────

for level in basic strong lockdown; do
  bash "$PROJECT_ROOT/stages/55-privacy.sh" "$level" --dry-run --allow-unsupported \
    > "$TEST_AREA/privacy-$level.out" 2>&1 \
    || { sed 's/^/    /' "$TEST_AREA/privacy-$level.out" >&2
         fail "privacy $level --dry-run failed"; }
  assert_grep 'privacy: remote-access' "$TEST_AREA/privacy-$level.out" \
    "privacy $level did not run the remote-access category"
done
# Each level must be a strict superset of the one below it.
basic_count=$(grep -c '==> privacy:' "$TEST_AREA/privacy-basic.out")
strong_count=$(grep -c '==> privacy:' "$TEST_AREA/privacy-strong.out")
lockdown_count=$(grep -c '==> privacy:' "$TEST_AREA/privacy-lockdown.out")
(( basic_count < strong_count && strong_count < lockdown_count )) \
  || fail "privacy levels are not strictly nested ($basic_count/$strong_count/$lockdown_count)"
ok "privacy previews run at every level and the levels are nested"

# A dry run must not have written anything into the sandbox or HOME.
[[ -e "$TKOC_TEST_ROOT/etc/dnf" ]] && fail "a privacy dry run wrote into the sandbox"

# `tkoc harden` once skipped remote-access on the belief that the firewall stage
# had handled it. It never had, so sshd and remote-desktop agents stayed on.
bash "$TKOC" harden strong --dry-run --allow-unsupported > "$TEST_AREA/harden.out" 2>&1 \
  || { sed 's/^/    /' "$TEST_AREA/harden.out" >&2; fail "tkoc harden strong --dry-run failed"; }
assert_grep 'privacy: remote-access' "$TEST_AREA/harden.out" "tkoc harden skipped the remote-access category"
ok "tkoc harden turns remote access off"
ok "a privacy dry run writes nothing"

if bash "$PROJECT_ROOT/stages/55-privacy.sh" --categories no-such-category \
    --dry-run >/dev/null 2>&1; then
  fail "an unknown privacy category was accepted"
fi
ok "an unknown privacy category is rejected"

# ── state: the snapshot the staging run created ─────────────────

bash "$PROJECT_ROOT/tools/state.sh" list > "$TEST_AREA/state.out"
assert_grep 'tkoc firewall' "$TEST_AREA/state.out" "no snapshot was recorded for the firewall run"
ok "staging a tier records a recovery snapshot"

snapshot_id="$(awk 'NR==2 { print $1 }' "$TEST_AREA/state.out")"
[[ -n "$snapshot_id" ]] || fail "could not read a snapshot id"
bash "$PROJECT_ROOT/tools/state.sh" show "$snapshot_id" > "$TEST_AREA/show.out"
assert_grep 'Captured state:' "$TEST_AREA/show.out" "state show printed no manifest"
ok "state show reads the snapshot back"

bash "$PROJECT_ROOT/tools/state.sh" restore "$snapshot_id" --dry-run --yes > "$TEST_AREA/restore.out"
assert_grep 'dry-run' "$TEST_AREA/restore.out" "state restore --dry-run did not preview"
ok "state restore --dry-run previews without changing anything"

# ── uninstall report ────────────────────────────────────────────

bash "$PROJECT_ROOT/tools/uninstall.sh" > "$TEST_AREA/uninstall.out"
assert_grep 'remove .*etc/nftables/tkoc.nft' "$TEST_AREA/uninstall.out" \
  "uninstall did not notice the staged firewall policy"
assert_grep 'nothing was changed' "$TEST_AREA/uninstall.out" \
  "uninstall without --apply should change nothing"
assert_file "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft"
ok "uninstall reports without applying"

# The host may have firewalld masked. An isolated uninstall must not inspect
# that host state or run systemctl against it, even when --apply is supplied.
mkdir -p "$TEST_AREA/bin"
cat > "$TEST_AREA/bin/systemctl" <<'SYSTEMCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TKOC_TEST_ROOT/systemctl-calls"
if [[ "$*" == 'is-enabled firewalld.service' ]]; then
  printf 'masked\n'
fi
exit 0
SYSTEMCTL
chmod +x "$TEST_AREA/bin/systemctl"
mkdir -p "$XDG_CONFIG_HOME/systemd/user"
touch "$XDG_CONFIG_HOME/systemd/user/tkoc-clamav.timer" \
  "$XDG_CONFIG_HOME/systemd/user/tkoc-clamav.service"
PATH="$TEST_AREA/bin:$PATH" bash "$PROJECT_ROOT/tools/uninstall.sh" --apply > "$TEST_AREA/uninstall2.out"
[[ ! -e "$TKOC_TEST_ROOT/systemctl-calls" ]] \
  || fail "isolated uninstall contacted the real systemd manager"
[[ ! -e "$XDG_CONFIG_HOME/systemd/user/tkoc-clamav.timer" ]] \
  || fail "isolated uninstall left the staged user timer behind"
[[ -f "$TKOC_TEST_ROOT/etc/nftables/tkoc.nft" ]] && fail "uninstall --apply left the policy in place"
refute_grep '# >>> tkoc >>>' "$TKOC_TEST_ROOT/etc/sysconfig/nftables.conf" \
  "uninstall --apply left the boot include behind"
ok "uninstall --apply removes the policy and the boot include"

printf '\nall tests passed\n'
