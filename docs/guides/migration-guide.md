# Migration Guide: Monolithic to Modular Architecture

**Upgrading from zRPC v1.x to v2.x Transport Adapter Architecture**

This guide helps you migrate from the monolithic zRPC v1.x architecture to the new modular transport adapter pattern introduced in zRPC v2.0.

## Overview

zRPC v2.0 introduces a fundamental architectural change: the **Transport Adapter Pattern**. This separates the core RPC framework from transport implementations, providing greater flexibility, testability, and performance optimization opportunities.

### What Changed

**Before (v1.x - Monolithic):**
```zig
const zrpc = @import("zrpc");

// Transport was hardcoded/auto-detected from URL
var client = try zrpc.Client.init(allocator, "quic://localhost:8443");
var server = try zrpc.Server.init(allocator, "quic://0.0.0.0:8443");
```

**After (v2.x - Modular):**
```zig
const zrpc = @import("zrpc-core");              // Core RPC framework
const quic_transport = @import("zrpc-transport-quic"); // QUIC adapter

// Explicit transport injection
var transport = quic_transport.createClientTransport(allocator);
var client = try zrpc.Client.init(allocator, .{ .transport = transport });

var server_transport = quic_transport.createServerTransport(allocator);
var server = try zrpc.Server.init(allocator, .{ .transport = server_transport });
```

## Migration Steps

### 1. Update Dependencies

**Old build.zig:**
```zig
const zrpc = b.dependency("zrpc", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zrpc", zrpc.module("zrpc"));
```

**New build.zig:**
```zig
// Core framework (required)
const zrpc_core = b.dependency("zrpc-core", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zrpc-core", zrpc_core.module("zrpc-core"));

// Transport adapter (choose one or more)
const quic_transport = b.dependency("zrpc-transport-quic", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zrpc-transport-quic", quic_transport.module("zrpc-transport-quic"));
```

### 2. Update Import Statements

**Before:**
```zig
const zrpc = @import("zrpc");
```

**After:**
```zig
const zrpc = @import("zrpc-core");
const quic_transport = @import("zrpc-transport-quic");
```

### 3. Migrate Client Code

#### Simple Client Migration

**Before:**
```zig
var client = try zrpc.Client.init(allocator, "quic://localhost:8443");
defer client.deinit();

const response = try client.call("UserService/GetUser", GetUserRequest{ .id = 123 });
```

**After:**
```zig
var transport = quic_transport.createClientTransport(allocator);
defer transport.deinit();

var client = try zrpc.Client.init(allocator, .{ .transport = transport });
defer client.deinit();

// Connect explicitly
try client.connect("localhost:8443", &tls_config);

const response = try client.call("UserService/GetUser", GetUserRequest{ .id = 123 });
```

#### Client with Connection Pool

**Before:**
```zig
var client = try zrpc.Client.initWithPool(allocator, .{
    .endpoints = &.{ "quic://server1:8443", "quic://server2:8443" },
    .pool_size = 10,
});
```

**After:**
```zig
var pool_config = quic_transport.ConnectionPool.Config{
    .max_connections = 10,
    .idle_timeout_ms = 30000,
};

var transport = quic_transport.createClientTransportWithPool(allocator, pool_config);
defer transport.deinit();

var client = try zrpc.Client.init(allocator, .{ .transport = transport });
defer client.deinit();

// Add endpoints to pool
try client.addEndpoint("server1:8443", &tls_config);
try client.addEndpoint("server2:8443", &tls_config);
```

### 4. Migrate Server Code

#### Simple Server Migration

**Before:**
```zig
var server = try zrpc.Server.init(allocator, "quic://0.0.0.0:8443");
defer server.deinit();

try server.registerService(UserServiceImpl{});
try server.serve();
```

**After:**
```zig
var transport = quic_transport.createServerTransport(allocator);
defer transport.deinit();

var server = try zrpc.Server.init(allocator, .{ .transport = transport });
defer server.deinit();

try server.bind("0.0.0.0:8443", &tls_config);
try server.registerService(UserServiceImpl{});
try server.serve();
```

#### Server with Advanced Configuration

