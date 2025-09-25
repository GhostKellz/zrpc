# Getting Started Tutorial

**Build your first zRPC application step by step**

This tutorial walks you through creating a complete RPC application using zRPC, from basic setup to advanced features.

## Prerequisites

- **Zig 0.16.0-dev** or compatible version
- Basic understanding of Zig programming language
- Network programming concepts (optional but helpful)

## Installation

### Option 1: Add as Dependency (Recommended)

Add zRPC to your `build.zig.zon`:

```zig
.{
    .name = "my-rpc-app",
    .version = "0.1.0",
    .dependencies = .{
        .@"zrpc-core" = .{
            .url = "https://github.com/ghostkellz/zrpc/releases/download/v2.0.0/zrpc-core.tar.gz",
            .hash = "12345...", // Actual hash will be provided
        },
        .@"zrpc-transport-quic" = .{
            .url = "https://github.com/ghostkellz/zrpc/releases/download/v2.0.0/zrpc-transport-quic.tar.gz",
            .hash = "67890...", // Actual hash will be provided
        },
    },
}
```

Update your `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const zrpc_core = b.dependency("zrpc-core", .{ .target = target, .optimize = optimize });
    const quic_transport = b.dependency("zrpc-transport-quic", .{ .target = target, .optimize = optimize });

    // Your executable
    const exe = b.addExecutable(.{
        .name = "my-rpc-app",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add module imports
    exe.root_module.addImport("zrpc-core", zrpc_core.module("zrpc-core"));
    exe.root_module.addImport("zrpc-transport-quic", quic_transport.module("zrpc-transport-quic"));

    b.installArtifact(exe);
}
```

### Option 2: Clone Repository

```bash
git clone https://github.com/ghostkellz/zrpc.git
cd zrpc
zig build test  # Verify installation
```

## Your First RPC Service

Let's create a simple calculator service that demonstrates basic RPC patterns.

### Step 1: Define Your Data Types

Create `src/calculator.zig`:

```zig
const std = @import("std");

// Request/Response types for our calculator service
pub const AddRequest = struct {
    a: f64,
    b: f64,
};

pub const AddResponse = struct {
    result: f64,
};

pub const MultiplyRequest = struct {
    a: f64,
    b: f64,
};

pub const MultiplyResponse = struct {
    result: f64,
};

pub const DivideRequest = struct {
    a: f64,
    b: f64,
};

pub const DivideResponse = struct {
    result: f64,
    error_message: ?[]const u8 = null,
};
```

### Step 2: Implement the Server

Create `src/server.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
const calculator = @import("calculator.zig");

// Calculator service implementation
const CalculatorService = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    // Add method handler
    pub fn add(self: *Self, request: calculator.AddRequest, context: *const zrpc.RequestContext) !calculator.AddResponse {
        _ = self;
        _ = context;

        std.log.info("Adding {} + {}", .{ request.a, request.b });

        return calculator.AddResponse{
            .result = request.a + request.b,
        };
    }

    // Multiply method handler
    pub fn multiply(self: *Self, request: calculator.MultiplyRequest, context: *const zrpc.RequestContext) !calculator.MultiplyResponse {
        _ = self;
        _ = context;

        std.log.info("Multiplying {} * {}", .{ request.a, request.b });

        return calculator.MultiplyResponse{
            .result = request.a * request.b,
        };
    }

    // Divide method handler with error handling
    pub fn divide(self: *Self, request: calculator.DivideRequest, context: *const zrpc.RequestContext) !calculator.DivideResponse {
        _ = self;
        _ = context;

        std.log.info("Dividing {} / {}", .{ request.a, request.b });

        if (request.b == 0.0) {
            return calculator.DivideResponse{
                .result = 0.0,
                .error_message = "Division by zero",
            };
        }

        return calculator.DivideResponse{
            .result = request.a / request.b,
        };
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 Starting Calculator Server...");

    // Create transport adapter
    var transport = quic_transport.createServerTransport(allocator);
    defer transport.deinit();

    // Configure server
    var server_config = zrpc.ServerConfig.default(transport);
    server_config.enable_debug_logging = true;
    server_config.max_connections = 100;

    // Create server
    var server = try zrpc.Server.init(allocator, server_config);
    defer server.deinit();

    // TLS configuration (for production, use real certificates)
    var tls_config = zrpc.TlsConfig.development(); // Insecure for development

    // Bind to address
    try server.bind("0.0.0.0:8443", &tls_config);
    std.log.info("📡 Server listening on 0.0.0.0:8443");

    // Create and register calculator service
    var calc_service = CalculatorService.init(allocator);

    // Register method handlers
    try server.registerHandler("Calculator/Add", calculator.AddRequest, calculator.AddResponse,
        zrpc.MethodHandler(calculator.AddRequest, calculator.AddResponse){
            .handler_fn = @ptrCast(&calc_service.add)
        });

    try server.registerHandler("Calculator/Multiply", calculator.MultiplyRequest, calculator.MultiplyResponse,
        zrpc.MethodHandler(calculator.MultiplyRequest, calculator.MultiplyResponse){
            .handler_fn = @ptrCast(&calc_service.multiply)
        });

    try server.registerHandler("Calculator/Divide", calculator.DivideRequest, calculator.DivideResponse,
        zrpc.MethodHandler(calculator.DivideRequest, calculator.DivideResponse){
            .handler_fn = @ptrCast(&calc_service.divide)
        });

    std.log.info("✅ Calculator service registered");

    // Start serving requests
    std.log.info("🔥 Server ready to serve requests!");
    try server.serve();
}
```

