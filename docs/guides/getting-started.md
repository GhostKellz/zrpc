# Getting Started with zRPC

This guide will walk you through setting up and using zRPC for your first RPC application.

## Prerequisites

- Zig 0.16.0-dev or later
- Basic understanding of RPC concepts
- Familiarity with Protocol Buffers (optional)

## Installation

### Using Zig Package Manager

Add zRPC to your project using `zig fetch`:

```bash
zig fetch --save https://github.com/ghostkellz/zrpc
```

### Manual Installation

Add zRPC to your `build.zig.zon`:

```zig
.dependencies = .{
    .zrpc = .{
        .url = "https://github.com/ghostkellz/zrpc/archive/refs/heads/main.tar.gz",
        .hash = "...", // Will be filled by `zig fetch`
    },
},
```

### Build Configuration

In your `build.zig`, add zRPC as a dependency:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zrpc_dep = b.dependency("zrpc", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "my-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zrpc", zrpc_dep.module("zrpc"));
    b.installArtifact(exe);
}
```

## Your First RPC Service

Let's create a simple greeting service that demonstrates the basic concepts.

### Step 1: Define Message Types

Create `src/messages.zig`:

```zig
// Request message for greeting
pub const GreetRequest = struct {
    name: []const u8,
    language: []const u8 = "en",
};

// Response message for greeting
pub const GreetResponse = struct {
    message: []const u8,
    timestamp: i64,
};

// Request for list operation
pub const ListRequest = struct {
    limit: u32 = 10,
    offset: u32 = 0,
};

// Response for list operation
pub const ListResponse = struct {
    items: [][]const u8,
    total: u32,
};
```

### Step 2: Create the Server

Create `src/server.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc");
const messages = @import("messages.zig");

const GreeterService = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GreeterService {
        return GreeterService{ .allocator = allocator };
    }

    pub fn greetHandler(ctx: *zrpc.CallContext, request: []const u8) zrpc.Error![]u8 {
        // In a real implementation, deserialize the request from JSON/protobuf
        _ = request;

        // For demo purposes, create a mock response
        const response = messages.GreetResponse{
            .message = "Hello from zRPC!",
            .timestamp = std.time.timestamp(),
        };

        // In a real implementation, serialize the response to JSON/protobuf
        // For now, return a simple string
        return try ctx.allocator.dupe(u8, "Hello from zRPC!");
    }

    pub fn listHandler(ctx: *zrpc.CallContext, request: []const u8) zrpc.Error![]u8 {
        _ = request;

        // Mock list response
        return try ctx.allocator.dupe(u8, "item1,item2,item3");
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create server
    var server = zrpc.Server.init(allocator);
    defer server.deinit();

    // Create service instance
    var greeter = GreeterService.init(allocator);
    _ = greeter;

    // Register handlers
    const greet_handler = zrpc.MethodHandler.unary(GreeterService.greetHandler);
    const list_handler = zrpc.MethodHandler.unary(GreeterService.listHandler);

    try server.registerHandler("Greeter", "Greet", greet_handler);
    try server.registerHandler("Greeter", "List", list_handler);

    // Start server
    std.debug.print("Starting zRPC server on localhost:8080\n");
    std.debug.print("Available methods:\n");
    std.debug.print("  - Greeter/Greet\n");
    std.debug.print("  - Greeter/List\n");

    try server.serve("localhost:8080");
}
```

### Step 3: Create the Client

Create `src/client.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc");
const messages = @import("messages.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create client
    var client = zrpc.Client.init(allocator, "localhost:8080");

    // Create call context with timeout and metadata
    var context = zrpc.CallContext.init(allocator);
    defer context.deinit();

    context.setDeadline(5000); // 5 second timeout
    try context.addMetadata("user-agent", "zrpc-example-client");
    try context.addMetadata("version", "1.0.0");

    // Make RPC calls
    std.debug.print("Making RPC calls to localhost:8080\n\n");

    // Call Greet method
    const greet_request = messages.GreetRequest{
        .name = "World",
        .language = "en",
    };

    std.debug.print("Calling Greeter/Greet...\n");
    const greet_response = client.call(
        "Greeter/Greet",
        greet_request,
        messages.GreetResponse,
        &context,
    ) catch |err| switch (err) {
        zrpc.Error.ConnectionTimeout => {
            std.debug.print("Error: Connection timeout\n");
            return;
        },
        zrpc.Error.NotFound => {
            std.debug.print("Error: Service or method not found\n");
            return;
        },
        else => return err,
    };

    _ = greet_response; // Use the response
    std.debug.print("Greet call completed successfully\n");

    // Call List method
    const list_request = messages.ListRequest{
        .limit = 5,
        .offset = 0,
    };

    std.debug.print("Calling Greeter/List...\n");
    const list_response = client.call(
        "Greeter/List",
        list_request,
        messages.ListResponse,
        &context,
    ) catch |err| switch (err) {
        zrpc.Error.ConnectionTimeout => {
            std.debug.print("Error: Connection timeout\n");
            return;
        },
        zrpc.Error.NotFound => {
            std.debug.print("Error: Service or method not found\n");
            return;
        },
        else => return err,
    };

    _ = list_response; // Use the response
    std.debug.print("List call completed successfully\n");

    std.debug.print("\nAll RPC calls completed!\n");
}
```

### Step 4: Build and Run

Create your project structure:

```
my-zrpc-app/
├── build.zig
├── build.zig.zon
└── src/
    ├── main.zig
    ├── server.zig
    ├── client.zig
    └── messages.zig
