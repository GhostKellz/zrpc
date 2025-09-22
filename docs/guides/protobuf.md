# Protocol Buffers Integration Guide

zRPC provides comprehensive support for Protocol Buffers, including .proto file parsing and automatic Zig code generation. This guide covers everything from basic usage to advanced features.

## Overview

Protocol Buffers (protobuf) is a language-neutral, platform-neutral, extensible mechanism for serializing structured data. zRPC provides:

- **Proto File Parsing** - Complete .proto file parser with AST generation
- **Code Generation** - Generate Zig structs, enums, and service definitions
- **Serialization** - Efficient binary serialization/deserialization
- **gRPC Compatibility** - Full compatibility with standard gRPC services

## Quick Start

### Define a Service

Create `greeter.proto`:

```protobuf
syntax = "proto3";

package greeter;

// The greeting service definition.
service Greeter {
  // Sends a greeting
  rpc SayHello (HelloRequest) returns (HelloReply) {}

  // Sends multiple greetings
  rpc SayHelloStreamReply (HelloRequest) returns (stream HelloReply) {}

  // Collects names and sends a greeting
  rpc SayHelloStreamRequest (stream HelloRequest) returns (HelloReply) {}

  // Bidirectional streaming
  rpc SayHelloBidirectional (stream HelloRequest) returns (stream HelloReply) {}
}

// The request message containing the user's name.
message HelloRequest {
  string name = 1;
  int32 age = 2;
  repeated string interests = 3;

  enum Language {
    ENGLISH = 0;
    SPANISH = 1;
    FRENCH = 2;
  }

  Language language = 4;
}

// The response message containing the greetings.
message HelloReply {
  string message = 1;
  int64 timestamp = 2;
  bool success = 3;
}
```

### Generate Zig Code

```bash
zig build run -- codegen greeter.proto src/generated/greeter.zig
```

This generates:

```zig
// src/generated/greeter.zig
const std = @import("std");
const zrpc = @import("zrpc");

// Generated message types
pub const HelloRequest = struct {
    name: []const u8 = "",
    age: i32 = 0,
    interests: [][]const u8 = &[_][]const u8{},
    language: Language = .ENGLISH,

    pub const Language = enum(u32) {
        ENGLISH = 0,
        SPANISH = 1,
        FRENCH = 2,
    };

    // Protobuf serialization methods
    pub fn serialize(self: HelloRequest, allocator: std.mem.Allocator) ![]u8 {
        // Generated serialization code
        return zrpc.protobuf.ProtobufMessage.SerializerFor(HelloRequest).serialize(allocator, self);
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !HelloRequest {
        return zrpc.protobuf.ProtobufMessage.SerializerFor(HelloRequest).deserialize(allocator, data);
    }
};

pub const HelloReply = struct {
    message: []const u8 = "",
    timestamp: i64 = 0,
    success: bool = false,

    pub fn serialize(self: HelloReply, allocator: std.mem.Allocator) ![]u8 {
        return zrpc.protobuf.ProtobufMessage.SerializerFor(HelloReply).serialize(allocator, self);
    }

    pub fn deserialize(allocator: std.mem.Allocator, data: []const u8) !HelloReply {
        return zrpc.protobuf.ProtobufMessage.SerializerFor(HelloReply).deserialize(allocator, data);
    }
};

// Generated service definition
pub const GreeterService = struct {
    pub const service_name = "greeter.Greeter";

    pub const Methods = struct {
        pub const say_hello = "SayHello";
        pub const say_hello_stream_reply = "SayHelloStreamReply";
        pub const say_hello_stream_request = "SayHelloStreamRequest";
        pub const say_hello_bidirectional = "SayHelloBidirectional";
    };
};

// Generated client
pub const GreeterClient = struct {
    client: zrpc.Client,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) GreeterClient {
        return GreeterClient{
            .client = zrpc.Client.init(allocator, endpoint),
        };
    }

    pub fn sayHello(
        self: *GreeterClient,
        request: HelloRequest,
        context: ?*zrpc.CallContext,
    ) !HelloReply {
        return try self.client.call(
            GreeterService.service_name ++ "/" ++ GreeterService.Methods.say_hello,
            request,
            HelloReply,
            context,
        );
    }

    pub fn sayHelloStreamReply(
        self: *GreeterClient,
        request: HelloRequest,
        context: ?*zrpc.CallContext,
    ) !zrpc.streaming.Stream(HelloReply) {
        return try self.client.serverStream(
            GreeterService.service_name ++ "/" ++ GreeterService.Methods.say_hello_stream_reply,
            request,
            HelloReply,
            context,
        );
    }

    // Additional streaming methods...
};
```

