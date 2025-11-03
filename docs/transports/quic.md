# QUIC Transport (HTTP/3)

## Overview

The QUIC transport provides **next-generation network performance** with built-in TLS 1.3, 0-RTT connection resumption, and connection migration. Built on RFC 9000 with HTTP/3 support.

## Performance Characteristics

| Metric | QUIC | HTTP/2 | Improvement |
|--------|------|--------|-------------|
| **Connection Setup** | 0-RTT (resumed) | 1-2 RTT | **Instant** |
| **Head-of-line Blocking** | ❌ No | ✅ Yes | **Major win** |
| **Connection Migration** | ✅ Yes | ❌ No | **Mobile-friendly** |
| **Multiplexing** | Stream-level | Byte-level | **Better isolation** |
| **Loss Recovery** | Stream-specific | Connection-wide | **Faster** |

## Key Features

✅ **0-RTT Resumption** - Instant reconnection with session tickets
✅ **Connection Migration** - Seamless IP/network changes
✅ **No Head-of-line Blocking** - Independent stream processing
✅ **Built-in TLS 1.3** - Mandatory encryption
✅ **UDP-based** - Better NAT traversal
✅ **HTTP/3 Compatible** - Standard gRPC framing

## When to Use

### ✅ Perfect For
- **Mobile applications** - Network switching (WiFi ↔ 4G)
- **High-performance microservices** - Low latency critical
- **Long-lived connections** - 0-RTT saves roundtrips
- **Lossy networks** - Better recovery than TCP
- **Service mesh** - Inter-service communication

### ❌ Consider Alternatives
- **Legacy compatibility** (use HTTP/2)
- **Restricted networks** (UDP may be blocked)
- **Simple local IPC** (use UDS)
- **Minimal binary size** (HTTP/2 is smaller)

## Usage

### Build Configuration

```zig
// build.zig
const zrpc_dep = b.dependency("zrpc", .{
    .target = target,
    .optimize = optimize,
    .quic = true,      // Enable QUIC
    .http2 = false,    // Disable HTTP/2
});

const zrpc_quic = zrpc_dep.module("zrpc-transport-quic");
exe.root_module.addImport("zrpc-transport-quic", zrpc_quic);
```

### Client Example

```zig
const std = @import("std");
const zrpc = @import("zrpc-transport-quic");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create QUIC transport
    var transport = zrpc.QuicTransport.init(allocator);

    // Optional: Configure TLS and 0-RTT
    const config = zrpc.QuicConfig{
        .server_name = "api.example.com",
        .enable_0rtt = true,
        .session_cache = &session_cache,
    };

    // Send request
    var message = zrpc.Message.init(allocator, "request payload");
    defer message.deinit();

    try message.addHeader("grpc-method", "MyService/MyMethod");

    const response = try transport.send("quics://api.example.com:443/service", message);
    defer allocator.free(response.body);

    std.log.info("Response: {s}", .{response.body});
}
```

### Server Example

```zig
const std = @import("std");
const zrpc = @import("zrpc-transport-quic");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Configure TLS
    const tls_config = zrpc.TlsConfig{
        .cert_file = "server.crt",
        .key_file = "server.key",
        .alpn_protocols = &.{"h3"}, // HTTP/3
    };

    // Create QUIC server
    const bind_addr = try std.net.Address.parseIp("0.0.0.0", 8443);
    var server = try zrpc.QuicServer.init(allocator, bind_addr, tls_config);
    defer server.deinit();

    std.log.info("QUIC server listening on :8443", .{});

    // Accept connections
    while (true) {
        var conn = try server.accept();
        defer conn.close();

        // Handle streams
        var stream = try conn.acceptStream();
        defer stream.close();

        // Process gRPC frames
        const frame = try stream.readFrame();
        // ... handle request
    }
}
```

## 0-RTT Connection Resumption

### Concept

```
First Connection (1-RTT):
Client                Server
  |---ClientHello----->|
  |<--ServerHello------|
  |<--Certificate------|
  |<--Finished---------|
  |---Finished-------->|
  Total: 1 RTT before sending data

Resumed Connection (0-RTT):
Client                Server
  |---ClientHello----->|
  |---[Application Data]->| ← 0-RTT data
  |<--ServerHello------|
  |<--Finished---------|
  Total: 0 RTT before sending data!
```

### Implementation

```zig
// Client: Enable 0-RTT with session cache
const SessionCache = struct {
    tickets: std.StringHashMap([]const u8),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) SessionCache {
        return .{
            .tickets = std.StringHashMap([]const u8).init(allocator),
            .mutex = .{},
        };
    }

    pub fn store(self: *SessionCache, server_name: []const u8, ticket: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = try self.tickets.allocator.dupe(u8, server_name);
        try self.tickets.put(key, ticket);
    }

    pub fn retrieve(self: *SessionCache, server_name: []const u8) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.tickets.get(server_name);
    }
};

// Usage
var session_cache = SessionCache.init(allocator);
defer session_cache.deinit();

const config = zrpc.QuicConfig{
    .enable_0rtt = true,
    .session_cache = &session_cache,
};

// First connection: 1-RTT
const resp1 = try transport.sendWithConfig("quics://api.example.com", msg, config);
// Session ticket saved automatically

// Second connection: 0-RTT!
const resp2 = try transport.sendWithConfig("quics://api.example.com", msg, config);
// Data sent before TLS handshake completes
```

## Connection Migration

### Use Case: Mobile Network Switching

```zig
// Client maintains QUIC connection across network changes
pub const MigratingClient = struct {
    allocator: std.mem.Allocator,
    connection: *zrpc.QuicConnection,

    pub fn handleNetworkChange(self: *MigratingClient, new_interface: std.net.Address) !void {
        // QUIC automatically handles migration via connection ID
        // Just update local socket binding
        try self.connection.migrate(new_interface);

        std.log.info("Connection migrated to new network", .{});
        // Existing streams continue seamlessly!
    }
};
```

