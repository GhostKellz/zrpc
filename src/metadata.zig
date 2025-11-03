const std = @import("std");
const Error = @import("error.zig").Error;

/// gRPC Metadata for request/response headers
/// Supports both binary and ASCII metadata values
/// Compatible with gRPC wire format
pub const Metadata = struct {
    entries: std.StringHashMap(Entry),
    allocator: std.mem.Allocator,

    pub const Entry = union(enum) {
        ascii: []const u8,
        binary: []const u8,

        pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .ascii => |v| allocator.free(v),
                .binary => |v| allocator.free(v),
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator) Metadata {
        return .{
            .entries = std.StringHashMap(Entry).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Metadata) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            var val = entry.value_ptr.*;
            val.deinit(self.allocator);
        }
        self.entries.deinit();
    }

    /// Add ASCII metadata (standard header)
    pub fn addAscii(self: *Metadata, key: []const u8, value: []const u8) !void {
        // Validate key (lowercase, no -bin suffix)
        if (std.mem.endsWith(u8, key, "-bin")) {
            return Error.InvalidArgument;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try self.entries.put(key_copy, .{ .ascii = value_copy });
    }

    /// Add binary metadata (key must end with -bin)
    pub fn addBinary(self: *Metadata, key: []const u8, value: []const u8) !void {
        // Binary metadata keys MUST end with -bin
        if (!std.mem.endsWith(u8, key, "-bin")) {
            return Error.InvalidArgument;
        }

        const key_copy = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(key_copy);

        const value_copy = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(value_copy);

        try self.entries.put(key_copy, .{ .binary = value_copy });
    }

    /// Get metadata value (ASCII)
    pub fn getAscii(self: *const Metadata, key: []const u8) ?[]const u8 {
        const entry = self.entries.get(key) orelse return null;
        return switch (entry) {
            .ascii => |v| v,
            .binary => null,
        };
    }

    /// Get metadata value (binary)
    pub fn getBinary(self: *const Metadata, key: []const u8) ?[]const u8 {
        const entry = self.entries.get(key) orelse return null;
        return switch (entry) {
            .binary => |v| v,
            .ascii => null,
        };
    }

    /// Remove metadata entry
    pub fn remove(self: *Metadata, key: []const u8) bool {
        if (self.entries.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            var val = kv.value;
            val.deinit(self.allocator);
            return true;
        }
        return false;
    }

    /// Clone metadata
    pub fn clone(self: *const Metadata) !Metadata {
        var new_meta = Metadata.init(self.allocator);
        errdefer new_meta.deinit();

        var it = self.entries.iterator();
        while (it.next()) |entry| {
            const key_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(key_copy);

            const value_copy = switch (entry.value_ptr.*) {
                .ascii => |v| Entry{ .ascii = try self.allocator.dupe(u8, v) },
                .binary => |v| Entry{ .binary = try self.allocator.dupe(u8, v) },
            };
            errdefer {
                var val = value_copy;
                val.deinit(self.allocator);
            }

            try new_meta.entries.put(key_copy, value_copy);
        }

        return new_meta;
    }

    /// Count of metadata entries
    pub fn count(self: *const Metadata) usize {
        return self.entries.count();
    }

    /// Check if key exists
    pub fn contains(self: *const Metadata, key: []const u8) bool {
        return self.entries.contains(key);
    }
};

/// Common gRPC metadata keys
pub const CommonKeys = struct {
    // Authentication
    pub const authorization = "authorization";
    pub const www_authenticate = "www-authenticate";

    // Request metadata
    pub const content_type = "content-type";
    pub const user_agent = "user-agent";
    pub const grpc_timeout = "grpc-timeout";
    pub const grpc_encoding = "grpc-encoding";
    pub const grpc_accept_encoding = "grpc-accept-encoding";

    // Response metadata
    pub const grpc_status = "grpc-status";
    pub const grpc_message = "grpc-message";
    pub const grpc_status_details_bin = "grpc-status-details-bin";

    // Tracing
    pub const trace_id = "x-trace-id";
    pub const span_id = "x-span-id";
    pub const parent_span_id = "x-parent-span-id";

    // Custom application metadata
    pub const request_id = "x-request-id";
    pub const correlation_id = "x-correlation-id";
};

