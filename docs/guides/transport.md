# Transport Layer Guide

zRPC provides multiple transport options for different performance and deployment requirements. This guide covers HTTP/2, QUIC, and transport configuration.

## Overview

The transport layer handles the underlying network communication for RPC calls. zRPC supports:

- **HTTP/2** - Standard gRPC-compatible transport with multiplexing
- **QUIC** - Modern UDP-based transport with 0-RTT and connection migration
- **Mock Transport** - For testing and development

## HTTP/2 Transport

HTTP/2 is the standard transport for gRPC and provides excellent compatibility.

### Features

- Stream multiplexing over a single connection
- Header compression (HPACK)
- Server push (for streaming responses)
- Flow control
- TLS 1.2+ encryption

### Configuration

```zig
const transport_config = zrpc.transport.Http2Config{
    .max_frame_size = 16384,
    .max_header_table_size = 4096,
    .enable_push = true,
    .initial_window_size = 65535,
};

var client = try zrpc.Client.initWithHttp2(allocator, "https://api.example.com", transport_config);
```

### Connection Settings

```zig
const settings = zrpc.transport.Http2Settings{
    .header_table_size = 4096,
    .enable_push = true,
    .max_concurrent_streams = 100,
    .initial_window_size = 65535,
    .max_frame_size = 16384,
    .max_header_list_size = 8192,
};
```

## QUIC Transport

QUIC provides advanced features for modern networking environments.

### Features

- 0-RTT connection establishment
- Connection migration (switch networks seamlessly)
- Built-in encryption (TLS 1.3)
- Improved congestion control
- Stream multiplexing without head-of-line blocking

### Basic Configuration

```zig
const quic_config = zrpc.quic.QuicConfig{
    .initial_max_data = 1048576, // 1MB
    .initial_max_stream_data_bidi_local = 262144, // 256KB
    .initial_max_stream_data_bidi_remote = 262144, // 256KB
    .initial_max_streams_bidi = 100,
    .initial_max_streams_uni = 100,
    .max_idle_timeout = 30000, // 30 seconds
    .max_udp_payload_size = 1200,
};

var client = try zrpc.Client.initWithQuic(allocator, "quic://api.example.com:443", quic_config);
```

### Connection Migration

QUIC supports seamless connection migration when switching networks:

```zig
const migration_config = zrpc.quic.MigrationConfig{
    .enable_migration = true,
    .probe_timeout = 3000, // 3 seconds
    .max_migration_attempts = 3,
};

var connection = try zrpc.QuicConnection.initWithMigration(allocator, config, migration_config);
```

### 0-RTT Resumption

Enable 0-RTT for faster reconnections:

```zig
var connection = try zrpc.QuicConnection.init(allocator, config);

// Store session ticket for future use
const ticket = try connection.getSessionTicket();
try saveTicketToStorage(ticket);

// Resume with 0-RTT
const saved_ticket = try loadTicketFromStorage();
var resumed_connection = try zrpc.QuicConnection.resumeWith0RTT(allocator, config, saved_ticket);
```

## Message Structure

All transports use a common message structure:

```zig
const message = zrpc.transport.Message{
    .headers = headers_map,
    .body = request_data,
    .allocator = allocator,
};

// Add gRPC headers
try message.addHeader("content-type", "application/grpc");
try message.addHeader("grpc-encoding", "identity");
try message.addHeader("grpc-accept-encoding", "gzip");
```

## Frame Types

### HTTP/2 Frames

```zig
const frame = zrpc.transport.Frame{
    .stream_id = 1,
    .frame_type = .data,
    .flags = zrpc.transport.Frame.Flags.END_STREAM,
    .data = payload,
};
```

Common frame types:
- `data` - Contains message payload
- `headers` - Contains request/response headers
- `settings` - Connection configuration
- `ping` - Keep-alive and RTT measurement
- `goaway` - Graceful connection termination

### QUIC Frames

```zig
const quic_frame = zrpc.quic.QuicFrame{
    .frame_type = .stream,
    .stream_id = 4, // Client-initiated bidirectional stream
    .data = payload,
    .fin = true, // Final frame for stream
};
```

## Transport Selection

Choose the appropriate transport based on your requirements:

### Use HTTP/2 When:
- Maximum compatibility with existing gRPC infrastructure
- Corporate environments with HTTP proxy requirements
- Existing TLS certificate infrastructure
- Debugging tools that understand HTTP/2

### Use QUIC When:
- Mobile applications (connection migration)
- Low-latency requirements (0-RTT)
- Networks with packet loss (better congestion control)
- Modern cloud-native deployments

## Performance Optimization

### Connection Pooling

```zig
const pool_config = zrpc.transport.PoolConfig{
    .max_connections = 10,
    .max_idle_connections = 5,
    .connection_timeout = 30000,
    .idle_timeout = 300000, // 5 minutes
};

var pool = try zrpc.transport.ConnectionPool.init(allocator, pool_config);
defer pool.deinit();

// Get connection from pool
var connection = try pool.getConnection("api.example.com:443");
defer pool.returnConnection(connection);
```

