# Core API Reference

**Complete API documentation for zRPC core framework**

The core module provides transport-agnostic RPC functionality, including client/server operations, service definitions, and message handling.

## Client API

### Client

Main client interface for making RPC calls.

```zig
pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    config: ClientConfig,

    /// Initialize a new RPC client
    pub fn init(allocator: std.mem.Allocator, config: ClientConfig) !*Client {
        const client = try allocator.create(Client);
        client.* = Client{
            .allocator = allocator,
            .transport = config.transport,
            .config = config,
        };
        return client;
    }

    /// Clean up client resources
    pub fn deinit(self: *Client) void {
        self.transport.deinit();
        self.allocator.destroy(self);
    }

    /// Connect to server endpoint
    pub fn connect(self: *Client, endpoint: []const u8, tls_config: ?*const TlsConfig) !void {
        const connection = try self.transport.connect(self.allocator, endpoint, tls_config);
        self.connection = connection;
    }

    /// Check if client is connected
    pub fn isConnected(self: *const Client) bool {
        return self.connection != null and self.connection.?.isConnected();
    }

    /// Make a unary RPC call
    pub fn call(self: *Client, comptime RequestType: type, comptime ResponseType: type,
                service_method: []const u8, request: RequestType) !ResponseType {
        return self.callWithContext(RequestType, ResponseType, service_method, request, &RequestContext{});
    }

    /// Make a unary RPC call with context
    pub fn callWithContext(self: *Client, comptime RequestType: type, comptime ResponseType: type,
                          service_method: []const u8, request: RequestType, context: *const RequestContext) !ResponseType {
        // Implementation details...
    }

    /// Create a client streaming RPC
    pub fn clientStream(self: *Client, comptime RequestType: type, comptime ResponseType: type,
                       service_method: []const u8) !*ClientStream(RequestType, ResponseType) {
        // Implementation details...
    }

    /// Create a server streaming RPC
    pub fn serverStream(self: *Client, comptime RequestType: type, comptime ResponseType: type,
                       service_method: []const u8, request: RequestType) !*ServerStream(RequestType, ResponseType) {
        // Implementation details...
    }

    /// Create a bidirectional streaming RPC
    pub fn bidirectionalStream(self: *Client, comptime RequestType: type, comptime ResponseType: type,
                              service_method: []const u8) !*BidirectionalStream(RequestType, ResponseType) {
        // Implementation details...
    }
};
```

### ClientConfig

Configuration options for RPC clients.

```zig
pub const ClientConfig = struct {
    /// Transport adapter instance (required)
    transport: Transport,

    /// Request timeout in milliseconds
    request_timeout_ms: u64 = 5000,

    /// Maximum message size in bytes
    max_message_size: usize = 4 * 1024 * 1024, // 4MB

    /// Enable request compression
    enable_compression: bool = true,

    /// Compression algorithm
    compression_algorithm: CompressionAlgorithm = .gzip,

    /// Authentication configuration
    auth: ?AuthConfig = null,

    /// Enable debug logging
    enable_debug_logging: bool = false,

    /// Enable metrics collection
    enable_metrics: bool = false,

    /// Arena allocator for request-scoped allocations
    arena_allocator: ?std.mem.Allocator = null,

    /// Custom headers to include with all requests
    default_headers: ?std.StringHashMap([]const u8) = null,

    /// Create default client configuration
    pub fn default(transport: Transport) ClientConfig {
        return ClientConfig{
            .transport = transport,
        };
    }

    /// Create configuration optimized for high throughput
    pub fn highThroughput(transport: Transport) ClientConfig {
        return ClientConfig{
            .transport = transport,
            .request_timeout_ms = 10000,
            .max_message_size = 16 * 1024 * 1024, // 16MB
            .enable_compression = true,
            .compression_algorithm = .lz4, // Faster compression
        };
    }

    /// Create configuration optimized for low latency
    pub fn lowLatency(transport: Transport) ClientConfig {
        return ClientConfig{
            .transport = transport,
            .request_timeout_ms = 1000,
            .enable_compression = false, // Skip compression overhead
        };
    }
};
```

### RequestContext

Context information for RPC requests.