**Before:**
```zig
var config = zrpc.ServerConfig{
    .max_connections = 1000,
    .request_timeout_ms = 5000,
    .tls_cert_path = "cert.pem",
    .tls_key_path = "key.pem",
};
var server = try zrpc.Server.initWithConfig(allocator, "quic://0.0.0.0:8443", config);
```

**After:**
```zig
var tls_config = zrpc.TlsConfig{
    .cert_path = "cert.pem",
    .key_path = "key.pem",
    .verify_client = false,
};

var transport_config = quic_transport.ServerConfig{
    .max_connections = 1000,
    .idle_timeout_ms = 30000,
};

var transport = quic_transport.createServerTransportWithConfig(allocator, transport_config);
defer transport.deinit();

var server_config = zrpc.ServerConfig{
    .request_timeout_ms = 5000,
    .max_message_size = 4 * 1024 * 1024,
};

var server = try zrpc.Server.initWithConfig(allocator, server_config, .{ .transport = transport });
defer server.deinit();

try server.bind("0.0.0.0:8443", &tls_config);
```

### 5. Migrate Streaming RPCs

Streaming RPC APIs remain largely the same, but initialization changes:

**Before:**
```zig
var stream = try client.serverStream("ChatService/GetMessages", GetMessagesRequest{});
```

**After:**
```zig
// Same API after client initialization
var stream = try client.serverStream("ChatService/GetMessages", GetMessagesRequest{});
```

### 6. Migrate Authentication

Authentication configuration moves from URL parameters to explicit configuration:

**Before:**
```zig
var client = try zrpc.Client.init(allocator, "quic://localhost:8443?auth=jwt&token=eyJ...");
```

**After:**
```zig
var auth_config = zrpc.AuthConfig{
    .type = .jwt,
    .token = "eyJ...",
};

var client_config = zrpc.ClientConfig{
    .auth = auth_config,
};

var transport = quic_transport.createClientTransport(allocator);
var client = try zrpc.Client.initWithConfig(allocator, client_config, .{ .transport = transport });
```

### 7. Update Error Handling

Error handling is more explicit with the transport adapter pattern:

**Before:**
```zig
const response = client.call("Service/Method", request) catch |err| switch (err) {
    error.ConnectionFailed => // Handle connection error
    error.Timeout => // Handle timeout
    else => return err,
};
```

**After:**
```zig
const response = client.call("Service/Method", request) catch |err| switch (err) {
    // Transport-specific errors
    zrpc.TransportError.ConnectionFailed => // Handle connection error
    zrpc.TransportError.ConnectionTimeout => // Handle timeout
    zrpc.TransportError.NotConnected => // Handle disconnection

    // RPC-level errors remain the same
    zrpc.Error.InvalidRequest => // Handle RPC error
    else => return err,
};
```

## Advanced Migration Scenarios

### Multiple Transport Support

The new architecture allows using multiple transports simultaneously:

```zig
const quic_transport = @import("zrpc-transport-quic");
const http2_transport = @import("zrpc-transport-http2"); // When available

// Create clients for different transports
var quic_client = try zrpc.Client.init(allocator, .{
    .transport = quic_transport.createClientTransport(allocator)
});

var http2_client = try zrpc.Client.init(allocator, .{
    .transport = http2_transport.createClientTransport(allocator)
});

// Use based on requirements
if (need_low_latency) {
    try quic_client.connect("server:8443", &tls_config);
    const response = try quic_client.call("Service/Method", request);
} else {
    try http2_client.connect("server:8080", &tls_config);
    const response = try http2_client.call("Service/Method", request);
}
```

### Custom Transport Adapters

The modular architecture allows custom transport implementations:

```zig
const CustomTransport = struct {
    // Implement zrpc.Transport interface
    pub const vtable = zrpc.Transport.VTable{
        .connect = connect,
        .deinit = deinit,
    };

    fn connect(ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const zrpc.TlsConfig) zrpc.TransportError!zrpc.Connection {
        // Custom transport logic
    }
};

var custom_transport = zrpc.Transport{
    .ptr = &custom_adapter,
    .vtable = &CustomTransport.vtable,
};

var client = try zrpc.Client.init(allocator, .{ .transport = custom_transport });
```

## Testing Migrations

