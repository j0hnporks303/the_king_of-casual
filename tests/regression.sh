#!/usr/bin/env bash
# tests/regression.sh -- structural checks that run anywhere, including on a
# macOS development machine with no nft, dnf, or systemd.
#
# The point of this suite is that every help path must be usable for diagnosis
# without privilege and without touching $HOME. A fake sudo on PATH that exits
# 97 and logs turns any accidental escalation into a hard failure instead of a
# password prompt you would otherwise just type through.
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/tkoc-regression.XXXXXX")"
trap 'rm -rf -- "$TMP_ROOT"' EXIT

fail() { printf '[regression][FAIL] %s\n' "$*" >&2; exit 1; }
pass() { printf '[regression][OK] %s\n' "$*"; }

# ── 1. Every implementation named by the CLI actually exists ────

for required in \
  "$ROOT/tools/tkoc.sh" \
  "$ROOT/stages/lib/common.sh" \
  "$ROOT/stages/lib/state.sh" \
  "$ROOT/stages/lib/audit.sh" \
  "$ROOT/stages/lib/hardening-common.sh" \
  "$ROOT/stages/lib/persistence.sh" \
  "$ROOT/stages/40-hardening.sh" \
  "$ROOT/stages/55-privacy.sh" \
  "$ROOT/config/firewall/tkoc.nft" \
  "$ROOT/config/sysctl.d/60-tkoc-hardening.conf" \
  "$ROOT/config/downlock.json" \
  "$ROOT/config/network-profiles.json"; do
  [[ -f "$required" ]] || fail "required implementation missing: $required"
done
pass "required implementations are present"

# ── 2. Everything parses ────────────────────────────────────────

script_count=0
while IFS= read -r script; do
  bash -n "$script" || fail "syntax error: $script"
  script_count=$((script_count + 1))
done < <(find "$ROOT/tools" "$ROOT/stages" "$ROOT/tests" "$ROOT/config/dotfiles/shell.d" \
  -name '*.sh' -type f | sort)
pass "$script_count shell scripts parse"

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck_failures=0
  while IFS= read -r script; do
    shellcheck --severity=error --shell=bash "$script" >/dev/null 2>&1 \
      || { printf '[regression]   shellcheck: %s\n' "${script#"$ROOT/"}"; shellcheck_failures=$((shellcheck_failures + 1)); }
  done < <(find "$ROOT/tools" "$ROOT/stages" -name '*.sh' -type f | sort)
  (( shellcheck_failures == 0 )) || fail "$shellcheck_failures script(s) have shellcheck errors"
  pass "shellcheck reports no errors"
else
  printf '[regression][SKIP] shellcheck is not installed\n'
fi

# ── 3. JSON configs are valid ───────────────────────────────────

if command -v python3 >/dev/null 2>&1; then
  for json in "$ROOT/config/downlock.json" "$ROOT/config/network-profiles.json" \
              "$ROOT/config/flatpak-access.json"; do
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$json" \
      || fail "invalid JSON: $json"
  done
  pass "JSON configuration files are valid"
fi

# ── 4. Help paths never escalate and never touch the real HOME ──

HELP_HOME="$TMP_ROOT/help home"
HELP_BIN="$TMP_ROOT/help-bin"
SUDO_CAPTURE="$TMP_ROOT/sudo.capture"
mkdir -p "$HELP_HOME" "$HELP_BIN"
cat > "$HELP_BIN/sudo" <<'MOCK_SUDO'
#!/bin/sh
printf 'sudo called: %s\n' "$*" >> "${TKOC_SUDO_CAPTURE:?}"
exit 97
MOCK_SUDO
chmod 700 "$HELP_BIN/sudo"
: > "$SUDO_CAPTURE"

