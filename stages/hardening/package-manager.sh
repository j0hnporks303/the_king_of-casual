#!/usr/bin/env bash
# package-manager.sh -- what dnf and flatpak disclose, and to whom
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "DNF"

# GPG checking is the difference between "installed a package" and "installed
# whatever the mirror served". It is on by default; this verifies rather than
# assumes, because a single local edit turns it off system-wide.
_gpgcheck="$(hc_config_get /etc/dnf/dnf.conf main gpgcheck 2>/dev/null || printf '1')"
case "$_gpgcheck" in
  1|True|true|yes) ok "dnf gpgcheck is on"; tally_ok ;;
  *) hc_set_config /etc/dnf/dnf.conf main gpgcheck 1 "dnf package signature checking" ;;
esac
unset _gpgcheck

# A repo file that sets gpgcheck=0 defeats the global setting for that repo.
if [[ -d /etc/yum.repos.d ]] && grep -rlq '^[[:space:]]*gpgcheck[[:space:]]*=[[:space:]]*0' /etc/yum.repos.d 2>/dev/null; then
  hc_advise "one or more repos under /etc/yum.repos.d set gpgcheck=0; review them (grep -rn 'gpgcheck' /etc/yum.repos.d)"
else
  skip "no repo file disables gpgcheck"
  tally_skip
fi

# Keeping downloaded packages means the full install history stays on disk.
hc_set_config /etc/dnf/dnf.conf main keepcache False "dnf package cache retention"

hdr "Flatpak"

if ! have_cmd flatpak; then
  skip "flatpak is not installed"
  tally_skip
  summary
  exit 0
fi

# System-wide remotes are visible and changeable by every user on the machine;
# per-user remotes are not. Report what is configured rather than removing a
# remote the user depends on.
_remotes="$(flatpak remotes --columns=name,options 2>/dev/null || true)"
if [[ -n "$_remotes" ]]; then
  step "configured flatpak remotes:"
  printf '%s\n' "$_remotes" | sed 's/^/      /'
  tally_skip
else
  skip "no flatpak remotes are configured"
  tally_skip
fi
unset _remotes

summary
