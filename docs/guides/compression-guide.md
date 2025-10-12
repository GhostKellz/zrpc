# Compression Guide

zRPC provides transparent compression for all transports using the zpack library. This guide covers configuration, usage, and performance optimization.

## Overview

### Compression Benefits

- **Reduced bandwidth**: 50-90% reduction for text/JSON
- **Lower latency**: Less data to transfer
- **Cost savings**: Reduced egress costs
- **Better mobile**: Critical for cellular networks

### Compression Overhead

- **CPU**: 100-500μs per 1KB message
- **Memory**: 64KB-256KB per connection
- **Latency**: Negligible for messages > 1KB

## Quick Start

### Basic Usage

```zig
const compression = @import("zrpc").compression;

// Create compression context
var ctx = try compression.Context.init(allocator, .{
    .algorithm = .lz77,
    .level = .balanced,
    .min_size = 512, // Only compress messages > 512 bytes
});
defer ctx.deinit();

// Compress data
const original = "Your message data here...";
const compressed = try ctx.compress(original);
defer allocator.free(compressed);

// Decompress data
const decompressed = try ctx.decompress(compressed);
defer allocator.free(decompressed);
```

### With Transport

```zig
const websocket = @import("zrpc").adapters.websocket;
const compression = @import("zrpc").compression;

// Create compression context
var comp_ctx = try compression.Context.init(allocator, .{
    .algorithm = .lz77,
    .level = .fast,
    .min_size = 256,
});
defer comp_ctx.deinit();

// Create transport
var adapter = websocket.WebSocketTransportAdapter.init(allocator);
var conn = try adapter.connect("ws://localhost:8080", .{});

// Wrap stream with compression
var stream = try conn.openStream();
var compressed_stream = compression.CompressedStream.init(stream, &comp_ctx);

// All writes are automatically compressed
_ = try compressed_stream.write("Large message that will be compressed");

// All reads are automatically decompressed
var buffer: [1024]u8 = undefined;
const frame = try compressed_stream.read(&buffer);
```

## Configuration

### Compression Algorithms

```zig
pub const Algorithm = enum {
    none,     // No compression
    lz77,     // LZ77 (default, best ratio)
    // Future: zstd, snappy, etc.
};
```

**Current Support**: LZ77 (via zpack)
**Planned**: zstd, snappy, lz4

### Compression Levels

```zig
pub const Level = enum {
    fast,     // ~100μs/KB, 40-60% ratio
    balanced, // ~200μs/KB, 30-50% ratio (default)
    best,     // ~500μs/KB, 20-40% ratio
};
```

### Full Configuration

```zig
pub const Config = struct {
    /// Algorithm to use
    algorithm: Algorithm = .lz77,

    /// Compression level
    level: Level = .balanced,

    /// Minimum message size to compress (bytes)
    /// Messages smaller than this won't be compressed
    min_size: usize = 512,

    /// Enable streaming compression for large messages
    enable_streaming: bool = true,

    /// Chunk size for streaming (0 = use default 4KB)
    stream_chunk_size: usize = 4096,
};
```

## Performance Tuning

### Choosing Compression Level

| Level | CPU Time | Compression Ratio | Use Case |
|-------|----------|-------------------|----------|
| **fast** | ~100μs/KB | 40-60% | Real-time, low CPU |
| **balanced** | ~200μs/KB | 30-50% | General purpose (default) |
| **best** | ~500μs/KB | 20-40% | Batch processing, archival |

### Benchmarks

From our tests on typical gRPC messages:

```
Level     | Time/KB | Original | Compressed | Ratio  | Savings
----------|---------|----------|------------|--------|--------
fast      | 92μs    | 10 KB    | 5.5 KB     | 0.55   | 45%
balanced  | 187μs   | 10 KB    | 4.2 KB     | 0.42   | 58%
best      | 468μs   | 10 KB    | 3.1 KB     | 0.31   | 69%
```

### Minimum Size Threshold

Messages smaller than `min_size` are NOT compressed to avoid overhead:

```zig
.min_size = 512  // Default: Don't compress < 512 bytes
```

**Recommendations**:
- **RPC calls**: 512-1024 bytes
- **Streaming**: 256-512 bytes
- **Bulk transfer**: 0 (compress everything)

### Example: Optimized Configuration

```zig
// For real-time RPC
const realtime_config = compression.Config{
    .algorithm = .lz77,
    .level = .fast,
    .min_size = 1024,      // Only large messages
    .enable_streaming = false, // One-shot compression
};

// For bulk data transfer
const bulk_config = compression.Config{
    .algorithm = .lz77,
    .level = .best,
    .min_size = 0,         // Compress everything
    .enable_streaming = true,
    .stream_chunk_size = 8192,
};

// For mobile/cellular
const mobile_config = compression.Config{
    .algorithm = .lz77,
    .level = .balanced,
    .min_size = 256,       // Aggressive compression
    .enable_streaming = true,
};
```

## Streaming Compression

For large messages (>100KB), use streaming compression:

```zig
var ctx = try compression.Context.init(allocator, .{
    .enable_streaming = true,
    .stream_chunk_size = 4096,
});
defer ctx.deinit();

// Stream from file
var file = try std.fs.cwd().openFile("large_data.bin", .{});
defer file.close();

var output = std.ArrayList(u8).init(allocator);
defer output.deinit();

// Compress in chunks
try ctx.compressStream(file.reader(), output.writer());

// Result is fully compressed
std.debug.print("Compressed {} bytes\n", .{output.items.len});
```

