const std = @import("std");
const Error = @import("error.zig").Error;
const transport = @import("transport.zig");

/// Health check status
pub const HealthStatus = enum {
    unknown,
    serving,
    not_serving,
    service_unknown,

    pub fn toString(self: HealthStatus) []const u8 {
        return switch (self) {
            .unknown => "UNKNOWN",
            .serving => "SERVING",
            .not_serving => "NOT_SERVING",
            .service_unknown => "SERVICE_UNKNOWN",
        };
    }
};

/// HTTP/2 PING frame for keepalive
pub const PingFrame = struct {
    opaque_data: [8]u8,

    pub fn init() PingFrame {
        var ping = PingFrame{
            .opaque_data = undefined,
        };
        std.crypto.random.bytes(&ping.opaque_data);
        return ping;
    }

    pub fn initWithData(data: [8]u8) PingFrame {
        return .{ .opaque_data = data };
    }

    pub fn toFrame(self: *const PingFrame) transport.Frame {
        return .{
            .stream_id = 0, // PING frames always use stream 0
            .frame_type = .ping,
            .flags = 0,
            .data = &self.opaque_data,
        };
    }

    pub fn toAckFrame(self: *const PingFrame) transport.Frame {
        return .{
            .stream_id = 0,
            .frame_type = .ping,
            .flags = 0x01, // ACK flag
            .data = &self.opaque_data,
        };
    }

    pub fn matches(self: *const PingFrame, other: *const PingFrame) bool {
        return std.mem.eql(u8, &self.opaque_data, &other.opaque_data);
    }
};

/// Health checker for connection monitoring
pub const HealthChecker = struct {
    allocator: std.mem.Allocator,
    ping_interval: u64, // Nanoseconds
    ping_timeout: u64, // Nanoseconds
    last_ping_time: i64,
    pending_pings: std.ArrayList(PendingPing),
    connection_healthy: bool,

    const PendingPing = struct {
        ping: PingFrame,
        sent_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator, ping_interval_s: u64, ping_timeout_s: u64) HealthChecker {
        return .{
            .allocator = allocator,
            .ping_interval = ping_interval_s * std.time.ns_per_s,
            .ping_timeout = ping_timeout_s * std.time.ns_per_s,
            .last_ping_time = 0,
            .pending_pings = std.ArrayList(PendingPing).init(allocator),
            .connection_healthy = true,
        };
    }

    pub fn deinit(self: *HealthChecker) void {
        self.pending_pings.deinit();
    }

    /// Check if it's time to send a ping
    pub fn shouldSendPing(self: *const HealthChecker) bool {
        const now = std.time.nanoTimestamp();
        return (now - self.last_ping_time) >= @as(i64, @intCast(self.ping_interval));
    }

    /// Create and register a new ping
    pub fn createPing(self: *HealthChecker) !PingFrame {
        const ping = PingFrame.init();
        const now = std.time.nanoTimestamp();

        try self.pending_pings.append(.{
            .ping = ping,
            .sent_at = now,
        });

        self.last_ping_time = now;
        return ping;
    }

    /// Handle received PING ACK
    pub fn receivePingAck(self: *HealthChecker, ack_data: [8]u8) bool {
        const now = std.time.nanoTimestamp();
        const ack_ping = PingFrame.initWithData(ack_data);

        var i: usize = 0;
        while (i < self.pending_pings.items.len) {
            const pending = &self.pending_pings.items[i];

            if (pending.ping.matches(&ack_ping)) {
                const rtt = now - pending.sent_at;
                _ = self.pending_pings.swapRemove(i);

                // Connection is healthy if we got a response
                self.connection_healthy = true;

                // Log RTT for monitoring
                std.log.debug("PING RTT: {d}ms", .{@divFloor(rtt, std.time.ns_per_ms)});
                return true;
            }

            i += 1;
        }

        return false;
    }

    /// Check for timed-out pings
    pub fn checkTimeouts(self: *HealthChecker) Error!void {
        const now = std.time.nanoTimestamp();
        var i: usize = 0;

        while (i < self.pending_pings.items.len) {
            const pending = &self.pending_pings.items[i];
            const elapsed = now - pending.sent_at;

            if (elapsed >= @as(i64, @intCast(self.ping_timeout))) {
                // Ping timed out - connection unhealthy
                self.connection_healthy = false;
                _ = self.pending_pings.swapRemove(i);

                std.log.warn("PING timeout detected - connection unhealthy", .{});
                return Error.Unavailable;
            }

            i += 1;
        }
    }

    /// Get connection health status
    pub fn isHealthy(self: *const HealthChecker) bool {
        return self.connection_healthy;
    }

    /// Reset health status (e.g., after reconnection)
    pub fn reset(self: *HealthChecker) void {
        self.pending_pings.clearRetainingCapacity();
        self.connection_healthy = true;
        self.last_ping_time = 0;
    }
};

