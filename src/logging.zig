const std = @import("std");
const zlog = @import("zlog");

/// zRPC Logging Integration
/// Provides structured logging for all transports and RPC operations

/// Log context for request tracking
pub const RequestContext = struct {
    request_id: []const u8,
    method: []const u8,
    transport: []const u8,
    start_time: i64,

    pub fn fields(self: RequestContext, allocator: std.mem.Allocator) ![]zlog.Field {
        var field_list = std.ArrayList(zlog.Field).init(allocator);
        errdefer field_list.deinit();

        try field_list.append(.{ .key = "request_id", .value = .{ .string = self.request_id } });
        try field_list.append(.{ .key = "method", .value = .{ .string = self.method } });
        try field_list.append(.{ .key = "transport", .value = .{ .string = self.transport } });
        try field_list.append(.{ .key = "start_time", .value = .{ .int = self.start_time } });

        return field_list.toOwnedSlice();
    }
};

/// RPC Logger wrapper
pub const RpcLogger = struct {
    logger: *zlog.Logger,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: zlog.LoggerConfig) !RpcLogger {
        const logger_ptr = try allocator.create(zlog.Logger);
        logger_ptr.* = try zlog.Logger.init(allocator, config);

        return RpcLogger{
            .logger = logger_ptr,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RpcLogger) void {
        self.logger.deinit();
        self.allocator.destroy(self.logger);
    }

    /// Log RPC call start
    pub fn logRpcStart(self: *RpcLogger, ctx: RequestContext) void {
        const fields = ctx.fields(self.allocator) catch return;
        defer self.allocator.free(fields);

        self.logger.logWithFields(.info, "RPC call started", fields);
    }

    /// Log RPC call success
    pub fn logRpcSuccess(self: *RpcLogger, ctx: RequestContext, duration_us: i64) void {
        var field_list = std.ArrayList(zlog.Field).init(self.allocator);
        defer field_list.deinit();

        const base_fields = ctx.fields(self.allocator) catch return;
        defer self.allocator.free(base_fields);

        field_list.appendSlice(base_fields) catch return;
        field_list.append(.{ .key = "duration_us", .value = .{ .int = duration_us } }) catch return;
        field_list.append(.{ .key = "status", .value = .{ .string = "success" } }) catch return;

        self.logger.logWithFields(.info, "RPC call completed", field_list.items);
    }

    /// Log RPC call error
    pub fn logRpcError(self: *RpcLogger, ctx: RequestContext, error_value: anyerror, duration_us: i64) void {
        var field_list = std.ArrayList(zlog.Field).init(self.allocator);
        defer field_list.deinit();

        const base_fields = ctx.fields(self.allocator) catch return;
        defer self.allocator.free(base_fields);

        field_list.appendSlice(base_fields) catch return;
        field_list.append(.{ .key = "duration_us", .value = .{ .int = duration_us } }) catch return;
        field_list.append(.{ .key = "status", .value = .{ .string = "error" } }) catch return;
        field_list.append(.{ .key = "error", .value = .{ .string = @errorName(error_value) } }) catch return;

        self.logger.logWithFields(.err, "RPC call failed", field_list.items);
    }

    /// Log transport connection
    pub fn logTransportConnect(self: *RpcLogger, transport: []const u8, url: []const u8) void {
        const fields = [_]zlog.Field{
            .{ .key = "transport", .value = .{ .string = transport } },
            .{ .key = "url", .value = .{ .string = url } },
        };

        self.logger.logWithFields(.info, "Transport connecting", &fields);
    }

    /// Log transport disconnection
    pub fn logTransportDisconnect(self: *RpcLogger, transport: []const u8, reason: []const u8) void {
        const fields = [_]zlog.Field{
            .{ .key = "transport", .value = .{ .string = transport } },
            .{ .key = "reason", .value = .{ .string = reason } },
        };

        self.logger.logWithFields(.info, "Transport disconnected", &fields);
    }

    /// Log stream open
    pub fn logStreamOpen(self: *RpcLogger, request_id: []const u8, stream_id: u64) void {
        const fields = [_]zlog.Field{
            .{ .key = "request_id", .value = .{ .string = request_id } },
            .{ .key = "stream_id", .value = .{ .uint = stream_id } },
        };

        self.logger.logWithFields(.debug, "Stream opened", &fields);
    }

    /// Log stream close
    pub fn logStreamClose(self: *RpcLogger, request_id: []const u8, stream_id: u64) void {
        const fields = [_]zlog.Field{
            .{ .key = "request_id", .value = .{ .string = request_id } },
            .{ .key = "stream_id", .value = .{ .uint = stream_id } },
        };

        self.logger.logWithFields(.debug, "Stream closed", &fields);
    }

    /// Log compression stats
    pub fn logCompression(self: *RpcLogger, request_id: []const u8, before: usize, after: usize) void {
        const ratio = @as(f64, @floatFromInt(after)) / @as(f64, @floatFromInt(before));
        const savings_pct = (1.0 - ratio) * 100.0;

        const fields = [_]zlog.Field{
            .{ .key = "request_id", .value = .{ .string = request_id } },
            .{ .key = "bytes_before", .value = .{ .uint = @intCast(before) } },
            .{ .key = "bytes_after", .value = .{ .uint = @intCast(after) } },
            .{ .key = "savings_pct", .value = .{ .float = savings_pct } },
        };

        self.logger.logWithFields(.debug, "Compression applied", &fields);
    }

    /// Debug logging
    pub fn debug(self: *RpcLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.debug(fmt, args);
    }

    /// Info logging
    pub fn info(self: *RpcLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.info(fmt, args);
    }

    /// Warn logging
    pub fn warn(self: *RpcLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.warn(fmt, args);
    }

    /// Error logging
    pub fn err(self: *RpcLogger, comptime fmt: []const u8, args: anytype) void {
        self.logger.err(fmt, args);
    }
};