```zig
pub const RequestContext = struct {
    /// Request deadline (absolute timestamp)
    deadline: ?i64 = null,

    /// Custom headers for this request
    headers: ?std.StringHashMap([]const u8) = null,

    /// Request priority (0 = lowest, 255 = highest)
    priority: u8 = 128,

    /// Trace ID for distributed tracing
    trace_id: ?[]const u8 = null,

    /// Parent span ID for distributed tracing
    parent_span_id: ?[]const u8 = null,

    /// User-defined metadata
    metadata: ?std.StringHashMap([]const u8) = null,

    /// Create context with deadline
    pub fn withDeadline(deadline_ms: u64) RequestContext {
        const now = std.time.milliTimestamp();
        return RequestContext{
            .deadline = now + @as(i64, @intCast(deadline_ms)),
        };
    }

    /// Create context with custom headers
    pub fn withHeaders(headers: std.StringHashMap([]const u8)) RequestContext {
        return RequestContext{
            .headers = headers,
        };
    }

    /// Create context with tracing information
    pub fn withTrace(trace_id: []const u8, parent_span_id: ?[]const u8) RequestContext {
        return RequestContext{
            .trace_id = trace_id,
            .parent_span_id = parent_span_id,
        };
    }

    /// Check if request has exceeded deadline
    pub fn isExpired(self: *const RequestContext) bool {
        if (self.deadline) |deadline| {
            return std.time.milliTimestamp() > deadline;
        }
        return false;
    }
};
```

## Server API

### Server

RPC server for handling incoming requests.

```zig
pub const Server = struct {
    allocator: std.mem.Allocator,
    transport: Transport,
    config: ServerConfig,
    services: std.StringHashMap(ServiceHandler),

    /// Initialize a new RPC server
    pub fn init(allocator: std.mem.Allocator, config: ServerConfig) !*Server {
        const server = try allocator.create(Server);
        server.* = Server{
            .allocator = allocator,
            .transport = config.transport,
            .config = config,
            .services = std.StringHashMap(ServiceHandler).init(allocator),
        };
        return server;
    }

    /// Clean up server resources
    pub fn deinit(self: *Server) void {
        self.services.deinit();
        self.transport.deinit();
        self.allocator.destroy(self);
    }

    /// Bind server to network endpoint
    pub fn bind(self: *Server, endpoint: []const u8, tls_config: ?*const TlsConfig) !void {
        // Implementation details...
    }

    /// Register a service implementation
    pub fn registerService(self: *Server, comptime ServiceType: type, service_impl: ServiceType) !void {
        const service_name = @typeName(ServiceType);
        const handler = ServiceHandler{
            .ptr = @ptrCast(&service_impl),
            .vtable = comptime createServiceVTable(ServiceType),
        };
        try self.services.put(service_name, handler);
    }

    /// Register a method handler directly
    pub fn registerHandler(self: *Server, service_method: []const u8,
                          comptime RequestType: type, comptime ResponseType: type,
                          handler: MethodHandler(RequestType, ResponseType)) !void {
        // Implementation details...
    }

    /// Start serving requests
    pub fn serve(self: *Server) !void {
        while (true) {
            const connection = try self.acceptConnection();
            try self.handleConnection(connection);
        }
    }

    /// Start serving requests with graceful shutdown
    pub fn serveWithShutdown(self: *Server, shutdown_signal: *std.Thread.ResetEvent) !void {
        // Implementation with graceful shutdown handling...
    }

    /// Stop the server gracefully
    pub fn stop(self: *Server) void {
        // Implementation details...
    }
};
```

### ServerConfig

Configuration options for RPC servers.

```zig
pub const ServerConfig = struct {
    /// Transport adapter instance (required)
    transport: Transport,

    /// Maximum concurrent connections
    max_connections: usize = 1000,

    /// Request timeout in milliseconds
    request_timeout_ms: u64 = 30000,

    /// Maximum message size in bytes
    max_message_size: usize = 4 * 1024 * 1024, // 4MB

    /// Enable request compression
    enable_compression: bool = true,

    /// Authentication required for all requests
    require_auth: bool = false,

    /// Authentication configuration
    auth: ?AuthConfig = null,

    /// Enable debug logging
    enable_debug_logging: bool = false,

    /// Enable metrics collection
    enable_metrics: bool = true,

    /// Thread pool configuration
    thread_pool_size: usize = 8,

    /// Enable keep-alive for connections
    enable_keep_alive: bool = true,

    /// Keep-alive interval in milliseconds
    keep_alive_interval_ms: u64 = 30000,

    /// Create default server configuration
    pub fn default(transport: Transport) ServerConfig {
        return ServerConfig{
            .transport = transport,
        };
    }

    /// Create configuration for high-load servers
    pub fn highLoad(transport: Transport) ServerConfig {
        return ServerConfig{
            .transport = transport,
            .max_connections = 10000,
            .thread_pool_size = 16,
            .request_timeout_ms = 15000,
        };
    }
};
```

### ResponseContext

Context information for RPC responses.