### Use Generated Code

```zig
const std = @import("std");
const zrpc = @import("zrpc");
const greeter = @import("generated/greeter.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = greeter.GreeterClient.init(allocator, "localhost:8080");

    // Create request
    const request = greeter.HelloRequest{
        .name = "World",
        .age = 25,
        .interests = &[_][]const u8{ "programming", "music" },
        .language = .ENGLISH,
    };

    // Make RPC call
    const response = try client.sayHello(request, null);

    std.debug.print("Response: {s}\n", .{response.message});
    std.debug.print("Timestamp: {}\n", .{response.timestamp});
}
```

## Proto File Parsing

### Parser API

```zig
const std = @import("std");
const zrpc = @import("zrpc");

pub fn parseProtoFile(allocator: std.mem.Allocator, file_path: []const u8) !void {
    // Parse .proto file
    const proto_file = try zrpc.parseProtoFromFile(allocator, file_path);
    defer proto_file.deinit();

    std.debug.print("Package: {s}\n", .{proto_file.package});
    std.debug.print("Syntax: {s}\n", .{proto_file.syntax});

    // Iterate through messages
    for (proto_file.messages) |message| {
        std.debug.print("Message: {s}\n", .{message.name});

        for (message.fields) |field| {
            std.debug.print("  Field: {s} ({s}) = {}\n", .{
                field.name,
                @tagName(field.field_type),
                field.number,
            });
        }
    }

    // Iterate through services
    for (proto_file.services) |service| {
        std.debug.print("Service: {s}\n", .{service.name});

        for (service.methods) |method| {
            std.debug.print("  Method: {s}\n", .{method.name});
            std.debug.print("    Input: {s}\n", .{method.input_type});
            std.debug.print("    Output: {s}\n", .{method.output_type});
            std.debug.print("    Client Streaming: {}\n", .{method.client_streaming});
            std.debug.print("    Server Streaming: {}\n", .{method.server_streaming});
        }
    }
}
```

### AST Structure

The parser creates a complete Abstract Syntax Tree:

```zig
pub const ProtoFile = struct {
    syntax: []const u8,
    package: []const u8,
    imports: [][]const u8,
    messages: []MessageDef,
    services: []ServiceDef,
    enums: []EnumDef,
    options: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ProtoFile) void {
        // Cleanup implementation
    }
};

pub const MessageDef = struct {
    name: []const u8,
    fields: []FieldDef,
    nested_messages: []MessageDef,
    nested_enums: []EnumDef,
    options: std.StringHashMap([]const u8),
};

pub const FieldDef = struct {
    name: []const u8,
    field_type: FieldType,
    number: u32,
    label: FieldLabel,
    default_value: ?[]const u8,
    options: std.StringHashMap([]const u8),

    pub const FieldType = union(enum) {
        scalar: ScalarType,
        message: []const u8,
        enum_type: []const u8,
        map: MapType,
    };

    pub const FieldLabel = enum {
        optional,
        required,
        repeated,
    };

    pub const ScalarType = enum {
        double,
        float,
        int32,
        int64,
        uint32,
        uint64,
        sint32,
        sint64,
        fixed32,
        fixed64,
        sfixed32,
        sfixed64,
        bool,
        string,
        bytes,
    };

    pub const MapType = struct {
        key_type: ScalarType,
        value_type: FieldType,
    };
};

pub const ServiceDef = struct {
    name: []const u8,
    methods: []MethodDef,
    options: std.StringHashMap([]const u8),
};

pub const MethodDef = struct {
    name: []const u8,
    input_type: []const u8,
    output_type: []const u8,
    client_streaming: bool,
    server_streaming: bool,
    options: std.StringHashMap([]const u8),
};
```

## Code Generation

### Generation Options

```zig
const codegen_options = zrpc.CodegenOptions{
    .package_name = "myapi",
    .output_dir = "src/generated",
    .generate_client = true,
    .generate_server = true,
    .generate_tests = true,
    .async_methods = false,
    .json_serialization = true,
    .validation = true,
};

const generated_code = try zrpc.generateFromProtoFile(
    allocator,
    "api.proto",
    codegen_options,
);
defer allocator.free(generated_code);
```

