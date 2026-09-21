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

# dotfiles/theme are user-scoped (they never consult TKOC_TEST_ROOT), so
# sandbox them by overriding HOME and both XDG variables explicitly --
# an ambient XDG_CONFIG_HOME/XDG_STATE_HOME in the developer's own shell
# must never leak through to these commands during the test run.
export HOME="$TEST_AREA/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_STATE_HOME="$HOME/.local/state"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_STATE_HOME"

"$PROJECT_ROOT/bin/tkoc" check
"$PROJECT_ROOT/bin/tkoc" help >"$TEST_AREA/help.out"
grep -Fq 'dotfiles set-theme' "$TEST_AREA/help.out" \
    || fail "top-level help did not list dotfiles set-theme"
grep -Fq 'theme set <name>' "$TEST_AREA/help.out" \
    || fail "top-level help did not list theme set"
"$PROJECT_ROOT/bin/tkoc" install --help >"$TEST_AREA/install-help.out"
grep -Fq 'Usage: sudo tkoc install' "$TEST_AREA/install-help.out" \
    || fail "tkoc install --help did not show detailed help"
"$PROJECT_ROOT/bin/tkoc" theme --help >"$TEST_AREA/theme-help.out"
grep -Fq 'tkoc theme set <name>' "$TEST_AREA/theme-help.out" \
    || fail "tkoc theme --help did not show detailed help"
if "$PROJECT_ROOT/bin/tkoc" bogus --help >/dev/null 2>&1; then
    fail "an unknown command with --help should still fail"
fi

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
assert_file "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/dotfiles/environment.conf"
assert_file "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/dotfiles/bashrc.block"
assert_file "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/dotfiles/shell.d/00-environment.sh"
assert_file "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/dotfiles/prompt-themes/arch.conf"
assert_file "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/theme/kde.conf"
assert_file "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/theme/presets/nord.conf"

grep -Fq 'define ALLOWED_DNS4 = { 192.0.2.53 }' \
    "$TKOC_TEST_ROOT/etc/nftables.conf" \
    || fail "TKOC_DNS4 was not written to the staged firewall"
cmp "$TKOC_TEST_ROOT/etc/nftables.conf" \
    "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/nftables.conf"
cmp "$PROJECT_ROOT/config/sysctl.d/60-tkoc-hardening.conf" \
    "$TKOC_TEST_ROOT/etc/sysctl.d/60-tkoc-hardening.conf"
cmp "$PROJECT_ROOT/config/ice/packages.conf" \
    "$TKOC_TEST_ROOT/usr/local/lib/tkoc/config/ice/packages.conf"

# An installed tkoc reads its sources from the staging directory. Reinstalling
# from that command must not copy the staged files or executable onto itself.
INSTALLED_TEST_ROOT="$TEST_AREA/installed-root"
TKOC_TEST_ROOT="$INSTALLED_TEST_ROOT" TKOC_DNS4="$TKOC_DNS4" \
    "$PROJECT_ROOT/bin/tkoc" install >"$TEST_AREA/installed-first.out"
TKOC_TEST_ROOT="$INSTALLED_TEST_ROOT" TKOC_DNS4="$TKOC_DNS4" \
    "$INSTALLED_TEST_ROOT/usr/local/bin/tkoc" install \
    >"$TEST_AREA/installed-second.out"
grep -Fq 'staged security baseline' "$TEST_AREA/installed-second.out" \
    || fail "installed tkoc could not stage its existing configuration again"

# Some distributions intentionally leave a successful one-shot nftables
# loader inactive after it exits. That state is healthy when it is enabled.
(
    source "$PROJECT_ROOT/bin/tkoc"
    systemctl() {
        case "$*" in
            'is-enabled --quiet nftables.service') return 0 ;;
            'is-active --quiet nftables.service') return 3 ;;
            'show nftables.service --property=Type --value') printf 'oneshot\n' ;;
            'show nftables.service --property=RemainAfterExit --value') printf 'no\n' ;;
            'show nftables.service --property=Result --value') printf 'success\n' ;;
            *) return 1 ;;
        esac
    }
    nftables_service_ready
) || fail "a successful inactive one-shot nftables loader was not accepted"

