# Transport Adapter Pattern

**The Core Architectural Design of zRPC**

The Transport Adapter Pattern is the foundational architectural design that makes zRPC transport-agnostic while maintaining high performance and clean abstractions.

## Overview

zRPC's architecture is built around the concept of **pluggable transport adapters** that implement a standardized Service Provider Interface (SPI). This allows the core RPC framework to remain transport-agnostic while supporting multiple underlying network protocols.

```
┌─────────────────────────────────────────────────────────┐
│                    Application Layer                    │
├─────────────────────────────────────────────────────────┤
│                      zrpc-core                          │
│  ┌─────────────────┐ ┌─────────────────┐ ┌───────────┐ │
│  │     Client      │ │     Server      │ │  Service  │ │
│  │   Operations    │ │   Operations    │ │Definition │ │
│  └─────────────────┘ └─────────────────┘ └───────────┘ │
├─────────────────────────────────────────────────────────┤
│                 Transport Interface                     │
│         (Standardized SPI - Service Provider Interface) │
├─────────────────────────────────────────────────────────┤
│                Transport Adapters                       │
│ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐        │
│ │    QUIC     │ │   HTTP/2    │ │    Mock     │  ...   │
│ │  Adapter    │ │   Adapter   │ │   Adapter   │        │
│ └─────────────┘ └─────────────┘ └─────────────┘        │
├─────────────────────────────────────────────────────────┤
│                    Network Layer                        │
│        (UDP/TCP, TLS, Connection Management)            │
└─────────────────────────────────────────────────────────┘
```

## Key Components

### 1. Transport Interface (SPI)

The Transport Interface defines the contract that all transport adapters must implement:

```zig
pub const Transport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        connect: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection,
        deinit: *const fn (ptr: *anyopaque) void,
    };
};
```

**Key Interface Components:**
- **Connection Management**: Establish, maintain, and close connections
- **Stream Operations**: Create, read, write, and manage streams
- **Frame Protocol**: Standardized frame-based communication
- **Error Handling**: Unified error taxonomy
- **Resource Management**: Proper cleanup and lifecycle management

### 2. Connection Abstraction

Each transport adapter provides connection management through a standardized interface:

```zig
pub const Connection = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        openStream: *const fn (ptr: *anyopaque) TransportError!Stream,
        close: *const fn (ptr: *anyopaque) void,
        ping: *const fn (ptr: *anyopaque) TransportError!void,
        isConnected: *const fn (ptr: *anyopaque) bool,
    };
};
```

### 3. Stream Operations

All RPC operations are performed through streams that provide a consistent interface:

```zig
pub const Stream = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        writeFrame: *const fn (ptr: *anyopaque, frame_type: FrameType, flags: u8, data: []const u8) TransportError!void,
        readFrame: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) TransportError!Frame,
        close: *const fn (ptr: *anyopaque) void,
        cancel: *const fn (ptr: *anyopaque) void,
    };
};
```

## Design Principles

### 1. Transport Agnostic Core

The zrpc-core module remains completely independent of any specific transport implementation:

- **No Transport Dependencies**: Core module imports no transport-specific code
- **Standardized Interface**: All transports implement the same contract
- **Runtime Selection**: Transport choice made at application startup
- **Hot Swapping**: Potential for runtime transport switching (future feature)

### 2. Performance Through Specialization

Each transport adapter can optimize for its specific protocol characteristics:

- **QUIC Adapter**: 0-RTT connection resumption, connection migration
- **HTTP/2 Adapter**: Stream multiplexing, header compression
- **Mock Adapter**: Development testing, predictable behavior

### 3. Contract Testing

The architecture includes comprehensive contract testing to ensure adapter compliance:

```zig
// Contract test ensures all adapters behave consistently
pub fn runContractTests(allocator: std.mem.Allocator, transports: []Transport) !void {
    for (transports) |transport| {
        try testConnectionLifecycle(allocator, transport);
        try testStreamOperations(allocator, transport);
        try testErrorHandling(allocator, transport);
        try testResourceCleanup(allocator, transport);
    }
}
```

## Implementation Details

### Transport Adapter Structure

Each transport adapter follows a consistent structure:

```zig
// src/adapters/my_transport.zig
pub const MyTransportAdapter = struct {
    allocator: std.mem.Allocator,
    // Transport-specific fields...

    pub fn init(allocator: std.mem.Allocator) !*MyTransportAdapter {
        // Initialize transport-specific resources
    }

    pub fn deinit(self: *MyTransportAdapter) void {
        // Clean up resources
    }

    pub const vtable = Transport.VTable{
        .connect = connect,
        .deinit = deinit,
    };

    fn connect(ptr: *anyopaque, allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
        const self: *MyTransportAdapter = @ptrCast(@alignCast(ptr));
        // Transport-specific connection logic
    }
};

pub fn createClientTransport(allocator: std.mem.Allocator) Transport {
    const adapter = MyTransportAdapter.init(allocator) catch @panic("Failed to initialize transport");
    return Transport{
        .ptr = adapter,
        .vtable = &MyTransportAdapter.vtable,
    };
}
```

