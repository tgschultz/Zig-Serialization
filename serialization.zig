//! Simple serialization of arbitrary types.
//! The method of serialization should be adequate to allow
//! normal zig structs to specify the format of many on-disk/wire
//! data formats while simultaneously providing reasonable in-memory
//! representation without the need to worry about endianess or bit
//! packing details.

//! Types may implement a custom serialization or deserialization routine with a 
//! function named `serialize` or `deserialize` in the form of:
//! ```
//! pub fn deserialize(self: *Self, deserializer: anytype) !void
//! ```
//! or
//! ```
//! pub fn serialize(self: *Self, serializer: anytype) !void
//! ```
//! these functions will be called when the serializer or deserializer is used to
//! serialize or deserialize that type. It will pass a pointer to the type instance
//! to serialize or deserialize into and a pointer to the (de)serializer struct.

//! Serialization method:
//! If `packing` is set to `Byte`:
//!   -Integer and Float types are serialized in the specified
//!   endianess using the minimum number of bytes required to fit
//!   all of the integer's bits.
//!   -Booleans are serialized as a single byte integer.
//!   -Structs are serialized field-by-field in the order specified
//!   by the struct source definition. Field serialization is
//!   dependant on type. Packed structs will be serialized
//!   as though `Bit` packing was specified, and then aligned
//!   to the nearest byte. Comptime fields are ignored.
//!   -Unions are serialized by first serializing the active tag
//!   integer, then the payload. The amount of bytes used to
//!   serialize the union is dependent on the active payload type.
//!   Untagged unions are not handled by the serializer and must
//!   employ a custom serializer/deserializer routine.
//!   -Enums and Errors are serialized as their integer values.
//!   -Optionals are serialized as a single `0` value integer
//!   if they are null. If the optional is not null, then a
//!   `1` value integer is serialized, followed by the serialization
//!   of the payload. As with unions, the number of bytes consumed is
//!   dependant on the payload type.
//!   -All other types are not handled and require a custom 
//!   serializer/deserializer routine.
//!
//! If `packing` is set to `Bit`:
//!   -Integer and Float types are serialized in the specified
//!   endianess using the number of bits specified by the integer
//!   type.
//!   -Booleans are serialized as a single bit integer.
//!   -Structs are serialized field-by-field in the order specified
//!   by the struct source definition. Field serialization is
//!   dependant on type. Comptime fields are ignored.
//!   -Unions are serialized by first serializing the active tag
//!   integer, then the payload. The amount of bits used to
//!   serialize the union is dependent on the active payload type.
//!   Untagged unions are not handled by the serializer and must
//!   employ a custom serializer/deserializer routine.
//!   -Enums and Errors are serialized as their integer values.
//!   -Optionals are serialized as a single `0` value integer
//!   if they are null. If the optional is not null, then a
//!   `1` value integer is serialized, followed by the serialization
//!   of the payload. As with unions, the number of bytes consumed is
//!   dependant on the payload type.
//!   -All other types are not handled and require a custom 
//!   serializer/deserializer routine.

const std = @import("std");
const builtin = std.builtin;
const io = std.io;
const assert = std.debug.assert;
const math = std.math;
const meta = std.meta;
const trait = meta.trait;
const testing = std.testing;

pub const Packing = enum {
    /// Pack data to byte alignment
    Byte,

    /// Pack data to bit alignment
    Bit,
};

