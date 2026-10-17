#!/usr/bin/env bash
# discovery.sh -- stop announcing this machine to the local network
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Network discovery"

# Avahi answers and broadcasts mDNS, which tells every device on the LAN this
# machine's hostname, and often its services and addresses.
hc_disable_unit avahi-daemon.service "mDNS/Bonjour responder"
hc_disable_unit avahi-daemon.socket "mDNS/Bonjour socket"

# cups-browsed hunts for shared printers over the network and has a long history
# of remote-facing bugs. Local printing through cups itself is unaffected.
hc_disable_unit cups-browsed.service "network printer discovery"

# systemd-resolved does its own mDNS and LLMNR, independently of Avahi.
hc_drop_in /etc/systemd/resolved.conf.d 90-tkoc-no-discovery.conf \
'# Managed by tkoc: do not use or answer multicast name resolution.
[Resolve]
MulticastDNS=no
LLMNR=no' "resolved multicast name resolution"

if unit_active systemd-resolved.service && tkoc_bool_enabled TKOC_DRY_RUN disabled; then
  # The run_root preview line is swallowed by the redirect below, so say it here
  # rather than reporting a restart that never happened.
  step "[dry-run] would restart systemd-resolved"
elif unit_active systemd-resolved.service; then
  run_root systemctl restart systemd-resolved.service >/dev/null 2>&1 \
    && ok "restarted systemd-resolved to load the new policy" \
    || wrn "could not restart systemd-resolved; the drop-in applies at next boot"
fi

summary
