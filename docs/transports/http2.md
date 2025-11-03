# HTTP/2 Transport

## Overview

The HTTP/2 transport provides **standard gRPC compatibility** with widespread support, battle-tested performance, and broad ecosystem integration.

## Performance Characteristics

| Metric | HTTP/2 | HTTP/1.1 | QUIC |
|--------|--------|----------|------|
| **Multiplexing** | ✅ Yes | ❌ No | ✅ Yes |
| **Header Compression** | HPACK | ❌ No | QPACK |
| **Server Push** | ✅ Yes | ❌ No | ✅ Yes |
| **Connection Setup** | 1-2 RTT | 1-2 RTT | 0-1 RTT |
| **Head-of-line Blocking** | ✅ Yes (TCP) | ✅ Yes | ❌ No |
| **Binary Size** | 400KB | 300KB | 800KB |

## Key Features

✅ **gRPC Standard** - 100% compatible with existing gRPC services
✅ **Streaming** - Unary, client, server, bidirectional
✅ **Multiplexing** - Many RPCs over one connection
✅ **Flow Control** - Per-stream and connection-level
✅ **TLS 1.3** - Optional encryption
✅ **Widely Supported** - All major platforms

## When to Use

### ✅ Perfect For
- **gRPC compatibility** - Standard protocol
- **Production systems** - Battle-tested
- **Mixed environments** - Interop with Go/Java/Python gRPC
- **Corporate networks** - TCP/443 always allowed
- **Reliable networks** - Low packet loss

### ✅ Consider Instead
- **QUIC** for 0-RTT and mobile (if supported)
- **UDS** for local IPC (faster)
- **gRPC-Web** for browsers

## Usage

### Build Configuration

```zig
// build.zig
const zrpc_dep = b.dependency("zrpc", .{
    .target = target,
    .optimize = optimize,
    .http2 = true,     // Enable HTTP/2
    .quic = false,     // Disable QUIC (smaller binary)
});

const zrpc_http2 = zrpc_dep.module("zrpc-transport-http2");
exe.root_module.addImport("zrpc-transport-http2", zrpc_http2);
```

### Client Example

```zig
const std = @import("std");
const zrpc = @import("zrpc-transport-http2");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var transport = zrpc.Http2Transport.init(allocator);

    // Create message with metadata
    var message = zrpc.Message.init(allocator, "request payload");
    defer message.deinit();

    try message.addHeader("grpc-method", "MyService/MyMethod");
    try message.addHeader("authorization", "Bearer token123");

    const response = try transport.send("https://api.example.com/service", message);
    defer allocator.free(response.body);

    std.log.info("Response: {s}", .{response.body});
}
```

### Server Example

```zig
const std = @import("std");
const zrpc = @import("zrpc-transport-http2");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Optional TLS
    const tls_config = zrpc.TlsConfig{
        .cert_file = "server.crt",
        .key_file = "server.key",
        .alpn_protocols = &.{"h2"}, // HTTP/2
    };

    const bind_addr = try std.net.Address.parseIp("0.0.0.0", 8080);
    var server = try zrpc.Http2Server.init(allocator, bind_addr, tls_config);
    defer server.deinit();

    while (true) {
        var conn = try server.accept();
        defer conn.close();

        // Handle gRPC streams
        while (true) {
            const frame = try conn.readFrame();
            defer allocator.free(frame.data);

            if (frame.frame_type == .headers) {
                // Parse gRPC method
                const method = parseMethod(frame.data);
                std.log.info("RPC call: {s}", .{method});
            }

            if (frame.flags & zrpc.Frame.Flags.END_STREAM != 0) {
                break; // Request complete
            }
        }

        // Send response
        const response_frame = zrpc.Frame{
            .stream_id = frame.stream_id,
            .frame_type = .data,
            .flags = zrpc.Frame.Flags.END_STREAM,
            .data = "response data",
        };
        try conn.sendFrame(response_frame);
    }
}
```

## gRPC Wire Format

### Message Framing

```
gRPC Message = [Compressed-Flag][Message-Length][Message]

Compressed-Flag: 1 byte
  0 = not compressed
  1 = compressed with gzip/deflate

Message-Length: 4 bytes (big-endian uint32)
  Length of protobuf message

Message: N bytes
  Serialized protobuf
```