/// Creates a deserializer that deserializes types from any stream.
/// Types may implement a custom deserialization routine with a
/// function named `deserialize` in the form of:
/// ```
/// pub fn deserialize(self: *Self, deserializer: anytype) !void
/// ```
/// which will be called when the deserializer is used to deserialize
/// that type. It will pass a pointer to the type instance to deserialize
/// into and a pointer to the deserializer struct.
pub fn Deserializer(comptime endian: builtin.Endian, comptime packing: Packing, comptime Reader: type) type {
    return struct {
        reader: if (packing == .Bit) io.BitReader(endian, Reader) else Reader,

        const Self = @This();

        pub fn init(reader: Reader) Self {
            return Self{
                .reader = switch (packing) {
                    .Bit => io.bitReader(endian, reader),
                    .Byte => reader,
                },
            };
        }

        pub fn alignToByte(self: *Self) void {
            if (packing == .Byte) return;
            self.reader.alignToByte();
        }

        //@BUG: inferred error issue. See: #1386
        fn deserializeInt(self: *Self, comptime T: type) (Reader.Error || error{EndOfStream})!T {
            comptime assert(trait.is(.Int)(T) or trait.is(.Float)(T));

            const u8_bit_count = 8;
            const t_bit_count = @bitSizeOf(T);

            const U = std.meta.Int(.unsigned, t_bit_count);
            const Log2U = math.Log2Int(U);
            const int_size = (t_bit_count + 7) / 8;

            if (packing == .Bit) {
                const result = try self.reader.readBitsNoEof(U, t_bit_count);
                return @bitCast(T, result);
            }

            var buffer: [int_size]u8 = undefined;
            const read_size = try self.reader.read(buffer[0..]);
            if (read_size < int_size) return error.EndOfStream;

            if (int_size == 1) {
                if (t_bit_count == 8) return @bitCast(T, buffer[0]);
                const PossiblySignedByte = std.meta.Int(@typeInfo(T).Int.signedness, 8);
                return @truncate(T, @bitCast(PossiblySignedByte, buffer[0]));
            }

            var result = @as(U, 0);
            for (buffer) |byte, i| {
                switch (endian) {
                    .Big => {
                        result = (result << u8_bit_count) | byte;
                    },
                    .Little => {
                        result |= @as(U, byte) << @intCast(Log2U, u8_bit_count * i);
                    },
                }
            }

            return @bitCast(T, result);
        }

        /// Deserializes and returns data of the specified type from the stream
        pub fn deserialize(self: *Self, comptime T: type) !T {
            var value: T = undefined;
            try self.deserializeInto(&value);
            return value;
        }

        /// Deserializes data into the type pointed to by `ptr`
        pub fn deserializeInto(self: *Self, ptr: anytype) !void {
            const T = @TypeOf(ptr);
            comptime assert(trait.is(.Pointer)(T));

            if (comptime trait.isSlice(T) or trait.isPtrTo(.Array)(T)) {
                for (ptr) |*v|
                    try self.deserializeInto(v);
                return;
            }

            comptime assert(trait.isSingleItemPtr(T));

            const C = comptime meta.Child(T);
            const child_type_id = @typeInfo(C);

            //custom deserializer: fn(self: *Self, deserializer: anytype) !void
            if (comptime trait.hasFn("deserialize")(C)) return C.deserialize(ptr, self);

            if (comptime trait.isPacked(C) and packing != .Bit) {
                var packed_deserializer = deserializer(endian, .Bit, self.reader);
                return packed_deserializer.deserializeInto(ptr);
            }

            switch (child_type_id) {
                .Void => return,
                .Bool => ptr.* = (try self.deserializeInt(u1)) > 0,
                .Float, .Int => ptr.* = try self.deserializeInt(C),
                .Struct => {
                    const info = @typeInfo(C).Struct;

                    inline for (info.fields) |*field_info| {
                        if (field_info.is_comptime) continue;
                        const name = field_info.name;
                        const FieldType = field_info.field_type;

                        if (FieldType == void or FieldType == u0) continue;

                        //it doesn't make any sense to read pointers
                        if (comptime trait.is(.Pointer)(FieldType)) {
                            @compileError("Will not " ++ "read field " ++ name ++ " of struct " ++
                                @typeName(C) ++ " because it " ++ "is of pointer-type " ++
                                @typeName(FieldType) ++ ".");
                        }

                        try self.deserializeInto(&@field(ptr, name));
                    }
                },
                .Union => {
                    const info = @typeInfo(C).Union;
                    if (info.tag_type) |TagType| {
                        //we avoid duplicate iteration over the enum tags
                        // by getting the int directly and casting it without
                        // safety. If it is bad, it will be caught anyway.
                        const TagInt = std.meta.TagType(TagType);
                        const tag = try self.deserializeInt(TagInt);

                        inline for (info.fields) |field_info| {
                            if (@enumToInt(@field(TagType, field_info.name)) == tag) {
                                const name = field_info.name;
                                ptr.* = @unionInit(C, name, undefined);
                                try self.deserializeInto(&@field(ptr, name));
                                return;
                            }
                        }
                        //This is reachable if the enum data is bad
                        return error.InvalidEnumTag;
                    }
                    @compileError("Cannot meaningfully deserialize " ++ @typeName(C) ++
                        " because it is an untagged union. Use a custom deserialize().");
                },
                .Optional => {
                    const OC = comptime meta.Child(C);
                    const exists = (try self.deserializeInt(u1)) > 0;
                    if (!exists) {
                        ptr.* = null;
                        return;
                    }

                    ptr.* = @as(OC, undefined); //make it non-null so the following .? is guaranteed safe
                    const val_ptr = &ptr.*.?;
                    try self.deserializeInto(val_ptr);
                },
                .Enum => {
                    var value = try self.deserializeInt(std.meta.TagType(C));
                    ptr.* = try meta.intToEnum(C, value);
                },
                else => {
                    @compileError("Cannot deserialize " ++ @tagName(child_type_id) ++ " types (unimplemented).");
                },
            }
        }
    };
}

