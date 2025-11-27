#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <reef_package_id> <protocol_object_id> <protocol_cap_object_id> <coin_type>" >&2
    echo "Example coin type: 0xa1...::usdc::USDC" >&2
    exit 1
fi

REEF_PKG="$1"
PROTOCOL_OBJECT_ID="$2"
PROTOCOL_CAP_OBJECT_ID="$3"
COIN_TYPE="$4"

sui client ptb \
    --move-call "$REEF_PKG::protocol::remove_supported_coin_type" \
        "<$COIN_TYPE>" \
        @"$PROTOCOL_OBJECT_ID" \
        @"$PROTOCOL_CAP_OBJECT_ID"
