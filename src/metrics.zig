const std = @import("std");

/// Prometheus Metrics Collection for zRPC
/// Tracks request counts, latency, throughput, errors

/// Metric types
pub const MetricType = enum {
    counter,
    gauge,
    histogram,
    summary,
};

/// Counter metric (monotonically increasing)
pub const Counter = struct {
    name: []const u8,
    help: []const u8,
    labels: []const []const u8,
    value: std.atomic.Value(u64),

    pub fn init(name: []const u8, help: []const u8, labels: []const []const u8) Counter {
        return .{
            .name = name,
            .help = help,
            .labels = labels,
            .value = std.atomic.Value(u64).init(0),
        };
    }

    pub fn inc(self: *Counter) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn add(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *Counter) u64 {
        return self.value.load(.monotonic);
    }
};

/// Gauge metric (can go up or down)
pub const Gauge = struct {
    name: []const u8,
    help: []const u8,
    labels: []const []const u8,
    value: std.atomic.Value(i64),

    pub fn init(name: []const u8, help: []const u8, labels: []const []const u8) Gauge {
        return .{
            .name = name,
            .help = help,
            .labels = labels,
            .value = std.atomic.Value(i64).init(0),
        };
    }

    pub fn set(self: *Gauge, val: i64) void {
        self.value.store(val, .monotonic);
    }

    pub fn inc(self: *Gauge) void {
        _ = self.value.fetchAdd(1, .monotonic);
    }

    pub fn dec(self: *Gauge) void {
        _ = self.value.fetchSub(1, .monotonic);
    }

    pub fn add(self: *Gauge, delta: i64) void {
        _ = self.value.fetchAdd(delta, .monotonic);
    }

    pub fn get(self: *Gauge) i64 {
        return self.value.load(.monotonic);
    }
};

/// Histogram for latency tracking
pub const Histogram = struct {
    name: []const u8,
    help: []const u8,
    labels: []const []const u8,
    buckets: []const f64,
    counts: []std.atomic.Value(u64),
    sum: std.atomic.Value(u64),
    count: std.atomic.Value(u64),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, help: []const u8, labels: []const []const u8, buckets: []const f64) !Histogram {
        const counts = try allocator.alloc(std.atomic.Value(u64), buckets.len);
        for (counts) |*c| {
            c.* = std.atomic.Value(u64).init(0);
        }

        return .{
            .name = name,
            .help = help,
            .labels = labels,
            .buckets = buckets,
            .counts = counts,
            .sum = std.atomic.Value(u64).init(0),
            .count = std.atomic.Value(u64).init(0),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Histogram) void {
        self.allocator.free(self.counts);
    }

    pub fn observe(self: *Histogram, value: f64) void {
        _ = self.sum.fetchAdd(@intFromFloat(value), .monotonic);
        _ = self.count.fetchAdd(1, .monotonic);

        for (self.buckets, 0..) |bucket, i| {
            if (value <= bucket) {
                _ = self.counts[i].fetchAdd(1, .monotonic);
            }
        }
    }

    pub fn getSum(self: *Histogram) u64 {
        return self.sum.load(.monotonic);
    }

    pub fn getCount(self: *Histogram) u64 {
        return self.count.load(.monotonic);
    }

    pub fn getBucketCount(self: *Histogram, bucket_idx: usize) u64 {
        if (bucket_idx >= self.counts.len) return 0;
        return self.counts[bucket_idx].load(.monotonic);
    }
};

