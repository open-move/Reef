module reef::macros;

public macro fun default_fee_factor(): u64 {
    5000
}

public macro fun max_topic_length(): u64 {
    256 // Maximum 256 bytes for a topic
}

public macro fun min_liveness_ms(): u64 {
    5 * 60 * 1000
}

public macro fun bps(): u64 {
    10_000
}

/// Data value representing a too early query proposal
public macro fun too_early(): vector<u8> {
    x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe"
}

/// Data value representing unresolvable query
public macro fun unresolvable(): vector<u8> {
    x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd"
}

public macro fun max_metadata_length(): u64 {
    1024 // Maximum 1KB for metadata
}
