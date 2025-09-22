const std = @import("std");
const Error = @import("error.zig").Error;
const codec = @import("codec.zig");
const streaming = @import("streaming.zig");

pub const CallType = enum {
    unary,
    client_streaming,
    server_streaming,
    bidirectional_streaming,
};

pub const MethodDef = struct {
    name: []const u8,
    call_type: CallType,
};

pub const ServiceDef = struct {
    name: []const u8,
    methods: []const MethodDef,
};

pub const UnaryHandlerFn = *const fn (ctx: *CallContext, request: []const u8) Error![]u8;
pub const StreamingHandlerFn = *const fn (ctx: *CallContext, stream: *anyopaque) Error!void;

pub const CallContext = struct {
    allocator: std.mem.Allocator,
    deadline: ?i64 = null,
    metadata: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) CallContext {
        return CallContext{
            .allocator = allocator,
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CallContext) void {
        self.metadata.deinit();
    }

    pub fn setDeadline(self: *CallContext, deadline_ms: i64) void {
        self.deadline = deadline_ms;
    }

    pub fn addMetadata(self: *CallContext, key: []const u8, value: []const u8) !void {
        try self.metadata.put(key, value);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) Client {
        return Client{
            .allocator = allocator,
            .endpoint = endpoint,
        };
    }

    pub fn call(
        self: *Client,
        comptime service_method: []const u8,
        request: anytype,
        response_type: type,
        context: ?*CallContext,
    ) Error!response_type {
        _ = context;

        const request_data = try codec.JsonCodec.encode(self.allocator, request);
        defer self.allocator.free(request_data);

        var message = @import("transport.zig").Message.init(self.allocator, request_data);
        defer message.deinit();

        try message.addHeader("content-type", "application/grpc");
        try message.addHeader("grpc-method", service_method);

        const response_message = try @import("transport.zig").MockTransport.send(self.endpoint, message);
        defer {
            var mut_response = response_message;
            mut_response.deinit();
        }

        return try codec.JsonCodec.decode(self.allocator, response_message.body, response_type);
    }

    pub fn clientStream(
        self: *Client,
        comptime service_method: []const u8,
        comptime request_type: type,
        comptime response_type: type,
        context: ?*CallContext,
    ) Error!streaming.ClientStream(request_type, response_type) {
        _ = self;
        _ = service_method;
        _ = context;
        return @as(Error!streaming.ClientStream(request_type, response_type), Error.NotImplemented);
    }

    pub fn serverStream(
        self: *Client,
        comptime service_method: []const u8,
        request: anytype,
        comptime response_type: type,
        context: ?*CallContext,
    ) Error!streaming.Stream(response_type) {
        _ = self;
        _ = service_method;
        _ = request;
        _ = context;
        return @as(Error!streaming.Stream(response_type), Error.NotImplemented);
    }

    pub fn bidirectionalStream(
        self: *Client,
        comptime service_method: []const u8,
        comptime request_type: type,
        comptime response_type: type,
        context: ?*CallContext,
    ) Error!streaming.BidirectionalStream(request_type, response_type) {
        _ = self;
        _ = service_method;
        _ = context;
        return @as(Error!streaming.BidirectionalStream(request_type, response_type), Error.NotImplemented);
    }
};