/// Generate a Deserializer instance with the specified attributes using the
/// specified `reader`.
pub fn deserializer(
    comptime endian: builtin.Endian,
    comptime packing: Packing,
    reader: anytype,
) Deserializer(endian, packing, @TypeOf(reader)) {
    return Deserializer(endian, packing, @TypeOf(reader)).init(reader);
}

/// Creates a serializer that serializes types to any stream.
/// Note that the you must call `serializer.flush()` when you are done
/// writing bit-packed data in order ensure any unwritten bits are committed.
/// Types may implement a custom serialization routine with a
/// function named `serialize` in the form of:
/// ```
/// pub fn serialize(self: Self, serializer: anytype) !void
/// ```
/// which will be called when the serializer is used to serialize that type. It will
/// pass a const pointer to the type instance to be serialized and a pointer
/// to the serializer struct.
pub fn Serializer(comptime endian: builtin.Endian, comptime packing: Packing, comptime Writer: type) type {
    return struct {
        writer: if (packing == .Bit) io.BitWriter(endian, Writer) else Writer,

        const Self = @This();
        pub const Error = Writer.Error;

        pub fn init(writer: Writer) Self {
            return Self{
                .writer = switch (packing) {
                    .Bit => io.bitWriter(endian, writer),
                    .Byte => writer,
                },
            };
        }

        /// Flushes any unwritten bits to the stream
        pub fn flush(self: *Self) Error!void {
            if (packing == .Bit) return self.writer.flushBits();
        }

        fn serializeInt(self: *Self, value: anytype) Error!void {
            const T = @TypeOf(value);
            comptime assert(trait.is(.Int)(T) or trait.is(.Float)(T));

            const t_bit_count = @bitSizeOf(T);
            const u8_bit_count = @bitSizeOf(u8);

            const U = std.meta.Int(.unsigned, t_bit_count);
            const Log2U = math.Log2Int(U);
            const int_size = (t_bit_count + 7) / 8;

            const u_value = @bitCast(U, value);

            if (packing == .Bit) return self.writer.writeBits(u_value, t_bit_count);

            var buffer: [int_size]u8 = undefined;
            if (int_size == 1) buffer[0] = u_value;

            for (buffer) |*byte, i| {
                const idx = switch (endian) {
                    .Big => int_size - i - 1,
                    .Little => i,
                };
                const shift = @intCast(Log2U, idx * u8_bit_count);
                const v = u_value >> shift;
                byte.* = if (t_bit_count < u8_bit_count) v else @truncate(u8, v);
            }

            try self.writer.writeAll(&buffer);
        }

        /// Serializes the passed value into the stream
        pub fn serialize(self: *Self, value: anytype) Error!void {
            const T = comptime @TypeOf(value);

            if (comptime trait.isIndexable(T)) {
                for (value) |v|
                    try self.serialize(v);
                return;
            }

            //custom serializer: fn(self: Self, serializer: anytype) !void
            if (comptime trait.hasFn("serialize")(T)) return T.serialize(value, self);

            if (comptime trait.isPacked(T) and packing != .Bit) {
                var packed_serializer = Serializer(endian, .Bit, Writer).init(self.writer);
                try packed_serializer.serialize(value);
                try packed_serializer.flush();
                return;
            }

            switch (@typeInfo(T)) {
                .Void => return,
                .Bool => try self.serializeInt(@as(u1, @boolToInt(value))),
                .Float, .Int => try self.serializeInt(value),
                .Struct => {
                    const info = @typeInfo(T);

                    inline for (info.Struct.fields) |*field_info| {
                        if (field_info.is_comptime) continue;
                        const name = field_info.name;
                        const FieldType = field_info.field_type;

                        if (FieldType == void or FieldType == u0) continue;

                        //It doesn't make sense to write pointers
                        if (comptime trait.is(.Pointer)(FieldType)) {
                            @compileError("Will not " ++ "serialize field " ++ name ++
                                " of struct " ++ @typeName(T) ++ " because it " ++
                                "is of pointer-type " ++ @typeName(FieldType) ++ ".");
                        }
                        try self.serialize(@field(value, name));
                    }
                },
                .Union => {
                    const info = @typeInfo(T).Union;
                    if (info.tag_type) |TagType| {
                        const active_tag = meta.activeTag(value);
                        try self.serialize(active_tag);
                        //This inline loop is necessary because active_tag is a runtime
                        // value, but @field requires a comptime value. Our alternative
                        // is to check each field for a match
                        inline for (info.fields) |field_info| {
                            if (@field(TagType, field_info.name) == active_tag) {
                                const name = field_info.name;
                                try self.serialize(@field(value, name));
                                return;
                            }
                        }
                        unreachable;
                    }
                    @compileError("Cannot meaningfully serialize " ++ @typeName(T) ++
                        " because it is an untagged union. Use a custom serialize().");
                },
                .Optional => {
                    if (value == null) {
                        try self.serializeInt(@as(u1, @boolToInt(false)));
                        return;
                    }
                    try self.serializeInt(@as(u1, @boolToInt(true)));

                    const val_ptr = &value.?;
                    try self.serialize(val_ptr.*);
                },
                .Enum => {
                    try self.serializeInt(@enumToInt(value));
                },
                else => @compileError("Cannot serialize " ++ @tagName(@typeInfo(T)) ++ " types (unimplemented)."),
            }
        }
    };
}

