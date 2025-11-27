#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <reef_package_id> <publisher_address> <initial_supported_coin_type>" >&2
    exit 1
fi

REEF_PKG="$1"
PUBLISHER="$2"
COIN_TYPE="$3"

sui client ptb \
    --move-call "$REEF_PKG::protocol::initialize" \
        @"$PUBLISHER" \
        --assign protocol \
    --move-call 0x2::tx_context::sender \
        --assign sender \
    --move-call "$REEF_PKG::protocol::add_supported_coin_type" \
        "<$COIN_TYPE>" \
        protocol.0 \
        protocol.1 \
    --move-call "$REEF_PKG::protocol::set_resolver_fee" \
        "<$COIN_TYPE>" \
        protocol.0 \
        protocol.1 \
        "0" \
    --move-call "$REEF_PKG::protocol::transfer_cap" \
        protocol.1 \
        sender \
    --move-call "0x2::transfer::public_share_object" \
        "<$REEF_PKG::protocol::Protocol>" \
        protocol.0