/// RPC Metrics Registry
pub const MetricsRegistry = struct {
    allocator: std.mem.Allocator,

    // RPC metrics
    rpc_requests_total: Counter,
    rpc_requests_success: Counter,
    rpc_requests_failed: Counter,
    rpc_duration_microseconds: Histogram,

    // Transport metrics
    transport_connections_active: Gauge,
    transport_connections_total: Counter,
    transport_bytes_sent: Counter,
    transport_bytes_received: Counter,

    // Stream metrics
    streams_active: Gauge,
    streams_total: Counter,

    // Compression metrics
    compression_bytes_before: Counter,
    compression_bytes_after: Counter,

    pub fn init(allocator: std.mem.Allocator) !MetricsRegistry {
        // Latency buckets: 10μs, 50μs, 100μs, 500μs, 1ms, 5ms, 10ms, 50ms, 100ms, 500ms, 1s
        const latency_buckets = [_]f64{ 10, 50, 100, 500, 1000, 5000, 10000, 50000, 100000, 500000, 1000000 };
        const buckets = try allocator.dupe(f64, &latency_buckets);

        return .{
            .allocator = allocator,
            .rpc_requests_total = Counter.init("zrpc_requests_total", "Total number of RPC requests", &[_][]const u8{}),
            .rpc_requests_success = Counter.init("zrpc_requests_success_total", "Total number of successful RPC requests", &[_][]const u8{}),
            .rpc_requests_failed = Counter.init("zrpc_requests_failed_total", "Total number of failed RPC requests", &[_][]const u8{}),
            .rpc_duration_microseconds = try Histogram.init(allocator, "zrpc_duration_microseconds", "RPC request duration in microseconds", &[_][]const u8{}, buckets),
            .transport_connections_active = Gauge.init("zrpc_transport_connections_active", "Number of active transport connections", &[_][]const u8{}),
            .transport_connections_total = Counter.init("zrpc_transport_connections_total", "Total number of transport connections", &[_][]const u8{}),
            .transport_bytes_sent = Counter.init("zrpc_transport_bytes_sent_total", "Total bytes sent over transport", &[_][]const u8{}),
            .transport_bytes_received = Counter.init("zrpc_transport_bytes_received_total", "Total bytes received over transport", &[_][]const u8{}),
            .streams_active = Gauge.init("zrpc_streams_active", "Number of active streams", &[_][]const u8{}),
            .streams_total = Counter.init("zrpc_streams_total", "Total number of streams created", &[_][]const u8{}),
            .compression_bytes_before = Counter.init("zrpc_compression_bytes_before_total", "Total bytes before compression", &[_][]const u8{}),
            .compression_bytes_after = Counter.init("zrpc_compression_bytes_after_total", "Total bytes after compression", &[_][]const u8{}),
        };
    }

    pub fn deinit(self: *MetricsRegistry) void {
        self.rpc_duration_microseconds.deinit();
        self.allocator.free(self.rpc_duration_microseconds.buckets);
    }

    /// Record RPC request start
    pub fn recordRpcStart(self: *MetricsRegistry) void {
        self.rpc_requests_total.inc();
    }

    /// Record RPC request success
    pub fn recordRpcSuccess(self: *MetricsRegistry, duration_us: u64) void {
        self.rpc_requests_success.inc();
        self.rpc_duration_microseconds.observe(@floatFromInt(duration_us));
    }

    /// Record RPC request failure
    pub fn recordRpcFailure(self: *MetricsRegistry, duration_us: u64) void {
        self.rpc_requests_failed.inc();
        self.rpc_duration_microseconds.observe(@floatFromInt(duration_us));
    }

    /// Record transport connection
    pub fn recordTransportConnect(self: *MetricsRegistry) void {
        self.transport_connections_total.inc();
        self.transport_connections_active.inc();
    }

    /// Record transport disconnection
    pub fn recordTransportDisconnect(self: *MetricsRegistry) void {
        self.transport_connections_active.dec();
    }

    /// Record bytes sent/received
    pub fn recordBytesTransferred(self: *MetricsRegistry, sent: usize, received: usize) void {
        self.transport_bytes_sent.add(@intCast(sent));
        self.transport_bytes_received.add(@intCast(received));
    }

    /// Record stream open
    pub fn recordStreamOpen(self: *MetricsRegistry) void {
        self.streams_total.inc();
        self.streams_active.inc();
    }

    /// Record stream close
    pub fn recordStreamClose(self: *MetricsRegistry) void {
        self.streams_active.dec();
    }

    /// Record compression
    pub fn recordCompression(self: *MetricsRegistry, before: usize, after: usize) void {
        self.compression_bytes_before.add(@intCast(before));
        self.compression_bytes_after.add(@intCast(after));
    }

    /// Get current statistics
    pub fn getStats(self: *MetricsRegistry) Stats {
        const total_requests = self.rpc_requests_total.get();
        const success_requests = self.rpc_requests_success.get();
        const failed_requests = self.rpc_requests_failed.get();

        const error_rate = if (total_requests > 0)
            @as(f64, @floatFromInt(failed_requests)) / @as(f64, @floatFromInt(total_requests))
        else
            0.0;

        const avg_latency_us = if (self.rpc_duration_microseconds.getCount() > 0)
            @as(f64, @floatFromInt(self.rpc_duration_microseconds.getSum())) / @as(f64, @floatFromInt(self.rpc_duration_microseconds.getCount()))
        else
            0.0;

        const compression_before = self.compression_bytes_before.get();
        const compression_after = self.compression_bytes_after.get();
        const compression_ratio = if (compression_before > 0)
            @as(f64, @floatFromInt(compression_after)) / @as(f64, @floatFromInt(compression_before))
        else
            1.0;

        return .{
            .total_requests = total_requests,
            .success_requests = success_requests,
            .failed_requests = failed_requests,
            .error_rate = error_rate,
            .avg_latency_us = avg_latency_us,
            .active_connections = @intCast(self.transport_connections_active.get()),
            .total_connections = self.transport_connections_total.get(),
            .active_streams = @intCast(self.streams_active.get()),
            .total_streams = self.streams_total.get(),
            .bytes_sent = self.transport_bytes_sent.get(),
            .bytes_received = self.transport_bytes_received.get(),
            .compression_ratio = compression_ratio,
        };
    }

    /// Export Prometheus format
    pub fn exportPrometheus(self: *MetricsRegistry, writer: anytype) !void {
        // Counter metrics
        try writer.print("# HELP {s} {s}\n", .{ self.rpc_requests_total.name, self.rpc_requests_total.help });
        try writer.print("# TYPE {s} counter\n", .{self.rpc_requests_total.name});
        try writer.print("{s} {d}\n", .{ self.rpc_requests_total.name, self.rpc_requests_total.get() });

        try writer.print("# HELP {s} {s}\n", .{ self.rpc_requests_success.name, self.rpc_requests_success.help });
        try writer.print("# TYPE {s} counter\n", .{self.rpc_requests_success.name});
        try writer.print("{s} {d}\n", .{ self.rpc_requests_success.name, self.rpc_requests_success.get() });

        try writer.print("# HELP {s} {s}\n", .{ self.rpc_requests_failed.name, self.rpc_requests_failed.help });
        try writer.print("# TYPE {s} counter\n", .{self.rpc_requests_failed.name});
        try writer.print("{s} {d}\n", .{ self.rpc_requests_failed.name, self.rpc_requests_failed.get() });

        // Histogram
        try writer.print("# HELP {s} {s}\n", .{ self.rpc_duration_microseconds.name, self.rpc_duration_microseconds.help });
        try writer.print("# TYPE {s} histogram\n", .{self.rpc_duration_microseconds.name});

        for (self.rpc_duration_microseconds.buckets, 0..) |bucket, i| {
            const count = self.rpc_duration_microseconds.getBucketCount(i);
            try writer.print("{s}_bucket{{le=\"{d}\"}} {d}\n", .{ self.rpc_duration_microseconds.name, bucket, count });
        }
        try writer.print("{s}_bucket{{le=\"+Inf\"}} {d}\n", .{ self.rpc_duration_microseconds.name, self.rpc_duration_microseconds.getCount() });
        try writer.print("{s}_sum {d}\n", .{ self.rpc_duration_microseconds.name, self.rpc_duration_microseconds.getSum() });
        try writer.print("{s}_count {d}\n", .{ self.rpc_duration_microseconds.name, self.rpc_duration_microseconds.getCount() });

        // Gauge metrics
        try writer.print("# HELP {s} {s}\n", .{ self.transport_connections_active.name, self.transport_connections_active.help });
        try writer.print("# TYPE {s} gauge\n", .{self.transport_connections_active.name});
        try writer.print("{s} {d}\n", .{ self.transport_connections_active.name, self.transport_connections_active.get() });

        try writer.print("# HELP {s} {s}\n", .{ self.streams_active.name, self.streams_active.help });
        try writer.print("# TYPE {s} gauge\n", .{self.streams_active.name});
        try writer.print("{s} {d}\n", .{ self.streams_active.name, self.streams_active.get() });

        // More counters
        try writer.print("# HELP {s} {s}\n", .{ self.transport_bytes_sent.name, self.transport_bytes_sent.help });
        try writer.print("# TYPE {s} counter\n", .{self.transport_bytes_sent.name});
        try writer.print("{s} {d}\n", .{ self.transport_bytes_sent.name, self.transport_bytes_sent.get() });

        try writer.print("# HELP {s} {s}\n", .{ self.transport_bytes_received.name, self.transport_bytes_received.help });
        try writer.print("# TYPE {s} counter\n", .{self.transport_bytes_received.name});
        try writer.print("{s} {d}\n", .{ self.transport_bytes_received.name, self.transport_bytes_received.get() });
    }
};

