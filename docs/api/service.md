# Service API Reference

The service module provides the core RPC functionality for both clients and servers.

## Types

### CallType

Defines the type of RPC call:

```zig
pub const CallType = enum {
    unary,                    // Single request, single response
    client_streaming,         // Multiple requests, single response
    server_streaming,         // Single request, multiple responses
    bidirectional_streaming,  // Multiple requests, multiple responses
};
```

### CallContext

Provides request context and metadata:

```zig
pub const CallContext = struct {
    allocator: std.mem.Allocator,
    deadline: ?i64 = null,
    metadata: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) CallContext
    pub fn deinit(self: *CallContext) void
    pub fn setDeadline(self: *CallContext, deadline_ms: i64) void
    pub fn addMetadata(self: *CallContext, key: []const u8, value: []const u8) !void
};
```

**Usage:**
```zig
var context = CallContext.init(allocator);
defer context.deinit();

context.setDeadline(5000); // 5 second timeout
try context.addMetadata("authorization", "Bearer token123");
```

### MethodDef

Defines an RPC method:

```zig
pub const MethodDef = struct {
    name: []const u8,
    call_type: CallType,
};
```

### ServiceDef

Defines an RPC service:

```zig
pub const ServiceDef = struct {
    name: []const u8,
    methods: []const MethodDef,
};
```

## Client

### Client

RPC client for making calls to remote services:

```zig
pub const Client = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) Client
};
```

#### Methods

##### call()

Makes a unary RPC call:

```zig
pub fn call(
    self: *Client,
    comptime service_method: []const u8,
    request: anytype,
    response_type: type,
    context: ?*CallContext,
) Error!response_type
```

**Parameters:**
- `service_method`: Service and method name in format "Service/Method"
- `request`: Request data (any type that can be serialized)
- `response_type`: Expected response type
- `context`: Optional call context with metadata and timeout

**Example:**
```zig
const HelloRequest = struct { name: []const u8 };
const HelloResponse = struct { message: []const u8 };

var client = Client.init(allocator, "localhost:8080");
const request = HelloRequest{ .name = "World" };

const response = try client.call(
    "Greeter/SayHello",
    request,
    HelloResponse,
    null
);
```

##### clientStream()

Creates a client streaming RPC:

```zig
pub fn clientStream(
    self: *Client,
    comptime service_method: []const u8,
    comptime request_type: type,
    comptime response_type: type,
    context: ?*CallContext,
) Error!streaming.ClientStream(request_type, response_type)
```

**Note:** Currently returns `Error.NotImplemented`

##### serverStream()

Creates a server streaming RPC:

```zig
pub fn serverStream(
    self: *Client,
    comptime service_method: []const u8,
    request: anytype,
    comptime response_type: type,
    context: ?*CallContext,
) Error!streaming.Stream(response_type)
```

**Note:** Currently returns `Error.NotImplemented`

##### bidirectionalStream()

Creates a bidirectional streaming RPC:

```zig
pub fn bidirectionalStream(
    self: *Client,
    comptime service_method: []const u8,
    comptime request_type: type,
    comptime response_type: type,
    context: ?*CallContext,
) Error!streaming.BidirectionalStream(request_type, response_type)
```

**Note:** Currently returns `Error.NotImplemented`

## Server

### Server

RPC server for handling incoming requests:

```zig
pub const Server = struct {
    allocator: std.mem.Allocator,
    services: std.StringHashMap(ServiceDef),
    handlers: std.StringHashMap(MethodHandler),
    is_running: bool,

    pub fn init(allocator: std.mem.Allocator) Server
    pub fn deinit(self: *Server) void
};
```

#### Methods

##### registerService()

Registers a service definition:

```zig
pub fn registerService(self: *Server, service_def: ServiceDef) !void
```

##### registerHandler()

Registers a method handler:

```zig
pub fn registerHandler(
    self: *Server,
    service_name: []const u8,
    method_name: []const u8,
    handler: MethodHandler
) !void
```