```

Build the project:

```bash
zig build
```

Run the server in one terminal:

```bash
zig build run -- server
```

Run the client in another terminal:

```bash
zig build run -- client
```

## Understanding the Code

### Server Side

1. **Service Definition**: We defined a `GreeterService` struct with handler methods
2. **Method Handlers**: Each RPC method has a handler function with the signature:
   ```zig
   fn handler(ctx: *zrpc.CallContext, request: []const u8) zrpc.Error![]u8
   ```
3. **Registration**: Handlers are registered with the server using service and method names
4. **Serving**: The server listens on a specified address for incoming requests

### Client Side

1. **Client Creation**: A client is initialized with the server endpoint
2. **Call Context**: Context provides timeout, metadata, and other call-specific options
3. **RPC Calls**: The `call()` method sends requests and receives responses
4. **Error Handling**: Proper error handling for timeouts, missing services, etc.

## Next Steps

Now that you have a basic RPC service running, you can explore:

1. **[Transport Layer](../api/transport.md)** - Configure HTTP/2 and QUIC transports
2. **[Authentication](auth.md)** - Add JWT and OAuth2 security
3. **[Streaming](../api/streaming.md)** - Implement streaming RPCs
4. **[Protocol Buffers](protobuf.md)** - Use .proto files for message definitions
5. **[Code Generation](codegen.md)** - Generate Zig code from .proto files

## Common Patterns

### Error Handling

```zig
const response = client.call(...) catch |err| switch (err) {
    zrpc.Error.ConnectionTimeout => {
        // Retry logic or user notification
        return handleTimeout();
    },
    zrpc.Error.Unauthorized => {
        // Refresh auth token
        return refreshAndRetry();
    },
    zrpc.Error.NotFound => {
        // Service discovery or fallback
        return tryAlternativeService();
    },
    else => return err, // Propagate unexpected errors
};
```

### Context Configuration

```zig
var context = zrpc.CallContext.init(allocator);
defer context.deinit();

// Set timeout
context.setDeadline(std.time.timestamp() + 30_000); // 30 seconds

// Add authentication
try context.addMetadata("authorization", "Bearer your-jwt-token");

// Add tracing headers
try context.addMetadata("x-trace-id", generateTraceId());

// Add custom metadata
try context.addMetadata("user-id", "12345");
try context.addMetadata("request-id", generateRequestId());
```

### Service Registration

```zig
// Register multiple methods for a service
const handlers = [_]struct { name: []const u8, handler: zrpc.MethodHandler }{
    .{ .name = "Create", .handler = zrpc.MethodHandler.unary(MyService.create) },
    .{ .name = "Read", .handler = zrpc.MethodHandler.unary(MyService.read) },
    .{ .name = "Update", .handler = zrpc.MethodHandler.unary(MyService.update) },
    .{ .name = "Delete", .handler = zrpc.MethodHandler.unary(MyService.delete) },
    .{ .name = "List", .handler = zrpc.MethodHandler.unary(MyService.list) },
};

for (handlers) |h| {
    try server.registerHandler("MyService", h.name, h.handler);
}
```

## Troubleshooting

### Common Issues

1. **Build Errors**: Ensure you're using Zig 0.16.0-dev or later
2. **Import Errors**: Check that zRPC is properly added to your `build.zig`
3. **Connection Issues**: Verify server is running and address is correct
4. **Serialization**: Currently using mock serialization - implement JSON/protobuf codecs

### Debug Mode

Enable debug logging:

```zig
// Add to your main function
const builtin = @import("builtin");
if (builtin.mode == .Debug) {
    std.debug.print("Debug mode enabled\n");
}
```

### Performance Tips

1. Reuse clients when possible
2. Configure appropriate timeouts
3. Use connection pooling for high-throughput applications
4. Monitor memory usage with the allocator

## Resources

- [API Reference](../api/README.md)
- [Examples](../examples/README.md)
- [Transport Configuration](transport.md)
- [Authentication Guide](auth.md)
- [Streaming Guide](streaming.md)