help_scripts=(
  tools/tkoc.sh
  tools/selfcheck.sh tools/postcheck.sh tools/doctor.sh tools/audit.sh
  tools/state.sh tools/ice.sh tools/dotfiles.sh
  tools/firewall-status.sh tools/firewall-test.sh
  tools/network-learn.sh tools/network-profile.sh tools/network-watch.sh
  tools/update.sh tools/uninstall.sh tools/uav.sh tools/linker.sh
  tools/pgp.sh tools/downlock.sh tools/killall.sh tools/vm-net.sh tools/vm-host.sh
  stages/00-base.sh stages/40-hardening.sh stages/45-wireguard.sh
  stages/50-antivirus.sh stages/55-privacy.sh stages/60-ricing.sh
)
for script in "${help_scripts[@]}"; do
  [[ -f "$ROOT/$script" ]] || fail "help script missing: $script"
  out="$TMP_ROOT/help.out"
  if ! env -i \
      PATH="$HELP_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
      HOME="$HELP_HOME" \
      TERM=dumb \
      TKOC_SUDO_CAPTURE="$SUDO_CAPTURE" \
      bash "$ROOT/$script" --help >"$out" 2>&1; then
    printf '%s\n' "--- $script --help ---" >&2
    sed 's/^/    /' "$out" >&2
    fail "$script --help exited non-zero"
  fi
  [[ -s "$out" ]] || fail "$script --help printed nothing"
done
pass "${#help_scripts[@]} scripts print help without privilege"

[[ -s "$SUDO_CAPTURE" ]] && {
  sed 's/^/    /' "$SUDO_CAPTURE" >&2
  fail "a help path invoked sudo"
}
pass "no help path invoked sudo"