**Example:**
```zig
var server = Server.init(allocator);
defer server.deinit();

const echo_handler = MethodHandler.unary(struct {
    fn handle(ctx: *CallContext, request: []const u8) Error![]u8 {
        return ctx.allocator.dupe(u8, request);
    }
}.handle);

try server.registerHandler("EchoService", "Echo", echo_handler);
```

##### handleRequest()

Handles an incoming RPC request:

```zig
pub fn handleRequest(
    self: *Server,
    method_path: []const u8,
    request_data: []const u8,
    context: *CallContext
) Error![]u8
```

##### serve()

Starts the server on the specified address:

```zig
pub fn serve(self: *Server, address: []const u8) Error!void
```

**Example:**
```zig
try server.serve("0.0.0.0:8080");
```

##### stop()

Stops the server:

```zig
pub fn stop(self: *Server) void
```

##### isRunning()

Checks if the server is running:

```zig
pub fn isRunning(self: Server) bool
```

### MethodHandler

Represents a handler for an RPC method:

```zig
pub const MethodHandler = struct {
    call_type: CallType,
    unary_handler: ?*const fn (ctx: *CallContext, request: []const u8) Error![]u8,
    client_streaming_handler: ?*const fn (ctx: *CallContext, stream: *anyopaque) Error![]u8,
    server_streaming_handler: ?*const fn (ctx: *CallContext, request: []const u8, stream: *anyopaque) Error!void,
    bidirectional_streaming_handler: ?*const fn (ctx: *CallContext, stream: *anyopaque) Error!void,
};
```

#### Constructor Methods

##### unary()

Creates a unary method handler:

```zig
pub fn unary(handler: *const fn (ctx: *CallContext, request: []const u8) Error![]u8) MethodHandler
```

##### clientStreaming()

Creates a client streaming method handler:

```zig
pub fn clientStreaming(handler: *const fn (ctx: *CallContext, stream: *anyopaque) Error![]u8) MethodHandler
```

##### serverStreaming()

Creates a server streaming method handler:

```zig
pub fn serverStreaming(handler: *const fn (ctx: *CallContext, request: []const u8, stream: *anyopaque) Error!void) MethodHandler
```

##### bidirectionalStreaming()

Creates a bidirectional streaming method handler:

```zig
pub fn bidirectionalStreaming(handler: *const fn (ctx: *CallContext, stream: *anyopaque) Error!void) MethodHandler
```

## Examples

### Complete Client Example

```zig
const std = @import("std");
const zrpc = @import("zrpc");

const HelloRequest = struct { name: []const u8 };
const HelloResponse = struct { message: []const u8 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var client = zrpc.Client.init(allocator, "localhost:8080");

    var context = zrpc.CallContext.init(allocator);
    defer context.deinit();

    context.setDeadline(5000);
    try context.addMetadata("user-agent", "zrpc-client/1.0");

    const request = HelloRequest{ .name = "World" };
    const response = try client.call(
        "Greeter/SayHello",
        request,
        HelloResponse,
        &context
    );

    std.debug.print("Response: {s}\n", .{response.message});
}
```

### Complete Server Example

```zig
const std = @import("std");
const zrpc = @import("zrpc");

const HelloRequest = struct { name: []const u8 };
const HelloResponse = struct { message: []const u8 };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var server = zrpc.Server.init(allocator);
    defer server.deinit();

    // Register greeter service
    const greeter_handler = zrpc.MethodHandler.unary(struct {
        fn sayHello(ctx: *zrpc.CallContext, request: []const u8) zrpc.Error![]u8 {
            // In a real implementation, you'd deserialize the request
            _ = request;

            const response = HelloResponse{
                .message = "Hello, World!"
            };

            // In a real implementation, you'd serialize the response
            return try ctx.allocator.dupe(u8, "serialized_response");
        }
    }.sayHello);

    try server.registerHandler("Greeter", "SayHello", greeter_handler);

    std.debug.print("Server starting on port 8080...\n");
    try server.serve("0.0.0.0:8080");
}
```