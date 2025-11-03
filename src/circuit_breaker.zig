const std = @import("std");
const Error = @import("error.zig").Error;
const Status = @import("error.zig").Status;
const interceptor_mod = @import("interceptor.zig");
const Interceptor = interceptor_mod.Interceptor;
const InterceptorContext = interceptor_mod.InterceptorContext;

/// Circuit breaker states
pub const CircuitState = enum {
    closed,      // Normal operation
    open,        // Rejecting requests
    half_open,   // Testing if service recovered
};

/// Circuit breaker configuration
pub const CircuitBreakerConfig = struct {
    /// Failure threshold to open circuit
    failure_threshold: u32 = 5,

    /// Success threshold to close from half-open
    success_threshold: u32 = 2,

    /// Timeout before moving to half-open (nanoseconds)
    timeout_ns: u64 = 30 * std.time.ns_per_s,

    /// Window size for failure tracking (nanoseconds)
    window_ns: u64 = 60 * std.time.ns_per_s,

    /// Maximum half-open requests
    max_half_open_requests: u32 = 3,
};

/// Circuit breaker statistics
pub const CircuitBreakerStats = struct {
    state: CircuitState,
    failures: u32,
    successes: u32,
    total_requests: u64,
    rejected_requests: u64,
    last_failure_time: ?i64,
    state_changed_at: i64,
};

