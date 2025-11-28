#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <reef_package_id> <publisher_address>" >&2
    exit 1
fi

REEF_PKG="$1"
PUBLISHER="$2"

sui client ptb \
    --move-call "$REEF_PKG::protocol::initialize" \
        @"$PUBLISHER" \
        --assign protocol \
    --move-call 0x2::tx_context::sender \
        --assign sender \
    --move-call "$REEF_PKG::protocol::transfer_cap" \
        protocol.1 \
        sender \
    --move-call "0x2::transfer::public_share_object" \
        "<$REEF_PKG::protocol::Protocol>" \
        protocol.0
