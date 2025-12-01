//! Code generation for Zig stubs and clients from .proto definitions
//! Generates idiomatic Zig code for gRPC services and messages

const std = @import("std");
const proto_parser = @import("proto_parser.zig");
const Error = @import("error.zig").Error;

// Code generation options
pub const CodegenOptions = struct {
    output_dir: []const u8,
    package_prefix: ?[]const u8,
    generate_server: bool,
    generate_client: bool,
    use_async: bool,

    pub fn default() CodegenOptions {
        return CodegenOptions{
            .output_dir = "generated",
            .package_prefix = null,
            .generate_server = true,
            .generate_client = true,
            .use_async = true,
        };
    }
};

// Code generator context
pub const CodeGenerator = struct {
    allocator: std.mem.Allocator,
    options: CodegenOptions,
    output_buffer: std.ArrayListUnmanaged(u8),
    indent_level: u32,

    pub fn init(allocator: std.mem.Allocator, options: CodegenOptions) CodeGenerator {
        return CodeGenerator{
            .allocator = allocator,
            .options = options,
            .output_buffer = .{},
            .indent_level = 0,
        };
    }

    pub fn deinit(self: *CodeGenerator) void {
        self.output_buffer.deinit(self.allocator);
    }

    pub fn generateFromProto(self: *CodeGenerator, proto_file: *const proto_parser.ProtoFile) ![]const u8 {
        try self.generateHeader(proto_file);
        try self.generateImports();

        // Generate message structs
        for (proto_file.messages.items) |*message| {
            try self.generateMessage(message);
        }

        // Generate enum types
        for (proto_file.enums.items) |*enum_def| {
            try self.generateEnum(enum_def);
        }

        // Generate service interfaces
        for (proto_file.services.items) |*service| {
            try self.generateService(service);
        }

        return try self.output_buffer.toOwnedSlice(self.allocator);
    }

    fn generateHeader(self: *CodeGenerator, proto_file: *const proto_parser.ProtoFile) !void {
        try self.writeLine("//! Generated from .proto file");
        if (proto_file.package) |package| {
            try self.writef("//! Package: {s}", .{package});
        }
        try self.writeLine("//! DO NOT EDIT - This file is auto-generated");
        try self.writeLine("");
    }

    fn generateImports(self: *CodeGenerator) !void {
        try self.writeLine("const std = @import(\"std\");");
        try self.writeLine("const zrpc = @import(\"zrpc\");");
        try self.writeLine("const protobuf = zrpc.protobuf;");
        try self.writeLine("const Error = zrpc.Error;");
        try self.writeLine("");
    }

    fn generateMessage(self: *CodeGenerator, message: *const proto_parser.MessageDef) !void {
        try self.writef("pub const {s} = struct {{", .{message.name});
        self.indent();

        // Generate fields
        for (message.fields.items) |*field| {
            try self.generateField(field);
        }

        // Generate nested messages
        for (message.nested_messages.items) |*nested| {
            try self.generateMessage(nested);
        }

        // Generate nested enums
        for (message.nested_enums.items) |*nested_enum| {
            try self.generateEnum(nested_enum);
        }

        try self.writeLine("");
        try self.generateMessageMethods(message);

        self.dedent();
        try self.writeLine("};");
        try self.writeLine("");
    }

    fn generateField(self: *CodeGenerator, field: *const proto_parser.FieldDef) !void {
        const zig_type = try self.fieldTypeToZig(field);
        defer self.allocator.free(zig_type);

        if (field.label == .repeated) {
            try self.writef("{s}: std.ArrayList({s}),", .{ field.name, zig_type });
        } else if (field.label == .optional) {
            try self.writef("{s}: ?{s},", .{ field.name, zig_type });
        } else {
            try self.writef("{s}: {s},", .{ field.name, zig_type });
        }
    }

    fn generateMessageMethods(self: *CodeGenerator, message: *const proto_parser.MessageDef) !void {
        // Generate init method
        try self.writef("pub fn init(allocator: std.mem.Allocator) {s} {{", .{message.name});
        self.indent();
        try self.writef("return {s}{{", .{message.name});
        self.indent();

        for (message.fields.items) |*field| {
            if (field.label == .repeated) {
                const zig_type = try self.fieldTypeToZig(field);
                defer self.allocator.free(zig_type);
                try self.writef(".{s} = std.ArrayList({s}).init(allocator),", .{ field.name, zig_type });
            } else if (field.label == .optional) {
                try self.writef(".{s} = null,", .{field.name});
            } else {
                const default_value = try self.getDefaultValue(field);
                defer self.allocator.free(default_value);
                try self.writef(".{s} = {s},", .{ field.name, default_value });
            }
        }

        self.dedent();
        try self.writeLine("};");
        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");

        // Generate deinit method
        try self.writef("pub fn deinit(self: *{s}) void {{", .{message.name});
        self.indent();

        for (message.fields.items) |*field| {
            if (field.label == .repeated) {
                try self.writef("self.{s}.deinit();", .{field.name});
            } else if (field.field_type == .string or field.field_type == .bytes) {
                if (field.label == .optional) {
                    try self.writef("if (self.{s}) |val| self.allocator.free(val);", .{field.name});
                } else {
                    try self.writef("self.allocator.free(self.{s});", .{field.name});
                }
            }
        }

        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");

        // Generate encode method
        try self.writef("pub fn encode(self: *const {s}, allocator: std.mem.Allocator) ![]u8 {{", .{message.name});
        self.indent();
        try self.writeLine("var buffer = std.ArrayList(u8).init(allocator);");
        try self.writeLine("defer buffer.deinit();");
        try self.writeLine("");

        for (message.fields.items) |*field| {
            try self.generateFieldEncoding(field);
        }

        try self.writeLine("return try buffer.toOwnedSlice(allocator);");
        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");

        // Generate decode method
        try self.writef("pub fn decode(allocator: std.mem.Allocator, data: []const u8) !{s} {{", .{message.name});
        self.indent();
        try self.writeLine("var decoder = protobuf.Decoder.init(data);");
        try self.writef("var result = {s}.init(allocator);", .{message.name});
        try self.writeLine("");
        try self.writeLine("while (try decoder.hasMore()) {");
        self.indent();
        try self.writeLine("const tag = try decoder.readVarint();");
        try self.writeLine("const field_number = tag >> 3;");
        try self.writeLine("const wire_type = @as(u3, @truncate(tag));");
        try self.writeLine("");
        try self.writeLine("switch (field_number) {");
        self.indent();

        for (message.fields.items) |*field| {
            try self.generateFieldDecoding(field);
        }

        try self.writeLine("else => {");
        self.indent();
        try self.writeLine("try decoder.skipField(wire_type);");
        self.dedent();
        try self.writeLine("},");

        self.dedent();
        try self.writeLine("}");
        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");
        try self.writeLine("return result;");
        self.dedent();
        try self.writeLine("}");
    }

    fn generateFieldEncoding(self: *CodeGenerator, field: *const proto_parser.FieldDef) !void {
        const tag = (field.number << 3) | try self.getWireType(field.field_type);

        if (field.label == .repeated) {
            try self.writef("for (self.{s}.items) |item| {{", .{field.name});
            self.indent();
            try self.writef("try protobuf.encodeVarint(&buffer, {});", .{tag});
            try self.generateSingleFieldEncoding(field, "item");
            self.dedent();
            try self.writeLine("}");
        } else if (field.label == .optional) {
            try self.writef("if (self.{s}) |val| {{", .{field.name});
            self.indent();
            try self.writef("try protobuf.encodeVarint(&buffer, {});", .{tag});
            try self.generateSingleFieldEncoding(field, "val");
            self.dedent();
            try self.writeLine("}");
        } else {
            try self.writef("try protobuf.encodeVarint(&buffer, {});", .{tag});
            const value_expr = try std.fmt.allocPrint(self.allocator, "self.{s}", .{field.name});
            defer self.allocator.free(value_expr);
            try self.generateSingleFieldEncoding(field, value_expr);
        }
        try self.writeLine("");
    }

    fn generateSingleFieldEncoding(self: *CodeGenerator, field: *const proto_parser.FieldDef, value_expr: []const u8) !void {
        switch (field.field_type) {
            .int32, .uint32, .int64, .uint64, .sint32, .sint64 => {
                try self.writef("try protobuf.encodeVarint(&buffer, @as(u64, @bitCast(@as(i64, {s}))));", .{value_expr});
            },
            .fixed32, .sfixed32 => {
                try self.writef("try protobuf.encodeFixed32(&buffer, @as(u32, @bitCast({s})));", .{value_expr});
            },
            .fixed64, .sfixed64 => {
                try self.writef("try protobuf.encodeFixed64(&buffer, @as(u64, @bitCast({s})));", .{value_expr});
            },
            .float => {
                try self.writef("try protobuf.encodeFixed32(&buffer, @as(u32, @bitCast({s})));", .{value_expr});
            },
            .double => {
                try self.writef("try protobuf.encodeFixed64(&buffer, @as(u64, @bitCast({s})));", .{value_expr});
            },
            .bool => {
                try self.writef("try protobuf.encodeVarint(&buffer, if ({s}) 1 else 0);", .{value_expr});
            },
            .string, .bytes => {
                try self.writef("try protobuf.encodeString(&buffer, {s});", .{value_expr});
            },
            .message => {
                try self.writef("const encoded = try {s}.encode(allocator);", .{value_expr});
                try self.writeLine("defer allocator.free(encoded);");
                try self.writeLine("try protobuf.encodeString(&buffer, encoded);");
            },
            .enum_type => {
                try self.writef("try protobuf.encodeVarint(&buffer, @intFromEnum({s}));", .{value_expr});
            },
        }
    }

    fn generateFieldDecoding(self: *CodeGenerator, field: *const proto_parser.FieldDef) !void {
        try self.writef("{} => {{", .{field.number});
        self.indent();

        const decode_expr = switch (field.field_type) {
            .int32 => "try decoder.readVarint()",
            .uint32 => "try decoder.readVarint()",
            .int64 => "@as(i64, @bitCast(try decoder.readVarint()))",
            .uint64 => "try decoder.readVarint()",
            .sint32 => "protobuf.zigzagDecode32(@as(u32, @truncate(try decoder.readVarint())))",
            .sint64 => "protobuf.zigzagDecode64(try decoder.readVarint())",
            .fixed32 => "try decoder.readFixed32()",
            .fixed64 => "try decoder.readFixed64()",
            .sfixed32 => "@as(i32, @bitCast(try decoder.readFixed32()))",
            .sfixed64 => "@as(i64, @bitCast(try decoder.readFixed64()))",
            .float => "@as(f32, @bitCast(try decoder.readFixed32()))",
            .double => "@as(f64, @bitCast(try decoder.readFixed64()))",
            .bool => "(try decoder.readVarint()) != 0",
            .string => "try decoder.readString(allocator)",
            .bytes => "try decoder.readBytes(allocator)",
            .message => blk: {
                const type_name = field.type_name orelse "UnknownMessage";
                break :blk try std.fmt.allocPrint(self.allocator, "try {s}.decode(allocator, try decoder.readBytes(allocator))", .{type_name});
            },
            .enum_type => blk: {
                const type_name = field.type_name orelse "UnknownEnum";
                break :blk try std.fmt.allocPrint(self.allocator, "@as({s}, @enumFromInt(try decoder.readVarint()))", .{type_name});
            },
        };

        if (field.label == .repeated) {
            try self.writef("try result.{s}.append(allocator, {s});", .{ field.name, decode_expr });
        } else {
            try self.writef("result.{s} = {s};", .{ field.name, decode_expr });
        }

        self.dedent();
        try self.writeLine("},");
    }

    fn generateEnum(self: *CodeGenerator, enum_def: *const proto_parser.EnumDef) !void {
        try self.writef("pub const {s} = enum(i32) {{", .{enum_def.name});
        self.indent();

        for (enum_def.values.items) |*value| {
            try self.writef("{s} = {},", .{ value.name, value.number });
        }

        self.dedent();
        try self.writeLine("};");
        try self.writeLine("");
    }

    fn generateService(self: *CodeGenerator, service: *const proto_parser.ServiceDef) !void {
        if (self.options.generate_server) {
            try self.generateServerInterface(service);
        }

        if (self.options.generate_client) {
            try self.generateClientStub(service);
        }
    }

    fn generateServerInterface(self: *CodeGenerator, service: *const proto_parser.ServiceDef) !void {
        try self.writef("pub const {s}Server = struct {{", .{service.name});
        self.indent();

        try self.writeLine("allocator: std.mem.Allocator,");
        try self.writeLine("server: *zrpc.Server,");
        try self.writeLine("");

        // Generate method interface definitions
        for (service.methods.items) |*method| {
            try self.generateServerMethod(method);
        }

        // Generate register method
        try self.writef("pub fn register(self: *{s}Server, server: *zrpc.Server) !void {{", .{service.name});
        self.indent();

        for (service.methods.items) |*method| {
            const method_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ service.name, method.name });
            defer self.allocator.free(method_path);
            try self.writef("try server.registerMethod(\"{s}\", {s}Handler, self);", .{ method_path, method.name });
        }

        self.dedent();
        try self.writeLine("}");

        self.dedent();
        try self.writeLine("};");
        try self.writeLine("");
    }

    fn generateServerMethod(self: *CodeGenerator, method: *const proto_parser.MethodDef) !void {
        if (method.client_streaming and method.server_streaming) {
            try self.writef("pub fn {s}(self: *{s}Server, stream: *zrpc.streaming.BidirectionalStream({s}, {s})) !void {{", .{ method.name, "TODO", method.input_type, method.output_type });
        } else if (method.client_streaming) {
            try self.writef("pub fn {s}(self: *{s}Server, stream: *zrpc.streaming.ClientStream({s})) !{s} {{", .{ method.name, "TODO", method.input_type, method.output_type });
        } else if (method.server_streaming) {
            try self.writef("pub fn {s}(self: *{s}Server, request: {s}, stream: *zrpc.streaming.ServerStream({s})) !void {{", .{ method.name, "TODO", method.input_type, method.output_type });
        } else {
            try self.writef("pub fn {s}(self: *{s}Server, request: {s}) !{s} {{", .{ method.name, "TODO", method.input_type, method.output_type });
        }

        self.indent();
        try self.writeLine("_ = self;");
        if (!method.client_streaming and !method.server_streaming) {
            try self.writeLine("_ = request;");
            try self.writeLine("return Error.Unimplemented;");
        } else {
            try self.writeLine("return Error.Unimplemented;");
        }
        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");

        // Generate handler wrapper
        try self.writef("fn {s}Handler(context: *anyopaque, request: []const u8) ![]const u8 {{", .{method.name});
        self.indent();
        try self.writef("const self = @as(*{s}Server, @ptrCast(@alignCast(context)));", .{"TODO"});
        try self.writef("const req = try {s}.decode(self.allocator, request);", .{method.input_type});
        try self.writef("defer req.deinit();", .{});
        try self.writef("const response = try self.{s}(req);", .{method.name});
        try self.writeLine("return try response.encode(self.allocator);");
        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");
    }

    fn generateClientStub(self: *CodeGenerator, service: *const proto_parser.ServiceDef) !void {
        try self.writef("pub const {s}Client = struct {{", .{service.name});
        self.indent();

        try self.writeLine("allocator: std.mem.Allocator,");
        try self.writeLine("client: *zrpc.Client,");
        try self.writeLine("");

        try self.writef("pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !{s}Client {{", .{service.name});
        self.indent();
        try self.writeLine("const client = try zrpc.Client.init(allocator, endpoint);");
        try self.writef("return {s}Client{{", .{service.name});
        self.indent();
        try self.writeLine(".allocator = allocator,");
        try self.writeLine(".client = client,");
        self.dedent();
        try self.writeLine("};");
        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");

        try self.writef("pub fn deinit(self: *{s}Client) void {{", .{service.name});
        self.indent();
        try self.writeLine("self.client.deinit();");
        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");

        // Generate client methods
        for (service.methods.items) |*method| {
            try self.generateClientMethod(service, method);
        }

        self.dedent();
        try self.writeLine("};");
        try self.writeLine("");
    }

    fn generateClientMethod(self: *CodeGenerator, service: *const proto_parser.ServiceDef, method: *const proto_parser.MethodDef) !void {
        if (method.client_streaming and method.server_streaming) {
            try self.writef("pub fn {s}(self: *{s}Client) !*zrpc.streaming.BidirectionalStream({s}, {s}) {{", .{ method.name, service.name, method.input_type, method.output_type });
        } else if (method.client_streaming) {
            try self.writef("pub fn {s}(self: *{s}Client) !*zrpc.streaming.ClientStream({s}) {{", .{ method.name, service.name, method.input_type });
        } else if (method.server_streaming) {
            try self.writef("pub fn {s}(self: *{s}Client, request: {s}) !*zrpc.streaming.ServerStream({s}) {{", .{ method.name, service.name, method.input_type, method.output_type });
        } else {
            try self.writef("pub fn {s}(self: *{s}Client, request: {s}) !{s} {{", .{ method.name, service.name, method.input_type, method.output_type });
        }

        self.indent();

        if (!method.client_streaming and !method.server_streaming) {
            // Unary call
            try self.writeLine("const request_data = try request.encode(self.allocator);");
            try self.writeLine("defer self.allocator.free(request_data);");
            try self.writeLine("");

            const method_path = try std.fmt.allocPrint(self.allocator, "/{s}/{s}", .{ service.name, method.name });
            defer self.allocator.free(method_path);

            try self.writef("const response_data = try self.client.call(\"{s}\", request_data);", .{method_path});
            try self.writeLine("defer self.allocator.free(response_data);");
            try self.writeLine("");
            try self.writef("return try {s}.decode(self.allocator, response_data);", .{method.output_type});
        } else {
            // Streaming calls
            try self.writeLine("return Error.Unimplemented;");
        }

        self.dedent();
        try self.writeLine("}");
        try self.writeLine("");
    }

    // Helper methods
    fn fieldTypeToZig(self: *CodeGenerator, field: *const proto_parser.FieldDef) ![]u8 {
        return switch (field.field_type) {
            .double => try self.allocator.dupe(u8, "f64"),
            .float => try self.allocator.dupe(u8, "f32"),
            .int32, .sint32, .sfixed32 => try self.allocator.dupe(u8, "i32"),
            .int64, .sint64, .sfixed64 => try self.allocator.dupe(u8, "i64"),
            .uint32, .fixed32 => try self.allocator.dupe(u8, "u32"),
            .uint64, .fixed64 => try self.allocator.dupe(u8, "u64"),
            .bool => try self.allocator.dupe(u8, "bool"),
            .string => try self.allocator.dupe(u8, "[]const u8"),
            .bytes => try self.allocator.dupe(u8, "[]const u8"),
            .message, .enum_type => {
                if (field.type_name) |type_name| {
                    return try self.allocator.dupe(u8, type_name);
                } else {
                    return try self.allocator.dupe(u8, "void");
                }
            },
        };
    }

    fn getDefaultValue(self: *CodeGenerator, field: *const proto_parser.FieldDef) ![]u8 {
        return switch (field.field_type) {
            .double, .float => try self.allocator.dupe(u8, "0.0"),
            .int32, .int64, .uint32, .uint64, .sint32, .sint64, .fixed32, .fixed64, .sfixed32, .sfixed64 => try self.allocator.dupe(u8, "0"),
            .bool => try self.allocator.dupe(u8, "false"),
            .string, .bytes => try self.allocator.dupe(u8, "\"\""),
            .message => {
                if (field.type_name) |type_name| {
                    return try std.fmt.allocPrint(self.allocator, "{s}.init(allocator)", .{type_name});
                } else {
                    return try self.allocator.dupe(u8, "void{{}}");
                }
            },
            .enum_type => {
                if (field.type_name) |type_name| {
                    return try std.fmt.allocPrint(self.allocator, "@as({s}, @enumFromInt(0))", .{type_name});
                } else {
                    return try self.allocator.dupe(u8, "@as(i32, 0)");
                }
            },
        };
    }

    fn getWireType(self: *CodeGenerator, field_type: proto_parser.FieldType) !u3 {
        _ = self;
        return switch (field_type) {
            .int32, .int64, .uint32, .uint64, .sint32, .sint64, .bool, .enum_type => 0, // Varint
            .fixed64, .sfixed64, .double => 1, // 64-bit
            .string, .bytes, .message => 2, // Length-delimited
            .fixed32, .sfixed32, .float => 5, // 32-bit
        };
    }

    fn indent(self: *CodeGenerator) void {
        self.indent_level += 1;
    }

    fn dedent(self: *CodeGenerator) void {
        if (self.indent_level > 0) {
            self.indent_level -= 1;
        }
    }

    fn writeLine(self: *CodeGenerator, line: []const u8) !void {
        try self.writeIndent();
        try self.output_buffer.appendSlice(self.allocator, line);
        try self.output_buffer.append(self.allocator, '\n');
    }

    fn writef(self: *CodeGenerator, comptime fmt: []const u8, args: anytype) !void {
        try self.writeIndent();
        const line = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(line);
        try self.output_buffer.appendSlice(self.allocator, line);
        try self.output_buffer.append(self.allocator, '\n');
    }

    fn writeIndent(self: *CodeGenerator) !void {
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) {
            try self.output_buffer.appendSlice(self.allocator, "    ");
        }
    }
};