/// Circuit breaker interceptor for fault tolerance
pub const CircuitBreakerInterceptor = struct {
    allocator: std.mem.Allocator,
    config: CircuitBreakerConfig,
    state: std.atomic.Value(CircuitState),
    failure_count: std.atomic.Value(u32),
    success_count: std.atomic.Value(u32),
    total_requests: std.atomic.Value(u64),
    rejected_requests: std.atomic.Value(u64),
    last_failure_time: std.atomic.Value(i64),
    state_changed_at: std.atomic.Value(i64),
    half_open_requests: std.atomic.Value(u32),
    mutex: std.Thread.Mutex,

    const vtable = Interceptor.VTable{
        .intercept_request = interceptRequest,
        .intercept_response = interceptResponse,
        .deinit = deinitFn,
    };

    pub fn init(allocator: std.mem.Allocator, config: CircuitBreakerConfig) !*CircuitBreakerInterceptor {
        const self = try allocator.create(CircuitBreakerInterceptor);
        const now = std.time.nanoTimestamp();

        self.* = .{
            .allocator = allocator,
            .config = config,
            .state = std.atomic.Value(CircuitState).init(.closed),
            .failure_count = std.atomic.Value(u32).init(0),
            .success_count = std.atomic.Value(u32).init(0),
            .total_requests = std.atomic.Value(u64).init(0),
            .rejected_requests = std.atomic.Value(u64).init(0),
            .last_failure_time = std.atomic.Value(i64).init(0),
            .state_changed_at = std.atomic.Value(i64).init(now),
            .half_open_requests = std.atomic.Value(u32).init(0),
            .mutex = .{},
        };
        return self;
    }

    pub fn asInterceptor(self: *CircuitBreakerInterceptor) Interceptor {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn interceptRequest(ptr: *anyopaque, ctx: *InterceptorContext) Error!void {
        const self: *CircuitBreakerInterceptor = @ptrCast(@alignCast(ptr));
        _ = self.total_requests.fetchAdd(1, .monotonic);

        const current_state = self.state.load(.acquire);

        switch (current_state) {
            .closed => {
                // Normal operation - allow request
                return;
            },
            .open => {
                // Check if timeout expired
                const now = std.time.nanoTimestamp();
                const state_change_time = self.state_changed_at.load(.acquire);

                if (now - state_change_time >= @as(i64, @intCast(self.config.timeout_ns))) {
                    // Try to transition to half-open
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    if (self.state.load(.acquire) == .open) {
                        self.state.store(.half_open, .release);
                        self.state_changed_at.store(now, .release);
                        self.success_count.store(0, .release);
                        self.half_open_requests.store(0, .release);

                        std.log.info("Circuit breaker: OPEN -> HALF_OPEN (testing recovery)", .{});
                    }
                    return;
                }

                // Circuit is open, reject request
                _ = self.rejected_requests.fetchAdd(1, .monotonic);

                const time_until_retry = self.config.timeout_ns - @as(u64, @intCast(now - state_change_time));
                const retry_after_s = @divFloor(time_until_retry, std.time.ns_per_s);

                std.log.warn("Circuit breaker: Request rejected (retry after {d}s)", .{retry_after_s});

                // Add metadata about circuit breaker state
                const retry_str = try std.fmt.allocPrint(ctx.allocator, "{d}", .{retry_after_s});
                defer ctx.allocator.free(retry_str);

                try ctx.metadata.addAscii("x-circuit-breaker-state", "open");
                try ctx.metadata.addAscii("x-retry-after-seconds", retry_str);

                return Error.Unavailable;
            },
            .half_open => {
                // Allow limited requests to test if service recovered
                const current_half_open = self.half_open_requests.load(.acquire);

                if (current_half_open >= self.config.max_half_open_requests) {
                    // Too many half-open requests, reject
                    _ = self.rejected_requests.fetchAdd(1, .monotonic);
                    std.log.warn("Circuit breaker: Half-open request limit reached", .{});

                    try ctx.metadata.addAscii("x-circuit-breaker-state", "half-open-limited");
                    return Error.Unavailable;
                }

                _ = self.half_open_requests.fetchAdd(1, .monotonic);
                try ctx.metadata.addAscii("x-circuit-breaker-state", "half-open");
                return;
            },
        }
    }

    fn interceptResponse(ptr: *anyopaque, ctx: *InterceptorContext) Error!void {
        const self: *CircuitBreakerInterceptor = @ptrCast(@alignCast(ptr));
        const current_state = self.state.load(.acquire);

        if (ctx.status) |status| {
            const is_failure = switch (status.code) {
                .unavailable, .deadline_exceeded, .resource_exhausted, .internal => true,
                else => false,
            };

            if (is_failure) {
                try self.recordFailure();
            } else {
                try self.recordSuccess();
            }

            // Decrement half-open counter if applicable
            if (current_state == .half_open) {
                _ = self.half_open_requests.fetchSub(1, .monotonic);
            }
        }
    }

    fn recordFailure(self: *CircuitBreakerInterceptor) Error!void {
        const now = std.time.nanoTimestamp();
        _ = self.failure_count.fetchAdd(1, .monotonic);
        self.last_failure_time.store(now, .release);

        const current_state = self.state.load(.acquire);
        const failures = self.failure_count.load(.acquire);

        switch (current_state) {
            .closed => {
                if (failures >= self.config.failure_threshold) {
                    self.mutex.lock();
                    defer self.mutex.unlock();

                    if (self.state.load(.acquire) == .closed) {
                        self.state.store(.open, .release);
                        self.state_changed_at.store(now, .release);
                        self.failure_count.store(0, .release);

                        std.log.warn("Circuit breaker: CLOSED -> OPEN (failures: {d})", .{failures});
                    }
                }
            },
            .half_open => {
                // Single failure in half-open = back to open
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.state.load(.acquire) == .half_open) {
                    self.state.store(.open, .release);
                    self.state_changed_at.store(now, .release);
                    self.failure_count.store(0, .release);
                    self.success_count.store(0, .release);

                    std.log.warn("Circuit breaker: HALF_OPEN -> OPEN (recovery failed)", .{});
                }
            },
            .open => {
                // Already open, nothing to do
            },
        }
    }

    fn recordSuccess(self: *CircuitBreakerInterceptor) Error!void {
        const current_state = self.state.load(.acquire);

        if (current_state == .closed) {
            // Reset failure count on success
            self.failure_count.store(0, .release);
            return;
        }

        if (current_state == .half_open) {
            const successes = self.success_count.fetchAdd(1, .monotonic) + 1;

            if (successes >= self.config.success_threshold) {
                self.mutex.lock();
                defer self.mutex.unlock();

                if (self.state.load(.acquire) == .half_open) {
                    const now = std.time.nanoTimestamp();
                    self.state.store(.closed, .release);
                    self.state_changed_at.store(now, .release);
                    self.failure_count.store(0, .release);
                    self.success_count.store(0, .release);

                    std.log.info("Circuit breaker: HALF_OPEN -> CLOSED (service recovered)", .{});
                }
            }
        }
    }

    /// Get current statistics
    pub fn getStats(self: *CircuitBreakerInterceptor) CircuitBreakerStats {
        return .{
            .state = self.state.load(.acquire),
            .failures = self.failure_count.load(.acquire),
            .successes = self.success_count.load(.acquire),
            .total_requests = self.total_requests.load(.acquire),
            .rejected_requests = self.rejected_requests.load(.acquire),
            .last_failure_time = blk: {
                const val = self.last_failure_time.load(.acquire);
                break :blk if (val == 0) null else val;
            },
            .state_changed_at = self.state_changed_at.load(.acquire),
        };
    }

    /// Reset circuit breaker to closed state
    pub fn reset(self: *CircuitBreakerInterceptor) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.nanoTimestamp();
        self.state.store(.closed, .release);
        self.state_changed_at.store(now, .release);
        self.failure_count.store(0, .release);
        self.success_count.store(0, .release);
        self.half_open_requests.store(0, .release);

        std.log.info("Circuit breaker: Manual reset to CLOSED", .{});
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *CircuitBreakerInterceptor = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

// Tests
test "circuit breaker basic flow" {
    const allocator = std.testing.allocator;

    const config = CircuitBreakerConfig{
        .failure_threshold = 3,
        .success_threshold = 2,
        .timeout_ns = 1 * std.time.ns_per_s,
    };

    var cb = try CircuitBreakerInterceptor.init(allocator, config);
    defer cb.asInterceptor().deinit();

    var metadata_mod = @import("metadata.zig");
    var meta = metadata_mod.Metadata.init(allocator);
    defer meta.deinit();

    var ctx = InterceptorContext{
        .method = "TestService/TestMethod",
        .metadata = &meta,
        .request_body = "test",
        .response_body = "response",
        .status = Status.ok(),
        .allocator = allocator,
    };

    // Initial state: closed
    try std.testing.expectEqual(CircuitState.closed, cb.state.load(.acquire));

    // Successful requests
    try cb.asInterceptor().interceptRequest(&ctx);
    try cb.asInterceptor().interceptResponse(&ctx);

    // Still closed
    try std.testing.expectEqual(CircuitState.closed, cb.state.load(.acquire));

    // Multiple failures
    ctx.status = Status.unavailable("service down");

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try cb.asInterceptor().interceptRequest(&ctx);
        try cb.asInterceptor().interceptResponse(&ctx);
    }

    // Should be open now
    try std.testing.expectEqual(CircuitState.open, cb.state.load(.acquire));

    // Requests should be rejected
    const result = cb.asInterceptor().interceptRequest(&ctx);
    try std.testing.expectError(Error.Unavailable, result);

    const stats = cb.getStats();
    try std.testing.expect(stats.rejected_requests > 0);
}

