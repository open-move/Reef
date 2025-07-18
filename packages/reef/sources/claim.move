module reef::claim {
    use sui::bcs::{Self, BCS};

    use std::string::{Self, String};

    public struct Claim has copy, store, drop {
        type_: ClaimType,
        data: vector<u8>
    }

    public enum ClaimType has copy, store, drop {
        Boolean,
        Integer,
        String,
        Enum,
        Bytes,
    }

    const EInvalidClaimData: u64 = 0;
    const EInvalidClaimType: u64 = 1;

    public fun new_boolean_claim(data: bool): Claim {
        Claim {
            type_: ClaimType::Boolean,
            data: bcs::to_bytes(&data)
        }
    }

    public fun new_integer_claim(data: u256): Claim {
        Claim {
            type_: ClaimType::Integer,
            data: bcs::to_bytes(&data)
        }
    }

    public fun new_string_claim(data: String): Claim {
        Claim {
            type_: ClaimType::String,
            data: bcs::to_bytes(&data)
        }
    }

    public fun new_enum_claim(data: vector<u8>): Claim {
        Claim {
            type_: ClaimType::Enum,
            data: bcs::to_bytes(&data)
        }
    }

    public fun new_bytes_claim(data: vector<u8>): Claim {
        Claim {
            type_: ClaimType::Bytes,
            data: bcs::to_bytes(&data)
        }
    }

    public fun data(claim: &Claim): vector<u8> {
        claim.data
    }

    public fun type_(claim: &Claim): ClaimType {
        claim.type_
    }


    public fun is_boolean(claim: &Claim): bool {
        claim.type_ == ClaimType::Boolean
    }

    public fun is_integer(claim: &Claim): bool {
        claim.type_ == ClaimType::Integer
    }

    public fun is_string(claim: &Claim): bool {
        claim.type_ == ClaimType::String
    }

    public fun is_enum(claim: &Claim): bool {
        claim.type_ == ClaimType::Enum
    }

    public fun is_bytes(claim: &Claim): bool {
        claim.type_ == ClaimType::Bytes
    }

    public macro fun as_type<$T>($claim: &Claim, $as_type: |&mut BCS| -> $T): $T {
        let claim = $claim;
        let mut bcs = bcs::new(claim.data);
        let value = $as_type(&mut bcs);

        assert!(bcs.into_remainder_bytes().is_empty(), EInvalidClaimData);
        value
    }

    public fun as_boolean(claim: &Claim): bool {
        assert!(is_boolean(claim), EInvalidClaimType);
        claim.as_type!(|bcs| bcs.peel_bool())
    }

    public fun as_integer(claim: &Claim): u256 {
        assert!(is_integer(claim), EInvalidClaimType);
        claim.as_type!(|bcs| bcs.peel_u256())
    }

    public fun as_string(claim: &Claim): String {
        assert!(is_string(claim), EInvalidClaimType);
        string::utf8(as_bytes(claim))
    }


    public fun as_bytes(claim: &Claim): vector<u8> {
        assert!(is_bytes(claim), EInvalidClaimType);
        claim.as_type!(|bcs| bcs.peel_vec_u8())
    }

    public fun as_enum(claim: &Claim): vector<u8> {
        assert!(is_enum(claim), EInvalidClaimType);
        claim.as_type!(|bcs| bcs.peel_vec_u8())
    }
}