### Step 3: Implement the Client

Create `src/client.zig`:

```zig
const std = @import("std");
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
const calculator = @import("calculator.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🔌 Connecting to Calculator Server...");

    // Create transport adapter
    var transport = quic_transport.createClientTransport(allocator);
    defer transport.deinit();

    // Configure client
    var client_config = zrpc.ClientConfig.default(transport);
    client_config.enable_debug_logging = true;
    client_config.request_timeout_ms = 5000; // 5 second timeout

    // Create client
    var client = try zrpc.Client.init(allocator, client_config);
    defer client.deinit();

    // TLS configuration (matches server)
    var tls_config = zrpc.TlsConfig.development(); // Insecure for development

    // Connect to server
    try client.connect("localhost:8443", &tls_config);
    std.log.info("✅ Connected to server");

    // Test addition
    const add_request = calculator.AddRequest{ .a = 10.5, .b = 5.2 };
    const add_response = try client.call(calculator.AddRequest, calculator.AddResponse, "Calculator/Add", add_request);
    std.log.info("➕ {} + {} = {}", .{ add_request.a, add_request.b, add_response.result });

    // Test multiplication
    const mult_request = calculator.MultiplyRequest{ .a = 3.0, .b = 4.0 };
    const mult_response = try client.call(calculator.MultiplyRequest, calculator.MultiplyResponse, "Calculator/Multiply", mult_request);
    std.log.info("✖️  {} * {} = {}", .{ mult_request.a, mult_request.b, mult_response.result });

    // Test division (success case)
    const div_request = calculator.DivideRequest{ .a = 15.0, .b = 3.0 };
    const div_response = try client.call(calculator.DivideRequest, calculator.DivideResponse, "Calculator/Divide", div_request);
    if (div_response.error_message) |error_msg| {
        std.log.err("➗ Division error: {s}", .{error_msg});
    } else {
        std.log.info("➗ {} / {} = {}", .{ div_request.a, div_request.b, div_response.result });
    }

    // Test division by zero (error case)
    const div_zero_request = calculator.DivideRequest{ .a = 10.0, .b = 0.0 };
    const div_zero_response = try client.call(calculator.DivideRequest, calculator.DivideResponse, "Calculator/Divide", div_zero_request);
    if (div_zero_response.error_message) |error_msg| {
        std.log.warn("⚠️  Division error: {s}", .{error_msg});
    } else {
        std.log.info("➗ {} / {} = {}", .{ div_zero_request.a, div_zero_request.b, div_zero_response.result });
    }

    std.log.info("🎉 Calculator client completed successfully!");
}
```

### Step 4: Update build.zig

Create a complete `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Mock zRPC modules (in a real project, these would be dependencies)
    const zrpc_core = b.addModule("zrpc-core", .{
        .root_source_file = b.path("../../src/core.zig"), // Adjust path as needed
        .target = target,
    });

    const quic_transport = b.addModule("zrpc-transport-quic", .{
        .root_source_file = b.path("../../src/adapters/quic.zig"), // Adjust path as needed
        .target = target,
        .imports = &.{
            .{ .name = "zrpc-core", .module = zrpc_core },
        },
    });

    // Server executable
    const server_exe = b.addExecutable(.{
        .name = "calculator-server",
        .root_source_file = b.path("src/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    server_exe.root_module.addImport("zrpc-core", zrpc_core);
    server_exe.root_module.addImport("zrpc-transport-quic", quic_transport);

    // Client executable
    const client_exe = b.addExecutable(.{
        .name = "calculator-client",
        .root_source_file = b.path("src/client.zig"),
        .target = target,
        .optimize = optimize,
    });
    client_exe.root_module.addImport("zrpc-core", zrpc_core);
    client_exe.root_module.addImport("zrpc-transport-quic", quic_transport);

    // Install both executables
    b.installArtifact(server_exe);
    b.installArtifact(client_exe);

    // Run steps
    const server_run = b.addRunArtifact(server_exe);
    const client_run = b.addRunArtifact(client_exe);

    const run_server_step = b.step("server", "Run the calculator server");
    run_server_step.dependOn(&server_run.step);

    const run_client_step = b.step("client", "Run the calculator client");
    run_client_step.dependOn(&client_run.step);
}
```

### Step 5: Run Your Application

Build the project:
```bash
zig build
```

Run the server (in one terminal):
```bash
zig build server
```

Run the client (in another terminal):
```bash
zig build client
```

**Expected Output:**