/// Service health state tracker
pub const ServiceHealth = struct {
    allocator: std.mem.Allocator,
    services: std.StringHashMap(HealthStatus),
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) ServiceHealth {
        return .{
            .allocator = allocator,
            .services = std.StringHashMap(HealthStatus).init(allocator),
            .mutex = .{},
        };
    }

    pub fn deinit(self: *ServiceHealth) void {
        var it = self.services.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.services.deinit();
    }

    /// Set service health status
    pub fn setStatus(self: *ServiceHealth, service_name: []const u8, status: HealthStatus) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.services.get(service_name)) |_| {
            try self.services.put(service_name, status);
        } else {
            const name_copy = try self.allocator.dupe(u8, service_name);
            try self.services.put(name_copy, status);
        }
    }

    /// Get service health status
    pub fn getStatus(self: *ServiceHealth, service_name: []const u8) HealthStatus {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.services.get(service_name) orelse .service_unknown;
    }

    /// Mark service as serving
    pub fn markServing(self: *ServiceHealth, service_name: []const u8) !void {
        try self.setStatus(service_name, .serving);
    }

    /// Mark service as not serving
    pub fn markNotServing(self: *ServiceHealth, service_name: []const u8) !void {
        try self.setStatus(service_name, .not_serving);
    }

    /// Remove service
    pub fn removeService(self: *ServiceHealth, service_name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.services.fetchRemove(service_name)) |kv| {
            self.allocator.free(kv.key);
        }
    }
};

/// Keepalive configuration
pub const KeepaliveConfig = struct {
    /// Time between keepalive pings (default: 2 hours)
    ping_interval_s: u64 = 7200,

    /// Timeout for ping response (default: 20s)
    ping_timeout_s: u64 = 20,

    /// Allow pings when no streams are active (default: false)
    permit_without_stream: bool = false,

    /// Maximum time for idle connections (default: infinity)
    max_idle_time_s: ?u64 = null,

    pub fn default() KeepaliveConfig {
        return .{};
    }

    pub fn aggressive() KeepaliveConfig {
        return .{
            .ping_interval_s = 10,
            .ping_timeout_s = 5,
            .permit_without_stream = true,
        };
    }

    pub fn relaxed() KeepaliveConfig {
        return .{
            .ping_interval_s = 3600,
            .ping_timeout_s = 30,
            .permit_without_stream = false,
        };
    }
};

// Tests
test "ping frame creation" {
    const ping = PingFrame.init();
    const frame = ping.toFrame();

    try std.testing.expectEqual(@as(u32, 0), frame.stream_id);
    try std.testing.expectEqual(transport.Frame.FrameType.ping, frame.frame_type);
    try std.testing.expectEqual(@as(usize, 8), frame.data.len);
}

test "ping frame ack" {
    const ping = PingFrame.init();
    const ack_frame = ping.toAckFrame();

    try std.testing.expectEqual(@as(u8, 0x01), ack_frame.flags);
    try std.testing.expect(ping.matches(&PingFrame.initWithData(ping.opaque_data)));
}

test "health checker basic flow" {
    const allocator = std.testing.allocator;
    var checker = HealthChecker.init(allocator, 10, 5);
    defer checker.deinit();

    try std.testing.expect(checker.isHealthy());

    // Should not send ping immediately
    try std.testing.expect(!checker.shouldSendPing());

    // Simulate time passing
    checker.last_ping_time = std.time.nanoTimestamp() - (11 * std.time.ns_per_s);
    try std.testing.expect(checker.shouldSendPing());

    // Create ping
    const ping = try checker.createPing();
    try std.testing.expectEqual(@as(usize, 1), checker.pending_pings.items.len);

    // Receive ACK
    const matched = checker.receivePingAck(ping.opaque_data);
    try std.testing.expect(matched);
    try std.testing.expectEqual(@as(usize, 0), checker.pending_pings.items.len);
    try std.testing.expect(checker.isHealthy());
}

test "health checker timeout" {
    const allocator = std.testing.allocator;
    var checker = HealthChecker.init(allocator, 10, 1);
    defer checker.deinit();

    // Create ping with past timestamp
    const ping = PingFrame.init();
    try checker.pending_pings.append(.{
        .ping = ping,
        .sent_at = std.time.nanoTimestamp() - (2 * std.time.ns_per_s),
    });

    // Check timeouts should mark unhealthy
    const result = checker.checkTimeouts();
    try std.testing.expectError(Error.Unavailable, result);
    try std.testing.expect(!checker.isHealthy());
}

test "service health tracking" {
    const allocator = std.testing.allocator;
    var health = ServiceHealth.init(allocator);
    defer health.deinit();

    try health.markServing("TestService");
    try std.testing.expectEqual(HealthStatus.serving, health.getStatus("TestService"));

    try health.markNotServing("TestService");
    try std.testing.expectEqual(HealthStatus.not_serving, health.getStatus("TestService"));

    try std.testing.expectEqual(HealthStatus.service_unknown, health.getStatus("UnknownService"));
}

test "keepalive config presets" {
    const default_cfg = KeepaliveConfig.default();
    try std.testing.expectEqual(@as(u64, 7200), default_cfg.ping_interval_s);

    const aggressive_cfg = KeepaliveConfig.aggressive();
    try std.testing.expectEqual(@as(u64, 10), aggressive_cfg.ping_interval_s);

    const relaxed_cfg = KeepaliveConfig.relaxed();
    try std.testing.expectEqual(@as(u64, 3600), relaxed_cfg.ping_interval_s);
}