/// Statistics summary
pub const Stats = struct {
    total_requests: u64,
    success_requests: u64,
    failed_requests: u64,
    error_rate: f64,
    avg_latency_us: f64,
    active_connections: u32,
    total_connections: u64,
    active_streams: u32,
    total_streams: u64,
    bytes_sent: u64,
    bytes_received: u64,
    compression_ratio: f64,

    pub fn print(self: Stats) void {
        std.debug.print("\nzRPC Metrics:\n", .{});
        std.debug.print("  Requests: {} total ({} success, {} failed)\n", .{ self.total_requests, self.success_requests, self.failed_requests });
        std.debug.print("  Error rate: {d:.2}%\n", .{self.error_rate * 100.0});
        std.debug.print("  Avg latency: {d:.2} μs\n", .{self.avg_latency_us});
        std.debug.print("  Connections: {} active ({} total)\n", .{ self.active_connections, self.total_connections });
        std.debug.print("  Streams: {} active ({} total)\n", .{ self.active_streams, self.total_streams });
        std.debug.print("  Traffic: {} sent, {} received\n", .{ self.bytes_sent, self.bytes_received });
        std.debug.print("  Compression: {d:.3}:1 ratio\n", .{self.compression_ratio});
    }
};

// Tests
test "counter metric" {
    const testing = std.testing;

    var counter = Counter.init("test_counter", "Test counter", &[_][]const u8{});

    counter.inc();
    counter.inc();
    counter.add(5);

    try testing.expectEqual(@as(u64, 7), counter.get());
}

