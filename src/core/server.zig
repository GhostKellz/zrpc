//! Transport-agnostic RPC server
//! Takes a Transport interface and provides RPC serving functionality

const std = @import("std");
const zsync = @import("zsync");
const transport_interface = @import("../transport_interface.zig");
const Error = @import("../error.zig").Error;

const Transport = transport_interface.Transport;
const Connection = transport_interface.Connection;
const Stream = transport_interface.Stream;
const Frame = transport_interface.Frame;
const FrameType = transport_interface.FrameType;
const TransportError = transport_interface.TransportError;
const TlsConfig = transport_interface.TlsConfig;
const Listener = transport_interface.Listener;

pub const ServerConfig = struct {
    transport: Transport,
    max_concurrent_connections: u32 = 1000,
    max_concurrent_streams_per_connection: u32 = 100,
    request_timeout_ms: u32 = 30000,
};

pub const RequestContext = struct {
    method: []const u8,
    headers: std.StringHashMap([]const u8),
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, method: []const u8, data: []const u8) RequestContext {
        return RequestContext{
            .method = method,
            .headers = std.StringHashMap([]const u8).init(allocator),
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RequestContext) void {
        self.headers.deinit();
    }
};

pub const ResponseContext = struct {
    status_code: u32 = 0, // gRPC status code
    status_message: ?[]const u8 = null,
    headers: std.StringHashMap([]const u8),
    data: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, data: []const u8) ResponseContext {
        return ResponseContext{
            .headers = std.StringHashMap([]const u8).init(allocator),
            .data = data,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ResponseContext) void {
        self.headers.deinit();
        if (self.status_message) |msg| {
            self.allocator.free(msg);
        }
    }
};

