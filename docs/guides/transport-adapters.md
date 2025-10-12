# Transport Adapters Guide

zRPC supports multiple transport protocols through a pluggable adapter architecture. This guide covers all available transports and how to use them.

## Overview

zRPC provides 4 transport adapters:

| Transport | Protocol | Use Case | Status |
|-----------|----------|----------|--------|
| **WebSocket** | RFC 6455 | Web apps, browsers, MCP | ✅ Ready |
| **HTTP/2** | RFC 7540 | Standard gRPC, existing infrastructure | ✅ Ready |
| **HTTP/3** | RFC 9114 | Modern apps, 0-RTT, mobile | ✅ Ready |
| **QUIC** | RFC 9000 | Low-latency, connection migration | ✅ Ready |

## Architecture

All transports implement the same SPI interface:

```zig
pub const Transport = struct {
    connect: fn(url: []const u8) TransportError!Connection,
    listen: fn(address: []const u8) TransportError!Listener,
};

pub const Connection = struct {
    openStream: fn() TransportError!Stream,
    close: fn() void,
    ping: fn() TransportError!void,
};

pub const Stream = struct {
    write: fn(data: []const u8) TransportError!usize,
    read: fn(buffer: []u8) TransportError!Frame,
    close: fn() void,
};
```

## WebSocket Transport

### Features

- RFC 6455 compliant
- ws:// and wss:// support
- Automatic ping/pong heartbeat
- Binary frame mode for RPC
- Masking for client frames
- Text and binary messages

### Usage

```zig
const websocket = @import("zrpc").adapters.websocket;

// Create adapter
var adapter = websocket.WebSocketTransportAdapter.init(allocator);
defer adapter.deinit();

// Connect
var conn = try adapter.connect("ws://localhost:8080", .{});
defer conn.close();

// Open stream
var stream = try conn.openStream();
defer stream.close();

// Write data
const message = "Hello, WebSocket!";
_ = try stream.write(message);

// Read response
var buffer: [1024]u8 = undefined;
const frame = try stream.read(&buffer);
std.debug.print("Received: {s}\n", .{frame.data});
```

### Use Cases

- **Rune MCP Integration**: WebSocket is required for MCP protocol
- **Browser clients**: Direct connection from web apps
- **Real-time apps**: Chat, notifications, live updates
- **Mobile apps**: Efficient binary protocol

### Performance

- **Latency**: < 5ms for small messages
- **Throughput**: ~500 MB/s
- **Overhead**: 2-6 bytes per frame

## HTTP/2 Transport

### Features

- RFC 7540 compliant
- HPACK header compression
- Stream multiplexing
- Flow control
- gRPC-compatible
- Server push (optional)

### Usage

```zig
const http2 = @import("zrpc").adapters.http2;

// Create adapter
var adapter = http2.Http2TransportAdapter.init(allocator);
defer adapter.deinit();

// Connect
var conn = try adapter.connect("http://localhost:50051", .{});
defer conn.close();

// Open stream (gRPC request)
var stream = try conn.openStream();
defer stream.close();

// Write gRPC message
const request = // ... your protobuf message
_ = try stream.write(request);

// Read response
var buffer: [8192]u8 = undefined;
const frame = try stream.read(&buffer);
```

### Use Cases

- **Standard gRPC**: Drop-in replacement for gRPC C++/Go
- **Existing infrastructure**: Works with standard gRPC servers
- **HTTP/2 proxies**: Compatible with Envoy, nginx
- **Load balancers**: Works with standard HTTP/2 LBs

### Performance

- **Latency**: < 10ms for small messages
- **Throughput**: ~1 GB/s
- **Overhead**: HPACK reduces header size by 50-80%

## HTTP/3 Transport

### Features

- RFC 9114 compliant
- Built on QUIC (RFC 9000)
- QPACK header compression
- 0-RTT connection resumption
- Connection migration
- No head-of-line blocking

### Usage

```zig
const http3 = @import("zrpc").adapters.http3;

// Create adapter
var adapter = http3.Http3TransportAdapter.init(allocator);
defer adapter.deinit();

// Connect (uses QUIC)
var conn = try adapter.connect("h3://localhost:443", .{});
defer conn.close();

// Open stream
var stream = try conn.openStream();
defer stream.close();

// Write data
_ = try stream.write(data);

// Read response
var buffer: [8192]u8 = undefined;
const frame = try stream.read(&buffer);
```

### Use Cases

- **Modern apps**: Latest protocol with best performance
- **Mobile apps**: Connection migration for network changes
- **0-RTT apps**: Ultra-low latency for repeat connections
- **Global apps**: Better performance over long distances

### Performance

- **Latency**: < 5ms (< 1ms with 0-RTT)
- **Throughput**: ~1.5 GB/s
- **Overhead**: QPACK + VarInt encoding

## QUIC Transport

### Features

- RFC 9000 compliant
- Native multiplexing
- 0-RTT resumption
- Connection migration
- PATH_CHALLENGE/RESPONSE
- Advanced flow control

### Usage

