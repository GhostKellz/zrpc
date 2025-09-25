# zRPC Quickstart Guide

Get up and running with zRPC in under 10 minutes! This guide shows you how to build a simple gRPC-over-QUIC service using the modular architecture.

## Prerequisites

- Zig 0.16.0-dev or later
- Basic familiarity with gRPC concepts

## Step 1: Project Setup (2 minutes)

Create a new Zig project:

```bash
mkdir my-zrpc-service
cd my-zrpc-service
zig init
```

Add zRPC dependencies to `build.zig.zon`:

```zig
.{
    .name = "my-zrpc-service",
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0-dev",
    .dependencies = .{
        .@"zrpc-core" = .{
            .url = "https://github.com/ghostkellz/zrpc/releases/download/v0.4.0-beta.1/zrpc-core.tar.gz",
            .hash = "1220abcd...", // zig fetch will fill this
        },
        .@"zrpc-transport-quic" = .{
            .url = "https://github.com/ghostkellz/zrpc/releases/download/v0.1.0-beta.1/zrpc-transport-quic.tar.gz",
            .hash = "1220efgh...", // zig fetch will fill this
        },
    },
}
```

Update `build.zig`:

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const zrpc_core = b.dependency("zrpc-core", .{}).module("zrpc-core");
    const zrpc_quic = b.dependency("zrpc-transport-quic", .{}).module("zrpc-transport-quic");

    const exe = b.addExecutable(.{
        .name = "my-zrpc-service",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zRPC modules
    exe.root_module.addImport("zrpc-core", zrpc_core);
    exe.root_module.addImport("zrpc-transport-quic", zrpc_quic);

    b.installArtifact(exe);
}
```

## Step 2: Define Your Service (3 minutes)

Create `src/main.zig` with a simple echo service:

```zig
const std = @import("std");
const zrpc_core = @import("zrpc-core");
const zrpc_quic = @import("zrpc-transport-quic");

// Service handler function
fn echoHandler(request: *zrpc_core.RequestContext, response: *zrpc_core.ResponseContext) zrpc_core.Error!void {
    std.log.info("Echo request from method: {s}", .{request.method});
    std.log.info("Request data: {s}", .{request.data});

    // Simple echo - return the request data
    response.data = request.data;
    response.status_code = 0; // gRPC OK status
}

// Greeting handler with custom logic
fn greetHandler(request: *zrpc_core.RequestContext, response: *zrpc_core.ResponseContext) zrpc_core.Error!void {
    // In a real app, you'd parse protobuf here
    const name = request.data; // Simplified - assume request.data is the name

    // Build response
    var greeting_buf: [256]u8 = undefined;
    const greeting = try std.fmt.bufPrint(&greeting_buf, "Hello, {s}! Welcome to zRPC over QUIC.", .{name});

    // Copy to response (in real app, you'd serialize protobuf)
    response.data = try response.allocator.dupe(u8, greeting);
    response.status_code = 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🚀 Starting zRPC server with QUIC transport...");

    // Step 1: Create QUIC transport (explicit injection)
    const transport = zrpc_quic.createServerTransport(allocator);

    // Step 2: Create server with transport
    var server = zrpc_core.Server.init(allocator, .{ .transport = transport });
    defer server.deinit();

    // Step 3: Register service handlers
    try server.registerHandler("EchoService/Echo", echoHandler);
    try server.registerHandler("GreeterService/SayHello", greetHandler);

    // Step 4: Bind to address
    try server.bind("127.0.0.1:8080", null);

    std.log.info("✅ Server listening on 127.0.0.1:8080");
    std.log.info("📡 Transport: QUIC (HTTP/3 + gRPC)");
    std.log.info("🔧 Registered methods:");
    std.log.info("   - EchoService/Echo");
    std.log.info("   - GreeterService/SayHello");

    // Step 5: Start serving (this blocks)
    try server.serve();
}
```

## Step 3: Build and Test (2 minutes)

Build your service:

```bash
zig build
```

Run the server:

```bash
./zig-out/bin/my-zrpc-service
```

You should see:
```
🚀 Starting zRPC server with QUIC transport...
✅ Server listening on 127.0.0.1:8080
📡 Transport: QUIC (HTTP/3 + gRPC)
🔧 Registered methods:
   - EchoService/Echo
   - GreeterService/SayHello
```

## Step 4: Create a Client (3 minutes)

Create `src/client.zig` to test your service:

```zig
const std = @import("std");
const zrpc_core = @import("zrpc-core");
const zrpc_quic = @import("zrpc-transport-quic");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("🔗 Connecting to zRPC server via QUIC...");

    // Step 1: Create QUIC transport for client
    const transport = zrpc_quic.createClientTransport(allocator);

    // Step 2: Create client with explicit transport injection
    var client = zrpc_core.Client.init(allocator, .{ .transport = transport });
    defer client.deinit();

    // Step 3: Connect to server
    try client.connect("127.0.0.1:8080", null);
    std.log.info("✅ Connected to server!");

    // Step 4: Make RPC calls

    // Test echo service
    const echo_response = try client.call("EchoService/Echo", "Hello from client!");
    defer allocator.free(echo_response);
    std.log.info("Echo response: {s}", .{echo_response});

    // Test greeter service
    const greet_response = try client.call("GreeterService/SayHello", "World");
    defer allocator.free(greet_response);
    std.log.info("Greet response: {s}", .{greet_response});

    std.log.info("🎉 All RPC calls completed successfully!");
}
```

Add client build to your `build.zig`:

```zig
// Add after the server executable
const client = b.addExecutable(.{
    .name = "client",
    .root_source_file = b.path("src/client.zig"),
    .target = target,
    .optimize = optimize,
});

