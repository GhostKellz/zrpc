const std = @import("std");
const testing = std.testing;
const transport = @import("../transport.zig");
const compression = @import("../compression.zig");

/// Performance Benchmarking Suite for zRPC
/// Measures throughput, latency, and resource usage

pub const BenchmarkConfig = struct {
    /// Number of messages to send
    message_count: usize = 10000,
    /// Message size in bytes
    message_size: usize = 1024,
    /// Number of concurrent streams
    concurrent_streams: usize = 10,
    /// Enable compression
    use_compression: bool = false,
    /// Compression level
    compression_level: compression.Level = .balanced,
    /// Warmup iterations
    warmup_iterations: usize = 100,
};

pub const BenchmarkResult = struct {
    name: []const u8,
    /// Total time in nanoseconds
    total_time_ns: i64,
    /// Messages per second
    messages_per_sec: f64,
    /// Megabytes per second
    mbps: f64,
    /// Average latency in microseconds
    avg_latency_us: f64,
    /// P50 latency in microseconds
    p50_latency_us: f64,
    /// P95 latency in microseconds
    p95_latency_us: f64,
    /// P99 latency in microseconds
    p99_latency_us: f64,
    /// Memory allocated (bytes)
    memory_used: usize,

    pub fn print(self: BenchmarkResult) void {
        std.debug.print("\n" ++ "=" ** 80 ++ "\n", .{});
        std.debug.print("Benchmark: {s}\n", .{self.name});
        std.debug.print("=" ** 80 ++ "\n", .{});
        std.debug.print("  Total Time:       {d:.2} ms\n", .{@as(f64, @floatFromInt(self.total_time_ns)) / 1_000_000});
        std.debug.print("  Messages/sec:     {d:.0}\n", .{self.messages_per_sec});
        std.debug.print("  Throughput:       {d:.2} MB/s\n", .{self.mbps});
        std.debug.print("  Latency (avg):    {d:.2} μs\n", .{self.avg_latency_us});
        std.debug.print("  Latency (p50):    {d:.2} μs\n", .{self.p50_latency_us});
        std.debug.print("  Latency (p95):    {d:.2} μs\n", .{self.p95_latency_us});
        std.debug.print("  Latency (p99):    {d:.2} μs\n", .{self.p99_latency_us});
        std.debug.print("  Memory Used:      {d:.2} MB\n", .{@as(f64, @floatFromInt(self.memory_used)) / 1_000_000});
        std.debug.print("=" ** 80 ++ "\n\n", .{});
    }
};

pub const LatencyStats = struct {
    samples: std.ArrayList(i64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LatencyStats {
        return .{
            .samples = std.ArrayList(i64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LatencyStats) void {
        self.samples.deinit();
    }

    pub fn record(self: *LatencyStats, latency_ns: i64) !void {
        try self.samples.append(latency_ns);
    }

    pub fn avg(self: *LatencyStats) f64 {
        if (self.samples.items.len == 0) return 0;
        var sum: i64 = 0;
        for (self.samples.items) |sample| {
            sum += sample;
        }
        return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(self.samples.items.len));
    }

    pub fn percentile(self: *LatencyStats, p: f64) f64 {
        if (self.samples.items.len == 0) return 0;

        // Sort samples
        var sorted = std.ArrayList(i64).init(self.allocator);
        defer sorted.deinit();
        sorted.appendSlice(self.samples.items) catch return 0;
        std.mem.sort(i64, sorted.items, {}, comptime std.sort.asc(i64));

        const index = @as(usize, @intFromFloat(@as(f64, @floatFromInt(sorted.items.len)) * p));
        const clamped_index = @min(index, sorted.items.len - 1);
        return @floatFromInt(sorted.items[clamped_index]);
    }
};

/// Benchmark: Compression Performance
pub fn benchmarkCompression(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    std.debug.print("\n[Benchmark] Running compression benchmark...\n", .{});

    var stats = LatencyStats.init(allocator);
    defer stats.deinit();

    // Generate test data
    const test_data = try allocator.alloc(u8, config.message_size);
    defer allocator.free(test_data);

    // Fill with pseudo-random but compressible data
    for (test_data, 0..) |*byte, i| {
        byte.* = @intCast((i % 256));
    }

    // Warmup
    var comp_ctx = try compression.Context.init(allocator, .{
        .algorithm = .lz77,
        .level = config.compression_level,
        .min_size = 0,
    });
    defer comp_ctx.deinit();

    for (0..config.warmup_iterations) |_| {
        const compressed = try comp_ctx.compress(test_data);
        defer allocator.free(compressed);
    }

    // Actual benchmark
    var memory_tracker = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = false }){};
    defer _ = memory_tracker.deinit();
    const tracked_allocator = memory_tracker.allocator();

    var ctx = try compression.Context.init(tracked_allocator, .{
        .algorithm = .lz77,
        .level = config.compression_level,
        .min_size = 0,
    });
    defer ctx.deinit();

    const start = std.time.nanoTimestamp();

    for (0..config.message_count) |_| {
        const iter_start = std.time.nanoTimestamp();

        const compressed = try ctx.compress(test_data);
        defer tracked_allocator.free(compressed);

        const decompressed = try ctx.decompress(compressed);
        defer tracked_allocator.free(decompressed);

        const iter_end = std.time.nanoTimestamp();
        try stats.record(iter_end - iter_start);
    }

    const end = std.time.nanoTimestamp();
    const total_time_ns = end - start;

    const total_bytes = config.message_count * config.message_size * 2; // compress + decompress
    const total_time_s = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0;

    return BenchmarkResult{
        .name = "Compression (LZ77)",
        .total_time_ns = total_time_ns,
        .messages_per_sec = @as(f64, @floatFromInt(config.message_count)) / total_time_s,
        .mbps = @as(f64, @floatFromInt(total_bytes)) / total_time_s / 1_000_000.0,
        .avg_latency_us = stats.avg() / 1000.0,
        .p50_latency_us = stats.percentile(0.50) / 1000.0,
        .p95_latency_us = stats.percentile(0.95) / 1000.0,
        .p99_latency_us = stats.percentile(0.99) / 1000.0,
        .memory_used = memory_tracker.total_requested_bytes,
    };
}