### Implementation

```zig
pub fn encodeGrpcMessage(allocator: std.mem.Allocator, data: []const u8, compressed: bool) ![]u8 {
    var result = try allocator.alloc(u8, 5 + data.len);

    // Compressed flag
    result[0] = if (compressed) 1 else 0;

    // Message length (4 bytes, big-endian)
    std.mem.writeInt(u32, result[1..5], @intCast(data.len), .big);

    // Message data
    @memcpy(result[5..], data);

    return result;
}

pub fn decodeGrpcMessage(allocator: std.mem.Allocator, data: []const u8) !struct {
    compressed: bool,
    message: []const u8,
} {
    if (data.len < 5) return error.InvalidMessage;

    const compressed = data[0] != 0;
    const length = std.mem.readInt(u32, data[1..5], .big);

    if (data.len < 5 + length) return error.IncompleteMessage;

    return .{
        .compressed = compressed,
        .message = data[5 .. 5 + length],
    };
}
```

## Streaming RPCs

### Server Streaming

```zig
// Server sends multiple responses
pub fn handleServerStreaming(conn: *zrpc.Http2Connection, stream_id: u32) !void {
    const items = [_][]const u8{ "item1", "item2", "item3" };

    for (items, 0..) |item, i| {
        const is_last = (i == items.len - 1);

        const frame = zrpc.Frame{
            .stream_id = stream_id,
            .frame_type = .data,
            .flags = if (is_last) zrpc.Frame.Flags.END_STREAM else 0,
            .data = item,
        };

        try conn.sendFrame(frame);
    }
}
```

### Client Streaming

```zig
// Client sends multiple requests
pub fn handleClientStreaming(conn: *zrpc.Http2Connection, stream_id: u32) ![]const u8 {
    var accumulated = std.ArrayList(u8).init(allocator);
    defer accumulated.deinit();

    while (true) {
        const frame = try conn.readFrame();
        defer allocator.free(frame.data);

        if (frame.stream_id != stream_id) continue;

        if (frame.frame_type == .data) {
            try accumulated.appendSlice(frame.data);
        }

        if (frame.flags & zrpc.Frame.Flags.END_STREAM != 0) {
            break; // Client done sending
        }
    }

    // Process accumulated data
    return processClientData(accumulated.items);
}
```

### Bidirectional Streaming

```zig
// Full-duplex communication
pub fn handleBidiStreaming(conn: *zrpc.Http2Connection, stream_id: u32) !void {
    // Spawn reader thread
    const reader_thread = try std.Thread.spawn(.{}, readClientData, .{ conn, stream_id });
    defer reader_thread.join();

    // Write responses in main thread
    while (shouldContinue()) {
        const response_data = generateResponse();
        const frame = zrpc.Frame{
            .stream_id = stream_id,
            .frame_type = .data,
            .flags = 0,
            .data = response_data,
        };
        try conn.sendFrame(frame);
    }
}
```

## Flow Control

### Connection-Level

```zig
pub const FlowController = struct {
    window_size: u32,
    bytes_sent: u32,

    pub fn init(initial_window: u32) FlowController {
        return .{
            .window_size = initial_window,
            .bytes_sent = 0,
        };
    }

    pub fn canSend(self: *FlowController, bytes: usize) bool {
        return (self.bytes_sent + bytes) <= self.window_size;
    }

    pub fn consumeWindow(self: *FlowController, bytes: usize) void {
        self.bytes_sent += @intCast(bytes);
    }

    pub fn updateWindow(self: *FlowController, increment: u32) void {
        self.window_size += increment;
    }
};
```

### Stream-Level

```zig
// Each stream has its own flow control
pub const Stream = struct {
    id: u32,
    flow_controller: FlowController,

    pub fn sendData(self: *Stream, conn: *Http2Connection, data: []const u8) !void {
        var offset: usize = 0;

        while (offset < data.len) {
            // Wait for window
            while (!self.flow_controller.canSend(1)) {
                const window_update = try conn.readFrame();
                if (window_update.frame_type == .window_update) {
                    const increment = std.mem.readInt(u32, window_update.data, .big);
                    self.flow_controller.updateWindow(increment);
                }
            }

            // Send chunk
            const chunk_size = @min(
                data.len - offset,
                self.flow_controller.window_size - self.flow_controller.bytes_sent,
            );

            const frame = Frame{
                .stream_id = self.id,
                .frame_type = .data,
                .flags = if (offset + chunk_size == data.len) Frame.Flags.END_STREAM else 0,
                .data = data[offset .. offset + chunk_size],
            };

            try conn.sendFrame(frame);
            self.flow_controller.consumeWindow(chunk_size);
            offset += chunk_size;
        }
    }
};
```