pub const ServiceHandler = struct {
    method: []const u8,
    handler_fn: *const fn (request: *RequestContext, response: *ResponseContext) Error!void,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, method: []const u8, handler_fn: *const fn (request: *RequestContext, response: *ResponseContext) Error!void) !ServiceHandler {
        const owned_method = try allocator.dupe(u8, method);
        return ServiceHandler{
            .method = owned_method,
            .handler_fn = handler_fn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ServiceHandler) void {
        self.allocator.free(self.method);
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    listener: ?Listener,
    config: ServerConfig,
    handlers: std.StringHashMap(ServiceHandler),
    is_running: std.atomic.Value(bool),
    active_connections: std.ArrayList(*ActiveConnection),

    // zsync integration for async operations
    runtime: ?*zsync.Runtime = null,
    executor: ?zsync.Executor = null,
    connection_semaphore: ?zsync.Semaphore = null,
    shutdown_wg: zsync.WaitGroup,
    rate_limiter: ?zsync.TokenBucket = null,

    const ActiveConnection = struct {
        connection: Connection,
        server: *Server,
        thread: ?std.Thread = null,

        pub fn deinit(self: *ActiveConnection) void {
            self.connection.close();
            if (self.thread) |thread| {
                thread.join();
            }
        }
    };

    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) Server {
        return Server{
            .allocator = allocator,
            .transport = config.transport,
            .listener = null,
            .config = config,
            .handlers = std.StringHashMap(ServiceHandler).init(allocator),
            .is_running = std.atomic.Value(bool).init(false),
            .active_connections = std.ArrayList(*ActiveConnection){},
            .shutdown_wg = zsync.WaitGroup.init(),
        };
    }

    /// Initialize with zsync async runtime for production use
    pub fn initWithRuntime(allocator: std.mem.Allocator, config: ServerConfig) !Server {
        // Create executor for managing connection tasks (creates its own runtime)
        const executor = try zsync.Executor.init(allocator);
        const runtime = executor.runtime;

        // Create semaphore to limit concurrent connections
        const semaphore = zsync.Semaphore.init(config.max_concurrent_connections);

        // Create rate limiter (1000 req/sec with burst of 100)
        const rate_limiter = zsync.TokenBucket.init(100, 1000);

        const server = Server{
            .allocator = allocator,
            .transport = config.transport,
            .listener = null,
            .config = config,
            .handlers = std.StringHashMap(ServiceHandler).init(allocator),
            .is_running = std.atomic.Value(bool).init(false),
            .active_connections = std.ArrayList(*ActiveConnection){},
            .runtime = runtime,
            .executor = executor,
            .connection_semaphore = semaphore,
            .shutdown_wg = zsync.WaitGroup.init(),
            .rate_limiter = rate_limiter,
        };

        return server;
    }

    pub fn deinit(self: *Server) void {
        self.stop();

        // Wait for all active connections to finish (graceful shutdown)
        self.shutdown_wg.wait();

        // Clean up handlers
        var handler_iter = self.handlers.iterator();
        while (handler_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.handlers.deinit();

        // Clean up active connections
        for (self.active_connections.items) |conn| {
            conn.deinit();
            self.allocator.destroy(conn);
        }
        self.active_connections.deinit(self.allocator);

        // Clean up zsync resources (executor owns runtime)
        if (self.executor) |*exec| {
            exec.deinit();
        }
    }

    pub fn bind(self: *Server, bind_address: []const u8, tls_config: ?*const TlsConfig) Error!void {
        self.listener = self.transport.listen(self.allocator, bind_address, tls_config) catch |err| {
            return switch (err) {
                TransportError.InvalidArgument => Error.InvalidArgument,
                TransportError.ResourceExhausted => Error.ResourceExhausted,
                else => Error.TransportError,
            };
        };
    }

    pub fn registerHandler(self: *Server, method: []const u8, handler_fn: *const fn (request: *RequestContext, response: *ResponseContext) Error!void) Error!void {
        const handler = ServiceHandler.init(self.allocator, method, handler_fn) catch return Error.OutOfMemory;
        try self.handlers.put(handler.method, handler);
    }

    pub fn serve(self: *Server) Error!void {
        if (self.listener == null) return Error.InvalidState;

        self.is_running.store(true, .release);

        // If zsync runtime is available, use async connection handling
        const use_async = self.executor != null and self.runtime != null;

        while (self.is_running.load(.acquire)) {
            // Accept new connection
            const connection = self.listener.?.accept() catch |err| {
                switch (err) {
                    TransportError.Timeout => continue,
                    TransportError.Closed => break,
                    else => return Error.TransportError,
                }
            };

            // Rate limiting (if enabled)
            if (self.rate_limiter) |*limiter| {
                if (!limiter.tryConsume(1)) {
                    std.debug.print("[Server] Rate limit exceeded, rejecting connection\n", .{});
                    connection.close();
                    continue;
                }
            }

            // Create active connection
            const active_conn = try self.allocator.create(ActiveConnection);
            active_conn.* = ActiveConnection{
                .connection = connection,
                .server = self,
            };

            try self.active_connections.append(active_conn);

            if (use_async) {
                // Async path: Use zsync executor and semaphore
                // Wait for semaphore permit (limits concurrent connections)
                if (self.connection_semaphore) |*sem| {
                    sem.acquire();
                }

                // Add to wait group for graceful shutdown
                self.shutdown_wg.add(1);

                // Spawn async task to handle connection
                const ConnectionTask = struct {
                    fn handle(io: zsync.Io) !void {
                        _ = io;
                        const conn = active_conn;
                        defer {
                            if (conn.server.connection_semaphore) |*sem| {
                                sem.release();
                            }
                            conn.server.shutdown_wg.done();
                        }

                        conn.server.handleConnection(conn) catch |err| {
                            std.debug.print("[Server] Error handling connection: {}\n", .{err});
                        };
                    }
                };

                if (self.executor) |*exec| {
                    _ = exec.spawn(ConnectionTask.handle, .{}) catch |err| {
                        std.debug.print("[Server] Failed to spawn connection task: {}\n", .{err});
                        if (self.connection_semaphore) |*sem| {
                            sem.release();
                        }
                        self.shutdown_wg.done();
                    };
                }
            } else {
                // Synchronous path (backward compatibility)
                self.handleConnection(active_conn) catch |err| {
                    std.debug.print("[Server] Error handling connection: {}\n", .{err});
                };
            }
        }
    }

    pub fn stop(self: *Server) void {
        self.is_running.store(false, .release);
        if (self.listener) |listener| {
            listener.close();
            self.listener = null;
        }
    }

    fn handleConnection(self: *Server, active_conn: *ActiveConnection) Error!void {
        while (self.is_running.load(.acquire) and active_conn.connection.isConnected()) {
            // Accept new stream on this connection
            const stream = active_conn.connection.openStream() catch |err| {
                switch (err) {
                    TransportError.Timeout => continue,
                    TransportError.Closed => break,
                    else => return Error.TransportError,
                }
            };

            // Handle stream
            self.handleStream(stream) catch |err| {
                std.debug.print("[Server] Error handling stream: {}\n", .{err});
                stream.close();
            };
        }
    }

    fn handleStream(self: *Server, stream: Stream) Error!void {
        var method: ?[]u8 = null;
        var request_data = std.ArrayList(u8){};
        defer {
            if (method) |m| self.allocator.free(m);
            request_data.deinit(self.allocator);
        }

        var end_stream_received = false;
        var headers_received = false;

        // Read request frames
        while (!end_stream_received) {
            var frame = stream.readFrame(self.allocator) catch |err| {
                return switch (err) {
                    TransportError.Timeout => Error.Timeout,
                    TransportError.Closed => Error.NetworkError,
                    TransportError.Canceled => Error.Canceled,
                    else => Error.TransportError,
                };
            };
            defer frame.deinit();

            switch (frame.frame_type) {
                .headers => {
                    headers_received = true;
                    method = try self.parseMethodFromHeaders(frame.data);
                },
                .data => {
                    // Parse gRPC message framing
                    if (frame.data.len < 5) return Error.InvalidRequest;

                    const compression_flag = frame.data[0];
                    _ = compression_flag; // Not implemented yet

                    const message_length = std.mem.readInt(u32, frame.data[1..5], .big);
                    if (frame.data.len < 5 + message_length) return Error.InvalidRequest;

                    const message_data = frame.data[5..5 + message_length];
                    try request_data.appendSlice(self.allocator, message_data);

                    if (frame.flags & Frame.Flags.END_STREAM != 0) {
                        end_stream_received = true;
                    }
                },
                else => {
                    // Ignore other frame types
                },
            }
        }

        if (!headers_received or method == null) return Error.InvalidRequest;

        // Find handler
        const handler = self.handlers.get(method.?) orelse {
            try self.sendErrorResponse(stream, 12, "Method not found"); // UNIMPLEMENTED
            return;
        };

        // Create request context
        var request_ctx = RequestContext.init(self.allocator, method.?, request_data.items);
        defer request_ctx.deinit();

        // Create response context
        var response_data = std.ArrayList(u8){};
        defer response_data.deinit(self.allocator);

        var response_ctx = ResponseContext.init(self.allocator, &.{});
        defer response_ctx.deinit();

        // Call handler
        handler.handler_fn(&request_ctx, &response_ctx) catch |err| {
            const status_code: u32 = switch (err) {
                Error.InvalidRequest => 3, // INVALID_ARGUMENT
                Error.NotFound => 5, // NOT_FOUND
                Error.Timeout => 4, // DEADLINE_EXCEEDED
                else => 13, // INTERNAL
            };
            try self.sendErrorResponse(stream, status_code, "Handler error");
            return;
        };

        // Send successful response
        try self.sendResponse(stream, response_ctx.data);
    }

    fn parseMethodFromHeaders(self: *Server, headers_data: []const u8) Error![]u8 {
        // Simple header parsing - look for :path header
        // Format: "key\0value\0key\0value\0..."
        var pos: usize = 0;

        while (pos < headers_data.len) {
            // Find key
            const key_start = pos;
            const key_end = std.mem.indexOfScalarPos(u8, headers_data, pos, 0) orelse break;
            const key = headers_data[key_start..key_end];

            pos = key_end + 1;
            if (pos >= headers_data.len) break;

            // Find value
            const value_start = pos;
            const value_end = std.mem.indexOfScalarPos(u8, headers_data, pos, 0) orelse headers_data.len;
            const value = headers_data[value_start..value_end];

            pos = value_end + 1;

            if (std.mem.eql(u8, key, ":path") and value.len > 1 and value[0] == '/') {
                return try self.allocator.dupe(u8, value[1..]); // Remove leading '/'
            }
        }

        return Error.InvalidRequest;
    }

    fn sendResponse(self: *Server, stream: Stream, response_data: []const u8) Error!void {
        // Send response headers
        var headers = std.ArrayList(u8){};
        defer headers.deinit(self.allocator);

        try headers.appendSlice(self.allocator, ":status");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "200");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "content-type");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "application/grpc");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "grpc-status");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "0");
        try headers.append(self.allocator, 0);

        stream.writeFrame(FrameType.headers, Frame.Flags.END_HEADERS, headers.items) catch |err| {
            return switch (err) {
                TransportError.Timeout => Error.Timeout,
                TransportError.Closed => Error.NetworkError,
                else => Error.TransportError,
            };
        };

        // Send response data
        var framed_data = std.ArrayList(u8){};
        defer framed_data.deinit(self.allocator);

        try framed_data.append(self.allocator, 0); // Not compressed
        const length_bytes = std.mem.toBytes(std.mem.nativeToBig(u32, @intCast(response_data.len)));
        try framed_data.appendSlice(self.allocator, &length_bytes);
        try framed_data.appendSlice(self.allocator, response_data);

        stream.writeFrame(FrameType.data, Frame.Flags.END_STREAM, framed_data.items) catch |err| {
            return switch (err) {
                TransportError.Timeout => Error.Timeout,
                TransportError.Closed => Error.NetworkError,
                else => Error.TransportError,
            };
        };
    }

    fn sendErrorResponse(self: *Server, stream: Stream, status_code: u32, message: []const u8) Error!void {
        var headers = std.ArrayList(u8){};
        defer headers.deinit(self.allocator);

        try headers.appendSlice(self.allocator, ":status");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "500");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "content-type");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, "application/grpc");
        try headers.append(self.allocator, 0);

        // Convert status code to string
        var status_buf: [16]u8 = undefined;
        const status_str = std.fmt.bufPrint(&status_buf, "{}", .{status_code}) catch "13";

        try headers.appendSlice(self.allocator, "grpc-status");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, status_str);
        try headers.append(self.allocator, 0);

        try headers.appendSlice(self.allocator, "grpc-message");
        try headers.append(self.allocator, 0);
        try headers.appendSlice(self.allocator, message);
        try headers.append(self.allocator, 0);

        stream.writeFrame(FrameType.headers, Frame.Flags.END_HEADERS | Frame.Flags.END_STREAM, headers.items) catch |err| {
            return switch (err) {
                TransportError.Timeout => Error.Timeout,
                TransportError.Closed => Error.NetworkError,
                else => Error.TransportError,
            };
        };
    }
};

test "server basic functionality" {
    // Mock transport for testing
    const MockTransport = struct {
        pub fn connect(self: *@This(), allocator: std.mem.Allocator, endpoint: []const u8, tls_config: ?*const TlsConfig) TransportError!Connection {
            _ = self;
            _ = allocator;
            _ = endpoint;
            _ = tls_config;
            return TransportError.NotConnected;
        }

        pub fn listen(self: *@This(), allocator: std.mem.Allocator, bind_address: []const u8, tls_config: ?*const TlsConfig) TransportError!Listener {
            _ = self;
            _ = allocator;
            _ = bind_address;
            _ = tls_config;
            return TransportError.NotConnected;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var mock_transport = MockTransport{};
    const transport = transport_interface.createTransport(MockTransport, &mock_transport);

    var server = Server.init(std.testing.allocator, .{ .transport = transport });
    defer server.deinit();

    try std.testing.expect(!server.is_running.load(.acquire));
}