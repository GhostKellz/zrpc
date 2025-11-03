const std = @import("std");
const zpack = @import("zpack");
const transport = @import("transport.zig");

/// Compression middleware for zrpc
/// Provides transparent compression/decompression for all transports
/// Integrates zpack's LZ77 streaming compression

pub const CompressionError = error{
    CompressionFailed,
    DecompressionFailed,
    UnsupportedAlgorithm,
    InvalidConfiguration,
} || zpack.ZpackError;

/// Compression algorithms supported
pub const Algorithm = enum(u8) {
    none = 0,
    lz77 = 1,
    // Future: zstd = 2, snappy = 3, etc.

    pub fn toString(self: Algorithm) []const u8 {
        return switch (self) {
            .none => "identity",
            .lz77 => "lz77",
        };
    }

    pub fn fromString(name: []const u8) ?Algorithm {
        if (std.mem.eql(u8, name, "identity")) return .none;
        if (std.mem.eql(u8, name, "lz77")) return .lz77;
        return null;
    }
};

/// Compression level
pub const Level = enum {
    fast,
    balanced,
    best,

    pub fn toZpackLevel(self: Level) zpack.CompressionLevel {
        return switch (self) {
            .fast => .fast,
            .balanced => .balanced,
            .best => .best,
        };
    }
};

/// Compression configuration
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
    /// Chunk size for streaming (0 = use default)
    stream_chunk_size: usize = 4096,

    pub fn validate(self: Config) CompressionError!void {
        if (self.min_size > 1024 * 1024) {
            return CompressionError.InvalidConfiguration;
        }
        if (self.stream_chunk_size > 0 and self.stream_chunk_size < 1024) {
            return CompressionError.InvalidConfiguration;
        }
    }
};

/// Compression context for a connection
pub const Context = struct {
    allocator: std.mem.Allocator,
    config: Config,
    compressor: ?*zpack.StreamingCompressor = null,
    decompressor: ?*zpack.StreamingDecompressor = null,

    pub fn init(allocator: std.mem.Allocator, config: Config) CompressionError!Context {
        try config.validate();

        return Context{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Context) void {
        if (self.compressor) |comp| {
            comp.deinit();
            self.allocator.destroy(comp);
        }
        if (self.decompressor) |decomp| {
            decomp.deinit();
            self.allocator.destroy(decomp);
        }
    }

    /// Initialize streaming compressor (lazy init)
    fn ensureCompressor(self: *Context) CompressionError!*zpack.StreamingCompressor {
        if (self.compressor) |comp| {
            return comp;
        }

        const zpack_config = self.config.level.toZpackLevel().getConfig();
        const comp = try self.allocator.create(zpack.StreamingCompressor);
        comp.* = try zpack.StreamingCompressor.init(self.allocator, zpack_config);
        self.compressor = comp;
        return comp;
    }

    /// Initialize streaming decompressor (lazy init)
    fn ensureDecompressor(self: *Context) CompressionError!*zpack.StreamingDecompressor {
        if (self.decompressor) |decomp| {
            return decomp;
        }

        const window_size = self.config.level.toZpackLevel().getConfig().window_size;
        const decomp = try self.allocator.create(zpack.StreamingDecompressor);
        decomp.* = try zpack.StreamingDecompressor.init(self.allocator, window_size);
        self.decompressor = decomp;
        return decomp;
    }

    /// Compress data (one-shot)
    pub fn compress(self: *Context, data: []const u8) CompressionError![]u8 {
        if (self.config.algorithm == .none or data.len < self.config.min_size) {
            // No compression - return copy
            const result = try self.allocator.alloc(u8, data.len);
            @memcpy(result, data);
            return result;
        }

        switch (self.config.algorithm) {
            .none => unreachable,
            .lz77 => {
                return zpack.Compression.compressWithLevel(
                    self.allocator,
                    data,
                    self.config.level.toZpackLevel(),
                ) catch |err| {
                    std.debug.print("[Compression] LZ77 compression failed: {}\n", .{err});
                    return CompressionError.CompressionFailed;
                };
            },
        }
    }

    /// Decompress data (one-shot)
    pub fn decompress(self: *Context, data: []const u8) CompressionError![]u8 {
        if (self.config.algorithm == .none) {
            // No compression - return copy
            const result = try self.allocator.alloc(u8, data.len);
            @memcpy(result, data);
            return result;
        }

        switch (self.config.algorithm) {
            .none => unreachable,
            .lz77 => {
                return zpack.Compression.decompress(self.allocator, data) catch |err| {
                    std.debug.print("[Compression] LZ77 decompression failed: {}\n", .{err});
                    return CompressionError.DecompressionFailed;
                };
            },
        }
    }

    /// Compress data using streaming API
    pub fn compressStream(self: *Context, reader: anytype, writer: anytype) CompressionError!void {
        if (self.config.algorithm == .none) {
            // No compression - copy data
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = reader.read(&buf) catch return CompressionError.CompressionFailed;
                if (n == 0) break;
                writer.writeAll(buf[0..n]) catch return CompressionError.CompressionFailed;
            }
            return;
        }

        switch (self.config.algorithm) {
            .none => unreachable,
            .lz77 => {
                var comp = try self.ensureCompressor();
                comp.compressReader(writer, reader, self.config.stream_chunk_size) catch |err| {
                    std.debug.print("[Compression] Streaming compression failed: {}\n", .{err});
                    return CompressionError.CompressionFailed;
                };
            },
        }
    }

    /// Decompress data using streaming API
    pub fn decompressStream(self: *Context, reader: anytype, writer: anytype) CompressionError!void {
        if (self.config.algorithm == .none) {
            // No compression - copy data
            var buf: [4096]u8 = undefined;
            while (true) {
                const n = reader.read(&buf) catch return CompressionError.DecompressionFailed;
                if (n == 0) break;
                writer.writeAll(buf[0..n]) catch return CompressionError.DecompressionFailed;
            }
            return;
        }

        switch (self.config.algorithm) {
            .none => unreachable,
            .lz77 => {
                var decomp = try self.ensureDecompressor();
                const window_size = self.config.level.toZpackLevel().getConfig().window_size;
                decomp.decompressReader(writer, reader, window_size, self.config.stream_chunk_size) catch |err| {
                    std.debug.print("[Compression] Streaming decompression failed: {}\n", .{err});
                    return CompressionError.DecompressionFailed;
                };
            },
        }
    }
};

