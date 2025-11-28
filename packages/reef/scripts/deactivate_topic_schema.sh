#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 5 ]; then
    echo "Usage: $0 <reef_package_id> <protocol_object_id> <protocol_cap_object_id> <topic_bytes> <version>" >&2
    echo "Example topic_bytes: vector[0x59,0x45,0x53,0x5F,0x4F,0x52,0x5F,0x4E,0x4F,0x5F,0x51,0x55,0x45,0x52,0x59]" >&2
    exit 1
fi

REEF_PKG="$1"
PROTOCOL_OBJECT_ID="$2"
PROTOCOL_CAP_OBJECT_ID="$3"
TOPIC_BYTES="$4"
VERSION="$5"

sui client ptb \
    --move-call "$REEF_PKG::protocol::deactivate_topic_schema" \
        @"$PROTOCOL_OBJECT_ID" \
        @"$PROTOCOL_CAP_OBJECT_ID" \
        "$TOPIC_BYTES" \
        "$VERSION"