test "gauge metric" {
    const testing = std.testing;

    var gauge = Gauge.init("test_gauge", "Test gauge", &[_][]const u8{});

    gauge.set(10);
    try testing.expectEqual(@as(i64, 10), gauge.get());

    gauge.inc();
    try testing.expectEqual(@as(i64, 11), gauge.get());

    gauge.dec();
    try testing.expectEqual(@as(i64, 10), gauge.get());
}

test "histogram metric" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const buckets = [_]f64{ 10, 50, 100, 500, 1000 };
    var histogram = try Histogram.init(allocator, "test_histogram", "Test histogram", &[_][]const u8{}, &buckets);
    defer histogram.deinit();

    histogram.observe(25);
    histogram.observe(75);
    histogram.observe(150);

    try testing.expectEqual(@as(u64, 3), histogram.getCount());
}

test "metrics registry" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    registry.recordRpcStart();
    registry.recordRpcSuccess(100);

    registry.recordTransportConnect();
    registry.recordStreamOpen();

    const stats = registry.getStats();
    try testing.expectEqual(@as(u64, 1), stats.total_requests);
    try testing.expectEqual(@as(u64, 1), stats.success_requests);
}

test "prometheus export" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    registry.recordRpcStart();
    registry.recordRpcSuccess(100);

    var output = std.ArrayList(u8).init(allocator);
    defer output.deinit();

    try registry.exportPrometheus(output.writer());

    try testing.expect(output.items.len > 0);
    try testing.expect(std.mem.indexOf(u8, output.items, "zrpc_requests_total") != null);
}
