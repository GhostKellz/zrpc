const std = @import("std");
const Error = @import("error.zig").Error;
const Status = @import("error.zig").Status;
const metadata_mod = @import("metadata.zig");
const Metadata = metadata_mod.Metadata;
const Context = metadata_mod.Context;

/// Interceptor interface for RPC middleware
/// Interceptors can modify requests/responses, add logging, auth, etc.
pub const Interceptor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Called before RPC request is sent
        intercept_request: *const fn (
            ptr: *anyopaque,
            ctx: *InterceptorContext,
        ) Error!void,

        /// Called after RPC response is received
        intercept_response: *const fn (
            ptr: *anyopaque,
            ctx: *InterceptorContext,
        ) Error!void,

        /// Optional cleanup
        deinit: ?*const fn (ptr: *anyopaque) void,
    };

    pub fn interceptRequest(self: Interceptor, ctx: *InterceptorContext) Error!void {
        return self.vtable.intercept_request(self.ptr, ctx);
    }

    pub fn interceptResponse(self: Interceptor, ctx: *InterceptorContext) Error!void {
        return self.vtable.intercept_response(self.ptr, ctx);
    }

    pub fn deinit(self: Interceptor) void {
        if (self.vtable.deinit) |deinit_fn| {
            deinit_fn(self.ptr);
        }
    }
};

/// Context passed to interceptors
pub const InterceptorContext = struct {
    method: []const u8,
    metadata: *Metadata,
    request_body: []const u8,
    response_body: ?[]const u8,
    status: ?Status,
    allocator: std.mem.Allocator,

    /// Additional context data (for custom interceptors)
    user_data: ?*anyopaque = null,
};

/// Chain of interceptors
pub const InterceptorChain = struct {
    interceptors: std.ArrayList(Interceptor),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) InterceptorChain {
        return .{
            .interceptors = std.ArrayList(Interceptor).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InterceptorChain) void {
        for (self.interceptors.items) |interceptor| {
            interceptor.deinit();
        }
        self.interceptors.deinit();
    }

    pub fn add(self: *InterceptorChain, interceptor: Interceptor) !void {
        try self.interceptors.append(interceptor);
    }

    /// Execute all interceptors for request
    pub fn interceptRequest(self: *InterceptorChain, ctx: *InterceptorContext) Error!void {
        for (self.interceptors.items) |interceptor| {
            try interceptor.interceptRequest(ctx);
        }
    }

    /// Execute all interceptors for response (in reverse order)
    pub fn interceptResponse(self: *InterceptorChain, ctx: *InterceptorContext) Error!void {
        var i = self.interceptors.items.len;
        while (i > 0) {
            i -= 1;
            try self.interceptors.items[i].interceptResponse(ctx);
        }
    }
};