### Custom Templates

Create custom generation templates:

```zig
const custom_template =
\\// Custom header
\\const std = @import("std");
\\const zrpc = @import("zrpc");
\\
\\{{#messages}}
\\pub const {{name}} = struct {
\\{{#fields}}
\\    {{name}}: {{zig_type}},
\\{{/fields}}
\\
\\    // Custom validation method
\\    pub fn validate(self: {{name}}) !void {
\\        // Generated validation code
\\    }
\\};
\\
\\{{/messages}}
;

const template_options = zrpc.CodegenOptions{
    .custom_template = custom_template,
    .template_variables = std.StringHashMap([]const u8).init(allocator),
};
```

### Build Integration

Add code generation to your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Add codegen step
    const codegen_step = b.step("codegen", "Generate code from .proto files");

    const proto_files = [_][]const u8{
        "proto/greeter.proto",
        "proto/user.proto",
        "proto/order.proto",
    };

    for (proto_files) |proto_file| {
        const codegen_cmd = b.addRunArtifact(b.dependency("zrpc", .{}).artifact("zrpc"));
        codegen_cmd.addArg("codegen");
        codegen_cmd.addArg(proto_file);

        const output_file = std.fs.path.basename(proto_file);
        const zig_file = try std.fmt.allocPrint(b.allocator, "src/generated/{s}.zig", .{output_file[0..output_file.len-6]});
        codegen_cmd.addArg(zig_file);

        codegen_step.dependOn(&codegen_cmd.step);
    }

    // Main executable depends on codegen
    const exe = b.addExecutable(.{
        .name = "myapp",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.step.dependOn(codegen_step);
}
```

## Advanced Features

### Well-Known Types

zRPC supports Google's well-known types:

```protobuf
syntax = "proto3";

import "google/protobuf/timestamp.proto";
import "google/protobuf/duration.proto";
import "google/protobuf/struct.proto";
import "google/protobuf/any.proto";

message Event {
  string name = 1;
  google.protobuf.Timestamp created_at = 2;
  google.protobuf.Duration duration = 3;
  google.protobuf.Struct metadata = 4;
  google.protobuf.Any payload = 5;
}
```

Generated Zig code:

```zig
pub const Event = struct {
    name: []const u8 = "",
    created_at: ?zrpc.protobuf.Timestamp = null,
    duration: ?zrpc.protobuf.Duration = null,
    metadata: ?zrpc.protobuf.Struct = null,
    payload: ?zrpc.protobuf.Any = null,
};
```

### Custom Options

Define and use custom options:

```protobuf
import "google/protobuf/descriptor.proto";

extend google.protobuf.FieldOptions {
  bool required_field = 50001;
  string validation_rule = 50002;
}

message User {
  string email = 1 [(required_field) = true, (validation_rule) = "email"];
  string password = 2 [(required_field) = true, (validation_rule) = "min:8"];
  int32 age = 3 [(validation_rule) = "min:0,max:120"];
}
```

Generated validation:

```zig
pub const User = struct {
    email: []const u8 = "",
    password: []const u8 = "",
    age: i32 = 0,

    pub fn validate(self: User) !void {
        // Email validation
        if (self.email.len == 0) return error.EmailRequired;
        if (!isValidEmail(self.email)) return error.InvalidEmail;

        // Password validation
        if (self.password.len == 0) return error.PasswordRequired;
        if (self.password.len < 8) return error.PasswordTooShort;

        // Age validation
        if (self.age < 0 or self.age > 120) return error.InvalidAge;
    }
};
```

### Oneof Fields

Handle oneof fields (union types):

```protobuf
message Payment {
  oneof payment_method {
    CreditCard credit_card = 1;
    BankTransfer bank_transfer = 2;
    Cryptocurrency crypto = 3;
  }

  double amount = 4;
  string currency = 5;
}
```

Generated code:

```zig
pub const Payment = struct {
    payment_method: ?PaymentMethod = null,
    amount: f64 = 0.0,
    currency: []const u8 = "",

    pub const PaymentMethod = union(enum) {
        credit_card: CreditCard,
        bank_transfer: BankTransfer,
        crypto: Cryptocurrency,
    };
};
```

### Maps

Handle map fields:

```protobuf
message UserPreferences {
  map<string, string> settings = 1;
  map<string, int32> counts = 2;
}
```

Generated code:

```zig
pub const UserPreferences = struct {
    settings: std.StringHashMap([]const u8),
    counts: std.StringHashMap(i32),

    pub fn init(allocator: std.mem.Allocator) UserPreferences {
        return UserPreferences{
            .settings = std.StringHashMap([]const u8).init(allocator),
            .counts = std.StringHashMap(i32).init(allocator),
        };
    }

    pub fn deinit(self: *UserPreferences) void {
        self.settings.deinit();
        self.counts.deinit();
    }
};
```

## Testing Generated Code

### Unit Tests

Generated code includes tests:

```zig
test "HelloRequest serialization" {
    const allocator = std.testing.allocator;

    const request = HelloRequest{
        .name = "Test User",
        .age = 30,
        .interests = &[_][]const u8{ "coding", "reading" },
        .language = .ENGLISH,
    };

    // Test serialization
    const serialized = try request.serialize(allocator);
    defer allocator.free(serialized);

    // Test deserialization
    const deserialized = try HelloRequest.deserialize(allocator, serialized);

    try std.testing.expectEqualStrings(request.name, deserialized.name);
    try std.testing.expectEqual(request.age, deserialized.age);
    try std.testing.expectEqual(request.language, deserialized.language);
}

test "GreeterClient integration" {
    const allocator = std.testing.allocator;

    // Mock server setup
    var server = zrpc.Server.init(allocator);
    defer server.deinit();

    const handler = zrpc.MethodHandler.unary(struct {
        fn handle(ctx: *zrpc.CallContext, request: []const u8) zrpc.Error![]u8 {
            const hello_request = try HelloRequest.deserialize(ctx.allocator, request);

            const reply = HelloReply{
                .message = try std.fmt.allocPrint(ctx.allocator, "Hello, {s}!", .{hello_request.name}),
                .timestamp = std.time.timestamp(),
                .success = true,
            };

            return try reply.serialize(ctx.allocator);
        }
    }.handle);

    try server.registerHandler("greeter.Greeter", "SayHello", handler);

    // Client test
    var client = greeter.GreeterClient.init(allocator, "localhost:8080");

    const request = HelloRequest{
        .name = "Test",
        .age = 25,
        .language = .ENGLISH,
    };

    const response = try client.sayHello(request, null);
    try std.testing.expect(response.success);
    try std.testing.expect(std.mem.indexOf(u8, response.message, "Hello, Test!") != null);
}
```

## Performance Optimization

### Zero-Copy Deserialization

For performance-critical applications:

```zig
pub const ZeroCopyMessage = struct {
    // Store references to original buffer instead of copying
    raw_data: []const u8,
    field_offsets: []u32,

    pub fn getName(self: ZeroCopyMessage) []const u8 {
        // Return slice into original buffer
        const start = self.field_offsets[0];
        const end = self.field_offsets[1];
        return self.raw_data[start..end];
    }
};
```

### Streaming Serialization

For large messages:

```zig
pub const StreamingSerializer = struct {
    writer: std.io.Writer,

    pub fn writeMessage(self: *StreamingSerializer, message: anytype) !void {
        // Stream serialization without buffering entire message
        try self.writeField(1, message.field1);
        try self.writeField(2, message.field2);
        // ...
    }
};
```

## Best Practices

1. **Version Compatibility**: Always use compatible field numbers
2. **Backward Compatibility**: Don't remove required fields
3. **Documentation**: Add comments to .proto files
4. **Validation**: Use custom options for validation rules
5. **Testing**: Test serialization round-trips
6. **Performance**: Use appropriate message sizes
7. **Security**: Validate all inputs from untrusted sources

## Migration Guide

### From JSON to Protobuf

```zig
// Before (JSON)
const User = struct {
    id: u32,
    name: []const u8,
    email: []const u8,
};

// After (Protobuf)
// Define user.proto, generate code, use:
const user = user_pb.User{
    .id = 123,
    .name = "John Doe",
    .email = "john@example.com",
};

const serialized = try user.serialize(allocator);
```

### Schema Evolution

```protobuf
// Version 1
message User {
  uint32 id = 1;
  string name = 2;
}

// Version 2 (backward compatible)
message User {
  uint32 id = 1;
  string name = 2;
  string email = 3; // New optional field
  reserved 4; // Reserved for future use
}
```

This guide provides comprehensive coverage of Protocol Buffers integration in zRPC, from basic usage to advanced features and optimization techniques.