### Load Balancing

```zig
const lb_config = zrpc.transport.LoadBalancerConfig{
    .strategy = .round_robin,
    .health_check_interval = 30000,
    .unhealthy_threshold = 3,
    .healthy_threshold = 2,
};

var load_balancer = try zrpc.transport.LoadBalancer.init(allocator, lb_config);

// Add backend endpoints
try load_balancer.addEndpoint("api1.example.com:443");
try load_balancer.addEndpoint("api2.example.com:443");
try load_balancer.addEndpoint("api3.example.com:443");

// Get balanced connection
var connection = try load_balancer.getConnection();
```

### Streaming Configuration

```zig
const stream_config = zrpc.transport.StreamConfig{
    .initial_window_size = 65535,
    .max_message_size = 4194304, // 4MB
    .compression = .gzip,
    .keep_alive_interval = 30000,
    .keep_alive_timeout = 5000,
};
```

## Error Handling

### Connection Errors

```zig
const connection = client.getConnection() catch |err| switch (err) {
    zrpc.Error.ConnectionTimeout => {
        // Retry with exponential backoff
        try retryWithBackoff();
    },
    zrpc.Error.ConnectionRefused => {
        // Try alternative endpoint
        try connectToBackup();
    },
    zrpc.Error.TlsHandshakeFailure => {
        // Check certificates and TLS configuration
        return handleTlsError();
    },
    else => return err,
};
```

### Transport-Specific Errors

```zig
// HTTP/2 specific errors
zrpc.Error.Http2ProtocolError => // Invalid frame or stream state
zrpc.Error.Http2FlowControlError => // Window size exceeded
zrpc.Error.Http2CompressionError => // HPACK decompression failed

// QUIC specific errors
zrpc.Error.QuicConnectionError => // QUIC connection terminated
zrpc.Error.QuicTransportError => // Transport parameter error
zrpc.Error.QuicApplicationError => // Application protocol error
```

## Monitoring and Debugging

### Transport Metrics

```zig
const metrics = try connection.getMetrics();
std.debug.print("RTT: {}ms\n", .{metrics.rtt_ms});
std.debug.print("Bandwidth: {} bytes/s\n", .{metrics.bandwidth_bps});
std.debug.print("Packet loss: {d:.2}%\n", .{metrics.packet_loss_rate * 100});
```

### Debug Logging

```zig
const debug_config = zrpc.transport.DebugConfig{
    .log_frames = true,
    .log_headers = true,
    .log_congestion = true,
    .log_migration = true,
};

var connection = try zrpc.QuicConnection.initWithDebug(allocator, config, debug_config);
```

## Example Configurations

### High-Performance Setup

```zig
// QUIC with optimized settings for high throughput
const high_perf_config = zrpc.quic.QuicConfig{
    .initial_max_data = 10485760, // 10MB
    .initial_max_stream_data_bidi_local = 2097152, // 2MB
    .initial_max_stream_data_bidi_remote = 2097152, // 2MB
    .initial_max_streams_bidi = 1000,
    .max_idle_timeout = 60000, // 60 seconds
    .max_udp_payload_size = 1452, // Ethernet MTU - headers
    .congestion_control = .bbr2,
};
```

### Low-Latency Setup

```zig
// QUIC with 0-RTT and minimal timeouts
const low_latency_config = zrpc.quic.QuicConfig{
    .initial_max_data = 262144, // 256KB
    .initial_max_stream_data_bidi_local = 65536, // 64KB
    .initial_max_stream_data_bidi_remote = 65536, // 64KB
    .initial_max_streams_bidi = 10,
    .max_idle_timeout = 10000, // 10 seconds
    .max_udp_payload_size = 1200,
    .enable_0rtt = true,
    .congestion_control = .cubic,
};
```

### Mobile-Optimized Setup

```zig
// QUIC with connection migration for mobile
const mobile_config = zrpc.quic.QuicConfig{
    .initial_max_data = 524288, // 512KB
    .initial_max_stream_data_bidi_local = 131072, // 128KB
    .initial_max_stream_data_bidi_remote = 131072, // 128KB
    .initial_max_streams_bidi = 50,
    .max_idle_timeout = 300000, // 5 minutes
    .max_udp_payload_size = 1200,
    .enable_migration = true,
    .migration_probe_timeout = 5000,
};
```

## Best Practices

1. **Choose Transport Wisely**: Use QUIC for new applications, HTTP/2 for compatibility
2. **Configure Timeouts**: Set appropriate timeouts based on network conditions
3. **Monitor Performance**: Track RTT, bandwidth, and error rates
4. **Handle Migration**: Implement proper connection migration for mobile apps
5. **Use Compression**: Enable gzip compression for large messages
6. **Pool Connections**: Reuse connections to reduce overhead
7. **Implement Retries**: Add exponential backoff for failed connections

## Related Documentation

- [TLS Configuration](tls.md)
- [Authentication](auth.md)
- [Streaming](streaming.md)
- [Performance Tuning](performance.md)