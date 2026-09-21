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
# process running as this user can read. Disabling it is the setting; the
# existing index is left in place because deleting user data is not this
# category's job.
hc_set_kconfig baloofilerc "Basic Settings" Indexing-Enabled false "Baloo file indexing"
if [[ -d "$HOME/.local/share/baloo" ]]; then
  hc_advise "an existing Baloo index remains at ~/.local/share/baloo; remove it yourself with 'balooctl6 purge' if you want the contents gone"
fi

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