/// Generate unique request ID
pub fn generateRequestId(allocator: std.mem.Allocator) ![]u8 {
    var buf: [16]u8 = undefined;
    std.crypto.random.bytes(&buf);

    return std.fmt.allocPrint(allocator, "{s}", .{std.fmt.bytesToHex(&buf, .lower)});
}

/// Sensitive data redaction
pub fn redactSensitive(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Redact common sensitive patterns
    const patterns = [_][]const u8{
        "password",
        "token",
        "api_key",
        "secret",
        "authorization",
    };

    var result = try allocator.dupe(u8, data);

    for (patterns) |pattern| {
        var start: usize = 0;
        while (std.mem.indexOf(u8, result[start..], pattern)) |pos| {
            const actual_pos = start + pos;
            const end = @min(actual_pos + pattern.len + 20, result.len);

            // Replace sensitive data with [REDACTED]
            for (actual_pos..end) |i| {
                if (i < result.len) result[i] = '*';
            }

            start = end;
            if (start >= result.len) break;
        }
    }

    return result;
}

// Tests
test "request context" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const ctx = RequestContext{
        .request_id = "req-123",
        .method = "TestService/TestMethod",
        .transport = "quic",
        .start_time = std.time.timestamp(),
    };

    const fields = try ctx.fields(allocator);
    defer allocator.free(fields);

    try testing.expectEqual(@as(usize, 4), fields.len);
}

test "generate request ID" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const id1 = try generateRequestId(allocator);
    defer allocator.free(id1);

    const id2 = try generateRequestId(allocator);
    defer allocator.free(id2);

    try testing.expect(id1.len > 0);
    try testing.expect(id2.len > 0);
    try testing.expect(!std.mem.eql(u8, id1, id2));
}

test "redact sensitive data" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const data = "user=admin&password=secret123&token=abc123";
    const redacted = try redactSensitive(allocator, data);
    defer allocator.free(redacted);

    try testing.expect(std.mem.indexOf(u8, redacted, "secret123") == null);
    try testing.expect(std.mem.indexOf(u8, redacted, "abc123") == null);
}

test "RPC logger initialization" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var logger = try RpcLogger.init(allocator, .{
        .level = .debug,
        .format = .text,
    });
    defer logger.deinit();

    logger.info("Test log message", .{});
}