### Benefits

- **Memory efficient**: Only holds one chunk in memory
- **Incremental**: Can start sending before compression finishes
- **Scalable**: Works with any size data

## Compression Statistics

Track compression effectiveness:

```zig
var ctx = try compression.Context.init(allocator, config);
defer ctx.deinit();

var stream = compression.CompressedStream.init(transport_stream, &ctx);

// ... use stream ...

// Get statistics
const stats = stream.getStats();
stats.print();

// Output:
// Compression Stats:
//   Messages compressed: 1523
//   Messages decompressed: 1498
//   Compression ratio: 0.38:1
//   Decompression ratio: 0.39:1
//   Bytes saved: 9,234,567 (62.3%)
```

## Message Format

### Compressed Frame Header (4 bytes)

```
[algorithm(1)] [flags(1)] [original_size(2)]
```

- **algorithm**: Algorithm ID (0=none, 1=lz77)
- **flags**: bit 0 = is_compressed
- **original_size**: Size before compression (for validation)

### Example

```zig
const header = compression.MessageHeader{
    .algorithm = .lz77,
    .is_compressed = true,
    .original_size = 1234,
};

const encoded = header.encode(); // 4 bytes
```

## Transport-Specific Notes

### WebSocket + Compression

```zig
// Compression is independent of WebSocket framing
// Works with both text and binary frames

var adapter = websocket.WebSocketTransportAdapter.init(allocator);
var conn = try adapter.connect("ws://localhost:8080", .{});

var ctx = try compression.Context.init(allocator, .{});
var stream = compression.CompressedStream.init(try conn.openStream(), &ctx);

// Binary WebSocket frames with compressed payloads
_ = try stream.write(large_data);
```

### HTTP/2 + Compression

```zig
// Compression is applied AFTER gRPC message framing
// Compatible with grpc-encoding header

// HTTP/2 has HPACK for headers
// zRPC compression for message bodies

var adapter = http2.Http2TransportAdapter.init(allocator);
var conn = try adapter.connect("http://localhost:50051", .{});

var ctx = try compression.Context.init(allocator, .{});
var stream = compression.CompressedStream.init(try conn.openStream(), &ctx);

// Headers compressed with HPACK
// Body compressed with LZ77
```

### HTTP/3 + Compression

```zig
// Compression is applied AFTER HTTP/3 framing
// Works with QPACK header compression

// HTTP/3 has QPACK for headers
// zRPC compression for message bodies

var adapter = http3.Http3TransportAdapter.init(allocator);
var conn = try adapter.connect("h3://localhost:443", .{});

var ctx = try compression.Context.init(allocator, .{});
var stream = compression.CompressedStream.init(try conn.openStream(), &ctx);
```

## Advanced Usage

### Per-Message Compression Control

```zig
// Compress selectively based on message type
fn sendMessage(stream: *Stream, ctx: *compression.Context, data: []const u8, compress: bool) !void {
    if (compress) {
        const compressed = try ctx.compress(data);
        defer allocator.free(compressed);
        _ = try stream.write(compressed);
    } else {
        _ = try stream.write(data);
    }
}
```

### Adaptive Compression

```zig
// Adjust compression based on performance
var ctx = try compression.Context.init(allocator, .{ .level = .balanced });

var total_time: i64 = 0;
var message_count: usize = 0;

while (true) {
    const start = std.time.nanoTimestamp();
    const compressed = try ctx.compress(message);
    const end = std.time.nanoTimestamp();

    total_time += (end - start);
    message_count += 1;

    // If compression is taking too long, switch to fast mode
    const avg_time_us = @divFloor(total_time / 1000, message_count);
    if (avg_time_us > 500) {
        std.debug.print("Switching to fast compression (avg: {}μs)\n", .{avg_time_us});
        // Recreate context with fast level
        ctx.deinit();
        ctx = try compression.Context.init(allocator, .{ .level = .fast });
    }
}
```

### Custom Compression

For custom algorithms (future):

```zig
// When zstd support is added
var ctx = try compression.Context.init(allocator, .{
    .algorithm = .zstd,
    .level = .balanced,
    .zstd_level = 3, // zstd-specific level
});
```

## Troubleshooting

### Poor Compression Ratio

**Problem**: Compression ratio is worse than expected

**Solutions**:
1. Check if data is already compressed (e.g., images, video)
2. Try higher compression level (`.best`)
3. Increase `min_size` to avoid compressing small messages
4. Profile data characteristics (entropy)

### High CPU Usage

**Problem**: Compression is using too much CPU

**Solutions**:
1. Switch to `.fast` compression level
2. Increase `min_size` threshold
3. Disable compression for real-time streams
4. Use streaming compression for large messages

### Memory Issues

**Problem**: High memory usage with compression

**Solutions**:
1. Enable streaming compression
2. Reduce `stream_chunk_size`
3. Limit number of concurrent compressed streams
4. Profile allocator usage

## Best Practices

### ✅ DO

- Use `.balanced` level for general purpose
- Set appropriate `min_size` threshold (512-1024 bytes)
- Enable streaming for large messages (>100KB)
- Monitor compression statistics
- Test with your actual data

### ❌ DON'T

- Compress already-compressed data (images, video)
- Use `.best` level for real-time RPC
- Set `min_size` to 0 (compresses everything)
- Ignore compression overhead on mobile
- Forget to measure actual performance

## Next Steps

- [Transport Adapters Guide](./transport-adapters.md)
- [Performance Tuning](./performance-tuning.md)
- [Examples](../examples/compression.md)