/// Benchmark: Message Serialization
pub fn benchmarkSerialization(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    std.debug.print("\n[Benchmark] Running serialization benchmark...\n", .{});

    var stats = LatencyStats.init(allocator);
    defer stats.deinit();

    // Generate test message
    const test_message = try allocator.alloc(u8, config.message_size);
    defer allocator.free(test_message);
    @memset(test_message, 0xAA);

    // Warmup
    for (0..config.warmup_iterations) |_| {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();
        try buf.appendSlice(test_message);
    }

    // Actual benchmark
    var memory_tracker = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = false }){};
    defer _ = memory_tracker.deinit();
    const tracked_allocator = memory_tracker.allocator();

    const start = std.time.nanoTimestamp();

    for (0..config.message_count) |_| {
        const iter_start = std.time.nanoTimestamp();

        var buf = std.ArrayList(u8).init(tracked_allocator);
        defer buf.deinit();
        try buf.appendSlice(test_message);

        const iter_end = std.time.nanoTimestamp();
        try stats.record(iter_end - iter_start);
    }

    const end = std.time.nanoTimestamp();
    const total_time_ns = end - start;

    const total_bytes = config.message_count * config.message_size;
    const total_time_s = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0;

    return BenchmarkResult{
        .name = "Message Serialization",
        .total_time_ns = total_time_ns,
        .messages_per_sec = @as(f64, @floatFromInt(config.message_count)) / total_time_s,
        .mbps = @as(f64, @floatFromInt(total_bytes)) / total_time_s / 1_000_000.0,
        .avg_latency_us = stats.avg() / 1000.0,
        .p50_latency_us = stats.percentile(0.50) / 1000.0,
        .p95_latency_us = stats.percentile(0.95) / 1000.0,
        .p99_latency_us = stats.percentile(0.99) / 1000.0,
        .memory_used = memory_tracker.total_requested_bytes,
    };
}

/// Benchmark: Memory Allocation
pub fn benchmarkMemoryAllocation(allocator: std.mem.Allocator, config: BenchmarkConfig) !BenchmarkResult {
    std.debug.print("\n[Benchmark] Running memory allocation benchmark...\n", .{});

    var stats = LatencyStats.init(allocator);
    defer stats.deinit();

    // Warmup
    for (0..config.warmup_iterations) |_| {
        const buf = try allocator.alloc(u8, config.message_size);
        allocator.free(buf);
    }

    // Actual benchmark
    var memory_tracker = std.heap.GeneralPurposeAllocator(.{ .enable_memory_limit = false }){};
    defer _ = memory_tracker.deinit();
    const tracked_allocator = memory_tracker.allocator();

    const start = std.time.nanoTimestamp();

    for (0..config.message_count) |_| {
        const iter_start = std.time.nanoTimestamp();

        const buf = try tracked_allocator.alloc(u8, config.message_size);
        tracked_allocator.free(buf);

        const iter_end = std.time.nanoTimestamp();
        try stats.record(iter_end - iter_start);
    }

    const end = std.time.nanoTimestamp();
    const total_time_ns = end - start;

    const total_time_s = @as(f64, @floatFromInt(total_time_ns)) / 1_000_000_000.0;

    return BenchmarkResult{
        .name = "Memory Allocation",
        .total_time_ns = total_time_ns,
        .messages_per_sec = @as(f64, @floatFromInt(config.message_count)) / total_time_s,
        .mbps = 0,
        .avg_latency_us = stats.avg() / 1000.0,
        .p50_latency_us = stats.percentile(0.50) / 1000.0,
        .p95_latency_us = stats.percentile(0.95) / 1000.0,
        .p99_latency_us = stats.percentile(0.99) / 1000.0,
        .memory_used = memory_tracker.total_requested_bytes,
    };
}