/// Generate a Serializer instance with the specified attributes using the
/// specified `writer`.
pub fn serializer(
    comptime endian: builtin.Endian,
    comptime packing: Packing,
    writer: anytype,
) Serializer(endian, packing, @TypeOf(writer)) {
    return Serializer(endian, packing, @TypeOf(writer)).init(writer);
}

fn testIntSerializerDeserializer(comptime endian: builtin.Endian, comptime packing: Packing) !void {
    @setEvalBranchQuota(1500);
    //@NOTE: if this test is taking too long, reduce the maximum tested bitsize
    const max_test_bitsize = 128;

    const total_bytes = comptime blk: {
        var bytes = 0;
        comptime var i = 0;
        while (i <= max_test_bitsize) : (i += 1) bytes += (i / 8) + @boolToInt(i % 8 > 0);
        break :blk bytes * 2;
    };

    var data_mem: [total_bytes]u8 = undefined;
    var out = io.fixedBufferStream(&data_mem);
    var _serializer = serializer(endian, packing, out.writer());

    var in = io.fixedBufferStream(&data_mem);
    var _deserializer = deserializer(endian, packing, in.reader());

    comptime var i = 0;
    inline while (i <= max_test_bitsize) : (i += 1) {
        const U = std.meta.Int(.unsigned, i);
        const S = std.meta.Int(.signed, i);
        try _serializer.serializeInt(@as(U, i));
        if (i != 0) try _serializer.serializeInt(@as(S, -1)) else try _serializer.serialize(@as(S, 0));
    }
    try _serializer.flush();

    i = 0;
    inline while (i <= max_test_bitsize) : (i += 1) {
        const U = std.meta.Int(.unsigned, i);
        const S = std.meta.Int(.signed, i);
        const x = try _deserializer.deserializeInt(U);
        const y = try _deserializer.deserializeInt(S);
        try testing.expect(x == @as(U, i));
        try (if (i != 0) testing.expect(y == @as(S, -1)) else testing.expect(y == 0));
    }

    const u8_bit_count = @bitSizeOf(u8);
    //0 + 1 + 2 + ... n = (n * (n + 1)) / 2
    //and we have each for unsigned and signed, so * 2
    const total_bits = (max_test_bitsize * (max_test_bitsize + 1));
    const extra_packed_byte = @boolToInt(total_bits % u8_bit_count > 0);
    const total_packed_bytes = (total_bits / u8_bit_count) + extra_packed_byte;

    try testing.expect(in.pos == if (packing == .Bit) total_packed_bytes else total_bytes);

    //Verify that empty error set works with serializer.
    //deserializer is covered by FixedBufferStream
    var null_serializer = serializer(endian, packing, std.io.null_writer);
    try null_serializer.serialize(data_mem[0..]);
    try null_serializer.flush();
}