if (
    source "$PROJECT_ROOT/bin/tkoc"
    systemctl() {
        case "$*" in
            'is-enabled --quiet nftables.service') return 0 ;;
            'is-active --quiet nftables.service') return 3 ;;
            'show nftables.service --property=Type --value') printf 'simple\n' ;;
            'show nftables.service --property=RemainAfterExit --value') printf 'no\n' ;;
            'show nftables.service --property=Result --value') printf 'success\n' ;;
            *) return 1 ;;
        esac
    }
    nftables_service_ready
); then
    fail "an inactive non-one-shot nftables service was accepted"
fi

"$PROJECT_ROOT/bin/tkoc" ice --dry-run >"$TEST_AREA/ice.out"
grep -Fq 'ttf-nerd-fonts-symbols-mono' "$TEST_AREA/ice.out" \
    || fail "ice dry run did not list its package"
grep -Fq 'no packages were installed' "$TEST_AREA/ice.out" \
    || fail "ice dry run did not confirm that it was non-mutating"

"$PROJECT_ROOT/bin/tkoc" dotfiles --dry-run >"$TEST_AREA/dotfiles-dry.out"
grep -Fq 'would link: managed shell snippets' "$TEST_AREA/dotfiles-dry.out" \
    || fail "dotfiles dry run did not describe the shell snippet link"
grep -Fq 'dry run: no files were modified' "$TEST_AREA/dotfiles-dry.out" \
    || fail "dotfiles dry run did not confirm that it was non-mutating"
[[ ! -e "$XDG_CONFIG_HOME/tkoc/dotfiles/shell.d" ]] \
    || fail "dotfiles dry run created a symlink"

"$PROJECT_ROOT/bin/tkoc" dotfiles >"$TEST_AREA/dotfiles-apply.out"
[[ -L "$XDG_CONFIG_HOME/tkoc/dotfiles/shell.d" ]] \
    || fail "dotfiles did not link the shell snippet directory"
[[ "$(readlink -- "$XDG_CONFIG_HOME/tkoc/dotfiles/shell.d")" \
    == "$PROJECT_ROOT/config/dotfiles/shell.d" ]] \
    || fail "dotfiles linked the shell snippet directory to the wrong source"
[[ -L "$XDG_CONFIG_HOME/tkoc/dotfiles/environment.conf" ]] \
    || fail "dotfiles did not link the environment file"
grep -Fq '# >>> tkoc >>>' "$HOME/.bashrc" \
    || fail "dotfiles did not append the managed bashrc block"
bash -c "shopt -s expand_aliases; source '$HOME/.bashrc'; alias ll" \
    | grep -Fq "alias ll='ls -la'" \
    || fail "sourced bashrc did not define the managed ll alias"
bash -c "source '$HOME/.bashrc'; [[ \"\$EDITOR\" == nvim ]]" \
    || fail "sourced bashrc did not export the managed EDITOR variable"

"$PROJECT_ROOT/bin/tkoc" dotfiles >"$TEST_AREA/dotfiles-again.out"
grep -Fq 'already linked: managed shell snippets' "$TEST_AREA/dotfiles-again.out" \
    || fail "dotfiles re-run did not report the existing link as already linked"
grep -Fq 'already up to date' "$TEST_AREA/dotfiles-again.out" \
    || fail "dotfiles re-run did not report the bashrc block as already up to date"
[[ ! -d "$XDG_STATE_HOME/tkoc/backups" ]] \
    || fail "dotfiles re-run created a backup even though nothing changed"