/// Parse gRPC timeout format (e.g., "1H", "30S", "500m")
pub fn parseTimeout(timeout_str: []const u8) ?u64 {
    if (timeout_str.len < 2) return null;

    const value_str = timeout_str[0 .. timeout_str.len - 1];
    const unit = timeout_str[timeout_str.len - 1];

    const value = std.fmt.parseInt(u64, value_str, 10) catch return null;

    return switch (unit) {
        'H' => value * std.time.ns_per_hour,
        'M' => value * std.time.ns_per_min,
        'S' => value * std.time.ns_per_s,
        'm' => value * std.time.ns_per_ms,
        'u' => value * std.time.ns_per_us,
        'n' => value,
        else => null,
    };
}

/// Format timeout to gRPC format
pub fn formatTimeout(allocator: std.mem.Allocator, timeout_ns: u64) ![]u8 {
    // Choose appropriate unit based on magnitude
    if (timeout_ns >= std.time.ns_per_hour) {
        const hours = timeout_ns / std.time.ns_per_hour;
        return std.fmt.allocPrint(allocator, "{d}H", .{hours});
    } else if (timeout_ns >= std.time.ns_per_min) {
        const mins = timeout_ns / std.time.ns_per_min;
        return std.fmt.allocPrint(allocator, "{d}M", .{mins});
    } else if (timeout_ns >= std.time.ns_per_s) {
        const secs = timeout_ns / std.time.ns_per_s;
        return std.fmt.allocPrint(allocator, "{d}S", .{secs});
    } else if (timeout_ns >= std.time.ns_per_ms) {
        const ms = timeout_ns / std.time.ns_per_ms;
        return std.fmt.allocPrint(allocator, "{d}m", .{ms});
    } else if (timeout_ns >= std.time.ns_per_us) {
        const us = timeout_ns / std.time.ns_per_us;
        return std.fmt.allocPrint(allocator, "{d}u", .{us});
    } else {
        return std.fmt.allocPrint(allocator, "{d}n", .{timeout_ns});
    }
}