test "circuit breaker half-open transition" {
    const allocator = std.testing.allocator;

    const config = CircuitBreakerConfig{
        .failure_threshold = 2,
        .success_threshold = 2,
        .timeout_ns = 100 * std.time.ns_per_ms, // 100ms timeout
    };

    var cb = try CircuitBreakerInterceptor.init(allocator, config);
    defer cb.asInterceptor().deinit();

    var metadata_mod = @import("metadata.zig");
    var meta = metadata_mod.Metadata.init(allocator);
    defer meta.deinit();

    var ctx = InterceptorContext{
        .method = "TestService/TestMethod",
        .metadata = &meta,
        .request_body = "test",
        .response_body = "response",
        .status = Status.unavailable("service down"),
        .allocator = allocator,
    };

    // Trigger failures to open circuit
    try cb.asInterceptor().interceptRequest(&ctx);
    try cb.asInterceptor().interceptResponse(&ctx);
    try cb.asInterceptor().interceptRequest(&ctx);
    try cb.asInterceptor().interceptResponse(&ctx);

    try std.testing.expectEqual(CircuitState.open, cb.state.load(.acquire));

    // Wait for timeout
    std.Thread.sleep(150 * std.time.ns_per_ms);

    // Next request should transition to half-open
    try cb.asInterceptor().interceptRequest(&ctx);
    try std.testing.expectEqual(CircuitState.half_open, cb.state.load(.acquire));

    // Successful responses should close circuit
    ctx.status = Status.ok();
    try cb.asInterceptor().interceptResponse(&ctx);

    try cb.asInterceptor().interceptRequest(&ctx);
    try cb.asInterceptor().interceptResponse(&ctx);

    try std.testing.expectEqual(CircuitState.closed, cb.state.load(.acquire));
}

test "circuit breaker statistics" {
    const allocator = std.testing.allocator;

    var cb = try CircuitBreakerInterceptor.init(allocator, .{});
    defer cb.asInterceptor().deinit();

    const stats1 = cb.getStats();
    try std.testing.expectEqual(@as(u64, 0), stats1.total_requests);
    try std.testing.expectEqual(@as(u64, 0), stats1.rejected_requests);

    var metadata_mod = @import("metadata.zig");
    var meta = metadata_mod.Metadata.init(allocator);
    defer meta.deinit();

    var ctx = InterceptorContext{
        .method = "Test",
        .metadata = &meta,
        .request_body = "test",
        .response_body = null,
        .status = null,
        .allocator = allocator,
    };

    try cb.asInterceptor().interceptRequest(&ctx);

    const stats2 = cb.getStats();
    try std.testing.expectEqual(@as(u64, 1), stats2.total_requests);
}