Server terminal:
```
info: 🚀 Starting Calculator Server...
info: 📡 Server listening on 0.0.0.0:8443
info: ✅ Calculator service registered
info: 🔥 Server ready to serve requests!
info: Adding 10.5 + 5.2
info: Multiplying 3 * 4
info: Dividing 15 / 3
info: Dividing 10 / 0
```

Client terminal:
```
info: 🔌 Connecting to Calculator Server...
info: ✅ Connected to server
info: ➕ 10.5 + 5.2 = 15.7
info: ✖️  3 * 4 = 12
info: ➗ 15 / 3 = 5
warn: ⚠️  Division error: Division by zero
info: 🎉 Calculator client completed successfully!
```

## Understanding the Code

### Transport Adapter Pattern

The key architectural concept in zRPC v2.x is the **Transport Adapter Pattern**:

```zig
// Create transport adapter (QUIC in this case)
var transport = quic_transport.createClientTransport(allocator);

// Inject transport into client
var client = try zrpc.Client.init(allocator, .{ .transport = transport });
```

This separation allows you to:
- Switch transports without changing RPC logic
- Test with mock transports
- Optimize each transport independently
- Use multiple transports in the same application

### Method Registration

Server methods are registered with type safety:

```zig
try server.registerHandler(
    "Calculator/Add",                    // Service/Method name
    calculator.AddRequest,               // Request type
    calculator.AddResponse,              // Response type
    zrpc.MethodHandler(...){             // Type-safe handler
        .handler_fn = @ptrCast(&calc_service.add)
    }
);
```

### Error Handling

zRPC provides structured error handling:

```zig
const response = client.call(...) catch |err| switch (err) {
    error.ConnectionFailed => {
        // Handle connection errors
        return err;
    },
    error.RequestTimeout => {
        // Handle timeout errors
        return err;
    },
    else => return err,
};
```

## Next Steps

### Add Authentication

```zig
// Client with JWT authentication
var auth_config = zrpc.AuthConfig{
    .type = .jwt,
    .token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
};

var client_config = zrpc.ClientConfig{
    .transport = transport,
    .auth = auth_config,
};
```

### Add Streaming RPCs

```zig
// Server streaming example
var stream = try client.serverStream(calculator.AddRequest, calculator.AddResponse,
    "Calculator/AddStream", initial_request);

while (try stream.next()) |response| {
    std.log.info("Received: {}", .{response.result});
}
```

### Add Error Context

```zig
// Request with context
var context = zrpc.RequestContext.withDeadline(5000); // 5s deadline
const response = try client.callWithContext(RequestType, ResponseType,
    "Service/Method", request, &context);
```

### Performance Optimization

```zig
// High-performance client configuration
var client_config = zrpc.ClientConfig.highThroughput(transport);
client_config.enable_compression = true;
client_config.max_message_size = 16 * 1024 * 1024; // 16MB
```

## Common Patterns

### Graceful Shutdown

```zig
// Server with graceful shutdown
var shutdown_signal = std.Thread.ResetEvent{};

// Handle SIGINT
const sigint_handler = struct {
    fn handle(sig: i32) callconv(.C) void {
        if (sig == std.os.SIG.INT) {
            shutdown_signal.set();
        }
    }
}.handle;

try std.os.sigaction(std.os.SIG.INT, &std.os.Sigaction{
    .handler = .{ .handler = sigint_handler },
    .mask = std.os.empty_sigset,
    .flags = 0,
}, null);

// Serve with shutdown handling
try server.serveWithShutdown(&shutdown_signal);
```

### Connection Pooling

```zig
// Client with connection pool
var pool_config = quic_transport.ConnectionPool.Config{
    .max_connections = 10,
    .min_connections = 2,
    .idle_timeout_ms = 300000, // 5 minutes
};

var transport = quic_transport.createClientTransportWithPool(allocator, pool_config);
```

### Load Balancing

```zig
// Client with load balancing
var lb_config = quic_transport.LoadBalancer.Config{
    .strategy = .round_robin,
    .health_check_enabled = true,
};

var client = try zrpc.Client.init(allocator, .{ .transport = transport });

// Add multiple endpoints
try client.addEndpoint("server1:8443", &tls_config);
try client.addEndpoint("server2:8443", &tls_config);
try client.addEndpoint("server3:8443", &tls_config);
```

## Troubleshooting

### Common Issues

1. **Connection Failed**
   ```bash
   # Check if server is running
   nc -z localhost 8443

   # Check firewall settings
   sudo iptables -L
   ```

2. **Build Errors**
   ```bash
   # Clean build cache
   rm -rf zig-cache/
   zig build clean

   # Rebuild
   zig build
   ```

3. **Import Errors**
   - Verify module paths in `build.zig`
   - Check that dependencies are properly declared
   - Ensure Zig version compatibility

### Debug Mode

Enable debug logging for troubleshooting:

```zig
var config = zrpc.ClientConfig{
    .transport = transport,
    .enable_debug_logging = true,
    .log_transport_frames = true, // Very detailed logging
};
```

---

**Next**: Continue with the [Streaming Tutorial](streaming-tutorial.md) to learn about streaming RPCs, or check the [Authentication Tutorial](auth-tutorial.md) for security features.