test "Serializer/Deserializer Int" {
    try testIntSerializerDeserializer(.Big, .Byte);
    try testIntSerializerDeserializer(.Little, .Byte);
    try testIntSerializerDeserializer(.Big, .Bit);
    try testIntSerializerDeserializer(.Little, .Bit);
}

fn testIntSerializerDeserializerInfNaN(
    comptime endian: builtin.Endian,
    comptime packing: Packing,
) !void {
    const mem_size = (16 * 2 + 32 * 2 + 64 * 2 + 128 * 2) / @bitSizeOf(u8);
    var data_mem: [mem_size]u8 = undefined;

    var out = io.fixedBufferStream(&data_mem);
    var _serializer = serializer(endian, packing, out.writer());

    var in = io.fixedBufferStream(&data_mem);
    var _deserializer = deserializer(endian, packing, in.reader());

    try _serializer.serialize(std.math.nan(f16));
    try _serializer.serialize(std.math.inf(f16));
    try _serializer.serialize(std.math.nan(f32));
    try _serializer.serialize(std.math.inf(f32));
    try _serializer.serialize(std.math.nan(f64));
    try _serializer.serialize(std.math.inf(f64));
    try _serializer.serialize(std.math.nan(f128));
    try _serializer.serialize(std.math.inf(f128));
    const nan_check_f16 = try _deserializer.deserialize(f16);
    const inf_check_f16 = try _deserializer.deserialize(f16);
    const nan_check_f32 = try _deserializer.deserialize(f32);
    _deserializer.alignToByte();
    const inf_check_f32 = try _deserializer.deserialize(f32);
    const nan_check_f64 = try _deserializer.deserialize(f64);
    const inf_check_f64 = try _deserializer.deserialize(f64);
    const nan_check_f128 = try _deserializer.deserialize(f128);
    const inf_check_f128 = try _deserializer.deserialize(f128);
    try testing.expect(std.math.isNan(nan_check_f16));
    try testing.expect(std.math.isInf(inf_check_f16));
    try testing.expect(std.math.isNan(nan_check_f32));
    try testing.expect(std.math.isInf(inf_check_f32));
    try testing.expect(std.math.isNan(nan_check_f64));
    try testing.expect(std.math.isInf(inf_check_f64));
    try testing.expect(std.math.isNan(nan_check_f128));
    try testing.expect(std.math.isInf(inf_check_f128));
}

test "Serializer/Deserializer Int: Inf/NaN" {
    try testIntSerializerDeserializerInfNaN(.Big, .Byte);
    try testIntSerializerDeserializerInfNaN(.Little, .Byte);
    try testIntSerializerDeserializerInfNaN(.Big, .Bit);
    try testIntSerializerDeserializerInfNaN(.Little, .Bit);
}

fn testAlternateSerializer(self: anytype, _serializer: anytype) !void {
    try _serializer.serialize(self.f_f16);
}

