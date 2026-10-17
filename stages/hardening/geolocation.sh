#!/usr/bin/env bash
# geolocation.sh -- stop the machine from resolving its own physical location
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Location services"

# GeoClue turns nearby Wi-Fi access points into a physical location by querying
# a remote service. Any application can ask it, and the lookup itself tells that
# service where this machine is.
#
# Masked, not disabled. geoclue.service is static and D-Bus activated
# (org.freedesktop.GeoClue2): the first app to ask for a location starts it, so
# "disabled" stopped nothing. Masking is what makes that activation fail.
# Plasma's Night Color then cannot locate you; give it a manual location or
# fixed times instead.
hc_mask_unit geoclue.service "location lookup daemon, D-Bus activated"

# If something genuinely needs GeoClue, the agent list is what decides who may
# ask. Report rather than rewrite: a wrong edit here silently breaks a
# legitimate application instead of protecting anything.
if [[ -r /etc/geoclue/geoclue.conf ]]; then
  if grep -Eq '^[[:space:]]*url[[:space:]]*=' /etc/geoclue/geoclue.conf; then
    hc_advise "geoclue.conf still names a remote lookup URL; review /etc/geoclue/geoclue.conf if you re-enable the service"
  else
    skip "geoclue.conf names no remote lookup URL"
    tally_skip
  fi
fi

# KDE's own location permission, so Plasma applets do not re-request it.
hc_set_kconfig kded5rc Module-geoclue autoload false "KDE geoclue module"

summary