client.root_module.addImport("zrpc-core", zrpc_core);
client.root_module.addImport("zrpc-transport-quic", zrpc_quic);
b.installArtifact(client);

// Add run steps
const run_server = b.addRunArtifact(exe);
const run_client = b.addRunArtifact(client);

const server_step = b.step("server", "Run the server");
server_step.dependOn(&run_server.step);

const client_step = b.step("client", "Run the client");
client_step.dependOn(&run_client.step);
```

Build and test:

```bash
# Build both server and client
zig build

# Run server in one terminal
zig build server

# Run client in another terminal
zig build client
```

## Success! You now have:

✅ **Modular Architecture**: Clean separation between core and transport
✅ **QUIC Transport**: HTTP/3 + gRPC over QUIC for high performance
✅ **Explicit Injection**: No magic - you control the transport layer
✅ **Working RPC**: Bidirectional client-server communication

## Next Steps

### Add Protocol Buffers (Advanced)

For production services, integrate protobuf:

```bash
# Install protoc and generate Zig code
protoc --zig_out=src/ service.proto
```

```zig
// Use generated code
const MyServiceProto = @import("generated/myservice.pb.zig");

fn typedHandler(request: *zrpc_core.RequestContext, response: *zrpc_core.ResponseContext) !void {
    // Deserialize protobuf request
    const req = try MyServiceProto.HelloRequest.decode(request.data, response.allocator);

    // Call business logic
    const resp = MyServiceProto.HelloResponse{
        .message = try std.fmt.allocPrint(response.allocator, "Hello, {s}!", .{req.name}),
    };

    // Serialize protobuf response
    response.data = try resp.encode(response.allocator);
}
```

### Explore Transport Options

Try different transports:

```zig
// HTTP/2 transport (when available)
const zrpc_http2 = @import("zrpc-transport-http2");
const transport = zrpc_http2.createServerTransport(allocator);

// Custom transport
const custom_transport = MyCustomTransport.create(allocator);
```

### Add Middleware

Use optional security packages:

```zig
const zrpc_auth = @import("zrpc-auth");

// Wrap handlers with authentication
const secure_handler = zrpc_auth.requireJWT(jwt_config, base_handler);
try server.registerHandler("SecureService/Method", secure_handler);
```

### Performance Tuning

Run benchmarks and optimize:

```bash
# Run built-in benchmarks
zig build bench

# Profile your specific workload
zig build -Doptimize=ReleaseFast
```

## Troubleshooting

**Build errors?**
- Ensure Zig 0.16.0-dev or later
- Run `zig fetch` to update hashes

**Connection errors?**
- Check firewall settings
- Verify address/port not in use
- Enable debug logging: `std.log.info`

**Performance issues?**
- Build with `-Doptimize=ReleaseFast`
- Check network latency with `ping`
- Use QUIC 0-RTT for reconnections

## Documentation

- [Architecture Guide](architecture.md) - Deep dive into modular design
- [Transport SPI](transport-spi.md) - Build custom transport adapters
- [Migration Guide](migration.md) - Migrate from monolithic zrpc
- [Performance Guide](performance.md) - Tuning and benchmarking

🎉 **Congratulations!** You've built a high-performance RPC service with zRPC's modular architecture in under 10 minutes!