#!/usr/bin/env bash
# remote-access.sh -- turn off every service that lets something reach this machine
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Remote access"

# sshd is the one service here that a person may genuinely be using to run this
# very command. --ssh is the explicit opt-out; without it, remote login goes.
if tkoc_bool_enabled TKOC_ALLOW_SSH disabled; then
  skip "sshd left enabled because --ssh was given"
  tally_skip
else
  # Fedora starts sshd through socket activation as well as the service, so
  # disabling only sshd.service leaves it reachable on demand.
  hc_disable_unit sshd.service "remote login"
  hc_disable_unit sshd.socket "socket-activated remote login"
fi

# sshd-unix-local.socket is deliberately left alone. systemd-ssh-generator
# creates it to accept ssh over an AF_UNIX path under /run -- local IPC, not a
# TCP/22 listener, and unreachable from off this machine. It stays "active
# listening" in systemctl after sshd itself is off, which looks like the
# shutdown failed. It did not.
if unit_exists sshd-unix-local.socket; then
  skip "sshd-unix-local.socket left alone (local AF_UNIX IPC, not a TCP/22 listener)"
  tally_skip
fi

# Cockpit is Fedora's web admin console. It is socket-activated on 9090 and is
# enabled by default on Server; on Workstation it is usually just installed.
hc_disable_unit cockpit.socket "web admin console on 9090"
hc_disable_unit cockpit.service "web admin console"

# Screen and remote desktop sharing.
hc_disable_unit xrdp.service "RDP server"
hc_disable_unit xrdp-sesman.service "RDP session manager"
hc_disable_unit x11vnc.service "VNC server"
hc_disable_unit wayvnc.service "VNC server"
hc_disable_unit vino-server.service "legacy desktop sharing"
hc_disable_unit gnome-remote-desktop.service "remote desktop daemon"

# Third-party remote-access agents, if any were installed.
for _unit in teamviewerd.service anydesk.service rustdesk.service \
             tailscaled.service zerotier-one.service; do
  hc_disable_unit "$_unit" "third-party remote access"
done
unset _unit

summary