/// Compressed message header (4 bytes)
/// Format: [algorithm(1)][flags(1)][original_size(2)]
pub const MessageHeader = struct {
    algorithm: Algorithm,
    is_compressed: bool,
    original_size: u16,

    pub fn encode(self: MessageHeader) [4]u8 {
        var buf: [4]u8 = undefined;
        buf[0] = @intFromEnum(self.algorithm);
        buf[1] = if (self.is_compressed) 1 else 0;
        buf[2] = @intCast((self.original_size >> 8) & 0xFF);
        buf[3] = @intCast(self.original_size & 0xFF);
        return buf;
    }

    pub fn decode(buf: *const [4]u8) MessageHeader {
        return MessageHeader{
            .algorithm = @enumFromInt(buf[0]),
            .is_compressed = buf[1] != 0,
            .original_size = (@as(u16, buf[2]) << 8) | @as(u16, buf[3]),
        };
    }
};

/// Compressed frame wrapper
/// Adds compression metadata to transport frames
pub const CompressedFrame = struct {
    header: MessageHeader,
    payload: []const u8,

    pub fn encode(self: CompressedFrame, allocator: std.mem.Allocator) ![]u8 {
        const total_size = 4 + self.payload.len;
        var result = try allocator.alloc(u8, total_size);

        const header_bytes = self.header.encode();
        @memcpy(result[0..4], &header_bytes);
        @memcpy(result[4..], self.payload);

        return result;
    }

    pub fn decode(allocator: std.mem.Allocator, data: []const u8) !CompressedFrame {
        if (data.len < 4) {
            return error.InvalidFrame;
        }

        const header_bytes: *const [4]u8 = @ptrCast(data[0..4]);
        const header = MessageHeader.decode(header_bytes);

        const payload = try allocator.alloc(u8, data.len - 4);
        @memcpy(payload, data[4..]);

        return CompressedFrame{
            .header = header,
            .payload = payload,
        };
    }
};

/// Compression statistics
pub const Stats = struct {
    messages_compressed: u64 = 0,
    messages_decompressed: u64 = 0,
    bytes_before_compression: u64 = 0,
    bytes_after_compression: u64 = 0,
    bytes_before_decompression: u64 = 0,
    bytes_after_decompression: u64 = 0,

    pub fn compressionRatio(self: Stats) f64 {
        if (self.bytes_before_compression == 0) return 0.0;
        return @as(f64, @floatFromInt(self.bytes_after_compression)) / @as(f64, @floatFromInt(self.bytes_before_compression));
    }

    pub fn decompressionRatio(self: Stats) f64 {
        if (self.bytes_before_decompression == 0) return 0.0;
        return @as(f64, @floatFromInt(self.bytes_after_decompression)) / @as(f64, @floatFromInt(self.bytes_before_decompression));
    }

    pub fn print(self: Stats) void {
        std.debug.print("Compression Stats:\n", .{});
        std.debug.print("  Messages compressed: {}\n", .{self.messages_compressed});
        std.debug.print("  Messages decompressed: {}\n", .{self.messages_decompressed});
        std.debug.print("  Compression ratio: {d:.2}:1\n", .{self.compressionRatio()});
        std.debug.print("  Decompression ratio: {d:.2}:1\n", .{self.decompressionRatio()});
        std.debug.print("  Bytes saved: {} ({d:.1}%)\n", .{
            self.bytes_before_compression - self.bytes_after_compression,
            (1.0 - self.compressionRatio()) * 100.0,
        });
    }
};

