#!/usr/bin/env bash
# kde-privacy.sh -- Plasma's own telemetry, indexing, and history
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "KDE Plasma privacy"

if ! hc_kde_available; then
  skip "KDE Plasma 6 tooling (kwriteconfig6) is not installed; nothing to do"
  tally_skip
  summary
  exit 0
fi

# Plasma User Feedback ships usage statistics to KDE. Level 0 is "none".
hc_set_kconfig PlasmaUserFeedback Global FeedbackLevel 0 "Plasma user feedback"

# Baloo indexes the content of every file in $HOME into a database that any
# process running as this user can read. Disabling it is the setting. The index
# already built is not your data but a derived copy of it, so lockdown deletes
# it; at strong it is reported. It is rebuilt if indexing is ever turned back
# on -- by you, or by a snapshot restore when it was on before -- so nothing is
# lost for good.
hc_set_kconfig baloofilerc "Basic Settings" Indexing-Enabled false "Baloo file indexing"
_baloo_index="${XDG_DATA_HOME:-$HOME/.local/share}/baloo/index"
if [[ -e "$_baloo_index" ]]; then
  _baloo_size="$(du -sh -- "$_baloo_index" 2>/dev/null | awk '{ print $1 }' || true)"
  if [[ "${TKOC_PRIVACY_LEVEL:-strong}" != lockdown ]]; then
    hc_advise "an existing Baloo index (${_baloo_size:-unknown size}) remains at $_baloo_index; lockdown deletes it, or run 'balooctl6 purge'"
  elif tkoc_bool_enabled TKOC_DRY_RUN disabled; then
    step "[dry-run] would delete the Baloo index (${_baloo_size:-unknown size}) with: balooctl6 purge"
    tally_ok
  elif ! have_cmd balooctl6; then
    hc_advise "balooctl6 is not installed, so the Baloo index at $_baloo_index was left in place"
  elif balooctl6 purge >/dev/null 2>&1 && [[ ! -e "$_baloo_index" ]]; then
    ok "deleted the Baloo index (${_baloo_size:-unknown size}); it is rebuilt only if indexing is re-enabled"
    tally_ok
  else
    wrn "balooctl6 purge did not remove $_baloo_index"
    tally_fail
  fi
fi
unset _baloo_index _baloo_size

# KRunner's web shortcuts send whatever is typed into the launcher to a search
# engine, including things typed there by mistake.
hc_set_kconfig krunnerrc Plugins krunner_webshortcutsEnabled false "KRunner web shortcuts"
hc_set_kconfig kuriikwsfilterrc General EnableWebShortcuts false "web shortcuts in URL handling"

# Recent documents and application history.
hc_set_kconfig kactivitymanagerd-statsrc Plugins org.kde.ActivityManager.ResourceScoringEnabled false "activity usage tracking"
hc_set_kconfig kdeglobals RecentDocuments UseRecent false "recent documents list"

# Plasma search should not reach the network for suggestions.
hc_set_kconfig krunnerrc General historyEnabled false "KRunner query history"

hdr "Session restore"
# A restored session re-opens whatever was on screen at logout, which is a
# record of the last session readable from disk.
hc_set_kconfig ksmserverrc General loginMode emptySession "session restore"

summary