```zig
pub const ResponseContext = struct {
    /// Response status code
    status: RpcStatus = .ok,

    /// Custom headers for response
    headers: ?std.StringHashMap([]const u8) = null,

    /// Error message (if status != ok)
    error_message: ?[]const u8 = null,

    /// Error details for structured error reporting
    error_details: ?[]const u8 = null,

    /// Trace information
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,

    /// Create successful response context
    pub fn ok() ResponseContext {
        return ResponseContext{
            .status = .ok,
        };
    }

    /// Create error response context
    pub fn err(status: RpcStatus, message: []const u8) ResponseContext {
        return ResponseContext{
            .status = status,
            .error_message = message,
        };
    }

    /// Create error response with details
    pub fn errWithDetails(status: RpcStatus, message: []const u8, details: []const u8) ResponseContext {
        return ResponseContext{
            .status = status,
            .error_message = message,
            .error_details = details,
        };
    }
};
```

## Streaming APIs

### ClientStream

Client-side streaming interface for sending multiple requests.

```zig
pub fn ClientStream(comptime RequestType: type, comptime ResponseType: type) type {
    return struct {
        const Self = @This();

        stream: Stream,
        allocator: std.mem.Allocator,
        closed: bool = false,

        /// Send a request to the server
        pub fn send(self: *Self, request: RequestType) !void {
            if (self.closed) return error.StreamClosed;

            const data = try encodeMessage(self.allocator, request);
            defer self.allocator.free(data);

            try self.stream.writeFrame(.data, 0, data);
        }

        /// Signal end of requests and wait for response
        pub fn closeAndReceive(self: *Self) !ResponseType {
            if (!self.closed) {
                try self.stream.writeFrame(.data, 0x01, &.{}); // End of stream
                self.closed = true;
            }

            const frame = try self.stream.readFrame(self.allocator);
            defer self.allocator.free(frame.payload);

            return try decodeMessage(ResponseType, frame.payload);
        }

        /// Cancel the stream
        pub fn cancel(self: *Self) void {
            self.stream.cancel();
            self.closed = true;
        }

        /// Close the stream
        pub fn close(self: *Self) void {
            if (!self.closed) {
                self.stream.close();
                self.closed = true;
            }
        }
    };
}
```

### ServerStream

Server-side streaming interface for sending multiple responses.

```zig
pub fn ServerStream(comptime RequestType: type, comptime ResponseType: type) type {
    return struct {
        const Self = @This();

        stream: Stream,
        allocator: std.mem.Allocator,
        closed: bool = false,

        /// Send a response to the client
        pub fn send(self: *Self, response: ResponseType) !void {
            if (self.closed) return error.StreamClosed;

            const data = try encodeMessage(self.allocator, response);
            defer self.allocator.free(data);

            try self.stream.writeFrame(.data, 0, data);
        }

        /// Send final response and close stream
        pub fn sendAndClose(self: *Self, response: ResponseType) !void {
            if (self.closed) return error.StreamClosed;

            const data = try encodeMessage(self.allocator, response);
            defer self.allocator.free(data);

            try self.stream.writeFrame(.data, 0x01, data); // End of stream
            self.closed = true;
        }

        /// Close the stream without sending more data
        pub fn close(self: *Self) void {
            if (!self.closed) {
                self.stream.writeFrame(.data, 0x01, &.{}) catch {}; // End of stream
                self.closed = true;
            }
        }

        /// Get the initial request
        pub fn getRequest(self: *Self) !RequestType {
            const frame = try self.stream.readFrame(self.allocator);
            defer self.allocator.free(frame.payload);

            return try decodeMessage(RequestType, frame.payload);
        }
    };
}
```

### BidirectionalStream

Bidirectional streaming interface for full-duplex communication.

```zig
pub fn BidirectionalStream(comptime RequestType: type, comptime ResponseType: type) type {
    return struct {
        const Self = @This();

        stream: Stream,
        allocator: std.mem.Allocator,
        send_closed: bool = false,
        receive_closed: bool = false,

        /// Send a request to the server
        pub fn send(self: *Self, request: RequestType) !void {
            if (self.send_closed) return error.StreamClosed;

            const data = try encodeMessage(self.allocator, request);
            defer self.allocator.free(data);

            try self.stream.writeFrame(.data, 0, data);
        }

        /// Receive a response from the server
        pub fn receive(self: *Self) !?ResponseType {
            if (self.receive_closed) return null;

            const frame = try self.stream.readFrame(self.allocator);
            defer self.allocator.free(frame.payload);

            if (frame.hasFlag(0x01)) { // End of stream
                self.receive_closed = true;
                if (frame.payload.len == 0) return null;
            }

            return try decodeMessage(ResponseType, frame.payload);
        }

        /// Close the send side of the stream
        pub fn closeSend(self: *Self) !void {
            if (!self.send_closed) {
                try self.stream.writeFrame(.data, 0x01, &.{}); // End of stream
                self.send_closed = true;
            }
        }

        /// Close both sides of the stream
        pub fn close(self: *Self) void {
            if (!self.send_closed) {
                self.stream.writeFrame(.data, 0x01, &.{}) catch {}; // End of stream
                self.send_closed = true;
            }
            self.receive_closed = true;
            self.stream.close();
        }

        /// Cancel the stream immediately
        pub fn cancel(self: *Self) void {
            self.stream.cancel();
            self.send_closed = true;
            self.receive_closed = true;
        }
    };
}
```