/// Compression-aware stream wrapper
pub const CompressedStream = struct {
    inner_stream: transport.Stream,
    context: *Context,
    stats: Stats = .{},

    pub fn init(inner: transport.Stream, ctx: *Context) CompressedStream {
        return .{
            .inner_stream = inner,
            .context = ctx,
        };
    }

    pub fn write(self: *CompressedStream, data: []const u8) !usize {
        // Compress if needed
        const compressed = try self.context.compress(data);
        defer self.context.allocator.free(compressed);

        const header = MessageHeader{
            .algorithm = self.context.config.algorithm,
            .is_compressed = compressed.len < data.len,
            .original_size = @intCast(@min(data.len, std.math.maxInt(u16))),
        };

        // Encode frame with header
        const frame = CompressedFrame{
            .header = header,
            .payload = if (header.is_compressed) compressed else data,
        };

        const encoded = try frame.encode(self.context.allocator);
        defer self.context.allocator.free(encoded);

        // Update stats
        self.stats.messages_compressed += 1;
        self.stats.bytes_before_compression += data.len;
        self.stats.bytes_after_compression += encoded.len;

        // Write to underlying stream
        return try self.inner_stream.vtable.write(self.inner_stream.ptr, encoded);
    }

    pub fn read(self: *CompressedStream, buffer: []u8) !transport.Frame {
        // Read from underlying stream
        const frame = try self.inner_stream.vtable.read(self.inner_stream.ptr, buffer);

        if (frame.data.len < 4) {
            return frame; // Pass through small frames
        }

        // Decode compression header
        const compressed_frame = try CompressedFrame.decode(self.context.allocator, frame.data);
        defer self.context.allocator.free(compressed_frame.payload);

        // Decompress if needed
        if (compressed_frame.header.is_compressed) {
            const decompressed = try self.context.decompress(compressed_frame.payload);
            defer self.context.allocator.free(decompressed);

            // Update stats
            self.stats.messages_decompressed += 1;
            self.stats.bytes_before_decompression += compressed_frame.payload.len;
            self.stats.bytes_after_decompression += decompressed.len;

            // Copy to buffer
            const copy_len = @min(decompressed.len, buffer.len);
            @memcpy(buffer[0..copy_len], decompressed[0..copy_len]);

            return transport.Frame{
                .data = buffer[0..copy_len],
                .end_of_stream = frame.end_of_stream,
            };
        } else {
            // Pass through uncompressed data
            return frame;
        }
    }

    pub fn close(self: *CompressedStream) void {
        self.inner_stream.vtable.close(self.inner_stream.ptr);
    }

    pub fn getStats(self: *CompressedStream) Stats {
        return self.stats;
    }
};

/// Helper function to create compressed connection
pub fn wrapConnection(conn: transport.Connection, ctx: *Context) transport.Connection {
    _ = conn;
    _ = ctx;
    // TODO: Implement connection wrapper that automatically compresses streams
    unreachable;
}

// Tests
test "compression context init" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try Context.init(allocator, .{});
    defer ctx.deinit();

    try testing.expect(ctx.config.algorithm == .lz77);
    try testing.expect(ctx.config.level == .balanced);
}

test "compress and decompress" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var ctx = try Context.init(allocator, .{ .min_size = 0 });
    defer ctx.deinit();

    const original = "Hello, zRPC compression! This is a test message.";

    const compressed = try ctx.compress(original);
    defer allocator.free(compressed);

    const decompressed = try ctx.decompress(compressed);
    defer allocator.free(decompressed);

    try testing.expectEqualSlices(u8, original, decompressed);
}

test "message header encoding/decoding" {
    const testing = std.testing;

    const header = MessageHeader{
        .algorithm = .lz77,
        .is_compressed = true,
        .original_size = 1234,
    };

    const encoded = header.encode();
    const decoded = MessageHeader.decode(&encoded);

    try testing.expectEqual(header.algorithm, decoded.algorithm);
    try testing.expectEqual(header.is_compressed, decoded.is_compressed);
    try testing.expectEqual(header.original_size, decoded.original_size);
}

test "compressed frame encoding/decoding" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const payload = "test payload";

    const frame = CompressedFrame{
        .header = MessageHeader{
            .algorithm = .lz77,
            .is_compressed = true,
            .original_size = @intCast(payload.len),
        },
        .payload = payload,
    };

    const encoded = try frame.encode(allocator);
    defer allocator.free(encoded);

    const decoded = try CompressedFrame.decode(allocator, encoded);
    defer allocator.free(decoded.payload);

    try testing.expectEqual(frame.header.algorithm, decoded.header.algorithm);
    try testing.expectEqual(frame.header.is_compressed, decoded.header.is_compressed);
    try testing.expectEqualSlices(u8, payload, decoded.payload);
}

test "compression stats" {
    const testing = std.testing;

    var stats = Stats{
        .bytes_before_compression = 1000,
        .bytes_after_compression = 500,
    };

    try testing.expectEqual(@as(f64, 0.5), stats.compressionRatio());
}

test "algorithm from string" {
    const testing = std.testing;

    try testing.expectEqual(Algorithm.none, Algorithm.fromString("identity").?);
    try testing.expectEqual(Algorithm.lz77, Algorithm.fromString("lz77").?);
    try testing.expect(Algorithm.fromString("unknown") == null);
}
