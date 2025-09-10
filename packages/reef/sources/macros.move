module reef::macros;

macro public fun data_invalid_query(): vector<u8> {
   x"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
}

macro public fun data_unresolvable(): vector<u8> {
   x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe"
}

macro public fun data_too_early(): vector<u8> {
   x"fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffd"
}