# Nothing may have been written into the throwaway HOME either.
if [[ -n "$(find "$HELP_HOME" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
  find "$HELP_HOME" -mindepth 1 | sed 's/^/    /' >&2
  fail "a help path wrote into HOME"
fi
pass "no help path wrote into HOME"

# ── 5. Category scripts all exist and are reachable ─────────────

missing_categories=0
while IFS= read -r category; do
  [[ -n "$category" ]] || continue
  [[ -f "$ROOT/stages/hardening/$category.sh" ]] \
    || { printf '[regression]   missing category script: %s\n' "$category"; missing_categories=$((missing_categories + 1)); }
done < <(bash "$ROOT/stages/55-privacy.sh" --list-categories | awk 'NF==2 && $2 ~ /^(basic|strong|lockdown)$/ { print $1 }')
(( missing_categories == 0 )) || fail "$missing_categories privacy categories have no script"
pass "every listed privacy category has a script"

# ── 6. The firewall template renders and validates at every tier ─

# shellcheck source=../stages/lib/common.sh
source "$ROOT/stages/lib/common.sh"

render_tier() {
  local label="$1" out="$TMP_ROOT/$1.nft"; shift
  tkoc_render_markers "$ROOT/config/firewall/tkoc.nft" "$out" "$@" \
    || fail "$label: render failed"
  tkoc_validate_nft "$out" >/dev/null || fail "$label: validation failed"
  printf '%s' "$out"
}

vanilla="$(render_tier vanilla)"
strong="$(render_tier strong TKOC_LAN_NOISE TKOC_IPV6_OFF)"
lockdown="$(render_tier lockdown TKOC_LAN_NOISE TKOC_IPV6_OFF TKOC_DNS_ENFORCE)"
pass "the firewall template renders and validates at all three tiers"

# Each tier must actually differ in the ways the documentation claims.
grep -qE '^\s+udp dport \{ 137, 138' "$vanilla" \
  && fail "vanilla must not drop LAN discovery"
grep -qE '^\s+udp dport \{ 137, 138' "$strong" \
  || fail "strong must drop LAN discovery"
grep -qE '^\s+meta nfproto ipv6' "$vanilla" \
  && fail "vanilla must not block off-host IPv6"
grep -qE '^\s+meta nfproto ipv6' "$strong" \
  || fail "strong must block off-host IPv6"
grep -qE '^\s+ip daddr \$ALLOWED_DNS4' "$strong" \
  && fail "strong must not pin DNS"
grep -qE '^\s+ip daddr \$ALLOWED_DNS4' "$lockdown" \
  || fail "lockdown must pin DNS"
grep -qE '^\s+meta l4proto \{ tcp, udp \} th dport 853' "$lockdown" \
  || fail "lockdown must drop DNS-over-TLS/QUIC"
pass "each tier differs from the next exactly as documented"

# Loopback must be accepted at every tier, or systemd-resolved's stub at
# 127.0.0.53 stops answering and the machine cannot resolve anything.
for tier in "$vanilla" "$strong" "$lockdown"; do
  grep -qE '^\s+iifname "lo" accept' "$tier" || fail "a tier does not accept loopback input"
  grep -qE '^\s+oifname "lo" accept' "$tier" || fail "a tier does not accept loopback output"
done
pass "loopback is accepted at every tier"

# No tier may accept inbound SSH unless the carve-out was asked for.
for tier in "$vanilla" "$strong" "$lockdown"; do
  grep -qE '^\s+ip saddr \$SSH_SOURCE' "$tier" && fail "a tier opened SSH without --ssh"
done
ssh_tier="$(render_tier ssh TKOC_LAN_NOISE TKOC_IPV6_OFF TKOC_SSH_ALLOW)"
grep -qE '^\s+ip saddr \$SSH_SOURCE tcp dport 22' "$ssh_tier" \
  || fail "the SSH marker did not render the carve-out"
pass "inbound SSH is closed unless the carve-out marker is enabled"

# DoT is dropped at lockdown unless it was asked for, and when it is, the
# carve-out reaches the pinned resolvers only and comes before the 853 drop.
grep -qE '^\s+ip6? daddr \$ALLOWED_DNS[46] tcp dport 853 accept' "$lockdown" \
  && fail "lockdown opened DNS-over-TLS without --dns-over-tls"
dot_tier="$(render_tier dot TKOC_LAN_NOISE TKOC_IPV6_OFF TKOC_DNS_ENFORCE TKOC_DOT_ALLOW)"
grep -qE '^\s+ip daddr \$ALLOWED_DNS4 tcp dport 853 accept' "$dot_tier" \
  || fail "the DoT marker did not open 853 to the pinned IPv4 resolvers"
grep -qE '^\s+ip6 daddr \$ALLOWED_DNS6 tcp dport 853 accept' "$dot_tier" \
  || fail "the DoT marker did not open 853 to the pinned IPv6 resolvers"
dot_accept="$(grep -nE '^\s+ip daddr \$ALLOWED_DNS4 tcp dport 853 accept' "$dot_tier" | cut -d: -f1)"
dot_drop="$(grep -nE '^\s+meta l4proto \{ tcp, udp \} th dport 853 counter' "$dot_tier" | cut -d: -f1)"
(( dot_accept < dot_drop )) || fail "the DoT carve-out comes after the 853 drop and can never match"
pass "DNS-over-TLS reaches only the pinned resolvers, and only when asked"

# ── 6b. Resolver lists are validated before anything is rendered ─

for good in 192.0.2.53 2001:db8::53 ::1 1:2:3:4:5:6:7:8 '1.1.1.1#cloudflare-dns.com' \
    '2606:4700:4700::1111#one.one.one.one'; do
  tkoc_valid_dns_server "$good" || fail "a valid resolver was refused: $good"
done
for bad in '' 1.1.1.1:53 '[::1]:53' 'fe80::1%eth0' 1::2::3 1:2:3:4:5:6:7:8:9 999.1.1.1 \
    '1.1.1.1#' '1.1.1.1#-bad' '1.1.1.1#a b' $'1.1.1.1#a\nDNS=9.9.9.9'; do
  tkoc_valid_dns_server "$bad" && fail "a malformed resolver was accepted: $(printf '%q' "$bad")"
done
tkoc_parse_dns_list '192.0.2.1#a.example, 192.0.2.1#a.example,2001:db8::1 192.0.2.2'
[[ "${TKOC_DNS_SERVERS[*]}" == '192.0.2.1#a.example 2001:db8::1 192.0.2.2' ]] \
  || fail "the resolver list did not split and de-duplicate: ${TKOC_DNS_SERVERS[*]}"
[[ "${TKOC_DNS_ADDR4[*]}" == '192.0.2.1 192.0.2.2' && "${TKOC_DNS_ADDR6[*]}" == '2001:db8::1' ]] \
  || fail "the resolver list did not separate by family"
pass "resolver lists are validated, split by family, and de-duplicated"

# ── 7. The sysctl template renders and validates ────────────────

tkoc_render_markers "$ROOT/config/sysctl.d/60-tkoc-hardening.conf" "$TMP_ROOT/vanilla.conf"
tkoc_render_markers "$ROOT/config/sysctl.d/60-tkoc-hardening.conf" "$TMP_ROOT/locked.conf" TKOC_IPV6_OFF
tkoc_validate_sysctl "$TMP_ROOT/vanilla.conf" || fail "vanilla sysctl policy is invalid"
tkoc_validate_sysctl "$TMP_ROOT/locked.conf" || fail "lockdown sysctl policy is invalid"
grep -qE '^net\.ipv6\.conf\.all\.disable_ipv6' "$TMP_ROOT/vanilla.conf" \
  && fail "IPv6 must not be disabled when the marker is off"
grep -qE '^net\.ipv6\.conf\.all\.disable_ipv6 = 1' "$TMP_ROOT/locked.conf" \
  || fail "the IPv6 marker did not render"
grep -qE '^net\.ipv6\.conf\.lo\.disable_ipv6 = 0' "$TMP_ROOT/locked.conf" \
  || fail "loopback IPv6 must stay enabled even when IPv6 is disabled"
pass "the sysctl template renders and validates"

# ── 8. Snapshot capture and restore round-trips ─────────────────

# shellcheck source=../stages/lib/state.sh
TKOC_STATE_HOME="$TMP_ROOT/state" source "$ROOT/stages/lib/state.sh"
TKOC_STATE_HOME="$TMP_ROOT/state"
TKOC_SNAPSHOT_ROOT="$TKOC_STATE_HOME/snapshots"

work="$TMP_ROOT/work"; mkdir -p "$work"
printf 'ORIGINAL\n' > "$work/keep.conf"; chmod 640 "$work/keep.conf"

tkoc_state_begin "regression" >/dev/null || fail "could not begin a snapshot"
tkoc_state_capture_file "$work/keep.conf" || fail "could not capture an existing file"
tkoc_state_capture_file "$work/created.conf" || fail "could not capture an absent file"
printf 'MUTATED\n' > "$work/keep.conf"; chmod 600 "$work/keep.conf"
printf 'NEW\n' > "$work/created.conf"
snapshot="$TKOC_ACTIVE_SNAPSHOT"
tkoc_state_finish

tkoc_state_restore "$snapshot" || fail "restore failed with status $?"
[[ "$(cat "$work/keep.conf")" == ORIGINAL ]] || fail "restore did not put the content back"
[[ "$(tkoc_stat mode "$work/keep.conf")" == 640 ]] || fail "restore did not put the mode back"
[[ ! -e "$work/created.conf" ]] || fail "restore did not remove a file created during the transaction"
pass "snapshot capture and restore round-trip correctly"

# A snapshot from another schema (the macOS edition uses 1) must be refused
# rather than walked with the wrong restorers.
sed -i.bak 's/^schema=.*/schema=99/' "$snapshot/meta" && rm -f "$snapshot/meta.bak"
if tkoc_state_restore "$snapshot" 2>/dev/null; then
  fail "a snapshot with an unsupported schema was restored anyway"
fi
pass "a snapshot with an unsupported schema is refused"

printf '\n[regression] all checks passed\n'