rm -rf "$XDG_CONFIG_HOME/tkoc" "$HOME/.bashrc"
mkdir -p "$XDG_CONFIG_HOME/tkoc/dotfiles/shell.d"
printf 'pre-existing snippet\n' >"$XDG_CONFIG_HOME/tkoc/dotfiles/shell.d/custom.sh"
printf '# custom bashrc\nexport CUSTOM=1\n' >"$HOME/.bashrc"
"$PROJECT_ROOT/bin/tkoc" dotfiles >"$TEST_AREA/dotfiles-conflict.out"
grep -Fq 'backed up existing shell.d' "$TEST_AREA/dotfiles-conflict.out" \
    || fail "dotfiles did not back up a pre-existing shell.d directory before replacing it"
grep -Fxq 'export CUSTOM=1' "$HOME/.bashrc" \
    || fail "dotfiles clobbered pre-existing bashrc content"
find "$XDG_STATE_HOME/tkoc/backups" -mindepth 1 -maxdepth 1 -type d ! -name latest \
    -exec test -f {}/shell.d/custom.sh \; -print | grep -q . \
    || fail "dotfiles did not preserve the pre-existing snippet in its backup"

"$PROJECT_ROOT/bin/tkoc" dotfiles list-themes >"$TEST_AREA/dotfiles-list-themes.out"
grep -Fq 'macos' "$TEST_AREA/dotfiles-list-themes.out" \
    || fail "dotfiles list-themes did not include the macos theme"
grep -Fq '(current)' "$TEST_AREA/dotfiles-list-themes.out" \
    || fail "dotfiles list-themes did not mark the current selection"

"$PROJECT_ROOT/bin/tkoc" dotfiles set-theme terminal --dry-run \
    >"$TEST_AREA/dotfiles-set-theme-dry.out"
grep -Fq 'would select prompt theme: terminal' "$TEST_AREA/dotfiles-set-theme-dry.out" \
    || fail "dotfiles set-theme --dry-run did not describe the selection"

"$PROJECT_ROOT/bin/tkoc" dotfiles set-theme terminal >"$TEST_AREA/dotfiles-set-theme.out"
grep -Fq 'selected prompt theme: terminal' "$TEST_AREA/dotfiles-set-theme.out" \
    || fail "dotfiles set-theme did not report the new selection"
[[ "$(<"$XDG_STATE_HOME/tkoc/prompt-theme")" == terminal ]] \
    || fail "dotfiles set-theme did not persist the new selection"
bash -c "source '$HOME/.bashrc'; [[ -n \"\$ACCENT1\" ]]" \
    || fail "sourced bashrc did not load ACCENT1 after switching prompt themes"

if "$PROJECT_ROOT/bin/tkoc" dotfiles set-theme bogus-theme --dry-run >/dev/null 2>&1; then
    fail "dotfiles set-theme should reject an unknown theme name"
fi

# --- legacy prompt-theme migration: TKOC_DOTFILES_BACKUP=no ---
printf '%s\n' \
    '# start' \
    '# SECTION 3: THEME SYSTEM' \
    'legacy_theme_line=1' \
    '# SECTION 7: STARTUP COMMANDS' \
    '# end' \
    >"$HOME/.bashrc"
rm -f "$HOME/.bash_theme"

TKOC_DOTFILES_BACKUP=no "$PROJECT_ROOT/bin/tkoc" dotfiles >"$TEST_AREA/migrate-no-backup.out"
grep -Fq 'proceeding without a backup' "$TEST_AREA/migrate-no-backup.out" \
    || fail "migration did not honor TKOC_DOTFILES_BACKUP=no"
if grep -Fq 'legacy_theme_line=1' "$HOME/.bashrc"; then
    fail "migration did not strip the legacy theme section"
fi
grep -Fq '# start' "$HOME/.bashrc" || fail "migration removed content before the legacy section"
grep -Fq '# end' "$HOME/.bashrc" || fail "migration removed content after the legacy section"
[[ "$(<"$XDG_STATE_HOME/tkoc/prompt-theme")" == arch ]] \
    || fail "migration did not default to the arch theme when no .bash_theme file existed"