### Unit Testing with Mock Transport

The modular architecture provides better testing capabilities:

**Before:**
```zig
test "client call" {
    var client = try zrpc.Client.init(testing.allocator, "mock://test");
    // Limited testing capabilities
}
```

**After:**
```zig
const mock_transport = @import("zrpc-transport-mock");

test "client call" {
    var transport = mock_transport.createClientTransport(testing.allocator);
    defer transport.deinit();

    var client = try zrpc.Client.init(testing.allocator, .{ .transport = transport });
    defer client.deinit();

    // Full control over transport behavior for testing
    mock_transport.expectCall("Service/Method", expected_request, expected_response);

    const response = try client.call("Service/Method", request);
    try testing.expectEqual(expected_response, response);
}
```

### Integration Testing

Contract tests ensure transport adapter compliance:

```zig
const contract_tests = @import("zrpc-core").contract_tests;

test "QUIC transport contract compliance" {
    var transport = quic_transport.createClientTransport(testing.allocator);
    defer transport.deinit();

    try contract_tests.runClientTransportTests(testing.allocator, transport);
}
```

## Common Migration Issues

### 1. URL Parsing

**Issue**: Code that parsed transport from URLs
```zig
// This no longer works
if (std.mem.startsWith(u8, url, "quic://")) {
    // Auto-detect QUIC
}
```

**Solution**: Use explicit transport selection
```zig
// Explicit transport choice
const transport_type = if (use_quic)
    quic_transport.createClientTransport(allocator)
else
    http2_transport.createClientTransport(allocator);
```

### 2. Configuration Scattered

**Issue**: Transport configuration mixed with RPC configuration

**Solution**: Separate transport config from RPC config
```zig
// Transport configuration
var quic_config = quic_transport.Config{
    .max_streams = 1000,
    .keepalive_interval_ms = 30000,
};

// RPC configuration
var rpc_config = zrpc.ClientConfig{
    .request_timeout_ms = 5000,
    .max_message_size = 4 * 1024 * 1024,
};
```

### 3. Implicit Connections

**Issue**: Connections were implicit in v1.x

**Solution**: Explicit connection management
```zig
// Explicit connection
try client.connect("localhost:8443", &tls_config);

// Check connection status
if (!client.isConnected()) {
    try client.reconnect();
}
```

## Performance Considerations

### Connection Reuse

The modular architecture enables better connection management:

```zig
// Shared connection pool across multiple clients
var pool = try quic_transport.ConnectionPool.init(allocator, pool_config);
defer pool.deinit();

var client1 = try zrpc.Client.init(allocator, .{
    .transport = quic_transport.createClientTransportWithPool(allocator, &pool)
});

var client2 = try zrpc.Client.init(allocator, .{
    .transport = quic_transport.createClientTransportWithPool(allocator, &pool)
});
```

### Transport-Specific Optimizations

Each transport can be optimized independently:

```zig
// QUIC-specific optimizations
var quic_config = quic_transport.Config{
    .enable_0rtt = true,           // 0-RTT connection resumption
    .enable_migration = true,      // Connection migration
    .congestion_control = .bbr,    // BBR congestion control
};

// HTTP/2-specific optimizations (when available)
var http2_config = http2_transport.Config{
    .enable_push = false,          // Disable server push
    .header_table_size = 8192,     // HPACK table size
    .max_concurrent_streams = 100, // Stream limit
};
```

## Verification Checklist

After migration, verify:

- [ ] All imports updated to modular structure
- [ ] Transport adapters explicitly configured
- [ ] Connection management explicit
- [ ] TLS configuration separated from transport
- [ ] Authentication configuration updated
- [ ] Error handling covers transport errors
- [ ] Tests use mock transport where appropriate
- [ ] Performance meets or exceeds v1.x benchmarks

## Getting Help

If you encounter migration issues:

1. **Check the Contract Tests**: Run contract tests on your transport adapter
2. **Review Examples**: See `/examples/` for complete migration examples
3. **Performance Testing**: Use the benchmarking framework to validate performance
4. **API Reference**: Consult the [API documentation](../api/README.md)

---

**Next**: Review the [Performance Tuning Guide](performance-tuning.md) to optimize your migrated application.