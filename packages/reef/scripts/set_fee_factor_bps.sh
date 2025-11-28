#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <reef_package_id> <protocol_object_id> <protocol_cap_object_id> <fee_factor_bps>" >&2
    exit 1
fi

REEF_PKG="$1"
PROTOCOL_OBJECT_ID="$2"
PROTOCOL_CAP_OBJECT_ID="$3"
FEE_FACTOR_BPS="$4"

sui client ptb \
    --move-call "$REEF_PKG::protocol::set_fee_factor_bps" \
        @"$PROTOCOL_OBJECT_ID" \
        @"$PROTOCOL_CAP_OBJECT_ID" \
        "$FEE_FACTOR_BPS"
