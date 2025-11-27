#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <reef_package_id> <resolver_object_id> <protocol_cap_object_id>" >&2
    exit 1
fi

REEF_PKG="$1"
RESOLVER_OBJECT_ID="$2"
PROTOCOL_CAP_OBJECT_ID="$3"

sui client ptb \
    --move-call "$REEF_PKG::resolver::disable" \
        @"$RESOLVER_OBJECT_ID" \
        @"$PROTOCOL_CAP_OBJECT_ID"