/// Context for carrying metadata and deadlines across RPC calls
pub const Context = struct {
    metadata: Metadata,
    deadline: ?i64, // Absolute timestamp in nanoseconds
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Context {
        return .{
            .metadata = Metadata.init(allocator),
            .deadline = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Context) void {
        self.metadata.deinit();
    }

    /// Create context with deadline
    pub fn withDeadline(allocator: std.mem.Allocator, deadline: i64) Context {
        return .{
            .metadata = Metadata.init(allocator),
            .deadline = deadline,
            .allocator = allocator,
        };
    }

    /// Create context with timeout (relative to now)
    pub fn withTimeout(allocator: std.mem.Allocator, timeout_ns: u64) Context {
        const now = std.time.nanoTimestamp();
        return withDeadline(allocator, now + @as(i64, @intCast(timeout_ns)));
    }

    /// Check if deadline has been exceeded
    pub fn isDeadlineExceeded(self: *const Context) bool {
        if (self.deadline) |dl| {
            const now = std.time.nanoTimestamp();
            return now >= dl;
        }
        return false;
    }

    /// Get remaining time until deadline
    pub fn getRemainingTime(self: *const Context) ?u64 {
        if (self.deadline) |dl| {
            const now = std.time.nanoTimestamp();
            if (now >= dl) return 0;
            return @intCast(dl - now);
        }
        return null;
    }

    /// Clone context (useful for propagation)
    pub fn clone(self: *const Context) !Context {
        return .{
            .metadata = try self.metadata.clone(),
            .deadline = self.deadline,
            .allocator = self.allocator,
        };
    }
};

// Tests
test "metadata ascii operations" {
    const allocator = std.testing.allocator;
    var meta = Metadata.init(allocator);
    defer meta.deinit();

    try meta.addAscii("content-type", "application/grpc");
    try meta.addAscii("authorization", "Bearer token123");

    try std.testing.expectEqualStrings("application/grpc", meta.getAscii("content-type").?);
    try std.testing.expectEqualStrings("Bearer token123", meta.getAscii("authorization").?);
    try std.testing.expect(meta.getAscii("nonexistent") == null);
}

test "metadata binary operations" {
    const allocator = std.testing.allocator;
    var meta = Metadata.init(allocator);
    defer meta.deinit();

    const binary_data = "\x00\x01\x02\x03\xff";
    try meta.addBinary("custom-bin", binary_data);

    const retrieved = meta.getBinary("custom-bin").?;
    try std.testing.expectEqualSlices(u8, binary_data, retrieved);

    // Binary key without -bin suffix should fail
    const result = meta.addBinary("invalid", "data");
    try std.testing.expectError(Error.InvalidArgument, result);
}

test "metadata clone" {
    const allocator = std.testing.allocator;
    var meta = Metadata.init(allocator);
    defer meta.deinit();

    try meta.addAscii("key1", "value1");
    try meta.addAscii("key2", "value2");

    var cloned = try meta.clone();
    defer cloned.deinit();

    try std.testing.expectEqualStrings("value1", cloned.getAscii("key1").?);
    try std.testing.expectEqualStrings("value2", cloned.getAscii("key2").?);
}

test "timeout parsing" {
    try std.testing.expectEqual(@as(?u64, 3600 * std.time.ns_per_s), parseTimeout("1H"));
    try std.testing.expectEqual(@as(?u64, 60 * std.time.ns_per_s), parseTimeout("1M"));
    try std.testing.expectEqual(@as(?u64, 30 * std.time.ns_per_s), parseTimeout("30S"));
    try std.testing.expectEqual(@as(?u64, 500 * std.time.ns_per_ms), parseTimeout("500m"));
    try std.testing.expectEqual(@as(?u64, 100 * std.time.ns_per_us), parseTimeout("100u"));
    try std.testing.expectEqual(@as(?u64, 50), parseTimeout("50n"));

    try std.testing.expect(parseTimeout("invalid") == null);
    try std.testing.expect(parseTimeout("X") == null);
}

test "timeout formatting" {
    const allocator = std.testing.allocator;

    const hour_fmt = try formatTimeout(allocator, 2 * std.time.ns_per_hour);
    defer allocator.free(hour_fmt);
    try std.testing.expectEqualStrings("2H", hour_fmt);

    const sec_fmt = try formatTimeout(allocator, 45 * std.time.ns_per_s);
    defer allocator.free(sec_fmt);
    try std.testing.expectEqualStrings("45S", sec_fmt);

    const ms_fmt = try formatTimeout(allocator, 250 * std.time.ns_per_ms);
    defer allocator.free(ms_fmt);
    try std.testing.expectEqualStrings("250m", ms_fmt);
}

test "context with deadline" {
    const allocator = std.testing.allocator;

    const future_deadline: i64 = @intCast(std.time.nanoTimestamp() + (10 * std.time.ns_per_s));
    var ctx = Context.withDeadline(allocator, future_deadline);
    defer ctx.deinit();

    try std.testing.expect(!ctx.isDeadlineExceeded());
    try std.testing.expect(ctx.getRemainingTime() != null);
    try std.testing.expect(ctx.getRemainingTime().? > 0);

    const past_deadline: i64 = @intCast(std.time.nanoTimestamp() - (10 * std.time.ns_per_s));
    var past_ctx = Context.withDeadline(allocator, past_deadline);
    defer past_ctx.deinit();

    try std.testing.expect(past_ctx.isDeadlineExceeded());
    try std.testing.expectEqual(@as(u64, 0), past_ctx.getRemainingTime().?);
}

test "context with timeout" {
    const allocator = std.testing.allocator;

    var ctx = Context.withTimeout(allocator, 5 * std.time.ns_per_s);
    defer ctx.deinit();

    try std.testing.expect(!ctx.isDeadlineExceeded());

    const remaining = ctx.getRemainingTime().?;
    try std.testing.expect(remaining > 0);
    try std.testing.expect(remaining <= 5 * std.time.ns_per_s);
}

test "context metadata integration" {
    const allocator = std.testing.allocator;

    var ctx = Context.init(allocator);
    defer ctx.deinit();

    try ctx.metadata.addAscii("authorization", "Bearer abc123");
    try ctx.metadata.addAscii("x-request-id", "req-12345");

    try std.testing.expectEqualStrings("Bearer abc123", ctx.metadata.getAscii("authorization").?);
    try std.testing.expectEqualStrings("req-12345", ctx.metadata.getAscii("x-request-id").?);
}
