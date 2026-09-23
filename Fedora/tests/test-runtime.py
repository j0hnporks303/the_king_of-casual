#!/usr/bin/env python3
"""Exercise installed commands with disposable homes and fake system tools."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tkoc-runtime-")
        self.addCleanup(self.temp.cleanup)
        self.area = Path(self.temp.name)
        self.home = self.area / "home"
        self.bin = self.area / "bin"
        self.root = self.area / "root"
        for path in (self.home, self.bin, self.root / "etc"):
            path.mkdir(parents=True)
        (self.root / "etc/os-release").write_text('ID=fedora\nVERSION_ID=44\n')
        # Do not inherit a user's TKOC flags, snapshots, XDG paths or shell hooks.
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "XDG_STATE_HOME": str(self.home / ".local/state"),
            "TKOC_STATE_HOME": str(self.home / ".local/state/tkoc"),
            "TKOC_TEST_ROOT": str(self.root),
            "TERM": "dumb",
            "LC_ALL": "C",
            "TEST_CALLS": str(self.area / "calls"),
        }
        self.cli = PROJECT / "tools/tkoc.sh"
        for tool in ("sudo", "clamscan", "modinfo"):
            self.stub(tool, 'printf "%s %s\\n" "$0" "$*" >> "$TEST_CALLS"; exit 97')
        self.stub("systemctl", '''case "$*" in
            list-unit-files*) exit 0 ;;
            is-enabled*) printf 'disabled\\n'; exit 1 ;;
            is-active*) exit 3 ;;
            *) printf 'systemctl %s\\n' "$*" >> "$TEST_CALLS"; exit 97 ;;
        esac''')
        self.stub("nft", "exit 1")
        # Read-only queries in these programs can create their own caches.
        # Keep external programs deterministic and inside this fixture.
        self.stub("flatpak", "exit 0")
        self.stub("fwupdmgr", "echo 'No updates available'; exit 2")
        self.stub("nmcli", '''case "$*" in
            *'dev wifi list'*) printf 'yes:Home:WiFi\\n' ;;
            *'connection show --active')
                printf 'wired-uuid:802-3-ethernet:eth0\\nwifi-uuid:802-11-wireless:wlan0\\n' ;;
            '-g ipv4.dns connection show -- '*) printf '%s\\n' "${TEST_DNS:-}" ;;
            '-g ipv4.ignore-auto-dns connection show -- '*) printf '%s\\n' "${TEST_IGNORE:-no}" ;;
            '-g ipv6.method connection show -- '*) printf '%s\\n' "${TEST_IPV6:-disabled}" ;;
            '-g ipv4.dns,ipv4.ignore-auto-dns connection show -- '*)
                printf '%s\\n%s\\n' "${TEST_DNS:-}" "${TEST_IGNORE:-no}" ;;
            *) printf 'nmcli'; printf ' <%s>' "$@"; printf '\\n' ;;
        esac''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_process(self, args, *, expected=0, env=None, cwd=None, input_text=None):
        result = subprocess.run(
            [str(arg) for arg in args], env=self.env | (env or {}),
            cwd=cwd or self.home,
            **({"input": input_text} if input_text is not None
               else {"stdin": subprocess.DEVNULL}),
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30,
        )
        self.assertEqual(result.returncode, expected, result.stdout)
        return result.stdout

    def cli_run(self, *args, **kwargs):
        return self.run_process(["bash", self.cli, *args], **kwargs)

    def no_system_calls(self):
        calls = Path(self.env["TEST_CALLS"])
        self.assertFalse(calls.exists(), calls.read_text() if calls.exists() else "")

    def test_install_runs_outside_checkout_with_an_unrelated_home(self):
        checkout = self.area / "relocated"
        checkout.mkdir()
        for name in ("tools", "stages", "config"):
            shutil.copytree(PROJECT / name, checkout / name)
        shutil.copy2(PROJECT / "Makefile", checkout / "Makefile")
        destination = self.area / "linked bin"
        self.run_process(["make", "-C", checkout, f"BIN_DIR={destination}", "install"])
        output = self.run_process([destination / "tkoc", "help"])
        self.assertIn("Fedora edition", output)
        self.run_process(["make", "-C", checkout, f"BIN_DIR={destination}", "check"])
        # A relative link to another relative link must work as well.
        (self.area / "hop").symlink_to("linked bin/tkoc")
        (self.bin / "tkoc").symlink_to("../hop")
        self.assertIn("Privacy categories", self.run_process([self.bin / "tkoc", "privacy", "list"]))
        self.no_system_calls()

    def test_bare_firewall_defaults_to_status(self):
        self.assertIn("Installed policy", self.cli_run("firewall"))

    def test_inbound_check_uses_drop_counter_without_changing_rules(self):
        self.stub("sudo", '''case "$*" in
            'nft list counter inet tkoc_host input_dropped')
                count_file="$TKOC_TEST_ROOT/counter-reads"
                if [[ -e "$count_file" ]]; then count=4; else count=3; fi
                touch "$count_file"
                printf 'table inet tkoc_host {\\n counter input_dropped {\\n packets %s bytes 0\\n }\\n}\\n' "$count"
                ;;
            *) exit 97 ;;
        esac''')
        output = self.cli_run("firewall", "test", "--inbound-check", "65000",
                              input_text="\n")
        self.assertIn("1 new drop(s)", output)
        self.assertIn("Other inbound traffic may also have contributed", output)
        self.assertNotIn("public address", output)
        self.no_system_calls()

    def test_firewall_status_never_prompts_to_read_boot_config(self):
        config = self.root / "etc/sysconfig/nftables.conf"
        config.parent.mkdir()
        config.write_text('include "/etc/nftables/tkoc.nft"\n')
        config.chmod(0)
        try:
            out = self.cli_run("firewall")
            self.assertIn("include wired up", out)
            self.assertNotIn("unexpected sudo", out)
        finally:
            config.chmod(0o600)

    def test_firewall_audit_distinguishes_inaccessible_from_missing(self):
        script = '''source "$1/stages/lib/common.sh"
            source "$1/stages/lib/audit.sh"
            audit_firewall_state
            printf 'failures=%s\\n' "$AUDIT_FAIL"
        '''
        self.stub("systemctl", "echo 'Failed to connect to bus' >&2; exit 1")
        self.stub("nft", "echo 'Operation not permitted' >&2; exit 1")
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT])
        self.assertIn("failures=0", out)
        self.assertIn("needs privilege", out)
        self.assertIn("firewalld state could not be verified", out)
        self.stub("nft", "echo 'No such file or directory' >&2; exit 1")
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT])
        self.assertIn("failures=1", out)
        self.assertIn("firewall table is not loaded", out)

    def test_command_help_is_successful_and_read_only(self):
        commands = ["check", "status", "doctor", "audit", "harden", "firewall", "privacy",
                    "state", "update", "uninstall", "install", "ice", "dotfiles", "theme",
                    "clamav", "wg", "vm", "uav", "fs", "pgp", "link", "killall"]
        for command in commands:
            with self.subTest(command=command):
                self.assertIn("Usage:", self.cli_run(command, "--help"))
        self.no_system_calls()
        self.assertFalse(any(self.home.iterdir()))

    def test_privacy_default_level_accepts_preview_options(self):
        for args in (("apply", "--dry-run"), ("--dry-run",), ("run", "basic", "--dry-run")):
            with self.subTest(args=args):
                out = self.cli_run("privacy", *args)
                self.assertIn("Privacy hardening complete", out)
        self.no_system_calls()
        self.assertFalse(any(self.home.iterdir()))

    def test_wireguard_previews_never_start_or_stop_a_tunnel(self):
        for args in (("up", "--dry-run"), ("up", "wg1", "--dry-run"), ("down", "wg1", "-n")):
            with self.subTest(args=args):
                self.assertIn("[dry-run]", self.cli_run("wg", *args))
        self.cli_run("wg", "up", "../../bad", "--dry-run", expected=1)
        self.cli_run("wg", "up", "wg0", "--typo", expected=1)
        self.no_system_calls()

    def test_clamav_previews_preserve_timer_and_do_not_run_scans(self):
        units = self.home / ".config/systemd/user"
        units.mkdir(parents=True)
        for suffix in ("timer", "service"):
            (units / f"tkoc-clamav.{suffix}").write_text("original")
        self.assertIn("[dry-run]", self.cli_run("clamav", "uninstall-daily", "--dry-run"))
        self.assertIn("[dry-run]", self.cli_run("clamav", "scan", self.home, "--dry-run"))
        for suffix in ("timer", "service"):
            self.assertEqual((units / f"tkoc-clamav.{suffix}").read_text(), "original")
        self.cli_run("clamav", "uninstall-daily", "--typo", expected=1)
        self.cli_run("clamav", "typo", expected=1)
        self.no_system_calls()

    def test_dnf_reports_small_and_large_update_sets_without_exiting_early(self):
        self.stub("dnf", '''for ((i=0; i<${TEST_UPDATES:-1}; i++)); do
            printf 'package-%s.x86_64 2.0 updates\\n' "$i"
        done
        exit 100''')
        for count in (1, 15, 16, 3000):
            with self.subTest(count=count):
                output = self.cli_run("update", "--dnf", "--dry-run", env={"TEST_UPDATES": str(count)})
                self.assertIn(f"{count} package(s)", output)
                self.assertIn("dry run: nothing was applied", output)
        self.no_system_calls()

    def test_failed_update_queries_are_not_reported_as_up_to_date(self):
        for tool, option in (("dnf", "--dnf"), ("flatpak", "--flatpak"), ("fwupdmgr", "--firmware")):
            with self.subTest(tool=tool):
                self.stub(tool, "echo 'test: metadata unavailable' >&2; exit 1")
                out = self.cli_run("update", option, "--dry-run", expected=1)
                self.assertIn("metadata unavailable", out)
                self.assertIn("nothing was applied", out)
                self.assertNotIn("everything is up to date", out)
        self.no_system_calls()

    def test_firmware_report_handles_no_updates_and_mixed_devices(self):
        self.stub("fwupdmgr", "echo 'No updates available'; exit 2")
        self.assertIn("everything is up to date", self.cli_run("update", "--firmware", "--dry-run"))
        self.stub("fwupdmgr", "echo 'Devices with no available firmware updates: disk'; echo 'BIOS upgrade available'")
        self.assertIn("dry run: nothing was applied", self.cli_run("update", "--firmware", "--dry-run"))

    def test_default_network_profile_preserves_empty_dns(self):
        output = self.cli_run("firewall", "auto", "--dry-run")
        self.assertIn("leave as DHCP provides", output)
        self.assertIn("ipv6:       disabled", output)
        self.assertFalse(any(self.home.iterdir()))
        self.no_system_calls()

    def test_ssid_with_colons_and_dispatcher_interface_select_the_right_profile(self):
        profiles = self.area / "profiles.json"
        profiles.write_text(json.dumps({"profiles": [
            {"ssid": "Home:WiFi", "name": "test wifi", "dns": "192.0.2.53", "ipv6": "enabled"}
        ]}))
        output = self.cli_run("firewall", "auto", "--dry-run", env={
            "TKOC_NETWORK_PROFILES": str(profiles), "TKOC_NETWORK_INTERFACE": "wlan0"})
        self.assertIn("connection: wifi-uuid", output)
        self.assertIn("profile:    test wifi", output)
        self.assertIn("192.0.2.53", output)

    def test_matching_network_profile_does_not_reactivate_connection(self):
        output = self.cli_run("firewall", "auto", "--yes")
        self.assertIn("already applied", output)
        self.assertNotIn("<modify>", output)
        self.assertNotIn("<up>", output)
        self.assertFalse(any(self.home.iterdir()))

    def test_dhcp_profile_clears_previously_pinned_dns(self):
        output = self.cli_run("firewall", "auto", "--yes", env={"TEST_DNS": "192.0.2.53", "TEST_IGNORE": "yes"})
        self.assertIn("<ipv4.dns> <>", output)
        self.assertIn("<ipv4.ignore-auto-dns> <no>", output)
        self.assertIn("profile 'default' applied", output)

    def test_installed_network_watcher_has_its_libraries_and_config(self):
        self.cli_run("firewall", "watch", "install", "--yes")
        watch = self.root / "usr/local/libexec/tkoc/network-watch"
        helper = watch / "tools/network-profile.sh"
        self.assertIn("Usage:", self.run_process(["bash", helper, "--help"]))
        self.assertIn("leave as DHCP provides", self.run_process(["bash", helper, "--dry-run"]))
        for name in ("common", "state"):
            self.assertTrue((watch / f"stages/lib/{name}.sh").is_file())
        self.cli_run("firewall", "watch", "uninstall", "--yes")
        self.assertFalse(helper.exists())
        self.assertFalse((self.root / "etc/NetworkManager/dispatcher.d/90-tkoc-network-watch").exists())
        self.no_system_calls()

    def test_link_uses_the_requested_destination_and_needs_no_sudo_in_home(self):
        # Exercise the actual ownership check, not the TKOC_TEST_ROOT bypass.
        env = {"TKOC_TEST_ROOT": ""}
        source = self.area / "example.sh"
        source.write_text("#!/bin/sh\nexit 0\n")
        source.chmod(0o755)
        destination = self.home / "bin/example"
        self.cli_run("link", source, destination, env=env)
        self.assertTrue(destination.is_symlink())
        self.assertIn(str(destination), self.cli_run("link", "list", env=env))
        self.cli_run("link", "unlink", "example", env=env)
        self.assertFalse(destination.exists())
        self.assertIn("no links", self.cli_run("link", "--bin", destination.parent, "list", env=env))
        self.no_system_calls()

    def test_unlink_refuses_to_delete_a_replacement_file(self):
        source = self.bin / "clamscan"
        destination = self.home / "example"
        self.cli_run("link", source, destination)
        destination.unlink()
        destination.write_text("replacement")
        self.cli_run("link", "unlink", "example", expected=1)
        self.assertEqual(destination.read_text(), "replacement")

    def test_privacy_helpers_do_not_crash_without_optional_labels(self):
        body = '''source "$1/stages/lib/hardening-common.sh"
            hc_set_config "$2/new.conf" main sample value
            hc_drop_in "$2/unit.d" override.conf example
            hc_set_kconfig test-rc Main sample value
            hc_set_sysctl net.ipv4.ip_forward 1
        '''
        self.run_process(["bash", "-euc", body, "bash", PROJECT, self.area], env={"TKOC_DRY_RUN": "enabled"})
        self.no_system_calls()
        self.assertFalse((self.area / "new.conf").exists())

    def test_nouveau_report_distinguishes_missing_proprietary_driver(self):
        self.stub("lspci", "printf '0000:2b:00.0 VGA compatible controller: NVIDIA RTX 3080\\n\\tKernel driver in use: nouveau\\n'")
        out = self.run_process(["bash", "-euc", '''source "$1/stages/lib/common.sh"
            source "$1/stages/lib/audit.sh"
            audit_nvidia_stack
            (( AUDIT_FAIL == 0 ))
            (( AUDIT_WARN == 1 ))
        ''', "bash", PROJECT])
        self.assertIn("Nouveau driver", out)
        self.assertIn("proprietary NVIDIA driver is not installed", out)

    def test_normal_btrfs_startup_is_not_reported_as_corruption(self):
        self.stub("findmnt", "exit 0")
        self.stub("journalctl", "echo 'BTRFS info (device dm-0): using crc32c checksum algorithm'")
        script = '''source "$1/stages/lib/common.sh"
            source "$1/stages/lib/audit.sh"
            audit_filesystem_health
        '''
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT], env={"TKOC_TEST_ROOT": ""})
        self.assertIn("no filesystem corruption", out)
        self.stub("journalctl", "echo 'BTRFS error (device dm-0): checksum mismatch'")
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT], env={"TKOC_TEST_ROOT": ""})
        self.assertIn("1 filesystem or unclean-shutdown warning", out)


if __name__ == "__main__":
    unittest.main(verbosity=2)
