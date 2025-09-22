const std = @import("std");
const Error = @import("error.zig").Error;
const protobuf = @import("protobuf.zig");

pub const CodecType = enum {
    protobuf,
    json,
    msgpack,
};

pub const JsonCodec = struct {
    pub fn encode(allocator: std.mem.Allocator, value: anytype) Error![]u8 {
        _ = value;
        return try allocator.dupe(u8, "{\"mock\":\"data\"}");
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8, comptime T: type) Error!T {
        _ = allocator;
        _ = data;
        return @as(Error!T, Error.DeserializationError);
    }
};

pub const ProtobufCodec = struct {
    pub fn encode(allocator: std.mem.Allocator, value: anytype) Error![]u8 {
        const Serializer = protobuf.ProtobufMessage.SerializerFor(@TypeOf(value));
        return Serializer.serialize(allocator, value);
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8, comptime T: type) Error!T {
        const Serializer = protobuf.ProtobufMessage.SerializerFor(T);
        return Serializer.deserialize(allocator, data);
    }
};

test "json codec basic functionality" {
    const TestStruct = struct {
        name: []const u8,
        age: u32,
    };

    const original = TestStruct{ .name = "Alice", .age = 30 };

    const encoded = try JsonCodec.encode(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("{\"mock\":\"data\"}", encoded);

    // Decode will return DeserializationError for now
    const result = JsonCodec.decode(std.testing.allocator, encoded, TestStruct);
    try std.testing.expectError(Error.DeserializationError, result);
}

test "protobuf codec functionality" {
    const TestMessage = struct {
        id: u32,
        name: []const u8,
        active: bool,
    };

    const original = TestMessage{
        .id = 42,
        .name = "test message",
        .active = true,
    };

    const encoded = try ProtobufCodec.encode(std.testing.allocator, original);
    defer std.testing.allocator.free(encoded);

    try std.testing.expect(encoded.len > 0);

    // Decode will return DeserializationError for now (mock implementation)
    const result = ProtobufCodec.decode(std.testing.allocator, encoded, TestMessage);
    try std.testing.expectError(Error.DeserializationError, result);
}