## Service Definition

### Service Handler

Generic service handler interface.

```zig
pub const ServiceHandler = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        call: *const fn (ptr: *anyopaque, method: []const u8, request_data: []const u8,
                        context: *const RequestContext) anyerror![]u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn call(self: ServiceHandler, method: []const u8, request_data: []const u8,
                context: *const RequestContext) ![]u8 {
        return self.vtable.call(self.ptr, method, request_data, context);
    }

    pub fn deinit(self: ServiceHandler) void {
        self.vtable.deinit(self.ptr);
    }
};
```

### Method Handler

Type-safe method handler for specific request/response types.

```zig
pub fn MethodHandler(comptime RequestType: type, comptime ResponseType: type) type {
    return struct {
        const Self = @This();

        handler_fn: *const fn (request: RequestType, context: *const RequestContext) anyerror!ResponseType,

        pub fn call(self: Self, request: RequestType, context: *const RequestContext) !ResponseType {
            return self.handler_fn(request, context);
        }
    };
}
```

## Status Codes

### RpcStatus

Standard RPC status codes following gRPC conventions.

```zig
pub const RpcStatus = enum(u32) {
    ok = 0,
    cancelled = 1,
    unknown = 2,
    invalid_argument = 3,
    deadline_exceeded = 4,
    not_found = 5,
    already_exists = 6,
    permission_denied = 7,
    resource_exhausted = 8,
    failed_precondition = 9,
    aborted = 10,
    out_of_range = 11,
    unimplemented = 12,
    internal = 13,
    unavailable = 14,
    data_loss = 15,
    unauthenticated = 16,

    /// Convert status to human-readable string
    pub fn toString(self: RpcStatus) []const u8 {
        return switch (self) {
            .ok => "OK",
            .cancelled => "CANCELLED",
            .unknown => "UNKNOWN",
            .invalid_argument => "INVALID_ARGUMENT",
            .deadline_exceeded => "DEADLINE_EXCEEDED",
            .not_found => "NOT_FOUND",
            .already_exists => "ALREADY_EXISTS",
            .permission_denied => "PERMISSION_DENIED",
            .resource_exhausted => "RESOURCE_EXHAUSTED",
            .failed_precondition => "FAILED_PRECONDITION",
            .aborted => "ABORTED",
            .out_of_range => "OUT_OF_RANGE",
            .unimplemented => "UNIMPLEMENTED",
            .internal => "INTERNAL",
            .unavailable => "UNAVAILABLE",
            .data_loss => "DATA_LOSS",
            .unauthenticated => "UNAUTHENTICATED",
        };
    }

    /// Check if status represents success
    pub fn isOk(self: RpcStatus) bool {
        return self == .ok;
    }

    /// Check if status represents a client error
    pub fn isClientError(self: RpcStatus) bool {
        return switch (self) {
            .invalid_argument, .not_found, .already_exists,
            .permission_denied, .failed_precondition,
            .out_of_range, .unauthenticated => true,
            else => false,
        };
    }

    /// Check if status represents a server error
    pub fn isServerError(self: RpcStatus) bool {
        return switch (self) {
            .internal, .unavailable, .data_loss, .resource_exhausted => true,
            else => false,
        };
    }
};
```

## Authentication

### AuthConfig

Authentication configuration for clients and servers.

```zig
pub const AuthConfig = struct {
    type: AuthType,
    token: ?[]const u8 = null,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    oauth2: ?OAuth2Config = null,
    jwt: ?JwtConfig = null,

    pub const AuthType = enum {
        none,
        basic,
        bearer,
        jwt,
        oauth2,
        custom,
    };
};
```

### JWT Configuration

```zig
pub const JwtConfig = struct {
    secret_key: []const u8,
    algorithm: Algorithm = .hs256,
    issuer: ?[]const u8 = null,
    audience: ?[]const u8 = null,
    expiration_minutes: u32 = 60,

    pub const Algorithm = enum {
        hs256,
        hs384,
        hs512,
        rs256,
        rs384,
        rs512,
    };
};
```

---

**Next**: See the [Streaming API](streaming.md) for detailed streaming patterns, or check the [Transport API](transport.md) for transport layer interfaces.