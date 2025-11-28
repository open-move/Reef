#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 4 ] || [ "$#" -gt 6 ]; then
    echo "Usage: $0 <reef_package_id> <protocol_object_id> <protocol_cap_object_id> <topic_bytes> [yes_literal] [no_literal]" >&2
    echo "Example topic_bytes: vector[0x59,0x45,0x53,0x5F,0x4F,0x52,0x5F,0x4E,0x4F,0x5F,0x51,0x55,0x45,0x52,0x59]" >&2
    echo "Default option literals are YES/NO." >&2
    exit 1
fi

REEF_PKG="$1"
PROTOCOL_OBJECT_ID="$2"
PROTOCOL_CAP_OBJECT_ID="$3"
TOPIC_BYTES="$4"
YES_LITERAL="${5:-vector[0x59,0x45,0x53]}"
NO_LITERAL="${6:-vector[0x4E,0x4F]}"
OPTIONS_LITERAL="vector[$YES_LITERAL, $NO_LITERAL]"

sui client ptb \
    --move-call "$REEF_PKG::schema::data_type_string" \
        --assign string_type \
    --move-call "$REEF_PKG::schema::new_options_schema" \
        string_type \
        "$OPTIONS_LITERAL" \
        --assign yes_no_schema \
    --move-call "$REEF_PKG::protocol::set_topic_schema" \
        @"$PROTOCOL_OBJECT_ID" \
        @"$PROTOCOL_CAP_OBJECT_ID" \
        "$TOPIC_BYTES" \
        yes_no_schema
