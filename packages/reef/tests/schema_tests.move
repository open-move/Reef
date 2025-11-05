#[test_only]
module reef::schema_tests;

use reef::schema;

// ====== Helper Functions ======

fun valid_utf8_bytes(): vector<u8> {
    b"Hello, World!"
}

fun invalid_utf8_bytes(): vector<u8> {
    // Invalid UTF-8 sequence: 0xFF is not valid UTF-8
    vector[0xFF, 0xFE, 0xFD]
}

fun make_bytes(len: u64): vector<u8> {
    vector::tabulate!(len, |i| ((i % 256) as u8))
}

// ====== DataType Validation Tests ======

#[test]
fun test_raw_accepts_any_bytes() {
    let data_type = schema::data_type_raw();

    // Raw should accept any data
    assert!(schema::validate_data_type(&data_type, &vector[]));
    assert!(schema::validate_data_type(&data_type, &make_bytes(1)));
    assert!(schema::validate_data_type(&data_type, &make_bytes(100)));
    assert!(schema::validate_data_type(&data_type, &invalid_utf8_bytes()));
}

#[test]
fun test_u8_validation() {
    let data_type = schema::data_type_u8();

    // Valid: exactly 1 byte
    assert!(schema::validate_data_type(&data_type, &vector[0]));
    assert!(schema::validate_data_type(&data_type, &vector[255]));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &vector[]));
    assert!(!schema::validate_data_type(&data_type, &vector[0, 0]));
}

#[test]
fun test_u16_validation() {
    let data_type = schema::data_type_u16();

    // Valid: exactly 2 bytes
    assert!(schema::validate_data_type(&data_type, &vector[0, 0]));
    assert!(schema::validate_data_type(&data_type, &vector[255, 255]));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &vector[0]));
    assert!(!schema::validate_data_type(&data_type, &vector[0, 0, 0]));
}

#[test]
fun test_u32_validation() {
    let data_type = schema::data_type_u32();

    // Valid: exactly 4 bytes
    assert!(schema::validate_data_type(&data_type, &make_bytes(4)));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &make_bytes(3)));
    assert!(!schema::validate_data_type(&data_type, &make_bytes(5)));
}

#[test]
fun test_u64_validation() {
    let data_type = schema::data_type_u64();

    // Valid: exactly 8 bytes
    assert!(schema::validate_data_type(&data_type, &make_bytes(8)));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &make_bytes(7)));
    assert!(!schema::validate_data_type(&data_type, &make_bytes(9)));
}

#[test]
fun test_u128_validation() {
    let data_type = schema::data_type_u128();

    // Valid: exactly 16 bytes
    assert!(schema::validate_data_type(&data_type, &make_bytes(16)));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &make_bytes(15)));
    assert!(!schema::validate_data_type(&data_type, &make_bytes(17)));
}

#[test]
fun test_u256_validation() {
    let data_type = schema::data_type_u256();

    // Valid: exactly 32 bytes
    assert!(schema::validate_data_type(&data_type, &make_bytes(32)));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &make_bytes(31)));
    assert!(!schema::validate_data_type(&data_type, &make_bytes(33)));
}

#[test]
fun test_bool_validation() {
    let data_type = schema::data_type_bool();

    // Valid: 0 or 1
    assert!(schema::validate_data_type(&data_type, &vector[0]));
    assert!(schema::validate_data_type(&data_type, &vector[1]));

    // Invalid: other values or wrong length
    assert!(!schema::validate_data_type(&data_type, &vector[2]));
    assert!(!schema::validate_data_type(&data_type, &vector[255]));
    assert!(!schema::validate_data_type(&data_type, &vector[]));
    assert!(!schema::validate_data_type(&data_type, &vector[0, 0]));
}

#[test]
fun test_address_validation() {
    let data_type = schema::data_type_address();

    // Valid: exactly 32 bytes
    assert!(schema::validate_data_type(&data_type, &make_bytes(32)));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &make_bytes(31)));
    assert!(!schema::validate_data_type(&data_type, &make_bytes(33)));
}

#[test]
fun test_bytes32_validation() {
    let data_type = schema::data_type_bytes32();

    // Valid: exactly 32 bytes
    assert!(schema::validate_data_type(&data_type, &make_bytes(32)));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &make_bytes(31)));
    assert!(!schema::validate_data_type(&data_type, &make_bytes(33)));
}

