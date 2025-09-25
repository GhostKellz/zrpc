# zRPC Architecture Guide

## Overview

zRPC is a transport-agnostic RPC framework designed with a clean separation between the core RPC logic and transport implementations. This modular architecture enables pluggable transports while maintaining zero dependencies in the core.

## Design Principles

### 1. Transport Agnostic Core
- **Zero Transport Dependencies**: Core compiles without any transport implementation
- **Explicit Injection**: Transport adapters are explicitly provided, no magic
- **Standard Interface**: All transports implement the same minimal SPI

### 2. Minimal Adapter Contract
The transport SPI is intentionally small and locked:

```zig
pub const Transport = struct {
    connect: fn(allocator, endpoint, tls_config) !Connection,
    listen: fn(allocator, bind_address, tls_config) !Listener,
};

pub const Connection = struct {
    openStream: fn() !Stream,
    ping: fn() !void,
    close: fn() void,
};

pub const Stream = struct {
    writeFrame: fn(frame_type, flags, data) !void,
    readFrame: fn(allocator) !Frame,
    cancel: fn() void,
};
```

### 3. Clean Responsibilities

**zrpc-core** handles:
- RPC message framing and dispatch
- Service method routing
- Deadline enforcement
- Standard error taxonomy
- Auth header construction
- Codec management (protobuf, JSON)

**Transport Adapters** handle:
- Network I/O and connections
- TLS/encryption
- Transport-specific features (0-RTT, migration)
- Mapping cancel() to transport reset mechanisms

**Optional Packages** handle:
- Authentication verification (zrpc-auth)
- Middleware and rate limiting
- Observability and metrics

## Module Structure

```
zrpc-ecosystem/
├── zrpc-core/
│   ├── src/core/
│   │   ├── client.zig          # Transport-agnostic client
│   │   ├── server.zig          # Transport-agnostic server
│   │   └── ...
│   ├── src/transport_interface.zig  # SPI definition
│   ├── src/codec.zig           # Message serialization
│   ├── src/protobuf.zig        # Protocol buffer support
│   └── src/error.zig           # Standard error taxonomy
│
├── zrpc-transport-quic/
│   ├── src/adapters/quic.zig   # QUIC adapter entry point
│   ├── src/adapters/quic/
│   │   ├── transport.zig       # QUIC transport implementation
│   │   ├── client.zig          # QUIC client adapter
│   │   └── server.zig          # QUIC server adapter
│   └── tests/contract_runner.zig
│
└── zrpc-tools/
    ├── src/cli.zig             # CLI utilities
    ├── src/contract_tests/     # Transport adapter validation
    └── src/benchmarks/         # Performance testing
```

## Transport Adapter Implementation

### Implementing the SPI

Transport adapters must map the minimal SPI to their underlying protocol:

```zig
// Example: QUIC adapter mapping
pub const QuicTransportAdapter = struct {
    pub fn connect(self: *@This(), allocator: std.mem.Allocator,
                   endpoint: []const u8, tls_config: ?*const TlsConfig) !Connection {
        // 1. Parse endpoint
        // 2. Create QUIC connection
        // 3. Perform handshake
        // 4. Wrap in Connection interface
    }

    // ... implement listen, etc.
};

// Stream adapter maps RPC frames to transport streams
const QuicStreamAdapter = struct {
    fn writeFrame(ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) !void {
        // Map RPC frame to QUIC stream data
        // Handle end-of-stream flags
        // Manage flow control
    }

    fn cancel(ptr: *anyopaque) void {
        // Map to QUIC STOP_SENDING + RESET_STREAM
    }
};
```

### Error Mapping

All transport adapters must map their errors to the standard taxonomy:

```zig
pub const TransportError = error{
    Timeout,        // Operation timed out
    Canceled,       // Operation was canceled
    Closed,         // Connection/stream closed
    ConnectionReset,// Connection reset by peer
    Temporary,      // Temporary failure, can retry
    ResourceExhausted, // Out of resources
    Protocol,       // Protocol violation
    InvalidArgument,// Invalid input
    NotConnected,   // Not connected to peer
    InvalidState,   // Invalid state for operation
    OutOfMemory,    // Memory allocation failed
};
```

