const std = @import("std");
const metrics = @import("metrics.zig");
const MetricsRegistry = metrics.MetricsRegistry;

/// HTTP server for Prometheus metrics endpoint
/// Provides a /metrics endpoint that exports metrics in Prometheus text format
pub const MetricsServer = struct {
    allocator: std.mem.Allocator,
    registry: *MetricsRegistry,
    bind_address: std.net.Address,
    server: ?std.net.Server,
    is_running: std.atomic.Value(bool),
    thread: ?std.Thread,

    pub fn init(allocator: std.mem.Allocator, registry: *MetricsRegistry, port: u16) !MetricsServer {
        const address = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, port);

        return MetricsServer{
            .allocator = allocator,
            .registry = registry,
            .bind_address = address,
            .server = null,
            .is_running = std.atomic.Value(bool).init(false),
            .thread = null,
        };
    }

    pub fn deinit(self: *MetricsServer) void {
        self.stop();
    }

    /// Start the metrics server in a background thread
    pub fn start(self: *MetricsServer) !void {
        if (self.is_running.load(.acquire)) {
            return error.AlreadyRunning;
        }

        // Create TCP server
        const server = try self.bind_address.listen(.{
            .reuse_address = true,
        });
        self.server = server;

        std.log.info("Metrics server listening on http://{any}/metrics", .{self.bind_address});

        // Start background thread
        self.is_running.store(true, .release);
        self.thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    /// Stop the metrics server
    pub fn stop(self: *MetricsServer) void {
        if (!self.is_running.load(.acquire)) {
            return;
        }

        self.is_running.store(false, .release);

        if (self.server) |*server| {
            server.deinit();
            self.server = null;
        }

        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }

        std.log.info("Metrics server stopped", .{});
    }

    fn serverLoop(self: *MetricsServer) void {
        while (self.is_running.load(.acquire)) {
            var server = self.server orelse return;

            // Accept connection
            const connection = server.accept() catch |err| {
                if (self.is_running.load(.acquire)) {
                    std.log.err("Metrics server accept error: {}", .{err});
                }
                continue;
            };
            defer connection.stream.close();

            // Handle HTTP request
            self.handleRequest(connection.stream) catch |err| {
                std.log.err("Metrics server request error: {}", .{err});
            };
        }
    }

    fn handleRequest(self: *MetricsServer, stream: std.net.Stream) !void {
        var buffer: [4096]u8 = undefined;

        // Read HTTP request
        const bytes_read = try stream.read(&buffer);
        if (bytes_read == 0) return;

        const request = buffer[0..bytes_read];

        // Parse request line
        var line_iter = std.mem.splitSequence(u8, request, "\r\n");
        const request_line = line_iter.next() orelse return error.InvalidRequest;

        // Check if it's a GET request to /metrics
        if (std.mem.startsWith(u8, request_line, "GET /metrics")) {
            try self.serveMetrics(stream);
        } else if (std.mem.startsWith(u8, request_line, "GET /health")) {
            try self.serveHealth(stream);
        } else if (std.mem.startsWith(u8, request_line, "GET /")) {
            try self.serveIndex(stream);
        } else {
            try self.serve404(stream);
        }
    }

    fn serveMetrics(self: *MetricsServer, stream: std.net.Stream) !void {
        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();

        // Export metrics in Prometheus format
        try self.registry.exportPrometheus(response.writer());

        // Build HTTP response
        var http_response = std.ArrayList(u8).init(self.allocator);
        defer http_response.deinit();

        try http_response.writer().print(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/plain; version=0.0.4\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n",
            .{response.items.len},
        );
        try http_response.appendSlice(response.items);

        _ = try stream.write(http_response.items);
    }

    fn serveHealth(self: *MetricsServer, stream: std.net.Stream) !void {
        _ = self;
        const response =
            "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: application/json\r\n" ++
            "Content-Length: 15\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "{\"status\":\"ok\"}";

        _ = try stream.write(response);
    }

    fn serveIndex(self: *MetricsServer, stream: std.net.Stream) !void {
        const html =
            \\<!DOCTYPE html>
            \\<html>
            \\<head><title>zRPC Metrics</title></head>
            \\<body>
            \\<h1>zRPC Metrics Server</h1>
            \\<ul>
            \\<li><a href="/metrics">/metrics</a> - Prometheus metrics</li>
            \\<li><a href="/health">/health</a> - Health check</li>
            \\</ul>
            \\</body>
            \\</html>
        ;

        var response = std.ArrayList(u8).init(self.allocator);
        defer response.deinit();

        try response.writer().print(
            "HTTP/1.1 200 OK\r\n" ++
                "Content-Type: text/html\r\n" ++
                "Content-Length: {d}\r\n" ++
                "Connection: close\r\n" ++
                "\r\n" ++
                "{s}",
            .{ html.len, html },
        );

        _ = try stream.write(response.items);
    }

    fn serve404(self: *MetricsServer, stream: std.net.Stream) !void {
        _ = self;
        const response =
            "HTTP/1.1 404 Not Found\r\n" ++
            "Content-Type: text/plain\r\n" ++
            "Content-Length: 9\r\n" ++
            "Connection: close\r\n" ++
            "\r\n" ++
            "Not Found";

        _ = try stream.write(response);
    }
};

// Tests
test "metrics server initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    var server = try MetricsServer.init(allocator, &registry, 9090);
    defer server.deinit();

    try testing.expect(!server.is_running.load(.acquire));
}

test "metrics server start and stop" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    var server = try MetricsServer.init(allocator, &registry, 9091);
    defer server.deinit();

    try server.start();
    try testing.expect(server.is_running.load(.acquire));

    // Give it a moment to start
    std.Thread.sleep(10 * std.time.ns_per_ms);

    server.stop();
    try testing.expect(!server.is_running.load(.acquire));
}

test "metrics endpoint" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var registry = try MetricsRegistry.init(allocator);
    defer registry.deinit();

    // Record some metrics
    registry.recordRpcStart();
    registry.recordRpcSuccess(100);
    registry.recordTransportConnect();

    var server = try MetricsServer.init(allocator, &registry, 9092);
    defer server.deinit();

    try server.start();
    defer server.stop();

    // Give server time to start
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Connect and fetch metrics
    const address = std.net.Address.initIp4([_]u8{ 127, 0, 0, 1 }, 9092);
    const conn = try std.net.tcpConnectToAddress(address);
    defer conn.close();

    const request = "GET /metrics HTTP/1.1\r\nHost: localhost\r\n\r\n";
    _ = try conn.write(request);

    var response_buf: [8192]u8 = undefined;
    const bytes_read = try conn.read(&response_buf);
    const response = response_buf[0..bytes_read];

    // Verify response contains expected metrics
    try testing.expect(std.mem.indexOf(u8, response, "HTTP/1.1 200 OK") != null);
    try testing.expect(std.mem.indexOf(u8, response, "zrpc_requests_total") != null);
    try testing.expect(std.mem.indexOf(u8, response, "zrpc_requests_success_total") != null);
}
