module reef::schema;

use std::string;

const EInvalidDataType: u64 = 1;
const EInvalidOptionsCount: u64 = 2;

public enum DataType has copy, drop, store {
    Raw, // No validation, any bytes
    U8,
    U16,
    U32,
    U64, // 8 bytes
    U128, // 16 bytes
    U256, // 32 bytes
    String, // UTF-8 validated string
    Bool, // 1 byte (0 or 1)
    Address, // 32 bytes Sui address
    Bytes32, // Exactly 32 bytes
    Timestamp, // 8 bytes unix timestamp
}

public enum Schema has copy, drop, store {
    Blob(DataType),
    Options(DataType, vector<vector<u8>>),
}

public struct SchemaRef(vector<u8>, u64) has copy, drop, store;

public fun new_options_schema(data_type: DataType, options: vector<vector<u8>>): Schema {
    assert!(options.length() >= 2 && options.length() < (1 << 8), EInvalidOptionsCount);
    options.do_ref!(|option| {
        assert!(data_type.validate_data_type(option), EInvalidDataType)
    });

    Schema::Options(data_type, options)
}

public fun new_blob_schema(data_type: DataType): Schema {
    Schema::Blob(data_type)
}

public fun options(schema: &Schema): vector<vector<u8>> {
    match (schema) {
        Schema::Blob(_) => vector[],
        Schema::Options(_, options) => *options,
    }
}

public fun data_type(schema: &Schema): DataType {
    *(
        match (schema) {
            Schema::Options(data_type, _) => data_type,
            Schema::Blob(data_type) => data_type,
        },
    )
}

public fun validate_data_type(data_type: &DataType, data: &vector<u8>): bool {
    match (data_type) {
        DataType::Raw => true,
        DataType::U8 => data.length() == 1,
        DataType::U16 => data.length() == 2,
        DataType::U32 => data.length() == 4,
        DataType::U128 => data.length() == 16,
        DataType::String => string::try_utf8(*data).is_some(),
        DataType::U64 | DataType::Timestamp => data.length() == 8,
        DataType::Bool => data.length() == 1 && (data[0] == 0 || data[0] == 1),
        DataType::U256 | DataType::Address | DataType::Bytes32 => data.length() == 32,
    }
}

public fun validate(schema: &Schema, data: &vector<u8>): bool {
    match (schema) {
        Schema::Options(
            data_type,
            options,
        ) => data_type.validate_data_type(data) && options.contains(data),
        Schema::Blob(data_type) => data_type.validate_data_type(data),
    }
}

public fun new_schema_ref(topic: vector<u8>, version: u64): SchemaRef {
    SchemaRef(topic, version)
}

public fun data_type_raw(): DataType {
    DataType::Raw
}

public fun data_type_u8(): DataType {
    DataType::U8
}

public fun data_type_u16(): DataType {
    DataType::U16
}

public fun data_type_u32(): DataType {
    DataType::U32
}

public fun data_type_u64(): DataType {
    DataType::U64
}

public fun data_type_u128(): DataType {
    DataType::U128
}

public fun data_type_u256(): DataType {
    DataType::U256
}

public fun data_type_bool(): DataType {
    DataType::Bool
}

public fun data_type_address(): DataType {
    DataType::Address
}

public fun data_type_bytes32(): DataType {
    DataType::Bytes32
}

public fun data_type_timestamp(): DataType {
    DataType::Timestamp
}

public fun data_type_string(): DataType {
    DataType::String
}
