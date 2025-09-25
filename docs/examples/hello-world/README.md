# Hello World Example

**The simplest possible zRPC application**

This example demonstrates the basic building blocks of a zRPC application: a server that responds to greetings and a client that sends greeting requests.

## What You'll Learn

- Basic client-server setup with zRPC
- Transport adapter configuration (QUIC)
- Unary RPC calls (request → response)
- TLS setup for development
- Error handling fundamentals

## Files Overview

```
hello-world/
├── src/
│   ├── types.zig        # Shared request/response types
│   ├── server.zig       # Greeting server implementation
│   ├── client.zig       # Greeting client implementation
│   └── main.zig         # Combined server/client for demo
├── build.zig            # Build configuration
└── README.md           # This file
```

## Code Walkthrough

### 1. Define Message Types (`src/types.zig`)

```zig
const std = @import("std");

// Request message for greeting
pub const GreetingRequest = struct {
    name: []const u8,
    language: []const u8 = "en", // Default to English
};

// Response message with greeting
pub const GreetingResponse = struct {
    message: []const u8,
    timestamp: i64,

    pub fn now(message: []const u8) GreetingResponse {
        return GreetingResponse{
            .message = message,
            .timestamp = std.time.milliTimestamp(),
        };
    }
};
```

### 2. Implement the Server (`src/server.zig`)

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
const types = @import("types.zig");

const GreetingService = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    pub fn greet(self: *Self, request: types.GreetingRequest, context: *const zrpc.RequestContext) !types.GreetingResponse {
        _ = self; // Service state not needed for this simple example
        _ = context; // Context not needed for this example

        std.log.info("Greeting request from: {s} (language: {s})", .{ request.name, request.language });

        // Generate greeting based on language
        const greeting = switch (request.language[0]) {
            'e' => try std.fmt.allocPrint(self.allocator, "Hello, {s}!", .{request.name}),
            's' => try std.fmt.allocPrint(self.allocator, "¡Hola, {s}!", .{request.name}),
            'f' => try std.fmt.allocPrint(self.allocator, "Bonjour, {s}!", .{request.name}),
            'g' => try std.fmt.allocPrint(self.allocator, "Guten Tag, {s}!", .{request.name}),
            'd' => try std.fmt.allocPrint(self.allocator, "Hej, {s}!", .{request.name}),
            else => try std.fmt.allocPrint(self.allocator, "Hello, {s}!", .{request.name}),
        };

        return types.GreetingResponse.now(greeting);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 Starting Hello World Server...");

    // Create QUIC transport adapter
    var transport = quic_transport.createServerTransport(allocator);
    defer transport.deinit();

    // Configure server
    var server_config = zrpc.ServerConfig.default(transport);
    server_config.enable_debug_logging = true;
    server_config.max_connections = 100;
    server_config.request_timeout_ms = 5000; // 5 second timeout

    // Create server
    var server = try zrpc.Server.init(allocator, server_config);
    defer server.deinit();

    // TLS configuration for development (INSECURE - don't use in production!)
    var tls_config = zrpc.TlsConfig.development();

    // Bind to address
    try server.bind("0.0.0.0:8443", &tls_config);
    std.log.info("📡 Server listening on 0.0.0.0:8443");

    // Create greeting service
    var greeting_service = GreetingService.init(allocator);

    // Register the greet method
    try server.registerHandler(
        "Greeting/Greet",                 // Service/Method name
        types.GreetingRequest,            // Request type
        types.GreetingResponse,           // Response type
        zrpc.MethodHandler(types.GreetingRequest, types.GreetingResponse){
            .handler_fn = @ptrCast(&greeting_service.greet),
        }
    );

    std.log.info("✅ Greeting service registered");
    std.log.info("🔥 Server ready to greet the world!");

    // Start serving requests
    try server.serve();
}
```

### 3. Implement the Client (`src/client.zig`)

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
const types = @import("types.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("👋 Hello World Client Starting...");

    // Create QUIC transport adapter
    var transport = quic_transport.createClientTransport(allocator);
    defer transport.deinit();

    // Configure client
    var client_config = zrpc.ClientConfig.default(transport);
    client_config.enable_debug_logging = true;
    client_config.request_timeout_ms = 5000; // 5 second timeout

    // Create client
    var client = try zrpc.Client.init(allocator, client_config);
    defer client.deinit();

    // TLS configuration (matches server - INSECURE for development)
    var tls_config = zrpc.TlsConfig.development();

    // Connect to server
    try client.connect("localhost:8443", &tls_config);
    std.log.info("✅ Connected to Hello World server");

    // Test different greetings
    const greetings = [_]types.GreetingRequest{
        .{ .name = "World", .language = "en" },
        .{ .name = "Alice", .language = "en" },
        .{ .name = "José", .language = "es" },
        .{ .name = "Marie", .language = "fr" },
        .{ .name = "Hans", .language = "de" },
        .{ .name = "Lars", .language = "da" },
    };

    for (greetings) |greeting_request| {
        std.log.info("📤 Sending greeting request for: {s} ({s})", .{ greeting_request.name, greeting_request.language });

        const greeting_response = client.call(
            types.GreetingRequest,
            types.GreetingResponse,
            "Greeting/Greet",
            greeting_request
        ) catch |err| {
            std.log.err("❌ Failed to send greeting: {}", .{err});
            continue;
        };

        std.log.info("📥 Received: {s} (at {})", .{ greeting_response.message, greeting_response.timestamp });

        // Small delay between requests for demo effect
        std.time.sleep(500 * std.time.ns_per_ms);
    }

    std.log.info("🎉 Hello World client completed!");
}
```