/// Built-in logging interceptor
pub const LoggingInterceptor = struct {
    allocator: std.mem.Allocator,
    log_requests: bool,
    log_responses: bool,

    const vtable = Interceptor.VTable{
        .intercept_request = interceptRequest,
        .intercept_response = interceptResponse,
        .deinit = deinitFn,
    };

    pub fn init(allocator: std.mem.Allocator, log_requests: bool, log_responses: bool) !*LoggingInterceptor {
        const self = try allocator.create(LoggingInterceptor);
        self.* = .{
            .allocator = allocator,
            .log_requests = log_requests,
            .log_responses = log_responses,
        };
        return self;
    }

    pub fn asInterceptor(self: *LoggingInterceptor) Interceptor {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn interceptRequest(ptr: *anyopaque, ctx: *InterceptorContext) Error!void {
        const self: *LoggingInterceptor = @ptrCast(@alignCast(ptr));
        if (self.log_requests) {
            std.log.info("RPC Request: method={s} body_len={d}", .{
                ctx.method,
                ctx.request_body.len,
            });
        }
    }

    fn interceptResponse(ptr: *anyopaque, ctx: *InterceptorContext) Error!void {
        const self: *LoggingInterceptor = @ptrCast(@alignCast(ptr));
        if (self.log_responses) {
            const body_len = if (ctx.response_body) |body| body.len else 0;
            const status_code = if (ctx.status) |s| @intFromEnum(s.code) else 0;

            std.log.info("RPC Response: method={s} status={d} body_len={d}", .{
                ctx.method,
                status_code,
                body_len,
            });
        }
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *LoggingInterceptor = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

/// Built-in authentication interceptor
pub const AuthInterceptor = struct {
    allocator: std.mem.Allocator,
    token: []const u8,
    header_key: []const u8,

    const vtable = Interceptor.VTable{
        .intercept_request = interceptRequest,
        .intercept_response = interceptResponse,
        .deinit = deinitFn,
    };

    pub fn init(allocator: std.mem.Allocator, token: []const u8, header_key: []const u8) !*AuthInterceptor {
        const self = try allocator.create(AuthInterceptor);
        self.* = .{
            .allocator = allocator,
            .token = try allocator.dupe(u8, token),
            .header_key = try allocator.dupe(u8, header_key),
        };
        return self;
    }

    pub fn asInterceptor(self: *AuthInterceptor) Interceptor {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn interceptRequest(ptr: *anyopaque, ctx: *InterceptorContext) Error!void {
        const self: *AuthInterceptor = @ptrCast(@alignCast(ptr));
        try ctx.metadata.addAscii(self.header_key, self.token);
    }

    fn interceptResponse(_: *anyopaque, _: *InterceptorContext) Error!void {
        // No-op for auth interceptor
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *AuthInterceptor = @ptrCast(@alignCast(ptr));
        self.allocator.free(self.token);
        self.allocator.free(self.header_key);
        self.allocator.destroy(self);
    }
};

/// Built-in retry interceptor
pub const RetryInterceptor = struct {
    allocator: std.mem.Allocator,
    max_retries: u32,
    retry_count: u32,

    const vtable = Interceptor.VTable{
        .intercept_request = interceptRequest,
        .intercept_response = interceptResponse,
        .deinit = deinitFn,
    };

    pub fn init(allocator: std.mem.Allocator, max_retries: u32) !*RetryInterceptor {
        const self = try allocator.create(RetryInterceptor);
        self.* = .{
            .allocator = allocator,
            .max_retries = max_retries,
            .retry_count = 0,
        };
        return self;
    }

    pub fn asInterceptor(self: *RetryInterceptor) Interceptor {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn interceptRequest(ptr: *anyopaque, ctx: *InterceptorContext) Error!void {
        const self: *RetryInterceptor = @ptrCast(@alignCast(ptr));

        // Add retry metadata
        const retry_str = try std.fmt.allocPrint(
            ctx.allocator,
            "{d}",
            .{self.retry_count},
        );
        defer ctx.allocator.free(retry_str);

        try ctx.metadata.addAscii("x-retry-count", retry_str);
    }

    fn interceptResponse(ptr: *anyopaque, ctx: *InterceptorContext) Error!void {
        const self: *RetryInterceptor = @ptrCast(@alignCast(ptr));

        if (ctx.status) |status| {
            // Retry on specific status codes
            const should_retry = switch (status.code) {
                .unavailable, .deadline_exceeded, .resource_exhausted => true,
                else => false,
            };

            if (should_retry and self.retry_count < self.max_retries) {
                self.retry_count += 1;
                std.log.warn("Retrying request (attempt {d}/{d})", .{
                    self.retry_count,
                    self.max_retries,
                });
                // In real implementation, would signal retry to caller
            } else {
                self.retry_count = 0; // Reset for next call
            }
        }
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *RetryInterceptor = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }
};

/// Built-in metrics interceptor
pub const MetricsInterceptor = struct {
    allocator: std.mem.Allocator,
    request_count: std.atomic.Value(u64),
    error_count: std.atomic.Value(u64),
    start_time: ?i64,

    const vtable = Interceptor.VTable{
        .intercept_request = interceptRequest,
        .intercept_response = interceptResponse,
        .deinit = deinitFn,
    };

    pub fn init(allocator: std.mem.Allocator) !*MetricsInterceptor {
        const self = try allocator.create(MetricsInterceptor);
        self.* = .{
            .allocator = allocator,
            .request_count = std.atomic.Value(u64).init(0),
            .error_count = std.atomic.Value(u64).init(0),
            .start_time = null,
        };
        return self;
    }

    pub fn asInterceptor(self: *MetricsInterceptor) Interceptor {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    fn interceptRequest(ptr: *anyopaque, _: *InterceptorContext) Error!void {
        const self: *MetricsInterceptor = @ptrCast(@alignCast(ptr));
        _ = self.request_count.fetchAdd(1, .monotonic);
        self.start_time = std.time.nanoTimestamp();
    }

    fn interceptResponse(ptr: *anyopaque, ctx: *InterceptorContext) Error!void {
        const self: *MetricsInterceptor = @ptrCast(@alignCast(ptr));

        if (ctx.status) |status| {
            if (!status.isOk()) {
                _ = self.error_count.fetchAdd(1, .monotonic);
            }
        }

        if (self.start_time) |start| {
            const end = std.time.nanoTimestamp();
            const duration_ms = @divFloor(end - start, std.time.ns_per_ms);
            std.log.debug("RPC duration: {d}ms", .{duration_ms});
        }
    }

    fn deinitFn(ptr: *anyopaque) void {
        const self: *MetricsInterceptor = @ptrCast(@alignCast(ptr));
        self.allocator.destroy(self);
    }

    pub fn getRequestCount(self: *MetricsInterceptor) u64 {
        return self.request_count.load(.monotonic);
    }

    pub fn getErrorCount(self: *MetricsInterceptor) u64 {
        return self.error_count.load(.monotonic);
    }
};

// Tests
test "interceptor chain execution" {
    const allocator = std.testing.allocator;

    var chain = InterceptorChain.init(allocator);
    defer chain.deinit();

    var logging = try LoggingInterceptor.init(allocator, true, true);
    try chain.add(logging.asInterceptor());

    var meta = Metadata.init(allocator);
    defer meta.deinit();

    var ctx = InterceptorContext{
        .method = "TestService/TestMethod",
        .metadata = &meta,
        .request_body = "test request",
        .response_body = "test response",
        .status = Status.ok(),
        .allocator = allocator,
    };

    try chain.interceptRequest(&ctx);
    try chain.interceptResponse(&ctx);
}

test "auth interceptor adds headers" {
    const allocator = std.testing.allocator;

    var auth = try AuthInterceptor.init(allocator, "Bearer abc123", "authorization");
    defer auth.asInterceptor().deinit();

    var meta = Metadata.init(allocator);
    defer meta.deinit();

    var ctx = InterceptorContext{
        .method = "TestService/TestMethod",
        .metadata = &meta,
        .request_body = "test",
        .response_body = null,
        .status = null,
        .allocator = allocator,
    };

    try auth.asInterceptor().interceptRequest(&ctx);

    const auth_header = meta.getAscii("authorization");
    try std.testing.expect(auth_header != null);
    try std.testing.expectEqualStrings("Bearer abc123", auth_header.?);
}

test "metrics interceptor counts requests" {
    const allocator = std.testing.allocator;

    var metrics = try MetricsInterceptor.init(allocator);
    defer metrics.asInterceptor().deinit();

    var meta = Metadata.init(allocator);
    defer meta.deinit();

    var ctx = InterceptorContext{
        .method = "TestService/TestMethod",
        .metadata = &meta,
        .request_body = "test",
        .response_body = "response",
        .status = Status.ok(),
        .allocator = allocator,
    };

    try metrics.asInterceptor().interceptRequest(&ctx);
    try metrics.asInterceptor().interceptResponse(&ctx);

    try std.testing.expectEqual(@as(u64, 1), metrics.getRequestCount());
    try std.testing.expectEqual(@as(u64, 0), metrics.getErrorCount());

    // Test error counting
    ctx.status = Status.internal("test error");
    try metrics.asInterceptor().interceptRequest(&ctx);
    try metrics.asInterceptor().interceptResponse(&ctx);

    try std.testing.expectEqual(@as(u64, 2), metrics.getRequestCount());
    try std.testing.expectEqual(@as(u64, 1), metrics.getErrorCount());
}