```zig
const quic = @import("zrpc").adapters.quic;

// Create adapter
var adapter = quic.QuicTransportAdapter.init(allocator);
defer adapter.deinit();

// Connect
var conn = try adapter.connect("quic://localhost:4433", .{});
defer conn.close();

// 0-RTT enabled by default for repeat connections

// Open stream
var stream = try conn.openStream();
defer stream.close();

// Write and read
_ = try stream.write(data);
const frame = try stream.read(&buffer);
```

### Use Cases

- **Custom protocols**: Build your own framing on QUIC
- **Low-latency RPC**: Direct QUIC for minimal overhead
- **Connection migration**: Mobile apps, roaming
- **Advanced features**: Custom congestion control

### Performance

- **Latency**: < 3ms (< 500μs with 0-RTT)
- **Throughput**: ~2 GB/s
- **Overhead**: Minimal (direct stream framing)

## Choosing a Transport

### Decision Matrix

| Requirement | Recommended Transport |
|-------------|----------------------|
| Browser support | **WebSocket** |
| gRPC compatibility | **HTTP/2** |
| Lowest latency | **QUIC** or **HTTP/3** |
| Mobile apps | **HTTP/3** (connection migration) |
| Existing infrastructure | **HTTP/2** |
| MCP integration | **WebSocket** (required) |
| Maximum throughput | **QUIC** |

### Performance Comparison

Based on our benchmarks:

```
Transport    | Latency (p95) | Throughput | 0-RTT | Migration
-------------|---------------|------------|-------|----------
WebSocket    | 5ms           | 500 MB/s   | ❌    | ❌
HTTP/2       | 10ms          | 1 GB/s     | ❌    | ❌
HTTP/3       | 5ms (1ms)     | 1.5 GB/s   | ✅    | ✅
QUIC         | 3ms (500μs)   | 2 GB/s     | ✅    | ✅
```

## Transport Configuration

### Connection Options

```zig
pub const ConnectOptions = struct {
    /// TLS configuration
    tls: ?TlsConfig = null,
    /// Connection timeout (ms)
    timeout_ms: u32 = 5000,
    /// Enable 0-RTT (HTTP/3, QUIC only)
    enable_0rtt: bool = true,
    /// Enable compression
    enable_compression: bool = true,
    /// Compression level
    compression_level: compression.Level = .balanced,
};
```

### Example: Custom Configuration

```zig
const options = ConnectOptions{
    .timeout_ms = 10000,
    .enable_0rtt = true,
    .enable_compression = true,
    .compression_level = .fast,
};

var conn = try adapter.connect("h3://example.com:443", options);
```

## Error Handling

All transports use the same error types:

```zig
pub const TransportError = error{
    NetworkError,
    HandshakeFailed,
    ProtocolError,
    StreamReset,
    ConnectionReset,
    Timeout,
    NotSupported,
    OutOfMemory,
};
```

### Example: Robust Error Handling

```zig
var conn = adapter.connect(url, options) catch |err| {
    switch (err) {
        error.NetworkError => {
            std.log.err("Network error, check connectivity", .{});
            return err;
        },
        error.HandshakeFailed => {
            std.log.err("TLS handshake failed, check certificates", .{});
            return err;
        },
        error.Timeout => {
            std.log.err("Connection timeout, server may be down", .{});
            return err;
        },
        else => {
            std.log.err("Unknown error: {}", .{err});
            return err;
        },
    }
};
defer conn.close();
```

## Advanced Features

### Connection Pooling

```zig
// Reuse connections for multiple requests
var pool = ConnectionPool.init(allocator, adapter);
defer pool.deinit();

// Get or create connection
var conn = try pool.get("h3://example.com:443");

// Use connection
var stream = try conn.openStream();
defer stream.close();

// Connection is returned to pool automatically
```

### Load Balancing

```zig
// Round-robin across multiple servers
const servers = [_][]const u8{
    "h3://server1.example.com:443",
    "h3://server2.example.com:443",
    "h3://server3.example.com:443",
};

var lb = LoadBalancer.init(allocator, adapter, .round_robin);
defer lb.deinit();

for (servers) |server| {
    try lb.addServer(server);
}

// Get connection from load balancer
var conn = try lb.getConnection();
```

## Testing

### Contract Tests

All transports pass the same contract tests:

```bash
zig build test --filter "Transport Contract"
```

### Performance Tests

Run benchmarks for all transports:

```bash
zig build test --filter "Benchmark"
```

## Migration Guide

### From gRPC C++/Go

Replace transport layer, keep everything else:

```zig
// Before (gRPC C++)
auto channel = grpc::CreateChannel("localhost:50051", ...);
auto stub = MyService::NewStub(channel);

// After (zRPC)
const http2 = @import("zrpc").adapters.http2;
var adapter = http2.Http2TransportAdapter.init(allocator);
var conn = try adapter.connect("http://localhost:50051", .{});
```

### From WebSocket Libraries

Direct replacement with better performance:

```zig
// Before (websocket library)
var client = WebSocketClient.init(allocator);
try client.connect("ws://localhost:8080");

// After (zRPC)
var adapter = websocket.WebSocketTransportAdapter.init(allocator);
var conn = try adapter.connect("ws://localhost:8080", .{});
```

## Next Steps

- [Compression Guide](./compression-guide.md)
- [Performance Tuning](./performance-tuning.md)
- [Examples](../examples/)