fn testSerializerDeserializer(comptime endian: builtin.Endian, comptime packing: Packing) !void {
    const ColorType = enum(u4) {
        RGB8 = 1,
        RA16 = 2,
        R32 = 3,
    };

    const TagAlign = union(enum(u32)) {
        A: u8,
        B: u8,
        C: u8,
    };

    const Color = union(ColorType) {
        RGB8: struct {
            r: u8,
            g: u8,
            b: u8,
            a: u8,
        },
        RA16: struct {
            r: u16,
            a: u16,
        },
        R32: u32,
    };

    const PackedStruct = packed struct {
        f_i3: i3,
        f_u2: u2,
    };

    //to test custom serialization
    const Custom = struct {
        f_f16: f16,
        f_unused_u32: u32,

        pub fn deserialize(self: *@This(), _deserializer: anytype) !void {
            try _deserializer.deserializeInto(&self.f_f16);
            self.f_unused_u32 = 47;
        }

        pub const serialize = testAlternateSerializer;
    };

    const MyStruct = struct {
        f_i3: i3,
        f_u8: u8,
        f_tag_align: TagAlign,
        comptime f_comptime_field: u22 = 12345,
        f_u24: u24,
        f_i19: i19,
        f_void: void,
        f_f32: f32,
        f_f128: f128,
        f_packed_0: PackedStruct,
        f_i7arr: [10]i7,
        f_of64n: ?f64,
        f_of64v: ?f64,
        f_color_type: ColorType,
        f_packed_1: PackedStruct,
        f_custom: Custom,
        f_color: Color,
    };

    const my_inst = MyStruct{
        .f_i3 = -1,
        .f_u8 = 8,
        .f_tag_align = .{ .B = 148 },
        .f_comptime_field = 12345,
        .f_u24 = 24,
        .f_i19 = 19,
        .f_void = {},
        .f_f32 = 32.32,
        .f_f128 = 128.128,
        .f_packed_0 = .{ .f_i3 = -1, .f_u2 = 2 },
        .f_i7arr = [10]i7{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 },
        .f_of64n = null,
        .f_of64v = 64.64,
        .f_color_type = .R32,
        .f_packed_1 = .{ .f_i3 = 1, .f_u2 = 1 },
        .f_custom = .{ .f_f16 = 38.63, .f_unused_u32 = 47 },
        .f_color = .{ .R32 = 123822 },
    };

    var data_mem: [@sizeOf(MyStruct)]u8 = undefined;
    var out = io.fixedBufferStream(&data_mem);
    var _serializer = serializer(endian, packing, out.writer());

    var in = io.fixedBufferStream(&data_mem);
    var _deserializer = deserializer(endian, packing, in.reader());

    try _serializer.serialize(my_inst);

    const my_copy = try _deserializer.deserialize(MyStruct);
    try testing.expect(meta.eql(my_copy, my_inst));
}

test "Serializer/Deserializer generic" {
    try testSerializerDeserializer(builtin.Endian.Big, .Byte);
    try testSerializerDeserializer(builtin.Endian.Little, .Byte);
    try testSerializerDeserializer(builtin.Endian.Big, .Bit);
    try testSerializerDeserializer(builtin.Endian.Little, .Bit);
}

fn testBadData(comptime endian: builtin.Endian, comptime packing: Packing) !void {
    const E = enum(u14) {
        One = 1,
        Two = 2,
    };

    const A = struct {
        e: E,
    };

    const C = union(E) {
        One: u14,
        Two: f16,
    };

    var data_mem: [4]u8 = undefined;
    var out = io.fixedBufferStream(&data_mem);
    var _serializer = serializer(endian, packing, out.writer());

    var in = io.fixedBufferStream(&data_mem);
    var _deserializer = deserializer(endian, packing, in.reader());

    try _serializer.serialize(@as(u14, 3));
    try testing.expectError(error.InvalidEnumTag, _deserializer.deserialize(A));
    out.pos = 0;
    try _serializer.serialize(@as(u14, 3));
    try _serializer.serialize(@as(u14, 88));
    try testing.expectError(error.InvalidEnumTag, _deserializer.deserialize(C));
}

test "Deserializer bad data" {
    try testBadData(.Big, .Byte);
    try testBadData(.Little, .Byte);
    try testBadData(.Big, .Bit);
    try testBadData(.Little, .Bit);
}
