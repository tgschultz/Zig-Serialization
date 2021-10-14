# Zig-Serialization
A simple serializer and deserializer for arbitrary types with any endianess and bit or byte packing.

The method of serialization should be adequate to allow normal zig structs to specify the format of many on-disk/wire data formats while simultaneously providing reasonable in-memory representation without the need to worry about endianess or bit packing details.

Types may implement a custom serialization or deserialization routine with a function named `serialize` or `deserialize` in the form of:
```zig
pub fn deserialize(self: *Self, deserializer: anytype) !void
```
or
```zig
pub fn serialize(self: *Self, serializer: anytype) !void
```
these functions will be called when the serializer or deserializer is used to serialize or deserialize that type. It will pass a pointer to the type instance to serialize or deserialize into and a pointer to the (de)serializer struct.

## Serialization method:
If `packing` is set to `Byte`:
  - Integer and Float types are serialized in the specified
  endianess using the minimum number of bytes required to fit
  all of the integer's bits.
  - Booleans are serialized as a single byte integer.
  - Structs are serialized field-by-field in the order specified
  by the struct source definition. Field serialization is
  dependant on type. Packed structs will be serialized
  as though `Bit` packing was specified, and then aligned
  to the nearest byte. Comptime fields are ignored.
  - Unions are serialized by first serializing the active tag
  integer, then the payload. The amount of bytes used to
  serialize the union is dependent on the active payload type.
  Untagged unions are not handled by the serializer and must
  employ a custom serializer/deserializer routine.
  - Enums and Errors are serialized as their integer values.
  - Optionals are serialized as a single `0` value integer
  if they are null. If the optional is not null, then a
  `1` value integer is serialized, followed by the serialization
  of the payload. As with unions, the number of bytes consumed is
  dependant on the payload type.
  - All other types are not handled and require a custom 
  serializer/deserializer routine.

If `packing` is set to `Bit`:
  - Integer and Float types are serialized in the specified
  endianess using the number of bits specified by the integer
  type.
  - Booleans are serialized as a single bit integer.
  - Structs are serialized field-by-field in the order specified
  by the struct source definition. Field serialization is
  dependant on type. Comptime fields are ignored.
  - Unions are serialized by first serializing the active tag
  integer, then the payload. The amount of bits used to
  serialize the union is dependent on the active payload type.
  Untagged unions are not handled by the serializer and must
  employ a custom serializer/deserializer routine.
  - Enums and Errors are serialized as their integer values.
  - Optionals are serialized as a single `0` value integer
  if they are null. If the optional is not null, then a
  `1` value integer is serialized, followed by the serialization
  of the payload. As with unions, the number of bytes consumed is
  dependant on the payload type.
  - All other types are not handled and require a custom 
  serializer/deserializer routine.
  
## Types
```zig
pub const Packing = enum {
    /// Pack data to byte alignment
    Byte,

    /// Pack data to bit alignment
    Bit,
};
```
Used to specify the packing type of a `Serializer` or `Deserializer`.


```zig
pub fn Deserializer(comptime endian: builtin.Endian, comptime packing: Packing, comptime Reader: type) type
```
Creates a deserializer that deserializes types from the given `Reader` type. The `Deserializer` provides the following functions:


```zig
pub fn deserialize(self: *Self, comptime T: type) !T
```
Deserializes and returns type `T` from the underlying reader.


```zig
pub fn deserializeInto(self: *Self, ptr: anytype) !void
```
Deserializes `@TypeOf(ptr)` into the location pointed to by pointer `ptr`.


The `deserializer` convenience function is provided to construct a deserializer instance directly from a reader instance.
```zig
pub fn deserializer(
    comptime endian: builtin.Endian,
    comptime packing: Packing,
    reader: anytype,
) Deserializer(endian, packing, @TypeOf(reader))
```

```zig
pub fn Serializer(comptime endian: builtin.Endian, comptime packing: Packing, comptime Writer: type) type
```
Creates a serializer that serializes types to the given `Writer` type. The `Serializer` provides the following functions:


```zig
pub fn flush(self: *Self) Error!void
```
If `Bit` packing is specified, the current bit buffer is written to the underlying writer, ensuring it is byte aligned. Otherwise it does nothing.


```zig
pub fn serialize(self: *Self, value: anytype) Error!void
```
Serializes `value` to the underlying writer.


The `serializer` convenience function is provided to construct a serializer instance directly from a writer instance.
```zig
pub fn serializer(
    comptime endian: builtin.Endian,
    comptime packing: Packing,
    writer: anytype,
) Serializer(endian, packing, @TypeOf(writer))
```
