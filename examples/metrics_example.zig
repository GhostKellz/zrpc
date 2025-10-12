const std = @import("std");
const zrpc = @import("zrpc");
const metrics = @import("metrics");
const metrics_server = @import("metrics_server");

const MetricsRegistry = metrics.MetricsRegistry;
const MetricsServer = metrics_server.MetricsServer;

/// Example demonstrating zRPC metrics collection and Prometheus integration
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Initialize metrics registry
    var registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    std.log.info("=== zRPC Metrics Example ===", .{});

    // Start metrics HTTP server on port 9090
    var server = try MetricsServer.init(allocator, &registry, 9090);
    defer server.deinit();

    try server.start();
    std.log.info("Metrics server started on http://127.0.0.1:9090/metrics", .{});
    std.log.info("Visit http://127.0.0.1:9090/ for index", .{});

    // Simulate some RPC activity
    std.log.info("\nSimulating RPC activity...", .{});

    // Simulate 100 successful requests
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        registry.recordRpcStart();

        // Simulate request processing (random latency)
        const latency = 50 + (std.crypto.random.int(u32) % 200);
        std.time.sleep(latency * std.time.ns_per_us);

        registry.recordRpcSuccess(latency);

        // Occasionally simulate a connection
        if (i % 10 == 0) {
            registry.recordTransportConnect();
            registry.recordStreamOpen();
        }

        // Simulate some failures
        if (i % 25 == 0) {
            registry.recordRpcStart();
            registry.recordRpcFailure(latency);
        }

        // Simulate data transfer
        const bytes_sent = 1024 + (std.crypto.random.int(u32) % 4096);
        const bytes_received = 512 + (std.crypto.random.int(u32) % 2048);
        registry.recordBytesTransferred(bytes_sent, bytes_received);

        // Simulate compression
        if (i % 5 == 0) {
            const before = 10000;
            const after = 3500; // ~35% compression
            registry.recordCompression(before, after);
        }
    }

    // Close some streams and connections
    i = 0;
    while (i < 10) : (i += 1) {
        registry.recordStreamClose();
    }

    i = 0;
    while (i < 10) : (i += 1) {
        registry.recordTransportDisconnect();
    }

    std.log.info("Activity simulation complete", .{});

    // Print statistics
    const stats = registry.getStats();
    std.log.info("\n=== Metrics Summary ===", .{});
    stats.print();

    // Export Prometheus format
    std.log.info("\n=== Prometheus Format (sample) ===", .{});
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    try registry.exportPrometheus(buffer.writer());

    // Print first 500 chars of Prometheus output
    const preview_len = @min(500, buffer.items.len);
    std.log.info("{s}...", .{buffer.items[0..preview_len]});

    // Keep server running for manual testing
    std.log.info("\n=== Server Running ===", .{});
    std.log.info("Metrics endpoint: http://127.0.0.1:9090/metrics", .{});
    std.log.info("Health endpoint: http://127.0.0.1:9090/health", .{});
    std.log.info("Press Ctrl+C to stop...", .{});

    // Run for 60 seconds
    var seconds: usize = 0;
    while (seconds < 60) : (seconds += 1) {
        std.time.sleep(std.time.ns_per_s);

        // Simulate ongoing activity
        registry.recordRpcStart();
        registry.recordRpcSuccess(100);
    }
}
