const std = @import("std");
const Error = @import("error.zig").Error;
const metadata_mod = @import("metadata.zig");

/// Deadline timer for tracking RPC call timeouts
pub const DeadlineTimer = struct {
    deadline: ?i64, // Absolute timestamp in nanoseconds
    start_time: i64,

    pub fn init(deadline: ?i64) DeadlineTimer {
        return .{
            .deadline = deadline,
            .start_time = std.time.nanoTimestamp(),
        };
    }

    /// Create timer with timeout duration
    pub fn fromTimeout(timeout_ns: u64) DeadlineTimer {
        const now = std.time.nanoTimestamp();
        return .{
            .deadline = now + @as(i64, @intCast(timeout_ns)),
            .start_time = now,
        };
    }

    /// Check if deadline has been exceeded
    pub fn isExceeded(self: *const DeadlineTimer) bool {
        if (self.deadline) |dl| {
            return std.time.nanoTimestamp() >= dl;
        }
        return false;
    }

    /// Get remaining time until deadline
    pub fn remaining(self: *const DeadlineTimer) ?u64 {
        if (self.deadline) |dl| {
            const now = std.time.nanoTimestamp();
            if (now >= dl) return 0;
            return @intCast(dl - now);
        }
        return null;
    }

    /// Get elapsed time since start
    pub fn elapsed(self: *const DeadlineTimer) u64 {
        const now = std.time.nanoTimestamp();
        return @intCast(now - self.start_time);
    }

    /// Check and return error if deadline exceeded
    pub fn check(self: *const DeadlineTimer) Error!void {
        if (self.isExceeded()) {
            return Error.DeadlineExceeded;
        }
    }
};

/// Deadline propagation helper
pub const DeadlinePropagation = struct {
    /// Extract deadline from metadata
    pub fn fromMetadata(meta: *const metadata_mod.Metadata) ?i64 {
        const timeout_str = meta.getAscii(metadata_mod.CommonKeys.grpc_timeout) orelse return null;
        const timeout_ns = metadata_mod.parseTimeout(timeout_str) orelse return null;

        const now = std.time.nanoTimestamp();
        return now + @as(i64, @intCast(timeout_ns));
    }

    /// Add deadline to metadata
    pub fn toMetadata(allocator: std.mem.Allocator, meta: *metadata_mod.Metadata, deadline: i64) !void {
        const now = std.time.nanoTimestamp();
        if (deadline <= now) {
            // Already exceeded, set to 0
            try meta.addAscii(metadata_mod.CommonKeys.grpc_timeout, "0n");
            return;
        }

        const remaining_ns: u64 = @intCast(deadline - now);
        const timeout_str = try metadata_mod.formatTimeout(allocator, remaining_ns);
        defer allocator.free(timeout_str);

        try meta.addAscii(metadata_mod.CommonKeys.grpc_timeout, timeout_str);
    }

    /// Propagate deadline from incoming context to outgoing context
    pub fn propagate(
        allocator: std.mem.Allocator,
        from_ctx: *const metadata_mod.Context,
        to_meta: *metadata_mod.Metadata,
    ) !void {
        if (from_ctx.deadline) |dl| {
            try toMetadata(allocator, to_meta, dl);
        }
    }
};

/// Timeout configuration presets
pub const TimeoutPreset = enum {
    very_short, // 100ms
    short, // 1s
    medium, // 5s
    long, // 30s
    very_long, // 2m

    pub fn duration(self: TimeoutPreset) u64 {
        return switch (self) {
            .very_short => 100 * std.time.ns_per_ms,
            .short => 1 * std.time.ns_per_s,
            .medium => 5 * std.time.ns_per_s,
            .long => 30 * std.time.ns_per_s,
            .very_long => 120 * std.time.ns_per_s,
        };
    }
};

