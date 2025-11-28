#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <reef_package_id> <protocol_object_id> <protocol_cap_object_id> <coin_type> <fee_amount>" >&2
    echo "Example coin type: 0xa1...::usdc::USDC" >&2
    exit 1
fi

REEF_PKG="$1"
PROTOCOL_OBJECT_ID="$2"
PROTOCOL_CAP_OBJECT_ID="$3"
COIN_TYPE="$4"
FEE_AMOUNT="$5"

sui client ptb \
    --move-call "$REEF_PKG::protocol::set_resolver_fee" \
        "<$COIN_TYPE>" \
        @"$PROTOCOL_OBJECT_ID" \
        @"$PROTOCOL_CAP_OBJECT_ID" \
        "$FEE_AMOUNT"
