#!/usr/bin/env bash
# firewall-extras.sh -- the kernel-side half of the network posture
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "Kernel network hardening"

# These duplicate config/sysctl.d/60-tkoc-hardening.conf on purpose. That file
# is written by the firewall stage; this category applies the same values at
# runtime so `tkoc privacy lockdown` on its own still leaves the kernel in the
# intended state, without depending on the firewall stage having run.
hc_set_sysctl net.ipv4.conf.all.accept_redirects 0 "ICMP redirects (all)"
hc_set_sysctl net.ipv4.conf.default.accept_redirects 0 "ICMP redirects (default)"
hc_set_sysctl net.ipv4.conf.all.secure_redirects 0 "secure ICMP redirects"
hc_set_sysctl net.ipv4.conf.all.send_redirects 0 "sending ICMP redirects"
hc_set_sysctl net.ipv4.conf.all.accept_source_route 0 "source routing (all)"
hc_set_sysctl net.ipv4.conf.default.accept_source_route 0 "source routing (default)"
hc_set_sysctl net.ipv4.icmp_echo_ignore_broadcasts 1 "broadcast ping replies"
hc_set_sysctl net.ipv4.icmp_ignore_bogus_error_responses 1 "bogus ICMP error responses"
hc_set_sysctl net.ipv4.conf.all.log_martians 1 "martian packet logging"
hc_set_sysctl net.ipv6.conf.all.accept_redirects 0 "IPv6 ICMP redirects"
hc_set_sysctl net.ipv6.conf.all.accept_source_route 0 "IPv6 source routing"

hdr "Kernel information exposure"

hc_set_sysctl kernel.kptr_restrict 2 "kernel pointer exposure"
hc_set_sysctl kernel.dmesg_restrict 1 "unprivileged dmesg access"
hc_set_sysctl kernel.yama.ptrace_scope 1 "cross-process ptrace"
hc_set_sysctl kernel.perf_event_paranoid 3 "perf event access"

# 2, not 1: a value of 1 cannot be undone until the next boot, which would make
# this category irreversible and break `tkoc state restore`.
hc_set_sysctl kernel.unprivileged_bpf_disabled 2 "unprivileged BPF"

summary
