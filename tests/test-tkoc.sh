#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="$(cd -- "$TEST_DIR/.." && pwd -P)"
TEST_AREA="$(mktemp -d "${TMPDIR:-/tmp}/tkoc-test.XXXXXX")"
trap 'rm -rf -- "$TEST_AREA"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [[ -f "$1" ]] || fail "missing file: $1"
}

export TKOC_TEST_ROOT="$TEST_AREA/root"
export TKOC_DNS4="192.0.2.53"

"$PROJECT_ROOT/bin/tkoc" check
grep -Fq 'udp dport { 137, 138, 1716, 1900, 27036, 5353, 5355 }' \
    "$PROJECT_ROOT/config/nftables.conf" \
    || fail "LAN discovery ports are not blocked"
grep -Fq 'ip protocol igmp' "$PROJECT_ROOT/config/nftables.conf" \
    || fail "IGMP is not blocked"

mkdir -p "$TKOC_TEST_ROOT/etc/sysctl.d" \
    "$TKOC_TEST_ROOT/usr/local/bin" \
    "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/sysctl.d"
printf 'old firewall\n' >"$TKOC_TEST_ROOT/etc/nftables.conf"
printf 'old sysctl\n' >"$TKOC_TEST_ROOT/etc/sysctl.d/60-tkoc-hardening.conf"
printf 'old command\n' >"$TKOC_TEST_ROOT/usr/local/bin/tkoc"
printf 'old template\n' >"$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/nftables.conf"
printf 'old template sysctl\n' \
    >"$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/sysctl.d/60-tkoc-hardening.conf"

"$PROJECT_ROOT/bin/tkoc" install

assert_file "$TKOC_TEST_ROOT/etc/nftables.conf"
assert_file "$TKOC_TEST_ROOT/etc/sysctl.d/60-tkoc-hardening.conf"
assert_file "$TKOC_TEST_ROOT/usr/local/bin/tkoc"
assert_file "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/nftables.conf"
assert_file "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/ice/packages.conf"

grep -Fq 'define ALLOWED_DNS4 = { 192.0.2.53 }' \
    "$TKOC_TEST_ROOT/etc/nftables.conf" \
    || fail "TKOC_DNS4 was not written to the staged firewall"
cmp "$TKOC_TEST_ROOT/etc/nftables.conf" \
    "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/nftables.conf"
cmp "$PROJECT_ROOT/config/sysctl.d/60-tkoc-hardening.conf" \
    "$TKOC_TEST_ROOT/etc/sysctl.d/60-tkoc-hardening.conf"
cmp "$PROJECT_ROOT/config/ice/packages.conf" \
    "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/ice/packages.conf"

"$PROJECT_ROOT/bin/tkoc" ice --dry-run >"$TEST_AREA/ice.out"
grep -Fq 'ttf-nerd-fonts-symbols-mono' "$TEST_AREA/ice.out" \
    || fail "ice dry run did not list its package"
grep -Fq 'no packages were installed' "$TEST_AREA/ice.out" \
    || fail "ice dry run did not confirm that it was non-mutating"

"$PROJECT_ROOT/bin/tkoc" status
"$PROJECT_ROOT/bin/tkoc" gut --dry-run >"$TEST_AREA/gut.out"
grep -Fq 'DHCP is preserved' "$TEST_AREA/gut.out" \
    || fail "gut did not explain its DHCP exception"
grep -Fq 'no services were disabled and no packages were removed' "$TEST_AREA/gut.out" \
    || fail "gut dry run did not confirm that it was non-mutating"
"$PROJECT_ROOT/bin/tkoc" audit >"$TEST_AREA/audit.out" 2>&1 || true
grep -Fq 'Trust No One posture audit' "$TEST_AREA/audit.out" \
    || fail "posture audit did not run"
grep -Fq 'summary:' "$TEST_AREA/audit.out" \
    || fail "posture audit did not produce a summary"
"$PROJECT_ROOT/bin/tkoc" doctor >"$TEST_AREA/doctor.out" 2>&1 || true
grep -Fq 'System health and driver assessment (read-only)' "$TEST_AREA/doctor.out" \
    || fail "system health and driver assessment did not run"
grep -Fq 'no filesystems were repaired, SMART tests started, or drivers installed' \
    "$TEST_AREA/doctor.out" \
    || fail "doctor did not confirm that it was non-mutating"

(
    # Source the command and replace lspci with a deterministic hardware fixture.
    source "$PROJECT_ROOT/bin/tkoc"
    TEST_ROOT=""
    lspci() {
        cat <<'EOF'
0000:01:00.0 Ethernet controller [0200]: Example wired adapter [1234:0001]
	Kernel driver in use: r8169
	Kernel modules: r8169
0000:02:00.0 Network controller [0280]: Example wireless adapter [1234:0002]
	Kernel modules: iwlwifi
0000:03:00.0 Audio device [0403]: Example unknown device [1234:0003]
EOF
    }
    audit_pci_driver_bindings
) >"$TEST_AREA/drivers.out"
grep -Fq 'PASS  r8169 is bound to' "$TEST_AREA/drivers.out" \
    || fail "driver assessment missed a bound kernel driver"
grep -Fq 'candidate module(s): iwlwifi' "$TEST_AREA/drivers.out" \
    || fail "driver assessment missed an unbound candidate module"
grep -Fq 'FAIL  no kernel driver or candidate module was found' \
    "$TEST_AREA/drivers.out" \
    || fail "driver assessment missed unsupported hardware"

(
    source "$PROJECT_ROOT/bin/tkoc"
    TEST_ROOT=""
    lspci() {
        printf '%s\n' \
            '0000:01:00.0 VGA compatible controller [0300]: NVIDIA Corporation Example GPU [10de:0001]'
    }
    modinfo() {
        if [[ ${1:-} == -n ]]; then
            printf '/usr/lib/modules/test/nvidia.ko.zst\n'
        elif [[ ${1:-} == -F && ${2:-} == version ]]; then
            printf '999.1\n'
        fi
        return 0
    }
    pacman() {
        [[ ${1:-} == -Qqo ]] && printf 'linux-test-nvidia-open\n'
        return 0
    }
    nvidia-smi() {
        printf 'NVIDIA-SMI failed to communicate with the driver\n'
        return 9
    }
    journalctl() {
        return 0
    }
    audit_graphics_driver_stack
) >"$TEST_AREA/nvidia.out"
grep -Fq 'FAIL  nvidia-smi cannot communicate with the NVIDIA driver' \
    "$TEST_AREA/nvidia.out" \
    || fail "NVIDIA assessment did not handle a failing nvidia-smi"
if grep -Fq 'AMD graphics stack' "$TEST_AREA/nvidia.out"; then
    fail "NVIDIA compatible-controller text was mistaken for ATI hardware"
fi

[[ $("$PROJECT_ROOT/bin/tkoc" backups | wc -l | tr -d ' ') == 1 ]] \
    || fail "expected exactly one backup"
"$PROJECT_ROOT/bin/tkoc" rollback latest

grep -Fxq 'old firewall' "$TKOC_TEST_ROOT/etc/nftables.conf" \
    || fail "rollback did not restore nftables config"
grep -Fxq 'old sysctl' "$TKOC_TEST_ROOT/etc/sysctl.d/60-tkoc-hardening.conf" \
    || fail "rollback did not restore sysctl config"
grep -Fxq 'old command' "$TKOC_TEST_ROOT/usr/local/bin/tkoc" \
    || fail "rollback did not restore installed command"
grep -Fxq 'old template' "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/nftables.conf" \
    || fail "rollback did not restore bundled config"

printf 'ok - isolated install and rollback\n'