/// Call options with deadline/timeout
pub const CallOptions = struct {
    timeout: ?u64 = null, // Timeout in nanoseconds
    deadline: ?i64 = null, // Absolute deadline
    propagate_deadline: bool = true, // Propagate deadline from parent context

    /// Get effective deadline from options and parent context
    pub fn getDeadline(self: *const CallOptions, parent_ctx: ?*const metadata_mod.Context) ?i64 {
        // Priority: explicit deadline > timeout > parent context
        if (self.deadline) |dl| {
            return dl;
        }

        if (self.timeout) |timeout_ns| {
            const now = std.time.nanoTimestamp();
            return now + @as(i64, @intCast(timeout_ns));
        }

        if (self.propagate_deadline) {
            if (parent_ctx) |ctx| {
                return ctx.deadline;
            }
        }

        return null;
    }

    /// Create options with timeout
    pub fn withTimeout(timeout_ns: u64) CallOptions {
        return .{ .timeout = timeout_ns };
    }

    /// Create options with deadline
    pub fn withDeadline(deadline: i64) CallOptions {
        return .{ .deadline = deadline };
    }

    /// Create options with preset
    pub fn withPreset(preset: TimeoutPreset) CallOptions {
        return .{ .timeout = preset.duration() };
    }
};

// Tests
test "deadline timer basic" {
    const timer = DeadlineTimer.fromTimeout(1 * std.time.ns_per_s);
    try std.testing.expect(!timer.isExceeded());
    try std.testing.expect(timer.remaining() != null);
    try std.testing.expect(timer.remaining().? > 0);
}

test "deadline timer exceeded" {
    const past = std.time.nanoTimestamp() - (10 * std.time.ns_per_s);
    const timer = DeadlineTimer.init(past);
    try std.testing.expect(timer.isExceeded());
    try std.testing.expectEqual(@as(u64, 0), timer.remaining().?);

    const result = timer.check();
    try std.testing.expectError(Error.DeadlineExceeded, result);
}

test "deadline timer elapsed" {
    const timer = DeadlineTimer.fromTimeout(10 * std.time.ns_per_s);
    std.time.sleep(10 * std.time.ns_per_ms); // Sleep 10ms

    const elapsed_time = timer.elapsed();
    try std.testing.expect(elapsed_time >= 10 * std.time.ns_per_ms);
}

test "deadline propagation to metadata" {
    const allocator = std.testing.allocator;
    var meta = metadata_mod.Metadata.init(allocator);
    defer meta.deinit();

    const future_deadline = std.time.nanoTimestamp() + (30 * std.time.ns_per_s);
    try DeadlinePropagation.toMetadata(allocator, &meta, future_deadline);

    const timeout_str = meta.getAscii(metadata_mod.CommonKeys.grpc_timeout).?;
    try std.testing.expect(std.mem.startsWith(u8, timeout_str, "30") or std.mem.startsWith(u8, timeout_str, "29"));
}

test "deadline propagation from metadata" {
    const allocator = std.testing.allocator;
    var meta = metadata_mod.Metadata.init(allocator);
    defer meta.deinit();

    try meta.addAscii(metadata_mod.CommonKeys.grpc_timeout, "15S");

    const deadline = DeadlinePropagation.fromMetadata(&meta);
    try std.testing.expect(deadline != null);

    const timer = DeadlineTimer.init(deadline);
    try std.testing.expect(!timer.isExceeded());
}

test "call options deadline priority" {
    const allocator = std.testing.allocator;

    // Explicit deadline takes priority
    const explicit_deadline = std.time.nanoTimestamp() + (100 * std.time.ns_per_s);
    const opts = CallOptions.withDeadline(explicit_deadline);

    var ctx = metadata_mod.Context.withTimeout(allocator, 5 * std.time.ns_per_s);
    defer ctx.deinit();

    const effective = opts.getDeadline(&ctx);
    try std.testing.expectEqual(explicit_deadline, effective.?);
}

test "call options timeout" {
    const opts = CallOptions.withTimeout(10 * std.time.ns_per_s);
    const deadline = opts.getDeadline(null);

    try std.testing.expect(deadline != null);

    const timer = DeadlineTimer.init(deadline);
    try std.testing.expect(!timer.isExceeded());
}

test "timeout presets" {
    try std.testing.expectEqual(@as(u64, 100 * std.time.ns_per_ms), TimeoutPreset.very_short.duration());
    try std.testing.expectEqual(@as(u64, 1 * std.time.ns_per_s), TimeoutPreset.short.duration());
    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_s), TimeoutPreset.medium.duration());
    try std.testing.expectEqual(@as(u64, 30 * std.time.ns_per_s), TimeoutPreset.long.duration());
    try std.testing.expectEqual(@as(u64, 120 * std.time.ns_per_s), TimeoutPreset.very_long.duration());
}
