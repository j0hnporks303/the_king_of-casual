#!/usr/bin/env bash
# bluetooth.sh -- stop broadcasting over Bluetooth
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Bluetooth"

# A discoverable adapter answers any scan with a stable identifier, which is a
# trackable beacon in any public place. Even when not discoverable, a powered
# adapter is a live attack surface in the kernel.
hc_drop_in /etc/bluetooth/main.conf.d 90-tkoc.conf \
'# Managed by tkoc: never power on or advertise by default.
[Policy]
AutoEnable=false

[General]
DiscoverableTimeout=30
PairableTimeout=30
FastConnectable=false' "bluetooth default policy"

# This is the tier that turns the radio off. Anyone who uses Bluetooth
# peripherals should be at strong, not lockdown -- disabling bluetooth.service
# disconnects Bluetooth keyboards and mice, which on a laptop with no others
# attached leaves no way to log back in.
if [[ -e /sys/class/bluetooth ]] && find /sys/class/bluetooth -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | grep -q .; then
  wrn "a Bluetooth adapter is present; disabling it will disconnect any Bluetooth keyboard or mouse"
fi
hc_disable_unit bluetooth.service "bluetooth stack"

# KDE's applet re-enables the adapter at login if it remembers it was on.
hc_set_kconfig bluedevilglobalrc Global launchState disabled "KDE bluetooth autostart"

summary