// Public API
pub fn generateZigCode(allocator: std.mem.Allocator, proto_file: *const proto_parser.ProtoFile, options: CodegenOptions) ![]const u8 {
    var generator = CodeGenerator.init(allocator, options);
    defer generator.deinit();

    // generateFromProto returns owned memory from toOwnedSlice, return it directly
    return try generator.generateFromProto(proto_file);
}

pub fn generateFromProtoFile(allocator: std.mem.Allocator, proto_path: []const u8, options: CodegenOptions) ![]const u8 {
    var proto_file = try proto_parser.parseProtoFromFile(allocator, proto_path);
    defer proto_file.deinit();

    return try generateZigCode(allocator, &proto_file, options);
}

// Tests
test "generate message struct" {
    const proto_content =
        \\syntax = "proto3";
        \\
        \\message TestMessage {
        \\  string name = 1;
        \\  int32 id = 2;
        \\  repeated string tags = 3;
        \\}
    ;

    var proto_file = try proto_parser.parseProtoFile(std.testing.allocator, proto_content);
    defer proto_file.deinit();

    const generated = try generateZigCode(std.testing.allocator, &proto_file, CodegenOptions.default());
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const TestMessage = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "name: []const u8,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "id: i32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "tags: std.ArrayList([]const u8),") != null);
}

test "generate service client" {
    const proto_content =
        \\syntax = "proto3";
        \\
        \\message Request {
        \\  string query = 1;
        \\}
        \\
        \\message Response {
        \\  string result = 1;
        \\}
        \\
        \\service TestService {
        \\  rpc Process(Request) returns (Response);
        \\}
    ;

    var proto_file = try proto_parser.parseProtoFile(std.testing.allocator, proto_content);
    defer proto_file.deinit();

    const generated = try generateZigCode(std.testing.allocator, &proto_file, CodegenOptions.default());
    defer std.testing.allocator.free(generated);

    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const TestServiceClient = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub const TestServiceServer = struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "pub fn Process(") != null);
}
