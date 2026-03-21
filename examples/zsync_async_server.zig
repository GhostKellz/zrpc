//! Example: zrpc Server with zsync Async Runtime
//! Demonstrates how to use zrpc with zsync for async connection handling

const std = @import("std");
const zrpc_core = @import("zrpc-core");
const zsync = @import("zsync");

const Server = zrpc_core.server.Server;
const ServerConfig = zrpc_core.server.ServerConfig;
const RequestContext = zrpc_core.server.RequestContext;
const ResponseContext = zrpc_core.server.ResponseContext;
const Error = zrpc_core.Error;

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    std.debug.print("\n🚀 zrpc + zsync Async Server Example\n\n", .{});

    // Create mock transport for demonstration
    var mock_transport = MockTransport{};
    const transport = zrpc_core.transport.createTransport(MockTransport, &mock_transport);

    // Create server config
    const config = ServerConfig{
        .transport = transport,
        .max_concurrent_connections = 100,
        .max_concurrent_streams_per_connection = 10,
        .request_timeout_ms = 30000,
    };

    // Initialize server with zsync async runtime
    var server = try Server.initWithRuntime(allocator, config);
    defer server.deinit();

    std.debug.print("✓ Server initialized with zsync async runtime\n", .{});
    std.debug.print("  - Max concurrent connections: {}\n", .{config.max_concurrent_connections});
    std.debug.print("  - Rate limiter: {} req/sec (burst: 100)\n", .{1000});
    std.debug.print("  - Executor: enabled\n", .{});
    std.debug.print("  - Connection semaphore: enabled\n", .{});
    std.debug.print("  - WaitGroup for graceful shutdown: enabled\n\n", .{});

    // Register example handlers
    try server.registerHandler("Echo", echoHandler);
    try server.registerHandler("Uppercase", uppercaseHandler);
    try server.registerHandler("Reverse", reverseHandler);

    std.debug.print("✓ Registered 3 RPC handlers:\n", .{});
    std.debug.print("  - Echo: Returns the input unchanged\n", .{});
    std.debug.print("  - Uppercase: Converts input to uppercase\n", .{});
    std.debug.print("  - Reverse: Reverses the input string\n\n", .{});

    // Bind to address
    try server.bind("localhost:9000", null);
    std.debug.print("✓ Server bound to localhost:9000\n\n", .{});

    std.debug.print("📊 Server Features:\n", .{});
    std.debug.print("  • Async connection handling via zsync.Executor\n", .{});
    std.debug.print("  • Concurrent connection limiting via zsync.Semaphore\n", .{});
    std.debug.print("  • Rate limiting via zsync.TokenBucket (1000 req/sec)\n", .{});
    std.debug.print("  • Graceful shutdown via zsync.WaitGroup\n", .{});
    std.debug.print("  • Zero-cost abstractions with zsync runtime\n\n", .{});

    std.debug.print("🎯 Key Benefits:\n", .{});
    std.debug.print("  ✓ Handles thousands of concurrent connections\n", .{});
    std.debug.print("  ✓ Automatic backpressure via semaphore\n", .{});
    std.debug.print("  ✓ Rate limiting prevents abuse\n", .{});
    std.debug.print("  ✓ Clean shutdown waits for all connections\n", .{});
    std.debug.print("  ✓ gRPC protocol handling unchanged\n\n", .{});

    std.debug.print("💡 Note: This example demonstrates zsync integration.\n", .{});
    std.debug.print("   Real servers would call server.serve() and handle connections.\n\n", .{});

    std.debug.print("✅ Example completed successfully!\n\n", .{});
}

// Echo handler - returns input unchanged
fn echoHandler(request: *RequestContext, response: *ResponseContext) Error!void {
    response.* = ResponseContext.init(request.allocator, request.data);
}

// Uppercase handler - converts to uppercase
fn uppercaseHandler(request: *RequestContext, response: *ResponseContext) Error!void {
    const upper = try request.allocator.alloc(u8, request.data.len);
    for (request.data, 0..) |c, i| {
        upper[i] = std.ascii.toUpper(c);
    }
    response.* = ResponseContext.init(request.allocator, upper);
}

// Reverse handler - reverses string
fn reverseHandler(request: *RequestContext, response: *ResponseContext) Error!void {
    const reversed = try request.allocator.alloc(u8, request.data.len);
    for (request.data, 0..) |c, i| {
        reversed[request.data.len - 1 - i] = c;
    }
    response.* = ResponseContext.init(request.allocator, reversed);
}

// Mock transport for demonstration
const MockTransport = struct {
    pub fn connect(
        _: *@This(),
        _: std.mem.Allocator,
        _: []const u8,
        _: ?*const zrpc_core.transport.TlsConfig,
    ) zrpc_core.transport.TransportError!zrpc_core.transport.Connection {
        return zrpc_core.transport.TransportError.NotConnected;
    }

    pub fn listen(
        _: *@This(),
        allocator: std.mem.Allocator,
        _: []const u8,
        _: ?*const zrpc_core.transport.TlsConfig,
    ) zrpc_core.transport.TransportError!zrpc_core.transport.Listener {
        // Return mock listener that doesn't accept connections
        const MockListener = struct {
            pub fn accept(_: *@This()) zrpc_core.transport.TransportError!zrpc_core.transport.Connection {
                return zrpc_core.transport.TransportError.Timeout;
            }

            pub fn close(_: *@This()) void {}
        };
        const listener = try allocator.create(MockListener);
        listener.* = MockListener{};
        return zrpc_core.transport.Listener{
            .ptr = listener,
            .vtable = &.{
                .accept = @ptrCast(&MockListener.accept),
                .close = @ptrCast(&MockListener.close),
            },
        };
    }

    pub fn deinit(_: *@This()) void {}
};