#[test]
fun test_timestamp_validation() {
    let data_type = schema::data_type_timestamp();

    // Valid: exactly 8 bytes (same as u64)
    assert!(schema::validate_data_type(&data_type, &make_bytes(8)));

    // Invalid: wrong length
    assert!(!schema::validate_data_type(&data_type, &make_bytes(7)));
    assert!(!schema::validate_data_type(&data_type, &make_bytes(9)));
}

#[test]
fun test_string_validation_valid_utf8() {
    let data_type = schema::data_type_string();

    // Valid UTF-8 strings
    assert!(schema::validate_data_type(&data_type, &b"Hello"));
    assert!(schema::validate_data_type(&data_type, &b""));
    assert!(schema::validate_data_type(&data_type, &valid_utf8_bytes()));

    // UTF-8 with special characters
    let emoji = vector[0xF0, 0x9F, 0x98, 0x80]; // 😀
    assert!(schema::validate_data_type(&data_type, &emoji));
}

#[test]
fun test_string_validation_invalid_utf8() {
    let data_type = schema::data_type_string();

    // Invalid UTF-8 sequences
    assert!(!schema::validate_data_type(&data_type, &invalid_utf8_bytes()));
    assert!(!schema::validate_data_type(&data_type, &vector[0xFF]));
    assert!(!schema::validate_data_type(&data_type, &vector[0xC0, 0x80])); // Overlong encoding
}

// ====== Blob Schema Tests ======

#[test]
fun test_blob_schema_creation() {
    // Test creating blob schemas with different data types
    let raw_schema = schema::new_blob_schema(schema::data_type_raw());
    let u64_schema = schema::new_blob_schema(schema::data_type_u64());
    let string_schema = schema::new_blob_schema(schema::data_type_string());

    // Verify data types are correctly stored
    assert!(schema::data_type(&raw_schema) == schema::data_type_raw());
    assert!(schema::data_type(&u64_schema) == schema::data_type_u64());
    assert!(schema::data_type(&string_schema) == schema::data_type_string());
}

#[test]
fun test_blob_schema_validate() {
    let u32_schema = schema::new_blob_schema(schema::data_type_u32());

    // Valid data
    assert!(schema::validate(&u32_schema, &make_bytes(4)));

    // Invalid data
    assert!(!schema::validate(&u32_schema, &make_bytes(3)));
    assert!(!schema::validate(&u32_schema, &make_bytes(5)));
}

// ====== Options Schema Tests ======

#[test]
fun test_options_schema_creation() {
    let options = vector[b"YES", b"NO", b"MAYBE"];
    let schema = schema::new_options_schema(schema::data_type_string(), options);

    // Verify options are stored
    let retrieved_options = schema::options(&schema);
    assert!(retrieved_options.length() == 3);
    assert!(retrieved_options[0] == b"YES");
    assert!(retrieved_options[1] == b"NO");
    assert!(retrieved_options[2] == b"MAYBE");
}

#[test]
#[expected_failure(abort_code = schema::EInvalidOptionsCount)]
fun test_options_schema_too_few_options() {
    // Should fail with less than 2 options
    let options = vector[b"ONLY_ONE"];
    schema::new_options_schema(schema::data_type_string(), options);
}

#[test]
#[expected_failure(abort_code = schema::EInvalidOptionsCount)]
fun test_options_schema_empty_options() {
    // Should fail with no options
    let options = vector[];
    schema::new_options_schema(schema::data_type_string(), options);
}

#[test]
fun test_options_schema_max_options() {
    // Test with maximum allowed options (255)
    let mut options = vector::empty<vector<u8>>();
    let mut i = 0;
    while (i < 255) {
        let mut option = vector::empty<u8>();
        option.push_back(i as u8);
        options.push_back(option);
        i = i + 1;
    };

    let schema = schema::new_options_schema(schema::data_type_u8(), options);
    assert!(schema::options(&schema).length() == 255);
}

#[test]
#[expected_failure(abort_code = schema::EInvalidOptionsCount)]
fun test_options_schema_too_many_options() {
    // Should fail with 256 options (max is 255)
    let mut options = vector::empty<vector<u8>>();
    let mut i = 0;
    while (i < 256) {
        let mut option = vector::empty<u8>();
        option.push_back(i as u8);
        options.push_back(option);
        i = i + 1;
    };

    schema::new_options_schema(schema::data_type_u8(), options);
}

#[test]
fun test_options_schema_validate_valid_option() {
    let option1 = make_bytes(4);
    let mut option2 = make_bytes(4);
    // Make second option different by modifying first byte
    option2.remove(0);
    option2.insert(255, 0);
    let options = vector[option1, option2];

    let schema = schema::new_options_schema(schema::data_type_u32(), options);

    // Valid options
    assert!(schema::validate(&schema, &options[0]));
    assert!(schema::validate(&schema, &options[1]));
}