### 4. Build Configuration (`build.zig`)

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // In a real project, these would be dependencies from build.zig.zon
    const zrpc_core = b.addModule("zrpc-core", .{
        .root_source_file = b.path("../../../src/core.zig"),
        .target = target,
    });

    const quic_transport = b.addModule("zrpc-transport-quic", .{
        .root_source_file = b.path("../../../src/adapters/quic.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zrpc-core", .module = zrpc_core },
        },
    });

    // Server executable
    const server_exe = b.addExecutable(.{
        .name = "hello-server",
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_exe.root_module.addImport("zrpc-core", zrpc_core);
    server_exe.root_module.addImport("zrpc-transport-quic", quic_transport);

    // Client executable
    const client_exe = b.addExecutable(.{
        .name = "hello-client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_exe.root_module.addImport("zrpc-core", zrpc_core);
    client_exe.root_module.addImport("zrpc-transport-quic", quic_transport);

    // Install executables
    b.installArtifact(server_exe);
    b.installArtifact(client_exe);

    // Run steps
    const run_server_step = b.step("server", "Run the Hello World server");
    const run_server_cmd = b.addRunArtifact(server_exe);
    run_server_cmd.step.dependOn(b.getInstallStep());
    run_server_step.dependOn(&run_server_cmd.step);

    const run_client_step = b.step("client", "Run the Hello World client");
    const run_client_cmd = b.addRunArtifact(client_exe);
    run_client_cmd.step.dependOn(b.getInstallStep());
    run_client_step.dependOn(&run_client_cmd.step);

    // Test step
    const test_step = b.step("test", "Run tests");
    const server_tests = b.addTest(.{ .root_source_file = b.path("src/server.zig") });
    const client_tests = b.addTest(.{ .root_source_file = b.path("src/client.zig") });

    const run_server_tests = b.addRunArtifact(server_tests);
    const run_client_tests = b.addRunArtifact(client_tests);

    test_step.dependOn(&run_server_tests.step);
    test_step.dependOn(&run_client_tests.step);
}
```

## Running the Example

### Prerequisites

Ensure you have **Zig 0.16.0-dev** or compatible installed:

```bash
zig version
```

### Step 1: Build the Example

```bash
cd docs/examples/hello-world
zig build
```

### Step 2: Run the Server

In one terminal:

```bash
zig build server
```

You should see:
```
info: 🚀 Starting Hello World Server...
info: 📡 Server listening on 0.0.0.0:8443
info: ✅ Greeting service registered
info: 🔥 Server ready to greet the world!
```

### Step 3: Run the Client

In another terminal:

```bash
zig build client
```

You should see:
```
info: 👋 Hello World Client Starting...
info: ✅ Connected to Hello World server
info: 📤 Sending greeting request for: World (en)
info: 📥 Received: Hello, World! (at 1703097234567)
info: 📤 Sending greeting request for: Alice (en)
info: 📥 Received: Hello, Alice! (at 1703097235067)
info: 📤 Sending greeting request for: José (es)
info: 📥 Received: ¡Hola, José! (at 1703097235567)
info: 📤 Sending greeting request for: Marie (fr)
info: 📥 Received: Bonjour, Marie! (at 1703097236067)
info: 📤 Sending greeting request for: Hans (de)
info: 📥 Received: Guten Tag, Hans! (at 1703097236567)
info: 📤 Sending greeting request for: Lars (da)
info: 📥 Received: Hej, Lars! (at 1703097237067)
info: 🎉 Hello World client completed!
```

The server terminal will show the incoming requests:
```
info: Greeting request from: World (language: en)
info: Greeting request from: Alice (language: en)
info: Greeting request from: José (language: es)
info: Greeting request from: Marie (language: fr)
info: Greeting request from: Hans (language: de)
info: Greeting request from: Lars (language: da)
```

## Key Concepts Explained

### 1. Transport Adapter Pattern

```zig
// Create transport adapter
var transport = quic_transport.createServerTransport(allocator);

// Inject into server/client
var server = try zrpc.Server.init(allocator, .{ .transport = transport });
```

This separation allows you to:
- Switch transports without changing RPC logic
- Test with mock transports
- Optimize transport independently

### 2. Type-Safe Method Registration

```zig
try server.registerHandler(
    "Greeting/Greet",                    // Method name
    types.GreetingRequest,               // Request type
    types.GreetingResponse,              // Response type
    zrpc.MethodHandler(...){             // Type-safe handler
        .handler_fn = @ptrCast(&greeting_service.greet)
    }
);
```

The type system ensures:
- Request/response types match
- Handlers have correct signatures
- Serialization/deserialization is automatic

### 3. Unified Error Handling

```zig
const response = client.call(...) catch |err| switch (err) {
    error.ConnectionFailed => {
        // Handle network issues
        return err;
    },
    error.RequestTimeout => {
        // Handle timeouts
        return err;
    },
    else => return err,
};
```

zRPC provides structured error handling across all transport types.

## Customization Examples

### Add Request Context

```zig
// Client with timeout
var context = zrpc.RequestContext.withDeadline(1000); // 1 second
const response = try client.callWithContext(
    types.GreetingRequest,
    types.GreetingResponse,
    "Greeting/Greet",
    request,
    &context
);

// Server using context
pub fn greet(self: *Self, request: types.GreetingRequest, context: *const zrpc.RequestContext) !types.GreetingResponse {
    if (context.isExpired()) {
        return error.DeadlineExceeded;
    }
    // ... handle request
}
```

### Add Authentication

```zig
// Client with authentication
var auth_config = zrpc.AuthConfig{
    .type = .bearer,
    .token = "your-auth-token-here",
};

var client_config = zrpc.ClientConfig{
    .transport = transport,
    .auth = auth_config,
};
```

### Custom Error Handling

```zig
// Server with custom error responses
pub fn greet(self: *Self, request: types.GreetingRequest, context: *const zrpc.RequestContext) !types.GreetingResponse {
    if (request.name.len == 0) {
        return error.InvalidArgument; // Maps to RPC status code
    }

    if (request.name.len > 100) {
        return error.InvalidArgument; // Name too long
    }

    // ... normal processing
}
```

## Testing

Run the included tests:

```bash
zig build test
```

The tests demonstrate:
- Unit testing service methods
- Mock transport usage
- Error condition testing

## Next Steps

After mastering this example:

1. **[Calculator Example](../calculator/)** - Multiple methods, error handling
2. **[Streaming Chat](../streaming-chat/)** - Real-time communication patterns
3. **[JWT Authentication](../jwt-auth/)** - Security implementation
4. **[High Throughput](../high-throughput/)** - Performance optimization

## Troubleshooting

### Common Issues

**Port already in use:**
```bash
# Check what's using port 8443
lsof -i :8443

# Kill the process
kill -9 <PID>

# Or use a different port in the code
```

**Build errors:**
```bash
# Clean and rebuild
zig build clean
zig build
```

**Connection refused:**
- Make sure the server is running first
- Check firewall settings
- Verify the port matches between server and client

**TLS errors:**
- This example uses development TLS (insecure)
- For production, use real certificates

### Enable Debug Mode

For more detailed logging:

```zig
var client_config = zrpc.ClientConfig{
    .transport = transport,
    .enable_debug_logging = true,
    .log_transport_frames = true, // Very detailed
};
```

---

**Success!** You've built your first zRPC application. The Hello World example demonstrates the fundamental patterns you'll use in all zRPC applications. Ready to move on to more advanced examples?