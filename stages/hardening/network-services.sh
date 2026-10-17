#!/usr/bin/env bash
# network-services.sh -- shut down the file-sharing and RPC surface
set -Eeuo pipefail
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd -P)/hardening-common.sh"
hc_category_begin "$@"

hdr "File sharing"

# Samba, NFS and their portmapper. rpcbind in particular listens on 111 and has
# been a reflection-amplification source for years; on a workstation that is not
# an NFS client or server, nothing needs it.
hc_disable_unit smb.service "Samba file server"
hc_disable_unit nmb.service "NetBIOS name server"
hc_disable_unit nfs-server.service "NFS server"
hc_disable_unit rpcbind.service "RPC portmapper"
hc_disable_unit rpcbind.socket "RPC portmapper socket"
hc_disable_unit rpc-statd.service "NFS lock manager"

hdr "Printing"

# CUPS is left running because local printing depends on it; what goes is its
# network listener. cups.socket is what accepts connections.
if unit_active cups.service; then
  hc_advise "cups is running and left alone so local printing keeps working; it listens on 631 -- 'tkoc uav 631' shows the current binding"
else
  skip "cups is not running"
  tally_skip
fi
hc_disable_unit cups-lpd.socket "legacy LPD printing protocol"

hdr "Directory and identity"

# sssd caches credentials and talks to a directory server. A standalone
# workstation has no directory to talk to.
hc_disable_unit sssd.service "directory-service client"

summary