#[test]
fun test_options_schema_validate_invalid_option() {
    let options = vector[vector[1], vector[2], vector[3]];
    let schema = schema::new_options_schema(schema::data_type_u8(), options);

    // Invalid option (not in list)
    assert!(!schema::validate(&schema, &vector[4]));
    assert!(!schema::validate(&schema, &vector[0]));
}

#[test]
fun test_options_schema_validate_invalid_type() {
    let options = vector[vector[1], vector[2]];
    let schema = schema::new_options_schema(schema::data_type_u8(), options);

    // Invalid type (wrong length for u8)
    assert!(!schema::validate(&schema, &vector[1, 2]));
    assert!(!schema::validate(&schema, &vector[]));
}

#[test]
#[expected_failure(abort_code = schema::EInvalidDataType)]
fun test_options_schema_invalid_option_type() {
    // Try to create options with invalid data type
    let options = vector[
        vector[1, 2], // 2 bytes
        vector[3], // 1 byte - mismatch!
    ];
    schema::new_options_schema(schema::data_type_u16(), options);
}

#[test]
fun test_options_with_string_type() {
    let options = vector[b"PENDING", b"APPROVED", b"REJECTED"];
    let schema = schema::new_options_schema(schema::data_type_string(), options);

    // Valid string options
    assert!(schema::validate(&schema, &b"PENDING"));
    assert!(schema::validate(&schema, &b"APPROVED"));
    assert!(schema::validate(&schema, &b"REJECTED"));

    // Invalid option
    assert!(!schema::validate(&schema, &b"CANCELLED"));
}

// ====== Accessor Function Tests ======

#[test]
fun test_get_data_type_from_blob() {
    let schema = schema::new_blob_schema(schema::data_type_u128());
    assert!(schema::data_type(&schema) == schema::data_type_u128());
}

#[test]
fun test_get_data_type_from_options() {
    let options = vector[b"A", b"B"];
    let schema = schema::new_options_schema(schema::data_type_string(), options);
    assert!(schema::data_type(&schema) == schema::data_type_string());
}

#[test]
fun test_get_options_from_blob_returns_empty() {
    let schema = schema::new_blob_schema(schema::data_type_raw());
    assert!(schema::options(&schema).is_empty());
}

// ====== SchemaRef Tests ======

#[test]
fun test_schema_ref_creation() {
    let topic = b"ETH_USD_PRICE";
    let version = 42;
    let _schema_ref = schema::new_schema_ref(topic, version);

    // Note: SchemaRef fields are private, so we can only test creation doesn't fail
    // The actual usage is tested in protocol module
}

// ====== Edge Cases ======

#[test]
fun test_empty_data_validation() {
    let empty_data = vector[];

    // Raw accepts empty
    assert!(schema::validate_data_type(&schema::data_type_raw(), &empty_data));

    // String accepts empty (empty string is valid UTF-8)
    assert!(schema::validate_data_type(&schema::data_type_string(), &empty_data));

    // All sized types reject empty
    assert!(!schema::validate_data_type(&schema::data_type_u8(), &empty_data));
    assert!(!schema::validate_data_type(&schema::data_type_u16(), &empty_data));
    assert!(!schema::validate_data_type(&schema::data_type_u32(), &empty_data));
    assert!(!schema::validate_data_type(&schema::data_type_u64(), &empty_data));
    assert!(!schema::validate_data_type(&schema::data_type_bool(), &empty_data));
}

#[test]
fun test_options_with_empty_option() {
    // Options schema with empty bytes as valid option
    let options = vector[vector[], vector[1]];
    let schema = schema::new_options_schema(schema::data_type_raw(), options);

    assert!(schema::validate(&schema, &vector[]));
    assert!(schema::validate(&schema, &vector[1]));
    assert!(!schema::validate(&schema, &vector[2]));
}

#[test]
fun test_all_data_type_constructors() {
    // Verify all constructor functions work
    let _ = schema::data_type_raw();
    let _ = schema::data_type_u8();
    let _ = schema::data_type_u16();
    let _ = schema::data_type_u32();
    let _ = schema::data_type_u64();
    let _ = schema::data_type_u128();
    let _ = schema::data_type_u256();
    let _ = schema::data_type_bool();
    let _ = schema::data_type_address();
    let _ = schema::data_type_bytes32();
    let _ = schema::data_type_timestamp();
    let _ = schema::data_type_string();
}