# --- legacy prompt-theme migration: TKOC_DOTFILES_BACKUP=yes, preserves selection ---
printf '%s\n' \
    '# start2' \
    '# SECTION 3: THEME SYSTEM' \
    'legacy_theme_line=2' \
    '# SECTION 7: STARTUP COMMANDS' \
    '# end2' \
    >"$HOME/.bashrc"
printf '7\n' >"$HOME/.bash_theme"
backups_before="$(find "$XDG_STATE_HOME/tkoc/backups" -mindepth 1 -maxdepth 1 -type d ! -name latest | wc -l)"

TKOC_DOTFILES_BACKUP=yes "$PROJECT_ROOT/bin/tkoc" dotfiles >"$TEST_AREA/migrate-with-backup.out"
grep -Fq 'backed up existing .bashrc' "$TEST_AREA/migrate-with-backup.out" \
    || fail "migration did not back up .bashrc when TKOC_DOTFILES_BACKUP=yes"
backups_after="$(find "$XDG_STATE_HOME/tkoc/backups" -mindepth 1 -maxdepth 1 -type d ! -name latest | wc -l)"
(( backups_after > backups_before )) \
    || fail "migration with backup=yes did not create a new backup"
[[ "$(<"$XDG_STATE_HOME/tkoc/prompt-theme")" == macos ]] \
    || fail "migration did not preserve the previously selected theme number (7 -> macos)"

"$PROJECT_ROOT/bin/tkoc" theme list >"$TEST_AREA/theme-list.out"
grep -Fq 'nord' "$TEST_AREA/theme-list.out" || fail "theme list did not include the nord preset"

"$PROJECT_ROOT/bin/tkoc" theme set nord --dry-run >"$TEST_AREA/theme-set-dry.out"
grep -Fq 'Utterly-Nord' "$TEST_AREA/theme-set-dry.out" \
    || fail "theme set --dry-run did not describe the nord preset"

if "$PROJECT_ROOT/bin/tkoc" theme set bogus-preset --dry-run >/dev/null 2>&1; then
    fail "theme set should reject an unknown preset name"
fi

"$PROJECT_ROOT/bin/tkoc" theme --dry-run >"$TEST_AREA/theme-dry.out"
grep -Fq 'LOOK_AND_FEEL' "$TEST_AREA/theme-dry.out" \
    || fail "theme dry run did not list a configured key"
grep -Fq 'dry run: no theme settings were changed' "$TEST_AREA/theme-dry.out" \
    || fail "theme dry run did not confirm that it was non-mutating"

(
    # Stub the KDE tools so this never touches a real Plasma session.
    source "$PROJECT_ROOT/bin/tkoc"
    kwriteconfig6() { printf '%s\n' "$*" >>"$TEST_AREA/kwriteconfig6.calls"; }
    kreadconfig6() { return 1; }
    plasma-apply-colorscheme() { printf '%s\n' "$*" >>"$TEST_AREA/plasma-apply-colorscheme.calls"; }
    apply_theme_color_scheme "BreezeDark"
    apply_theme_icon_theme "breeze-dark"
)
grep -Fq 'BreezeDark' "$TEST_AREA/plasma-apply-colorscheme.calls" \
    || fail "apply_theme_color_scheme did not invoke plasma-apply-colorscheme"
grep -Fq -- '--group Icons --key Theme breeze-dark' "$TEST_AREA/kwriteconfig6.calls" \
    || fail "apply_theme_icon_theme did not write the icon theme via kwriteconfig6"

(
    source "$PROJECT_ROOT/bin/tkoc"
    kreadconfig6() { printf 'breeze-dark\n'; }
    kwriteconfig6() { printf '%s\n' "$*" >>"$TEST_AREA/kwriteconfig6-noop.calls"; }
    apply_theme_icon_theme "breeze-dark"
)
[[ ! -e "$TEST_AREA/kwriteconfig6-noop.calls" ]] \
    || fail "apply_theme_icon_theme rewrote an already-current value"

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