pub const MethodHandler = struct {
    call_type: CallType,
    unary_handler: ?*const fn (ctx: *CallContext, request: []const u8) Error![]u8,
    client_streaming_handler: ?*const fn (ctx: *CallContext, stream: *anyopaque) Error![]u8,
    server_streaming_handler: ?*const fn (ctx: *CallContext, request: []const u8, stream: *anyopaque) Error!void,
    bidirectional_streaming_handler: ?*const fn (ctx: *CallContext, stream: *anyopaque) Error!void,

    pub fn unary(handler: *const fn (ctx: *CallContext, request: []const u8) Error![]u8) MethodHandler {
        return MethodHandler{
            .call_type = .unary,
            .unary_handler = handler,
            .client_streaming_handler = null,
            .server_streaming_handler = null,
            .bidirectional_streaming_handler = null,
        };
    }

    pub fn clientStreaming(handler: *const fn (ctx: *CallContext, stream: *anyopaque) Error![]u8) MethodHandler {
        return MethodHandler{
            .call_type = .client_streaming,
            .unary_handler = null,
            .client_streaming_handler = handler,
            .server_streaming_handler = null,
            .bidirectional_streaming_handler = null,
        };
    }

    pub fn serverStreaming(handler: *const fn (ctx: *CallContext, request: []const u8, stream: *anyopaque) Error!void) MethodHandler {
        return MethodHandler{
            .call_type = .server_streaming,
            .unary_handler = null,
            .client_streaming_handler = null,
            .server_streaming_handler = handler,
            .bidirectional_streaming_handler = null,
        };
    }

    pub fn bidirectionalStreaming(handler: *const fn (ctx: *CallContext, stream: *anyopaque) Error!void) MethodHandler {
        return MethodHandler{
            .call_type = .bidirectional_streaming,
            .unary_handler = null,
            .client_streaming_handler = null,
            .server_streaming_handler = null,
            .bidirectional_streaming_handler = handler,
        };
    }
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    services: std.StringHashMap(ServiceDef),
    handlers: std.StringHashMap(MethodHandler),
    is_running: bool,

    pub fn init(allocator: std.mem.Allocator) Server {
        return Server{
            .allocator = allocator,
            .services = std.StringHashMap(ServiceDef).init(allocator),
            .handlers = std.StringHashMap(MethodHandler).init(allocator),
            .is_running = false,
        };
    }

    pub fn deinit(self: *Server) void {
        // Free all the handler keys we allocated
        var handler_iterator = self.handlers.iterator();
        while (handler_iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.services.deinit();
        self.handlers.deinit();
    }

    pub fn registerService(self: *Server, service_def: ServiceDef) !void {
        try self.services.put(service_def.name, service_def);
    }

    pub fn registerHandler(self: *Server, service_name: []const u8, method_name: []const u8, handler: MethodHandler) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ service_name, method_name });
        defer self.allocator.free(key);
        const owned_key = try self.allocator.dupe(u8, key);
        try self.handlers.put(owned_key, handler);
    }

    pub fn handleRequest(self: *Server, method_path: []const u8, request_data: []const u8, context: *CallContext) Error![]u8 {
        const handler = self.handlers.get(method_path) orelse {
            return Error.NotFound;
        };

        return switch (handler.call_type) {
            .unary => if (handler.unary_handler) |h| h(context, request_data) else Error.NotImplemented,
            .client_streaming => Error.NotImplemented, // Requires stream setup
            .server_streaming => Error.NotImplemented, // Requires stream setup
            .bidirectional_streaming => Error.NotImplemented, // Requires stream setup
        };
    }

    pub fn serve(self: *Server, address: []const u8) Error!void {
        _ = address;
        self.is_running = true;

        // Mock server implementation
        while (self.is_running) {
            // In a real implementation, this would:
            // 1. Accept incoming connections
            // 2. Parse HTTP/2 frames
            // 3. Route to appropriate handlers
            // 4. Send responses back
            std.Thread.sleep(1000000); // 1ms
        }
    }

    pub fn stop(self: *Server) void {
        self.is_running = false;
    }

    pub fn isRunning(self: Server) bool {
        return self.is_running;
    }
};

test "service definition" {
    const test_method = MethodDef{
        .name = "TestMethod",
        .call_type = .unary,
    };

    const test_service = ServiceDef{
        .name = "TestService",
        .methods = &[_]MethodDef{test_method},
    };

    try std.testing.expectEqualStrings("TestService", test_service.name);
    try std.testing.expectEqual(@as(usize, 1), test_service.methods.len);
    try std.testing.expectEqualStrings("TestMethod", test_service.methods[0].name);
    try std.testing.expectEqual(CallType.unary, test_service.methods[0].call_type);
}

test "call context" {
    var context = CallContext.init(std.testing.allocator);
    defer context.deinit();

    context.setDeadline(1000);
    try context.addMetadata("authorization", "Bearer token123");

    try std.testing.expectEqual(@as(?i64, 1000), context.deadline);
    try std.testing.expectEqualStrings("Bearer token123", context.metadata.get("authorization").?);
}

test "unary rpc call" {
    const TestRequest = struct {
        message: []const u8,
    };

    const TestResponse = struct {
        reply: []const u8,
    };

    var client = Client.init(std.testing.allocator, "http://localhost:8080");

    const request = TestRequest{ .message = "Hello, World!" };

    const response = client.call(
        "TestService/TestMethod",
        request,
        TestResponse,
        null,
    ) catch |err| switch (err) {
        Error.DeserializationError => {
            return;
        },
        else => return err,
    };

    _ = response;
}

test "server handler registration" {
    var server = Server.init(std.testing.allocator);
    defer server.deinit();

    const echo_handler = MethodHandler.unary(struct {
        fn handle(ctx: *CallContext, request: []const u8) Error![]u8 {
            _ = ctx;
            return std.testing.allocator.dupe(u8, request) catch Error.Internal;
        }
    }.handle);

    try server.registerHandler("EchoService", "Echo", echo_handler);

    var context = CallContext.init(std.testing.allocator);
    defer context.deinit();

    const response = try server.handleRequest("EchoService/Echo", "test input", &context);
    defer std.testing.allocator.free(response);

    try std.testing.expectEqualStrings("test input", response);
}

test "streaming rpc interfaces" {
    const RequestType = struct {
        data: []const u8,
    };

    const ResponseType = struct {
        result: u32,
    };

    var client = Client.init(std.testing.allocator, "http://localhost:8080");

    // Test streaming method existence (will return NotImplemented)
    const client_stream_result = client.clientStream("TestService/ClientStream", RequestType, ResponseType, null);
    try std.testing.expectError(Error.NotImplemented, client_stream_result);

    const server_stream_result = client.serverStream("TestService/ServerStream", RequestType{ .data = "test" }, ResponseType, null);
    try std.testing.expectError(Error.NotImplemented, server_stream_result);

    const bidir_stream_result = client.bidirectionalStream("TestService/BidirStream", RequestType, ResponseType, null);
    try std.testing.expectError(Error.NotImplemented, bidir_stream_result);
}