### Frame Format

The SPI uses a simple frame format that adapters must handle:

```
Frame = {
    frame_type: u8,  // FrameType enum
    flags: u8,       // Frame flags (END_STREAM, etc.)
    data: []u8,      // Frame payload
}

// Frame types
pub const FrameType = enum(u8) {
    data = 0x0,      // RPC message data
    headers = 0x1,   // gRPC headers
    status = 0x2,    // Status/trailers
    cancel = 0x3,    // Cancellation
    keepalive = 0x4, // Keep-alive ping
    metadata = 0x5,  // Additional metadata
};
```

## Build System Integration

The modular build system ensures clean separation:

```zig
// build.zig snippet
const core_mod = b.addModule("zrpc-core", .{
    .root_source_file = b.path("src/core.zig"),
    // Only codec flags allowed in core
    .imports = &.{},
});

const quic_mod = b.addModule("zrpc-transport-quic", .{
    .root_source_file = b.path("src/adapters/quic.zig"),
    .imports = &.{
        .{ .name = "zrpc-core", .module = core_mod },
        // Transport-specific dependencies here
    },
});
```

## Testing Strategy

### Contract Tests
Every transport adapter runs the same contract test suite to ensure consistent behavior:

```zig
// tests/contract/unary_test.zig
test "unary RPC contract" {
    // Run against mock transport
    try testUnaryRpc(mock_transport);

    // Run against QUIC transport
    try testUnaryRpc(quic_transport);

    // Identical behavior expected
}
```

### Performance Benchmarks
Standardized benchmarks compare transport implementations:

```zig
// benchmarks/unary_bench.zig
test "unary RPC performance" {
    const results = try benchmarkUnary(transport, .{
        .payload_size = 1024,
        .request_count = 10000,
    });

    try std.testing.expect(results.p95_latency_us < 100);
}
```

## Migration from Monolithic

For users migrating from the previous monolithic zrpc:

1. **Replace single import**:
   ```zig
   // Old
   const zrpc = @import("zrpc");

   // New
   const zrpc_core = @import("zrpc-core");
   const zrpc_quic = @import("zrpc-transport-quic");
   ```

2. **Explicit transport injection**:
   ```zig
   // Old
   var client = try zrpc.Client.init(allocator, "localhost:8080");

   // New
   const transport = zrpc_quic.createClientTransport(allocator);
   var client = zrpc_core.Client.init(allocator, .{ .transport = transport });
   try client.connect("localhost:8080", null);
   ```

3. **Benefit from modularity**:
   - Core compiles faster (no transport deps)
   - Easy to swap transports
   - Better testing isolation
   - Cleaner dependency management

## Extension Points

### Custom Transport Adapters

Implement your own transport by following the SPI:

```zig
pub const MyTransportAdapter = struct {
    // Implement connect, listen functions
    pub fn connect(/*...*/) TransportError!Connection { /*...*/ }
    pub fn listen(/*...*/) TransportError!Listener { /*...*/ }
};

// Create transport using helper
pub fn createTransport(allocator: std.mem.Allocator) Transport {
    const adapter = allocator.create(MyTransportAdapter) catch @panic("OOM");
    adapter.* = MyTransportAdapter.init(allocator);
    return zrpc_core.transport.createTransport(MyTransportAdapter, adapter);
}
```

### Middleware Integration

Add middleware through the optional packages pattern:

```zig
// Optional zrpc-middleware package
const middleware = @import("zrpc-middleware");

// Wrap handlers with middleware
const auth_handler = middleware.requireAuth(jwt_config, base_handler);
try server.registerHandler("SecureService/Method", auth_handler);
```

This architecture enables a clean, testable, and extensible RPC framework while maintaining the performance and features users expect.