/// Benchmark: Compression Levels Comparison
pub fn benchmarkCompressionLevels(allocator: std.mem.Allocator) !void {
    std.debug.print("\n" ++ "#" ** 80 ++ "\n", .{});
    std.debug.print("# COMPRESSION LEVELS BENCHMARK\n", .{});
    std.debug.print("#" ** 80 ++ "\n\n", .{});

    const test_data = "The quick brown fox jumps over the lazy dog. " ** 100;

    const levels = [_]compression.Level{ .fast, .balanced, .best };

    for (levels) |level| {
        var ctx = try compression.Context.init(allocator, .{
            .algorithm = .lz77,
            .level = level,
            .min_size = 0,
        });
        defer ctx.deinit();

        const iterations = 1000;
        const start = std.time.nanoTimestamp();

        for (0..iterations) |_| {
            const compressed = try ctx.compress(test_data);
            defer allocator.free(compressed);
        }

        const end = std.time.nanoTimestamp();
        const total_time_us = @divFloor(end - start, 1000);
        const avg_time_us = @divFloor(total_time_us, iterations);

        const compressed_once = try ctx.compress(test_data);
        defer allocator.free(compressed_once);

        const ratio = @as(f64, @floatFromInt(compressed_once.len)) / @as(f64, @floatFromInt(test_data.len));

        std.debug.print("Level: {s:8} | ", .{@tagName(level)});
        std.debug.print("Time: {d:6} μs/msg | ", .{avg_time_us});
        std.debug.print("Ratio: {d:.3}:1 | ", .{ratio});
        std.debug.print("Size: {d} -> {d} bytes\n", .{ test_data.len, compressed_once.len });
    }

    std.debug.print("\n" ++ "#" ** 80 ++ "\n\n", .{});
}

/// Run all benchmarks
pub fn runAllBenchmarks(allocator: std.mem.Allocator) !void {
    std.debug.print("\n\n" ++ "=" ** 80 ++ "\n", .{});
    std.debug.print("zRPC PERFORMANCE BENCHMARKS\n", .{});
    std.debug.print("=" ** 80 ++ "\n", .{});

    const configs = [_]struct {
        name: []const u8,
        config: BenchmarkConfig,
    }{
        .{
            .name = "Small Messages (1KB)",
            .config = .{
                .message_count = 10000,
                .message_size = 1024,
            },
        },
        .{
            .name = "Medium Messages (64KB)",
            .config = .{
                .message_count = 1000,
                .message_size = 64 * 1024,
            },
        },
        .{
            .name = "Large Messages (1MB)",
            .config = .{
                .message_count = 100,
                .message_size = 1024 * 1024,
            },
        },
    };

    // Memory allocation benchmark
    {
        const result = try benchmarkMemoryAllocation(allocator, configs[0].config);
        result.print();
    }

    // Serialization benchmark
    {
        const result = try benchmarkSerialization(allocator, configs[0].config);
        result.print();
    }

    // Compression benchmarks
    for (configs) |cfg| {
        std.debug.print("\nConfiguration: {s}\n", .{cfg.name});
        std.debug.print("-" ** 80 ++ "\n", .{});

        const result = try benchmarkCompression(allocator, cfg.config);
        result.print();
    }

    // Compression levels comparison
    try benchmarkCompressionLevels(allocator);

    std.debug.print("\n" ++ "=" ** 80 ++ "\n", .{});
    std.debug.print("✓ ALL BENCHMARKS COMPLETED\n", .{});
    std.debug.print("=" ** 80 ++ "\n\n", .{});
}

// Tests that run benchmarks
test "Compression Benchmark - Small Messages" {
    const allocator = testing.allocator;

    const result = try benchmarkCompression(allocator, .{
        .message_count = 1000,
        .message_size = 1024,
        .compression_level = .balanced,
    });

    result.print();

    // Verify performance targets
    try testing.expect(result.avg_latency_us < 1000); // < 1ms average
    try testing.expect(result.p95_latency_us < 2000); // < 2ms p95
}

test "Compression Benchmark - Medium Messages" {
    const allocator = testing.allocator;

    const result = try benchmarkCompression(allocator, .{
        .message_count = 100,
        .message_size = 64 * 1024,
        .compression_level = .balanced,
    });

    result.print();

    try testing.expect(result.avg_latency_us < 5000); // < 5ms average
}

test "Serialization Benchmark" {
    const allocator = testing.allocator;

    const result = try benchmarkSerialization(allocator, .{
        .message_count = 10000,
        .message_size = 1024,
    });

    result.print();

    // Serialization should be very fast
    try testing.expect(result.avg_latency_us < 100); // < 100μs average
}

test "Memory Allocation Benchmark" {
    const allocator = testing.allocator;

    const result = try benchmarkMemoryAllocation(allocator, .{
        .message_count = 10000,
        .message_size = 1024,
    });

    result.print();

    // Memory allocation should be fast
    try testing.expect(result.avg_latency_us < 50); // < 50μs average
}

test "Compression Levels Comparison" {
    const allocator = testing.allocator;
    try benchmarkCompressionLevels(allocator);
}

test "Full Benchmark Suite" {
    const allocator = testing.allocator;
    try runAllBenchmarks(allocator);
}