## Performance Tuning

### Connection Settings

```zig
pub const Http2Settings = struct {
    max_concurrent_streams: u32 = 100,
    initial_window_size: u32 = 65535,
    max_frame_size: u32 = 16384,
    max_header_list_size: u32 = 8192,

    pub fn toFrame(self: Http2Settings) ![]u8 {
        var settings_data = std.ArrayList(u8).init(allocator);

        // Each setting is 6 bytes: 2-byte ID + 4-byte value
        try writeSettingEntry(&settings_data, 0x3, self.max_concurrent_streams);
        try writeSettingEntry(&settings_data, 0x4, self.initial_window_size);
        try writeSettingEntry(&settings_data, 0x5, self.max_frame_size);
        try writeSettingEntry(&settings_data, 0x6, self.max_header_list_size);

        return settings_data.toOwnedSlice();
    }
};
```

### Header Compression (HPACK)

```zig
// Simple HPACK static table
const STATIC_TABLE = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":status", .value = "200" },
    .{ .name = "content-type", .value = "application/grpc" },
    // ... more entries
};

pub fn encodeHeaders(headers: std.StringHashMap([]const u8)) ![]u8 {
    var result = std.ArrayList(u8).init(allocator);

    var it = headers.iterator();
    while (it.next()) |entry| {
        // Check static table
        if (findInStaticTable(entry.key_ptr.*, entry.value_ptr.*)) |index| {
            // Indexed header field
            try result.append(0x80 | @as(u8, @intCast(index)));
        } else {
            // Literal header field
            try result.append(0x00);
            try encodeString(&result, entry.key_ptr.*);
            try encodeString(&result, entry.value_ptr.*);
        }
    }

    return result.toOwnedSlice();
}
```

## Monitoring

### Connection Metrics

```zig
pub const Http2Metrics = struct {
    active_streams: u32,
    total_requests: u64,
    bytes_sent: u64,
    bytes_received: u64,
    header_compression_ratio: f64,

    pub fn collect(conn: *Http2Connection) Http2Metrics {
        return .{
            .active_streams = conn.stream_count,
            .total_requests = conn.request_count,
            .bytes_sent = conn.bytes_sent,
            .bytes_received = conn.bytes_received,
            .header_compression_ratio = @as(f64, @floatFromInt(conn.compressed_header_bytes)) /
                @as(f64, @floatFromInt(conn.uncompressed_header_bytes)),
        };
    }
};
```

## Troubleshooting

### "Stream closed"
```zig
// Common causes:
// 1. Flow control exhausted
// 2. Client cancelled request
// 3. Stream timeout

// Solution: Check flow control window
if (stream.flow_controller.window_size == 0) {
    // Send WINDOW_UPDATE
    try conn.sendWindowUpdate(stream.id, 65535);
}
```

### "Too many streams"
```zig
// Exceeded MAX_CONCURRENT_STREAMS
// Solution: Wait for stream to close or increase limit

const new_settings = Http2Settings{
    .max_concurrent_streams = 200, // Increase limit
};
try conn.updateSettings(new_settings);
```

## Best Practices

✅ **Use ALPN for TLS negotiation** (h2)
✅ **Set appropriate stream limits**
✅ **Enable header compression**
✅ **Monitor flow control windows**
✅ **Implement graceful shutdown**
✅ **Handle GOAWAY frames**
✅ **Use server push sparingly**

## Binary Size

- **zrpc-core**: 200KB
- **+ HTTP/2 transport**: +200KB (total 400KB)
- **No external dependencies**

## Summary

HTTP/2 is the **battle-tested standard** for gRPC, providing excellent compatibility, wide support, and solid performance. Perfect for production systems that need reliability over cutting-edge features.

Use HTTP/2 when you need **standard gRPC compatibility** and **reliable performance**.
