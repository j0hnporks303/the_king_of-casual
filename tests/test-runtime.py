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


    # ── Root-only directories, snapshots and rollback ───────────────
    #
    # /etc/wireguard and /etc/nftables are 0700 root on Fedora. To an ordinary
    # user every file inside them looks absent, which is how a re-run came to
    # replace a WireGuard key and how a snapshot came to record a loaded
    # firewall policy as "missing". These tests stand a user-owned directory in
    # for those, locked with mode 000, and a fake sudo that unlocks it only for
    # the duration of each command it runs -- the same view root has.

    def unlocking_sudo(self, locked):
        self.stub("sudo", f"""printf '%s\\n' "$*" >> "{self.area}/sudo.log"
            [ "${{1:-}}" = -n ] && shift
            chmod 700 "{locked}"
            rc=0; "$@" || rc=$?
            chmod 000 "{locked}"
            exit "$rc" """)

    def locked_dir(self, name="locked"):
        if os.geteuid() == 0:
            self.skipTest("root can look into every directory")
        locked = self.area / name
        locked.mkdir()
        self.addCleanup(locked.chmod, 0o700)
        return locked

    def test_wireguard_never_replaces_an_existing_key_or_config(self):
        wg_dir = self.root / "etc/wireguard"
        wg_dir.mkdir()
        (wg_dir / "wg0.key").write_text("EXISTING-PRIVATE-KEY\n")
        (wg_dir / "wg0.conf").write_text("[Interface]\n[Peer]\nEndpoint = vpn.example:51820\n")
        self.stub("rpm", "exit 0")
        self.stub("wg", 'case "$1" in genkey) echo NEW-KEY ;; pubkey) cat >/dev/null; echo NEW-PUB ;; esac')
        out = self.run_process(["bash", PROJECT / "stages/45-wireguard.sh", "--yes"])
        self.assertIn("keypair already exists", out)
        self.assertIn("config already exists", out)
        self.assertEqual((wg_dir / "wg0.key").read_text(), "EXISTING-PRIVATE-KEY\n")
        self.assertIn("Endpoint = vpn.example", (wg_dir / "wg0.conf").read_text())
        # A fresh machine still gets a private keypair and a stub.
        for name in ("wg0.key", "wg0.conf"):
            (wg_dir / name).unlink()
        self.run_process(["bash", PROJECT / "stages/45-wireguard.sh", "--yes"])
        self.assertEqual((wg_dir / "wg0.key").read_text(), "NEW-KEY\n")
        self.assertIn("PrivateKey = NEW-KEY", (wg_dir / "wg0.conf").read_text())
        self.assertEqual((wg_dir / "wg0.key").stat().st_mode & 0o777, 0o600)
        self.assertEqual((wg_dir / "wg0.conf").stat().st_mode & 0o777, 0o600)
        self.no_system_calls()

    def test_root_path_state_never_reports_an_unseen_path_as_absent(self):
        locked = self.locked_dir()
        (locked / "present").write_text("x")
        locked.chmod(0)
        script = r"""source "$1/stages/lib/common.sh"
            for name in present absent; do
              printf '%s=%s\n' "$name" "$(root_path_state "$2/$name" quiet)"
            done"""
        env = {"TKOC_TEST_ROOT": ""}
        self.stub("sudo", "exit 1")  # no cached credential
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT, locked], env=env)
        self.assertIn("present=unknown", out)
        self.assertIn("absent=unknown", out)
        self.unlocking_sudo(locked)
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT, locked], env=env)
        self.assertIn("present=present", out)
        self.assertIn("absent=absent", out)

    def test_snapshots_record_and_restore_files_inside_root_only_directories(self):
        locked = self.locked_dir()
        policy = locked / "policy"
        policy.write_text("OLD\n")
        policy.chmod(0o640)
        locked.chmod(0)
        self.unlocking_sudo(locked)
        script = r"""source "$1/stages/lib/common.sh"; source "$1/stages/lib/state.sh"
            tkoc_state_begin test >/dev/null
            snap="$TKOC_ACTIVE_SNAPSHOT"
            tkoc_state_capture_file "$2/policy"
            tkoc_state_capture_file "$2/created"
            tkoc_state_finish
            printf 'kinds=%s\n' "$(cut -f3 "$snap/manifest.tsv" | paste -sd, -)"
            sudo sh -c 'printf "NEW\n" > "$1/policy"; chmod 600 "$1/policy"; : > "$1/created"' sh "$2"
            tkoc_state_restore "$snap"
            sudo sh -c 'printf "content=%s mode=%s\n" "$(cat "$1/policy")" "$(stat -c %a "$1/policy")"
              if [ -e "$1/created" ]; then echo created=left; else echo created=removed; fi' sh "$2" """
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT, locked],
                               env={"TKOC_TEST_ROOT": ""})
        self.assertIn("kinds=file,missing", out)
        self.assertIn("content=OLD mode=640", out)
        self.assertIn("created=removed", out)
        # A snapshot from before privileged capture recorded every file in a
        # root-only directory as "missing", loaded firewall policy included.
        # Its word is not enough to delete one.
        legacy = r"""source "$1/stages/lib/common.sh"; source "$1/stages/lib/state.sh"
            tkoc_state_begin test >/dev/null
            snap="$TKOC_ACTIVE_SNAPSHOT"
            tkoc_state_capture_file "$2/created"
            tkoc_state_finish
            sed -i '/^capture=/d' "$snap/meta"
            sudo sh -c ': > "$1/created"' sh "$2"
            tkoc_state_restore "$snap"
            sudo sh -c 'if [ -e "$1/created" ]; then echo created=left; else echo created=removed; fi' sh "$2" """
        out = self.run_process(["bash", "-euc", legacy, "bash", PROJECT, locked],
                               env={"TKOC_TEST_ROOT": ""})
        self.assertIn("created=left", out)
        self.assertIn("predates privileged capture", out)
        # Without a way to look, the capture refuses rather than guessing.
        self.stub("sudo", "exit 1")
        refused = r"""source "$1/stages/lib/common.sh"; source "$1/stages/lib/state.sh"
            tkoc_state_begin test >/dev/null
            if tkoc_state_capture_file "$2/policy"; then echo captured; else echo refused; fi"""
        out = self.run_process(["bash", "-euc", refused, "bash", PROJECT, locked],
                               env={"TKOC_TEST_ROOT": ""})
        self.assertIn("refused", out)

    def test_restore_replaces_the_firewall_table_and_never_flushes_the_ruleset(self):
        log, nft_input = self.area / "sudo.log", self.area / "nft.stdin"
        self.stub("sudo", f"""printf '%s\\n' "$*" >> "{log}"
            if [ "$*" = "nft -f -" ]; then cat > "{nft_input}"; fi""")
        # The capture order of a first tier: firewalld displaced, the table
        # recorded, then nftables.service enabled.
        script = r"""source "$1/stages/lib/common.sh"; source "$1/stages/lib/state.sh"
            tkoc_state_begin test >/dev/null
            snap="$TKOC_ACTIVE_SNAPSHOT"
            tkoc_state_manifest_append 'firewalld\t%s\t%s\t%s\t%s\n' firewalld enabled active no
            tkoc_state_manifest_append 'nftables\t%s\t%s\t%s\n' "$(tkoc_b64_encode 'inet tkoc_host')" yes \
              "$(tkoc_b64_encode 'table inet tkoc_host { }')"
            tkoc_state_manifest_append 'systemd\t%s\t%s\t%s\t%s\n' "$(tkoc_b64_encode nftables.service)" \
              disabled inactive no
            tkoc_state_finish
            tkoc_state_restore "$snap" """
        self.run_process(["bash", "-euc", script, "bash", PROJECT])
        calls = log.read_text().splitlines()
        # Stopping nftables.service runs `nft flush ruleset`: firewalld's rules too.
        self.assertNotIn("systemctl stop -- nftables.service", calls)
        # Newest first: nftables.service, then the table, then firewalld back.
        self.assertLess(calls.index("systemctl disable -- nftables.service"), calls.index("nft -f -"))
        self.assertLess(calls.index("nft -f -"), calls.index("systemctl start -- firewalld.service"))
        # Replayed onto a live table a dump is merged, so it must replace it.
        self.assertEqual(nft_input.read_text().splitlines()[0], "destroy table inet tkoc_host")

    def test_firewall_capture_never_records_an_unreadable_table_as_absent(self):
        self.stub("sudo", "exit 1")
        script = r"""source "$1/stages/lib/common.sh"; source "$1/stages/lib/state.sh"
            tkoc_state_begin test >/dev/null
            if tkoc_state_capture_nftables "inet tkoc_host"; then echo captured; else echo refused; fi
            printf 'records=%s\n' "$(wc -l < "$TKOC_ACTIVE_SNAPSHOT/manifest.tsv")" """
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT], env={"TKOC_TEST_ROOT": ""})
        self.assertIn("refused", out)
        self.assertIn("records=0", out)

    def test_new_drop_ins_are_recorded_and_their_directories_stay_readable(self):
        script = r"""umask 022
            source "$1/stages/lib/hardening-common.sh"
            tkoc_state_begin test >/dev/null
            snap="$TKOC_ACTIVE_SNAPSHOT"
            printf 'umask=%s\n' "$(umask)"
            hc_drop_in "$TKOC_TEST_ROOT/etc/resolved.conf.d" 90-tkoc.conf '[Resolve]' resolved >/dev/null
            tkoc_state_finish
            printf 'dir-mode=%s\n' "$(tkoc_stat mode "$TKOC_TEST_ROOT/etc/resolved.conf.d")"
            tkoc_state_restore "$snap"
            if [[ -e "$TKOC_TEST_ROOT/etc/resolved.conf.d/90-tkoc.conf" ]]; then
              echo drop-in=left
            else
              echo drop-in=removed
            fi"""
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT])
        # The snapshot's private umask must not leak into the rest of the run.
        self.assertIn("umask=0022", out)
        self.assertIn("dir-mode=755", out)
        self.assertIn("drop-in=removed", out)

    # ── Privacy categories doing what their report says ─────────────

    def test_unreadable_drop_in_directories_are_repaired_and_recorded(self):
        drop_ins = self.root / "etc/resolved.conf.d"
        drop_ins.mkdir(parents=True)
        (drop_ins / "90-tkoc.conf").write_text("[Resolve]\n")
        drop_ins.chmod(0o700)
        script = r"""source "$1/stages/lib/hardening-common.sh"
            tkoc_state_begin test >/dev/null
            snap="$TKOC_ACTIVE_SNAPSHOT"
            hc_drop_in "$TKOC_TEST_ROOT/etc/resolved.conf.d" 90-tkoc.conf '[Resolve]' resolved
            tkoc_state_finish
            printf 'repaired=%s\n' "$(tkoc_stat mode "$TKOC_TEST_ROOT/etc/resolved.conf.d")"
            tkoc_state_restore "$snap"
            printf 'restored=%s\n' "$(tkoc_stat mode "$TKOC_TEST_ROOT/etc/resolved.conf.d")" """
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT])
        # Readable to the unprivileged daemon, and the content was already right.
        self.assertIn("made", out)
        self.assertIn("already in place", out)
        self.assertIn("repaired=755", out)
        # A restore puts the exact prior mode back, as with anything else.
        self.assertIn("restored=700", out)

    def fake_dnf5(self):
        # The last override file that names a repository decides, as in dnf5.
        self.stub("dnf", r"""repo=""
            for arg in "$@"; do
              case "$arg" in
                --version) echo "dnf5 version 5.4.6.0"; echo "dnf5 plugin API version 2.0"; exit 0 ;;
                --dump-repo-config=*) repo="${arg#*=}" ;;
              esac
            done
            [ -n "$repo" ] || exit 1
            value=1
            for file in "$TKOC_TEST_ROOT"/etc/dnf/repos.override.d/*.repo; do
              [ -f "$file" ] || continue
              found="$(awk -v r="[$repo]" '$0 == r { s = 1; next } /^\[/ { s = 0 }
                s && /^countme=/ { sub(/^countme=/, ""); print }' "$file")"
              [ -z "$found" ] || value="$found"
            done
            echo "countme = $value" """)

    def test_countme_is_turned_off_per_repository_and_verified(self):
        repos = self.root / "etc/yum.repos.d"
        repos.mkdir(parents=True)
        (repos / "fedora.repo").write_text(
            "[fedora]\nname=Fedora\ncountme=1\n\n[fedora-debuginfo]\nname=Debug\nenabled=0\n")
        (repos / "fedora-updates.repo").write_text("[updates]\nname=Updates\ncountme=1\n")
        (self.root / "etc/dnf").mkdir()
        (self.root / "etc/dnf/dnf.conf").write_text("[main]\ngpgcheck=True\n")
        self.fake_dnf5()
        out = self.run_process(["bash", PROJECT / "stages/hardening/telemetry.sh", "--yes"])
        override = (self.root / "etc/dnf/repos.override.d/90-tkoc-no-countme.repo").read_text()
        self.assertIn("[fedora]\ncountme=0", override)
        self.assertIn("[updates]\ncountme=0", override)
        self.assertNotIn("fedora-debuginfo", override)
        self.assertIn("countme=False", (self.root / "etc/dnf/dnf.conf").read_text())
        self.assertIn("dnf reports countme off for every repository", out)
        self.assertNotIn("review them", out)
        self.no_system_calls()
        # A later override that turns it back on is caught, not reported as done.
        (self.root / "etc/dnf/repos.override.d/99-config_manager.repo").write_text("[fedora]\ncountme=1\n")
        out = self.run_process(["bash", PROJECT / "stages/hardening/telemetry.sh", "--yes"], expected=1)
        self.assertIn("dnf still reports countme on for: fedora(1)", out)

    def test_firmware_turns_off_automatic_reports_and_removes_the_noop_drop_in(self):
        remotes = self.root / "etc/fwupd/remotes.d"
        remotes.mkdir(parents=True)
        (remotes / "lvfs.conf").write_text(
            "[fwupd Remote]\n# stable firmware\nEnabled=true\nReportURI=https://example.invalid/report\n"
            "AutomaticReports=true\nAutomaticSecurityReports=true\n")
        vendor = "[fwupd Remote]\nEnabled=true\nMetadataURI=file:///usr/share/vendor.xml\n"
        (remotes / "vendor.conf").write_text(vendor)
        noop = self.root / "etc/fwupd/fwupd.conf.d/90-tkoc-no-report.conf"
        noop.parent.mkdir()
        noop.write_text("[fwupd]\nUpdateMotd=false\n")
        out = self.run_process(["bash", PROJECT / "stages/hardening/firmware.sh", "--yes"])
        lvfs = (remotes / "lvfs.conf").read_text()
        self.assertIn("AutomaticReports=false", lvfs)
        self.assertIn("AutomaticSecurityReports=false", lvfs)
        self.assertIn("# stable firmware", lvfs)
        self.assertEqual((remotes / "vendor.conf").read_text(), vendor)
        self.assertFalse(noop.exists(), out)
        self.no_system_calls()

    def test_resolved_writes_the_resolvers_and_modes_it_was_given(self):
        self.stub("systemctl", '''case "$*" in
            list-unit-files*) printf 'systemd-resolved.service enabled enabled\\n' ;;
            daemon-reload) exit 0 ;;
            is-active*) exit 3 ;;
            *) printf 'systemctl %s\\n' "$*" >> "$TEST_CALLS"; exit 97 ;;
        esac''')
        out = self.run_process(["bash", PROJECT / "stages/hardening/resolved.sh", "--yes"], env={
            "ROUTER_DNS": "1.1.1.1#cloudflare-dns.com, 2606:4700:4700::1111#cloudflare-dns.com",
            "TKOC_DNS_OVER_TLS": "yes", "TKOC_DNSSEC": "yes"})
        conf = (self.root / "etc/systemd/resolved.conf.d/90-tkoc-lockdown.conf").read_text()
        self.assertIn("DNS=1.1.1.1#cloudflare-dns.com 2606:4700:4700::1111#cloudflare-dns.com\n", conf)
        self.assertIn("DNSOverTLS=yes\n", conf)
        self.assertIn("DNSSEC=yes\n", conf)
        self.assertIn("DNS-over-TLS is strict", out)
        self.no_system_calls()
        # A value resolved would misread must never reach its config file.
        out = self.run_process(["bash", PROJECT / "stages/hardening/resolved.sh", "--yes"],
                               expected=1, env={"TKOC_DNSSEC": "sure"})
        self.assertIn("TKOC_DNSSEC must be", out)

    def test_category_previews_report_only_what_would_happen(self):
        # systemd-resolved is running, so discovery has a restart to preview.
        self.stub("systemctl", '''case "$*" in
            list-unit-files*) exit 0 ;;
            is-enabled*) printf 'disabled\\n'; exit 1 ;;
            *'is-active --quiet -- systemd-resolved.service') exit 0 ;;
            is-active*) exit 3 ;;
            *) printf 'systemctl %s\\n' "$*" >> "$TEST_CALLS"; exit 97 ;;
        esac''')
        out = self.cli_run("privacy", "--categories", "discovery", "--dry-run")
        self.assertIn("would restart systemd-resolved", out)
        self.assertNotIn("ok   restarted", out)
        # A category run is not a level, and must not be recorded as one.
        self.assertIn("complete (categories: discovery)", out)
        self.assertNotIn("(level:", out)
        self.no_system_calls()

    # ── Automating what used to be left as advice ───────────────────

    def fake_kde(self):
        self.stub("kreadconfig6", "exit 0")
        self.stub("kwriteconfig6", "exit 0")
        self.stub("balooctl6", '''[ "$1" = purge ] || exit 1
            rm -f "$HOME/.local/share/baloo/index"; echo "Deleted the index database"''')

    def test_lockdown_deletes_the_baloo_index_and_strong_only_reports_it(self):
        self.fake_kde()
        index = self.home / ".local/share/baloo/index"
        index.parent.mkdir(parents=True)
        index.write_bytes(b"x" * 4096)
        out = self.run_process(["bash", PROJECT / "stages/hardening/kde-privacy.sh", "--yes"],
                               env={"TKOC_PRIVACY_LEVEL": "strong"})
        self.assertTrue(index.exists())
        self.assertIn("lockdown deletes it", out)
        out = self.run_process(["bash", PROJECT / "stages/hardening/kde-privacy.sh", "--yes"],
                               env={"TKOC_PRIVACY_LEVEL": "lockdown"})
        self.assertFalse(index.exists(), out)
        self.assertIn("deleted the Baloo index", out)

    def test_virtualbox_forgets_deleted_vms_and_keeps_ones_on_missing_drives(self):
        policy = self.root / "etc/nftables/tkoc.nft"
        policy.parent.mkdir(parents=True)
        shutil.copy2(PROJECT / "config/firewall/tkoc.nft", policy)
        gone = "1c920066-2e1f-4658-9f7a-109749a7108d"
        offline = "2d920066-2e1f-4658-9f7a-109749a7108d"
        (self.area / "VirtualBox VMs").mkdir()   # the VM's folder in it is gone
        listing = (f"Name: <inaccessible!>\\nUUID: {gone}\\n"
                   f"Config file: {self.area}/VirtualBox VMs/ubuntuu/ubuntuu.vbox\\n\\n"
                   f"Name: <inaccessible!>\\nUUID: {offline}\\n"
                   f"Config file: {self.area}/usb-drive/VMs/kali/kali.vbox\\n")
        self.stub("VBoxManage", f"""case "$*" in
            'list vms') printf '"<inaccessible>" {{{gone}}}\\n"<inaccessible>" {{{offline}}}\\n' ;;
            'list vms --long') printf '{listing}' ;;
            unregistervm*) printf '%s\\n' "$*" >> "{self.area}/vbox.log" ;;
            *) exit 1 ;;
        esac""")
        env = {"TKOC_TEST_VBOX": "enabled"}
        out = self.run_process(["bash", PROJECT / "tools/vm-net.sh", "status"], env=env)
        self.assertIn("ubuntuu was deleted", out)
        self.assertIn(f"VBoxManage unregistervm {gone}", out)
        self.assertIn("usb-drive/VMs is not available", out)
        self.assertFalse((self.area / "vbox.log").exists(), "status must not change anything")
        out = self.run_process(["bash", PROJECT / "tools/vm-net.sh", "off", "--yes"], env=env)
        self.assertEqual((self.area / "vbox.log").read_text(), f"unregistervm {gone}\n")
        self.assertIn("stale entry removed", out)
        self.assertIn("left registered", out)

    def fake_flatpak(self, apps):
        state = self.area / "flatpak"
        state.mkdir()
        (state / "apps.json").write_text(json.dumps(apps))
        self.stub("flatpak", f'''exec python3 - "{state}" "$@" <<'PY'
import json, os, sys
from pathlib import Path
state, args = Path(sys.argv[1]), sys.argv[2:]
apps = json.loads((state / "apps.json").read_text())
overrides = Path(os.environ["HOME"]) / ".local/share/flatpak/overrides"
def norm(e):
    path, sep, mode = e.rpartition(":") if e.rsplit(":", 1)[-1] in ("ro", "rw", "create") else (e, "", "")
    path = path.rstrip("/") or "/"
    return path + (":" + mode if sep else "")
def entries(app):
    f = overrides / app
    if not f.exists():
        return []
    for line in f.read_text().splitlines():
        if line.startswith("filesystems="):
            return [e for e in line[12:].split(";") if e]
    return []
def write(app, items):
    overrides.mkdir(parents=True, exist_ok=True)
    (overrides / app).write_text("[Context]\\nfilesystems=" + "".join(e + ";" for e in items) + "\\n")
if args[:2] == ["list", "--app"]:
    print("\\n".join(apps))
elif args[:2] == ["info", "--show-permissions"]:
    have = list(apps[args[2]])
    for e in entries(args[2]):
        if e.startswith("!"):
            have = [h for h in have if h.split(":")[0] != e[1:]]
        elif e not in have:
            have.append(e)
    print("[Context]\\nfilesystems=" + "".join(e + ";" for e in have))
elif args[:3] == ["override", "--user", "--show"]:
    if len(args) > 3 and (overrides / args[3]).exists():
        print((overrides / args[3]).read_text(), end="")
elif args[:2] == ["override", "--user"]:
    app, items = args[-1], entries(args[-1])
    for a in args[2:-1]:
        key, _, value = a.partition("=")
        value = norm(value)
        items = [i for i in items if i not in (value, "!" + value)]
        items.append(("!" if key == "--nofilesystem" else "") + value)
    write(app, items)
else:
    sys.exit(1)
PY''')

    def test_flatpak_apps_you_list_are_limited_and_the_rest_reported(self):
        self.fake_flatpak({
            "org.example.Ide": ["home"],
            "org.example.Game": ["xdg-config/kdeglobals:ro", "host:ro"],
            "org.example.Other": ["home"],
            "org.example.Fine": ["xdg-download"],
        })
        (self.home / "code").mkdir()
        config = self.area / "flatpak-access.json"
        config.write_text(json.dumps({"apps": {
            "org.example.Ide": ["~/code/"], "org.example.Game": []}}))
        env = {"TKOC_FLATPAK_ACCESS": str(config)}
        portals = PROJECT / "stages/hardening/flatpak-portals.sh"
        show = '''flatpak info --show-permissions "$1" | sed -n 's/^filesystems=//p' '''

        out = self.run_process(["bash", portals, "--dry-run"], env=env)
        self.assertIn("would limit org.example.Ide to ~/code/", out)
        self.assertFalse((self.home / ".local/share/flatpak").exists(), "a preview wrote overrides")

        out = self.run_process(["bash", portals, "--yes"], env=env)
        self.assertIn("limited org.example.Ide to ~/code/", out)
        self.assertIn("limited org.example.Game to no folders", out)
        self.assertIn("apps with user-level overrides: org.example.Game org.example.Ide", out)
        self.assertNotIn("no user-level flatpak overrides are set", out)
        self.assertIn("org.example.Other", out)          # reported, not changed
        self.assertNotIn("org.example.Fine", out)
        perms = lambda app: self.run_process(["bash", "-c", show, "bash", app], env=env).strip()
        self.assertEqual(perms("org.example.Ide"), "~/code;")
        self.assertEqual(perms("org.example.Game"), "xdg-config/kdeglobals:ro;")
        self.assertEqual(perms("org.example.Other"), "home;")
        self.no_system_calls()

        out = self.run_process(["bash", portals, "--yes"], env=env)
        self.assertIn("org.example.Ide is already limited", out)

        # The run's snapshot puts every app back exactly as it was.
        restore = '''source "$1/stages/lib/common.sh"; source "$1/stages/lib/state.sh"
            for snap in $(tkoc_state_snapshots | sort); do tkoc_state_restore "$snap"; done'''
        self.run_process(["bash", "-euc", restore, "bash", PROJECT])
        self.assertEqual(perms("org.example.Ide"), "home;")
        self.assertEqual(perms("org.example.Game"), "xdg-config/kdeglobals:ro;host:ro;")

        # A config that would hand back whole-home access is refused outright.
        config.write_text(json.dumps({"apps": {"org.example.Ide": ["~"]}}))
        out = self.run_process(["bash", portals, "--yes"], env=env, expected=1)
        self.assertIn("is not a folder tkoc will grant", out)
        self.assertEqual(perms("org.example.Ide"), "home;")

    def static_units_systemctl(self):
        """A systemctl whose every unit is static: no [Install] section."""
        units, log = self.area / "units", self.area / "systemctl.log"
        units.mkdir()
        self.stub("systemctl", f'''unit="${{@: -1}}"
            case "$1" in
              list-unit-files) printf '%s static -\\n' "$3" ;;
              is-enabled) if [ -e "{units}/$unit.masked" ]; then echo masked; exit 1; fi; echo static ;;
              is-active) [ -e "{units}/$unit.active" ] ;;
              *) printf '%s\\n' "$*" >> "{log}"
                 case "$1" in mask) touch "{units}/$unit.masked"; rm -f "{units}/$unit.active" ;;
                              stop) rm -f "{units}/$unit.active" ;; esac ;;
            esac''')
        return units, log

    def test_static_units_are_stopped_not_disabled_and_geoclue_is_masked(self):
        units, log = self.static_units_systemctl()
        self.fake_kde()
        script = r"""source "$1/stages/lib/hardening-common.sh"
            hc_disable_unit cockpit.service "web console"
            hc_disable_unit rpc-statd.service "NFS lock manager"
            printf 'applied=%s skipped=%s\n' "$applied" "$skipped" """
        (units / "rpc-statd.service.active").touch()
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT])
        # `disable` is a no-op on a static unit: never claim it, never run it.
        self.assertIn("cockpit.service is static and not running", out)
        self.assertIn("stopped rpc-statd.service", out)
        self.assertIn("applied=1 skipped=1", out)
        self.assertEqual(log.read_text(), "stop -- rpc-statd.service\n")
        # Re-running reports nothing as applied.
        out = self.run_process(["bash", "-euc", script, "bash", PROJECT])
        self.assertIn("applied=0 skipped=2", out)

        # geoclue is woken over D-Bus by any app; only a mask stops that.
        # A preview says so, and claims nothing.
        out = self.run_process(["bash", PROJECT / "stages/hardening/geolocation.sh", "--dry-run"])
        self.assertIn("would mask and stop geoclue.service", out)
        self.assertNotIn("ok   masked", out)
        self.assertNotIn("mask", log.read_text())
        out = self.run_process(["bash", PROJECT / "stages/hardening/geolocation.sh", "--yes"])
        self.assertIn("masked geoclue.service", out)
        self.assertIn("mask --now -- geoclue.service", log.read_text())
        out = self.run_process(["bash", PROJECT / "stages/hardening/geolocation.sh", "--yes"])
        self.assertIn("geoclue.service is already masked", out)

if __name__ == "__main__":
    unittest.main(verbosity=2)
