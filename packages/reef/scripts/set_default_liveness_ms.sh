#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <reef_package_id> <protocol_object_id> <protocol_cap_object_id> <liveness_ms>" >&2
    exit 1
fi

REEF_PKG="$1"
PROTOCOL_OBJECT_ID="$2"
PROTOCOL_CAP_OBJECT_ID="$3"
LIVENESS_MS="$4"

sui client ptb \
    --move-call "$REEF_PKG::protocol::set_default_liveness_ms" \
        @"$PROTOCOL_OBJECT_ID" \
        @"$PROTOCOL_CAP_OBJECT_ID" \
        "$LIVENESS_MS"