### Error Handling Strategy

The transport interface defines a unified error taxonomy:

```zig
pub const TransportError = error{
    // Network-level errors
    ConnectionFailed,
    ConnectionReset,
    ConnectionTimeout,
    NotConnected,

    // Protocol-level errors
    InvalidFrame,
    InvalidHeader,
    Protocol,

    // Resource errors
    ResourceExhausted,
    InvalidArgument,

    // System errors
    NetworkError,
    OutOfMemory,
};
```

### Frame Protocol

All transports communicate using a standardized frame protocol:

```zig
pub const FrameType = enum(u8) {
    data = 0x00,      // Payload data
    headers = 0x01,   // Request/response headers
    priority = 0x02,  // Stream priority
    rst_stream = 0x03,// Stream reset
    settings = 0x04,  // Connection settings
    ping = 0x06,      // Keep-alive ping
    goaway = 0x07,    // Connection termination
};

pub const Frame = struct {
    frame_type: FrameType,
    flags: u8,
    stream_id: u32,
    payload: []u8,
};
```

## Benefits

### 1. Modularity

- **Independent Development**: Transport adapters can be developed separately
- **Reduced Coupling**: Core RPC logic decoupled from transport details
- **Testing Isolation**: Each component can be tested independently
- **Maintenance**: Changes to one transport don't affect others

### 2. Extensibility

- **New Protocols**: Easy to add support for new network protocols
- **Custom Transports**: Applications can implement domain-specific transports
- **Protocol Evolution**: Transport updates don't break core functionality
- **Experimental Features**: New features can be tested in isolation

### 3. Performance Optimization

- **Transport-Specific Optimization**: Each adapter optimized for its protocol
- **Zero-Copy Operations**: Adapters can implement zero-copy where possible
- **Connection Pooling**: Transport-specific connection management strategies
- **Protocol Features**: Full utilization of underlying protocol capabilities

### 4. Production Readiness

- **Battle-Tested Interface**: Standardized SPI ensures consistency
- **Contract Compliance**: All adapters must pass comprehensive tests
- **Error Handling**: Unified error model across all transports
- **Resource Management**: Guaranteed cleanup and lifecycle management

## Comparison with Other Architectures

### Traditional Monolithic RPC

```
Application → gRPC Core → HTTP/2 (Fixed)
```

**Limitations:**
- Single transport protocol
- Transport changes require core modifications
- Testing requires actual network setup
- Performance limited by single implementation

### zRPC Transport Adapter Pattern

```
Application → zrpc-core → Transport Interface → Pluggable Adapters
```

**Advantages:**
- Multiple transport protocols
- Core remains stable across transport changes
- Mock transports for development/testing
- Optimized implementations per protocol

## Future Extensions

The Transport Adapter Pattern enables several future enhancements:

### 1. Multi-Transport Clients

```zig
var client_config = ClientConfig{
    .primary_transport = quic_transport,
    .fallback_transport = http2_transport,
    .failover_strategy = .automatic,
};
```

### 2. Transport Metrics and Monitoring

```zig
pub const TransportMetrics = struct {
    connections_active: u64,
    bytes_sent: u64,
    bytes_received: u64,
    latency_p99: Duration,
};

// Each adapter can provide detailed metrics
const metrics = transport.getMetrics();
```

### 3. Hot Transport Swapping

```zig
// Runtime transport switching for zero-downtime updates
try client.switchTransport(new_transport_adapter);
```

## Best Practices

### For Transport Adapter Developers

1. **Follow the Interface Contract**: Implement all required methods
2. **Pass Contract Tests**: Ensure your adapter passes all compliance tests
3. **Handle Errors Gracefully**: Map transport errors to standard taxonomy
4. **Optimize for Your Protocol**: Leverage transport-specific features
5. **Document Protocol Details**: Provide clear usage documentation

### For Application Developers

1. **Choose Appropriate Transport**: Select transport based on requirements
2. **Handle Transport Errors**: Implement proper error handling
3. **Test with Mock Transport**: Use mock adapter for unit testing
4. **Monitor Performance**: Track transport-specific metrics
5. **Plan for Transport Migration**: Design with transport flexibility

---

**Next**: Explore the [Modular Architecture Overview](modular-architecture.md) or learn about [Security Architecture](security-architecture.md).