### Path Validation

```zig
// Server validates new client path
pub fn validateClientMigration(conn: *zrpc.QuicConnection) !void {
    const new_addr = conn.getPeerAddress();

    // Send PATH_CHALLENGE frame
    const challenge_data = std.crypto.random.bytes(&[8]u8{});
    try conn.sendPathChallenge(challenge_data);

    // Wait for PATH_RESPONSE
    const response = try conn.receivePathResponse(5 * std.time.ns_per_s);

    if (!std.mem.eql(u8, &challenge_data, &response)) {
        return error.PathValidationFailed;
    }

    std.log.info("Client path validated: {}", .{new_addr});
}
```

## Performance Tuning

### Congestion Control

```zig
pub const CongestionControlAlgorithm = enum {
    cubic,      // Default, good general purpose
    bbr,        // Better for high bandwidth-delay product
    reno,       // Conservative, stable
};

const config = zrpc.QuicConfig{
    .congestion_control = .bbr,
    .initial_window = 32768,      // 32KB
    .max_window = 16 * 1024 * 1024, // 16MB
};
```

### Stream Limits

```zig
const config = zrpc.QuicConfig{
    .max_concurrent_streams = 100,
    .max_stream_data = 1024 * 1024, // 1MB per stream
    .max_connection_data = 10 * 1024 * 1024, // 10MB total
};
```

### Packet Sizing

```zig
// Optimize for network MTU
const config = zrpc.QuicConfig{
    .max_udp_payload_size = 1350, // Safe for most networks
    // Or detect MTU:
    .max_udp_payload_size = detectPathMTU(),
};

fn detectPathMTU() u16 {
    // Start with 1500, probe larger sizes
    // Fall back on ICMP fragmentation needed
    return 1350; // Conservative default
}
```

## Security

### TLS 1.3 Configuration

```zig
const tls_config = zrpc.TlsConfig{
    .cert_file = "server.crt",
    .key_file = "server.key",
    .ca_file = "ca.crt",

    // ALPN for HTTP/3
    .alpn_protocols = &.{"h3"},

    // Cipher suites (TLS 1.3)
    .cipher_suites = &.{
        "TLS_AES_256_GCM_SHA384",
        "TLS_CHACHA20_POLY1305_SHA256",
    },

    // Client authentication
    .verify_peer = true,
    .require_client_cert = false,
};
```

### 0-RTT Security Considerations

```zig
// 0-RTT data is NOT forward-secret
// Only use for idempotent requests

pub fn is0RttSafe(method: []const u8) bool {
    return std.mem.eql(u8, method, "GET") or
           std.mem.eql(u8, method, "HEAD");
}

// Reject replay attacks
pub fn handle0RttRequest(req: Request) !Response {
    if (req.is_0rtt) {
        if (!is0RttSafe(req.method)) {
            return error.UnsafeFor0RTT;
        }

        // Check anti-replay nonce
        if (replay_cache.contains(req.nonce)) {
            return error.ReplayAttack;
        }
    }

    // Process request...
}
```

## Monitoring

### Connection Metrics

```zig
pub const QuicMetrics = struct {
    rtt_us: u64,
    congestion_window: u64,
    bytes_in_flight: u64,
    packets_lost: u64,
    packets_sent: u64,
    streams_active: u32,

    pub fn collect(conn: *zrpc.QuicConnection) QuicMetrics {
        return .{
            .rtt_us = conn.smoothed_rtt,
            .congestion_window = conn.cwin,
            .bytes_in_flight = conn.bytes_in_flight,
            .packets_lost = conn.loss_count,
            .packets_sent = conn.packet_count,
            .streams_active = conn.active_stream_count,
        };
    }
};

// Prometheus export
pub fn exportMetrics(metrics: QuicMetrics) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\quic_rtt_microseconds {d}
        \\quic_congestion_window_bytes {d}
        \\quic_packets_lost_total {d}
        \\quic_streams_active {d}
    , .{
        metrics.rtt_us,
        metrics.congestion_window,
        metrics.packets_lost,
        metrics.streams_active,
    });
}
```

## Troubleshooting

### UDP Blocked

```bash
# Test UDP connectivity
nc -u -v -z api.example.com 443

# Fallback to HTTP/2
if (quic_connect_fails) {
    use_http2_fallback();
}
```

### High Packet Loss

```zig
// Increase retransmission timeout
const config = zrpc.QuicConfig{
    .max_pto = 60 * std.time.ns_per_s, // 60s max
    .pto_backoff = 2.0, // Exponential backoff
};
```

### Certificate Issues

```bash
# Verify certificate
openssl s_client -connect api.example.com:443 -alpn h3

# Common issues:
# - Wrong ALPN (must include "h3")
# - Expired certificate
# - Hostname mismatch
```

## Best Practices

✅ **Enable 0-RTT for repeated connections**
✅ **Use BBR congestion control for high-BDP**
✅ **Set appropriate stream limits**
✅ **Monitor packet loss and RTT**
✅ **Implement graceful HTTP/2 fallback**
✅ **Use connection migration on mobile**
✅ **Validate paths after migration**
✅ **Don't use 0-RTT for non-idempotent ops**

## Binary Size

- **zrpc-core**: 200KB
- **+ QUIC transport**: +600KB (total 800KB)
- **Dependencies**: zquic, zcrypto

## Summary

QUIC provides **cutting-edge performance** for network RPC with 0-RTT resumption, connection migration, and no head-of-line blocking. Perfect for high-performance microservices and mobile applications.

Use QUIC when you need **maximum network performance** and **modern features**.
